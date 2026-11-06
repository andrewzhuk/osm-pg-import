#!/usr/bin/env python3
"""Real osm2pgsql/PostGIS/replication integration on locally generated data only."""
import contextlib
import functools
import getpass
import gzip
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import uuid
from xml.etree.ElementTree import Element, SubElement, tostring

ROOT = Path(__file__).resolve().parents[1]
T1, T2, T3 = '2024-01-01T03:00:00Z', '2024-01-01T03:01:00Z', '2024-01-01T03:02:00Z'

class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args): pass


def element(kind, oid, tags=None, refs=None, version=1, timestamp=T1, **attrs):
    e = Element(kind, id=str(oid), version=str(version), timestamp=timestamp, **{k:str(v) for k,v in attrs.items()})
    for ref in refs or []:
        if kind == 'way': SubElement(e, 'nd', ref=str(ref))
        else: SubElement(e, 'member', type='way', ref=str(ref), role='outer')
    for key, value in (tags or {}).items(): SubElement(e, 'tag', k=key, v=value)
    return e


def fixtures(base):
    osm = Element('osm', version='0.6', generator='osm-pg-import-offline-test')
    nodes, ways, relations = [], [], []
    def node(x, y):
        oid = len(nodes) + 1
        nodes.append(element('node', oid, lon=x, lat=y))
        return oid
    def box(oid, x1, y1, x2, y2, tags=None):
        refs = [node(x1,y1), node(x2,y1), node(x2,y2), node(x1,y2)]
        ways.append(element('way', oid, tags, refs + refs[:1]))
    box(1001, 30,49,31,50)
    box(1002, 30.1,49.1,30.9,49.9)
    box(1003, 30.2,49.2,30.5,49.5)
    box(400, 30.5,49.2,30.8,49.5, {'place':'village','name':'Village B'})
    a,b,c = node(30.25,49.3), node(30.3,49.3), node(30.4,49.3)
    ways.extend([
        element('way', 500, {'highway':'residential','name':'вул. Шевченка','name:en':'Shevchenko st.'}, [a,b]),
        element('way', 501, {'highway':'residential','name':'Шевченка вул.','name:ru':'ул. Шевченко'}, [b,c]),
        element('way', 503, {'highway':'residential','name':'Crossing'}, [node(30.6,49.35),node(30.85,49.35)]),
        element('way', 504, {'highway':'residential','name':'Unassigned'}, [node(30.92,49.3),node(30.93,49.3)]),
        element('way', 505, {'highway':'residential','name':'Unassigned'}, [node(30.95,49.3),node(30.96,49.3)])
    ])
    city_tags = {'type':'boundary','place':'city','name':'City A','population':'12 345'}
    relations.extend([
        element('relation', 100, {'type':'boundary','boundary':'administrative','admin_level':'4','ISO3166-2':'UA-99','name':'Test region'}, [1001]),
        element('relation', 200, {'type':'boundary','boundary':'administrative','admin_level':'6','name':'Test district'}, [1002]),
        element('relation', 300, city_tags, [1003])
    ])
    for e in sorted(nodes, key=lambda e:int(e.get('id'))) + sorted(ways, key=lambda e:int(e.get('id'))) + relations: osm.append(e)
    (base/'tiny.osm').write_bytes(tostring(osm, encoding='utf-8', xml_declaration=True))
    change = Element('osmChange', version='0.6', generator='offline-test')
    create, modify, delete = SubElement(change,'create'), SubElement(change,'modify'), SubElement(change,'delete')
    create.append(element('way', 502, {'highway':'pedestrian','name':'пл. Нова'}, [a,b], timestamp=T2))
    modify.append(element('way', 501, {'highway':'primary','name':'вул. Шевченка','name:ru':'ул. Шевченко','addr:postcode':'01001'}, [b,c], version=2, timestamp=T2))
    modify.append(element('relation', 300, dict(city_tags, name='City A updated'), [1003], version=2, timestamp=T2))
    delete.append(element('way', 500, version=2, timestamp=T2, visible='false'))
    delta2 = tostring(change, encoding='utf-8', xml_declaration=True)
    change = Element('osmChange', version='0.6', generator='offline-test')
    modify, delete = SubElement(change,'modify'), SubElement(change,'delete')
    modify.append(element('node', b, lon=30.31,lat=49.31, version=2,timestamp=T3))
    modify.append(element('way', 502, {'highway':'primary','name':'просп. Новий'}, [a,b], version=2, timestamp=T3))
    delete.append(element('way', 501, version=3, timestamp=T3, visible='false'))
    delete.append(element('way', 400, version=2, timestamp=T3, visible='false'))
    delta3 = tostring(change, encoding='utf-8', xml_declaration=True)
    stream = base/'stream'; (stream/'000/000').mkdir(parents=True)
    def state(seq, timestamp): return 'sequenceNumber={}\ntimestamp={}\n'.format(seq, timestamp.replace(':', '\\:'))
    for seq,timestamp in [(0,'2024-01-01T02:59:00Z'),(1,T1),(2,T2),(3,T3)]:
        (stream/f'000/000/{seq:03}.state.txt').write_text(state(seq,timestamp))
    for seq,data in [(2,delta2),(3,delta3)]:
        (stream/f'000/000/{seq:03}.osc.gz').write_bytes(gzip.compress(data, mtime=0))
    (stream/'state.txt').write_text(state(1,T1))
    return stream, state


