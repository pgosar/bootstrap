#!/usr/bin/env python3
import http.client
import os
import subprocess
import sys
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "3004"))
PC_ML_URL = os.environ.get("PC_ML_URL", "http://pc:3003")
LOCAL_ML_URL = os.environ.get("LOCAL_ML_URL", "http://127.0.0.1:3003")
ENSURE_SCRIPT = os.environ.get(
    "ENSURE_SCRIPT", "/data/docker/compose/nightly-orchestrator/pc-worker-ensure.sh"
)
ENSURE_TIMEOUT = int(os.environ.get("ENSURE_TIMEOUT", "240"))
PC_CONNECT_TIMEOUT = int(os.environ.get("PC_CONNECT_TIMEOUT", "5"))
FALLBACK_TO_LOCAL = os.environ.get("FALLBACK_TO_LOCAL", "true").lower() == "true"
NIGHT_ONLY = os.environ.get("NIGHT_ONLY", "true").lower() == "true"
NIGHT_START = os.environ.get("NIGHT_START", "04:00")
NIGHT_END = os.environ.get("NIGHT_END", "10:00")

_ensure_lock = threading.Lock()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def split_target(url: str):
    parsed = urlsplit(url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return parsed.scheme, parsed.hostname, port


def healthcheck(url: str) -> bool:
    scheme, host, port = split_target(url)
    conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
    try:
        conn = conn_cls(host, port, timeout=PC_CONNECT_TIMEOUT)
        conn.request("GET", "/ping")
        resp = conn.getresponse()
        resp.read()
        return resp.status < 500
    except Exception:
        return False
    finally:
        try:
            conn.close()
        except Exception:
            pass


def minutes_since_midnight(value: str) -> int:
    hour, minute = value.split(":", 1)
    return int(hour) * 60 + int(minute)


def in_night_window() -> bool:
    if not NIGHT_ONLY:
        return True

    now_dt = datetime.now()
    now = now_dt.hour * 60 + now_dt.minute
    start = minutes_since_midnight(NIGHT_START)
    end = minutes_since_midnight(NIGHT_END)

    if start == end:
        return True
    if start < end:
        return start <= now < end
    return now >= start or now < end


def ensure_pc_ml() -> bool:
    if not in_night_window():
        return False
    if healthcheck(PC_ML_URL):
        return True
    with _ensure_lock:
        if healthcheck(PC_ML_URL):
            return True
        log("PC Immich ML endpoint unavailable; running pc-worker-ensure")
        try:
            subprocess.run(
                [ENSURE_SCRIPT],
                env={**os.environ, "CHECK_IMMICH_ML": "true", "IMMICH_ML_URL": PC_ML_URL},
                timeout=ENSURE_TIMEOUT,
                check=False,
            )
        except Exception as exc:
            log(f"pc-worker-ensure failed: {exc}")
        return healthcheck(PC_ML_URL)


def is_healthcheck_path(path: str) -> bool:
    return path.split("?", 1)[0] in {"/ping", "/health", "/healthcheck"}


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.proxy()

    def do_POST(self):
        self.proxy()

    def do_PUT(self):
        self.proxy()

    def do_PATCH(self):
        self.proxy()

    def do_DELETE(self):
        self.proxy()

    def proxy(self):
        target = LOCAL_ML_URL if is_healthcheck_path(self.path) else (PC_ML_URL if ensure_pc_ml() else LOCAL_ML_URL)
        if target == LOCAL_ML_URL and not FALLBACK_TO_LOCAL:
            self.send_error(503, "PC Immich ML endpoint unavailable")
            return

        scheme, host, port = split_target(target)
        conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in {"host", "connection"}}

        conn = conn_cls(host, port, timeout=300)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() not in {"transfer-encoding", "connection", "content-length"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            log(f"proxy request failed against {target}: {exc}")
            if target != LOCAL_ML_URL and FALLBACK_TO_LOCAL:
                self.proxy_to_local(body, headers)
            else:
                self.send_error(502, "ML proxy request failed")
        finally:
            conn.close()

    def proxy_to_local(self, body, headers):
        scheme, host, port = split_target(LOCAL_ML_URL)
        conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(host, port, timeout=300)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                if key.lower() not in {"transfer-encoding", "connection", "content-length"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            log(f"local ML fallback failed: {exc}")
            self.send_error(502, "Local ML fallback failed")
        finally:
            conn.close()

    def log_message(self, fmt, *args):
        log("%s - %s" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    log(f"Immich ML wake proxy listening on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()
