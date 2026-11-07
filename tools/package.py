#!/usr/bin/env python3
"""Package only approved source paths; never recurse through the workspace."""
import argparse
import hashlib
from pathlib import Path
import tarfile
import zipfile
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--output-dir', type=Path, default=root.parent/'outputs')
args=parser.parse_args()
roots=['bin','lib','assets','shell','systemd','tests','tools']
names=['README.md','ARCHITECTURE.md','CHANGELOG.md','VALIDATION.md',
       'SECURITY.md','SECURITY_AUDIT.md','LICENSE','VERSION','template.yaml',
       'install.sh','.gitignore','.gitattributes']
files=[root/n for n in names if (root/n).is_file()]
for name in roots:
    for p in (root/name).rglob('*'):
        if p.is_symlink(): raise SystemExit(f'Refusing symlink: {p.relative_to(root)}')
        if p.is_file() and '__pycache__' not in p.parts and p.suffix not in ('.pyc','.log','.pem','.key') and not any(x.startswith('.') for x in p.relative_to(root).parts):
            files.append(p)
files=sorted(files)
(root/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n' for p in files))
files.append(root/'SHA256SUMS')
version=(root/'VERSION').read_text().strip(); name=f'mihomo-local-v{version}'
out=args.output_dir;out.mkdir(parents=True,exist_ok=True)
with tarfile.open(out/(name+'.tar.gz'),'w:gz') as tf:
    def clean_metadata(info):
        info.uid=info.gid=0
        info.uname=info.gname=''
        info.mtime=0
        info.pax_headers={}
        return info
    for p in sorted(files): tf.add(p,arcname=f'{name}/{p.relative_to(root)}',recursive=False,filter=clean_metadata)
with zipfile.ZipFile(out/(name+'.zip'),'w',zipfile.ZIP_DEFLATED) as z:
    for p in sorted(files):
        info=zipfile.ZipInfo(f'{name}/{p.relative_to(root)}',date_time=(1980,1,1,0,0,0))
        info.compress_type=zipfile.ZIP_DEFLATED
        info.external_attr=(0o100755 if p.stat().st_mode & 0o111 else 0o100644)<<16
        z.writestr(info,p.read_bytes())
for ext in ['.tar.gz','.zip']:
    p=out/(name+ext)
    print(hashlib.sha256(p.read_bytes()).hexdigest(),p)
