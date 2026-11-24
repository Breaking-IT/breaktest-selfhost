"""Copy and verify a consistent TimescaleDB monitoring snapshot into native segments."""

from collections import Counter, defaultdict
from contextlib import closing, contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from itertools import batched, groupby


# The running service image supplies the exact native codec, rollup definitions and schemas.
@contextmanager
def storage_tools(container, work):
    with tempfile.TemporaryDirectory(dir=work) as directory:
        target = Path(directory)
        for src, dest in [
            ("/usr/local/bin/breaktest-db", target / "breaktest-db"),
            ("/usr/lib/breaktest/monitoring", target / "monitoring"),
        ]:
            subprocess.run(
                ["docker", "cp", container + ":" + src, str(dest)], check=True
            )
        old = os.environ.get("BREAKTEST_DB_BINARY")
        os.environ["BREAKTEST_DB_BINARY"] = str(target / "breaktest-db")
        sys.path.insert(0, str(target / "monitoring"))
        try:
            yield
        finally:
            sys.path.remove(str(target / "monitoring"))
            if old is None:
                os.environ.pop("BREAKTEST_DB_BINARY", None)
            else:
                os.environ["BREAKTEST_DB_BINARY"] = old


class Fingerprint:
    def __init__(self):
        self.count = 0
        self.total = 0

    def add(self, row):
        self.count += 1
        self.total = (
            self.total
            + int.from_bytes(
                hashlib.sha256(
                    json.dumps(
                        row, separators=(",", ":"), ensure_ascii=True, allow_nan=False
                    ).encode()
                ).digest(),
                "big",
            )
        ) % (1 << 256)

    def result(self):
        return [self.count, format(self.total, "064x")]


def import_rows(tenant, state, stream, values, source_hash):
    from segments import SCHEMA, RAW, ERROR, canonical, period_of, write_part
    from native import append_samples, screenshot

    cols = SCHEMA[stream]
    for batch in batched(values, 8192):
        groups = defaultdict(list)
        for record in batch:
            row = [canonical(v, k) for v, (_, k) in zip(record, cols, strict=True)]
            if stream == "sm_screenshots":
                data = row[1]
                if data.startswith("data:"):
                    prefix, data = data.split(",", 1)
                    row[2] = prefix[5:].split(";")[0]
                row[1] = "".join(data.split())
            source_hash.add(row)
            if stream == "sm_screenshots":
                screenshot(tenant, state, row)
                continue
            groups[period_of(row[0])].append(row)
        for day, rows in groups.items():
            if stream in (*RAW, ERROR):
                append_samples(tenant, state, stream, day, rows, merge=False)
            else:
                write_part(tenant, state, stream, day, rows)


def verify(tenant, state, stream, expected):
    from segments import rows

    actual = Fingerprint()
    for r in rows(tenant, state, stream):
        actual.add(r)
    if stream == "sm_runs":
        for a in state["assignments"].values():
            if not a.get("done"):
                actual.add(a["row"])
    if actual.result() != expected:
        raise ValueError(f"Native monitoring row mismatch in {stream}")
    print(f"{stream}: {actual.count:,} rows verified", flush=True)


def imported_streams():
    from segments import SCHEMA

    return [s for s in SCHEMA if not s.startswith(("hours_", "monitor_"))]


class SourceChanged(ValueError):
    pass


def absent_columns(stream, columns, present):
    """Columns an older TimescaleDB schema lacks; they are copied as null.

    The time column orders and partitions the copy, so it must exist."""
    missing = [name for name, _ in columns if name not in present]
    stamp = "created_at" if stream == "sm_screenshots" else columns[0][0]
    if stamp in missing:
        raise ValueError(f"{stream} has no {stamp} column")
    return missing


