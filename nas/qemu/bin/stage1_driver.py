#!/usr/bin/env python3
"""Drive QEMU stage1: wait for prompts, send input. Replaces fixed sleeps."""
import subprocess, sys, time, threading, os

HTTP_PORT = os.environ.get("HTTP_PORT", "18080")
QEMU_CMD = sys.argv[1:]
INSTALL_LOG = os.environ.get("INSTALL_LOG", "/tmp/install.log")

def main():
    proc = subprocess.Popen(
        QEMU_CMD,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    log = open(INSTALL_LOG, "w", buffering=1)
    output_buf = b""
    login_sent = False
    curl_sent = False

    def reader():
        nonlocal output_buf
        while True:
            chunk = proc.stdout.read(1024)
            if not chunk:
                break
            log.write(chunk.decode(errors="replace"))
            log.flush()
            output_buf += chunk
            if len(output_buf) > 100000:
                output_buf = output_buf[-50000:]

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    time.sleep(5)
    proc.stdin.write(b"e console=ttyS0,115200n8\n")
    proc.stdin.flush()

    deadline = time.time() + 300
    while time.time() < deadline and not login_sent:
        if b"archiso login:" in output_buf:
            time.sleep(2)
            proc.stdin.write(b"root\n")
            proc.stdin.flush()
            login_sent = True
            break
        time.sleep(1)

    if not login_sent:
        print("ERROR: never saw archiso login prompt", file=sys.stderr)
        proc.terminate()
        return 1

    output_buf = b""
    deadline = time.time() + 120
    while time.time() < deadline and not curl_sent:
        stripped = output_buf.rstrip()
        if stripped.endswith(b"#"):
            time.sleep(1)
            cmd = "curl -fsSL http://10.0.2.2:" + HTTP_PORT + "/stage1.sh | QEMU_HTTP_PORT=" + HTTP_PORT + " bash\n"
            proc.stdin.write(cmd.encode())
            proc.stdin.flush()
            curl_sent = True
            break
        time.sleep(1)

    if not curl_sent:
        print("ERROR: never saw root shell prompt", file=sys.stderr)
        proc.terminate()
        return 1

    try:
        proc.wait(timeout=10800)
    except subprocess.TimeoutExpired:
        proc.terminate()
        return 1

    return proc.returncode

if __name__ == "__main__":
    sys.exit(main())
