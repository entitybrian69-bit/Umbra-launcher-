#!/usr/bin/env python3
"""Print the server jar download (url, sha1, size) from a version JSON.

usage: tools/pin_server.py <version.json>

Like `pin_client.py`, but for downloads.server: the same version JSON names both jars,
and the server is the one that can generate a world to read.
"""
import json
import sys


def main() -> int:
    with open(sys.argv[1], "rb") as f:
        doc = json.load(f)
    server = (doc.get("downloads") or {}).get("server")
    if not server:
        print("version JSON has no downloads.server", file=sys.stderr)
        return 1
    java = (doc.get("javaVersion") or {}).get("majorVersion", "")
    print(f'MC_SERVER_URL="{server["url"]}"')
    print(f'MC_SERVER_SHA1="{server["sha1"]}"')
    print(f'MC_SERVER_SIZE="{server["size"]}"')
    print(f'MC_SERVER_JAVA="{java}"')
    return 0


if __name__ == "__main__":
    sys.exit(main())
