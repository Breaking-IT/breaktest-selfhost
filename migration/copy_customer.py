#!/usr/bin/env python3
"""Copy finalized TimescaleDB runs; separately and reversibly switch their reads.
Credentials: MIGRATION_MONGO_URI, MIGRATION_MONGO_DB, MIGRATION_PG_DSN,
BREAKTEST_DB_ADMIN_TOKEN. PostgreSQL is always repeatable-read/read-only.
"""
import argparse,shutil,collections,datetime as dt,gzip,hashlib,heapq,importlib.util,json,os,re,secrets,struct,subprocess,sys,time,urllib.request,urllib.error,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('migration_retained',ROOT/'retained.py')
retained=importlib.util.module_from_spec(spec);spec.loader.exec_module(retained)
spec=importlib.util.spec_from_file_location('migration_bundles',ROOT/'bundles.py')
bundles=importlib.util.module_from_spec(spec);spec.loader.exec_module(bundles)
publish,inventory=bundles.publish,bundles.inventory
spec=importlib.util.spec_from_file_location('migration_hardware',ROOT/'hardware.py')
hardware_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(hardware_module)
def hardware_snapshot(test, db):
    import contextlib, psycopg2
    @contextlib.contextmanager
    def connection(name):
        conn=psycopg2.connect(os.environ.get('MIGRATION_MONITORING_PG_DSN',os.environ['MIGRATION_PG_DSN']), dbname=name, application_name='breaktest-copy-hardware')
        try:
            conn.set_session(readonly=True, isolation_level='REPEATABLE READ')
            yield conn
        finally:conn.close()
    return hardware_module.generator_hardware_snapshot(test,db,connection)
HEADER=b'PGCOPY\n\xff\r\n\0'+b'\0'*8
BOUNDARY='breaktest-copy-migration-v1'
ROUTING=('resultsStorageBackend','breaktestDb','breaktestDbCoverage')
SCHEMA=json.loads((ROOT/'wire-schema.json').read_text())['fixture_manifest']['tables']
MONITOR=['time','run_id','generator_name','location','node_name','source','container_id','container_name','container_image','app','status','cpu_percent','load_1m','cpu_count','memory_free_mb','memory_total_mb','memory_used_mb','memory_used_percent','network_bytes_in_per_sec','network_bytes_out_per_sec','network_bits_per_sec']
SCHEMA['load_generator_metrics']={'columns':[dict(column_name=n,data_type='timestamp with time zone' if i==0 else 'double precision' if i>=11 else 'text') for i,n in enumerate(MONITOR)]}

def save(p,data):
    tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(data,default=str,indent=2));tmp.replace(p)
def eligible(t):
    return (t.get('engine','breaktest') in ('breaktest','jmeter') and t.get('status') in (None,'stopped','finished','completed') and t.get('endTime') is not None and t.get('max_vus') is not None and t.get('total_errors') is not None)
def copy_eligible(t):
    return eligible(t) and t.get('resultsStorageBackend','timescaledb') == 'timescaledb'
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

def records(path):
    # Parse blocks rather than issuing a Python gzip read for every field.
    # Retain at most one bounded row plus a read block across boundaries.
    with gzip.open(path,'rb') as f:
        if f.read(19)!=HEADER:raise ValueError('Unsupported binary COPY header')
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
            if c.fetchone():raise ValueError('k6 browser results are not supported')
        for table,schema in SCHEMA.items():
            c.execute('SELECT to_regclass(%s)',('public.'+table,))
            if not c.fetchone()[0]:stats[table]={'rows':0,'sha256_multiset_sum':'0'*64};continue
            c.execute("SELECT column_name,data_type FROM information_schema.columns WHERE table_schema='public' AND table_name=%s",(table,));actual=dict(c.fetchall())
            if any(actual.get(x['column_name'])!=x['data_type'] for x in schema['columns']):raise ValueError('Unsupported source schema: '+table)
            path=work/(table+'.copy.gz');paths[table]=path
            query=sql.SQL('COPY (SELECT {} FROM public.{} WHERE run_id={} ORDER BY time) TO STDOUT (FORMAT binary)').format(sql.SQL(',').join(sql.Identifier(x['column_name']) for x in schema['columns']),sql.Identifier(table),sql.Literal(run))
            with gzip.open(path,'wb',compresslevel=1) as f:c.copy_expert(query.as_string(conn),f)
        for table,path in paths.items():
            count=0;finger=0;lo=None;hi=None
            for row in records(path):
                timestamp=row_timestamp(row)
                if timestamp<0:raise ValueError('Pre-2000 timestamps unsupported')
                lo=timestamp if lo is None else min(lo,timestamp);hi=timestamp if hi is None else max(hi,timestamp)
                count+=1;finger=(finger+int.from_bytes(hashlib.sha256(row).digest(),'big'))%(1<<256)
            stats[table]=dict(rows=count,sha256_multiset_sum=f'{finger:064x}',min_us=lo,max_us=hi)
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