def pg_import(tenant, state, dsn, existing=False):
    from segments import SCHEMA, HOUR, micros
    import psycopg2
    from psycopg2 import sql

    with closing(psycopg2.connect(dsn)) as pg, pg.cursor() as c:
        pg.set_session(readonly=True, isolation_level="REPEATABLE READ")
        c.execute("SET LOCAL TIME ZONE 'UTC'")
        c.execute("SELECT current_database()")
        database = c.fetchone()[0]
        c.execute("""SELECT view_definition FROM timescaledb_information.continuous_aggregates
                WHERE view_schema='public' AND view_name='requests_aggregated_1h_sm'""")
        result = c.fetchone()
        col = "*"
        if result:
            match = re.search(
                r'\bcount\(\s*(?:[\w"]+\.)?([\w*]+)\s*\)\s+AS\s+"?count"?\b',
                result[0],
                re.I,
            )
            if not match or match[1].lower() not in ("*", "response_code"):
                raise ValueError("unrecognized hourly request count")
            col = match[1].lower()
        c.execute("""SELECT table_name FROM information_schema.tables WHERE table_schema='public'
                  AND (right(table_name,3)='_sm' OR left(table_name,3)='sm_')""")
        tables = {r[0] for r in c}
        unmapped = sorted(tables - set(imported_streams()))
        if unmapped:
            # Copying the rest would silently leave this data behind.
            raise ValueError("unmapped monitoring stream: " + ", ".join(unmapped))
        c.execute(
            """SELECT table_name, column_name FROM information_schema.columns
                  WHERE table_schema='public' AND table_name = ANY(%s)""",
            (sorted(tables),),
        )
        present = defaultdict(set)
        for table, column in c:
            present[table].add(column)
        if not existing:
            state["request_count_column"] = col
        elif state["request_count_column"] != col:
            raise SourceChanged("hourly count definition changed")
        source = {}
        for stream in sorted(tables):
            cols = SCHEMA[stream]
            missing = absent_columns(stream, cols, present[stream])
            if missing and not existing:
                print(
                    f"{stream}: source has no {', '.join(missing)}; copied as null",
                    flush=True,
                )
                # A rollup without a dimension covers every value of it. Readers
                # need this to recognise the samples the rollup already counts.
                state.setdefault("absent_columns", {})[stream] = missing
            keys = sql.SQL(",").join(
                sql.SQL("NULL") if k in missing else sql.Identifier(k) for k, _ in cols
            )
            stamp = sql.Identifier(
                "created_at" if stream == "sm_screenshots" else cols[0][0]
            )
            with pg.cursor(name="sm_native_import") as cursor:
                cursor.itersize = 2048
                cursor.execute(
                    sql.SQL("SELECT {} FROM public.{} ORDER BY {}").format(
                        keys, sql.Identifier(stream), stamp
                    )
                )
                f = Fingerprint()
                if existing:
                    from segments import canonical

                    for row in cursor:
                        row = [
                            canonical(v, k) for v, (_, k) in zip(row, cols, strict=True)
                        ]
                        if stream == "sm_screenshots":
                            if row[1].startswith("data:"):
                                prefix, row[1] = row[1].split(",", 1)
                                row[2] = prefix[5:].split(";")[0]
                            row[1] = "".join(row[1].split())
                        f.add(row)
                else:
                    import_rows(tenant, state, stream, cursor, f)
                source[stream] = f.result()
            if not existing:
                verify(tenant, state, stream, f.result())
                if stream.endswith("_sm") and stream != "requests_error_sm":
                    c.execute(
                        sql.SQL("SELECT max({}) FROM public.{}").format(
                            stamp, sql.Identifier(stream)
                        )
                    )
                    t = c.fetchone()[0]
                    if t:
                        state["cutoff"] = max(
                            state.get("cutoff") or 0, (micros(t) // HOUR + 1) * HOUR
                        )
        if existing and (
            state.get("source") != source or database != state.get("database")
        ):
            raise SourceChanged(
                "TimescaleDB monitoring data changed since the previous copy"
            )
        state.update(source=source, database=database)


def check_refresh(tenant, previous, replacement):
    """Ensure advancing TS retention cannot silently erase already copied samples."""
    from hourly import STREAMS
    from segments import period_bounds, read_part

    dimensions = {view: 1 + len(dims) for view, dims, _ in STREAMS.values()}
    for stream, fingerprint in previous["source"].items():
        if fingerprint == replacement["source"].get(stream):
            continue

        # TS imports are ordered by event time; monthly compaction preserves
        # that order. Compare multiplicities one timestamp at a time.
        def groups(state):
            periods = state["parts"].get(stream, {})

            def key(period):
                return (period == "unknown", period_bounds(period)[0])

            records = (
                row
                for period in sorted(periods, key=key)
                for part in periods[period]
                for row in read_part(tenant, part)
            )
            index = 4 if stream == "sm_screenshots" else 0

            def time_key(row):
                return (row[index] is None, row[index])

            for stamp, batch in groupby(records, time_key):
                if stream == "sm_runs":
                    # A run may finish between snapshots.
                    keys = (tuple(row[:4]) for row in batch)
                elif stream in dimensions:
                    # Materialized totals may advance within an existing bucket.
                    keys = (tuple(row[: dimensions[stream]]) for row in batch)
                elif stream == "sm_screenshots":
                    keys = (
                        (row[0], hashlib.sha256(row[1].encode()).digest(), *row[2:])
                        for row in batch
                    )
                else:
                    keys = (tuple(row) for row in batch)
                yield stamp, Counter(keys)

        new_groups = groups(replacement)
        current = next(new_groups, None)
        for stamp, old_rows in groups(previous):
            while current and current[0] < stamp:
                current = next(new_groups, None)
            if current is None or current[0] != stamp or not old_rows <= current[1]:
                raise ValueError(
                    f"TimescaleDB no longer contains previously copied {stream} data; existing copy preserved"
                )


def source_database(dsn):
    from psycopg2.extensions import parse_dsn

    return parse_dsn(dsn)["dbname"]


def copy(dsn, cid, root, owner=None):
    from segments import initial, publish, catalog, locked, sweep

    tenant = Path(root) / ".monitoring" / cid
    tenant.mkdir(parents=True, exist_ok=True)
    (tenant / ".migration.lock").touch(exist_ok=True)
    (tenant / ".sweep.lock").touch(exist_ok=True)
    with locked(tenant, True):
        exists = (tenant / "native.json").exists()
        state = catalog(tenant) if exists else initial(cid)
        previous = state if exists else None
        if exists:
            if state.get("database") and state["database"] != source_database(dsn):
                raise ValueError("source monitoring database changed")
            try:
                pg_import(tenant, state, dsn, existing=True)
            except SourceChanged:
                if not state.get("source_snapshot_only"):
                    raise ValueError(
                        "cannot replace monitoring data with native writes"
                    )
                # The old catalog stays readable until the replacement is verified.
                state = initial(cid)
                exists = False
        if not exists:
            try:
                pg_import(tenant, state, dsn)
                if previous:
                    check_refresh(tenant, previous, state)
            except Exception:
                sweep(tenant, previous or initial(cid))
                raise
            state["source_snapshot_only"] = True
            from hourly import seal_months
            import time

            seal_months(tenant, state, time.time_ns() // 1000)
            if owner:
                for path in [
                    tenant.parent,
                    tenant,
                    tenant / ".migration.lock",
                    tenant / ".sweep.lock",
                    *(tenant / "segments").rglob("*"),
                ]:
                    os.chown(path, *owner)
                if (tenant / "segments").is_dir():
                    os.chown(tenant / "segments", *owner)
            # Install ownership before the generation becomes visible to the service.
            from segments import sync_dir

            with tempfile.TemporaryDirectory(dir=tenant) as stage:
                marker = Path(stage) / "native.json"
                publish(marker, state)
                if owner:
                    os.chown(marker, *owner)
                os.replace(marker, tenant / "native.json")
                sync_dir(tenant)
            sweep(tenant, state)
        else:
            # Check the retained bytes as well as the source snapshot.
            verify_installed(tenant, state)
        return state


def verify_installed(tenant, state):
    from segments import command

    for stream, periods in state["parts"].items():
        for ids in periods.values():
            for part in ids:
                if not re.fullmatch("[0-9a-f]{32}", part):
                    raise ValueError("invalid segment in monitoring catalog")
                subprocess.run(
                    command("verify", tenant / "segments" / part), check=True
                )
        print(f"{stream}: installed segments verified", flush=True)


def check_selected(root, cid, dsn, reverify):
    from segments import catalog, locked

    tenant = Path(root) / ".monitoring" / cid
    with locked(tenant, False):
        state = catalog(tenant)
        if "source" not in state or state.get("database") != source_database(dsn):
            raise ValueError(
                "Selected monitoring dataset has no matching verified TimescaleDB copy"
            )
        if reverify:
            verify_installed(tenant, state)