def main():
    for cmd in ['psql','dropdb','createdb','osm2pgsql','osm2pgsql-replication']:
        if not shutil.which(cmd): raise SystemExit('Required integration dependency missing: '+cmd)
    db = 'osm_pg_import_test_' + uuid.uuid4().hex[:12]
    env = dict(os.environ, DB_NAME=db, DB_USER=os.environ.get('PGUSER', getpass.getuser()),
               DB_HOST=os.environ.get('PGHOST','localhost'), DB_PORT=os.environ.get('PGPORT','5432'),
               CACHE_MB='16', INIT_REPLICATION='0', DOWNLOAD_OSM='0', REPLICATION_START_AT=T1)
    env.pop('SQL_SCRIPT', None)
    args = ['-d',db,'-U',env['DB_USER'],'-h',env['DB_HOST'],'-p',env['DB_PORT']]
    def run(command, extra=None, success=True):
        result = subprocess.run(command, env=dict(env, **(extra or {})), text=True, capture_output=True)
        if success and result.returncode:
            raise AssertionError('Command failed: '+repr(command)+'\n'+result.stdout+'\n'+result.stderr)
        if not success and not result.returncode: raise AssertionError('Command unexpectedly succeeded')
        return result
    def sql(query): return run(['psql','-X',*args,'-v','ON_ERROR_STOP=1','-Atc',query]).stdout.strip()
    def snapshot():
        return sql("SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY id), '[]') FROM streets s")
    def checkpoint():
        return sql("SELECT value FROM osm2pgsql_properties WHERE property='replication_sequence_number'")
    with tempfile.TemporaryDirectory(prefix='osm integration ') as directory:
        base=Path(directory); stream,state=fixtures(base)
        handler=functools.partial(QuietHandler,directory=str(stream))
        server=ThreadingHTTPServer(('127.0.0.1',0),handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        env.update(OSM_FILE=str(base/'tiny.osm'),REPLICATION_URL=f'http://127.0.0.1:{server.server_port}')
        try:
            # Prepared PostGIS databases are allowed; user tables are protected.
            run(['createdb','-U',env['DB_USER'],'-h',env['DB_HOST'],'-p',env['DB_PORT'],db])
            sql('CREATE EXTENSION postgis; CREATE TABLE sentinel(value integer); INSERT INTO sentinel VALUES (42)')
            run(['bash',str(ROOT/'run_osm_import.sh')], success=False)
            assert sql('SELECT value FROM sentinel')=='42'
            sql('DROP TABLE sentinel')
            run(['bash',str(ROOT/'run_osm_import.sh')])
            assert sql('SELECT count(*) FROM regions')=='1'
            assert sql('SELECT region_id FROM districts WHERE id=-200')=='-100'
            assert sql('SELECT district_id FROM cities WHERE id=-300')=='-200'
            assert sql('SELECT count(*) FROM cities')=='2'  # relation and closed way
            assert sql("SELECT metadata->>'population' FROM cities WHERE id=-300")=='12345'
            assert sql('SELECT city_id FROM streets_raw WHERE way_id=503')=='400'  # crossing city boundary
            assert sql("SELECT count(*) FROM streets WHERE name='Unassigned'")=='2'
            street_id=sql("SELECT id FROM streets WHERE name='вулиця Шевченка'")
            assert street_id
            translations=json.loads(sql("SELECT names FROM streets WHERE id="+street_id))
            assert translations=={'uk':'вулиця Шевченка','en':'Shevchenko Street','ru':'улица Шевченко'},translations
            before=snapshot()
            run(['bash',str(ROOT/'scripts/postprocess.sh')])
            assert snapshot()==before, 'Repeated SQL changed rows/IDs'
            run(['bash',str(ROOT/'run_osm_import.sh')], success=False)
            assert snapshot()==before, 'Refused reimport changed database'
            print('PASS: real import, spatial associations, normalization, translation merge, idempotent SQL, overwrite refusal', flush=True)
            run(['bash',str(ROOT/'run_osm_update.sh'),'--init'])
            assert checkpoint()=='1', checkpoint()
            (stream/'state.txt').write_text(state(2,T2))
            broken=base/'broken.sql'; broken.write_text("UPDATE streets SET name='broken'; SELECT deliberately_missing_function();")
            failed = run(['bash',str(ROOT/'run_osm_update.sh')], extra={'SQL_SCRIPT':str(broken)}, success=False)
            assert 'deliberately_missing_function' in failed.stderr, failed.stderr
            assert sql("SELECT names->>'uk' FROM cities WHERE id=-300")=='City A updated'
            assert checkpoint()=='1', 'Failed postprocessing advanced replication checkpoint'
            assert snapshot()==before, 'Failed SQL was not rolled back'
            run(['bash',str(ROOT/'run_osm_update.sh')])
            assert checkpoint()=='2'
            assert sql('SELECT count(*) FROM streets_raw WHERE way_id=500')=='0'
            assert sql("SELECT id FROM streets WHERE name='вулиця Шевченка'")==street_id
            assert sql('SELECT way_id FROM streets WHERE id='+street_id)=='501'
            assert sql("SELECT names->>'uk' FROM cities WHERE id=-300")=='City A updated'
            assert sql("SELECT metadata->>'postal_code' FROM streets WHERE id="+street_id)=='01001'
            assert sql("SELECT metadata->>'classification' FROM streets WHERE name='площа Нова'")=='square'
            after=snapshot()
            run(['bash',str(ROOT/'run_osm_update.sh')])
            assert checkpoint()=='2' and snapshot()==after, 'No-op update changed rows'
            print('PASS: real replication, forced SQL failure/rollback, unchanged checkpoint, retry, stable IDs, no-op update', flush=True)
            (stream/'state.txt').write_text(state(3,T3))
            run(['bash',str(ROOT/'run_osm_update.sh')])
            assert checkpoint()=='3'
            assert sql('SELECT count(*) FROM streets WHERE id='+street_id)=='0'
            assert sql("SELECT count(*) FROM streets WHERE name='площа Нова'")=='0'
            assert sql("SELECT metadata->>'classification' FROM streets WHERE name='проспект Новий'")=='avenue'
            assert sql('SELECT count(*) FROM cities WHERE id=400')=='0'
            assert sql('SELECT city_id IS NULL FROM streets_raw WHERE way_id=503')=='t'
            assert sql("SELECT ST_AsText(geom) FROM streets WHERE name='проспект Новий'").find('30.31 49.31')>=0
            after=snapshot()
            run(['bash',str(ROOT/'scripts/postprocess.sh')])
            assert snapshot()==after
            print('PASS: second replication batch, node movement, street rename/deletion, settlement deletion, repeat SQL', flush=True)
        finally:
            server.shutdown(); server.server_close(); thread.join()
            result=run(['dropdb','--if-exists','-U',env['DB_USER'],'-h',env['DB_HOST'],'-p',env['DB_PORT'],db])
            print('Cleaned up isolated test database '+db, flush=True)

if __name__=='__main__': main()
