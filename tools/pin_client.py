#!/usr/bin/env python3
"""Print the client jar download (url, sha1, size) from a version JSON.

usage: tools/pin_client.py <version.json>

The manifest entry's own `sha1` covers the version JSON, not the jar; the jar's
identity is in downloads.client, and that is what this prints.
"""
import json
import sys


def main() -> int:
    with open(sys.argv[1], "rb") as f:
        doc = json.load(f)
    dl = doc.get("downloads") or {}
    client = dl.get("client")
    if not client:
        print("version JSON has no downloads.client", file=sys.stderr)
        return 1
    print(f'MC_CLIENT_URL={client["url"]}')
    print(f'MC_CLIENT_SHA1={client["sha1"]}')
    print(f'MC_CLIENT_SIZE={client["size"]}')
    print(f'MC_ID={doc.get("id", "")}')
    print(f'MC_JAVA={doc.get("javaVersion", {}).get("majorVersion", "")}')
    assets = doc.get("assetIndex") or {}
    print(f'MC_ASSET_INDEX={assets.get("id", "")} {assets.get("sha1", "")} {assets.get("size", 0)}')
    print(f'MC_ASSET_INDEX_URL={assets.get("url", "")}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
