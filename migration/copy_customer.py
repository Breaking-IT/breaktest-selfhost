#!/usr/bin/env python3
"""Copy finalized TimescaleDB runs; separately and reversibly switch their reads.
Credentials: MIGRATION_MONGO_URI, MIGRATION_MONGO_DB, MIGRATION_PG_DSN,
BREAKTEST_DB_ADMIN_TOKEN. Copy uses a read-only source snapshot. compact-jvm writes to the selected TimescaleDB.
"""
import io
import argparse,shutil,collections,datetime as dt,gzip,hashlib,heapq,importlib.util,json,os,re,secrets,struct,subprocess,sys,time,urllib.request,urllib.error,uuid
from contextlib import closing, contextmanager
from pathlib import Path
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('migration_retained',ROOT/'retained.py')
retained=importlib.util.module_from_spec(spec);spec.loader.exec_module(retained)
spec=importlib.util.spec_from_file_location('migration_bundles',ROOT/'bundles.py')
bundles=importlib.util.module_from_spec(spec);spec.loader.exec_module(bundles)
publish,inventory=bundles.publish,bundles.inventory
spec=importlib.util.spec_from_file_location('migration_hardware',ROOT/'hardware.py')
hardware_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(hardware_module)
@contextmanager
def monitoring_connection(name):
    import psycopg2
    dsn = os.environ.get('MIGRATION_MONITORING_PG_DSN', os.environ['MIGRATION_PG_DSN'])
    with closing(psycopg2.connect(dsn, dbname=name, application_name='breaktest-copy-hardware')) as conn:
        conn.set_session(readonly=True, isolation_level='REPEATABLE READ')
        yield conn


def check_legacy_monitoring(conn, run, test, db, allow_copy=False):
    if not test.get('loadGenerators'):
        return
    with conn.cursor() as cur:
        cur.execute("SELECT EXISTS (SELECT 1 FROM load_generator_metrics WHERE run_id=%s AND source='agent')", (run,))
        if cur.fetchone()[0]:
            return
    generators = hardware_module.generator_metrics_context(test, db)['instance_metadata']
    ids = list(generators)
    if not ids:
        return
    start, end = test.get('startTime'), test.get('endTime')
    if start is None or end is None:
        raise ValueError('Test timestamps are required to check for legacy generator monitoring')
    # The TimescaleDB hardware chart falls back to these instance IDs during the test window.
    with monitoring_connection('breaktest_monitoring') as monitor, monitor.cursor() as cur:
        cur.execute("SET LOCAL TIME ZONE 'UTC'")
        cur.execute(
            """SELECT EXISTS (SELECT 1 FROM system_metrics
               WHERE instance_id=ANY(%s) AND time >= %s::timestamptz AND time <= %s::timestamptz)""",
            (ids, start, end),
        )
        if not cur.fetchone()[0]:
            return
    if not allow_copy:
        raise ValueError('Shared legacy generator monitoring requires explicit conversion before copy')
    names = [generators[i]['generator_name'] for i in ids]
    if len(names) != len(set(names)):
        raise ValueError('Ambiguous generator names in shared legacy monitoring')
    return (ids, names, [generators[i]['location'] for i in ids], start, end)


def export_legacy_monitoring(run, mapping, path, stats):
    if stats['rows']:
        raise ValueError('Cannot combine shared legacy monitoring with an existing run-scoped stream')
    ids, names, locations, start, end = mapping
    with monitoring_connection('breaktest_monitoring') as monitor, monitor.cursor() as cur:
        cur.execute("SET LOCAL TIME ZONE 'UTC'")
        query = cur.mogrify("""
            COPY (
                SELECT time, %s::text, mapping.generator_name, mapping.location, system_metrics.instance_id,
                       'agent'::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
                       cpu_percent::float8, load_1m::float8, cpu_count::float8,
                       memory_free_mb::float8, memory_total_mb::float8,
                       (memory_total_mb-memory_free_mb)::float8, (100-memory_free_percent)::float8,
                       bytes_in_per_sec::float8, bytes_out_per_sec::float8, (bytes_in_per_sec*8)::float8
                FROM public.system_metrics
                JOIN unnest(%s::text[], %s::text[], %s::text[]) AS mapping(instance_id, generator_name, location)
                  ON system_metrics.instance_id=mapping.instance_id
                WHERE time BETWEEN %s::timestamptz AND %s::timestamptz
                ORDER BY time
            ) TO STDOUT (FORMAT binary)
        """, (run, ids, names, locations, start, end)).decode()
        with gzip.open(path, 'wb', compresslevel=1) as compressed:
            with io.BufferedWriter(compressed) as output:
                spool = CopySpool(output, len(MONITOR))
                cur.copy_expert(query, spool)
                result = spool.stats()
    if not result['rows']:
        raise ValueError('Shared legacy monitoring disappeared during copy')
    print(f"{run}: copied {result['rows']:,} shared legacy generator samples", flush=True)
    return result


def hardware_snapshot(test, db):
    return hardware_module.generator_hardware_snapshot(test, db, monitoring_connection)
