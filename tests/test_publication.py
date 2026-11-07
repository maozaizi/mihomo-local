"""Public packages must not acquire developer credentials or follow symlinks."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

PACKAGE=Path(__file__).resolve().parents[1]

class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='mlocal-package-')
        self.root=Path(self.temp.name)
        self.source=self.root/'project'
        shutil.copytree(PACKAGE,self.source,ignore=shutil.ignore_patterns('.git','__pycache__','outputs','dist'))
        self.addCleanup(self.temp.cleanup)

    def test_private_unlisted_files_are_not_packaged(self):
        (self.source/'.env').write_text('DEMO_EXCLUDED_FILE')
        (self.source/'private-backup.txt').write_text('DEMO_EXCLUDED_BACKUP')
        (self.source/'.git').mkdir();(self.source/'.git/config').write_text('DEMO_EXCLUDED_GIT')
        out=self.root/'out'
        p=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--output-dir',str(out)],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        with tarfile.open(next(out.glob('*.tar.gz'))) as tf:
            for member in tf.getmembers():
                self.assertEqual((member.uid,member.gid,member.uname,member.gname,member.mtime),(0,0,'','',0))
        with zipfile.ZipFile(next(out.glob('*.zip'))) as z:
            names={n.split('/',1)[1] for n in z.namelist()}
            self.assertNotIn('.env',names);self.assertNotIn('.git/config',names);self.assertNotIn('private-backup.txt',names)
            self.assertIn('LICENSE',names);self.assertIn('.gitignore',names)
            for line in z.read(next(n for n in z.namelist() if n.endswith('/SHA256SUMS'))).decode().splitlines():
                digest,relative=line.split('  ',1)
                prefix=next(iter(z.namelist())).split('/',1)[0]
                self.assertEqual(hashlib.sha256(z.read(prefix+'/'+relative)).hexdigest(),digest)

    def make_vendor(self):
        vendor=self.root/'vendor';(vendor/'bin').mkdir(parents=True)
        (vendor/'licenses').mkdir();(vendor/'sources').mkdir()
        binary=bytearray(64);binary[:6]=b'\x7fELF\x02\x01';binary[18]=183
        for name in ['mihomo','yq']:
            p=vendor/'bin'/name;p.write_bytes(binary);p.chmod(0o755)
            (vendor/'licenses'/(name+'-LICENSE')).write_text('Synthetic fixture license')
            (vendor/'sources'/(name+'.tar.gz')).write_bytes(b'Synthetic source fixture')
        meta={'architecture':'arm64','binaries':{n:{'sha256':hashlib.sha256(binary).hexdigest()} for n in ['mihomo','yq']}}
        (vendor/'manifest.json').write_text(json.dumps(meta))
        (vendor/'SOURCES.md').write_text('Synthetic fixture provenance')
        (vendor/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(vendor)}\n' for p in sorted(vendor.rglob('*')) if p.is_file() and p.name!='SHA256SUMS'))
        return vendor

    def test_offline_bundle_contains_verified_binaries_and_sources(self):
        vendor=self.make_vendor();out=self.root/'out'
        r=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--vendor-dir',str(vendor),'--output-dir',str(out)],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        archive=next(out.glob('*-linux-arm64.zip'))
        with zipfile.ZipFile(archive) as z:
            prefix=z.namelist()[0].split('/',1)[0]+'/'
            for name in ['bin/mihomo','bin/yq','sources/mihomo.tar.gz','licenses/mihomo-LICENSE']:
                self.assertEqual(z.read(prefix+'vendor/'+name),(vendor/name).read_bytes())
            for row in z.read(prefix+'SHA256SUMS').decode().splitlines():
                digest,name=row.split('  ',1)
                self.assertEqual(hashlib.sha256(z.read(prefix+name)).hexdigest(),digest)
        self.assertNotIn('vendor/',(self.source/'SHA256SUMS').read_text())

    def test_corrupt_offline_vendor_is_not_packaged(self):
        vendor=self.make_vendor();(vendor/'bin/mihomo').write_bytes(b'corrupted')
        r=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--vendor-dir',str(vendor),'--output-dir',str(self.root/'out')],capture_output=True,text=True)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('checksum mismatch',r.stderr)

    def test_source_symlink_is_rejected(self):
        (self.source/'assets/escaped.yaml').symlink_to(self.root/'outside')
        p=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--output-dir',str(self.root/'out')],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('Refusing symlink',p.stderr)

    def test_root_document_symlink_is_rejected(self):
        (self.root/'private').write_text('DEMO_PRIVATE_UNLISTED')
        (self.source/'README.md').unlink()
        (self.source/'README.md').symlink_to(self.root/'private')
        p=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--output-dir',str(self.root/'out')],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('Refusing symlink',p.stderr)

if __name__=='__main__':unittest.main()
