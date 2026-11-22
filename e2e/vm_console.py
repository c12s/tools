#!/usr/bin/env python3
"""Run a shell command inside a libvirt VM through its serial console.

Used by the end-to-end test scripts: the nested VM fleet has no SSH keys
injected (the Star reconciler seed only carries node.env), but the console
auto-logs-in with the NoCloud debug user c12s/c12s.

Usage (on the libvirt host, e.g. via ssh):
    python3 vm_console.py <libvirt-domain> <base64-encoded-command> [timeout]

The command is base64-encoded so quoting survives the ssh round trip.
Output between the __C12S_BEGIN__/__C12S_END__ markers is printed to stdout.
"""

import base64
import os
import pty
import select
import signal
import sys
import time


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    domain = sys.argv[1]
    command = base64.b64decode(sys.argv[2]).decode()
    timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 90.0

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("sudo", ["sudo", "virsh", "console", "--force", domain])

    buf = b""
    deadline = time.time() + timeout

    def read_until(marker: bytes, extra: float) -> bool:
        nonlocal buf
        end = min(deadline, time.time() + extra)
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.3)
            if fd in ready:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    return False
                if not data:
                    return False
                buf += data
                if marker in buf:
                    return True
        return False

    try:
        os.write(fd, b"\x15")  # Ctrl-U: clear any pending line from a stale session

        def login_once() -> bool:
            nonlocal buf
            buf = b""
            # virsh console may show a blank screen until the first input
            os.write(fd, b"\n")
            read_until(b"login:", 10)
            if b"login:" not in buf:
                # maybe already at a shell prompt
                os.write(fd, b"\n")
                read_until(b"$", 5)
            if b"login:" in buf:
                os.write(fd, b"c12s\n")
                read_until(b"Password:", 10)
                os.write(fd, b"c12s\n")
                read_until(b"$", 20)
                return b"$" in buf and b"Login incorrect" not in buf
            return b"$" in buf

        if not login_once() and not login_once():
            print("vm_console: login failed", file=sys.stderr)
            return 1

        marker_begin = b"__C12S_BEGIN__"
        marker_end = b"__C12S_END__"
        buf = b""
        os.write(fd, b"echo " + marker_begin + b"; " + command.encode() + b"; echo " + marker_end + b"\n")

        # the terminal echoes the command line first (BEGIN..END), then the
        # command actually runs and prints BEGIN..END again: wait for the
        # second END before parsing
        end = min(deadline, time.time() + timeout)
        while buf.count(marker_end) < 2 and time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.3)
            if fd in ready:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                buf += data

        text = buf.decode(errors="replace")
        # the terminal echoes the command line (markers included), so anchor on
        # the LAST begin marker: the first one is just the echo
        begin = text.rfind("__C12S_BEGIN__")
        if begin >= 0:
            rest = text[begin + len("__C12S_BEGIN__"):]
            if "__C12S_END__" in rest:
                print(rest.split("__C12S_END__", 1)[0].strip("\r\n"))
                return 0
        print("vm_console: no marker in output:", file=sys.stderr)
        print(text[-500:], file=sys.stderr)
        return 1
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