HEADER=b'PGCOPY\n\xff\r\n\0'+b'\0'*8
BOUNDARY='breaktest-copy-migration-v1'
ROUTING=('resultsStorageBackend','breaktestDb','breaktestDbCoverage')
SCHEMA=json.loads((ROOT/'wire-schema.json').read_text())['fixture_manifest']['tables']
SCHEMA.pop('jvm_samples')  # The compatibility view already exports these measurements.
MONITOR=['time','run_id','generator_name','location','node_name','source','container_id','container_name','container_image','app','status','cpu_percent','load_1m','cpu_count','memory_free_mb','memory_total_mb','memory_used_mb','memory_used_percent','network_bytes_in_per_sec','network_bytes_out_per_sec','network_bits_per_sec']
SCHEMA['load_generator_metrics']={'columns':[dict(column_name=n,data_type='timestamp with time zone' if i==0 else 'double precision' if i>=11 else 'text') for i,n in enumerate(MONITOR)]}

def save(p,data):
    tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(data,default=str,indent=2));tmp.replace(p)
def eligible(t):
    return (t.get('engine','breaktest') in ('breaktest','jmeter','k6') and t.get('status') in (None,'stopped','finished','completed') and t.get('endTime') is not None and t.get('max_vus') is not None and t.get('total_errors') is not None)
def copy_eligible(t):
    return eligible(t) and t.get('resultsStorageBackend','timescaledb') == 'timescaledb'
def skip_reason(t):
    """Why a TimescaleDB test is left out of a copy, and whether waiting could change that."""
    if t.get('status') not in (None, 'stopped', 'finished', 'completed') or t.get('endTime') is None:
        return 'not finalized', True
    if t.get('engine', 'breaktest') not in ('breaktest', 'jmeter', 'k6'):
        return 'unsupported engine', False
    return 'finalized without a stored summary', False
def routing(t):return {k:t[k] for k in ROUTING if k in t}
def guard(t):return {k:t[k] if k in t else {'$exists':False} for k in ('_id','customer_id','runId','status','endTime',*ROUTING)}
def fields(row):
    n=struct.unpack_from('!h',row)[0];pos=2;out=[]
    for _ in range(n):
        size=struct.unpack_from('!i',row,pos)[0];pos+=4;out.append(None if size==-1 else row[pos:pos+size]);pos+=max(size,0)
    if pos!=len(row):raise ValueError('Invalid row length')
    return out

def row_timestamp(row):
    if len(row)<14 or struct.unpack_from('!i',row,2)[0]!=8:raise ValueError('Invalid timestamp field')
    return struct.unpack_from('!q',row,6)[0]

# The private spool keeps the length that libpq supplies with each COPY OUT
# row. This avoids unpacking every field just to locate the next row on replay.
SPOOL_HEADER = b'BTROWS01'
MAX_COPY_ROW = 8 * 1024 * 1024

class CopySpool:
    def __init__(self, output, width):
        self.output = output
        self.width = width
        self.started = self.finished = False
        self.count = self.digest = 0
        self.first = self.last = None
        output.write(SPOOL_HEADER)

    def write(self, message):
        # psycopg2 passes a PostgreSQL CopyData message per write. The first
        # message also carries the binary header, including on an empty COPY.
        if self.finished:
            raise ValueError('Trailing COPY bytes')
        if not self.started:
            if not message.startswith(HEADER):
                raise ValueError('Unsupported binary COPY header')
            message = message[len(HEADER):]
            self.started = True
            if not message:
                return
        if message == b'\xff\xff':
            self.output.write(bytes(4))
            self.finished = True
            return
        if not 14 <= len(message) <= MAX_COPY_ROW or struct.unpack_from('!h', message)[0] != self.width:
            raise ValueError('Unexpected COPY row size or column count')
        timestamp = row_timestamp(message)
        if timestamp < 0 or (self.last is not None and timestamp < self.last):
            raise ValueError('Source COPY timestamps must be sorted and on or after 2000')
        if self.first is None:
            self.first = timestamp
        self.last = timestamp
        self.count += 1
        self.digest += int.from_bytes(hashlib.sha256(message).digest(), 'big')
        self.output.write(struct.pack('!I', len(message)))
        self.output.write(message)

    def stats(self):
        if not self.finished:
            raise ValueError('Truncated COPY payload')
        return dict(rows=self.count, sha256_multiset_sum=f'{self.digest % (1<<256):064x}',
                    min_us=self.first, max_us=self.last)


def spool_records(stream):
    """Read length-prefixed rows after the migration spool header."""
    while True:
        prefix = stream.read(4)
        if len(prefix) != 4:
            raise ValueError('Truncated migration spool')
        length = struct.unpack('!I', prefix)[0]
        if length == 0:
            if stream.read(1):
                raise ValueError('Trailing migration spool bytes')
            return
        if not 14 <= length <= MAX_COPY_ROW:
            raise ValueError('Invalid migration spool row length')
        row = stream.read(length)
        if len(row) != length:
            raise ValueError('Truncated migration spool row')
        yield row


