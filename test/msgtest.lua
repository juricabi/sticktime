-- A B&W loader where the game can't start, in tools/etxhost's radio mode: on EdgeTX 2.10's own
-- Lua (5.2, which can't read the 5.3 binary), or the full game on a radio with too little memory.
-- The loader must start anyway and say what to do on a screen of its own, in lines that fit a
-- 128 px screen (21 characters), and close on EXIT. Prints the screen's text and "MSG OK".
--
--   ETX_MODEL=f2 ETX_HEAP=63300 .tools/etxhost-v2.10.7 -radio test/msgtest.lua <loader.lua> "<text>" [W H]
local path, want, W, H = arg[1], arg[2], tonumber(arg[3] or 128), tonumber(arg[4] or 64)
local EXIT = 513                                   -- EVT_VIRTUAL_EXIT in the host's radio API

radio.new(W, H)
local root = string.match(path, "^(.*)/SCRIPTS/TOOLS/")
if root then radio.sdroot(root) end
local ok, err = radio.load(path)
local good, screen = false, ""
if ok then
  local ok1, r1 = radio.call("run", 0)
  local _, _, _, text = radio.lcd()
  screen = text or ""
  local ok2, r2 = radio.call("run", EXIT)
  good = ok1 and ok2 and r1 == 0 and r2 == 1 and string.find(screen, want, 1, true) ~= nil
  for line in string.gmatch(screen, "[^|]+") do
    if #line > 21 then good = false end
  end
end
print(string.format("%s %dx%d: %s", string.match(path, "[^/]*$"), W, H,
  ok and ("shows \"" .. string.gsub(screen, "|", " / ") .. "\"") or ("LOAD FAILED (" .. tostring(err) .. ")")))
print(good and "MSG OK" or "MSG FAIL")
