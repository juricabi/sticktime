-- fly the autopilot on one track and report every crash: lua debug_track.lua <script> <kind> <W> <H> <track> [mode]
local src = io.open("harness.lua"):read("*a")
local head = src:sub(1, src:find("-- 1. menus", 1, true) - 1)
local f = assert(load(head .. [[
local track, m = tonumber(arg[5] or 1), tonumber(arg[6] or 1)
T.set("mode", 2) T.set("laps", 1) T.set("ai", 0)
T.track(track)
T.start(m)
local last = 0
for f = 1, 20 * 200 do
  local st, s = state()
  if st == 4 then autopilot() else idleSticks() end
  if st == 5 and last ~= 5 then
    local _, _, _, _, _, crashes = T.race()
    print(string.format("crash at t=%.1f pos (%.1f, %.1f, %.1f) vel (%.1f %.1f %.1f) next gate %d", clock / 1000, s[1], s[2], s[3], s[4], s[5], s[6], s[18]))
  end
  last = st
  if st == 8 then print("finished") break end
  frame(0)
end
]]))
f()