def records(path):
    # Parse blocks rather than issuing a Python gzip read for every field.
    # Retain at most one bounded row plus a read block across boundaries.
    with gzip.open(path,'rb') as f:
        prefix = f.read(len(SPOOL_HEADER))
        if prefix == SPOOL_HEADER:
            yield from spool_records(f)
            return
        if prefix + f.read(len(HEADER) - len(prefix)) != HEADER:
            raise ValueError('Unsupported binary COPY header')
        buf=bytearray();pos=0
        def need(end):
            while len(buf)<end:
                data=f.read(max(1024*1024,end-len(buf)))
                if not data:raise ValueError('Truncated COPY payload')
                buf.extend(data)
        while True:
            need(pos+2);n=struct.unpack_from('!h',buf,pos)[0]
            if n==-1:
                if len(buf)!=pos+2 or f.read(1):raise ValueError('Trailing COPY bytes')
                return
            if n<1 or n>128:raise ValueError('Invalid column count')
            cursor=pos+2
            for _ in range(n):
                need(cursor+4);length=struct.unpack_from('!i',buf,cursor)[0];cursor+=4
                if length < -1 or length>8*1024*1024:raise ValueError('Row exceeds migration budget')
                cursor+=max(length,0)
                if cursor-pos>8*1024*1024:raise ValueError('Row exceeds migration budget')
                need(cursor)
            yield bytes(buf[pos:cursor]);pos=cursor
            if pos>=1024*1024:del buf[:pos];pos=0

