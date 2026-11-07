"""Real-core policy tests, entirely on loopback: no Internet or router access.

Local HTTP proxy stubs identify the selected exit. A local DNS stub maps
unlisted names to a loopback web server, exercising IP fallback resolution.
Production DNS endpoints are replaced only in the test configuration.
"""
import http.server
import json
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.parse import quote
from test_server import PACKAGE, CORE as MIHOMO, YQ


class Dns(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        i = 12
        while data[i]:
            i += data[i] + 1
        i += 1
        qend = i + 4
        qtype = struct.unpack('!H', data[i:i+2])[0]
        answer = (b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4) + socket.inet_aton('127.0.0.1')) if qtype == 1 else b''
        response = data[:2] + struct.pack('!HHHHH', 0x8180, 1, bool(answer), 0, 0) + data[12:qend] + answer
        sock.sendto(response, self.client_address)


def handler(label):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = label.encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_CONNECT(self):
            # Mihomo's HTTP outbound uses CONNECT even for plain HTTP.
            # Answer the tunnel locally, then identify this synthetic exit.
            self.connection.settimeout(3)
            self.send_response(200, 'Connection established')
            self.end_headers()
            self.wfile.flush()
            try:
                request = self.rfile.readline()
                if not request.startswith(b'GET '):
                    return
                while self.rfile.readline().strip():
                    pass
                body = label.encode()
                self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode()
                                 + b'\r\nConnection: close\r\n\r\n' + body)
                self.wfile.flush()
            except (OSError, TimeoutError):
                pass
        def log_message(self, *args):
            pass
    return Handler


class TemplateRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nlocal-template-')
        self.root = Path(self.temp.name)
        self.servers = []
        self.core = None
        self.log = None
        self.ports = set()
        self.backends = {}
        for label in ['GENERAL', 'AI', 'TIKTOK', 'DIRECT']:
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler(label))
            self.servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.backends[label] = server.server_address[1]
        dns = socketserver.UDPServer(('127.0.0.1', 0), Dns)
        self.servers.append(dns)
        threading.Thread(target=dns.serve_forever, daemon=True).start()
        self.dns = '127.0.0.1:' + str(dns.server_address[1])
        self.config = json.loads(subprocess.check_output([YQ, 'e', '-o=json', '.', str(PACKAGE/'template.yaml')]))
        self.config.update({'mixed-port': self.port(), 'bind-address': '127.0.0.1', 'ipv6': False,
                            'external-controller': '127.0.0.1:' + str(self.port()), 'secret': 'synthetic',
                            'log-level': 'error'})
        self.config.pop('external-ui', None)
        self.config.pop('external-ui-url', None)
        self.config['dns'] = {'enable': True, 'listen': '127.0.0.1:' + str(self.port()), 'ipv6': False,
                              'enhanced-mode': 'redir-host', 'nameserver': [self.dns],
                              'default-nameserver': [self.dns], 'direct-nameserver': [self.dns],
                              'proxy-server-nameserver': [self.dns]}
        self.config['sniffer'] = {'enable': False}
        fixtures = {'lan': ('classical', ['IP-CIDR,10.0.0.0/8,no-resolve']),
                    'cn-domain': ('classical', ['DOMAIN-SUFFIX,known-cn.test']),
                    'cn-ipv4': ('ipcidr', ['127.0.0.0/8']), 'cn-ip': ('ipcidr', ['127.0.0.0/8']),
                    'ai-foreign': ('domain', ['+.remote-ai.test']), 'tiktok': ('domain', ['+.remote-tiktok.test'])}
        for name, (behavior, payload) in fixtures.items():
            self.config['rule-providers'][name] = {'type': 'inline', 'behavior': behavior, 'payload': payload}
        for name, provider in self.config['proxy-providers'].items():
            provider['path'] = str(self.root/(name+'.json'))
            provider['health-check']['enable'] = False
            nodes = ([{'name': label, 'type': 'http', 'server': '127.0.0.1', 'port': self.backends[label]}
                      for label in ['GENERAL', 'AI', 'TIKTOK']] if name == 'subscriptions'
                     else [{'name': '__mihomo_local_empty__', 'type': 'reject'}])
            Path(provider['path']).write_text(json.dumps({'proxies': nodes}))
        self.api = 'http://' + self.config['external-controller']
        self.addCleanup(self.clean)

    def port(self):
        while True:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                value = sock.getsockname()[1]
            if value not in self.ports:
                self.ports.add(value)
                return value

    def clean(self):
        if self.core:
            self.core.terminate()
            self.core.wait(10)
        if self.log:
            self.log.close()
        for server in self.servers:
            server.shutdown()
            server.server_close()
        self.temp.cleanup()

    def call(self, path, payload=None):
        args = ['/usr/bin/curl', '--noproxy', '*', '-fsS', '--max-time', '3', '-H',
                'Authorization: Bearer synthetic', self.api + path]
        if payload is not None:
            args += ['-X', 'PUT', '-H', 'Content-Type: application/json', '-d', json.dumps(payload)]
        return subprocess.run(args, capture_output=True, text=True)

    def start(self):
        cfg = self.root/'config.json'
        cfg.write_text(json.dumps(self.config, ensure_ascii=False))
        self.log = (self.root/'core.log').open('w')
        self.core = subprocess.Popen([MIHOMO, '-d', str(self.root), '-f', str(cfg)], stdout=self.log, stderr=self.log)
        for _ in range(60):
            if self.call('/version').returncode == 0:
                break
            time.sleep(.05)
        else:
            self.fail((self.root/'core.log').read_text())
        # /version may respond before configuration/provider loading finishes.
        for _ in range(60):
            result = self.call('/proxies/' + quote('手动选择', safe=''))
            if result.returncode == 0:
                break
            time.sleep(.05)
        else:
            self.fail((self.root/'core.log').read_text())
        for group, exit_name in [('手动选择', 'GENERAL'), ('AI服务', 'AI'), ('TikTok', 'TIKTOK')]:
            self.select(group, exit_name)

    def select(self, group, name):
        result = self.call('/proxies/' + quote(group, safe=''), {'name': name})
        self.assertEqual(result.returncode, 0, result.stderr)

    def fetch(self, domain, port=80):
        return subprocess.run(['/usr/bin/curl', '--noproxy', '', '-sS', '--max-time', '4', '--proxy',
                               'http://127.0.0.1:' + str(self.config['mixed-port']),
                               f'http://{domain}:{port}/policy-test'], capture_output=True, text=True)

    def test_services_keep_independent_exits_and_remote_supplements(self):
        self.start()
        for domain, expected in [('api.openai.com', 'AI'), ('claude.ai', 'AI'), ('remote-ai.test', 'AI'),
                                 ('www.tiktok.com', 'TIKTOK'), ('remote-tiktok.test', 'TIKTOK')]:
            self.assertEqual(self.fetch(domain).stdout, expected, domain)
        self.select('手动选择', 'TIKTOK')
        self.assertEqual(self.fetch('api.openai.com').stdout, 'AI')
        self.assertEqual(self.fetch('www.tiktok.com').stdout, 'TIKTOK')

    def test_domestic_ip_fallback_resolves_a_domain_missing_from_domain_rules(self):
        # Exercise the dual-stack supplement as well as the earlier IPv4 set.
        self.config['rule-providers']['cn-ipv4']['payload'] = ['192.0.2.0/24']
        self.start()
        self.assertEqual(self.fetch('unlisted.test', self.backends['DIRECT']).stdout, 'DIRECT')

    def test_no_resolve_control_would_send_the_same_domain_to_general_proxy(self):
        self.config['rules'] = [r + ',no-resolve' if r in ('RULE-SET,cn-ipv4,DIRECT', 'RULE-SET,cn-ip,DIRECT') else r
                                for r in self.config['rules']]
        self.start()
        self.assertEqual(self.fetch('unlisted.test', self.backends['DIRECT']).stdout, 'GENERAL')

    def test_empty_service_groups_reject_instead_of_falling_back_to_direct(self):
        self.start()
        for name, sentinel in [('subscriptions', '__mihomo_local_empty__')]:
            Path(self.config['proxy-providers'][name]['path']).write_text(json.dumps({'proxies': [{'name': sentinel, 'type': 'reject'}]}))
            self.assertEqual(self.call('/providers/proxies/' + name, {}).returncode, 0)
        for group, domain in [('AI服务', 'api.openai.com'), ('TikTok', 'www.tiktok.com')]:
            info = json.loads(self.call('/proxies/' + quote(group, safe='')).stdout)
            self.assertEqual(info['all'], ['REJECT'])
            self.assertNotEqual(self.fetch(domain, self.backends['DIRECT']).stdout, 'DIRECT')


if __name__ == '__main__':
    unittest.main()
