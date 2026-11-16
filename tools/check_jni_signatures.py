#!/usr/bin/env python3
"""Check the JNI method descriptors in android_main.c against UmbraNet.java.

A JNI signature is a string, so nothing type-checks it: a wrong one compiles, ships,
and fails on the device with `GetStaticMethodID` returning NULL. That is exactly what
happened on run 43956343069 -- `pickAndCopy(Activity, String, String[])` was asked for
as `(Landroid/app/Activity;Ljava/lang/String;Ljava/lang/String;)J`, the lookup for the
whole class was abandoned, and the app told the owner there was "no Java network class
in this APK" on an APK that has it.

There is no javac here, so this reads the Java source directly: every
`public [static] T name(args)` becomes its descriptor, and every
GetStaticMethodID/GetMethodID pair in android_main.c must name a method that exists
with exactly that descriptor.

Usage: tools/check_jni_signatures.py            # exit 0 when they all agree
"""
import re
import sys

JAVA = "android/app/src/main/java/org/umbra/client/UmbraNet.java"
NATIVE = "platform/android/android_main.c"

PRIMITIVES = {
    "void": "V", "boolean": "Z", "byte": "B", "char": "C", "short": "S",
    "int": "I", "long": "J", "float": "F", "double": "D",
}


JAVA_LANG = {"String", "Object", "Class", "ClassLoader", "CharSequence"}


def descriptor(java_name, imports=()):
    """JNI type descriptor for a Java type written in source form.

    Source uses simple names (`String`, `Activity`) and the descriptor needs fully
    qualified ones (`Ljava/lang/String;`, `Landroid/app/Activity;`), so the file's
    own imports are used to expand them. java.lang needs no import.
    """
    if java_name in PRIMITIVES:
        return PRIMITIVES[java_name]
    dims = 0
    while java_name.endswith("[]"):
        dims += 1
        java_name = java_name[:-2]
    if java_name in PRIMITIVES:
        base = PRIMITIVES[java_name]
    else:
        full = java_name
        if "." not in java_name:
            if java_name in imports:
                full = imports[java_name]
            elif java_name in JAVA_LANG:
                full = "java.lang." + java_name
        base = "L" + full.replace(".", "/") + ";"
    return "[" * dims + base


IMPORTS = {}


def java_methods(text):
    """{name: (descriptor, arity)} for every method declared in the class."""
    imports = {}
    for m in re.finditer(r"^import\s+([\w.]+);", text, re.M):
        full = m.group(1)
        imports[full.rsplit(".", 1)[-1]] = full
    found = {}
    # public/protected/private [static] Ret name(Type a, Type b) {
    pat = re.compile(
        r"^\s*(?:public|protected|private)\s+(?:static\s+)?(?:final\s+)?"
        r"([\w.\[\]]+)\s+(\w+)\s*\(([^)]*)\)\s*\{", re.M)
    for m in pat.finditer(text):
        ret, name, params = m.group(1), m.group(2), m.group(3).strip()
        types = []
        if params:
            for p in params.split(","):
                parts = p.strip().split()
                if len(parts) < 2:
                    continue  # a malformed parameter is not this tool's business
                # Drop the parameter name and any annotations.
                types.append(parts[-2])
        desc = "(" + "".join(descriptor(t, imports) for t in types) + ")" + descriptor(ret, imports)
        found[name] = (desc, len(types))
    return found


def native_lookups(text):
    """[(method, signature, line)] for lookups against UmbraNet itself.

    Lookups against other classes (Window, Intent, ClassLoader) are inherited or
    framework methods and are not declared in the file; they are out of scope.
    """
    out = []
    pat = re.compile(
        r"Get(?:Static)?MethodID\s*\(\s*env,\s*(\w+),\s*\"(\w+)\"\s*,\s*\"([^\"]+)\"",
        re.S)
    for m in pat.finditer(text):
        if m.group(1) != "g_umbra_net":
            continue
        line = text[:m.start()].count("\n") + 1
        out.append((m.group(2), m.group(3), line))
    return out


def main():
    try:
        java = open(JAVA, encoding="utf-8").read()
        native = open(NATIVE, encoding="utf-8").read()
    except OSError as e:
        print(f"check_jni_signatures: cannot read: {e}", file=sys.stderr)
        return 1
    methods = java_methods(java)
    if not methods:
        print(f"check_jni_signatures: no methods parsed out of {JAVA}", file=sys.stderr)
        return 1
    bad = 0
    checked = 0
    for name, sig, line in native_lookups(native):
        if name not in methods:
            print(f"{NATIVE}:{line}: {name} is not a method of UmbraNet", file=sys.stderr)
            bad += 1
            continue
        want = methods[name][0]
        checked += 1
        if sig != want:
            print(f"{NATIVE}:{line}: {name} is looked up as {sig} "
                  f"but {JAVA} declares {want}", file=sys.stderr)
            bad += 1
    # One table, not two: JNI_OnLoad ran before the device proved it is never
    # called, and its copy of the table kept a stale signature after the fix.
    if native.count("GetStaticMethodID(env, g_umbra_net") > 5:
        print(f"check_jni_signatures: {NATIVE} looks the UmbraNet methods up in more "
              "than one place; the table has to be the one net_init uses",
              file=sys.stderr)
        return 1
    if checked == 0:
        print("check_jni_signatures: no method lookups found; the C changed shape",
              file=sys.stderr)
        return 1
    if bad:
        print(f"check_jni_signatures: {bad} of {checked + bad} lookups disagree "
              f"with {JAVA}", file=sys.stderr)
        return 1
    print(f"check_jni_signatures: {checked} JNI lookups match {JAVA}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
