#!/usr/bin/env python3
import ipaddress
import json
import os
from pathlib import Path
import queue
import select
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOMAIN = "cache.example.test"
TARGET = "remote.example.test"
LIB = None


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=30, **kwargs)


def evaluate(services, providers=None):
    payload = json.dumps({
        "services": services,
        "socksProviders": {"mock": {"enable": True}} if providers is None else providers,
    })
    expression = f'''
      let
        lib = import {json.dumps(str(LIB))};
        evaluated = lib.evalModules {{ modules = [
          {json.dumps(str(ROOT / "modules/common/mesh-services.nix"))}
          ({{ lib, ... }}: {{
            options.assertions = lib.mkOption {{ default = []; type = lib.types.listOf lib.types.attrs; }};
            options.beacoworks.mesh.socksProviders = lib.mkOption {{ type = lib.types.attrs; default = {{}}; }};
            config.beacoworks.mesh = builtins.fromJSON {json.dumps(payload)};
          }})
        ]; }};
        failed = builtins.filter (item: !item.assertion) evaluated.config.assertions;
      in if failed != [] then throw (lib.concatMapStringsSep "\\n" (item: item.message) failed)
         else evaluated.config.beacoworks.mesh.serviceRouting
    '''
    return run("nix", "eval", "--offline", "--impure", "--option", "allow-import-from-derivation", "false", "--builders", "", "--json", "--expr", expression)


def service(**overrides):
    value = {
        "enable": True,
        "provider": "mock",
        "domains": [DOMAIN],
        "port": 443,
        "target": {"address": TARGET, "port": 10443},
    }
    value.update(overrides)
    return value


def receive_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("unexpected end of stream")
        data += chunk
    return data


def receive_headers(sock):
    data = b""
    while not data.endswith(b"\r\n\r\n"):
        data += receive_exact(sock, 1)
        if len(data) > 16384:
            raise ValueError("oversized HTTP header")
    return data


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ThreadedServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class TLSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        with self.server.context.wrap_socket(self.request, server_side=True) as secured:
            headers = receive_headers(secured)
            self.server.requests.put(headers)
            secured.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")


class SOCKSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        incoming = self.request
        incoming.settimeout(5)
        version, count = receive_exact(incoming, 2)
        if version != 5 or 0 not in receive_exact(incoming, count):
            raise ValueError("expected SOCKS5 without authentication")
        incoming.sendall(b"\x05\x00")
        version, command, reserved, address_type = receive_exact(incoming, 4)
        if (version, command, reserved) != (5, 1, 0):
            raise ValueError("expected SOCKS5 CONNECT")
        if address_type == 3:
            address = receive_exact(incoming, receive_exact(incoming, 1)[0]).decode()
        elif address_type in (1, 4):
            size = 4 if address_type == 1 else 16
            address = str(ipaddress.ip_address(receive_exact(incoming, size)))
        else:
            raise ValueError("unexpected SOCKS address type")
        port = struct.unpack("!H", receive_exact(incoming, 2))[0]
        self.server.targets.put((address, port))
        with socket.create_connection(self.server.destination, timeout=5) as outgoing:
            incoming.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            while True:
                ready, _, _ = select.select([incoming, outgoing], [], [], 5)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (outgoing if source is incoming else incoming).sendall(data)


class ModuleTests(unittest.TestCase):
    def routing(self, services):
        result = evaluate(services)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def rejected(self, services, message, providers=None):
        result = evaluate(services, providers)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)

    def test_empty_and_disabled_services_do_not_change_routing(self):
        empty = {"needsFakeIP": False, "dnsRules": [], "inbounds": [], "routeRules": []}
        self.assertEqual(self.routing({}), empty)
        self.assertEqual(self.routing({"off": service(enable=False)}), empty)

    def test_domain_and_port_match_is_exact(self):
        fragments = self.routing({"cache": service(domains=[DOMAIN.upper()], port=8443)})
        rule, = fragments["routeRules"]
        self.assertEqual(rule["domain"], [DOMAIN])
        self.assertEqual(rule["port"], 8443)
        self.assertEqual(rule["network"], "tcp")
        self.assertEqual(rule["override_address"], TARGET)
        self.assertEqual(rule["override_port"], 10443)
        self.assertNotIn("domain_suffix", rule)
        self.assertEqual(fragments["dnsRules"][0]["domain"], [DOMAIN])
        self.routing({"one": service(port=443), "two": service(port=8443)})

    def test_provider_must_exist_and_be_enabled(self):
        for providers in ({}, {"mock": {"enable": False}}):
            with self.subTest(providers=providers):
                self.rejected({"cache": service()}, "enabled SOCKS provider", providers)

    def test_duplicate_domain_and_port_is_rejected(self):
        self.rejected({"one": service(), "two": service(domains=[DOMAIN.upper()])}, "only one mesh service")

    def test_listener_bindings_must_be_unique_and_loopback_only(self):
        local = {"address": "127.0.0.1", "port": 18443}
        self.rejected({"one": service(listen=local), "two": service(port=8443, listen=local)}, "unique loopback bindings")
        self.rejected({"cache": service(listen={"address": "0.0.0.0", "port": 18443})}, "127.0.0.1")

    def test_listener_cannot_bind_local_provider_but_can_share_remote_port(self):
        services = {"cache": service(listen={"port": 18443})}
        self.rejected(services, "local SOCKS provider", {"mock": {"enable": True, "server": "127.0.0.1", "port": 18443}})
        remote = evaluate(services, {"mock": {"enable": True, "server": "192.0.2.10", "port": 18443}})
        self.assertEqual(remote.returncode, 0, remote.stderr)

    def test_local_listener_does_not_require_domain_routing(self):
        fragments = self.routing({"cache": service(domains=[], listen={"port": 18443})})
        self.assertFalse(fragments["needsFakeIP"])
        self.assertEqual(fragments["dnsRules"], [])
        self.assertEqual(fragments["inbounds"][0]["listen"], "127.0.0.1")
        self.assertEqual(fragments["routeRules"][0]["inbound"], ["mesh-service-cache"])

    def test_recursive_and_local_targets_are_rejected(self):
        for address in (DOMAIN, DOMAIN.upper(), "localhost", "127.0.0.2", "::1", "https://remote.example.test"):
            with self.subTest(address=address):
                self.rejected({"cache": service(target={"address": address, "port": 443})}, "remote addresses distinct")

    def test_wildcard_and_non_dns_match_names_are_rejected(self):
        for domain in ("*.example.test", "https://cache.example.test", "cache.example.test:443"):
            with self.subTest(domain=domain):
                self.rejected({"cache": service(domains=[domain])}, "exact DNS names")


