#!/usr/bin/env python3
import os
import select
import socket
import sys
import time


def usage() -> None:
    print("usage: drive-serial.py SOCKET LOG COMMAND", file=sys.stderr)


def wait_for_socket(path: str, timeout: int = 60) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.2)
    raise TimeoutError(f"serial socket did not appear: {path}")


def main() -> int:
    if len(sys.argv) != 4:
        usage()
        return 2

    socket_path, log_path, command = sys.argv[1:]
    wait_for_socket(socket_path)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    sock.setblocking(False)

    login_sent = False
    command_sent = False
    buffer = ""
    deadline = time.time() + 8 * 60 * 60
    idle_deadline = time.time() + 30 * 60

    with open(log_path, "ab", buffering=0) as log:
        while time.time() < deadline and time.time() < idle_deadline:
            readable, _, _ = select.select([sock], [], [], 1.0)
            if not readable:
                continue

            try:
                data = sock.recv(4096)
            except BlockingIOError:
                continue

            if not data:
                return 0

            idle_deadline = time.time() + 30 * 60
            log.write(data)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

            text = data.decode("utf-8", errors="ignore")
            buffer = (buffer + text)[-4000:]

            if not login_sent and "archiso login:" in buffer:
                sock.sendall(b"root\n")
                login_sent = True
                continue

            if login_sent and not command_sent:
                if "root@archiso" in buffer or buffer.rstrip().endswith("#"):
                    sock.sendall((command + "\n").encode())
                    command_sent = True

    print("serial driver timed out", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
