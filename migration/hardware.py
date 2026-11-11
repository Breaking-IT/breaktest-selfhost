"""Canonical hardware summary, shared by SQL reads and portable snapshots."""
import json

def _parse_numeric_value(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip().replace(',', '.'))
    except (TypeError, ValueError):
        return None


def _parse_memory_mb(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)

    text = str(value).strip().lower().replace(',', '.')
    if not text:
        return None

    multiplier = 1.0
    for suffix, suffix_multiplier in (
        ('gib', 1024.0),
        ('gb', 1024.0),
        ('g', 1024.0),
        ('mib', 1.0),
        ('mb', 1.0),
        ('m', 1.0),
    ):
        if text.endswith(suffix):
            text = text[:-len(suffix)].strip()
            multiplier = suffix_multiplier
            break

    parsed = _parse_numeric_value(text)
    return parsed * multiplier if parsed is not None else None


def _ephemeral_group_resource_specs(test):
    metadata = test.get('testOnlyLoadGenerators') or {}
    requested_groups = metadata.get('requested') or []
    if not isinstance(requested_groups, list):
        return {}

    test_id = str(test.get('_id') or '')
    specs_by_group_id = {}
    for index, group in enumerate(requested_groups, start=1):
        if not isinstance(group, dict):
            continue

        group_id = group.get('id') or f'{test_id}-group-{index}'
        if not group_id:
            continue

        cpu_count = _parse_numeric_value(group.get('cpu'))
        memory_total_mb = _parse_memory_mb(group.get('memory'))

        specs = {}
        if cpu_count is not None:
            specs['cpu_count'] = cpu_count
        if memory_total_mb is not None:
            specs['memory_total_mb'] = memory_total_mb

        if specs:
            specs_by_group_id[str(group_id)] = specs

    return specs_by_group_id


def _latest_specs(test, instance_ids, pg_conn):
    """Each generator's latest CPU count and memory size, as {instance_id: (cpu, mb)}.

    BreakTest DB tests read their own run-scoped generator metrics, so finishing
    or showing them never depends on the shared TimescaleDB monitoring store.
    """
    if test.get('resultsStorageBackend', 'timescaledb') != 'timescaledb':
        raise ValueError('Migration hardware snapshot requires a TimescaleDB source')
    instance_id_list = list(instance_ids)
    placeholders = ','.join(['%s'] * len(instance_id_list))
    with pg_conn('breaktest_monitoring') as monitoring_conn:
        monitoring_cur = monitoring_conn.cursor()
        monitoring_cur.execute(f'\n                    SELECT DISTINCT ON (instance_id)\n                        instance_id,\n                        cpu_count,\n                        memory_total_mb\n                    FROM system_metrics\n                    WHERE instance_id IN ({placeholders})\n                          AND cpu_count IS NOT NULL\n                          AND memory_total_mb IS NOT NULL\n                    ORDER BY instance_id, time DESC\n                ', instance_id_list)
        return {row[0]: (row[1], row[2]) for row in monitoring_cur.fetchall()}