def post(url,path,obj,token,headers=None):
    from urllib.parse import urlsplit
    parsed=urlsplit(url)
    if parsed.scheme not in ('http','https') or parsed.username or parsed.password or parsed.query or parsed.fragment:raise ValueError('Use an HTTP(S) service URL without embedded credentials/query')
    body=obj if isinstance(obj,bytes) else json.dumps(obj).encode()
    req=urllib.request.Request(url.rstrip('/')+path,data=body,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json',**(headers or {})})
    with urllib.request.urlopen(req,timeout=600) as r:return json.load(r)

class Staging:
    def __init__(self,image,work):
        self.work=work;self.name='bt-copy-migration-'+uuid.uuid4().hex;self.token=secrets.token_hex(32)
        (work/'storage').mkdir(mode=0o700)
        try:
            network=os.environ.get('MIGRATION_DOCKER_NETWORK')
            connection_args=['--network',network] if network else ['-p','127.0.0.1::8099']
            subprocess.run(['docker','run','-d','--name',self.name,'--label','com.breaktest.copy-migration=true','--cpus','2','--memory','1g','--memory-swap','1g','-e','BREAKTEST_DB_ADMIN_TOKEN','-v',str(work/'storage')+':/data',*connection_args,image,'serve','/data','0.0.0.0:8099'],env={**os.environ,'BREAKTEST_DB_ADMIN_TOKEN':self.token},check=True,stdout=subprocess.DEVNULL)
            if network:self.url='http://'+self.name+':8099'
            else:
                port=subprocess.check_output(['docker','port',self.name,'8099/tcp'],text=True).strip().rsplit(':',1)[1];self.url='http://127.0.0.1:'+port
            for _ in range(100):
                try:self.call('/health',{});return
                except OSError:time.sleep(.1)
            raise RuntimeError('Staging service unavailable')
        except BaseException:
            try:self.close()
            except Exception:pass
            raise
    def call(self,path,obj,token=None,headers=None):return post(self.url,path,obj,token or self.token,headers)
    def close(self):
        with (self.work/'service.log').open('w') as f:subprocess.run(['docker','logs',self.name],stdout=f,stderr=subprocess.STDOUT)
        subprocess.run(['docker','rm','-f',self.name],check=True,stdout=subprocess.DEVNULL)

def export(conn,run,work):
    from psycopg2 import sql
    stats={};paths={}
    with conn.cursor() as c:
        # Never silently drop browser data. Retained history is exported separately.
        c.execute("SELECT to_regclass('public.k6_browser_requests')")
        if c.fetchone()[0]:
            c.execute('SELECT 1 FROM public.k6_browser_requests WHERE run_id=%s LIMIT 1',(run,))
            if c.fetchone():raise ValueError('Cannot copy this run: public.k6_browser_requests contains legacy browser samples')
        c.execute("SELECT to_regclass('public.runtime_metrics_read'), to_regclass('public.jvm_samples')")
        runtime_view, jvm_samples = c.fetchone()
        if jvm_samples and not runtime_view:
            raise ValueError("Incomplete JVM schema: runtime_metrics_read is required to export jvm_samples")
        for table,schema in SCHEMA.items():
            relation = 'runtime_metrics_read' if table == 'runtime_metrics' and runtime_view else table
            c.execute('SELECT to_regclass(%s)',('public.'+relation,))
            if not c.fetchone()[0]:stats[table]={'rows':0,'sha256_multiset_sum':'0'*64};continue
            c.execute("SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name=%s",(relation,));actual=dict(c.fetchall())
            if any(actual.get(x['column_name'])!=x['data_type'] for x in schema['columns']):raise ValueError('Unsupported source schema: '+table)
            path=work/(table+'.rows.gz');paths[table]=path
            query=sql.SQL('COPY (SELECT {} FROM public.{} WHERE run_id={} ORDER BY time) TO STDOUT (FORMAT binary)').format(sql.SQL(',').join(sql.Identifier(x['column_name']) for x in schema['columns']),sql.Identifier(relation),sql.Literal(run))
            with gzip.open(path, 'wb', compresslevel=1) as compressed:
                with io.BufferedWriter(compressed, buffer_size=1024*1024) as output:
                    spool = CopySpool(output, len(schema['columns']))
                    c.copy_expert(query.as_string(conn), spool)
                    stats[table] = spool.stats()
    return paths,stats

MONITOR_WINDOW_ROWS=50_000  # Half the query limit: headroom for uneven row density.
def verify_monitor(call,run,stat):
    total=0;finger=0
    if stat['rows']:
        # The reader scans a whole window even after reaching the limit, so start
        # with about MONITOR_WINDOW_ROWS expected rows per equal-time window
        # instead of rescanning by halving from the full range. Sparse/legacy
        # ranges still need only a few queries; skewed windows split below.
        start,end=stat['min_us'],stat['max_us']+1
        parts=max(1,min(end-start,-(-stat['rows']//MONITOR_WINDOW_ROWS)))
        bounds=[start+(end-start)*i//parts for i in range(parts+1)]
        pending=[(bounds[i],bounds[i+1]) for i in reversed(range(parts))]
        while pending:
            start,end=pending.pop()
            try:
                data=call('/runs/'+run+'/query',dict(table='load_generator_metrics',start_us=start,end_us=end,limit=100000))
            except urllib.error.HTTPError as exc:
                # Defensive: the current reader only returns 413 for oversized
                # request bodies, but split rather than fail if that changes.
                if exc.code!=413:raise
                if end-start<=1:raise ValueError('Monitoring verification response exceeds indivisible time window') from exc
            else:
                if data['columns']!=MONITOR:raise ValueError('Unsafe monitoring verification columns')
                if len(data['rows'])<100000:
                    for values in data['rows']:
                        row=bytearray(struct.pack('!h',len(MONITOR)))
                        for i,v in enumerate(values):
                            raw=None if v is None else struct.pack('!q',v) if i==0 else struct.pack('!d',v) if i>=11 else v.encode()
                            row+=struct.pack('!i',-1) if raw is None else struct.pack('!i',len(raw))+raw
                        total+=1;finger=(finger+int.from_bytes(hashlib.sha256(row).digest(),'big'))%(1<<256)
                    continue
                if end-start<=1:raise ValueError('Monitoring verification response exceeds indivisible time window')
            # Discard possibly truncated responses; half-open windows count each row once.
            middle=(start+end)//2;pending.extend([(start,middle),(middle,end)])
    return dict(rows=total,sha256_multiset_sum=f'{finger:064x}')

def historical_block_seconds(stats, writer, reader):
    # Budget 8192 logical rows per five-minute block on average. The engine
    # still splits individual blocks if a burst reaches its byte budget.
    seconds = 300
    if any(seconds not in health.get('block_seconds_supported', ()) for health in (writer, reader)):
        return 10
    nonempty = [stat for stat in stats.values() if stat['rows']]
    if nonempty:
        duration_us = max(v['max_us'] for v in nonempty) - min(v['min_us'] for v in nonempty)
        if sum(v['rows'] for v in nonempty) * seconds * 1_000_000 <= 8192 * duration_us:
            return seconds
    return 10


def encode(service,run,customer,paths,stats,hardware=None,retained_header=None,reader_health=None):
    try:from compression import zstd
    except ImportError:import zstandard as zstd
    def compress(data):
        if hasattr(zstd,'CompressionParameter'):return zstd.compress(data,options={zstd.CompressionParameter.compression_level:1,zstd.CompressionParameter.window_log:18})
        return zstd.ZstdCompressor(compression_params=zstd.ZstdCompressionParameters.from_level(1,window_log=18)).compress(data)
    writer_health = service.call('/health', {})
    if retained_header and not writer_health.get('retained_timescaledb_v1'):
        raise ValueError('Upgrade the BreakTest DB image: retained-data migration requires bundle v3 support')
    origin=retained_header['origin_us'] if retained_header else min(v['min_us'] for v in stats.values() if v['rows'])//1_000_000*1_000_000;token=secrets.token_hex(32)
    reader = writer_health if reader_health is None else reader_health
    block_seconds = historical_block_seconds(stats, writer_health, reader)
    inc=service.call('/runs/create',dict(run_id=run,origin_us=origin,source_tokens=[token],block_seconds=block_seconds))['incarnation'];seq=0;pending=collections.defaultdict(list);size=0;second=None
    def flush():
        nonlocal seq,size
        if not pending:return
        parts=[]
        for table,rows in pending.items():
            if table=='load_generator_metrics':
                decoded=[]
                for row in rows:
                    values=fields(row);decoded.append([None if v is None else struct.unpack('!q',v)[0] if i==0 else struct.unpack('!d',v)[0] if i>=11 else v.decode() for i,v in enumerate(values)])
                # No retry on ambiguous monitoring ACK; abort private staging instead.
                for i in range(0,len(decoded),1000):service.call('/runs/'+run+'/monitoring',{'rows':decoded[i:i+1000]})
            else:parts.append(b'--'+BOUNDARY.encode()+b'\r\nX-Table: public.'+table.encode()+b'\r\nX-Format: binary\r\n\r\n'+HEADER+b''.join(rows)+b'\xff\xff\r\n')
        if parts:
            body=compress(b''.join(parts)+b'--'+BOUNDARY.encode()+b'--\r\n');seq+=1
            if len(body)>8*1024*1024:raise ValueError('Compressed batch exceeds receiver budget')
            h={'X-Incarnation':inc,'X-Sequence':str(seq),'Content-Type':'multipart/mixed; boundary='+BOUNDARY,'Content-Encoding':'zstd'}
            response=service.call('/runs/'+run+'/ingest/batch',body,token,h)
            if response['accepted']!=seq:raise ValueError('Unexpected ingestion acknowledgement')
        pending.clear();size=0
    def stream(table,path):
        for row in records(path):yield row_timestamp(row),table,row
    total_rows = sum(stat['rows'] for stat in stats.values())
    processed = 0
    next_report = time.monotonic() + 10
    # A watermark covers acknowledged data from complete seconds. Bound replay
    # by bytes for dense runs and elapsed time for sparse runs. A dense second
    # can span several transport batches without closing that second early.
    batch_bytes = 1024 * 1024
    window_start = None
    window_bytes = 0
    for timestamp,table,row in heapq.merge(*(stream(t,p) for t,p in paths.items())):
        sec = timestamp // 1_000_000
        if second is not None and sec != second and (window_bytes >= batch_bytes or sec - window_start >= 600):
            flush()
            service.call('/runs/'+run+'/watermark', {'before_us': (second+1)*1_000_000},
                         token, {'X-Incarnation': inc, 'X-Sequence': str(seq)})
            window_start = None
            window_bytes = 0
        if time.monotonic() >= next_report:
            print(f'{run}: replayed {processed:,} of {total_rows:,} rows', flush=True)
            next_report = time.monotonic() + 10
        if window_start is None:
            window_start = sec
        second = sec
        if size + len(row) > batch_bytes:
            flush()
        pending[table].append(row)
        size += len(row)
        window_bytes += len(row)
        processed += 1
    flush()
    if retained_header:
        with (service.work/retained.NAME).open('rb') as source, (service.work/'storage'/run/'data'/retained.NAME).open('xb') as target:
            shutil.copyfileobj(source,target,1024*1024);target.flush();os.fsync(target.fileno())
        service.call('/runs/'+run+'/watermark',{'before_us':retained_header['end_us']},token,{'X-Incarnation':inc,'X-Sequence':str(seq)})
    service.call('/runs/'+run+'/finish',{},token,{'X-Incarnation':inc,'X-Sequence':str(seq)})
    print(f'{run}: sealing {processed:,} staged rows', flush=True)
    finalize = {'coverage_only': True}
    if hardware is not None:
        finalize['generator_hardware'] = hardware
    final=service.call('/runs/'+run+'/finalize',finalize)
    if not final['run_complete']:raise ValueError('Converted run is incomplete')
    if hardware is not None and service.call('/runs/'+run+'/query',{'table':'generator_hardware'}).get('statistics')!=hardware:raise ValueError('Portable hardware snapshot differs from source')
    if retained_header and service.call('/runs/'+run+'/query',{'table':'retained_snapshot'})!=retained_header:raise ValueError('Retained snapshot verification mismatch')
    print(f'{run}: verifying staged rows against the source', flush=True)
    actual=service.call('/runs/'+run+'/verify',{})
    actual['load_generator_metrics']=verify_monitor(service.call,run,stats['load_generator_metrics'])
    for table,want in stats.items():
        got=actual.get(table,{'rows':0,'sha256_multiset_sum':'0'*64})
        if got!={k:want[k] for k in ('rows','sha256_multiset_sum')}:raise ValueError('Fingerprint mismatch: '+table)
    return origin,final,actual

def enable_customer_selection(db, record, main_url):
    """Explicit opt-in: main_url must be the application's historical reader."""
    marker=post(main_url,'/runs/'+record['run_id']+'/bundle',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
    if marker!=record['bundle']:raise ValueError('Application reader has a different bundle')
    verified=post(main_url,'/runs/'+record['run_id']+'/verify',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
    for table,want in record['fingerprints'].items():
        if table!='load_generator_metrics' and verified.get(table,{'rows':0,'sha256_multiset_sum':'0'*64})!=want:
            raise ValueError('Application copy fingerprint mismatch: '+table)
    want=record['fingerprints'].get('load_generator_metrics',{'rows':0,'sha256_multiset_sum':'0'*64})
    # Cover the whole source monitoring range recorded at copy time. Records from
    # before that field existed fall back to the run's frontier (never less than
    # the original 7-day window).
    window=record.get('monitoring_range_us')
    if not window:window=(marker['origin_us'],max(marker['origin_us']+7*86400*1_000_000,marker.get('frontier_us',0)+1))
    call=lambda path,obj:post(main_url,path,obj,os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
    actual=verify_monitor(call,record['run_id'],dict(rows=want['rows'],min_us=window[0],max_us=window[1]))
    if actual!=want:raise ValueError('Application monitoring fingerprint mismatch')
    changed=db.results_storage_migrations.update_one({'_id':record['_id'],'state':'verified','bundle':marker},
        {'$set':{'application_available':True,'installed_bundle':marker,'installed_at':dt.datetime.now(dt.timezone.utc)}})
    if changed.matched_count!=1:raise ValueError('Migration registration changed during verification')

def switch(db,t,record,backend,main_url):
    if not eligible(t):raise ValueError('Test is no longer finalized/stopped')
    if record.get('state')!='verified' or record['customer_id']!=t['customer_id'] or record['run_id']!=str(t.get('runId') or t['_id']):raise ValueError('Verified migration identity required')
    configs=list(db.timescaledb.find({'customer_id':t['customer_id']}))
    config=configs[0] if len(configs)==1 else None
    if not config or str(config['_id'])!=record['source_config_id'] or config.get('database')!=record['source_database']:raise ValueError('Original TimescaleDB configuration changed; review before switching')
    expected=record['original_routing'] if t.get('resultsStorageBackend','timescaledb')=='timescaledb' else record['breaktest_db_routing']
    if routing(t)!=expected:raise ValueError('Routing changed outside migration; refusing overwrite')
    target=record['breaktest_db_routing'] if backend=='breaktest-db' else record['original_routing']
    if backend=='breaktest-db':
        marker=post(main_url,'/runs/'+record['run_id']+'/bundle',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
        if marker!=record['bundle']:raise ValueError('Main bundle changed or unavailable')
    update={'$set':target} if target else {}
    unset={k:'' for k in ROUTING if k not in target}
    if unset:update['$unset']=unset
    if routing(t)!=target and db.tests.update_one(guard(t),update).matched_count!=1:raise ValueError('Test changed concurrently; no switch applied')
    db.results_storage_migrations.update_one({'_id':record['_id']},{'$set':{'last_selected_backend':backend,'last_switch_at':dt.datetime.now(dt.timezone.utc)}})

def compact_jvm(conn, run):
    # Each window commits independently. Failed windows roll back and reruns only
    # move still-named measurements. The view exposes both layouts atomically.
    with conn:
        with conn.cursor() as cur:
            cur.execute("SELECT to_regprocedure('public.compact_jvm_window(text,timestamptz,timestamptz)')")
            if not cur.fetchone()[0]:
                raise ValueError("Upgrade the customer schema before compacting historical JVM data")
            cur.execute("""SELECT DISTINCT time_bucket(interval '1 minute',time) AS minute
                           FROM public.runtime_metrics WHERE run_id=%s AND runtime='jmeter' ORDER BY minute""", (run,))
            minutes = [row[0] for row in cur]
    moved = samples = 0
    next_report = time.monotonic() + 10
    for minute in minutes:
        with conn:
            with conn.cursor() as cur:
                cur.execute("SET LOCAL lock_timeout='30s'")
                cur.execute("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction=0")
                cur.execute("SELECT * FROM public.compact_jvm_window(%s,%s,%s + interval '1 minute')",
                            (run, minute, minute))
                count, written = cur.fetchone()
        moved += count
        samples += written
        if time.monotonic() >= next_report:
            print(f"{run}: compacted {moved:,} measurements into {samples:,} samples", flush=True)
            next_report = time.monotonic() + 10
    return moved, samples


def main(a):
    from pymongo import MongoClient
    with MongoClient(os.environ['MIGRATION_MONGO_URI']) as client:
        db = client[os.environ.get('MIGRATION_MONGO_DB', 'breakingit')]
        run_customer(a, db)


def run_customer(a, db):
    from bson import ObjectId
    import psycopg2
    customer=str(ObjectId(a.customer));customer_doc=db.customers.find_one({'_id':ObjectId(customer)})
    if not customer_doc:raise ValueError('Customer not found')
    query={'customer_id':customer}
    if a.test:query['_id']={'$in':[ObjectId(x) for x in a.test]}
    tests=list(db.tests.find(query).sort('_id',1))
    if a.test and len(tests)!=len(set(a.test)):raise ValueError('Requested test does not belong to this customer')
    if a.command == 'compact-jvm':
        candidates = [t for t in tests if t.get('engine', 'breaktest') in ('breaktest', 'jmeter')
                      and t.get('endTime') is not None and t.get('status') in (None, 'stopped', 'finished', 'completed')]
        if a.test and len(candidates) != len(tests):
            raise ValueError("Selected tests must be finalized JMeter tests")
        configs = list(db.timescaledb.find({'customer_id': customer}))
        if len(configs) != 1:
            raise ValueError("Expected one unambiguous customer TimescaleDB configuration")
        import contextlib
        with contextlib.closing(psycopg2.connect(os.environ['MIGRATION_PG_DSN'], application_name='breaktest-compact-jvm')) as conn:
            if conn.info.dbname != configs[0]['database']:
                raise ValueError("Source DSN database does not match customer configuration")
            for t in candidates:
                run = str(t.get('runId') or t['_id'])
                print(f"{run}: compacting historical TimescaleDB JVM data", flush=True)
                moved, samples = compact_jvm(conn, run)
                print(f"{run}: moved {moved:,} named measurements into {samples:,} samples", flush=True)
        return
    if a.command=='plan':
        for t in tests:print(json.dumps(dict(test=str(t['_id']),run=str(t.get('runId') or t['_id']),backend=t.get('resultsStorageBackend','timescaledb'),eligible=copy_eligible(t))))
        return
    if a.command=='switch':
        for t in tests:
            r=db.results_storage_migrations.find_one({'_id':str(t['_id'])})
            if r is None:
                if a.test:raise ValueError('Test has not been migrated')
                continue
            switch(db,t,r,a.backend,a.main_url);print(str(t['_id']),a.backend)
        return
    work=a.work_dir.resolve();work.mkdir(parents=True,exist_ok=True)
    candidates=[t for t in tests if copy_eligible(t)]
    # A whole-customer copy names what it leaves behind instead of omitting it silently.
    left_out = [(t, *skip_reason(t)) for t in tests
                if not copy_eligible(t) and t.get('resultsStorageBackend', 'timescaledb') == 'timescaledb']
    if a.test and len(candidates)!=len(tests):raise ValueError('Selected tests must be finalized TimescaleDB tests')
    configs=list(db.timescaledb.find({'customer_id':customer}))
    if len(configs)!=1:raise ValueError('Expected one unambiguous customer TimescaleDB configuration')
    image=subprocess.check_output(['docker','image','inspect',a.image,'--format','{{.Id}}'],text=True).strip()
    totals = collections.Counter()
    for test in candidates:
        try:
            totals[copy_test(a, db, test, customer, configs[0], image, work)] += 1
        except Exception as exc:
            if not getattr(a, 'continue_on_error', False):
                raise
            totals['failed'] += 1
            print(f"{test['_id']}: {failure_message(exc)}", file=sys.stderr, flush=True)
    if getattr(a, 'continue_on_error', False):
        for t, reason, _ in left_out:
            print(f"{t['_id']}: not copied ({reason})", file=sys.stderr, flush=True)
        print(f"{customer}: {totals['copied']} copied, {totals['already_verified']} already verified, "
              f"{totals['empty']} empty, {totals['failed']} failed, {len(left_out)} not copied", flush=True)
    stranded = sum(1 for _, _, may_change in left_out if not may_change)
    if getattr(a, 'everything', False) and stranded and not totals['failed']:
        raise ValueError(f"{stranded} finished tests cannot be copied for customer {customer}")
    if totals['failed']:
        raise ValueError(f"{totals['failed']} test copies failed for customer {customer}")


def failure_message(exc):
    """Report operator errors without printing driver messages that can contain credentials."""
    if isinstance(exc, (ValueError, FileExistsError)):
        return f'{type(exc).__name__}: {exc}'
    if isinstance(exc, urllib.error.HTTPError):
        return f'BreakTest DB returned HTTP {exc.code}'
    return f'{type(exc).__name__}; check connectivity to MongoDB, PostgreSQL and BreakTest DB'


def copy_test(a, db, t, customer, config, image, work):
    import psycopg2
    rid=str(t.get('runId') or t['_id']);key=str(t['_id'])
    if not re.fullmatch('[A-Za-z0-9_-]{1,64}',rid):raise ValueError('Unsupported run ID')
    existing=db.results_storage_migrations.find_one({'_id':key})
    if existing:
        if existing.get('state')=='verified':
            if (existing.get('customer_id') != customer or existing.get('run_id') != rid
                    or existing.get('source_config_id') != str(config['_id'])
                    or existing.get('source_database') != config['database']
                    or routing(t) != existing.get('original_routing')):
                raise ValueError('Existing migration identity or source configuration changed')
            opened = post(a.main_url, f'/runs/{rid}/bundle', {}, os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
            if opened != existing['bundle']:
                raise ValueError('Existing migration bundle changed')
            if getattr(a, 'enable_customer_selection', False):
                if (getattr(a, 'reverify_existing', False) or not existing.get('application_available')
                        or existing.get('installed_bundle') != existing['bundle']):
                    enable_customer_selection(db, existing, a.main_url)
            print(f'{key}: already verified', flush=True)
            return 'already_verified'
        raise ValueError('An incomplete migration record needs operator review')
    reader_health = post(a.main_url,'/health',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
    if not reader_health.get('retained_timescaledb_v1'):raise ValueError('Upgrade the application storage reader before copying retained history')
    attempt=work/(key+'-'+uuid.uuid4().hex[:10]);attempt.mkdir(mode=0o700);service=None
    try:
        started = time.monotonic()
        print(f'{key}: exporting TimescaleDB results', flush=True)
        conn=psycopg2.connect(os.environ['MIGRATION_PG_DSN'],application_name='breaktest-copy-migration')
        try:
            conn.set_session(readonly=True,isolation_level='REPEATABLE READ',autocommit=False)
            if conn.info.dbname!=config['database']:raise ValueError('Source DSN database does not match customer configuration')
            legacy = check_legacy_monitoring(conn, rid, t, db, getattr(a, 'copy_legacy_monitoring', False))
            paths,stats=export(conn,rid,attempt)
            if legacy:
                stats['load_generator_metrics'] = export_legacy_monitoring(
                    rid, legacy, paths['load_generator_metrics'], stats['load_generator_metrics'],
                )
            retained_header=retained.export(conn,rid,attempt,stats,t)
            conn.rollback()
        finally:conn.close()
        rows = sum(stat['rows'] for stat in stats.values())
        print(f'{key}: exported {rows:,} rows and retained history in {time.monotonic() - started:.1f}s', flush=True)
        if t.get('total_requests') is not None and retained_header['expected_requests'] is not None and int(t['total_requests'])!=retained_header['expected_requests']:raise ValueError('Mongo request total differs from finalized summary')
        save(attempt/'source.json',dict(run_id=rid,customer_id=customer,stats=stats,retained=retained_header))
        destination=a.main_root.resolve()/rid
        main_call=lambda path,obj:post(a.main_url,path,obj,os.environ['BREAKTEST_DB_ADMIN_TOKEN'])
        if destination.exists():
            # Recover publication completed before the Mongo migration record.
            # Never replace a directory; re-prove identity and every raw row.
            marker=inventory(destination)
            if marker.get('run_id')!=rid:raise ValueError('Existing destination identity mismatch')
            for item in marker['files']:
                file=destination/item['name']
                if file.is_symlink() or not file.is_file() or file.stat().st_size!=item['bytes']:raise ValueError('Existing destination file invalid')
                with file.open('rb') as f:
                    if hashlib.file_digest(f,'sha256').hexdigest()!=item['sha256']:raise ValueError('Existing destination checksum mismatch')
            verified=main_call('/runs/'+rid+'/verify',{})
            verified['load_generator_metrics']=verify_monitor(main_call,rid,stats['load_generator_metrics'])
            for table,want in stats.items():
                if verified.get(table,{'rows':0,'sha256_multiset_sum':'0'*64})!= {k:want[k] for k in ('rows','sha256_multiset_sum')}:raise ValueError('Existing destination differs from source: '+table)
            origin=marker['origin_us'];coverage=main_call('/runs/'+rid+'/snapshot',{'coverage_only':True})
            if not coverage.get('run_complete'):raise ValueError('Existing destination is incomplete')
        else:
            print(f'{key}: staging {rows:,} rows', flush=True)
            service=Staging(image,attempt);origin,coverage,verified=encode(service,rid,customer,paths,stats,hardware_snapshot(t,db),retained_header,reader_health)
            source=attempt/'storage'/rid/'data';marker=inventory(source)
            if db.tests.find_one(guard(t)) is None:raise ValueError('Test changed during copy')
            publish(source,a.main_root.resolve(),owner=getattr(a,'target_owner',None))
        opened=main_call('/runs/'+rid+'/bundle',{})
        if opened!=marker:raise ValueError('Main did not open the expected bundle')
        if main_call('/runs/'+rid+'/query',{'table':'retained_snapshot'})!=retained_header:raise ValueError('Main retained aggregates or summaries differ from source')
        record=dict(_id=key,state='verified',customer_id=customer,run_id=rid,original_routing=routing(t),breaktest_db_routing=dict(resultsStorageBackend='breaktest-db',breaktestDb={'run_id':rid,'origin_us':origin,'location':'main','retained_data':retained_header['raw']},breaktestDbCoverage={k:coverage[k] for k in ('frontier','frontier_us','sealed','gaps','unknown','unknown_coverage','run_complete') if k in coverage}),bundle=marker,fingerprints=verified,source_database=config['database'],source_config_id=str(config['_id']),image=image,created_at=dt.datetime.now(dt.timezone.utc))
        monitor=stats['load_generator_metrics']
        if monitor['rows']:record['monitoring_range_us']=[monitor['min_us'],monitor['max_us']]
        if db.tests.find_one(guard(t)) is None:raise ValueError('Test changed before migration registration')
        db.results_storage_migrations.insert_one(record);save(attempt/'verified.json',record)
        if getattr(a,'enable_customer_selection',False):enable_customer_selection(db,record,a.main_url)
        print(f'{key}: copied and verified in {time.monotonic() - started:.1f}s (original test routing retained)', flush=True)
        return 'copied'
    except retained.EmptySource:
        # Wrong database or fully expired data: nothing is copied or recorded.
        shutil.rmtree(attempt)
        if a.test:raise
        print(f'{key}: skipped: source has no result rows for this test', flush=True)
        return 'empty'
    except Exception as e:
        save(attempt/'failed.json',{'error_type':type(e).__name__,'message':'Migration failed; source/routing retained. Inspect local service log and rerun only after resolving the cause.'});raise
    finally:
        if service:service.close()

def parser():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    for name in ['plan','copy','switch','compact-jvm']:
        x=sub.add_parser(name);x.add_argument('--customer',required=True);x.add_argument('--test',action='append')
        if name in ('copy','switch'):x.add_argument('--main-url',required=True)
        if name=='copy':x.add_argument('--main-root',type=Path,required=True);x.add_argument('--work-dir',type=Path,required=True);x.add_argument('--image',required=True)
        if name=='copy':
            x.add_argument('--continue-on-error', action='store_true')
            x.add_argument('--reverify-existing', action='store_true')
            x.add_argument('--copy-legacy-monitoring', action='store_true')
        if name=='copy':x.add_argument('--enable-customer-selection',action='store_true',help='Enable historical reads from this verified copy via the customer preference; main-url must be the application reader')
        if name=='switch':x.add_argument('--backend',choices=['timescaledb','breaktest-db'],required=True)
    return p

if __name__=='__main__':
    main(parser().parse_args())
