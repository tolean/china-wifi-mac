import base64
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from make_config import build_config, parse_key, read_key  # noqa: E402

MAKE_CONFIG = str(Path(__file__).resolve().parents[1] / "make_config.py")


def b64(s: str) -> str:
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


class ParseKeyTests(unittest.TestCase):
    def test_ss_sip002_base64_userinfo(self):
        key = "ss://" + b64("chacha20-ietf-poly1305:testpass") + "@1.2.3.4:8388#China"
        self.assertEqual(parse_key(key), {"type": "shadowsocks", "server": "1.2.3.4",
            "server_port": 8388, "method": "chacha20-ietf-poly1305", "password": "testpass"})

    def test_ss_sip002_percent_encoded_userinfo(self):
        out = parse_key("ss://2022-blake3-aes-128-gcm:p%40ss@h.example:443")
        self.assertEqual((out["method"], out["password"], out["server_port"]),
                         ("2022-blake3-aes-128-gcm", "p@ss", 443))

    def test_ss_legacy_whole_base64(self):
        out = parse_key("ss://" + b64("aes-256-gcm:pw@5.6.7.8:9000"))
        self.assertEqual((out["server"], out["server_port"]), ("5.6.7.8", 9000))

    def test_ss_plugin_rejected(self):
        with self.assertRaises(ValueError):
            parse_key("ss://" + b64("aes-256-gcm:pw") + "@1.1.1.1:1?plugin=obfs")

    def test_vless_reality(self):
        out = parse_key("vless://11111111-2222-3333-4444-555555555555@example.com:443"
            "?security=reality&sni=www.apple.com&fp=chrome&pbk=PUBKEY&sid=ab12&type=tcp&flow=xtls-rprx-vision")
        self.assertEqual(out["type"], "vless"); self.assertEqual(out["flow"], "xtls-rprx-vision")
        self.assertEqual(out["tls"]["reality"], {"enabled": True, "public_key": "PUBKEY", "short_id": "ab12"})
        self.assertEqual(out["tls"]["utls"], {"enabled": True, "fingerprint": "chrome"})
        self.assertEqual(out["tls"]["server_name"], "www.apple.com")

    def test_trojan_ws_defaults_to_tls(self):
        out = parse_key("trojan://pw@example.com:443?type=ws&path=%2Fws&host=cdn.example#t")
        self.assertTrue(out["tls"]["enabled"]); self.assertEqual(out["tls"]["server_name"], "cdn.example")
        self.assertEqual(out["transport"], {"type": "ws", "path": "/ws", "headers": {"Host": "cdn.example"}})

    def test_unknown_scheme(self):
        with self.assertRaises(ValueError):
            parse_key("http://x")


class FileAndCliTests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmpdir.name)

    def tearDown(self):
        self._tmpdir.cleanup()

    def test_read_key_strips_bom_crlf_and_comments(self):
        p = self.tmp / "china-key.txt"
        p.write_bytes(b"\xef\xbb\xbf# comment\r\n\r\nss://abc@1.2.3.4:1#n\r\n")
        self.assertEqual(read_key(p), "ss://abc@1.2.3.4:1#n")

    def test_build_config_shape(self):
        cfg = build_config({"type": "direct"})
        self.assertEqual([i["listen_port"] for i in cfg["inbounds"]], [7892, 2080])
        self.assertEqual(cfg["outbounds"][0]["tag"], "proxy"); self.assertNotIn("output", cfg["log"])

    def test_cli_writes_config_0600(self):
        (self.tmp / "china-key.txt").write_text("ss://" + b64("aes-128-gcm:x") + "@1.2.3.4:9\n")
        r = subprocess.run([sys.executable, "-I", MAKE_CONFIG, "--secrets", str(self.tmp)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr); self.assertIn("OK: shadowsocks → 1.2.3.4:9", r.stdout)
        self.assertEqual(stat.S_IMODE((self.tmp / "car-vpn.json").stat().st_mode), 0o600)

    def test_cli_unwritable_secrets_dir_prints_one_line(self):
        (self.tmp / "china-key.txt").write_text("ss://" + b64("aes-128-gcm:x") + "@1.2.3.4:9\n")
        os.chmod(self.tmp, 0o500)
        try:
            r = subprocess.run([sys.executable, "-I", MAKE_CONFIG, "--secrets", str(self.tmp)], capture_output=True, text=True)
        finally:
            os.chmod(self.tmp, 0o700)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("Traceback", r.stderr); self.assertIn("car-vpn.json", r.stderr)

    def test_cli_missing_key_file(self):
        r = subprocess.run([sys.executable, "-I", MAKE_CONFIG, "--secrets", str(self.tmp)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn("china-key.txt", r.stderr)


if __name__ == "__main__":
    unittest.main()
