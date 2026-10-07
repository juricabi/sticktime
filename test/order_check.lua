-- Draw-order check at the Bando: random camera poses; for every pair with a structure in it,
-- cast rays from the camera to points on the object drawn later. If such a ray passes through
-- the object drawn earlier first, the later one wrongly paints over it.
-- Usage: lua order_check.lua ../sdcard/SCRIPTS/TOOLS/StickTime.lua color 480 272
local src = io.open("harness.lua"):read("*a")
local head = src:sub(1, src:find("-- 1. menus", 1, true) - 1)
local f = assert(load(head .. [[
local function segHits(cx, cy, cz, px, py, pz, b, i)
  -- does the segment camera->point pass through bounds i (shrunk a little) before the point?
  local e = 0.03
  local lo, hi = 0, 0.995
  local d = { px - cx, py - cy, pz - cz }
  local o = { cx, cy, cz }
  local mn = { b.x0[i] + e, b.y0[i] + e, b.z0[i] + e }
  local mx = { b.x1[i] - e, b.y1[i] - e, b.z1[i] - e }
  for a = 1, 3 do
    if mn[a] > mx[a] then return false end
    if math.abs(d[a]) < 1e-9 then
      if o[a] < mn[a] or o[a] > mx[a] then return false end
    else
      local t1, t2 = (mn[a] - o[a]) / d[a], (mx[a] - o[a]) / d[a]
      if t1 > t2 then t1, t2 = t2, t1 end
      if t1 > lo then lo = t1 end
      if t2 < hi then hi = t2 end
      if lo > hi then return false end
    end
  end
  return true
end
local function inside(cx, cy, cz, b, i)
  return cx > b.x0[i] and cx < b.x1[i] and cy > b.y0[i] and cy < b.y1[i] and cz > b.z0[i] and cz < b.z1[i]
end
local function kind(id) return id < 0 and "tree" or id < 1000 and "gate" or id < 2000 and "box" or "ai" end
local function violations(n, order, ids, b, cx, cy, cz, tally)
  local bad = 0
  for p = 1, n do
    for q = p + 1, n do
      local A, B = order[p], order[q]
      if (b.b[A] or b.b[B]) and not inside(cx, cy, cz, b, A) and not inside(cx, cy, cz, b, B) then
        local hit = false
        for u = 0, 2 do for v = 0, 2 do for w = 0, 2 do
          if not hit then
            local x = b.x0[B] + (b.x1[B] - b.x0[B]) * u / 2
            local y = b.y0[B] + (b.y1[B] - b.y0[B]) * v / 2
            local z = b.z0[B] + (b.z1[B] - b.z0[B]) * w / 2
            if segHits(cx, cy, cz, x, y, z, b, A) then hit = true end
          end
        end end end
        if hit then
          bad = bad + 1
          local k = kind(ids[A]) .. "/" .. kind(ids[B])
          tally[k] = (tally[k] or 0) + 1
        end
      end
    end
  end
  return bad
end
T.track(7)
T.start(2)
for i = 1, 70 do frame(0) end
idleSticks()
local seed = 11
local function rnd() seed = (seed * 16807) % 2147483647 return seed / 2147483647 end
local newBad, oldBad, frames, tNew, tOld = 0, 0, 0, {}, {}
for k = 1, 400 do
  -- around the ruin, the tower and the containers, at all heights and headings
  local spots = { { 0, 40, 22 }, { 46, 64, 20 }, { 40, 10, 14 }, { -30, 30, 25 } }
  local s = spots[1 + (k % #spots)]
  local x, z = s[1] + (rnd() * 2 - 1) * s[3], s[2] + (rnd() * 2 - 1) * s[3]
  local y = 0.5 + rnd() * 26
  T.state(4)
  T.pose(x, y, z, rnd() * 360, (rnd() * 2 - 1) * 70, (rnd() * 2 - 1) * 40)
  frame(0)
  if state() == 4 then
    local n, order, ids, b, cx, cy, cz = T.order()
    frames = frames + 1
    newBad = newBad + violations(n, order, ids, b, cx, cy, cz, tNew)
    -- the old way: center depth only
    local _, oz = nil, nil
    local dep = {}
    for i = 1, n do dep[i] = i end
    local _, _, _, _, _, _, _ = nil
    local zz = {}
    for i = 1, n do
      local ox, oy, oz2 = (b.x0[i] + b.x1[i]) / 2 - cx, (b.y0[i] + b.y1[i]) / 2 - cy, (b.z0[i] + b.z1[i]) / 2 - cz
      local _, s2 = state()
      local fx, fy, fz, ux, uy, uz = s2[7], s2[8], s2[9], s2[10], s2[11], s2[12]
      local t = T.S.tilt * 0.0174533
      local kfx, kfy, kfz = fx * math.cos(t) + ux * math.sin(t), fy * math.cos(t) + uy * math.sin(t), fz * math.cos(t) + uz * math.sin(t)
      zz[i] = ox * kfx + oy * kfy + oz2 * kfz
    end
    table.sort(dep, function(p, q) return zz[p] > zz[q] end)
    oldBad = oldBad + violations(n, dep, ids, b, cx, cy, cz, tOld)
  end
end
local function fmtT(t) local r = {} for k, v in pairs(t) do r[#r + 1] = k .. " " .. v end table.sort(r) return table.concat(r, ", ") end
print(string.format("Bando draw order, %d camera poses: separating planes %d wrong pairs (%s) | center depth %d wrong pairs (%s)",
  frames, newBad, fmtT(tNew), oldBad, fmtT(tOld)))
print(newBad == 0 and frames > 300 and "ALL OK" or "FAIL: structures drawn in the wrong order")
]]))
f()
