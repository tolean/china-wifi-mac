#!/usr/bin/env python3
"""Turn a proxy key into a sing-box config for car-vpn.sh (key mode only).

Reads  <secrets>/china-key.txt  — one line: ss://, ssconf://, vless:// or trojan://
Writes <secrets>/car-vpn.json   — mode 0600, it contains the password.

The Monkey mode does not use this file: car-vpn.sh copies config.monkey.json.
"""
import argparse
import base64
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REDIRECT_PORT = 7892
TEST_PORT = 2080
B64_CHARS = re.compile(r"[A-Za-z0-9+/_=-]+")


def _b64decode(s: str) -> str:
    s = urllib.parse.unquote(s)
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode("utf-8")


def _split_userinfo(userinfo: str) -> tuple[str, str]:
    """SIP002 userinfo: base64("method:password") or percent-encoded "method:password".

    b64decode silently drops characters outside its alphabet, so a plain
    "method:pass" could "decode" into garbage; only treat it as base64 when it
    looks like base64 *and* yields a method:password pair.
    """
    decoded = None
    if B64_CHARS.fullmatch(userinfo):
        try:
            candidate = _b64decode(userinfo)
            if ":" in candidate:
                decoded = candidate
        except (ValueError, UnicodeDecodeError):
            decoded = None
    if decoded is None:
        decoded = urllib.parse.unquote(userinfo)
    if ":" not in decoded:
        raise ValueError("ss://: не нашёл method:password")
    method, password = decoded.split(":", 1)
    return method, password


def _hostport(hostport: str) -> tuple[str, int]:
    host, port = hostport.rsplit(":", 1)
    return host.strip("[]"), int(port)


def parse_ss(url: str) -> dict:
    body = url[len("ss://"):].split("#", 1)[0]
    body, _, query = body.partition("?")
    if "plugin=" in query:
        raise ValueError("ss:// с plugin= не поддерживается")
    if "@" in body:
        userinfo, hostport = body.rsplit("@", 1)
        method, password = _split_userinfo(userinfo)
    else:  # legacy: base64("method:password@host:port")
        userinfo, hostport = _b64decode(body).rsplit("@", 1)
        method, password = userinfo.split(":", 1)
    host, port = _hostport(hostport)
    return {"type": "shadowsocks", "server": host, "server_port": port,
            "method": method, "password": password}


def parse_ssconf(url: str) -> dict:
    # Outline dynamic key: ssconf://host/path -> https://host/path returns JSON or ss://
    target = "https://" + url[len("ssconf://"):].split("#", 1)[0]
    with urllib.request.urlopen(target, timeout=15) as r:
        text = r.read().decode().strip()
    if text.startswith("ss://"):
        return parse_ss(text)
    d = json.loads(text)
    return {"type": "shadowsocks", "server": d["server"], "server_port": int(d["server_port"]),
            "method": d["method"], "password": d["password"]}


def _tls_and_transport(q: dict, hostname: str) -> dict:
    out = {}
    security = q.get("security", "none")
    if security in ("tls", "reality"):
        tls = {"enabled": True, "server_name": q.get("sni") or q.get("host") or hostname}
        if q.get("fp"):
            tls["utls"] = {"enabled": True, "fingerprint": q["fp"]}
        if q.get("alpn"):
            tls["alpn"] = q["alpn"].split(",")
        if security == "reality":
            tls["reality"] = {"enabled": True, "public_key": q.get("pbk", ""),
                              "short_id": q.get("sid", "")}
            tls.setdefault("utls", {"enabled": True, "fingerprint": "chrome"})
        out["tls"] = tls
    net = q.get("type", "tcp")
    if net == "ws":
        t = {"type": "ws", "path": q.get("path", "/")}
        if q.get("host"):
            t["headers"] = {"Host": q["host"]}
        out["transport"] = t
    elif net == "grpc":
        out["transport"] = {"type": "grpc", "service_name": q.get("serviceName", "")}
    elif net not in ("tcp", ""):
        raise ValueError(f"транспорт type={net} не поддерживается")
    return out


def _userhost(url: str) -> tuple[str, str, int, dict]:
    u = urllib.parse.urlsplit(url)
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
    if not u.hostname or u.port is None:
        raise ValueError("в ключе нет host:port")
    return urllib.parse.unquote(u.username or ""), u.hostname, u.port, q


def parse_vless(url: str) -> dict:
    uuid, host, port, q = _userhost(url)
    ob = {"type": "vless", "server": host, "server_port": port, "uuid": uuid}
    if q.get("flow"):
        ob["flow"] = q["flow"]
    ob.update(_tls_and_transport(q, host))
    return ob


def parse_trojan(url: str) -> dict:
    password, host, port, q = _userhost(url)
    q.setdefault("security", "tls")
    ob = {"type": "trojan", "server": host, "server_port": port, "password": password}
    ob.update(_tls_and_transport(q, host))
    return ob


PARSERS = {"ss://": parse_ss, "ssconf://": parse_ssconf,
           "vless://": parse_vless, "trojan://": parse_trojan}


def parse_key(key: str) -> dict:
    for prefix, parser in PARSERS.items():
        if key.startswith(prefix):
            return parser(key)
    raise ValueError("ключ должен начинаться с ss://, ssconf://, vless:// или trojan://")


def read_key(path: Path) -> str:
    text = path.read_bytes().decode("utf-8-sig")
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    raise ValueError(f"в {path} нет ключа")


def build_config(outbound: dict) -> dict:
    return {
        "log": {"level": "info", "timestamp": True},
        "dns": {"servers": [{"type": "local", "tag": "local"}]},
        "inbounds": [
            {"type": "redirect", "tag": "car", "listen": "127.0.0.1", "listen_port": REDIRECT_PORT},
            {"type": "mixed", "tag": "test", "listen": "127.0.0.1", "listen_port": TEST_PORT},
        ],
        "outbounds": [{"tag": "proxy", **outbound}],
        "route": {"final": "proxy", "default_domain_resolver": "local"},
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--secrets", type=Path, default=Path(__file__).resolve().parent / "secrets",
                    help="папка с china-key.txt (по умолчанию secrets/ рядом со скриптом)")
    args = ap.parse_args(argv)
    key_file = args.secrets / "china-key.txt"
    out_file = args.secrets / "car-vpn.json"
    if not key_file.exists():
        print(f"Нет файла с ключом: {key_file}", file=sys.stderr)
        return 1
    try:
        outbound = parse_key(read_key(key_file))
    except (ValueError, OSError) as e:
        print(f"Не смог разобрать ключ: {e}", file=sys.stderr)
        return 1
    try:
        fd = os.open(out_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(build_config(outbound), f, indent=2)
        os.chmod(out_file, 0o600)
    except OSError as e:
        print(f"Не смог записать {out_file}: {e}", file=sys.stderr)
        return 1
    print(f"OK: {outbound['type']} → {outbound['server']}:{outbound['server_port']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
