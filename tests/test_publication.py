"""Public packages must not acquire developer credentials or follow symlinks."""
import hashlib
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

    def test_source_symlink_is_rejected(self):
        (self.source/'assets/escaped.yaml').symlink_to(self.root/'outside')
        p=subprocess.run([sys.executable,str(self.source/'tools/package.py'),'--output-dir',str(self.root/'out')],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0)
        self.assertIn('Refusing symlink',p.stderr)

if __name__=='__main__':unittest.main()
