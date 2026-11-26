"""Resolve deployment settings without exposing credentials in shell arguments/logs."""
import argparse
from contextlib import closing
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import quote

import psycopg2.extensions
from bson import ObjectId
from pymongo import MongoClient
import copy_customer
from copy_customer import failure_message


def inspect(container):
    return json.loads(subprocess.check_output(['docker', 'inspect', container], text=True))[0]


def environment(container):
    return dict(item.split('=', 1) for item in container['Config']['Env'] if '=' in item)


def mongo_uri(env):
    if env.get('RUST_API_MONGO_URI'):
        return env['RUST_API_MONGO_URI']
    return 'mongodb://{}:{}@mongodb:27017/?authSource=admin'.format(
        quote(env['MONGO_INITDB_ROOT_USERNAME'], safe=''),
        quote(env['MONGO_INITDB_ROOT_PASSWORD'], safe=''))


def source_dsn(config, env, *, writable=False):
    # Same customer/admin connection precedence as application backup/export.
    def setting(key, variable, default=''):
        return config.get(key) or env.get(variable) or default
    return psycopg2.extensions.make_dsn(
        host=setting('host', 'POSTGRES_HOST', 'timescaledb'),
        port=setting('port', 'POSTGRES_PORT', '5432'),
        user=setting('admin_user', 'POSTGRES_USER'),
        password=setting('admin_password', 'POSTGRES_PASSWORD'),
        dbname=config['database'],
        sslmode=env.get('PG_SSLMODE', 'prefer'),
        connect_timeout=10,
        options='-c default_transaction_read_only=off' if writable else '-c default_transaction_read_only=on')


def validate_data_mount(store, env):
    mounts = [m for m in store['Mounts'] if m['Destination'] == '/data' and m['RW']]
    if len(mounts) != 1:
        raise ValueError('Storage must have a writable /data mount')
    configured = env.get('BREAKTEST_DB_DATA_PATH')
    if configured and (mounts[0]['Type'] != 'bind' or
                       os.path.normpath(mounts[0]['Source']) != os.path.normpath(configured)):
        raise ValueError('Storage mount does not match BREAKTEST_DB_DATA_PATH; recreate the deployment first')


def check_monitoring_drained(db, customer, dsn):
    monitors = {'customer_id': {'$in': [customer, ObjectId(customer)]}, 'is_synthetic_monitoring': True}
    if db.scenarios.find_one({**monitors, 'enabled': True}, {'_id': 1}):
        raise ValueError('Pause monitoring schedules and drain active producers before activating')
    lifetimes = {str(m['_id']): m.get('duration') for m in db.scenarios.find(monitors, {'duration': 1})}
    with closing(psycopg2.connect(dsn)) as pg, pg.cursor() as cur:
        cur.execute("SELECT to_regclass('public.sm_runs') IS NOT NULL")
        if cur.fetchone()[0]:
            cur.execute("SELECT scenario_id,max(start_time),now() FROM sm_runs WHERE end_time IS NULL GROUP BY scenario_id")
            for sid, last, now in cur:
                duration = lifetimes.get(sid)
                lifetime = duration if isinstance(duration, int) and duration > 0 else 86400
                if (now-last).total_seconds() <= lifetime+14400:
                    raise ValueError('Wait for unfinished monitoring producers before activating')


def copy_synthetic(a, runtime, db, dsn, token):
    import copy_monitoring
    customer = a.customer
    record = db.customers.find_one({'_id': ObjectId(customer)}, {'syntheticMonitoringStorageBackend': 1})
    if not record:
        raise ValueError('Unknown customer')
    selected = record.get('syntheticMonitoringStorageBackend') == 'breaktest-db'
    if a.command == 'update-sm' and not selected and not db.results_storage_migrations.find_one(
        {'customer_id': customer, 'state': 'verified'}, {'_id': 1}
    ):
        raise ValueError('Use copy for a first customer migration; update-sm adds monitoring after a verified load-test migration')
    print(f'{customer}: checking Synthetic Monitoring', flush=True)
    with copy_monitoring.storage_tools(runtime.store_container, a.work_dir):
        if selected:
            copy_monitoring.check_selected(a.main_root, customer, dsn, a.reverify_existing)
            print(f'{customer}: Synthetic Monitoring already uses the verified native dataset', flush=True)
            return
        if a.activate:
            check_monitoring_drained(db, customer, dsn)
        copy_monitoring.copy(dsn, customer, a.main_root, a.target_owner)
    print(f'{customer}: Synthetic Monitoring copy verified', flush=True)
    if a.activate:
        info = copy_customer.post(a.main_url, f'/monitoring/{customer}/initialize', {}, token)
        cutoff = info.get('cutoff')
        if cutoff and datetime.fromisoformat(cutoff) > datetime.now(timezone.utc):
            raise ValueError(f'The last imported UTC hour closes at {cutoff}; keep monitors paused until activation')
        check_monitoring_drained(db, customer, dsn)
        db.customers.update_one({'_id': ObjectId(customer)}, {'$set': {'syntheticMonitoringStorageBackend': 'breaktest-db'}})
        print(f'{customer}: Synthetic Monitoring reads and new executions now use BreakTest DB', flush=True)