def encode(service,run,customer,paths,stats,hardware=None,retained_header=None):
    try:from compression import zstd
    except ImportError:import zstandard as zstd
    def compress(data):
        if hasattr(zstd,'CompressionParameter'):return zstd.compress(data,options={zstd.CompressionParameter.compression_level:1,zstd.CompressionParameter.window_log:18})
        return zstd.ZstdCompressor(compression_params=zstd.ZstdCompressionParameters.from_level(1,window_log=18)).compress(data)
    if retained_header and not service.call('/health',{}).get('retained_timescaledb_v1'):raise ValueError('Upgrade the BreakTest DB image: retained-data migration requires bundle v3 support')
    origin=retained_header['origin_us'] if retained_header else min(v['min_us'] for v in stats.values() if v['rows'])//1_000_000*1_000_000;token=secrets.token_hex(32)
    inc=service.call('/runs/create',dict(run_id=run,origin_us=origin,source_tokens=[token],block_seconds=10))['incarnation'];seq=0;pending=collections.defaultdict(list);size=0;second=None
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
    for timestamp,table,row in heapq.merge(*(stream(t,p) for t,p in paths.items())):
        sec=timestamp//1_000_000
        if second is not None and sec!=second:
            flush();service.call('/runs/'+run+'/watermark',{'before_us':(second+1)*1_000_000},token,{'X-Incarnation':inc,'X-Sequence':str(seq)})
        second=sec
        if size+len(row)>1024*1024:flush()
        pending[table].append(row);size+=len(row)
    flush()
    if retained_header:
        with (service.work/retained.NAME).open('rb') as source, (service.work/'storage'/run/'data'/retained.NAME).open('xb') as target:
            shutil.copyfileobj(source,target,1024*1024);target.flush();os.fsync(target.fileno())
        service.call('/runs/'+run+'/watermark',{'before_us':retained_header['end_us']},token,{'X-Incarnation':inc,'X-Sequence':str(seq)})
    service.call('/runs/'+run+'/finish',{},token,{'X-Incarnation':inc,'X-Sequence':str(seq)})
    final=service.call('/runs/'+run+'/finalize',{} if hardware is None else {'generator_hardware':hardware})
    if not final['run_complete']:raise ValueError('Converted run is incomplete')
    if hardware is not None and service.call('/runs/'+run+'/query',{'table':'generator_hardware'}).get('statistics')!=hardware:raise ValueError('Portable hardware snapshot differs from source')
    if retained_header and service.call('/runs/'+run+'/query',{'table':'retained_snapshot'})!=retained_header:raise ValueError('Retained snapshot verification mismatch')
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