def generator_hardware_statistics(test, db, pg_conn):
    load_generators = test.get('loadGenerators', [])
    if not load_generators:
        return {'by_location': {}, 'totals': {'count': 0, 'total_cpu': 0, 'total_memory_gb': 0}, 'has_location_data': False}
    location_stats = {}
    all_instance_ids = set()
    generator_name_to_location = {}
    group_resource_specs = _ephemeral_group_resource_specs(test)
    instance_resource_specs = {}
    for lg in load_generators:
        generator_name = None
        location = None
        ephemeral_group_id = None
        if isinstance(lg, dict):
            generator_name = lg.get('generator_name')
            location = lg.get('location')
            ephemeral_group_id = lg.get('ephemeral_group_id')
            if not location or (isinstance(location, str) and (not location.strip() or location.strip() == 'Unknown')):
                full_lg = db.loadgenerators.find_one({'$or': [{'generator_name': generator_name}, {'ip': lg.get('ip') or generator_name}]})
                if full_lg:
                    generator_type = full_lg.get('generator_type', 'manual')
                    if generator_type in ['local', 'manual']:
                        location = full_lg.get('generator_location')
                    else:
                        location = full_lg.get('generator_location')
                        if not location:
                            location = full_lg.get('region_name')
                        if not location:
                            generator_config_str = full_lg.get('generator_config')
                            if generator_config_str:
                                try:
                                    if isinstance(generator_config_str, str):
                                        generator_config = json.loads(generator_config_str)
                                    else:
                                        generator_config = generator_config_str
                                    if generator_config:
                                        location = generator_config.get('region_name')
                                        if not location:
                                            location = generator_config.get('region_id')
                                except (json.JSONDecodeError, AttributeError):
                                    pass
                if not location or (isinstance(location, str) and (not location.strip())):
                    location = 'Unknown'
        elif isinstance(lg, str):
            generator_name = lg
            full_lg = db.loadgenerators.find_one({'$or': [{'generator_name': generator_name}, {'ip': generator_name}]})
            if full_lg:
                generator_type = full_lg.get('generator_type', 'manual')
                if generator_type in ['local', 'manual']:
                    location = full_lg.get('generator_location')
                else:
                    location = full_lg.get('generator_location')
                    if not location:
                        location = full_lg.get('region_name')
                    if not location:
                        generator_config_str = full_lg.get('generator_config')
                        if generator_config_str:
                            try:
                                if isinstance(generator_config_str, str):
                                    generator_config = json.loads(generator_config_str)
                                else:
                                    generator_config = generator_config_str
                                if generator_config:
                                    location = generator_config.get('region_name')
                                    if not location:
                                        location = generator_config.get('region_id')
                            except (json.JSONDecodeError, AttributeError):
                                pass
            if not location or (isinstance(location, str) and (not location.strip())):
                location = 'Unknown'
        else:
            continue
        if generator_name:
            generator_name_to_location[generator_name] = location
            all_instance_ids.add(generator_name)
            if ephemeral_group_id and str(ephemeral_group_id) in group_resource_specs:
                instance_resource_specs[generator_name] = group_resource_specs[str(ephemeral_group_id)]
            if location not in location_stats:
                location_stats[location] = {'count': 0, 'total_cpu': 0, 'total_memory_mb': 0, 'instance_ids': set()}
            location_stats[location]['instance_ids'].add(generator_name)
    if all_instance_ids:
        latest = _latest_specs(test, all_instance_ids, pg_conn)
        for instance_id, (cpu_count, memory_total_mb) in latest.items():
            resource_specs = instance_resource_specs.pop(instance_id, {})
            cpu_count = resource_specs.get('cpu_count', cpu_count)
            memory_total_mb = resource_specs.get('memory_total_mb', memory_total_mb)
            location = generator_name_to_location.get(instance_id, 'Unknown')
            if location in location_stats:
                if cpu_count:
                    location_stats[location]['total_cpu'] += cpu_count
                if memory_total_mb:
                    location_stats[location]['total_memory_mb'] += memory_total_mb
        for instance_id, resource_specs in instance_resource_specs.items():
            location = generator_name_to_location.get(instance_id, 'Unknown')
            if location in location_stats:
                cpu_count = resource_specs.get('cpu_count')
                memory_total_mb = resource_specs.get('memory_total_mb')
                if cpu_count:
                    location_stats[location]['total_cpu'] += cpu_count
                if memory_total_mb:
                    location_stats[location]['total_memory_mb'] += memory_total_mb
    by_location = {}
    total_count = 0
    total_cpu = 0
    total_memory_mb = 0
    for location, stats in location_stats.items():
        location_count = len(stats['instance_ids'])
        total_count += location_count
        total_cpu += stats['total_cpu']
        total_memory_mb += stats['total_memory_mb']
        by_location[location] = {'count': location_count, 'total_cpu': stats['total_cpu'], 'total_memory_gb': round(stats['total_memory_mb'] / 1024, 1) if stats['total_memory_mb'] else 0}
    has_location_data = any((loc != 'Unknown' for loc in by_location.keys()))
    return {'by_location': by_location, 'totals': {'count': total_count, 'total_cpu': total_cpu, 'total_memory_gb': round(total_memory_mb / 1024, 1) if total_memory_mb else 0}, 'has_location_data': has_location_data}

PLACEHOLDER_IP_VALUES = {"", "-", "n/a", "none", "null", "pending", "unknown"}
def _has_usable_load_generator_ip(value):
    return value is not None and str(value).strip().lower() not in PLACEHOLDER_IP_VALUES


def _short_load_generator_suffix(value):
    value = str(value or '').strip()
    if not value:
        return 'unknown'
    return value if len(value) <= 12 else value[-8:]


def _load_generator_entries_with_display_names(entries):
    preferred_names = []
    for entry in entries or []:
        ip = entry.get('ip')
        preferred_names.append(
            str(ip).strip() if _has_usable_load_generator_ip(ip)
            else str(entry.get('generator_name') or entry.get('instance_id') or 'Unknown')
        )

    preferred_counts = {}
    for name in preferred_names:
        preferred_counts[name] = preferred_counts.get(name, 0) + 1

    used_names = set()
    result = []
    for entry, preferred_name in zip(entries or [], preferred_names):
        display_name = preferred_name
        if preferred_counts.get(preferred_name, 0) > 1:
            suffix = _short_load_generator_suffix(entry.get('generator_name') or entry.get('instance_id'))
            display_name = f"{preferred_name} ({suffix})"

        base_display_name = display_name
        index = 2
        while display_name in used_names:
            display_name = f"{base_display_name} #{index}"
            index += 1

        used_names.add(display_name)
        result.append({**entry, 'display_name': display_name})

    return result



