#!/usr/bin/env python3
"""Write a version manifest and a version JSON shaped like Mojang's own.

Not a copy of the real files: the point is that the game-files flow's parser is
held to the structure the real manifest has (latest, versions[] with id/type/url/
time/releaseTime/sha1, downloads.client with size/sha1/url) without this repository
containing any of Mojang's data, and without the test needing a network.

The version JSON's own sha1 is computed here and put in the manifest, so the flow's
"does the manifest name the pinned version, and is the JSON the one it names" check
has a right answer to find.

usage: tools/make_test_manifest.py <manifest out> <version.json out>
"""
import hashlib
import json
import sys

PIN_SIZE = 41483720
PIN_SHA1 = "e877b6a07acd633fb3bb475002175cec036e7b87"
VERSION = "26.3"


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    version_path, manifest_path = sys.argv[2], sys.argv[1]
    version = {
        "downloads": {
            "client": {
                "size": PIN_SIZE,
                "sha1": PIN_SHA1,
                "url": "https://piston-data.mojang.com/v1/objects/%s/client.jar" % PIN_SHA1,
            }
        }
    }
    body = json.dumps(version).encode()
    with open(version_path, "wb") as f:
        f.write(body)
    manifest = {
        "latest": {"release": VERSION, "snapshot": VERSION},
        "versions": [
            {
                "id": "1.20",
                "type": "release",
                "url": "https://example.invalid/1.20.json",
                "time": "2023-06-12T00:00:00+00:00",
                "releaseTime": "2023-06-12T00:00:00+00:00",
                "sha1": "0" * 40,
            },
            {
                "id": VERSION,
                "type": "release",
                "url": "https://example.invalid/%s.json" % VERSION,
                "time": "2026-09-15T11:23:02+00:00",
                "releaseTime": "2026-09-15T11:23:02+00:00",
                "sha1": hashlib.sha1(body).hexdigest(),
            },
        ],
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f)
    print("manifest: %s names %s, whose version json hashes to %s"
          % (manifest_path, VERSION, hashlib.sha1(body).hexdigest()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
