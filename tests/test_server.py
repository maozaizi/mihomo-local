"""Linux integration: real sh, flock, timeout, yq and running Mihomo.
Only subscription HTTPS downloads/failure injection are simulated. All sockets
are loopback and the container can run with --network=none.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

PACKAGE = Path(__file__).resolve().parents[1]
YQ = os.environ.get('MLOCAL_TEST_YQ', '/usr/local/bin/yq')
CORE = os.environ.get('MLOCAL_TEST_CORE', '/usr/local/bin/mihomo')


def feed(*names, protocol='ss'):
    proxies=[]
    for n in names:
        p={'name':n,'type':protocol,'server':'127.0.0.1','port':39999,'password':'TEST_ONLY_NOT_A_SECRET'}
        if protocol=='ss': p['cipher']='aes-128-gcm'
        proxies.append(p)
    return json.dumps({'proxies':proxies,'tun':{'enable':True},'rules':['MATCH,REJECT']})


def snapshot(path):
    result={}
    for p in path.rglob('*'):
        if p.is_symlink(): result[str(p.relative_to(path))]=('link',os.readlink(p))
        elif p.is_file(): result[str(p.relative_to(path))]=hashlib.sha256(p.read_bytes()).hexdigest()
    return result


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='mlocal-test-')
        self.root=Path(self.tmp.name); self.bin=self.root/'bin'; self.bin.mkdir()
        self.feeds=self.root/'feeds';self.feeds.mkdir()
        self.fault=self.root/'fault'; self.marker=self.root/'refresh'
        self.env=dict(os.environ, MLOCAL_ROOT=str(self.root), MIHOMO_LOCAL_LIB=str(PACKAGE),
                      MLOCAL_PATH=f'{self.bin}:/usr/local/bin:/usr/bin:/bin',
                      ML_TEST_FEEDS=str(self.feeds),ML_TEST_FAULT=str(self.fault),ML_TEST_MARKER=str(self.marker))
        self.write_exe('curl', '''#!/usr/bin/python3
import os,pathlib,subprocess,sys
args=sys.argv[1:]; config=pathlib.Path(args[args.index('--config')+1]) if '--config' in args else None
text=config.read_text() if config else ''
if text.startswith('url = "https://feeds.test/'):
    name=text.split('https://feeds.test/',1)[1].split('"',1)[0]
    if name == 'fallback' and 'proxy = "http://127.0.0.1:7890"' not in text: sys.exit(6)
    file=pathlib.Path(os.environ['ML_TEST_FEEDS'])/name
    if not file.is_file(): sys.exit(22)
    sys.stdout.buffer.write(file.read_bytes()); sys.exit(0)
fault=pathlib.Path(os.environ['ML_TEST_FAULT'])
if '-X' in args and args[args.index('-X')+1]=='PUT':
    pathlib.Path(os.environ['ML_TEST_MARKER']).touch()
    if fault.exists():
        mode=fault.read_text()
        if mode=='once': fault.unlink();sys.exit(22)
        if mode=='always': sys.exit(22)
        if mode=='kill': fault.unlink();os.kill(os.getppid(),9);sys.exit(0)
sys.exit(subprocess.call(['/usr/bin/curl',*args]))
''')
        self.core=None
        r=self.call('init'); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.config=self.root/'etc/mihomo-local/config.yaml'
        # Test may run concurrently with host services: unique controller port.
        with socket.socket() as sock: sock.bind(('127.0.0.1',0)); self.port=sock.getsockname()[1]
        self.env['MLOCAL_API']=f'http://127.0.0.1:{self.port}'
        self.runtime=self.root/'var/lib/mihomo-local/core'
        config=self.yaml_json(self.config)
        config.pop('mixed-port');config['external-controller']=f'127.0.0.1:{self.port}'
        # The canonical config keeps the strict production boundary. Only this
        # test copy changes controller address, so core auth still reads canonical.
        self.testcfg=self.root/'core-test.json';self.testcfg.write_text(json.dumps(config))
        self.corelog=open(self.root/'core.log','w')
        self.core=subprocess.Popen([CORE,'-d',str(self.runtime),'-f',str(self.testcfg)],stdout=self.corelog,stderr=self.corelog)
        for _ in range(100):
            r=self.call('doctor')
            if r.returncode==0: break
            if self.core.poll() is not None: self.fail((self.root/'core.log').read_text())
            time.sleep(.05)
        else:self.fail(r.stdout+r.stderr)

    def tearDown(self):
        if self.core:
            self.core.terminate();self.core.wait(10);self.corelog.close()
        self.tmp.cleanup()

    def write_exe(self,name,text):
        p=self.bin/name;p.write_text(text);p.chmod(0o755)

    def yaml_json(self,path):
        return json.loads(subprocess.check_output([YQ,'-o=json','.',str(path)]))

    def call(self,*args,timeout=150):
        return subprocess.run([str(PACKAGE/'bin/mihomo-local'),*args],env=self.env,capture_output=True,text=True,timeout=timeout)

    def add(self,name,body):
        (self.feeds/name).write_text(body)
        r=self.call('sub','add',f'https://feeds.test/{name}')
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        return r

    def names(self):
        path=self.runtime/'providers/subscriptions.yaml'
        return [p['name'] for p in self.yaml_json(path)['proxies']]

    def test_multiple_sources_update_remove_rollback_and_template_preserved(self):
        before=self.config.read_bytes()
        self.add('a',feed('same','a2'));self.add('b',feed('same','b2'))
        self.assertEqual(self.names(),['[s0001] same','[s0001] a2','[s0002] same','[s0002] b2'])
        (self.feeds/'a').write_text(feed('a-new','a2'));(self.feeds/'b').write_text(feed('b-new','b2'))
        self.assertEqual(self.call('update').returncode,0)
        self.assertIn('[s0002] b-new',self.names())
        self.assertEqual(self.call('sub','remove','s0001').returncode,0)
        self.assertEqual(len(self.names()),2)
        self.assertEqual(self.call('rollback').returncode,0)
        self.assertEqual(len(self.names()),4)
        self.assertEqual(self.config.read_bytes(),before)
        self.assertIsNone(self.core.poll())

    def test_upstream_failure_partial_update_and_drop_protection(self):
        self.add('a',feed('a1','a2','a3','a4'));self.add('b',feed('b1'))
        (self.feeds/'a').write_text(feed('a1'));(self.feeds/'b').write_text(feed('b2'))
        r=self.call('update');self.assertEqual(r.returncode,2,r.stdout+r.stderr)
        self.assertEqual(len(self.names()),5);self.assertIn('[s0002] b2',self.names())
        self.assertEqual(self.call('update','--force').returncode,0)
        self.assertEqual(len(self.names()),2)
        (self.feeds/'a').unlink();(self.feeds/'b').write_text(feed('b3'))
        self.assertEqual(self.call('update').returncode,2)
        self.assertIn('[s0001] a1',self.names());self.assertIn('[s0002] b3',self.names())

    def test_failed_publish_restores_old_provider_and_registry(self):
        self.add('a',feed('original'));self.fault.write_text('once')
        r=self.call('sub','add','https://feeds.test/missing')
        self.assertNotEqual(r.returncode,0)
        (self.feeds/'b').write_text(feed('new'))
        r=self.call('sub','add','https://feeds.test/b')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.names(),['[s0001] original'])
        self.assertEqual(self.call('doctor').returncode,0)
        self.assertNotIn('s0002 /',self.call('sub','list').stdout)

    def test_read_queries_never_recover_pending(self):
        self.add('a',feed('original'))
        store=self.root/'var/lib/mihomo-local/state/subscriptions'
        old=os.readlink(store/'current');(store/'pending').write_text(old+'\n\n')
        before=snapshot(self.root/'var/lib/mihomo-local/state')
        for command in [('sub','list'),('status',),('doctor',),('logs',)]: self.call(*command)
        self.assertEqual(snapshot(self.root/'var/lib/mihomo-local/state'),before)
        self.assertEqual(self.call('sub','recover').returncode,0)
        self.assertFalse((store/'pending').exists())

    def test_writer_lock_rejects_concurrent_mutation(self):
        lock=self.root/'var/lib/mihomo-local/state/operation.lock'
        import fcntl
        with lock.open('w') as f:
            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
            r=self.call('update');self.assertNotEqual(r.returncode,0)
        self.assertEqual(self.call('doctor').returncode,0)

    def test_native_base64_keeps_all_six_nodes_and_counts(self):
        uri='vless://11111111-2222-4333-8444-555555555555@127.0.0.1:443?security=tls&sni=example.com#'
        text='\n'.join(uri+f'N{i}' for i in range(6))
        r=self.add('links',base64.b64encode(text.encode()).decode())
        self.assertEqual(len(self.names()),6)
        self.assertIn('vless 6',r.stdout)

    def test_local_source_re_read_and_duplicate_address_rejected(self):
        local=self.root/'input.yaml';local.write_text(feed('first'))
        self.assertEqual(self.call('sub','add',str(local)).returncode,0)
        self.assertNotEqual(self.call('sub','add',str(local)).returncode,0)
        local.write_text(feed('second'))
        self.assertEqual(self.call('update').returncode,0)
        self.assertEqual(self.names(),['[s0001] second'])

    def test_forbidden_network_config_rejected_before_publication(self):
        self.add('a',feed('old'))
        cfg=self.yaml_json(self.config)
        for key,val in [('tun',{'enable':False}),('listeners',[{'type':'tun','name':'x'}]),('redir-port',1234)]:
            modified=dict(cfg);modified[key]=val;self.config.write_text(json.dumps(modified))
            r=self.call('update');self.assertNotEqual(r.returncode,0)
            self.assertEqual(self.names(),['[s0001] old'])
        self.config.write_text(json.dumps(cfg))

    def test_killed_writer_recovers_before_next_mutation(self):
        self.add('a',feed('old'))
        (self.feeds/'b').write_text(feed('new'))
        self.fault.write_text('kill')
        r=self.call('sub','add','https://feeds.test/b')
        self.assertNotEqual(r.returncode,0)
        store=self.root/'var/lib/mihomo-local/state/subscriptions'
        self.assertTrue((store/'pending').exists())
        # A query reports the pending state, it must not roll it back.
        self.assertNotEqual(self.call('sub','list').returncode,0)
        self.assertEqual(self.call('sub','recover').returncode,0)
        self.assertEqual(self.names(),['[s0001] old'])
        self.assertEqual(self.call('doctor').returncode,0)

    def test_direct_download_failure_retries_local_proxy(self):
        self.add('fallback',feed('via-proxy'))
        self.assertEqual(self.names(),['[s0001] via-proxy'])

    def test_oversized_feed_preserves_existing_nodes(self):
        self.add('a',feed('old'))
        (self.feeds/'a').write_text('x'*(8*1024*1024+1))
        r=self.call('update');self.assertEqual(r.returncode,2)
        self.assertIn('8 MiB',r.stdout)
        self.assertEqual(self.names(),['[s0001] old'])

    def test_aggregate_cap_rejects_without_losing_existing_source(self):
        self.add('a',feed(*(f'a{i}' for i in range(2050))))
        (self.feeds/'b').write_text(feed(*(f'b{i}' for i in range(2050))))
        r=self.call('sub','add','https://feeds.test/b')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('4096',r.stderr)
        self.assertEqual(len(self.names()),2050)

    def test_skipped_protocol_is_visible_and_parse_timeout_is_bounded(self):
        uri='vless://11111111-2222-4333-8444-555555555555@127.0.0.1:443?security=tls#Good'
        r=self.add('a',uri+'\nunknown://example.com#Unsupported\n')
        self.assertIn('跳过',r.stdout)
        self.assertEqual(len(self.names()),1)
        # Exercise the real caller's timeout exit handling, not a two-minute wait.
        self.write_exe('timeout', '#!/bin/sh\nif [ "$2" = sh ]; then exit 124; fi\nexec /usr/bin/timeout "$@"\n')
        r=self.call('update');self.assertEqual(r.returncode,2)
        self.assertIn('超时',r.stdout)
        self.assertEqual(len(self.names()),1)

    def test_parser_failure_and_protocol_disappearance_preserve_nodes(self):
        self.add('a',feed('a1','a2'))
        (self.feeds/'a').write_text(feed('a1','a2',protocol='trojan'))
        self.assertEqual(self.call('update').returncode,2)
        (self.feeds/'a').write_text('proxies: invalid')
        self.assertEqual(self.call('update').returncode,2)
        self.assertEqual(self.names(),['[s0001] a1','[s0001] a2'])


class ShellTests(unittest.TestCase):
    def run_shell(self,shell,script,check=0):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'bin').mkdir()
            fake=root/'bin/mihomo-proxy'
            fake.write_text('''#!/bin/sh
case "$1" in check) [ "${FAIL_CHECK:-0}" = 0 ];; persist) mkdir -p "$XDG_STATE_HOME/mihomo-proxy"; printf '%s\\n' "$2" > "$XDG_STATE_HOME/mihomo-proxy/state";; *) exit 0;; esac
''');fake.chmod(0o755)
            env=dict(os.environ,HOME=d,XDG_STATE_HOME=d+'/state',PATH=f'{root}/bin:/usr/bin:/bin')
            for k in ['http_proxy','https_proxy','HTTP_PROXY','HTTPS_PROXY','no_proxy','NO_PROXY']:env.pop(k,None)
            body=f'. {PACKAGE}/shell/mihomo-proxy.sh\n'+script
            r=subprocess.run([shell,'-ic',body],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(r.returncode,check,r.stdout+r.stderr)

    def test_bash_and_zsh_restore_exact_values_and_repeated_on(self):
        for shell in ['bash','zsh']:
            self.run_shell(shell,'''export http_proxy='http://old:123'; export https_proxy=''; export no_proxy='example.com'
mihomo-proxy on || exit 10
[ "$http_proxy" = http://127.0.0.1:7890 ] || exit 11
mihomo-proxy on || exit 12
mihomo-proxy off || exit 13
[ "$http_proxy" = http://old:123 ] || exit 14
[ "${https_proxy+x}" = x ] && [ "$https_proxy" = '' ] || exit 15
[ "${HTTP_PROXY+x}" = '' ] || exit 16
[ "$no_proxy" = example.com ] || exit 17
''')

    def test_failed_check_does_not_enable_or_persist(self):
        for shell in ['bash','zsh']:
            self.run_shell(shell,'''export FAIL_CHECK=1
mihomo-proxy on && exit 10
[ "${http_proxy+x}" = '' ] || exit 11
[ ! -f "$XDG_STATE_HOME/mihomo-proxy/state" ] || exit 12
exit 0
''')

    def test_saved_state_loads_and_off_unsets_inherited_owned_values(self):
        for shell in ['bash','zsh']:
            self.run_shell(shell,f'''mkdir -p "$XDG_STATE_HOME/mihomo-proxy"
printf 'on\\n' > "$XDG_STATE_HOME/mihomo-proxy/state"
export http_proxy=http://127.0.0.1:7890
. {PACKAGE}/shell/mihomo-proxy.sh
[ "$https_proxy" = http://127.0.0.1:7890 ] || exit 10
mihomo-proxy off || exit 11
[ "${{http_proxy+x}}" = '' ] || exit 12
''')


if __name__=='__main__':unittest.main(verbosity=2)

