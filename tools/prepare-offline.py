#!/usr/bin/env python3
"""Run on a connected preparation machine, never on the offline installer.
Fetch pinned official releases, verify asset digests, preserve provenance and
licenses, and include exact corresponding source archives for redistribution.
Requires Python 3 and curl; no Python SSL module is used.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--arch',choices=['amd64','arm64'],required=True)
p.add_argument('--output-dir',type=Path,required=True)
a=p.parse_args()
root=a.output_dir.resolve()
if root.exists() and any(root.iterdir()):p.error('output directory must be empty')
root.mkdir(parents=True,exist_ok=True)
versions={'mihomo':'v1.19.33','yq':'v4.54.2'}
repos={'mihomo':'MetaCubeX/mihomo','yq':'mikefarah/yq'}

def download(url,target):
    if not url.startswith(('https://api.github.com/','https://github.com/','https://raw.githubusercontent.com/')):
        raise ValueError('unexpected source host')
    target.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['curl','-fsSL','--proto','=https','--proto-redir','=https','--connect-timeout','10','--max-time','300','--retry','2',url,'-o',str(target)],check=True)

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def api(path):
    with tempfile.TemporaryDirectory(prefix='mlocal-meta-') as d:
        f=Path(d)/'api.json';download('https://api.github.com/'+path,f)
        return json.loads(f.read_text())

def commit_for(repo,tag):
    obj=api(f'repos/{repo}/git/ref/tags/{tag}')['object']
    for _ in range(4):
        if obj['type']=='commit':
            if not re.fullmatch('[0-9a-f]{40}',obj['sha']):raise ValueError('invalid commit')
            return obj['sha']
        if obj['type']!='tag':break
        obj=api(f'repos/{repo}/git/tags/'+obj['sha'])['object']
    raise ValueError('tag does not resolve to a commit')

manifest={'architecture':a.arch,'binaries':{},'sources':{}}
for name in ['mihomo','yq']:
    repo=repos[name];tag=versions[name]
    release=api(f'repos/{repo}/releases/tags/{tag}')
    if release['draft'] or release['prerelease'] or release['tag_name']!=tag:raise ValueError('not a stable pinned release')
    asset_name=(f'mihomo-linux-amd64-v1-{tag}.gz' if a.arch=='amd64' else f'mihomo-linux-arm64-{tag}.gz') if name=='mihomo' else 'yq_linux_'+a.arch
    matches=[x for x in release['assets'] if x['name']==asset_name]
    if len(matches)!=1:raise ValueError('missing/ambiguous asset')
    asset=matches[0];digest=asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest):raise ValueError('no official asset SHA256')
    url=asset['browser_download_url']
    if not url.startswith(f'https://github.com/{repo}/releases/download/{tag}/'):raise ValueError('unexpected asset URL')
    binary=root/'bin'/name
    with tempfile.TemporaryDirectory(prefix='mlocal-download-') as d:
        compressed=Path(d)/'asset';download(url,compressed)
        if sha(compressed)!=digest[7:]:raise ValueError('asset digest mismatch')
        binary.parent.mkdir(parents=True,exist_ok=True)
        binary.write_bytes(gzip.decompress(compressed.read_bytes()) if name=='mihomo' else compressed.read_bytes())
    data=binary.read_bytes()
    if data[:6]!=b'\x7fELF\x02\x01' or int.from_bytes(data[18:20],'little')!={'amd64':62,'arm64':183}[a.arch]:
        raise ValueError('binary architecture mismatch')
    binary.chmod(0o755)
    manifest['binaries'][name]={'version':tag,'file':'bin/'+name,'sha256':sha(binary),'asset':asset_name,'asset_sha256':digest[7:],'url':url}
    commit=commit_for(repo,tag)
    license_path=root/'licenses'/(name+'-LICENSE')
    download(f'https://raw.githubusercontent.com/{repo}/{commit}/LICENSE',license_path)
    source_path=root/'sources'/(name+'.tar.gz')
    source_url=f'https://api.github.com/repos/{repo}/tarball/{commit}'
    download(source_url,source_path)
    manifest['sources'][name]={'commit':commit,'url':source_url,'file':'sources/'+name+'.tar.gz','sha256':sha(source_path),'license':'GPL-3.0' if name=='mihomo' else 'MIT'}
(root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(root/'SOURCES.md').write_text('''# Bundled upstream binaries and corresponding sources

See manifest.json for pinned versions, exact commits, official asset digests,
binary digests and source URLs. licenses/ contains each upstream license.
sources/ contains the corresponding complete upstream source archives,
including build files, go.mod/go.sum and upstream build workflows. Follow those
upstream instructions to rebuild; builds may require Go module dependencies.
Mihomo is GPL-3.0; yq is MIT. The project's MIT license does not relicense them.
This directory is prepared on a connected machine, then included in the
architecture-specific release. The server installer never downloads these files.
''')
(root/'SHA256SUMS').write_text(''.join(f'{sha(f)}  {f.relative_to(root)}\n' for f in sorted(root.rglob('*')) if f.is_file() and f.name!='SHA256SUMS'))
print('Prepared verified offline vendor directory:',root)
