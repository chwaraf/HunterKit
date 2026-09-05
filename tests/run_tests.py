#!/usr/bin/env python3
"""Run the HunterKit Lua tests.

The addon is plain Lua, so the tests run the real .lua files against a stub of the
WoW client API (tests/wow_stub.lua) instead of re-implementing anything.

    python3 tests/run_tests.py            # needs `lua` on PATH, or `pip install lupa`
    python3 tests/run_tests.py --verbose  # also echo the addon's chat output
"""
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TESTS = [
    os.path.join(HERE, "test_mendmark.lua"),
    os.path.join(HERE, "test_options_ui.lua"),
    os.path.join(HERE, "test_settings.lua"),
    os.path.join(HERE, "test_ammobuy.lua"),
    os.path.join(HERE, "test_threatwatch.lua"),
    os.path.join(HERE, "test_docs.lua"),
]


def addon_files():
    """Root-level .lua files, in .toc order where possible (tests/ excluded)."""
    on_disk = {os.path.basename(p): p for p in glob.glob(os.path.join(ROOT, "*.lua"))}
    order = []
    with open(os.path.join(ROOT, "HunterKit.toc"), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.endswith(".lua") and not line.startswith("##"):
                if line in on_disk:
                    order.append(on_disk.pop(line))
    order.extend(sorted(on_disk.values()))       # anything the .toc forgot
    return ["../" + os.path.basename(p) for p in order]


def lua_prelude(files, verbose):
    lines = [
        'dofile("wow_stub.lua")',
        "HKTest.echo = %s" % ("true" if verbose else "false"),
        "HKTest.addonFiles = { %s }" % ", ".join('"%s"' % f for f in files),
    ]
    return "\n".join(lines)


def run_with_lua(binary, files, verbose):
    runner = "\n".join(
        [lua_prelude(files, verbose)]
        + ['dofile("%s")' % os.path.basename(t) for t in TESTS]
    )
    proc = subprocess.run([binary, "-"], input=runner, text=True, cwd=HERE,
                          capture_output=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    return proc.returncode


def run_with_lupa(files, verbose):
    try:
        import lupa  # type: ignore
    except ImportError:
        return None
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(lua_prelude(files, verbose))
    # NOTE: do not replace `print` here — the stub wraps the interpreter's print
    # and collects the addon's chat output into HKTest.prints for assertions.
    try:
        for t in TESTS:
            lua.globals().dofile(os.path.relpath(t, HERE))
    except Exception as exc:  # noqa: BLE001 - report the Lua error verbatim
        print("TEST ERROR: %s" % exc)
        return 1
    return 0


def main():
    verbose = "--verbose" in sys.argv
    os.chdir(HERE)             # the stub loadfiles its inputs relative to tests/
    files = addon_files()
    for binary in ("lua", "lua5.1", "luajit", "lua5.4"):
        if shutil.which(binary):
            return run_with_lua(binary, files, verbose)
    code = run_with_lupa(files, verbose)
    if code is None:
        print("No Lua interpreter found. Install lua5.1 or run `pip install lupa`.")
        return 2
    return code


if __name__ == "__main__":
    sys.exit(main())