def generator_metrics_context(test, db):
    instance_ids = set()
    instance_id_to_display = {}
    display_name_to_instance_id = {}
    instance_metadata = {}
    pending_instance_entries = []
    group_resource_specs = _ephemeral_group_resource_specs(test)
    instance_resource_specs = {}
    load_generators = test.get('loadGenerators', [])
    if load_generators:
        for lg in load_generators:
            if isinstance(lg, str):
                identifier = lg
                generator_name = identifier
                stored_location = None
                stored_ip = None
                generator_type = None
                ephemeral_group_id = None
            elif isinstance(lg, dict):
                generator_name = lg.get('generator_name')
                stored_location = lg.get('location')
                stored_ip = lg.get('ip')
                generator_type = lg.get('generator_type')
                ephemeral_group_id = lg.get('ephemeral_group_id')
                identifier = generator_name or lg.get('ip')
            else:
                continue

            if not identifier or not generator_name:
                continue

            instance_id = generator_name

            full_lg = None
            generator_config = None

            needs_lookup = (
                not stored_location or
                not _has_usable_load_generator_ip(stored_ip) or
                generator_type is None or
                (generator_type and generator_type not in ['local', 'manual'])
            )

            if needs_lookup:
                full_lg = db.loadgenerators.find_one({
                    '$or': [
                        {'generator_name': generator_name},
                        {'ip': identifier}
                    ]
                })
                if full_lg:
                    if generator_type is None:
                        generator_type = full_lg.get('generator_type', 'manual')

                    generator_config_str = full_lg.get('generator_config')
                    if generator_config_str:
                        try:
                            if isinstance(generator_config_str, str):
                                generator_config = json.loads(generator_config_str)
                            else:
                                generator_config = generator_config_str
                        except (json.JSONDecodeError, AttributeError):
                            generator_config = None

                    if generator_type and generator_type not in ['local', 'manual']:
                        if generator_config and generator_config.get('instance_id'):
                            instance_id = generator_config.get('instance_id')

            location = stored_location
            if not location:
                if not full_lg:
                    full_lg = db.loadgenerators.find_one({
                        '$or': [
                            {'generator_name': generator_name},
                            {'ip': identifier}
                        ]
                    })

                if full_lg:
                    generator_type = generator_type or full_lg.get('generator_type', 'manual')
                    if generator_type in ['local', 'manual']:
                        location = full_lg.get('generator_location')
                    else:
                        location = full_lg.get('generator_location')
                        if not location:
                            location = full_lg.get('region_name')
                        if not location and generator_config:
                            location = generator_config.get('region_name')
                        if not location and generator_config:
                            region_id = generator_config.get('region_id')
                            if region_id:
                                location = region_id

                if not location or (isinstance(location, str) and not location.strip()):
                    location = 'Unknown'

            ip = stored_ip if _has_usable_load_generator_ip(stored_ip) else None
            if not ip and full_lg and _has_usable_load_generator_ip(full_lg.get('ip')):
                ip = full_lg.get('ip')
            if not ip:
                ip = '-'

            if instance_id:
                pending_instance_entries.append({
                    'ip': ip,
                    'instance_id': instance_id,
                    'location': location,
                    'generator_name': generator_name,
                    'ephemeral_group_id': ephemeral_group_id
                })

    for entry in _load_generator_entries_with_display_names(pending_instance_entries):
        instance_id = entry.get('instance_id')
        display_name = entry.get('display_name')
        if not instance_id or not display_name or instance_id in instance_ids:
            continue

        instance_ids.add(instance_id)
        instance_id_to_display[instance_id] = display_name
        display_name_to_instance_id[display_name] = instance_id

        group_id = entry.get('ephemeral_group_id')
        if group_id and str(group_id) in group_resource_specs:
            instance_resource_specs[instance_id] = group_resource_specs[str(group_id)]

        instance_metadata[instance_id] = {
            'ip': entry.get('ip') or '-',
            'instance_id': instance_id,
            'location': entry.get('location') or 'Unknown',
            'generator_name': entry.get('generator_name')
        }

    from bson import ObjectId
    customer = db.customers.find_one({'_id': ObjectId(str(test['customer_id']))}) or {}
    interval = test.get('runMetricsIntervalSeconds') or customer.get('runMetricsIntervalSeconds') or 1
    return dict(instance_metadata=instance_metadata, instance_id_to_display=instance_id_to_display,
                display_name_to_instance_id=display_name_to_instance_id, instance_resource_specs=instance_resource_specs,
                interval_seconds=interval)


def generator_hardware_snapshot(test, db, pg_conn):
    return {**generator_hardware_statistics(test, db, pg_conn),
            'metrics_context': generator_metrics_context(test, db)}
