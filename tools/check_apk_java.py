#!/usr/bin/env python3
"""Check that the APK carries the Java the game-files screen needs.

The app is a NativeActivity with no Java of its own except org.umbra.client.UmbraNet,
which exists for the two things the NDK cannot do: an HTTPS download of the client
jar (there is no TLS client in the NDK) and the document picker, whose answer arrives
through onActivityResult() -- a callback android.app.NativeActivity does not implement.

An APK can look complete without it: the native libraries are all there, the manifest
parses, and the app runs, draws and passes its self-test while both buttons on the
"get game files" screen do nothing. That is exactly the failure this gate catches, and
it is a file-based check because no device test can be trusted to notice a button that
is drawn but not wired up.

usage: tools/check_apk_java.py <apk>
Exit 0 when the dex holds the class and the manifest names it, 1 when it does not.
"""
import re
import sys
import zipfile


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    apk = sys.argv[1]
    problems = []
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        dex = sorted(n for n in names if n.startswith("classes") and n.endswith(".dex"))
        if not dex:
            problems.append("the APK has no classes.dex at all")
        # A dex store the strings it references: the class name and its methods are
        # in there whether or not the class was stripped.
        blob = b"".join(z.read(n) for n in dex)
        for needle in (b"UmbraNet", b"UmbraNet$UmbraActivity", b"pickAndCopy",
                       b"progressGot"):
            if needle not in blob:
                problems.append("%s is not in the dex" % needle.decode())
        # The manifest has to point at the subclass: NativeActivity cannot receive
        # onActivityResult, so the picker would return to nothing.
        manifest = z.read("AndroidManifest.xml") if "AndroidManifest.xml" in names else b""
        try:
            text = manifest.decode("utf-16-le", "ignore") + manifest.decode("utf-8", "ignore")
        except Exception:
            text = ""
        if "UmbraActivity" not in text:
            problems.append("AndroidManifest.xml does not name UmbraNet$UmbraActivity")
        if "android.permission.INTERNET" not in text:
            problems.append("AndroidManifest.xml does not ask for INTERNET, so the download "
                            "would fail with a SecurityException")
        print("apk-java: dex %s, %d bytes of strings" % (" ".join(dex), len(blob)))
    if problems:
        for p in problems:
            print("::error title=apk-java::%s" % p)
            print("FAIL: %s" % p)
        return 1
    print("PASS apk-java: UmbraNet and its activity are in the APK, and the manifest "
          "names it with the network permission")
    return 0


if __name__ == "__main__":
    sys.exit(main())
