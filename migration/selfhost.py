"""Resolve deployment settings without exposing credentials in shell arguments/logs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
from urllib.parse import quote

import psycopg2.extensions
from bson import ObjectId
from pymongo import MongoClient
import copy_customer


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


def source_dsn(config, env):
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
        options='-c default_transaction_read_only=on')


def validate_data_mount(store, env):
    mounts = [m for m in store['Mounts'] if m['Destination'] == '/data' and m['RW']]
    if len(mounts) != 1:
        raise ValueError('Storage must have a writable /data mount')
    configured = env.get('BREAKTEST_DB_DATA_PATH')
    if configured and (mounts[0]['Type'] != 'bind' or
                       os.path.normpath(mounts[0]['Source']) != os.path.normpath(configured)):
        raise ValueError('Storage mount does not match BREAKTEST_DB_DATA_PATH; recreate the deployment first')


def run(argv=None):
    outer = argparse.ArgumentParser(add_help=False)
    outer.add_argument('--backend-container', required=True)
    outer.add_argument('--store-container', required=True)
    outer.add_argument('--work-root', type=Path, required=True)
    runtime, args = outer.parse_known_args(argv)
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('command', choices=['plan', 'copy', 'switch'])
    cli.add_argument('--customer', required=True)
    cli.add_argument('--test', action='append')
    cli.add_argument('--backend', choices=['timescaledb', 'breaktest-db'])
    a = cli.parse_args(args)
    if a.command == 'switch' and not a.backend:
        cli.error('switch requires --backend')
    if runtime.work_root.stat().st_mode & 0o077:
        raise ValueError('Work directory must be private (chmod 700)')
    backend, store = inspect(runtime.backend_container), inspect(runtime.store_container)
    if not all(c['State']['Running'] for c in (backend, store)):
        raise ValueError('Backend and BreakTest DB must be running')
    env, store_env = environment(backend), environment(store)
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
    os.environ.update(MIGRATION_MONGO_URI=mongo_uri(env),
                      MIGRATION_MONGO_DB=env.get('MONGO_DATABASE', 'breakingit'),
                      BREAKTEST_DB_ADMIN_TOKEN=token,
                      MIGRATION_DOCKER_NETWORK=next(iter(networks)))
    if a.command == 'copy':
        with MongoClient(os.environ['MIGRATION_MONGO_URI'], serverSelectionTimeoutMS=10000) as client:
            db = client[os.environ['MIGRATION_MONGO_DB']]
            configs = list(db.timescaledb.find({'customer_id': str(ObjectId(a.customer))}))
            if len(configs) != 1:
                raise ValueError('Customer must have exactly one TimescaleDB configuration')
            os.environ['MIGRATION_PG_DSN'] = source_dsn(configs[0], env)
            # Shared monitoring belongs to the installation, not an external customer DB.
            os.environ['MIGRATION_MONITORING_PG_DSN'] = source_dsn({'database': 'breaktest_monitoring'}, env)
    with (runtime.work_root / '.migration.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another migration is running with this work directory') from None
        copy_customer.main(a)


def failure_message(exc):
    """Operator-facing reason without anything that may embed credentials.

    The tool's own ValueError/FileExistsError messages are fixed text plus IDs,
    table names and paths. Driver/connection errors may contain DSNs or URIs,
    so only their type is shown.
    """
    if isinstance(exc, (ValueError, FileExistsError)):
        return f'{type(exc).__name__}: {exc}'
    if isinstance(exc, urllib.error.HTTPError):
        return f'BreakTest DB returned HTTP {exc.code}'
    return f'{type(exc).__name__}; check connectivity to MongoDB, PostgreSQL and BreakTest DB'


if __name__ == '__main__':
    try:
        run()
    except Exception as exc:
        # No raw driver exception/traceback in logs: connection errors may contain DSNs.
        print(f'Migration failed: {failure_message(exc)}. Source data and customer default were not changed.',
              file=sys.stderr)
        sys.exit(1)