class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="mesh-services-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        cls.cert = cls.directory / "cert.pem"
        key = cls.directory / "key.pem"
        result = run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", f"/CN={DOMAIN}", "-addext", f"subjectAltName=DNS:{DOMAIN}", "-keyout", str(key), "-out", str(cls.cert))
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.tls = ThreadedServer(("127.0.0.1", 0), TLSHandler)
        cls.addClassCleanup(cls.tls.server_close)
        cls.tls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.tls.context.load_cert_chain(cls.cert, key)
        cls.tls.requests = queue.Queue()
        cls.tls.names = queue.Queue()
        cls.tls.context.set_servername_callback(lambda sock, name, context: cls.tls.names.put(name))
        cls.socks = ThreadedServer(("127.0.0.1", 0), SOCKSHandler)
        cls.addClassCleanup(cls.socks.server_close)
        cls.socks.destination = cls.tls.server_address
        cls.socks.targets = queue.Queue()
        for server in (cls.tls, cls.socks):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.addClassCleanup(server.shutdown)
        cls.mixed_port = unused_port()
        cls.loopback_port = unused_port()
        cls.dns_port = unused_port()
        cls.target_port = unused_port()
        result = evaluate({
            "a-shadow": service(port=cls.loopback_port, target={"address": "shadow.example.test", "port": cls.target_port}),
            "cache": service(listen={"port": cls.loopback_port}, target={"address": TARGET, "port": cls.target_port}),
        })
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.fragments = json.loads(result.stdout)
        cls.configuration = {
            "log": {"level": "debug"},
            "dns": {
                "servers": [
                    {"type": "udp", "tag": "unused", "server": "127.0.0.1", "server_port": 9},
                    {"type": "fakeip", "tag": "dns_fakeip", "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"},
                ],
                "rules": cls.fragments["dnsRules"],
                "final": "unused",
                "strategy": "ipv4_only",
            },
            "inbounds": [
                {"type": "mixed", "tag": "mixed", "listen": "127.0.0.1", "listen_port": cls.mixed_port},
                {"type": "direct", "tag": "dns", "network": "udp", "listen": "127.0.0.1", "listen_port": cls.dns_port},
            ] + cls.fragments["inbounds"],
            "outbounds": [{"type": "socks", "tag": "mesh-mock", "server": "127.0.0.1", "server_port": cls.socks.server_address[1]}],
            "route": {"rules": [{"inbound": ["dns"], "action": "hijack-dns"}, {"action": "sniff"}] + cls.fragments["routeRules"] + [{"action": "reject"}]},
        }
        config = cls.directory / "config.json"
        config.write_text(json.dumps(cls.configuration))
        result = run("sing-box", "check", "-c", str(config))
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.log = (cls.directory / "sing-box.log").open("w+")
        cls.addClassCleanup(cls.log.close)
        cls.process = subprocess.Popen(["sing-box", "run", "-c", str(config)], stdout=cls.log, stderr=cls.log)
        cls.addClassCleanup(cls.stop_process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.process.poll() is not None:
                cls.log.seek(0)
                raise RuntimeError(cls.log.read())
            try:
                with socket.create_connection(("127.0.0.1", cls.mixed_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.02)
        else:
            raise RuntimeError("sing-box did not open its local listener")

    @classmethod
    def stop_process(cls):
        if cls.process.poll() is None:
            cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=5)

    def tunnel(self, mode, port=443, domain=DOMAIN):
        sock = socket.create_connection(("127.0.0.1", self.loopback_port if mode == "loopback" else self.mixed_port), timeout=5)
        self.addCleanup(sock.close)
        if mode == "http":
            sock.sendall(f"CONNECT {domain}:{port} HTTP/1.1\r\nHost: {domain}:{port}\r\n\r\n".encode())
            self.assertIn(b" 200 ", receive_headers(sock).split(b"\r\n", 1)[0])
        elif mode == "socks":
            sock.sendall(b"\x05\x01\x00")
            self.assertEqual(receive_exact(sock, 2), b"\x05\x00")
            host = domain.encode()
            sock.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", port))
            reply = receive_exact(sock, 4)
            self.assertEqual(reply[1], 0, repr(reply))
            if reply[3] == 1:
                receive_exact(sock, 6)
            elif reply[3] == 4:
                receive_exact(sock, 18)
            else:
                receive_exact(sock, receive_exact(sock, 1)[0] + 2)
        return sock

    def test_tls_identity_survives_all_local_entrypoints(self):
        context = ssl.create_default_context(cafile=str(self.cert))
        for mode in ("http", "socks", "loopback"):
            with self.subTest(mode=mode):
                with context.wrap_socket(self.tunnel(mode), server_hostname=DOMAIN) as secured:
                    secured.sendall(f"GET /test HTTP/1.1\r\nHost: {DOMAIN}\r\nConnection: close\r\n\r\n".encode())
                    self.assertIn(b"200 OK", receive_headers(secured))
                    self.assertEqual(receive_exact(secured, 2), b"OK")
                self.assertEqual(self.socks.targets.get(timeout=2), (TARGET, self.target_port))
                self.assertEqual(self.tls.names.get(timeout=2), DOMAIN)
                self.assertIn(f"\r\nHost: {DOMAIN}\r\n".encode(), self.tls.requests.get(timeout=2))

    def test_loopback_target_wins_over_another_services_matching_sni_and_port(self):
        rules = self.fragments["routeRules"]
        self.assertEqual(rules[0]["inbound"], ["mesh-service-cache"])
        self.assertTrue(any(rule.get("domain") == [DOMAIN] and rule.get("port") == self.loopback_port for rule in rules[1:]))
        context = ssl.create_default_context(cafile=str(self.cert))
        with context.wrap_socket(self.tunnel("loopback"), server_hostname=DOMAIN) as secured:
            secured.sendall(f"GET /priority HTTP/1.1\r\nHost: {DOMAIN}\r\n\r\n".encode())
            self.assertIn(b"200 OK", receive_headers(secured))
            self.assertEqual(receive_exact(secured, 2), b"OK")
        self.assertEqual(self.socks.targets.get(timeout=2), (TARGET, self.target_port))
        self.assertEqual(self.tls.names.get(timeout=2), DOMAIN)
        self.assertIn(b"GET /priority ", self.tls.requests.get(timeout=2))

    def test_other_domains_and_ports_do_not_reach_provider(self):
        context = ssl.create_default_context(cafile=str(self.cert))
        for domain, port in ((DOMAIN, 444), ("other.example.test", 443), ("nested." + DOMAIN, 443)):
            with self.subTest(domain=domain, port=port):
                with self.assertRaises((ConnectionError, ssl.SSLError)):
                    with context.wrap_socket(self.tunnel("http", domain=domain, port=port), server_hostname=domain):
                        pass
                self.assertTrue(self.socks.targets.empty())

    def test_fakeip_dns_obeys_ipv4_only_for_a_and_aaaa(self):
        encoded_name = b"".join(bytes([len(label)]) + label.encode() for label in DOMAIN.split(".")) + b"\x00"
        for query_type in (1, 28):
            with self.subTest(query_type=query_type):
                packet = struct.pack("!6H", query_type, 0x0100, 1, 0, 0, 0) + encoded_name + struct.pack("!2H", query_type, 1)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(5)
                    sock.sendto(packet, ("127.0.0.1", self.dns_port))
                    response = sock.recv(4096)
                identifier, flags, _, answers, _, _ = struct.unpack("!6H", response[:12])
                self.assertEqual(identifier, query_type)
                self.assertEqual(flags & 15, 0)
                if query_type == 1:
                    self.assertEqual(answers, 1)
                    self.assertIn(ipaddress.ip_address(response[-4:]), ipaddress.ip_network("198.18.0.0/15"))
                else:
                    self.assertEqual(answers, 0, "AAAA fake-IP escapes hosts that exclude fc00::/7 from the TUN")


if __name__ == "__main__":
    for executable in ("nix", "sing-box", "openssl"):
        if not shutil.which(executable):
            raise SystemExit(f"missing required executable: {executable}")
    if os.environ.get("NIXPKGS_LIB"):
        LIB = Path(os.environ["NIXPKGS_LIB"])
    else:
        result = run("nix", "eval", "--offline", "--impure", "--option", "allow-import-from-derivation", "false", "--builders", "", "--raw", "--expr", f'(builtins.getFlake {json.dumps(str(ROOT))}).inputs.nixpkgs.outPath')
        if result.returncode:
            raise SystemExit(result.stderr)
        LIB = Path(result.stdout) / "lib"
    unittest.main(verbosity=2)
