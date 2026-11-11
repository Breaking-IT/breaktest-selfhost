#!/usr/bin/env python3
"""Copy an immutable run bundle, verify it, then atomically make it discoverable.
Copy a remote bundle locally first (e.g. rsync into a staging directory), then use
--attach to verify/rename that directory on the main filesystem. No DB import.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import uuid


def inventory(source):
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Source must be a real bundle directory')
    marker = source / 'bundle.json'
    if marker.is_symlink() or marker.stat().st_size > 16*1024*1024:
        raise ValueError('Invalid bundle marker')
    info = json.loads(marker.read_text())
    run_id = info.get('run_id', '')
    version=info.get('format')
    if version not in ('breaktest-run-bundle-v1','breaktest-run-bundle-v2','breaktest-run-bundle-v3') or (version!='breaktest-run-bundle-v1' and info.get('storage_format_version')!=int(version[-1])):
        raise ValueError('Unsupported bundle storage format version')
    if (not info.get('sealed') or
            not run_id or len(run_id)>64 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in run_id)):
        raise ValueError('Unsupported or unfinished bundle')
    names = set()
    for item in info['files']:
        name = item['name']
        if not isinstance(name,str) or name in ('', '.', '..', 'bundle.json') or Path(name).name != name or name in names:
            raise ValueError('Invalid/duplicate inventory path')
        names.add(name)
    if (version=='breaktest-run-bundle-v3') != ('retained-timescaledb-v1.jsonl.zstd' in names):raise ValueError('Retained snapshot version mismatch')
    generation=info.get('generation')
    complete=('sealed-manifest.bin' in names if version in ('breaktest-run-bundle-v2','breaktest-run-bundle-v3') else
              isinstance(generation,int) and generation<=len(names) and all(f'delta-{n:012}.json.zstd' in names for n in range(generation)))
    if (not isinstance(generation,int) or isinstance(generation,bool) or generation < 1 or
            'manifest.json' not in names or not complete):
        raise ValueError('Incomplete bundle inventory')
    if version in ('breaktest-run-bundle-v2','breaktest-run-bundle-v3'):
        packed=source/'sealed-manifest.bin'
        if packed.is_symlink() or not packed.is_file():raise ValueError('Invalid sealed manifest')
        with packed.open('rb') as f:header=f.read(16)
        if len(header)!=16 or header[:8]!=b'BTMETA02':raise ValueError('Unsupported sealed manifest version')
        count=struct.unpack('!Q',header[8:])[0]
        if count!=generation or count>1_000_000 or packed.stat().st_size<16+16*count:raise ValueError('Incomplete sealed manifest')
    return info


def sync_dir(path):
    fd=os.open(path,os.O_RDONLY)
    try:os.fsync(fd)
    finally:os.close(fd)


def publish(source, main_root, attach=False, owner=None):
    """Copy a sealed bundle unchanged; ownership is recorded by the referencing test document."""
    source=source.absolute();main_root=main_root.absolute();info=inventory(source)
    if attach and not source.name.startswith(".incoming-"):
        raise ValueError("--attach requires a hidden .incoming- staging directory")
    main_root.mkdir(parents=True,exist_ok=True)
    destination=main_root/info['run_id']
    if destination.exists():
        raise FileExistsError(f'Destination already exists: {destination}')
    if attach and source.parent != main_root:
        raise ValueError('--attach needs a staging directory on the main root filesystem')
    staging=source if attach else main_root/('.incoming-'+uuid.uuid4().hex)
    if not attach:staging.mkdir()
    try:
        for item in info['files']:
            original=source/item['name']
            if original.is_symlink() or not original.is_file() or original.stat().st_size!=item['bytes']:
                raise ValueError('Missing, unsafe or incomplete bundle file: '+item['name'])
            digest=hashlib.sha256()
            with original.open('rb') as incoming:
                if attach:
                    for chunk in iter(lambda: incoming.read(1024*1024),b''):digest.update(chunk)
                    os.fsync(incoming.fileno())
                else:
                    with (staging/item['name']).open('xb') as outgoing:
                        for chunk in iter(lambda: incoming.read(1024*1024),b''):
                            digest.update(chunk);outgoing.write(chunk)
                        outgoing.flush();os.fsync(outgoing.fileno())
            if digest.hexdigest()!=item['sha256']:
                raise ValueError('Bundle checksum mismatch: '+item['name'])
        # Marker last; readers also check the complete inventory independently.
        if not attach:
            with (staging/'bundle.json').open('xb') as f:
                f.write(json.dumps(info,separators=(',',':')).encode());f.flush();os.fsync(f.fileno())
        if attach:
            with (staging/'bundle.json').open('rb') as f:os.fsync(f.fileno())
        if inventory(source) != info:
            raise ValueError("Bundle marker changed during transfer")
        if owner is not None:
            for path in staging.iterdir():os.chown(path, *owner)
            os.chown(staging, *owner)
        sync_dir(staging)
        # The final directory must be absent; never merge/replace a published run.
        # A publisher lock serializes cooperating transfers for this run.
        lock=main_root/('.publish-'+info['run_id']+'.lock')
        import fcntl
        with lock.open('a') as f:
            fcntl.flock(f,fcntl.LOCK_EX)
            if destination.exists():raise FileExistsError(destination)
            staging.rename(destination);sync_dir(main_root)
        return destination
    except Exception:
        if not attach and staging.exists():shutil.rmtree(staging)
        raise


def bundle_dir(run):
    """The directory holding bundle.json: the run itself, or its data/ subdirectory."""
    for candidate in (run / 'data', run):
        if (candidate / 'bundle.json').is_file() and not candidate.is_symlink():
            return candidate
    return None


def restore_runs(source, root):
    """Publish missing run directories from a backup into root; never overwrite (see tools/restore_volume.py)."""
    result = {'restored': [], 'identical': [], 'conflicts': [], 'unsealed': []}
    for run in sorted(p for p in source.iterdir() if p.is_dir() and not p.is_symlink() and not p.name.startswith('.')):
        target = root / run.name
        data = bundle_dir(run)
        if target.exists() or target.is_symlink():
            existing = bundle_dir(target)
            if data and existing and inventory(existing) == inventory(data):
                result['identical'].append(run.name)
            else:
                result['conflicts'].append(run.name)
            continue
        if data:
            if inventory(data).get('run_id') != run.name:
                result['conflicts'].append(run.name)
                continue
            publish(data, root)
            (root / f'.publish-{run.name}.lock').unlink(missing_ok=True)
            result['restored'].append(run.name)
        else:
            # A test that was still running at backup time: copy its checkpoint
            # files as-is; the store recovers it conservatively when reopened.
            staging = root / f'.incoming-restore-{run.name}'
            shutil.copytree(run, staging, symlinks=True)
            os.rename(staging, target)
            result['unsealed'].append(run.name)
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('main_root',type=Path);p.add_argument('--attach',action='store_true');a=p.parse_args()
    print(publish(a.source,a.main_root,a.attach))
