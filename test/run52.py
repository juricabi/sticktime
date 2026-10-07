import sys, lupa.lua52 as L
script, kind, w, h = sys.argv[1:5]
harness = sys.argv[5] if len(sys.argv) > 5 else "harness.lua"
rt = L.LuaRuntime(unpack_returned_tuples=True)
if harness == "harness.lua":
    rt.execute("arg = {...}", script, kind, w, h)
else:  # lite_test.lua: script W H
    rt.execute("arg = {...}", script, w, h)
src = open(harness, encoding="utf-8").read()
rt.execute(src)