def main(a):
    from bson import ObjectId
    from pymongo import MongoClient
    import psycopg2
    db=MongoClient(os.environ['MIGRATION_MONGO_URI'])[os.environ.get('MIGRATION_MONGO_DB','breakingit')]
    customer=str(ObjectId(a.customer));customer_doc=db.customers.find_one({'_id':ObjectId(customer)})
    if not customer_doc:raise ValueError('Customer not found')
    query={'customer_id':customer}
    if a.test:query['_id']={'$in':[ObjectId(x) for x in a.test]}
    tests=list(db.tests.find(query).sort('_id',1))
    if a.test and len(tests)!=len(set(a.test)):raise ValueError('Requested test does not belong to this customer')
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
    if a.test and len(candidates)!=len(tests):raise ValueError('Selected tests must be finalized TimescaleDB tests')
    configs=list(db.timescaledb.find({'customer_id':customer}))
    if len(configs)!=1:raise ValueError('Expected one unambiguous customer TimescaleDB configuration')
    image=subprocess.check_output(['docker','image','inspect',a.image,'--format','{{.Id}}'],text=True).strip()
    for t in candidates:
        rid=str(t.get('runId') or t['_id']);key=str(t['_id'])
        if not re.fullmatch('[A-Za-z0-9_-]{1,64}',rid):raise ValueError('Unsupported run ID')
        existing=db.results_storage_migrations.find_one({'_id':key})
        if existing:
            if existing.get('state')=='verified':
                if existing.get('customer_id')!=customer or existing.get('run_id')!=rid or post(a.main_url,'/runs/'+rid+'/bundle',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN'])!=existing['bundle']:raise ValueError('Existing migration identity/bundle changed')
                if getattr(a,'enable_customer_selection',False):enable_customer_selection(db,existing,a.main_url)
                print(key,'already verified');continue
            raise ValueError('An incomplete migration record needs operator review')
        if not post(a.main_url,'/health',{},os.environ['BREAKTEST_DB_ADMIN_TOKEN']).get('retained_timescaledb_v1'):raise ValueError('Upgrade the application storage reader before copying retained history')
        attempt=work/(key+'-'+uuid.uuid4().hex[:10]);attempt.mkdir(mode=0o700);service=None
        try:
            conn=psycopg2.connect(os.environ['MIGRATION_PG_DSN'],application_name='breaktest-copy-migration')
            try:
                conn.set_session(readonly=True,isolation_level='REPEATABLE READ',autocommit=False)
                if conn.info.dbname!=configs[0]['database']:raise ValueError('Source DSN database does not match customer configuration')
                paths,stats=export(conn,rid,attempt)
                # SQL may otherwise silently read shared monitoring instead. That
                # data is not in this run export: refuse to publish a partial copy.
                if t.get('loadGenerators'):
                    with conn.cursor() as cur:
                        cur.execute("SELECT count(*) FROM load_generator_metrics WHERE run_id=%s AND source='agent'",(rid,))
                        if not cur.fetchone()[0]:raise ValueError('No run-scoped generator monitoring; shared-monitoring-only legacy tests require explicit conversion')
                retained_header=retained.export(conn,rid,attempt,stats,t)
                conn.rollback()
            finally:conn.close()
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
                origin=marker['origin_us'];coverage=main_call('/runs/'+rid+'/snapshot',{})
                if not coverage.get('run_complete'):raise ValueError('Existing destination is incomplete')
            else:
                service=Staging(image,attempt);origin,coverage,verified=encode(service,rid,customer,paths,stats,hardware_snapshot(t,db),retained_header)
                source=attempt/'storage'/rid/'data';marker=inventory(source)
                if db.tests.find_one(guard(t)) is None:raise ValueError('Test changed during copy')
                publish(source,a.main_root.resolve(),owner=getattr(a,'target_owner',None))
            opened=main_call('/runs/'+rid+'/bundle',{})
            if opened!=marker:raise ValueError('Main did not open the expected bundle')
            if main_call('/runs/'+rid+'/query',{'table':'retained_snapshot'})!=retained_header:raise ValueError('Main retained aggregates or summaries differ from source')
            record=dict(_id=key,state='verified',customer_id=customer,run_id=rid,original_routing=routing(t),breaktest_db_routing=dict(resultsStorageBackend='breaktest-db',breaktestDb={'run_id':rid,'origin_us':origin,'location':'main','retained_data':retained_header['raw']},breaktestDbCoverage={k:coverage[k] for k in ('frontier','frontier_us','sealed','gaps','unknown','unknown_coverage','run_complete') if k in coverage}),bundle=marker,fingerprints=verified,source_database=configs[0]['database'],source_config_id=str(configs[0]['_id']),image=image,created_at=dt.datetime.now(dt.timezone.utc))
            monitor=stats['load_generator_metrics']
            if monitor['rows']:record['monitoring_range_us']=[monitor['min_us'],monitor['max_us']]
            if db.tests.find_one(guard(t)) is None:raise ValueError('Test changed before migration registration')
            db.results_storage_migrations.insert_one(record);save(attempt/'verified.json',record)
            if getattr(a,'enable_customer_selection',False):enable_customer_selection(db,record,a.main_url)
            print(key,'copied and verified; original test routing retained')
        except retained.EmptySource:
            # Wrong database or fully expired data: nothing is copied or recorded.
            shutil.rmtree(attempt)
            if a.test:raise
            print(key,'skipped: source has no result rows for this test');continue
        except Exception as e:
            save(attempt/'failed.json',{'error_type':type(e).__name__,'message':'Migration failed; source/routing retained. Inspect local service log and rerun only after resolving the cause.'});raise
        finally:
            if service:service.close()

def parser():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    for name in ['plan','copy','switch']:
        x=sub.add_parser(name);x.add_argument('--customer',required=True);x.add_argument('--test',action='append')
        if name in ('copy','switch'):x.add_argument('--main-url',required=True)
        if name=='copy':x.add_argument('--main-root',type=Path,required=True);x.add_argument('--work-dir',type=Path,required=True);x.add_argument('--image',required=True)
        if name=='copy':x.add_argument('--enable-customer-selection',action='store_true',help='Enable historical reads from this verified copy via the customer preference; main-url must be the application reader')
        if name=='switch':x.add_argument('--backend',choices=['timescaledb','breaktest-db'],required=True)
    return p

if __name__=='__main__':
    main(parser().parse_args())
