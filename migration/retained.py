"""Portable retained SQL results. Exported in the same read-only snapshot as raw rows."""
import datetime as dt
import hashlib
from email.utils import parsedate_to_datetime
import json
from pathlib import Path
try:
    from compression import zstd
except ImportError:
    import zstandard as zstd

NAME = 'retained-timescaledb-v1.jsonl.zstd'
TABLES = ('requests_aggregated_1s', 'requests_run_aggregated', 'transactions_run_aggregated', 'tests_aggregated')
EPOCH = dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc)


class EmptySource(ValueError):
    """The source holds neither raw nor retained rows for the run."""


def availability(rows, expected=None, strict=True):
    """Compare remaining raw rows with the finalized count.

    More rows than the summary is impossible for requests (the summary is built
    from them) and aborts. Error/transaction summaries are not a guaranteed upper
    bound, so with strict=False that stream is marked unknown instead.
    """
    excess = expected is not None and rows > expected
    if excess and strict:
        raise ValueError('Retained raw count exceeds finalized summary')
    return {'retained_rows': rows, 'expected_rows': expected,
            'status': 'unknown' if excess else ('complete' if rows == expected else 'missing' if rows == 0 else 'partial')
            if expected is not None else ('missing' if rows == 0 else 'unknown'),
            'reason': 'Source retention/deletion may have removed detail; missing rows are not reconstructed'}


def export(conn, run, work, stats, test):
    """Stream exact source JSON rows; numeric averages stay decimal strings."""
    tables = {}; bounds = []; expected = {}; digest = hashlib.sha256()
    payload = Path(work) / 'retained-rows.jsonl'
    with payload.open('wb') as out:
        for table in TABLES:
            with conn.cursor() as c:
                c.execute('SELECT to_regclass(%s)', ('public.' + table,))
                exists = c.fetchone()[0]
            count = 0
            if exists:
                # Named cursor prevents a large retained aggregate from becoming a Python list.
                with conn.cursor(name='retained_' + table) as c:
                    if table == 'requests_aggregated_1s':
                        columns = "(extract(epoch FROM bucket - timestamptz '2000-01-01')*1000000)::bigint AS time, sampler_name, transaction_name, mean_response_time::text, mean_latency::text, mean_connect_time::text, count, error_count, bytes_in, bytes_out"
                    else:
                        columns = '*'
                    c.execute('SELECT row_to_json(r)::text FROM (SELECT ' + columns + ' FROM public.' + table + ' WHERE run_id=%s ORDER BY ' + ('bucket,sampler_name,transaction_name' if table == 'requests_aggregated_1s' else 'sampler_name,transaction_name' if table == 'requests_run_aggregated' else 'transaction_name' if table == 'transactions_run_aggregated' else 'run_id') + ') r', (run,))
                    c.itersize = 1000
                    for (raw,) in c:
                        row = json.loads(raw)
                        if table == 'requests_aggregated_1s':
                            if not bounds: bounds[:] = [row['time'], row['time'] + 1000000]
                            else: bounds[:] = [min(bounds[0], row['time']), max(bounds[1], row['time'] + 1000000)]
                        if table in ('requests_run_aggregated', 'transactions_run_aggregated'):
                            n, errors = expected.setdefault(table, [0, 0])
                            expected[table] = [n + (row.get('count') or 0), errors + (row.get('failed_count') or 0)]
                        line = ('{"table":' + json.dumps(table) + ',"row":' + raw + '}\n').encode()
                        out.write(line); digest.update(line); count += 1
            tables[table] = {'rows': count, 'present': bool(exists)}
    # Nothing to copy: an empty bundle must not be recorded as a verified migration.
    if not any(t['rows'] for t in tables.values()) and not any(s['rows'] for s in stats.values()):
        payload.unlink()
        raise EmptySource('Source has no result rows for this test')
    request_count, error_count = expected.get('requests_run_aggregated', [test.get('total_requests'), test.get('total_errors')])
    transaction_count = expected.get('transactions_run_aggregated', [None])[0]
    raw = {name: availability(s['rows'], {'requests_raw': request_count, 'requests_error': error_count, 'transactions': transaction_count}.get(name), strict=name == 'requests_raw') for name, s in stats.items()}
    for s in stats.values():
        if s['rows']:
            if not bounds: bounds[:] = [s['min_us'], s['max_us'] + 1]
            else: bounds[:] = [min(bounds[0], s['min_us']), max(bounds[1], s['max_us'] + 1)]
    # A summary-only run still has an honest test interval, without inventing raw rows.
    if not bounds:
        for key in ('startTime', 'endTime'):
            value = test.get(key)
            if isinstance(value, str):
                try: value = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
                except ValueError: value = parsedate_to_datetime(value)
            if not isinstance(value, dt.datetime): raise ValueError('Summary-only migration requires test timestamps')
            if value.tzinfo is None: value = value.replace(tzinfo=dt.timezone.utc)
            bounds.append(int((value - EPOCH).total_seconds() * 1000000))
        bounds[1] += 1
    if bounds[0] < 0 or bounds[1] <= bounds[0]: raise ValueError('Invalid retained source bounds')
    header = {'format': 'breaktest-retained-timescaledb-v1', 'run_id': run, 'origin_us': bounds[0] // 1000000 * 1000000,
              'end_us': bounds[1], 'tables': tables, 'raw': raw, 'expected_requests': request_count,
              'expected_errors': error_count, 'rows_sha256': digest.hexdigest()}
    path = Path(work) / NAME
    compress = (lambda b: zstd.compress(b, level=3)) if hasattr(zstd, 'CompressionParameter') else zstd.ZstdCompressor(level=3).compress
    with path.open('wb') as target:
        target.write(compress((json.dumps(header, separators=(',', ':')) + '\n').encode()))
        with payload.open('rb') as source:
            while chunk := source.read(1024 * 1024): target.write(compress(chunk))
    payload.unlink()
    return header
