import sys, lupa.lua52 as L
script, kind, w, h = sys.argv[1:5]
rt = L.LuaRuntime(unpack_returned_tuples=True)
rt.execute("arg = {...}", script, kind, w, h)
src = open("harness.lua", encoding="utf-8").read()
rt.execute(src)
