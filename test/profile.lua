-- sample-based profile of run(): where do the VM instructions go?
local src = io.open("harness.lua"):read("*a")
local head = src:sub(1, src:find("-- 1. menus", 1, true) - 1)
local NAMES = {}
for line in io.lines(arg[1]) do NAMES[#NAMES + 1] = line end
local f = assert(load(head .. [[
local names = ...
local prof, total = {}, 0
local function sample()
  local info = debug.getinfo(2, "Sl")
  if info then
    local k = info.short_src:match("[^/]*$") .. ":" .. (info.linedefined or 0)
    prof[k] = (prof[k] or 0) + 100
    total = total + 100
  end
end
T.track(tonumber(arg[5] or 1)); T.set("mode", 2); T.set("laps", 2); T.start(1)
local frames = 0
for fr = 1, 1200 do
  local st = state()
  if st == 4 then autopilot() else sticks.ail, sticks.ele, sticks.rud, sticks.thr = 0, 0, 0, -1024 end
  clock = clock + 50
  debug.sethook(sample, "", 100)
  script.run(0)
  debug.sethook()
  frames = frames + 1
end
local rows = {}
for k, v in pairs(prof) do rows[#rows + 1] = { k, v } end
table.sort(rows, function(a, b) return a[2] > b[2] end)
print(string.format("avg instr/frame %d", total / frames))
for i = 1, math.min(18, #rows) do
  local ln = tonumber(rows[i][1]:match(":(%d+)$"))
  local txt = ln and names[ln] or ""
  print(string.format("%6d/frame  %5.1f%%  %-22s %s", rows[i][2] / frames, rows[i][2] * 100 / total, rows[i][1], (txt or ""):gsub("^%s+", ""):sub(1, 70)))
end
]]))
f(NAMES)
