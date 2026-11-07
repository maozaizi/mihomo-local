#!/usr/bin/env python3
"""Package only approved source paths; never recurse through the workspace."""
import argparse
import hashlib
import io
import json
import re
from pathlib import Path
import tarfile
import zipfile
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--output-dir', type=Path, default=root.parent/'outputs')
parser.add_argument('--vendor-dir',type=Path,help='verified directory produced by prepare-offline.py')
args=parser.parse_args()
roots=['bin','lib','assets','shell','systemd','tests','tools']
names=['README.md','ARCHITECTURE.md','CHANGELOG.md','VALIDATION.md',
       'SECURITY.md','SECURITY_AUDIT.md','LICENSE','VERSION','template.yaml',
       'install.sh','DEPENDENCIES.md','.gitignore','.gitattributes']
files=[root/n for n in names if (root/n).is_file()]
for p in files:
    if p.is_symlink(): raise SystemExit(f'Refusing symlink: {p.relative_to(root)}')
for name in roots:
    if (root/name).is_symlink(): raise SystemExit(f'Refusing symlink: {name}')
    for p in (root/name).rglob('*'):
        if p.is_symlink(): raise SystemExit(f'Refusing symlink: {p.relative_to(root)}')
        if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.pyc','.log','.pem','.key') and not any(x.startswith('.') for x in p.relative_to(root).parts):
            files.append(p)
files=sorted(files)
source_manifest=''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n' for p in files)
(root/'SHA256SUMS').write_text(source_manifest)
entries={str(p.relative_to(root)):p for p in files}
suffix='-source'
if args.vendor_dir:
    vendor=args.vendor_dir.resolve()
    allowed={'manifest.json','SHA256SUMS','SOURCES.md','bin/mihomo','bin/yq',
             'licenses/mihomo-LICENSE','licenses/yq-LICENSE',
             'sources/mihomo.tar.gz','sources/yq.tar.gz'}
    actual=set()
    for p in vendor.rglob('*'):
        if p.is_symlink():raise SystemExit('Vendor symlinks are forbidden')
        if p.is_file():actual.add(str(p.relative_to(vendor)))
    if actual!=allowed:raise SystemExit('Vendor directory is incomplete or has unapproved files')
    declared={}
    for line in (vendor/'SHA256SUMS').read_text().splitlines():
        digest,name=line.split('  ',1)
        if not re.fullmatch('[0-9a-f]{64}',digest) or name not in allowed-{'SHA256SUMS'} or name in declared:raise SystemExit('Invalid vendor manifest')
        declared[name]=digest
    if set(declared)!=allowed-{'SHA256SUMS'}:raise SystemExit('Incomplete vendor manifest')
    for name,digest in declared.items():
        if hashlib.sha256((vendor/name).read_bytes()).hexdigest()!=digest:raise SystemExit('Vendor checksum mismatch: '+name)
    metadata=json.loads((vendor/'manifest.json').read_text())
    arch=metadata['architecture']
    if arch not in ('amd64','arm64'):raise SystemExit('Unsupported vendor architecture')
    for binary in ('mihomo','yq'):
        data=(vendor/'bin'/binary).read_bytes()
        if data[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(data[18:20],'little')!={'amd64':62,'arm64':183}[arch]:raise SystemExit('Vendor ELF architecture mismatch')
        if metadata['binaries'][binary]['sha256']!=declared['bin/'+binary]:raise SystemExit('Vendor provenance mismatch')
    entries.update({'vendor/'+name:vendor/name for name in sorted(actual)})
    suffix='-linux-'+arch
manifest=''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {name}\n' for name,p in sorted(entries.items())).encode()
entries['SHA256SUMS']=manifest
version=(root/'VERSION').read_text().strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version):raise SystemExit('Invalid version')
name=f'mihomo-local-v{version}'
out=args.output_dir;out.mkdir(parents=True,exist_ok=True)
with tarfile.open(out/(name+suffix+'.tar.gz'),'w:gz') as tf:
    for relative,value in sorted(entries.items()):
        info=tarfile.TarInfo(name+'/'+relative)
        info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0
        info.mode=0o755 if isinstance(value,Path) and value.stat().st_mode & 0o111 else 0o644
        info.size=value.stat().st_size if isinstance(value,Path) else len(value)
        if isinstance(value,Path):
            with value.open('rb') as f:tf.addfile(info,f)
        else:tf.addfile(info,io.BytesIO(value))
with zipfile.ZipFile(out/(name+suffix+'.zip'),'w',zipfile.ZIP_DEFLATED) as z:
    for relative,value in sorted(entries.items()):
        info=zipfile.ZipInfo(name+'/'+relative,date_time=(1980,1,1,0,0,0))
        info.compress_type=zipfile.ZIP_DEFLATED
        info.external_attr=(0o100755 if isinstance(value,Path) and value.stat().st_mode & 0o111 else 0o100644)<<16
        z.writestr(info,value.read_bytes() if isinstance(value,Path) else value)
for ext in ['.tar.gz','.zip']:
    p=out/(name+suffix+ext)
    print(hashlib.sha256(p.read_bytes()).hexdigest(),p)