def migrate_customer(a, runtime, db, dsn, token):
    if a.command == 'update-sm':
        return copy_synthetic(a, runtime, db, dsn, token)
    if a.command != 'copy' or a.test:
        return copy_customer.main(a)
    try:
        copy_customer.main(a)
    except Exception as load_error:
        if not a.continue_on_error:
            raise
        print(f'{a.customer}: load-test phase failed; proceeding with monitoring', file=sys.stderr, flush=True)
        try:
            copy_synthetic(a, runtime, db, dsn, token)
        except Exception as sm_error:
            raise ValueError(f'Load tests: {failure_message(load_error)}. Monitoring: {failure_message(sm_error)}') from None
        raise
    copy_synthetic(a, runtime, db, dsn, token)


def run(argv=None):
    outer = argparse.ArgumentParser(add_help=False)
    outer.add_argument('--backend-container', required=True)
    outer.add_argument('--store-container')
    outer.add_argument('--work-root', type=Path, required=True)
    runtime, args = outer.parse_known_args(argv)
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('command', choices=['plan', 'copy', 'switch', 'compact-jvm', 'update-sm'])
    cli.add_argument('--customer', required=True, action='append', help='Customer ID or all for copy')
    cli.add_argument('--test', action='append')
    cli.add_argument('--backend', choices=['timescaledb', 'breaktest-db'])
    cli.add_argument('--continue-on-error', action='store_true')
    cli.add_argument('--reverify-existing', action='store_true')
    cli.add_argument('--copy-legacy-monitoring', action='store_true')
    cli.add_argument('--all', action='store_true', dest='everything',
                     help='Copy everything a customer has: every finalized test with its generator monitoring, '
                          'converting shared samples where a test has none of its own, then Synthetic Monitoring')
    cli.add_argument('--activate', action='store_true', help='Select the verified Synthetic Monitoring snapshot for reads and new writes')
    a = cli.parse_args(args)
    if a.command == 'update-sm' and a.test:
        cli.error('update-sm operates on all monitoring data for the customer')
    if a.activate and (a.command not in ('copy', 'update-sm') or a.test):
        cli.error('--activate selects monitoring storage and requires a whole-customer copy or update-sm')
    all_customers = 'all' in a.customer
    if all_customers and (a.customer != ['all'] or a.command != 'copy' or a.test):
        cli.error('--customer all requires copy without other customer IDs or --test')
    if not all_customers and any(not ObjectId.is_valid(value) for value in a.customer):
        cli.error('--customer expects a 24-character customer ID or all for copy')
    customers = [] if all_customers else list(dict.fromkeys(str(ObjectId(value)) for value in a.customer))
    if len(customers) > 1 and (a.command != 'copy' or a.test):
        cli.error('Multiple customers require copy without --test')
    if a.everything:
        if a.command != 'copy' or a.test:
            cli.error('--all copies a whole customer and requires copy without --test')
        # One test that cannot be copied must not keep the rest of the customer behind.
        a.copy_legacy_monitoring = a.continue_on_error = True
    if a.command != 'copy' and (a.continue_on_error or a.reverify_existing or a.copy_legacy_monitoring):
        cli.error('Copy options require the copy command')
    batch = all_customers or len(customers) > 1
    a.continue_on_error = a.continue_on_error or batch
    if a.backend and a.command != 'switch':
        cli.error('--backend only applies to switch')
    if a.command == 'switch' and not a.backend:
        cli.error('switch requires --backend')
    if runtime.work_root.stat().st_mode & 0o077:
        raise ValueError('Work directory must be private (chmod 700)')
    backend = inspect(runtime.backend_container)
    env = environment(backend)
    os.environ.update(MIGRATION_MONGO_URI=mongo_uri(env),
                      MIGRATION_MONGO_DB=env.get('MONGO_DATABASE', 'breakingit'))
    if a.command != 'compact-jvm':
        if not runtime.store_container:
            cli.error('this command requires --store-container')
        store = inspect(runtime.store_container)
        if not all(c['State']['Running'] for c in (backend, store)):
            raise ValueError('Backend and BreakTest DB must be running')
        store_env = environment(store)
        networks = set(backend['NetworkSettings']['Networks']) & set(store['NetworkSettings']['Networks'])
        if len(networks) != 1:
            raise ValueError('Expected one shared backend/storage Docker network')
        validate_data_mount(store, env)
        token = store_env.get('BREAKTEST_DB_ADMIN_TOKEN')
        if not token or token != env.get('BREAKTEST_DB_ADMIN_TOKEN'):
            raise ValueError('Backend/storage credentials differ or are missing; reconcile the deployment first')
        # The target owner can differ from the root user running this helper.
        owner = subprocess.check_output(['docker', 'exec', runtime.store_container,
                                        'stat', '-c', '%u:%g', '/data'], text=True).strip()
        a.target_owner = tuple(int(x) for x in owner.split(':'))
        a.main_root = Path('/data')
        a.main_url = 'http://' + store['NetworkSettings']['Networks'][next(iter(networks))]['IPAddress'] + ':8099'
        a.image = store['Image']  # Exact running digest, even if a tag has moved.
        a.work_dir = runtime.work_root
        a.enable_customer_selection = True
        os.environ.update(BREAKTEST_DB_ADMIN_TOKEN=token, MIGRATION_DOCKER_NETWORK=next(iter(networks)))
    if a.command == 'copy':
        # Shared monitoring belongs to the installation.
        os.environ['MIGRATION_MONITORING_PG_DSN'] = source_dsn({'database': 'breaktest_monitoring'}, env)
    with (runtime.work_root / '.migration.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another migration is running with this work directory') from None
        if all_customers:
            with MongoClient(os.environ['MIGRATION_MONGO_URI'], serverSelectionTimeoutMS=10000) as client:
                db = client[os.environ['MIGRATION_MONGO_DB']]
                configured = [ObjectId(cid) for cid in db.timescaledb.distinct('customer_id') if ObjectId.is_valid(cid)]
                customers = [str(doc['_id']) for doc in db.customers.find({'_id': {'$in': configured}}, {'_id': 1}).sort('_id', 1)]
            print(f'Found {len(customers)} customers with TimescaleDB configured', flush=True)
        failed = []
        for customer in customers:
            a.customer = customer
            if batch:
                print(f'Copying customer {customer}', flush=True)
            try:
                if a.command in ('copy', 'compact-jvm', 'update-sm'):
                    with MongoClient(os.environ['MIGRATION_MONGO_URI'], serverSelectionTimeoutMS=10000) as client:
                        db = client[os.environ['MIGRATION_MONGO_DB']]
                        configs = list(db.timescaledb.find({'customer_id': customer}))
                        if len(configs) != 1:
                            raise ValueError('Customer must have exactly one TimescaleDB configuration')
                        dsn = source_dsn(configs[0], env, writable=a.command == 'compact-jvm')
                        os.environ['MIGRATION_PG_DSN'] = dsn
                        migrate_customer(a, runtime, db, dsn, env.get('BREAKTEST_DB_ADMIN_TOKEN'))
                else:
                    copy_customer.main(a)
            except Exception as exc:
                if not batch:
                    raise
                failed.append(customer)
                print(f'{customer}: {failure_message(exc)}', file=sys.stderr, flush=True)
        if failed:
            raise ValueError(f'Copy failed for {len(failed)} of {len(customers)} customers')


if __name__ == '__main__':
    try:
        run()
    except Exception as exc:
        # No raw driver exception/traceback in logs: connection errors may contain DSNs.
        print(f'Migration failed: {failure_message(exc)}.',
              file=sys.stderr)
        sys.exit(1)
