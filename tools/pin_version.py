#!/usr/bin/env python3
"""Resolve one game version in the official manifest and print its client jar
URL, sha1 and size as shell assignments.

usage: tools/pin_version.py <version_manifest_v2.json> <version>

Exits 1 with a list of the newest releases when the version is not there, so a
moved or renamed version fails with something to pin instead of a stack trace.
"""
import json
import sys


def main() -> int:
    manifest, version = sys.argv[1], sys.argv[2]
    with open(manifest, "rb") as f:
        doc = json.load(f)
    versions = doc.get("versions", [])
    hit = next((v for v in versions if v.get("id") == version), None)
    if hit is None:
        print(f"version {version!r} is not in the manifest", file=sys.stderr)
        print("newest releases:", file=sys.stderr)
        releases = [v["id"] for v in versions if v.get("type") == "release"][:12]
        for v in releases:
            print("  ", v, file=sys.stderr)
        return 1
    print(f'MC_VERSION_ID={hit["id"]}')
    print(f'MC_VERSION_TYPE={hit["type"]}')
    print(f'MC_VERSION_URL={hit["url"]}')
    print(f'MC_VERSION_SHA1={hit["sha1"]}')
    print(f'MC_VERSION_TIME={hit.get("releaseTime", "")}')
    print(f'MC_MANIFEST_URL={doc.get("_url", "")}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
