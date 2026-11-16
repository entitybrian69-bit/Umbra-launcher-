#!/usr/bin/env python3
"""Send one command to a Minecraft server over RCON and print its answer.

usage: tools/rcon.py <host> <port> <password> <command...>

Why this exists: the server only writes its region files when it stops *cleanly*, and
SIGTERM does not do that for the vanilla server - the run this replaces was killed with
exit status 143 in the middle of "Saving chunks for level ..." and left `world/level.dat`
and no regions at all. `stop` over RCON is the documented way to ask it to shut down, and
the packet format is small enough to implement here rather than depend on a library.

Exit status: 0 when the command was sent (a `stop` closes the connection before it can
answer, which is success), 1 when the connection or the login failed.
"""
import socket
import struct
import sys
import time

AUTH = 3
COMMAND = 2


def packet(request_id, kind, body):
    payload = struct.pack("<ii", request_id, kind) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_exactly(sock, count):
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise EOFError("the server closed the connection")
        buf += chunk
    return buf


def read_packet(sock):
    (length,) = struct.unpack("<i", read_exactly(sock, 4))
    data = read_exactly(sock, length)
    request_id, kind = struct.unpack("<ii", data[:8])
    return request_id, kind, data[8:-2].decode("utf-8", "replace")


def main(argv):
    if len(argv) < 5:
        print(__doc__.strip(), file=sys.stderr)
        return 1
    host, port, password = argv[1], int(argv[2]), argv[3]
    command = " ".join(argv[4:])
    deadline = time.time() + 30.0
    sock = None
    while time.time() < deadline:
        try:
            sock = socket.create_connection((host, port), timeout=5.0)
            break
        except OSError as exc:
            last = exc
            time.sleep(1.0)
    if sock is None:
        print(f"rcon: cannot reach {host}:{port}: {last}", file=sys.stderr)
        return 1
    sock.settimeout(10.0)
    try:
        sock.sendall(packet(1, AUTH, password))
        request_id, _, _ = read_packet(sock)
        if request_id == -1:
            print("rcon: the password was refused", file=sys.stderr)
            return 1
        sock.sendall(packet(2, COMMAND, command))
        request_id, _, body = read_packet(sock)
        if body:
            print(body)
        return 0
    except EOFError:
        # `stop` closes the connection instead of answering, which is the point.
        return 0
    except OSError as exc:
        print(f"rcon: {exc}", file=sys.stderr)
        return 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
