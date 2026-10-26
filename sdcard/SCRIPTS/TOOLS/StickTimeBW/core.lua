local toolName = "TNS|StickTime BW|TNE"
--[[ ======================================================================
  StickTime BW v1.10.1  -  a real 3D FPV quad simulator that runs on your radio
  Black & white version - 128x64 and 212x64 radios with an STM32F4 (TX12 MkII, Zorro, Boxer,
  Pocket, MT12, GX12, X9D+ 2019, X9E, T14, T20 ...)

  Install : copy StickTimeBW.lua and the StickTimeBW folder to /SCRIPTS/TOOLS/ and
            start it from SYS > TOOLS (or SD card browser > Execute).
  Fly     : your sticks fly the quad (acro or angle mode). The radio
            handles stick mode 1-4. EXIT = pause/back, ENTER = select,
            rotary / +- / up-down = move. Touch screens: tap.
  Modes   : Race against AI pilots, Practice, Freestyle (tricks and
            combos) and Gate Rush (beat the clock), on eight tracks and
            eight of your own (StickTimeTracks/c1.txt .. c8.txt).
  Safety  : the radio keeps transmitting while the sim runs - keep the
            real quad unplugged or the RF module off.
  Credits : inspired by lua-fpv-sim by Alexey Stankevich (@AlexeyStn);
            this is an independent rewrite with a full 3D engine.
====================================================================== ]]

local lcd = lcd
local sqrt, sin, cos, floor = math.sqrt, math.sin, math.cos, math.floor
local fmt = string.format
local getValue, getTime = getValue, getTime
local W, H = LCD_W, LCD_H
local drawLine, fillRect, drawText, drawNumber = lcd.drawLine, lcd.drawFilledRectangle, lcd.drawText, lcd.drawNumber
local SOLID, DOTTED = SOLID, DOTTED
local XM, YM = W - 1, H - 1
local BLK = FORCE          -- B&W default draw mode is XOR: FORCE sets pixels black
-- menus and HUD grow with the fonts on a color radio (StickTimeBW/color.lua sets it); 1 on B&W
local U = STICKTIME_UI or 1

local EV = {
  ENTER = EVT_VIRTUAL_ENTER or EVT_ENTER_BREAK, EXIT = EVT_VIRTUAL_EXIT or EVT_EXIT_BREAK,
  NEXT = EVT_VIRTUAL_NEXT, PREV = EVT_VIRTUAL_PREV, INC = EVT_VIRTUAL_INC, DEC = EVT_VIRTUAL_DEC,
  NEXTR = EVT_VIRTUAL_NEXT_REPT, PREVR = EVT_VIRTUAL_PREV_REPT, INCR = EVT_VIRTUAL_INC_REPT, DECR = EVT_VIRTUAL_DEC_REPT,
  PGN = EVT_VIRTUAL_NEXT_PAGE, PGP = EVT_VIRTUAL_PREV_PAGE, TAP = EVT_TOUCH_TAP,
}

-- game states; game modes (gmode): 1 race, 2 practice, 3 freestyle, 4 gate rush
local MENU, SETUP, COUNT, FLY, CRASHED, READY, PAUSED, DONE = 1, 2, 3, 4, 5, 6, 7, 8
local focus, scroll, editing = 1, 0, false     -- menus: focused row, list scroll, editing a value

-- ------------------------------------------------------------ settings
local S = { track = 1, quad = 1, twr = 0, mode = 1, rates = 2, rc = 100, rm = 600, re = 50, yc = 100, ym = 500, ye = 40,
            tilt = 20, fov = 100, laps = 3, ai = 2, skill = 2, ghost = 1, wind = 0, wash = 0, grip = 1, batt = 0, vib = 1,
            map = 1, sticks = 0, fps = 0 }
-- rows: label, key, then either a value list (+ names, suffix) or nil, nil, suffix, min, max, step
local OPTS = {
  { "Quad", "quad", { 1, 2, 3, 4, 5 }, { 'Racer 5"', 'Freestyle 5"', '3" toothpick', 'Whoop 65mm', 'Whoop 75mm' } },
  { "Power", "twr", { 0, 3, 4, 5, 6, 7, 8, 10, 12 }, { "Stock", "3:1", "4:1", "5:1", "6:1", "7:1", "8:1", "10:1", "12:1" } },
  { "Flight mode", "mode", { 1, 2 }, { "Acro", "Angle" } },
  { "Rates", "rates", { 1, 2, 3, 4 }, { "Soft", "Normal", "Fast", "Custom" } },
  { "R/P center", "rc", nil, nil, "", 10, 500, 10 },
  { "R/P max", "rm", nil, nil, "", 100, 2000, 10 },
  { "R/P expo", "re", nil, nil, nil, 0, 100, 1 },
  { "Yaw center", "yc", nil, nil, "", 10, 500, 10 },
  { "Yaw max", "ym", nil, nil, "", 100, 2000, 10 },
  { "Yaw expo", "ye", nil, nil, nil, 0, 100, 1 },
  { "Camera tilt", "tilt", nil, nil, "", 0, 60, 5 },
  { "Field of view", "fov", nil, nil, "", 70, 130, 10 },
  { "Race laps", "laps", { 1, 2, 3, 5, 10 } },
  { "Opponents", "ai", { 0, 1, 2, 3 } },
  { "AI skill", "skill", { 1, 2, 3 }, { "Easy", "Medium", "Hard" } },
  { "Wind", "wind", { 0, 1, 2 }, { "Off", "Light", "Strong" } },
  { "Prop wash", "wash", { 0, 1, 2 }, { "Off", "Stock", "Max" } },
  { "Grip", "grip", { 0, 1, 2 }, { "Low", "Medium", "High" } },
  { "Battery", "batt", { 0, 1, 3, 2 }, { "Off", "Real", "1.5x", "2x" } },   -- (3: 1.5x, added after 2x)
  { "Vibration", "vib", { 0, 1 }, { "Off", "On" } },
  { "Show FPS", "fps", { 0, 1 }, { "Off", "On" } },
}
-- Betaflight "actual" rate presets: roll/pitch center, max (deg/s), expo %, then yaw
local RATES = { { 70, 400, 35, 70, 350, 30 }, { 100, 600, 50, 100, 500, 40 }, { 150, 850, 45, 130, 700, 40 } }
local RKEYS = { rc = 1, rm = 2, re = 3, yc = 4, ym = 5, ye = 6 }
-- quad profiles (Racer 5", Freestyle 5", 3" toothpick, Whoop 65mm, Whoop 75mm), each fitted to a detailed model
-- of that class (blade-element props on rpm-governed motors, a Betaflight-style PID loop; see
-- docs/flight-model.md). twr stock thrust/weight; thrust curve: i0 idle, tn exponent, dz bottom dead
-- zone, tk the share of a steep top end (x^8); vp, vc, vk climbing: prop pitch speed (m/s), throttle
-- exponent and bend of the inflow loss; tl, vt translational lift gain and speed (m/s), tb its growth
-- with throttle, te, ta its fades near full stick and with axial inflow (m/s); ks, kf, ku side, front,
-- top drag per kg; er, vd extra drag at low speed and the speed it fades by (m/s); lr
-- frame lift / drag; gg, gl, gw ground effect gain, ray length and fade (m); tm thrust, tr roll/pitch,
-- ty yaw response time (s); pw/wl/wv prop wash Max: shake rms at full wash (deg), thrust loss, the sink
-- speed where the loss has faded out (m/s); wls/wvs/pws the same at the class's Stock setting; sq, cq,
-- ce, se, rf descending: the cushion peaks at cq (less by ce near full stick) at a sink of sq*tf^se m/s,
-- then stalls down to rf + rq*tf (at most 1: at idle the blades stall, with power they hold); pf the prop wash shake's frequency (Hz); tlo, thi the Power settings that
-- suit the class (thrust/weight of real quads of its kind; Stock is always there); kh rotor drag at
-- Grip High (1/s, times sqrt(Tm/5g + 0.02); Medium, the default, 0.4 of it; Low none, as in the reference);
-- am how fast the motors spin the quad up in a flip (rad/s^2 at hover throttle; the airmode mixer in physics()).
-- One string per class (parsed for the class in use only: tables of numbers cost radio memory):
local QK = { "twr", "i0", "tn", "dz", "vp", "vk", "tl", "vt", "te", "ks", "kf", "ku", "er", "vd", "lr", "gg", "gl", "gw", "tm", "tr", "ty", "pw", "wl", "wv", "sq", "cq", "wls", "wvs", "pws", "vc", "ta", "ce", "se", "rf", "pf", "tlo", "thi", "kh", "tk", "tb", "rq", "am" }
local QP = {
  -- twr i0 tn dz vp vk tl vt te ks kf ku er vd lr gg gl gw tm tr ty pw wl wv sq cq wls wvs pws vc ta ce se rf pf tlo thi kh tk tb rq am
  "7.67 .0315 1.43 .123 87.5 -.362 .517 7.88 .566 .0152 .00819 .0287 .357 15 .229 .24 .25 .113 .006 .009 .02 .347 .326 6.01 13.2 1.42 .119 3.8 .19 .61 65.3 .655 .496 .72 26 5 12 .363 .184 .874 .334 430",  -- Racer 5": 0.49 kg, 2500KV, 5045 tri-blade
  "6.88 .026 1.5 .075 75.6 -.278 .502 7.61 .712 .011 .00635 .0184 .357 15 .257 .26 .25 .113 .006 .008 .02 .347 .348 7 11.4 1.42 .132 4.56 .19 .539 453 .75 .317 .661 24 4 10 .263 .015 .367 .272 550",       -- Freestyle 5": HD, 0.66 kg, 2400KV, 5045
  "5.35 .0221 1.76 0 69.6 -.786 .891 9.7 .204 .0176 .0167 .0417 .5 15 .1 .44 .15 .135 .006 .009 .02 .42 .291 7.04 14.7 1.57 .103 5.17 .23 .713 14.3 .121 .537 .577 35 3 10 .433 .032 .297 6.34 410",         -- 3" toothpick: 0.11 kg, 3S, 5000KV, 76 mm
  "2.58 .0059 .987 .094 117 -4.79 .824 9.1 .287 .0741 .07 .0875 .286 7 0 .17 .0625 .0344 .006 .02 .02 .854 .237 5.61 8.42 1.34 .0243 2.5 .27 .919 25.6 .0789 .517 0 45 3 8 1.59 -.041 .536 11.9 200",        -- Whoop 65mm: ducted 1S, 24 g, 28000KV, 31 mm
  "3.54 .0198 .916 .09 116 -2.78 .864 9.01 .042 .0962 .0822 .0288 .556 15 .4 .19 .08 .036 .006 .016 .02 .456 .285 5.61 8.68 1.32 .0949 3.63 .25 .952 24.6 .0829 .526 .203 40 3 8 2.38 -.031 .212 5.67 350",  -- Whoop 75mm: ducted 2S, 47 g, 12000KV, 4-blade 40 mm
}

-- -------------------------------------------------------------- tracks
-- gates: x, z, type, yaw (deg), center height (0 = default). Types: 1 gate, 2 high gate,
-- 3 dive gate (flat, fly down through it), 4 hoop, 5 arch, 6 flag (pass on its right),
-- 7 flag (pass on its left), 8 gap in a structure.
-- boxes: x, z, half size x, half size z, bottom, top, kind (1 concrete, 2 red, 3 blue; from format 3
-- also 4 wood, 5 brick, 6 dark steel, 7 white, 8 yellow, 9 green).
-- Boxes must not intersect: the renderer orders them with separating planes.
-- The scenery (DECO for these tracks, the last sections of a format 3 or 4 file): props x, z, kind,
-- height (0: the kind's own; 1 conifer, 2 leafy tree, 3 bush, 4 hay bale, 5 tyre stack, 6 traffic
-- cone, 7 light mast, 8 tent, 9 windsock, 10 post), "/", rails x1, z1, x2, z2, kind, height (1 fence,
-- 2 safety net, 3 race tape, 4 power line, 5 banner), "/", decals on the ground x, z, half length,
-- half width, yaw (deg), kind (1 dirt road, 2 tarmac, 3 gravel, 4 painted line: strips; 5 pond, 6
-- sand: ellipses).
local TRACKS = {
  { "Meadow", 11, { 0,0,1,0,0, 0,30,1,15,0, 14,52,2,55,0, 38,56,1,110,0, 50,40,1,180,0, 36,24,1,190,0, 42,6,2,185,0,
                    32,-14,1,230,0, 12,-20,1,290,0 } },
  { "Figure 8", 23, { -14,10,1,0,0, 6,46,2,40,0, 18,68,1,0,0, 0,88,1,-90,0, -18,68,1,180,0, 18,16,1,180,0, 0,-4,1,-90,0 } },
  { "Dive Tower", 37, { 0,0,1,0,0, 0,26,2,5,0, 6,50,2,25,10, 22,70,1,75,0, 40,62,4,150,6, 36,40,3,200,0, 30,20,1,210,0,
                        18,6,1,190,0, 24,-14,2,205,0, 6,-22,1,295,0 } },
  { "Slalom", 53, { 0,0,5,0,0, -2,22,7,0,0, 6,40,6,0,0, -2,58,7,0,0, 6,76,6,0,0, 2,96,4,0,3, 22,112,2,90,0, 44,100,4,120,3,
                    48,78,7,180,0, 40,60,6,180,0, 48,42,7,180,0, 44,18,3,200,0, 28,-22,1,-90,0 } },
  { "Hoop Forest", 61, { 0,0,1,0,0, 6,22,4,35,2.4, 22,32,4,35,5, 28,52,4,45,3, 48,58,4,115,6, 56,38,2,140,0,
                         72,28,4,155,2, 70,6,4,220,4, 48,0,3,245,0, 30,-14,4,245,2.2, 12,-18,4,290,3 }, nil, 2 },
  { "Grand Prix", 71, { 0,0,5,0,0, 0,46,1,5,0, 6,84,2,30,6, 26,100,7,90,0, 36,74,4,150,3, 50,58,1,90,0, 68,78,4,50,3,
                        92,92,7,120,0, 100,62,3,200,0, 88,30,1,175,0, 104,6,2,190,8, 80,-14,1,255,0, 50,-10,4,260,2.2,
                        26,-24,1,275,0 } },
  { "Bando", 83, { 0,0,1,0,0, 0,34,8,0,1.8, 0,46,8,0,1.8, 20,66,4,60,4, 40,88,3,146,0, 56,64,1,180,0, 43.95,10,8,180,1.3,
                   22,-16,4,250,2.5 },
    { -6.225,34,4.025,0.25,0,7,1, 6.225,34,4.025,0.25,0,7,1, 0,34,2.2,0.25,3.6,7,1,
      -6.225,46,4.025,0.25,0,7,1, 6.225,46,4.025,0.25,0,7,1, 0,46,2.2,0.25,3.6,7,1,
      -10,40,0.25,5.75,0,7,1, 10,36.025,0.25,1.775,0,7,1, 10,43.975,0.25,1.775,0,7,1, 10,40,0.25,2.2,3.6,7,1,
      46,64,2,2,0,36,1, 33.6,10,1.25,3,0,2.6,2, 40.5,10,1.25,3,0,2.6,3, 47.4,10,1.25,3,0,2.6,2,
      -30,20,3,1.25,0,5.2,3, -36,50,4,4,0,3,1 } },
  -- laid out like a real race: lanes up and down the field joined by flag hairpins, a high
  -- gate and a dive gate on the start straight, a split-S (through the high gate, back
  -- through the one under it) and a corner flag before the finish
  { "Pro Track", 97, { 0,0,1,0,0, 0,22,2,0,0, 0,44,3,0,0, 8,62,7,90,0, 16,44,4,180,0, 16,22,1,180,0, 24,4,6,90,0,
                       32,22,1,0,0, 32,46,2,0,0, 32,46,1,180,0, 46,26,4,160,3, 48,4,1,180,0, 46,-14,7,225,0,
                       24,-22,1,270,0 } },
}
-- custom tracks: StickTimeTracks/c1.txt .. c8.txt on the SD card (the browser emulator's track
-- editor makes them; StickTime and StickTime BW read the same files, the Lite doesn't). A name line, then the numbers: format 1,
-- an id (bests start over when it changes), tree seed, trees (9: as many as most tracks), the gates
-- (x z type yaw height), "/", the structures (x z half-x half-z bottom top kind). Format 3 (1.10.0)
-- has the scenery after the structures and structure kinds 1-9, up to 1600 bytes: this edition
-- builds its gates and structures, the scenery is the color edition's (no memory for it here).
-- Formats 2 and 4, bigger tracks, are the color edition's only. They are tracks 9-16 whether or
-- not the slots before them are filled; only the name, format and id are read here
local NB0, NT = #TRACKS, #TRACKS + 8
local CUSTOM = "/SCRIPTS/TOOLS/StickTimeTracks/c"
for i = 1, 8 do
  local f = io.open(CUSTOM .. i .. ".txt", "r")
  if f then
    local s = io.read(f, 60)
    io.close(f)
    local name, ver, id = string.match(s or "", "^%s*([^\r\n]+)[\r\n]+%s*(%d+)%s+(%d+)")
    if name and (ver == "1" or ver == "3") then TRACKS[NB0 + i] = { string.sub(name, 1, 16), file = i, id = tonumber(id), fm = tonumber(ver) } end
  end
end
collectgarbage()                                       -- (the files and strings: a B&W heap is tight)
local GT, FLAGH = 0.28, 3.4                            -- frame thickness, flag pole height (m)
local GHW = { 1.5, 1.5, 2.0, 1.25, 2.4, 6, 6, 2.2 }     -- inner half width, ring radius, flag zone
local GHH = { 1.0, 1.0, 2.0, 1.25, 2.4, 30, 30, 1.8 }   -- inner half height
local GSH = { 1, 1, 1, 2, 2, 3, 3, 4 }                 -- shape: 1 frame, 2 ring, 3 flag, 4 gap

-- gates (struct of arrays: fast indexed access in the hot loops)
local NG, gx, gy, gz, gk, gd = 0, {}, {}, {}, {}, {}
local gnx, gny, gnz, grx, grz, gax, gay, gaz = {}, {}, {}, {}, {}, {}, {}, {}
local AX, AY, AZ = {}, {}, {}           -- aim point per gate: racing line, markers, respawn
-- pillars: trees (k=1), gate legs, hoop stands, posts and pylons (k=2), flag poles (k=3), and the
-- props (k=4 leafy tree, 5 bush, 6 hay bale, 7 tyre stack, 8 traffic cone, 9 light mast, 10 tent,
-- 11 windsock, 12 post): only k=1 and the props are drawn as pillars
local NP, qx, qz, qr, qh, qk = 0, {}, {}, {}, {}, {}
-- boxes: walls, towers, containers
local BX = { n = 0, x0 = {}, x1 = {}, y0 = {}, y1 = {}, z0 = {}, z1 = {}, k = {} }
-- start pad, track bounds, wind direction
local TR = { px = 0, pz = -14, hx = 0, hz = 1, x0 = 0, x1 = 1, z0 = 0, z1 = 1, wx = 0, wz = 1 }
-- AI pilots and the racing line (Hermite curves between aim points)
local AI = { n = 0, vt = 0, ch = {}, sl = {}, sf = {}, seg = {}, k = {}, s = {}, v = {}, d = {},
             x = {}, y = {}, z = {}, f = {}, o = {}, x0 = {}, z0 = {}, l0 = {}, vs = { 9, 13, 17.5 } }

AI.pos = function(i, s)
  local j = i % NG + 1
  local c = AI.ch[i]
  local s2 = s * s
  local s3 = s2 * s
  local h1, h3 = 2 * s3 - 3 * s2 + 1, 3 * s2 - 2 * s3
  local h2, h4 = (s3 - 2 * s2 + s) * c, (s3 - s2) * c
  return h1 * AX[i] + h2 * gnx[i] + h3 * AX[j] + h4 * gnx[j],
         h1 * AY[i] + h2 * gny[i] + h3 * AY[j] + h4 * gny[j],
         h1 * AZ[i] + h2 * gnz[i] + h3 * AZ[j] + h4 * gnz[j]
end

local buildTrack
do
  local GCY = { 1.35, 5.5, 7.0, 2.4, 0, 0, 0, 2.0 }       -- default center height per type
  local seed = 1
  local function rnd()
    seed = seed * 171 % 30269
    return seed / 30269
  end
  local function addPillar(x, z, r, h, k)
    NP = NP + 1
    qx[NP], qz[NP], qr[NP], qh[NP], qk[NP] = x, z, r, h, k
  end
  local function segDist2(x, z, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local l = dx * dx + dz * dz
    local t = 0
    if l > 0 then t = ((x - ax) * dx + (z - az) * dz) / l end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    dx, dz = ax + dx * t - x, az + dz * t - z
    return dx * dx + dz * dz
  end
  local function boxDist2(x, z)
    local m = 1e9
    for b = 1, BX.n do
      local dx, dz = BX.x0[b] - x, BX.z0[b] - z
      if x - BX.x1[b] > dx then dx = x - BX.x1[b] end
      if z - BX.z1[b] > dz then dz = z - BX.z1[b] end
      if dx < 0 then dx = 0 end
      if dz < 0 then dz = 0 end
      if dx * dx + dz * dz < m then m = dx * dx + dz * dz end
    end
    return m
  end
  buildTrack = function(t)
    local T = TRACKS[t]
    if T.file then
      -- a custom track: read its numbers now (and let them go once it is built)
      local f, fm = io.open(CUSTOM .. T.file .. ".txt", "r"), T.fm
      local s = f and io.read(f, fm == 3 and 1600 or 1000) or ""
      if f then io.close(f) end
      local g, b = string.match(string.match(s, "^%s*[^\r\n]*[\r\n]+(.*)") or "", "([^/]*)/?(.*)")
      if fm > 2 then b = string.match(b or "", "([^/]*)") end   -- format 3: the gates and structures (not the scenery)
      local n, d = 0, {}
      for v in string.gmatch(g or "", "%S+") do
        n = n + 1
        if n == 3 then T[2] = tonumber(v) or 1
        elseif n == 4 then T[5] = (tonumber(v) or 9) / 9
        elseif n > 4 and n <= 124 then d[n - 4] = tonumber(v) or 0 end   -- at most 24 gates
      end
      local tr = T[5] or 1                             -- 0-30 trees
      if tr < 0 then tr = 0 elseif tr > 30 / 9 then tr = 30 / 9 end
      T[5] = tr
      T[3], T[4] = d, {}
      for v in string.gmatch(b or "", "%S+") do
        if #T[4] < 112 then T[4][#T[4] + 1] = tonumber(v) or 0 end   -- at most 16 structures
      end
      -- gates in fives with a known type, structures in sevens with a known kind (a file made by hand;
      -- a type or kind a hair over a whole number, 4.004, is that number: the tables are keyed by it)
      local ok, bd = #d >= 10 and #d % 5 == 0, T[4]
      for i = 3, #d, 5 do
        if d[i] < 1 or d[i] > 8 or d[i] - floor(d[i]) > 0.01 then ok = false else d[i] = floor(d[i]) end
      end
      if not ok then T[3] = { 0, 0, 1, 0, 0, 0, 30, 1, 0, 0 } end   -- unreadable: two gates in a line
      ok = #bd % 7 == 0
      for i = 7, #bd, 7 do
        if bd[i] < 1 or bd[i] > (fm > 2 and 9 or 3) or bd[i] - floor(bd[i]) > 0.01 then ok = false else bd[i] = floor(bd[i]) end
      end
      if not ok then T[4] = {} end
    end
    local d, bd = T[3], T[4]
    NG, NP, BX.n = 0, 0, 0
    if bd then
      for i = 1, #bd, 7 do
        local n = BX.n + 1
        BX.n = n
        BX.x0[n], BX.x1[n], BX.z0[n], BX.z1[n] = bd[i] - bd[i + 2], bd[i] + bd[i + 2], bd[i + 1] - bd[i + 3], bd[i + 1] + bd[i + 3]
        BX.y0[n], BX.y1[n], BX.k[n] = bd[i + 4], bd[i + 5], bd[i + 6]
      end
    end
    for i = 1, #d, 5 do
      NG = NG + 1
      local k, yaw = d[i + 2], d[i + 3] * 0.0174533
      local hx, hz = sin(yaw), cos(yaw)
      local x, z, y = d[i], d[i + 1], d[i + 4]
      if y <= 0 then y = GCY[k] end
      local iw, ih = GHW[k], GHH[k]
      grx[NG], grz[NG] = hz, -hx
      if k == 3 then
        gnx[NG], gny[NG], gnz[NG] = 0, -1, 0
        gax[NG], gay[NG], gaz[NG] = hx, 0, hz
      else
        gnx[NG], gny[NG], gnz[NG] = hx, 0, hz
        gax[NG], gay[NG], gaz[NG] = 0, 1, 0
      end
      local ax, ay, az = x, y, z
      if k == 2 then
        local o = iw + GT * 0.5
        addPillar(x + hz * o, z - hx * o, GT * 0.5, y - ih - GT, 2)
        addPillar(x - hz * o, z + hx * o, GT * 0.5, y - ih - GT, 2)
      elseif k == 3 then
        local ow, oh = iw + GT * 0.5, ih + GT * 0.5
        for sx = -1, 1, 2 do
          for sz = -1, 1, 2 do
            addPillar(x + hz * ow * sx + hx * oh * sz, z - hx * ow * sx + hz * oh * sz, GT * 0.5, y, 2)
          end
        end
      elseif k == 4 then
        addPillar(x, z, 0.08, y - iw - GT, 2)
      elseif k == 5 then
        ay = y > 1.4 and y or 1.4                               -- a raised ring: its middle
      elseif k == 6 or k == 7 then
        -- (x, z) is the pole; the gate itself is the pass zone beside it
        local s = k == 6 and 1 or -1
        addPillar(x, z, 0.12, FLAGH, 3)
        ax, ay, az = x + hz * s * 2.5, 1.8, z - hx * s * 2.5
        x, z, y = x + hz * s * iw, z - hx * s * iw, 0
      end
      gx[NG], gy[NG], gz[NG], gk[NG] = x, y, z, k
      AX[NG], AY[NG], AZ[NG] = ax, ay, az
    end
    TR.hx, TR.hz = gnx[1], gnz[1]
    TR.px, TR.pz = AX[1] - TR.hx * 14, AZ[1] - TR.hz * 14
    local x0, x1, z0, z1 = TR.px, TR.px, TR.pz, TR.pz
    for i = 1, NG do
      if gx[i] < x0 then x0 = gx[i] end
      if gx[i] > x1 then x1 = gx[i] end
      if gz[i] < z0 then z0 = gz[i] end
      if gz[i] > z1 then z1 = gz[i] end
    end
    for b = 1, BX.n do
      if BX.x0[b] < x0 then x0 = BX.x0[b] end
      if BX.x1[b] > x1 then x1 = BX.x1[b] end
      if BX.z0[b] < z0 then z0 = BX.z0[b] end
      if BX.z1[b] > z1 then z1 = BX.z1[b] end
    end
    TR.x0, TR.x1, TR.z0, TR.z1 = x0, x1, z0, z1
    seed = T[2]
    local a = rnd() * 6.2832
    TR.wx, TR.wz = sin(a), cos(a)
    -- scenery trees, kept away from the racing line, structures and the rest of the scenery
    local n, tries, want = 0, 0, 8 * (T[5] or 1)
    while n < want and tries < want * 16 do
      tries = tries + 1
      local x = x0 - 30 + rnd() * (x1 - x0 + 60)
      local z = z0 - 30 + rnd() * (z1 - z0 + 60)
      local ok = segDist2(x, z, TR.px, TR.pz, AX[1], AZ[1]) > 100 and boxDist2(x, z) > 16
      for i = 1, NG do
        local j = i % NG + 1
        if ok and segDist2(x, z, AX[i], AZ[i], AX[j], AZ[j]) < 100 then ok = false end
      end
      for i = 1, NP do
        local dx, dz = x - qx[i], z - qz[i]
        if ok and dx * dx + dz * dz < 36 then ok = false end
      end
      if ok then
        n = n + 1
        local h = 6 + rnd() * 6
        addPillar(x, z, h * 0.14, h, 1)
      end
    end
    -- racing line: length and speed factor of each leg
    for i = 1, NG do
      local j = i % NG + 1
      local dx, dy, dz = AX[j] - AX[i], AY[j] - AY[i], AZ[j] - AZ[i]
      local c = sqrt(dx * dx + dy * dy + dz * dz) + 0.01
      AI.ch[i] = c
      local L, lx, ly, lz = 0, AX[i], AY[i], AZ[i]
      for q = 1, 8 do
        local x, y, z = AI.pos(i, q / 8)
        L = L + sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly) + (z - lz) * (z - lz))
        lx, ly, lz = x, y, z
      end
      AI.sl[i] = L
      dx, dy, dz = dx / c, dy / c, dz / c
      local k1 = dx * gnx[i] + dy * gny[i] + dz * gnz[i]
      local k2 = dx * gnx[j] + dy * gny[j] + dz * gnz[j]
      if k2 < k1 then k1 = k2 end
      AI.sf[i] = 0.55 + 0.225 * (k1 + 1)
    end
    if T.file then T[3], T[4] = nil, nil end
  end
end

-- --------------------------------------------------------- persistence
local BEST = { l = {}, r = {}, g = {}, f = {}, i = {} }   -- per track: best lap, race, gate rush gates,
for t = 1, NT do BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t], BEST.i[t] = 0, 0, 0, 0, 0 end   -- combo, track id
local loadData, saveData
do
local DATA = "/SCRIPTS/TOOLS/StickTimeBW.dat"
local OLD = "/SCRIPTS/TOOLS/FPVSimBW.dat"                 -- the save under the old name, FPV Sim

local DEF = {}
for k, v in pairs(S) do DEF[k] = v end

local function validate()
  for i = 1, #OPTS do
    local o = OPTS[i]
    local v, ok = S[o[2]], false
    if type(v) == "number" then
      if o[3] then
        for j = 1, #o[3] do
          if o[3][j] == v then ok = true end
        end
      else
        ok = v >= o[6] and v <= o[7]
      end
    end
    if not ok then S[o[2]] = DEF[o[2]] end
  end
  if type(S.track) ~= "number" or not TRACKS[S.track] then S.track = 1 end
  -- a custom track that is not the one these bests were flown on: they start over
  for t = NB0 + 1, NT do
    local T = TRACKS[t]
    if T and BEST.i[t] ~= T.id then BEST.l[t], BEST.r[t], BEST.g[t], BEST.f[t], BEST.i[t] = 0, 0, 0, 0, T.id end
  end
end

loadData = function()
  local f, old = io.open(DATA, "r"), false
  if not f then f, old = io.open(OLD, "r"), true end
  if not f then validate() return end
  local s = io.read(f, 2048)
  io.close(f)
  if type(s) ~= "string" then return end
  if string.sub(s, 1, 7) == "FPVSIM2" then
    local lay = 0
    for k, n, v in string.gmatch(s, "(%a+)(%d*)=(%-?%d+)") do
      v = tonumber(v)
      if k == "lay" then lay = v
      elseif n == "" then
        if S[k] ~= nil then S[k] = v end
      else
        local t = tonumber(n)
        if BEST[k] and t >= 1 and t <= NT then BEST[k][t] = v end
      end
    end
    -- layout 2 (1.6.2) swapped the flag sides on the Slalom and the Grand Prix: a straight line
    -- passed them. Lap and race bests flown before cannot be beaten fairly, so they start over.
    if lay < 2 then BEST.l[4], BEST.r[4], BEST.l[6], BEST.r[6] = 0, 0, 0, 0 end
    -- layout 3 (1.7.0): Meadow, Dive Tower, Hoop Forest and the Grand Prix are new layouts, not ovals
    if lay < 3 then
      for _, t in ipairs({ 1, 3, 5, 6 }) do BEST.l[t], BEST.r[t], BEST.g[t] = 0, 0, 0 end
    end
  elseif string.sub(s, 1, 6) == "FPVSIM" then
    -- version 1 file: 10 settings, then best lap / race of the first three tracks
    local v, n = {}, 0
    for num in string.gmatch(s, "%-?%d+") do
      n = n + 1
      v[n] = tonumber(num)
    end
    local K1 = { "track", "mode", "rates", "tilt", "fov", "twr", "laps", "map", "sticks", "fps" }
    for i = 1, 10 do
      if v[i] then S[K1[i]] = v[i] end
    end
    S.twr = ({ 3, 4, 6 })[v[6] or 2] or 6
    for t = 2, 2 do                -- (Meadow and Dive Tower have new layouts since 1.7.0)
      BEST.l[t], BEST.r[t] = v[9 + t * 2] or 0, v[10 + t * 2] or 0
    end
  end
  validate()
  if old then saveData() end                       -- under the new name right away
end

saveData = function()
  -- piece by piece: a line grown by concatenation leaves 14-39 KB of strings behind
  local f = io.open(DATA, "w")
  if not f then return end
  io.write(f, "FPVSIM2 lay=3")
  for k, v in pairs(S) do io.write(f, " " .. k .. "=" .. floor(v)) end
  for k, b in pairs(BEST) do
    for t = 1, NT do
      if b[t] > 0 then io.write(f, " " .. k .. t .. "=" .. floor(b[t])) end
    end
  end
  io.write(f, "\n")
  io.close(f)
end
end

-- ----------------------------------------------------------- game state
local px, py, pz, vx, vy, vz = 0, 0.15, 0, 0, 0, 0                 -- quad position / velocity (m, m/s)
local rx, ry, rz, ux, uy, uz, fx, fy, fz = 1, 0, 0, 0, 1, 0, 0, 0, 1 -- quad right / up / forward axes
local sA, sE, sT, sR, speed = 0, 0, 0, 0, 0                           -- sticks, speed
local aTf, aVu, aE2, aW, aS, aF = 0, 0, 0, 0, 0, 0  -- sound state (thrust frac, sink, edge speed, wash, shake)
local DR, NEAR = 0.15, 0.2                                            -- quad radius, camera near plane
local P = { rc = 100, rm = 600, re = 0.5, yc = 100, ym = 500, ye = 0.4, twr = 6, angle = false, tc = 0.9, ts = 0.42,
            wr = 0, wp = 0, wy = 0 }                                  -- settings in use, body rates (rad/s)
local state, prevState, pausedFrom, gmode = MENU, MENU, FLY, 1
local gt, lastT, tState, tStart = 0, 0, 0, 0                          -- game clock in 10 ms ticks
local lapStart, lap, nextGate, lastGate = nil, 0, 1, 0
local R = { laps = {}, n = 0, total = 0, newLap = false, newRace = false, newBest = false, msg = nil, msgT = 0, good = true,
            ready = 0, crashes = 0, cd = -1, fps = 0, fpsN = 0, fpsT = 0, fpsX = "", runS = 0, showS = 0,
            pk = 0, pos = 1, sc = 0, ch = 0, chn = 0, cht = 0, prox = 9, rn = 0, rt = 0, smp = 0,
            fi = 5, pt = 0, st = 0 }          -- frame interval, sim time (10 ms ticks), prop strike left (s)
-- the battery (setting). One pack per class (Racer 5", Freestyle 5", 3" toothpick, Whoop 65mm, Whoop
-- 75mm): cells, capacity (mAh), resistance (milliohm a cell), current at full throttle (A), and the
-- volts a cell has over 4.2 when full (LiHV). In use (applySettings): cells n, capacity mah (1.5 or 2
-- times for 1.5x, 2x), resistance r (ohm), current f (more with more Power), h. The pack's state: charge s (1 full .. 0 empty), cell
-- voltage under load v (filtered over about 1 s), current i (A), flight time t and time since it ran
-- empty e (s), warning w (1 below 3.5 V a cell, 2 below 3.3 V)
local BAT = { "4 1300 6 95 0", "4 1500 6 120 0", "3 550 20 28 .15", "1 300 45 11 .15", "2 300 35 14 .15",
              s = 1, v = 4.2, i = 0, t = 0, e = 0, w = 0 }
BAT.new = function()                                   -- a fresh pack
  BAT.s, BAT.v, BAT.i, BAT.t, BAT.e, BAT.w = 1, 4.2 + BAT.h, 0, 0, 0, 0
end

local function timeStr(cs)
  cs = floor(cs)
  local s = floor(cs / 100)
  if s >= 60 then return fmt("%d:%02d.%02d", floor(s / 60), s % 60, cs % 100) end
  return fmt("%d.%02d", s, cs % 100)
end

-- HUD clocks: lap number, lap time, race time (ticks); frozen once the race is over
local function lapClock()
  if gmode == 1 and state == DONE and R.n > 0 then return S.laps, R.laps[R.n], R.total end
  return lap > 0 and lap or 1, lapStart and gt - lapStart or 0, gt - tStart
end

-- medals: Bronze, Silver and Gold are the lap times of the Easy, Medium and Hard AI pilot with
-- the pilot's class and power, a flying lap along the racing line as AI.update flies it (ticks)
local MED = { 0, 0, 0, n = { "BRONZE", "SILVER", "GOLD" } }
MED.calc = function()
  for m = 1, 3 do
    local vb, v, t = AI.vs[m] * (0.75 + 0.05 * P.twr), 0, 0
    for k = 1, 2 * NG do                     -- the second lap counts: it starts at racing speed
      local i = (k - 1) % NG + 1
      local vt, L = vb * AI.sf[i], AI.sl[i]
      local a = v < vt and 10 or -14
      local d = (vt * vt - v * v) / (2 * a)   -- to the leg's speed
      local dt
      if d > L then
        local v2 = sqrt(v * v + 2 * a * L)
        dt, v = (v2 - v) / a, v2
      else
        dt, v = (vt - v) / a + (L - d) / vt, vt
      end
      if k > NG then t = t + dt end
    end
    MED[m] = floor(t * 100 + 0.5)
  end
end
MED.of = function(t)                         -- 0 none, 1 bronze, 2 silver, 3 gold
  local m = 0
  for i = 1, 3 do
    if t > 0 and t <= MED[i] then m = i end
  end
  return m
end
-- the next medal to fly for on this track ("SILVER 16.48"), or the gold the pilot has; and which
MED.goal = function()
  local m = MED.of(BEST.l[S.track])
  if m == 3 then return MED.n[3], 3 end
  return MED.n[m + 1] .. " " .. timeStr(MED[m + 1]), m + 1
end

local function beep(f, d, flags, p)                   -- p: a pause after the tone (ms)
  if playTone then playTone(f, d, p or 0, flags or 0) end
end

local function showMsg(s, good)
  R.msg, R.msgT, R.good = s, gt, good
end


-- the saves: a new best and a new ghost are written at once (the radio may be switched off any
-- time); the breaks (pause, restart, the menu, a crash, the end of a run) write anything left
R.flush = function()
  if R.dirty then
    R.dirty = false
    saveData()
  end
end

-- -------------------------------------------------------------- physics
local readSticks, rotate, placeDrone, respawn, physics, rnd, trick, tricks, rushNext
;(function()
  local G = 10.78                               -- 1.1 g: a heavier, more planted feel
  local SRC = { "ail", "ele", "thr", "rud" }
  local grounded = true
  local nearG, nearP, nearB = {}, {}, {}
  local Tm = 0                                   -- motor thrust (lags the throttle)
  -- prop wash: shake (rad) and its turning part, wash build-up (0..1), shake size and severity,
  -- thrust loss
  local wob1, wob2, wob3, wq1, wq2, wq3, sW, sH, sV, wl = 0, 0, 0, 0, 0, 0, 0, 0, 1, 0
  local mr, mp = 0, 0                            -- the motors' own roll and pitch rate (flips)
  local kwr, kwp, kwy                            -- body rates a hit adds (rad/s)
  local turtle, hitT = false, 0                  -- on its back on the ground; when a hit last buzzed
  local seed = 7

  rnd = function()
    seed = seed * 171 % 30269
    return seed / 30269
  end

  local function clamp1(v)
    if v > 1 then return 1 elseif v < -1 then return -1 end
    return v
  end

  local hit                                      -- (below: a contact)
  readSticks = function(resolve)
    if resolve then
      for i = 1, 4 do
        local f = getFieldInfo and getFieldInfo(SRC[i])
        if f then SRC[i] = f.id end
      end
      return
    end
    sA = clamp1(getValue(SRC[1]) / 1024)
    sE = clamp1(getValue(SRC[2]) / 1024)
    sR = clamp1(getValue(SRC[4]) / 1024)
    sT = (getValue(SRC[3]) + 1024) / 2048
    if sT < 0 then sT = 0 elseif sT > 1 then sT = 1 end
  end

  -- Betaflight "actual" rates: center sensitivity c, max rate m (deg/s), expo e
  local function rate(x, c, m, e)
    local a = x < 0 and -x or x
    local x2 = x * x
    return (x * c + (m - c) * a * x * (x2 * x2 * e + 1 - e)) * 0.0174533
  end

  rotate = function(ar, ap, ay)
    -- (no '~= 0' on floats: EdgeTX 2.11/2.12 floors floats in int/float equality, so 0.02 ~= 0 is false there)
    if ar > 1e-7 or ar < -1e-7 then  -- roll right
      local c, s = cos(ar), sin(ar)
      local x, y, z, a, b, d = rx, ry, rz, ux, uy, uz
      rx, ry, rz, ux, uy, uz = x * c - a * s, y * c - b * s, z * c - d * s, a * c + x * s, b * c + y * s, d * c + z * s
    end
    if ap > 1e-7 or ap < -1e-7 then  -- pitch nose up
      local c, s = cos(ap), sin(ap)
      local x, y, z, a, b, d = fx, fy, fz, ux, uy, uz
      fx, fy, fz, ux, uy, uz = x * c + a * s, y * c + b * s, z * c + d * s, a * c - x * s, b * c - y * s, d * c - z * s
    end
    if ay > 1e-7 or ay < -1e-7 then  -- yaw right
      local c, s = cos(ay), sin(ay)
      local x, y, z, a, b, d = fx, fy, fz, rx, ry, rz
      fx, fy, fz, rx, ry, rz = x * c + a * s, y * c + b * s, z * c + d * s, a * c - x * s, b * c - y * s, d * c - z * s
    end
  end

  local function orthonormalize()
    local l = 1 / sqrt(fx * fx + fy * fy + fz * fz)
    fx, fy, fz = fx * l, fy * l, fz * l
    local d = rx * fx + ry * fy + rz * fz
    rx, ry, rz = rx - d * fx, ry - d * fy, rz - d * fz
    l = 1 / sqrt(rx * rx + ry * ry + rz * rz)
    rx, ry, rz = rx * l, ry * l, rz * l
    ux, uy, uz = fy * rz - fz * ry, fz * rx - fx * rz, fx * ry - fy * rx
  end

  placeDrone = function(x, y, z, hx, hz)
    px, py, pz, vx, vy, vz = x, y, z, 0, 0, 0
    local l = sqrt(hx * hx + hz * hz)
    if l < 0.01 then hx, hz, l = TR.hx, TR.hz, 1 end
    hx, hz = hx / l, hz / l
    fx, fy, fz, rx, ry, rz, ux, uy, uz = hx, 0, hz, hz, 0, -hx, 0, 1, 0
    grounded = y <= DR + 0.01
    speed, Tm, P.wr, P.wp, P.wy, sW, sH, wob1, wob2, wob3, wq1, wq2, wq3 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    mr, mp, R.st, kwr, turtle = 0, 0, 0, nil, false
    for i = 1, NG do
      gd[i] = (px - gx[i]) * gnx[i] + (py - gy[i]) * gny[i] + (pz - gz[i]) * gnz[i]
    end
  end

  respawn = function()
    if BAT.s <= 0 then BAT.new() end                   -- the pack ran empty: a fresh one
    if gmode == 3 then
      if R.ax then placeDrone(R.ax, R.ay + 0.5, R.az, R.ahx, R.ahz) else placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz) end
    elseif lastGate > 0 then
      local i, j = lastGate, nextGate
      local y = AY[i]
      if gk[i] == 3 then y = y - 1.5 end
      placeDrone(AX[i] + gnx[i] * 1.5, y, AZ[i] + gnz[i] * 1.5, AX[j] - AX[i], AZ[j] - AZ[i])
    else
      placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
    end
  end

  -- why: nil for a crash, "EMPTY" when the battery ran out (shown instead of CRASH, not counted)
  local function crash(why)
    if state == DONE then respawn() return end
    state, tState, R.why = CRASHED, gt, why
    R.flush()
    if not why then R.crashes = R.crashes + 1 end
    if gmode == 3 then
      R.ch, R.chn = 0, 0
      tricks(-1)
    end
    beep(260, 400, PLAY_NOW)
    if playHaptic and S.vib == 1 then playHaptic(60, 0) end
  end

  -- a contact (n: the surface's outward normal): no bounce, the quad stops into the surface and slides
  -- on with friction mu. From 1.5 m/s into it, the hit is a prop strike: for up to half a second the
  -- props lose most of their thrust and the flight controller its hold, and the quad tumbles about
  -- the point that touched (the rim of a disk the size of the quad, nearest the surface; most at 45
  -- deg to it, none flat on), so the pilot has to fly it out. Nothing breaks: no respawn
  hit = function(nx, ny, nz, mu)
    local vn = -(vx * nx + vy * ny + vz * nz)
    if vn <= 0 then return end
    vx, vy, vz = vx + vn * nx, vy + vn * ny, vz + vn * nz
    local vt = sqrt(vx * vx + vy * vy + vz * vz)
    local f = vt > 0.01 and mu * vn / vt or 1
    if f > 1 then f = 1 end
    local jx, jy, jz = vn * nx - vx * f, vn * ny - vy * f, vn * nz - vz * f   -- the impulse (per kg)
    vx, vy, vz = vx * (1 - f), vy * (1 - f), vz * (1 - f)
    if vn < 1.5 then return end
    if gt - hitT > 30 then
      hitT = gt
      beep(160 + vn * 8, 90, PLAY_NOW)
      if playHaptic and S.vib == 1 and vn > 3 then playHaptic(vn > 8 and 60 or 30, 0) end
    end
    -- the props and arms strike only edge-on: flat on (a level landing) the skids take it. Toward the
    -- rim point (length sqrt(1 - d^2)); the turn 3 * c x j is 1.5 rad/s per m/s into a surface at 45
    -- deg, at most 20 rad/s
    local d = nx * ux + ny * uy + nz * uz
    local q = 1 - d * d
    if q < 0 then q = 0 end
    local vs = vn * sqrt(q)
    if vs < 1.5 then return end
    local cx, cy, cz = d * ux - nx, d * uy - ny, d * uz - nz
    local ax, ay, az = (cy * jz - cz * jy) * 3, (cz * jx - cx * jz) * 3, (cx * jy - cy * jx) * 3
    local w = sqrt(ax * ax + ay * ay + az * az)
    if w > 20 then ax, ay, az = ax * 20 / w, ay * 20 / w, az * 20 / w end
    kwr, kwp, kwy = -(ax * fx + ay * fy + az * fz), -(ax * rx + ay * ry + az * rz), ax * ux + ay * uy + az * uz
    local t = vs * 0.04
    if t > 0.5 then t = 0.5 end
    if t > R.st then R.st = t end
    R.crashes, R.hv = R.crashes + 1, vs
    if gmode == 3 then
      R.ch, R.chn = 0, 0
      tricks(-1)
    end
  end

  local function finishRace()
    R.total = gt - tStart
    local t = S.track
    if BEST.r[t] == 0 or R.total < BEST.r[t] then
      BEST.r[t], R.newRace = R.total, true
    end
    local p = 1
    for a = 1, AI.n do
      if AI.d[a] > 0 then p = p + 1 end
    end
    R.pos = p
    state, tState, focus, R.dirty = DONE, gt, 1, true
    R.flush()
    beep(1800, 120)
    beep(2400, 300)
  end

  local function gatePassed(i, fwd)
    if state == DONE then return end
    if gmode == 3 then
      if GSH[gk[i]] ~= 3 then trick("GAP", 150) end
      return
    end
    if i ~= nextGate then return end
    if gmode == 4 then
      R.rn = R.rn + 1
      local b = 6 - R.rn * 0.15
      if b < 2.5 then b = 2.5 end
      R.rt = R.rt + b
      lastGate = i
      rushNext()
      showMsg("GATE " .. R.rn .. "  +" .. fmt("%.1f", b) .. "s", true)
      beep(1300 + R.rn * 30, 60)
      return
    end
    if not fwd then return end
    lastGate, nextGate = i, i % NG + 1
    R.pk = R.pk + 1
    if i == 1 then
      if lapStart then
        local lt = gt - lapStart
        R.n = R.n + 1
        R.laps[R.n] = lt
        local b = BEST.l[S.track]
        if b == 0 or lt < b then
          BEST.l[S.track], R.newLap = lt, true
          local m = MED.of(lt)
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  " .. (m > MED.of(b) and MED.n[m] or "BEST") .. "!", true)
          R.dirty = true
        else
          showMsg("LAP " .. lap .. "  " .. timeStr(lt) .. "  +" .. timeStr(lt - b), false)
        end
        R.flush()                                    -- (now: the radio may be switched off any time)
        lap = lap + 1
        beep(2200, 160)
        if playHaptic and S.vib == 1 then playHaptic(25, 0) end
        if gmode == 1 and lap > S.laps then finishRace() return end
      else
        lap = 1
        beep(1600, 80)
      end
      lapStart = gt
    else
      beep(1300 + i * 60, 60)
    end
  end

  physics = function(dt)
    local Tmax = P.twr * G
    local wr, wp
    if P.angle then
      -- self level: steer the up vector towards the stick-commanded tilt (45 deg at full stick)
      local hx, hz = -rz, rx
      local l = sqrt(hx * hx + hz * hz) + 0.0001
      hx, hz = hx / l, hz / l
      local dx, dz = hx * sE + hz * sA, hz * sE - hx * sA
      wr, wp = 8 * (dx * rx + ry + dz * rz), -8 * (dx * fx + fy + dz * fz)
      if wr > 8 then wr = 8 elseif wr < -8 then wr = -8 end
      if wp > 8 then wp = 8 elseif wp < -8 then wp = -8 end
    else
      wr, wp = rate(sA, P.rc, P.rm, P.re), -rate(sE, P.rc, P.rm, P.re)
    end
    local wy = rate(sR, P.yc, P.ym, P.ye)
    local cwr, cwp = wr, wp                       -- the stick's rates, before the prop wash shake (the mixer's)
    -- stick -> thrust: idle (min_throttle), the bottom dead zone, then the class curve (rpm ~ stick, thrust ~ rpm^2)
    local tx = (sT - P.dz) / (1 - P.dz)
    if tx < 0 then tx = 0 end
    local T = Tmax * (P.i0 + (1 - P.i0) * ((1 - P.tk) * tx ^ P.tn + P.tk * tx ^ 8))
    -- the battery (setting, off by default): the current grows with thrust^1.5 (momentum theory; 5%
    -- of full at idle for the motors and electronics) and the cells sag by current x resistance from
    -- their rest voltage. Down to 3.5 V a cell under load the quad flies as without it (Betaflight's
    -- sag compensation: a fresh pack flies as before, a lap never gets faster), below that the thrust
    -- falls with the voltage squared. Near empty the cells give no more current than takes them to
    -- 3.0 V: the quad limps (thrust ~ current^(2/3)). Empty when full throttle would lift no more than
    -- 1.25 times the weight: the motors stop
    if S.batt > 0 then
      local s, c, r, f = BAT.s, T / Tmax, BAT.r, BAT.f
      local I = f * (0.05 + 0.95 * c * sqrt(c))
      local v = (s >= 0.8 and 3.98 + 1.1 * (s - 0.8) or s >= 0.12 and 3.66 + 0.47 * (s - 0.12) or 3 + 5.5 * s) + BAT.h * s
      local im, k, t = (v - 3) / r, 1, BAT.t + dt
      if I <= im then
        v = v - I * r
        if v < 3.5 then k = v * v / 12.25 end
      else
        k, I, v = 0.735 * (im / I) ^ 0.67, im, 3
      end
      s = s - I * dt / (3.6 * BAT.mah)
      -- empty once full throttle would lift no more than 1.25 times the weight: limping on, it could
      -- hardly fly any more
      local km = im <= 0 and 0 or im < f and 0.735 * (im / f) ^ 0.67 or 1
      if km * P.twr < 1.25 then
        s, k, I = 0, 0, 0
        BAT.e = BAT.e + dt                             -- empty: the quad drops, a second later EMPTY
        if BAT.e > 1 then crash("EMPTY") return end
      end
      v = BAT.v + (v - BAT.v) * (dt < 1 and dt or 1)
      -- warnings: below 3.5 V a cell a beep every 2 s of flight, below 3.3 V a double beep (and LAND)
      local w = v < 3.3 and 2 or v < 3.5 and 1 or 0
      if w > 0 and floor(t * 0.5) > floor(BAT.t * 0.5) then
        beep(660, 150, 0, 100)
        if w > 1 then
          beep(660, 150)
          showMsg("LAND")
        end
      end
      BAT.s, BAT.i, BAT.v, BAT.t, BAT.w = s, I, v, t, w
      T = T * k
    end
    -- prop wash (setting, off by default): sinking into your own downwash. The props build up a
    -- wash over ~0.2 s while they move down their own axis, less the faster they also move edgewise.
    -- It costs thrust (up to wl, from a 0.6 m/s sink until it fades out at wv m/s: the quad sinks
    -- and feels mushy) and shakes it.
    wl = 0
    if S.wash > 0 then
      local vu0 = vx * ux + vy * uy + vz * uz
      if vu0 < 0 then
        local vr0, vf0 = vx * rx + vy * ry + vz * rz, vx * fx + vy * fy + vz * fz
        local k = dt * 5
        if k > 1 then k = 1 end
        sW = sW + (1 / (1 + sqrt(vr0 * vr0 + vf0 * vf0)) - sW) * k
        if vu0 < -0.6 then
          local f = (P.wv + vu0) / (P.wv - 2)
          if f > 1 then f = 1 elseif f < 0 then f = 0 end
          wl = P.wl * sW * f
        end
      end
      -- the shake: the props chop through their own turbulent wake and the quad rings at its wash
      -- frequency. Sized from real Betaflight blackbox logs: pw is the jitter's rms in degrees at full
      -- wash with the throttle chopped (tenths of a degree; about half with throttle on, when the
      -- motors have the authority to fight it), each wash its own severity. From a 0.5 m/s sink, gone
      -- in forward flight, no drift (the rates are its steps); the wake keeps buffeting it for ~0.2 s
      -- after the sink stops
      local a = 0
      if vu0 < -0.5 and dt > 0 then
        a = (-vu0 - 0.5) * 0.5
        if a > 1 then a = 1 end
        local th = sT * 2 - 0.2
        if th < 0 then th = 0 elseif th > 1 then th = 1 end
        if sH < 1e-4 then sV = 0.4 + 1.8 * rnd() ^ 2 end   -- a new wash: how bad this one is
        a = a * sW * (1 - 0.45 * th) * sV * P.pw * 0.0504  -- rad: its rms is 0.346 a
      end
      local k = dt * 5
      if k > 1 then k = 1 end
      if a < sH then a = sH + (a - sH) * k end
      sH = a
      local rh = dt * 9                                -- the same jitter at any frame rate:
      if rh > 1 then rh = 1 end                        -- 0.55 of it kept per 50 ms frame
      local g = a * sqrt(rh * (2 - rh)) * 1.2
      -- each axis is a fading phasor turning at the class's wash frequency (real quads: 20-45 Hz);
      -- past what the frame rate can show, as fast as the screen can (2.5 rad a frame)
      local w = dt * P.pf * 6.283
      if w > 2.5 then w = 2.5 end
      local c, s = cos(w) * (1 - rh), sin(w) * (1 - rh)
      local j1, j2, j3 = wob1 * c - wq1 * s + (rnd() - 0.5) * g, wob2 * c - wq2 * s + (rnd() - 0.5) * g,
        wob3 * c - wq3 * s + (rnd() - 0.5) * g * 0.35
      if dt > 0 then
        wr, wp, wy = wr + (j1 - wob1) / dt, wp + (j2 - wob2) / dt, wy + (j3 - wob3) / dt
        wq1, wq2, wq3 = wob1 * s + wq1 * c + (rnd() - 0.5) * g, wob2 * s + wq2 * c + (rnd() - 0.5) * g,
          wob3 * s + wq3 * c + (rnd() - 0.5) * g * 0.35
        wob1, wob2, wob3 = j1, j2, j3
      end
    end
    if grounded and uy < 0.4 then
      -- on its back or side on the ground (or a roof): the props can't lift it. Turtle mode: a roll
      -- or pitch stick spins two motors backwards and flips it back over
      wr = sA > 0.25 and 3.5 or sA < -0.25 and -3.5 or 0
      wp = sE > 0.25 and -3.5 or sE < -0.25 and 3.5 or 0
      wy, T, R.st, kwr = 0, 0, 0, nil
      P.wr, P.wp, P.wy, mr, mp, cwr, cwp = wr, wp, 0, 0, 0, 0, 0
      if not turtle then
        turtle = true
        showMsg("roll to flip", false)
      end
    else
      turtle = false
      if grounded and T < G * 1.02 and speed < 2 then
        -- resting on the ground (once a skid has slowed down): stays level, can only yaw
        wr, wp, P.wr, P.wp, mr, mp, cwr, cwp = 0, 0, 0, 0, 0, 0, 0, 0
        if uy < 0.999 then placeDrone(px, py, pz, fx, fz) end
      end
    end
    -- wind with gusts, weaker near the ground
    local wx, wz = 0, 0
    if S.wind > 0 and py > 0.3 then
      local g = (S.wind == 1 and 3 or 7) * (1 + 0.3 * sin(gt * 0.009) + 0.2 * sin(gt * 0.031))
      if py < 4 then g = g * py * 0.25 end
      wx, wz = TR.wx * g, TR.wz * g
    end
    local n = floor(dt * 80) + 1
    local h = dt / n
    local km, kr, ky = h / (P.tm + h), h / (P.tr + h), h / (P.ty + h)
    local VP, VK, VC, KS, KF, KU = P.vp, P.vk, P.vc, P.ks, P.kf, P.ku
    local TL, VT2, TE, TA, ER, VD, LR, GG, GL, GW = P.tl, P.vt * P.vt, P.te, P.ta, P.er, P.vd, P.lr, P.gg, P.gl, P.gw
    local SQ, CQ, CE, SE, RF, RQ, TB = P.sq, P.cq, P.ce, P.se, P.rf, P.rq, P.tb
    local KH = (P.kh or 0) * (S.grip == 2 and 1 or S.grip == 1 and 0.4 or 0)
    -- flips (an airmode mixer): the motors' own rate follows the stick's rate no faster than am (more
    -- toward full throttle; both fitted to the reference's thrust while a flip starts); while it catches
    -- up they need a differential on top of the collective: at full throttle the collective drops (the
    -- high side can't go higher), near hover it rises (the low side can't go below idle). Levels in
    -- motor command (thrust ~ c^2)
    local I0 = P.i0
    local ch, c0 = (1 / P.twr - I0) / (1 - I0), (T / Tmax - I0) / (1 - I0)
    ch, c0 = ch > 0 and sqrt(ch) or 0, c0 > 0 and sqrt(c0) or 0
    local AM = 1 - ch + c0
    if AM < 0.3 then AM = 0.3 end
    AM = P.am * AM * h
    local x0, x1, z0, z1 = TR.x0 - 160, TR.x1 + 160, TR.z0 - 160, TR.z1 + 160
    local bx0, bx1, by0, by1, bz0, bz1 = BX.x0, BX.x1, BX.y0, BX.y1, BX.z0, BX.z1
    -- broad phase once per frame: only objects within reach get tested per substep
    local reach = speed * dt + 7
    local ng, np, nb = 0, 0, 0
    do
      local x, y, z = px, py, pz
      for i = 1, NG do
        local dx, dy, dz = x - gx[i], y - gy[i], z - gz[i]
        local r = GSH[gk[i]] == 3 and reach + 6 or reach
        if dx < r and dx > -r and dy < r and dy > -r and dz < r and dz > -r then
          ng = ng + 1
          nearG[ng] = i
        else
          gd[i] = dx * gnx[i] + dy * gny[i] + dz * gnz[i]   -- keep the side-of-plane fresh
        end
      end
      for i = 1, NP do
        local dx, r = x - qx[i], reach + qr[i]
        if dx < r and dx > -r then
          local dz = z - qz[i]
          if dz < r and dz > -r then
            np = np + 1
            nearP[np] = i
          end
        end
      end
      for i = 1, BX.n do
        if x > bx0[i] - reach and x < bx1[i] + reach and z > bz0[i] - reach and z < bz1[i] + reach and y < by1[i] + reach then
          nb = nb + 1
          nearB[nb] = i
        end
      end
    end
    -- the surface under the quad, for ground effect: the ground, or the top of a structure
    local fl = 0
    for j = 1, nb do
      local i = nearB[j]
      if px > bx0[i] and px < bx1[i] and pz > bz0[i] and pz < bz1[i] and py > by1[i] and by1[i] > fl then fl = by1[i] end
    end
    local pwr, pwp, pwy = P.wr, P.wp, P.wy
    for _ = 1, n do
      Tm = Tm + (T - Tm) * km
      if kwr then pwr, pwp, pwy, kwr = pwr + kwr, pwp + kwp, pwy + kwy, nil end
      local st = R.st
      if st > 0 then
        -- a prop strike: the flight controller has lost its hold, the quad tumbles on
        R.st = st - h
        local k = 1 - 1.5 * h
        pwr, pwp, pwy = pwr * k, pwp * k, pwy * k
      else
        pwr, pwp, pwy = pwr + (wr - pwr) * kr, pwp + (wp - pwp) * kr, pwy + (wy - pwy) * ky
      end
      rotate(pwr * h, pwp * h, pwy * h)
      -- the flip's differential d (half of it, as a share of the motors' range; roll and pitch add up
      -- on a motor) and the collective Te it leaves
      local Te = Tm
      if AM > 0 then
        local dr, dp = cwr - mr, cwp - mp
        if dr > AM then dr = AM elseif dr < -AM then dr = -AM end
        if dp > AM then dp = AM elseif dp < -AM then dp = -AM end
        mr, mp = mr + dr, mp + dp
        local d = ((dr < 0 and -dr or dr) + (dp < 0 and -dp or dp)) / AM * 0.5
        if d > 1e-4 then
          if d > 0.5 then d = 0.5 end
          local c = (Tm / Tmax - I0) / (1 - I0)
          c = c > 0 and sqrt(c) or 0
          if c + d > 1 then c = 1 - d end
          if c < d then c = d end
          Te = Tmax * (I0 + (1 - I0) * (c * c + d * d))
        end
      end
      if st > 0 then Te = Te * 0.3 end              -- struck props: most of the thrust gone
      -- air-relative velocity in body axes
      local ax_, az_ = vx - wx, vz - wz
      local vu = ax_ * ux + vy * uy + az_ * uz
      local vr = ax_ * rx + vy * ry + az_ * rz
      local vf = ax_ * fx + vy * fy + az_ * fz
      -- props lose thrust as the air through them speeds up (climbing) and gain thrust sinking,
      -- until the blades stall in a fast drop
      local tf = Te / Tmax                              -- thrust fraction
      local Ta
      if vu < 0 then
        -- descending: a cushion that rises to cq at a sink of sq*tf^se, then stalls away (to rf + rq*tf:
        -- with power the blades hold their thrust, at idle they stall)
        local x = 9
        if tf > 0.001 then x = -vu / (SQ * tf ^ SE) end
        local r = 1 + (CQ - 1) * (1 - CE * tf) * (2 * x - x * x)
        local fl = RF + RQ * tf
        if fl > 1 then fl = 1 end
        if r < fl then r = fl end
        Ta = Te * r
      else
        if Te > 0.001 then                            -- the loss grows with thrust as T*(Tmax/T)^VC
          local den = VP + vu * VK                    -- and bends with VK as the inflow grows
          if den < VP * 0.3 then den = VP * 0.3 end
          Ta = Te - vu * Te * (Tmax / Te) ^ VC / den
        else
          Ta = 0
        end
        if Ta < 0 then Ta = 0 end
      end
      Ta = Ta * (1 - wl)
      -- translational lift: flying edgewise the props reach fresh air, the induced inflow drops
      -- and the same rpm gives more thrust (a 5" at hover throttle: about +20% at 6 m/s, levelling off near +50%)
      local e2 = vr * vr + vf * vf
      -- the gain grows with throttle (tb), fades near full stick (te) and as air comes through the
      -- props axially (ta, m/s)
      local t2 = tf * tf
      local fa = 1 - TE * t2 * t2
      if fa < 0 then fa = 0 end
      fa = fa * (1 + TB * tf)
      if vu > 0 then fa = fa / (1 + vu / TA) end
      Ta = Ta * (1 + TL * fa * e2 / (e2 + VT2))
      -- ground effect: within a twentieth of the prop diameter of the ground or a roof the props
      -- push their inflow against it (measured along body-down): up to
      -- +25% on a 5", +45% on a 3". Less when tilted (the ray is longer), fades with speed.
      if uy > 0.3 then
        local d = (py - fl - DR) / uy + 0.03
        if d < GL then
          local k = (GL - d) / GW
          if k > 1 then k = 1 end
          Ta = Ta * (1 + GG * k / (1 + e2 * 0.0125))
        end
      end
      -- body drag along the flow: each face's area weighted by the flow through it
      -- (a = -S v), somewhat more at low speed. No rotor drag: the quad keeps its momentum.
      local au, ar, af = Ta, 0, 0
      local v2 = vu * vu + e2
      if v2 > 1e-4 then
        local v = sqrt(v2)
        local S_ = KS * (vr < 0 and -vr or vr) + KU * (vu < 0 and -vu or vu) + KF * (vf < 0 and -vf or vf)
        local xd = v / VD
        if xd > 1 then xd = 1 end
        S_ = S_ * (1 + ER * (1 - xd * xd * (3 - 2 * xd)))
        au, ar, af = Ta - S_ * vu, -S_ * vr, -S_ * vf
        -- frame lift: air on the top of the frame (nose down at speed) pushes it down, air under
        -- the belly lifts it; strongest with the flow 45 deg to the frame, across the flow
        local sn = vu / v
        local c2 = 1 - sn * sn
        if c2 > 1e-4 then
          local c = sqrt(c2)
          local q = LR * sn * 0.813 * (2 * (sn < 0 and -sn or sn) * c) ^ 0.6 * S_ * v / c
          au = au - q * c2
          q = q * sn / v
          ar, af = ar + q * vr, af + q * vf
        end
      end
      -- rotor drag (the Grip setting; the reference model has none: Low): props moving edgewise are
      -- pushed back, harder the faster they spin (~ sqrt of the thrust)
      if KH > 0 then
        local k = KH * sqrt(Te * 0.0186 + 0.02)            -- 0.0186 = 1 / (5 G)
        ar, af = ar - k * vr, af - k * vf
      end
      vx = vx + (ux * au + rx * ar + fx * af) * h
      vy = vy + (uy * au + ry * ar + fy * af - G) * h
      vz = vz + (uz * au + rz * ar + fz * af) * h
      local ox, oy, oz = px, py, pz
      px, py, pz = px + vx * h, py + vy * h, pz + vz * h
      grounded = false
      if py < DR then
        py, grounded = DR, true
        if vy < 0 then hit(0, 1, 0, 0.6) end
        local fr = 1 - 7 * h
        vx, vz = vx * fr, vz * fr
      end
      if py > 250 or px < x0 or px > x1 or pz < z0 or pz > z1 then crash() return end
      -- gates: detect crossings of each nearby gate plane
      for j = 1, ng do
        local i = nearG[j]
        local cx, cy, cz = gx[i], gy[i], gz[i]
        local d1 = (px - cx) * gnx[i] + (py - cy) * gny[i] + (pz - cz) * gnz[i]
        local d0 = gd[i]
        gd[i] = d1
        if (d0 < 0) ~= (d1 < 0) then
          local t = d0 / (d0 - d1)
          local qx_, qy_, qz_ = ox + (px - ox) * t - cx, oy + (py - oy) * t - cy, oz + (pz - oz) * t - cz
          local lx = qx_ * grx[i] + qz_ * grz[i]
          local ly = qx_ * gax[i] + qy_ * gay[i] + qz_ * gaz[i]
          local k = gk[i]
          local iw, ih, sh = GHW[k], GHH[k], GSH[k]
          local bump = false
          if sh == 2 then
            local r2, a, b = lx * lx + ly * ly, iw - DR * 0.5, iw + GT + DR
            if r2 < a * a then gatePassed(i, d1 >= 0)
            elseif r2 < b * b then bump = true end
          else
            if lx < 0 then lx = -lx end
            if ly < 0 then ly = -ly end
            if lx < iw - DR * 0.5 and ly < ih - DR * 0.5 then gatePassed(i, d1 >= 0)
            elseif sh == 1 and lx < iw + GT + DR and ly < ih + GT + DR then bump = true end
          end
          if bump then
            -- the frame or rim: back on the side it came from, against it
            local sg = d0 < 0 and -1 or 1
            local m = sg * (GT * 0.5 + DR)
            local e = m - d1
            px, py, pz = px + gnx[i] * e, py + gny[i] * e, pz + gnz[i] * e
            gd[i] = m
            hit(gnx[i] * sg, gny[i] * sg, gnz[i] * sg, 0.3)
          end
          if state ~= FLY and state ~= DONE then return end
        end
      end
      -- trees, legs, poles and structures
      for j = 1, np do
        local i = nearP[j]
        local dx, dz, r = px - qx[i], pz - qz[i], qr[i] + DR
        if dx < r and dx > -r and dz < r and dz > -r and py < qh[i] and dx * dx + dz * dz < r * r then
          -- out from the middle of the trunk or pole
          if dx * dx + dz * dz < 1e-4 then dx, dz = ox - qx[i], oz - qz[i] + 0.01 end
          local l = sqrt(dx * dx + dz * dz)
          dx, dz = dx / l, dz / l
          px, pz = qx[i] + dx * r, qz[i] + dz * r
          hit(dx, 0, dz, 0.3)
        end
      end
      for j = 1, nb do
        local i = nearB[j]
        local a0, a1, b0, b1, c0, c1 = bx0[i] - DR, bx1[i] + DR, by0[i] - DR, by1[i] + DR, bz0[i] - DR, bz1[i] + DR
        if px > a0 and px < a1 and pz > c0 and pz < c1 and py < b1 and py > b0 then
          -- out through the face it came in by: the one it crossed last on the way, else the nearest
          local t, k = -1, 0
          local mx, my, mz = px - ox, py - oy, pz - oz
          if ox <= a0 and mx > 0 and (a0 - ox) / mx > t then t, k = (a0 - ox) / mx, 1 end
          if ox >= a1 and mx < 0 and (a1 - ox) / mx > t then t, k = (a1 - ox) / mx, 2 end
          if oz <= c0 and mz > 0 and (c0 - oz) / mz > t then t, k = (c0 - oz) / mz, 3 end
          if oz >= c1 and mz < 0 and (c1 - oz) / mz > t then t, k = (c1 - oz) / mz, 4 end
          if oy >= b1 and my < 0 and (b1 - oy) / my > t then t, k = (b1 - oy) / my, 5 end
          if oy <= b0 and my > 0 and (b0 - oy) / my > t then k = 6 end
          if k == 0 then
            t, k = px - a0, 1
            if a1 - px < t then t, k = a1 - px, 2 end
            if pz - c0 < t then t, k = pz - c0, 3 end
            if c1 - pz < t then t, k = c1 - pz, 4 end
            if b1 - py < t then k = 5 end
          end
          if k == 1 then px = a0 hit(-1, 0, 0, 0.3)
          elseif k == 2 then px = a1 hit(1, 0, 0, 0.3)
          elseif k == 3 then pz = c0 hit(0, 0, -1, 0.3)
          elseif k == 4 then pz = c1 hit(0, 0, 1, 0.3)
          elseif k == 5 then
            -- the roof: like the ground
            py, grounded = b1, true
            hit(0, 1, 0, 0.6)
            local fr = 1 - 7 * h
            vx, vz = vx * fr, vz * fr
          else py = b0 hit(0, -1, 0, 0.3) end
        end
      end
    end
    P.wr, P.wp, P.wy = pwr, pwp, pwy
    orthonormalize()
    speed = sqrt(vx * vx + vy * vy + vz * vz)
    if gmode == 3 then
      -- distance to the nearest surface, for proximity tricks
      local m = py + 0.7
      for j = 1, np do
        local i = nearP[j]
        if py < qh[i] then
          local dx, dz = px - qx[i], pz - qz[i]
          local d = sqrt(dx * dx + dz * dz) - qr[i]
          if d < m then m = d end
        end
      end
      for j = 1, nb do
        local i = nearB[j]
        local dx, dy, dz = bx0[i] - px, by0[i] - py, bz0[i] - pz
        if px - bx1[i] > dx then dx = px - bx1[i] end
        if py - by1[i] > dy then dy = py - by1[i] end
        if pz - bz1[i] > dz then dz = pz - bz1[i] end
        if dx < 0 then dx = 0 end
        if dy < 0 then dy = 0 end
        if dz < 0 then dz = 0 end
        local d = sqrt(dx * dx + dy * dy + dz * dz)
        if d < m then m = d end
      end
      R.prox = m
    end
  end
end)()

-- ----------------------------------------------------- freestyle tricks
;(function()
  local acc, t0, idle, thr, nrot = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
  local hiY, hiT, inv, prox = 0, 0, 0, 0
  local NAME = { "ROLL", "ROLL", "BACKFLIP", "FRONTFLIP", "360", "360" }
  local PTS = { 100, 100, 50 }

  local function mult()
    local m = 1 + (R.chn - 1) * 0.5
    if m > 4 then m = 4 end
    return m
  end

  trick = function(name, pts)
    pts = floor(pts)
    R.ch, R.chn, R.cht = R.ch + pts, R.chn + 1, gt
    showMsg(name .. " +" .. pts, true)
    beep(1400 + R.chn * 120, 50)
  end

  local function bank()
    local v = floor(R.ch * mult())
    R.sc = R.sc + v
    if v > BEST.f[S.track] then
      BEST.f[S.track], R.newBest, R.dirty = v, true, true
      showMsg("COMBO " .. v .. "  BEST!", true)
      beep(2400, 200)
      R.flush()
    elseif R.chn > 1 then
      showMsg("COMBO " .. v, true)
    end
    R.ch, R.chn = 0, 0
  end

  -- continuous rotation about one body axis: 330 deg counts as a full turn
  local function axis(a, w, dt)
    local s = acc[a]
    if (w > 1.5 and s >= 0) or (w < -1.5 and s <= 0) then
      if nrot[a] < 1 and s > -0.01 and s < 0.01 then t0[a], thr[a] = gt, 0 end
      s = s + w * dt
      thr[a] = thr[a] + sT * dt
      idle[a] = 0
      local need = 5.76 + nrot[a] * 6.2832
      if s > need or s < -need then
        nrot[a] = nrot[a] + 1
        local dur = (gt - t0[a]) * 0.01
        local name, pts = NAME[a * 2 - (s > 0 and 1 or 0)], PTS[a]
        if a == 2 and s > 0 and dur > 0.8 and thr[a] > dur * 0.4 then name, pts = "POWER LOOP", 250 end
        if nrot[a] == 2 then name, pts = "DOUBLE " .. name, pts * 1.5
        elseif nrot[a] > 2 then name, pts = "MULTI " .. name, pts * 2 end
        trick(name, pts)
        t0[a], thr[a] = gt, 0
      end
    else
      idle[a] = idle[a] + dt
      if idle[a] > 0.3 then s, nrot[a] = 0, 0 end
    end
    acc[a] = s
  end

  tricks = function(dt)
    if dt < 0 or R.st > 0 then                 -- (a tumble after a hit is no trick)
      for a = 1, 3 do acc[a], nrot[a], idle[a] = 0, 0, 0 end
      hiY, inv, prox = 0, 0, 0
      return
    end
    axis(1, P.wr, dt)
    axis(2, P.wp, dt)
    axis(3, P.wy, dt)
    -- dive: a fast drop of 10 m or more that ends under control
    if py > hiY or gt - hiT > 200 then hiY, hiT = py, gt end
    if hiY - py > 10 and vy > -2 then
      trick("DIVE " .. floor(hiY - py) .. "m", 60 + (hiY - py) * 6)
      hiY, hiT = py, gt
    end
    if uy < -0.5 then inv = inv + dt
    else
      if inv > 0.8 then trick("HANG TIME", inv * 60) end
      inv = 0
    end
    if R.prox < 1.5 and speed > 8 then prox = prox + dt
    else
      if prox > 0.3 then trick("PROXY", prox * 150) end
      prox = 0
    end
    if R.chn > 0 and gt - R.cht > 250 then bank() end
  end
end)()

-- ------------------------------------------------- gate rush, AI pilots
rushNext = function()
  local j = nextGate
  for _ = 1, 30 do
    j = floor(rnd() * NG) + 1
    if j > NG then j = NG end
    if j ~= nextGate and j ~= lastGate and GSH[gk[j]] ~= 3 then break end
  end
  nextGate = j
end

AI.start = function()
  local n = gmode == 1 and S.ai or 0
  AI.n = n
  AI.vt = AI.vs[S.skill] * (0.75 + 0.05 * P.twr)
  for a = 1, n do
    local L = a == 1 and 2.2 or (a == 2 and -2.2 or 0)
    local B = a == 3 and 3 or 0
    local x, z = TR.px + TR.hz * L - TR.hx * B, TR.pz - TR.hx * L - TR.hz * B
    local dx, dz = AX[1] - x, AZ[1] - z
    AI.x0[a], AI.z0[a], AI.l0[a] = x, z, sqrt(dx * dx + dz * dz) + 0.01
    AI.x[a], AI.y[a], AI.z[a] = x, DR, z
    AI.seg[a], AI.k[a], AI.s[a], AI.v[a], AI.d[a] = 0, 0, 0, 0, 0
    AI.f[a] = 1.02 - 0.04 * a + rnd() * 0.04
    AI.o[a] = L * 0.25
  end
end

AI.update = function(dt)
  local last = S.laps * NG + 1
  for a = 1, AI.n do
    local seg = AI.seg[a]
    local vt, L = AI.vt * AI.f[a], AI.l0[a]
    if seg > 0 then L, vt = AI.sl[seg], vt * AI.sf[seg] end
    if AI.d[a] > 0 then vt = vt * 0.6 end
    local v = AI.v[a]
    if v < vt then
      v = v + 10 * dt
      if v > vt then v = vt end
    else
      v = v - 14 * dt
      if v < vt then v = vt end
    end
    AI.v[a] = v
    local s = AI.s[a] + v * dt / L
    if s >= 1 then
      s = s - 1
      if s > 0.9 then s = 0.9 end
      seg = seg % NG + 1
      AI.seg[a], AI.k[a] = seg, AI.k[a] + 1
      if AI.k[a] == last and AI.d[a] <= 0 then AI.d[a] = gt - tStart end
    end
    AI.s[a] = s
    local x, y, z
    if seg == 0 then
      x, y, z = AI.x0[a] + (AX[1] - AI.x0[a]) * s, DR + (AY[1] - DR) * s, AI.z0[a] + (AZ[1] - AI.z0[a]) * s
    else
      x, y, z = AI.pos(seg, s)
      local j, o = seg % NG + 1, AI.o[a]
      x = x + (grx[seg] + (grx[j] - grx[seg]) * s) * o
      z = z + (grz[seg] + (grz[j] - grz[seg]) * s) * o
      if y < 0.4 then y = 0.4 end
    end
    AI.x[a], AI.y[a], AI.z[a] = x, y, z
  end
end

-- race position: 1 + AI pilots ahead of the player
AI.place = function()
  local pk, pf = R.pk, 0
  local i = nextGate
  local dx, dy, dz = AX[i] - px, AY[i] - py, AZ[i] - pz
  local d = sqrt(dx * dx + dy * dy + dz * dz)
  local L = pk > 0 and AI.sl[lastGate] or 14
  pf = 1 - d / L
  local p = 1
  for a = 1, AI.n do
    local k = AI.k[a]
    if AI.d[a] > 0 or k > pk or (k == pk and AI.s[a] > pf) then p = p + 1 end
  end
  return p
end

-- --------------------------------------------------------------- camera
local kpx, kpy, kpz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1
local PORTRAIT = H > W
local VX, VY, VW, VH = 0, 0, W, H
if PORTRAIT then VH = floor(W * 3 / 4) end
local CX, CY = VX + VW / 2, VY + VH / 2
local SC = VW / 128
local F, tanH = 160, 1.4

-- FPV camera, rendered where the quad will be when the frame reaches the screen. Color
-- screens show a frame one script cycle after it is drawn (50 ms on stock EdgeTX), so the
-- prediction follows the measured frame interval and stays right on faster firmware too.
-- STICKTIME_LAT (seconds) overrides it, e.g. in the emulator when frames show at once
-- (FPVSIM_LAT: its name before the rename to StickTime). StickTime BW on a color radio has
-- the color screen's delay too: its color.lua sets STICKTIME_LATK to the color factor.
-- The turn is predicted over a third of that time only: the stick can center at any moment,
-- and a fast roll drawn the whole delay ahead overshoots for a frame and swings back when it
-- stops (about 35 deg at 850 deg/s). A third is about as long as the quad keeps turning after
-- the stick centers, so the picture no longer swings back, and still gains 20 ms.
local function fpvCamera()
  local c, s = P.tc, P.ts
  local d = (state == FLY or state == DONE) and (STICKTIME_LAT or FPVSIM_LAT or R.fi * (STICKTIME_LATK or 0.003)) or 0
  local a1, a2, a3, b1, b2, b3, e1, e2, e3 = rx, ry, rz, ux, uy, uz, fx, fy, fz
  local dr = d * 0.35
  if d > 0 then rotate(P.wr * dr, P.wp * dr, P.wy * dr) end
  kpx, kpy, kpz = px + vx * d, py + vy * d, pz + vz * d
  if kpy < 0.05 then kpy = 0.05 end
  krx, kry, krz = rx, ry, rz
  kfx, kfy, kfz = fx * c + ux * s, fy * c + uy * s, fz * c + uz * s
  kux, kuy, kuz = ux * c - fx * s, uy * c - fy * s, uz * c - fz * s
  rx, ry, rz, ux, uy, uz, fx, fy, fz = a1, a2, a3, b1, b2, b3, e1, e2, e3
end

local function orbitCamera()
  local a = gt * 0.0012
  local cxw, czw = (TR.x0 + TR.x1) * 0.5, (TR.z0 + TR.z1) * 0.5
  local r = (TR.x1 - TR.x0 + TR.z1 - TR.z0) * 0.35 + 18
  kpx, kpy, kpz = cxw + r * sin(a), 9 + 3 * sin(a * 1.7), czw + r * cos(a)
  local dx, dy, dz = cxw - kpx, 1 - kpy, czw - kpz
  local l = sqrt(dx * dx + dy * dy + dz * dz)
  kfx, kfy, kfz = dx / l, dy / l, dz / l
  l = sqrt(kfx * kfx + kfz * kfz)
  krx, kry, krz = kfz / l, 0, -kfx / l
  kux, kuy, kuz = kfy * krz - kfz * kry, kfz * krx - kfx * krz, kfx * kry - kfy * krx
end

local function applySettings()
  local r = RATES[S.rates]
  if r then
    P.rc, P.rm, P.re, P.yc, P.ym, P.ye = r[1], r[2], r[3] * 0.01, r[4], r[5], r[6] * 0.01
  else
    P.rc, P.rm, P.re, P.yc, P.ym, P.ye = S.rc, S.rm, S.re * 0.01, S.yc, S.ym, S.ye * 0.01
  end
  local i = 0
  for v in string.gmatch(QP[S.quad] or QP[1], "%S+") do
    i = i + 1
    P[QK[i]] = tonumber(v)
  end
  local n, c, o, f, h = string.match(BAT[S.quad] or BAT[1], "(%S+) (%S+) (%S+) (%S+) (%S+)")   -- the class's pack
  BAT.n, BAT.mah, BAT.r, BAT.f, BAT.h = tonumber(n), tonumber(c) * (S.batt == 2 and 2 or S.batt == 3 and 1.5 or 1), tonumber(o) * 0.001, tonumber(f), tonumber(h)
  if S.twr > 0 and (S.twr < P.tlo or S.twr > P.thi) then S.twr = 0 end   -- not for this class: Stock
  if S.twr > 0 then
    -- the class's motors and props for this Power draw more at full throttle (hover current the same)
    BAT.f = BAT.f * (S.twr / P.twr) ^ 1.5
    P.twr = S.twr                           -- 0: the class's stock power
  end
  if S.wash == 1 then P.wl, P.wv, P.pw = P.wls, P.wvs, P.pws end  -- Stock: the class's own wash
  P.angle = S.mode == 2
  local t = S.tilt * 0.0174533
  P.tc, P.ts = cos(t), sin(t)
  tanH = sin(S.fov * 0.00872665) / cos(S.fov * 0.00872665)
  F = (VW / 2) / tanH
  MED.calc()
end

-- visible objects, drawn far -> near (painter's algorithm). ids: gates 1..NG, trees -i,
-- boxes 1000+b, AI pilots 2000+a. ordP holds the draw order (indices into the ord* arrays).
local ordZ, ordI, ordP, nOrd = {}, {}, {}, 0
local collectObjects
do

  collectObjects = function(maxZ)
    local n1 = NG + NP
    local n2 = n1 + BX.n
    local kpx, kpy, kpz, kfx, kfy, kfz, krx, kry, krz, tanH, no = kpx, kpy, kpz, kfx, kfy, kfz, krx, kry, krz, tanH, 0
    for n = 1, n2 + (gmode == 1 and AI.n or 0) do
      local id, X, Y, Z, rad = n, 0, 0, 0, 4
      if n <= NG then
        X, Y, Z = gx[n] - kpx, gy[n] - kpy, gz[n] - kpz
        local k = gk[n]
        if GSH[k] == 3 then rad = 9 elseif k == 2 or k == 3 then rad = 7 end
      elseif n <= n1 then
        local i = n - NG
        if qk[i] == 1 then
          X, Y, Z = qx[i] - kpx, qh[i] * 0.4 - kpy, qz[i] - kpz
          rad = qh[i]
        else
          Z = -1e9
        end
        id = -i
      elseif n <= n2 then
        local b = n - n1
        local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
        X, Y, Z = (x0 + x1) * 0.5 - kpx, (y0 + y1) * 0.5 - kpy, (z0 + z1) * 0.5 - kpz
        rad = (x1 - x0 + y1 - y0 + z1 - z0) * 0.5
        id = 1000 + b
      else
        local a = n - n2
        X, Y, Z = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz
        rad = 1
        id = 2000 + a
      end
      local z = X * kfx + Y * kfy + Z * kfz
      if z > -rad and z < maxZ then
        local x = X * krx + Y * kry + Z * krz
        if (x < 0 and -x or x) < z * tanH + rad or z < 4 then
          no = no + 1
          ordZ[no], ordI[no] = z, id
        end
      end
    end
    nOrd = no
    -- plain depth order (insertion sort)
    for o = 1, no do
      local z, j = ordZ[o], o - 1
      while j > 0 and ordZ[ordP[j]] < z do
        ordP[j + 1] = ordP[j]
        j = j - 1
      end
      ordP[j + 1] = o
    end
  end
end

local C = {}            -- colors (color radios) / grey levels (B&W)
local render3D, initGfx


-- =============================================================== B&W GFX
local line2
;(function()
  local GRAYS = type(GREY) == "function"
  local GRD, GRD2 = 0, 0
  local RCOS, RSIN = {}, {}                             -- ring segments (12 per turn)
  for j = 1, 12 do RCOS[j], RSIN[j] = cos(j * 0.5235988), sin(j * 0.5235988) end

  initGfx = function()
    -- grey levels: GREY(n) darkens by 15-n, FORCE makes it OR instead of XOR
    if GRAYS then GRD, GRD2 = GREY(12) + FORCE, GREY(7) + FORCE else GRD, GRD2 = FORCE, FORCE end
  end

  -- the B&W drawLine refuses off-screen points: clip in Lua (slab method)
  line2 = function(x1, y1, x2, y2, pat, fl)
    local XM, YM = XM, YM
    if x1 >= 0 and x1 <= XM and x2 >= 0 and x2 <= XM and y1 >= 0 and y1 <= YM and y2 >= 0 and y2 <= YM then
      drawLine(x1, y1, x2, y2, pat, fl)
      return
    end
    local dx, dy, t0, t1 = x2 - x1, y2 - y1, 0, 1
    if dx > -1e-6 and dx < 1e-6 then
      if x1 < 0 or x1 > XM then return end
    else
      local ta, tb = -x1 / dx, (XM - x1) / dx
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return end
    end
    if dy > -1e-6 and dy < 1e-6 then
      if y1 < 0 or y1 > YM then return end
    else
      local ta, tb = -y1 / dy, (YM - y1) / dy
      if ta > tb then ta, tb = tb, ta end
      if ta > t0 then t0 = ta end
      if tb < t1 then t1 = tb end
      if t0 > t1 then return end
    end
    drawLine(floor(x1 + dx * t0 + 0.5), floor(y1 + dy * t0 + 0.5), floor(x1 + dx * t1 + 0.5), floor(y1 + dy * t1 + 0.5), pat, fl)
  end

  local function line3(X1, Y1, Z1, X2, Y2, Z2, pat, fl)
    if Z1 < 0.2 then                                    -- (NEAR)
      if Z2 < 0.2 then return end
      local t = (0.2 - Z1) / (Z2 - Z1)
      X1, Y1, Z1 = X1 + (X2 - X1) * t, Y1 + (Y2 - Y1) * t, 0.2
    elseif Z2 < 0.2 then
      local t = (0.2 - Z2) / (Z1 - Z2)
      X2, Y2, Z2 = X2 + (X1 - X2) * t, Y2 + (Y1 - Y2) * t, 0.2
    end
    local F, CX, CY = F, CX, CY
    local s1, s2 = F / Z1, F / Z2
    return line2(CX + X1 * s1, CY - Y1 * s1, CX + X2 * s2, CY - Y2 * s2, pat, fl)
  end

  -- parallelogram a, a+u, a+u+v, a+v (camera space)
  local function quad3(ax, ay, az, ux_, uy_, uz_, vx_, vy_, vz_, pat)
    local bx, by, bz = ax + ux_, ay + uy_, az + uz_
    local cx, cy, cz = bx + vx_, by + vy_, bz + vz_
    local dx, dy, dz = ax + vx_, ay + vy_, az + vz_
    line3(ax, ay, az, bx, by, bz, pat, BLK)
    line3(bx, by, bz, cx, cy, cz, pat, BLK)
    line3(cx, cy, cz, dx, dy, dz, pat, BLK)
    line3(dx, dy, dz, ax, ay, az, pat, BLK)
  end

  local function drawGround()
    local a, b, c = kry, kuy, F * kfy
    local A, B = a < 0 and -a or a, b < 0 and -b or b
    if GRAYS then
      -- greyscale screens: fill the ground row by row (64 short calls)
      local CX, CY, XM = CX, CY, XM
      for y = 0, YM do
        local e = c - (y - CY) * b
        if A < 1e-5 then
          if e < 0 then drawLine(0, y, XM, y, SOLID, GRD) end
        else
          local xh = CX - e / a
          if a > 0 then
            if xh > 0 then drawLine(0, y, xh < XM and xh or XM, y, SOLID, GRD) end
          elseif xh < XM then
            drawLine(xh > 0 and xh or 0, y, XM, y, SOLID, GRD)
          end
        end
      end
    end
    if A <= B then
      if B < 1e-5 then return end
      line2(0, CY + (c - CX * a) / b, XM, CY + (c + (XM - CX) * a) / b, SOLID, GRD2)
    else
      line2(CX + (-CY * b - c) / a, 0, CX + ((YM - CY) * b - c) / a, YM, SOLID, GRD2)
    end
  end

  local function drawGrid()
    local krx, kux, kfx, krz, kuz, kfz = krx, kux, kfx, krz, kuz, kfz
    local bX = -kpx * krx - kpy * kry - kpz * krz
    local bY = -kpx * kux - kpy * kuy - kpz * kuz
    local bZ = -kpx * kfx - kpy * kfy - kpz * kfz
    local gs, gr = 10, 60
    local cxw, czw = floor(kpx / gs) * gs, floor(kpz / gs) * gs
    local pat, fl = DOTTED, BLK
    if GRAYS then pat, fl = SOLID, GRD2 end
    -- the ends of the lines across: the same for all of them
    local z1, z2, x1, x2 = czw - gr, czw + gr, cxw - gr, cxw + gr
    local a1, a2, a3, b1, b2, b3 = z1 * krz, z1 * kuz, z1 * kfz, z2 * krz, z2 * kuz, z2 * kfz
    local c1, c2, c3, d1, d2, d3 = x1 * krx, x1 * kux, x1 * kfx, x2 * krx, x2 * kux, x2 * kfx
    for i = -6, 6 do
      local x = cxw + i * gs
      local X0, Y0, Z0 = bX + x * krx, bY + x * kux, bZ + x * kfx
      line3(X0 + a1, Y0 + a2, Z0 + a3, X0 + b1, Y0 + b2, Z0 + b3, pat, fl)
      local z = czw + i * gs
      X0, Y0, Z0 = bX + z * krz, bY + z * kuz, bZ + z * kfz
      line3(X0 + c1, Y0 + c2, Z0 + c3, X0 + d1, Y0 + d2, Z0 + d3, pat, fl)
    end
    -- higher up, a coarser one (30 m) beyond it, out to 16 times the height (180 m at most): its
    -- edge stays near the horizon (a line across the fine one: only its two ends beyond it)
    local n = floor((kpy < 11.3 and kpy or 11.3) * 16 / 30)
    if n > 2 then
      local cx, cz = floor(kpx / 30) * 30, floor(kpz / 30) * 30
      local u, v = cz - n * 30, cz + n * 30
      local e1, e2, e3, f1, f2, f3 = u * krz, u * kuz, u * kfz, v * krz, v * kuz, v * kfz
      u, v = cx - n * 30, cx + n * 30
      local g1, g2, g3, h1, h2, h3 = u * krx, u * kux, u * kfx, v * krx, v * kux, v * kfx
      for i = -n, n do
        -- in two pieces: to the fine one's near edge, and from its far edge (from the near one
        -- again for a line beside it)
        local x = cx + i * 30
        local X0, Y0, Z0 = bX + x * krx, bY + x * kux, bZ + x * kfx
        local q1, q2, q3 = b1, b2, b3
        if x < x1 or x > x2 then q1, q2, q3 = a1, a2, a3 end
        line3(X0 + e1, Y0 + e2, Z0 + e3, X0 + a1, Y0 + a2, Z0 + a3, pat, fl)
        line3(X0 + q1, Y0 + q2, Z0 + q3, X0 + f1, Y0 + f2, Z0 + f3, pat, fl)
        local z = cz + i * 30
        X0, Y0, Z0 = bX + z * krz, bY + z * kuz, bZ + z * kfz
        q1, q2, q3 = d1, d2, d3
        if z < z1 or z > z2 then q1, q2, q3 = c1, c2, c3 end
        line3(X0 + g1, Y0 + g2, Z0 + g3, X0 + c1, Y0 + c2, Z0 + c3, pat, fl)
        line3(X0 + q1, Y0 + q2, Z0 + q3, X0 + h1, Y0 + h2, Z0 + h3, pat, fl)
      end
    end
  end

  local function drawGate(i, z)
    local krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz
    local nxt = i == nextGate and gmode ~= 3
    local pat = (nxt or z < 12) and SOLID or DOTTED
    local k = gk[i]
    local sh = GSH[k]
    local dx, dy, dz = gx[i] - kpx, gy[i] - kpy, gz[i] - kpz
    local cx, cy, cz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local r1, r3 = grx[i], grz[i]
    local Rx, Ry, Rz = r1 * krx + r3 * krz, r1 * kux + r3 * kuz, r1 * kfx + r3 * kfz
    local a1, a2, a3 = gax[i], gay[i], gaz[i]
    local Ax, Ay, Az = a1 * krx + a2 * kry + a3 * krz, a1 * kux + a2 * kuy + a3 * kuz, a1 * kfx + a2 * kfy + a3 * kfz
    local iw, ih = GHW[k], GHH[k]
    if sh == 3 then
      local sd = k == 6 and 1 or -1
      local o = -iw * sd
      local bX, bY, bZ = cx + Rx * o, cy + Ry * o, cz + Rz * o
      local ex, ey, ez = kry * FLAGH, kuy * FLAGH, kfy * FLAGH
      local tX, tY, tZ = bX + ex, bY + ey, bZ + ez
      line3(bX, bY, bZ, tX, tY, tZ, SOLID, BLK)
      local w = -0.9 * sd
      local mX, mY, mZ = bX + ex * 0.5, bY + ey * 0.5, bZ + ez * 0.5
      local qX, qY, qZ = tX + Rx * w - ex * 0.15, tY + Ry * w - ey * 0.15, tZ + Rz * w - ez * 0.15
      line3(tX, tY, tZ, qX, qY, qZ, SOLID, BLK)
      line3(qX, qY, qZ, mX, mY, mZ, SOLID, BLK)
      if nxt then
        line3(tX - ex * 0.15, tY - ey * 0.15, tZ - ez * 0.15, qX, qY, qZ, SOLID, BLK)
      end
      return
    elseif sh == 4 then
      if nxt then quad3(cx - Rx * iw - Ax * ih, cy - Ry * iw - Ay * ih, cz - Rz * iw - Az * ih, Rx * iw * 2, Ry * iw * 2, Rz * iw * 2,
                        Ax * ih * 2, Ay * ih * 2, Az * ih * 2, SOLID) end
      return
    elseif sh == 2 then
      local ns = k == 4 and 12 or 6
      if k == 4 then
        local h = gy[i] - iw - GT
        local X, Y, Z = cx - Ax * (iw + GT), cy - Ay * (iw + GT), cz - Az * (iw + GT)
        line3(X, Y, Z, X - kry * h, Y - kuy * h, Z - kfy * h, SOLID, BLK)
      end
      local r = iw + GT
      while r > 0 do
        local oX, oY, oZ = cx + Rx * r, cy + Ry * r, cz + Rz * r
        for j = 1, ns do
          local c_, s_ = RCOS[j], RSIN[j]
          local X, Y, Z = cx + (Rx * c_ + Ax * s_) * r, cy + (Ry * c_ + Ay * s_) * r, cz + (Rz * c_ + Az * s_) * r
          line3(oX, oY, oZ, X, Y, Z, pat, BLK)
          oX, oY, oZ = X, Y, Z
        end
        r = (r > iw and (z < 30 or nxt)) and iw or 0
      end
      return
    end
    local s = 1
    while s <= 2 do
      local w, h = iw, ih
      if s == 1 then w, h = iw + GT, ih + GT end
      local wx, wy, wz, hx, hy, hz = Rx * w, Ry * w, Rz * w, Ax * h, Ay * h, Az * h
      quad3(cx - wx - hx, cy - wy - hy, cz - wz - hz, wx * 2, wy * 2, wz * 2, hx * 2, hy * 2, hz * 2, pat)
      if z > 30 and not nxt then s = 3 else s = s + 1 end
    end
    if k > 1 then
      local lh = k == 2 and gy[i] - ih - GT or gy[i]
      local ex, ey, ez = kry * lh, kuy * lh, kfy * lh
      local lw = iw + GT * 0.5
      for sx = -1, 1, 2 do
        for sz = (k == 3 and -1 or 1), 1, 2 do
          local la = k == 3 and (ih + GT * 0.5) * sz or -(ih + GT)
          local X, Y, Z = cx + Rx * lw * sx + Ax * la, cy + Ry * lw * sx + Ay * la, cz + Rz * lw * sx + Az * la
          line3(X, Y, Z, X - ex, Y - ey, Z - ez, SOLID, BLK)
        end
      end
    end
  end

  local function drawTree(i, z)
    local krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz
    local h = qh[i]
    local dx, dy, dz = qx[i] - kpx, -kpy, qz[i] - kpz
    local bX, bY, bZ = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local tX, tY, tZ = bX + kry * h, bY + kuy * h, bZ + kfy * h
    line3(bX, bY, bZ, tX, tY, tZ, SOLID, BLK)
    if z < 90 then
      local w = h * 0.24
      local q = h * 0.25
      local mX, mY, mZ = bX + kry * q, bY + kuy * q, bZ + kfy * q
      local lX, lY, lZ, rX, rY, rZ = mX - krx * w, mY - kux * w, mZ - kfx * w, mX + krx * w, mY + kux * w, mZ + kfx * w
      line3(tX, tY, tZ, lX, lY, lZ, SOLID, BLK)
      line3(tX, tY, tZ, rX, rY, rZ, SOLID, BLK)
      line3(lX, lY, lZ, rX, rY, rZ, SOLID, BLK)
    end
  end

  -- structures: the edges of the faces turned to the camera
  local function drawBox(b, z)
    local krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz
    local x0, x1, y0, y1, z0, z1 = BX.x0[b], BX.x1[b], BX.y0[b], BX.y1[b], BX.z0[b], BX.z1[b]
    local dx, dy, dz = x0 - kpx, y0 - kpy, z0 - kpz
    local ox, oy, oz = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
    local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
    local Xx, Xy, Xz = krx * sx, kux * sx, kfx * sx
    local Yx, Yy, Yz = kry * sy, kuy * sy, kfy * sy
    local Zx, Zy, Zz = krz * sz, kuz * sz, kfz * sz
    local pat = z < 60 and SOLID or DOTTED
    if kpx < x0 then quad3(ox, oy, oz, Zx, Zy, Zz, Yx, Yy, Yz, pat)
    elseif kpx > x1 then quad3(ox + Xx, oy + Xy, oz + Xz, Zx, Zy, Zz, Yx, Yy, Yz, pat) end
    if kpz < z0 then quad3(ox, oy, oz, Xx, Xy, Xz, Yx, Yy, Yz, pat)
    elseif kpz > z1 then quad3(ox + Zx, oy + Zy, oz + Zz, Xx, Xy, Xz, Yx, Yy, Yz, pat) end
    if kpy > y1 then quad3(ox + Yx, oy + Yy, oz + Yz, Xx, Xy, Xz, Zx, Zy, Zz, pat)
    elseif kpy < y0 then quad3(ox, oy, oz, Xx, Xy, Xz, Zx, Zy, Zz, pat) end
  end

  local function drawAI(a, z)
    if z < 1 then return end
    local dx, dy, dz = AI.x[a] - kpx, AI.y[a] - kpy, AI.z[a] - kpz
    local s = F / z
    local sx, sy = floor(CX + (dx * krx + dy * kry + dz * krz) * s), floor(CY - (dx * kux + dy * kuy + dz * kuz) * s)
    if sx >= U and sx <= XM - 2 * U and sy >= 4 * U and sy <= YM - 2 * U then
      fillRect(sx - U, sy, 3 * U, 2 * U, BLK)
      drawLine(sx, sy - 3 * U, sx, sy - 2 * U, SOLID, BLK)
    end
  end

  -- the start pad (two squares), and a windsock behind it to the left (lines, as the Lite's): downwind,
  -- limp without wind. Points straight to camera space (y: the ground's, from the camera).
  local function drawPad()
    local kpx, kpz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz = kpx, kpz, krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz
    local hx, hz, y = TR.hx, TR.hz, 0 - kpy
    for s = 1, 2 do
      local e = s == 1 and 1.5 or 0.9
      local x, z = TR.px + (hx - hz) * e - kpx, TR.pz + (hz + hx) * e - kpz
      local pX, pY, pZ = x * krx + y * kry + z * krz, x * kux + y * kuy + z * kuz, x * kfx + y * kfy + z * kfz
      for j = 1, 4 do
        local a, b = (j == 1 or j == 4) and 1 or -1, j <= 2 and 1 or -1
        x, z = TR.px + (hx * a + hz * b) * e - kpx, TR.pz + (hz * a - hx * b) * e - kpz
        local X, Y, Z = x * krx + y * kry + z * krz, x * kux + y * kuy + z * kuz, x * kfx + y * kfy + z * kfz
        line3(pX, pY, pZ, X, Y, Z, SOLID, BLK)
        pX, pY, pZ = X, Y, Z
      end
    end
    local x, z = TR.px - hx * 7 - hz * 4, TR.pz - hz * 7 + hx * 4
    local e = S.wind > 0 and (S.wind == 1 and 3 or 7) * (1 + 0.3 * sin(gt * 0.009) + 0.2 * sin(gt * 0.031)) / 7.5 or 0
    if e > 1 then e = 1 end
    local a, b, c = x - kpx, 4 - kpy, z - kpz
    local bX, bY, bZ = a * krx + y * kry + c * krz, a * kux + y * kuy + c * kuz, a * kfx + y * kfy + c * kfz
    local tX, tY, tZ = a * krx + b * kry + c * krz, a * kux + b * kuy + c * kuz, a * kfx + b * kfy + c * kfz
    a, b, c = x + TR.wx * e * 1.4 - kpx, 3.9 - (1 - e) * 1.3 - kpy, z + TR.wz * e * 1.4 - kpz
    local eX, eY, eZ = a * krx + b * kry + c * krz, a * kux + b * kuy + c * kuz, a * kfx + b * kfy + c * kfz
    line3(bX, bY, bZ, tX, tY, tZ, SOLID, BLK)
    line3(tX, tY, tZ, eX, eY, eZ, SOLID, BLK)
    line3(tX - kry * 0.4, tY - kuy * 0.4, tZ - kfy * 0.4, eX, eY, eZ, SOLID, BLK)
  end

  -- mountains on the horizon: a ridge at infinity every 10 deg, the 17 around the way the camera
  -- faces (80 deg either side: the horizon in view reaches 65 deg to a side at Field of view 130,
  -- more toward a rolled view's corners; the azimuth from atan(t) ~ t * (0.7854 + 0.273 * (1 -
  -- t)), within 0.3 deg), dotted
  local function drawRidge()
    local krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz, F = krx, kry, krz, kux, kuy, kuz, kfx, kfy, kfz, F
    local ax_, az_ = kfx < 0 and -kfx or kfx, kfz < 0 and -kfz or kfz
    if ax_ + az_ < 0.05 then return end
    local a
    if ax_ < az_ then
      local t = ax_ / az_
      a = t * (0.7854 + 0.273 * (1 - t))
    else
      local t = az_ / ax_
      a = 1.5708 - t * (0.7854 + 0.273 * (1 - t))
    end
    if kfz < 0 then a = 3.1416 - a end
    if kfx < 0 then a = 6.2832 - a end
    local j0 = floor(a / 0.174533) - 8
    local px_, py_
    local pat, fl = GRAYS and SOLID or DOTTED, GRAYS and GRD2 or BLK
    for j = j0, j0 + 17 do
      local b = j * 0.174533
      local e = (1.6 + 2.2 * sin(b * 3 + 0.7) ^ 2 + 1.2 * sin(b * 7 + 1.9) ^ 2) * 0.0174533
      local c = cos(e)
      local x, y, z = sin(b) * c, sin(e), cos(b) * c
      local Z = x * kfx + y * kfy + z * kfz
      if Z > 0.3 then
        local X, Y = CX + (x * krx + y * kry + z * krz) * F / Z, CY - (x * kux + y * kuy + z * kuz) * F / Z
        if px_ then line2(px_, py_, X, Y, pat, fl) end
        px_, py_ = X, Y
      else
        px_ = nil
      end
    end
  end

  render3D = function()
    lcd.clear()
    drawGround()
    drawRidge()
    drawGrid()
    drawPad()
    collectObjects(90)
    for j = 1, nOrd do
      local o = ordP[j]
      local id, z = ordI[o], ordZ[o]
      if id < 0 then drawTree(-id, z)
      elseif id < 1000 then drawGate(id, z)
      elseif id < 2000 then drawBox(id - 1000, z)
      else drawAI(id - 2000, z) end
    end
  end
end)()

-- ---------------------------------------------------------- game flow
local function startRace(m)
  R.flush()
  gmode = m
  lap, nextGate, lastGate, lapStart = 0, 1, 0, nil
  R.n, R.total, R.newLap, R.newRace, R.newBest, R.crashes, R.msg, R.cd = 0, 0, false, false, false, 0, nil, -1
  R.pk, R.pos, R.sc, R.ch, R.chn, R.rn, R.rt, R.ax, R.bx, R.smp, R.why = 0, 1, 0, 0, 0, 0, 30, nil, nil, gt, nil
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  BAT.new()
  AI.start()
  tricks(-1)
  if m == 3 then state, R.ready = READY, gt else state, tState = COUNT, gt end
end

local function selectTrack(t)
  S.track = t
  buildTrack(t)
  MED.calc()
  AI.n = 0
  placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
end

local function update(dt)
  if state == COUNT then
    local n = floor((gt - tState) / 100)
    if n ~= R.cd then
      R.cd = n
      if n < 3 then beep(1000, 120) end
    end
    if n >= 3 then
      state, tStart = FLY, gt
      beep(2000, 400)
      showMsg("GO!", true)
    end
  elseif state == FLY or state == DONE then
    physics(dt)
    if gmode == 3 and state == FLY then
      tricks(dt)
      -- freestyle respawn point: where the quad was 1-2 s before a crash
      if gt - R.smp >= 100 then
        R.smp = gt
        R.ax, R.ay, R.az, R.ahx, R.ahz = R.bx, R.by, R.bz, R.bhx, R.bhz
        R.bx, R.by, R.bz, R.bhx, R.bhz = px, py, pz, fx, fz
      end
    end
  elseif state == CRASHED then
    if gt - tState > 120 then
      respawn()
      state, R.ready, R.why = READY, gt, nil
    end
  elseif state == READY then
    local e = gt - R.ready
    if e > 25 and (e > 200 or sA > 0.12 or sA < -0.12 or sE > 0.12 or sE < -0.12 or sR > 0.12 or sR < -0.12 or sT > 0.3) then
      state = FLY
    end
  end
  if gmode == 1 and AI.n > 0 and state ~= COUNT and dt > 0 then
    AI.update(dt)
    if state ~= DONE then R.pos = AI.place() end
  end
  if gmode == 4 and (state == FLY or state == CRASHED or state == READY) then
    R.rt = R.rt - dt
    if R.rt <= 0 then
      R.rt = 0
      local t = S.track
      if R.rn > BEST.g[t] then BEST.g[t], R.newBest = R.rn, true end
      R.dirty = true
      R.flush()
      state, tState, focus = DONE, gt, 1
      beep(900, 300)
    end
  end
end

-- menus
local MAIN_ITEMS = { "Race", "Practice", "Freestyle", "Gate Rush", "Track", "Settings", "Exit" }
local PAUSE_ITEMS = { "Resume", "Respawn", "Restart", "Settings", "Main menu" }

local optStep, optText
do
local function optIndex(o)
  local v = S[o[2]]
  for j = 1, #o[3] do
    if o[3][j] == v then return j end
  end
  return 1
end

local stepT, stepN, stepO = 0, 0, nil
optStep = function(o, d)
  local key = o[2]
  if RKEYS[key] and S.rates < 4 then
    -- editing a rate switches to custom rates, starting from the preset in use
    local r = RATES[S.rates]
    for k, j in pairs(RKEYS) do S[k] = r[j] end
    S.rates = 4
  end
  local vals = o[3]
  if vals then
    local j = optIndex(o)
    repeat                                     -- Power: only what suits the quad
      j = j + d
      if j < 1 then j = #vals elseif j > #vals then j = 1 end
    until key ~= "twr" or vals[j] == 0 or vals[j] >= P.tlo and vals[j] <= P.thi
    S[key] = vals[j]
  else
    -- fine steps, five times bigger after eight quick ones in a row (held key, fast wheel)
    local t = getTime()
    stepN = (o == stepO and t - stepT < 20) and stepN + 1 or 0
    stepT, stepO = t, o
    local v = S[key] + d * o[8] * (stepN >= 8 and 5 or 1)
    if v < o[6] then v = o[6] elseif v > o[7] then v = o[7] end
    S[key] = v
  end
  applySettings()
end

optText = function(o)
  if o[4] then return o[4][optIndex(o)] end
  local key = o[2]
  local v, j = S[key], RKEYS[key]
  if j and S.rates < 4 then v = RATES[S.rates][j] end
  if key == "re" or key == "ye" then return fmt("%.2f", v / 100) end
  return v .. (o[5] or "")
end
end

local function setLabel(i)
  if i > #OPTS then return "Back" end
  return OPTS[i][1]
end

local function setValue(i)
  if i > #OPTS then return nil end
  return optText(OPTS[i])
end


local render, hitTest, pauseHit, initUI


-- ================================================================ B&W UI
;(function()
  initUI = function() end

  local function place(p)
    return p .. (p == 1 and "st" or p == 2 and "nd" or p == 3 and "rd" or "th")
  end

  local function drawHUD()
    if gmode <= 2 then
      local l, lt = lapClock()
      drawNumber(U, U, floor(lt / 10), PREC1 + SMLSIZE + LEFT)
      local s = l .. ""
      if gmode == 1 then s = s .. "/" .. S.laps end
      if gmode == 1 and AI.n > 0 then s = "P" .. R.pos .. " L" .. s end
      drawText(XM, U, s, SMLSIZE + RIGHT)
      if gmode == 2 then drawText(CX, U, MED.goal(), SMLSIZE + CENTER) end
    elseif gmode == 3 then
      drawNumber(U, U, R.sc, SMLSIZE + LEFT)
      if R.chn > 0 then drawText(XM, U, "x" .. R.chn .. " " .. R.ch, SMLSIZE + RIGHT) end
    else
      drawNumber(U, U, floor(R.rt * 10), PREC1 + SMLSIZE + LEFT)
      drawText(XM, U, R.rn .. "", SMLSIZE + RIGHT)
    end
    if gmode ~= 3 then
      local i = nextGate
      local dx, dy, dz = AX[i] - kpx, AY[i] - kpy, AZ[i] - kpz
      local X, Y, Z = dx * krx + dy * kry + dz * krz, dx * kux + dy * kuy + dz * kuz, dx * kfx + dy * kfy + dz * kfz
      local onScreen = false
      if Z > 1 then
        local sx, sy = CX + X * F / Z, CY - Y * F / Z
        if sx > 3 and sx < XM - 3 and sy > 3 and sy < YM - 3 then onScreen = true end
      end
      if not onScreen then
        local ex, ey = X, -Y
        if Z < 0 and ex * ex + ey * ey < 1 then ex, ey = 0, 1 end
        local l = sqrt(ex * ex + ey * ey) + 0.0001
        ex, ey = ex / l, ey / l
        local k = (CX - 6 * U) / ((ex < 0 and -ex or ex) + 0.0001)
        local k2 = (CY - 6 * U) / ((ey < 0 and -ey or ey) + 0.0001)
        if k2 < k then k = k2 end
        local tx, ty = CX + ex * k, CY + ey * k
        local a, b, c, d = ex * 5 * U, ey * 5 * U, ey * 3 * U, ex * 3 * U
        line2(tx, ty, tx - a - c, ty - b + d, SOLID, BLK)
        line2(tx, ty, tx - a + c, ty - b - d, SOLID, BLK)
      end
    end
    local th = floor(sT * 30 * U)
    if th > 0 then fillRect(0, YM - th, 2 * U, th, BLK) end
    if S.batt > 0 and state < PAUSED then
      -- the battery right of the throttle bar (not under the pause and finish boxes): a fuel gauge
      -- and the cell voltage, inverted and blinking below 3.5 V a cell
      local y = YM - 4 * U
      fillRect(4 * U, y, 9 * U, 4 * U, ERASE)
      lcd.drawRectangle(4 * U, y, 9 * U, 4 * U, BLK)
      fillRect(5 * U, y + U, floor(7 * U * BAT.s + 0.5), 2 * U, BLK)
      drawNumber(15 * U, YM + 2 - 8 * U, floor(BAT.v * 100 + 0.5), PREC2 + SMLSIZE + ((BAT.w > 0 and gt % 50 < 30) and INVERS or 0))
    end
    drawLine(CX - 4 * U, CY, CX - 2 * U, CY, SOLID, BLK)
    drawLine(CX + 2 * U, CY, CX + 4 * U, CY, SOLID, BLK)
    if S.fps == 1 then drawNumber(XM, YM + 2 - 8 * U, R.fps, SMLSIZE + RIGHT) end
    -- wind: where it blows, as seen from the quad (up is the way its nose points)
    if S.wind > 0 then
      local r = 6 * U
      local cx, cy = XM - r, YM - r - (S.fps == 1 and 9 * U or 0)
      fillRect(cx - r, cy - r, r * 2 + 1, r * 2 + 1, ERASE)
      lcd.drawRectangle(cx - r, cy - r, r * 2 + 1, r * 2 + 1, BLK)
      local a = 4 * U / (sqrt(fx * fx + fz * fz) + 0.0001)
      local ex, ey = (TR.wx * fz - TR.wz * fx) * a, -(TR.wx * fx + TR.wz * fz) * a
      local tx, ty = cx + ex, cy + ey
      drawLine(cx - ex, cy - ey, tx, ty, SOLID, BLK)
      drawLine(tx, ty, tx - ex * 0.6 - ey * 0.5, ty - ey * 0.6 + ex * 0.5, SOLID, BLK)
      drawLine(tx, ty, tx - ex * 0.6 + ey * 0.5, ty - ey * 0.6 - ex * 0.5, SOLID, BLK)
    end
  end

  -- the pack's flight time and mAh used (Battery on), right-aligned at x on rows y1 and y2
  local function packInfo(x, y1, y2)
    if S.batt > 0 then
      drawText(x, y1, fmt("%d:%02d", floor(BAT.t / 60), floor(BAT.t) % 60), SMLSIZE + RIGHT)
      drawText(x, y2, floor((1 - BAT.s) * BAT.mah + 0.5) .. "mAh", SMLSIZE + RIGHT)
    end
  end

  local function drawList(title, n, label, value, y, rh)
    if title then
      drawText(U, 0, title, SMLSIZE + INVERS)
      y = 9 * U
    end
    local rows = floor((H - y) / rh)
    if rows > n then rows = n end
    if focus - scroll > rows then scroll = focus - rows end
    if focus <= scroll then scroll = focus - 1 end
    for r = 1, rows do
      local i = scroll + r
      local ry = y + (r - 1) * rh
      local v = value and value(i)
      drawText(2 * U, ry + U, label(i), SMLSIZE + ((i == focus and not (editing and v)) and INVERS or 0))
      if v then drawText(XM - U, ry + U, v, SMLSIZE + RIGHT + ((i == focus and editing) and INVERS or 0)) end
    end
  end

  local function mainLabel(i)
    local t = TRACKS[S.track][1]
    if i == 1 then return "Race " .. S.laps .. " laps" end
    if i == 5 then return (focus == 5 and editing) and ("< " .. t .. " >") or ("Track: " .. t) end
    return MAIN_ITEMS[i]
  end

  -- the track's bests next to the modes: race, lap, combo, gates
  local function mainValue(i)
    local t = S.track
    local b = i == 1 and BEST.r[t] or i == 2 and BEST.l[t] or i == 3 and BEST.f[t] or i == 4 and BEST.g[t]
    if b then return b < 1 and "--" or i < 3 and timeStr(b) or floor(b) .. "" end
  end

  render = function()
    if state == MENU or (state == SETUP and prevState == MENU) then
      lcd.clear()
      if state == MENU then
        drawText(U, 0, "StickTime", MIDSIZE)
        if W > 150 * U then drawText(XM, U, MED.goal(), SMLSIZE + RIGHT) end   -- where it fits
        drawList(nil, #MAIN_ITEMS, mainLabel, mainValue, 13 * U, 8 * U)
      else
        drawList("SETTINGS", #OPTS + 1, setLabel, setValue, 0, 9 * U)
      end
      return
    end
    fpvCamera()
    render3D()
    if state == SETUP then
      fillRect(0, 0, W, H, ERASE)
      drawList("SETTINGS", #OPTS + 1, setLabel, setValue, 0, 9 * U)
      return
    end
    drawHUD()
    if state == COUNT then
      drawText(CX, CY - 16 * U, tostring(3 - floor((gt - tState) / 100)), DBLSIZE + CENTER)
    elseif state == CRASHED then
      drawText(CX, CY - 8 * U, R.why or "CRASH", DBLSIZE + INVERS + CENTER)
    elseif state == READY then
      drawText(CX, CY - 14 * U, "READY", SMLSIZE + INVERS + CENTER)
    elseif state == PAUSED then
      fillRect(14 * U, 6 * U, W - 28 * U, H - 12 * U, ERASE)
      lcd.drawRectangle(14 * U, 6 * U, W - 28 * U, H - 12 * U, BLK)
      for i = 1, #PAUSE_ITEMS do
        drawText(22 * U, (8 + (i - 1) * 9) * U, PAUSE_ITEMS[i], i == focus and INVERS or 0)
      end
      packInfo(W - 17 * U, 32 * U, 43 * U)
    elseif state == DONE then
      fillRect(8 * U, 4 * U, W - 16 * U, H - 8 * U, ERASE)
      lcd.drawRectangle(8 * U, 4 * U, W - 16 * U, H - 8 * U, BLK)
      local x = 12 * U
      if gmode == 4 then
        drawText(x, 7 * U, R.newBest and "NEW RECORD!" or "TIME UP", SMLSIZE + INVERS)
        drawText(x, 17 * U, "Gates " .. R.rn, SMLSIZE)
        drawText(x, 26 * U, "Best " .. BEST.g[S.track], SMLSIZE)
      else
        local b = 0
        for i = 1, R.n do
          if b == 0 or R.laps[i] < b then b = R.laps[i] end
        end
        local m = MED.of(b)
        drawText(x, 7 * U, (R.newRace and "NEW RECORD!" or "FINISHED") .. (m > 0 and " " .. MED.n[m] or ""), SMLSIZE + INVERS)
        drawText(x, 17 * U, "Total " .. timeStr(R.total), SMLSIZE)
        drawText(x, 26 * U, "Best lap " .. timeStr(b), SMLSIZE)
        if AI.n > 0 then drawText(x, 35 * U, place(R.pos) .. " of " .. (AI.n + 1), SMLSIZE) end
      end
      drawText(x, H - 16 * U, "Again", SMLSIZE + (focus ~= 2 and INVERS or 0))
      drawText(x + 36 * U, H - 16 * U, "Menu", SMLSIZE + (focus == 2 and INVERS or 0))
      packInfo(W - 12 * U, 35 * U, H - 16 * U)
    end
    if R.msg and state == FLY then
      if gt - R.msgT < 200 then
        drawText(CX, 10 * U, R.msg, SMLSIZE + CENTER)
      else
        R.msg = nil
      end
    end
  end

  hitTest = function() return nil end
  pauseHit = function() return false end
end)()

-- ------------------------------------------------------------ input
local handleEvent
;(function()
  local function listNav(event, n)
    if event == EV.NEXT or event == EV.NEXTR then
      focus = focus % n + 1
    elseif event == EV.PREV or event == EV.PREVR then
      focus = (focus - 2) % n + 1
    end
  end

  local function toMenu()
    R.flush()
    state, focus, scroll, editing = MENU, 1, 0, false
    AI.n = 0
    placeDrone(TR.px, DR, TR.pz, TR.hx, TR.hz)
  end

  local function stepTrack(d)
    local t = S.track
    repeat                                          -- (custom slots without a file are skipped)
      t = t + d
      if t < 1 then t = NT elseif t > NT then t = 1 end
    until TRACKS[t]
    selectTrack(t)
    saveData()
  end

  local function mainSelect(i, frac)
    if i <= 4 then startRace(i)
    elseif i == 5 then stepTrack((frac and frac < 0.4) and -1 or 1)
    elseif i == 6 then prevState, state, focus, scroll, editing = MENU, SETUP, 1, 0, false
    elseif i == 7 then return 1
    end
    return 0
  end

  local function pauseSelect(i)
    if i == 1 then state = pausedFrom
    elseif i == 2 then
      -- back at the last gate (Freestyle: where it flew a second ago), the clock running on
      if pausedFrom == COUNT then state = COUNT else
        respawn()
        BAT.new()                                  -- with a fresh pack
        R.ch, R.chn = 0, 0                         -- (a Freestyle combo ends)
        tricks(-1)
        state, R.ready = READY, gt
      end
    elseif i == 3 then startRace(gmode)
    elseif i == 4 then prevState, state, focus, scroll, editing = PAUSED, SETUP, 1, 0, false
    elseif i == 5 then toMenu()
    end
  end

  handleEvent = function(event, touch)
    local tapI, tapF
    if EV.TAP and event == EV.TAP and touch then tapI, tapF = hitTest(touch.x, touch.y) end
    if state == MENU then
      if tapI then
        focus = tapI
        return mainSelect(tapI, tapF)
      end
      if editing then
        -- INC / DEC only: on radios with +/- keys NEXT is the minus key
        if event == EV.INC or event == EV.INCR then stepTrack(1)
        elseif event == EV.DEC or event == EV.DECR then stepTrack(-1)
        elseif event == EV.ENTER or event == EV.EXIT then editing = false end
        return 0
      end
      listNav(event, #MAIN_ITEMS)
      if event == EV.ENTER then
        if focus == 5 then
          editing = true
          return 0
        end
        return mainSelect(focus, nil)
      elseif event == EV.EXIT then
        return 1
      end
    elseif state == SETUP then
      local n = #OPTS + 1
      if tapI then
        focus = tapI
        if tapI == n then event = EV.EXIT else optStep(OPTS[tapI], tapF < 0.4 and -1 or 1) end
      elseif editing then
        if event == EV.INC or event == EV.INCR then optStep(OPTS[focus], 1)
        elseif event == EV.DEC or event == EV.DECR then optStep(OPTS[focus], -1)
        elseif event == EV.ENTER or event == EV.EXIT then editing = false end
        return 0
      else
        listNav(event, n)
        if event == EV.ENTER then
          if focus == n then event = EV.EXIT else editing = true end
        end
      end
      if event == EV.EXIT then
        saveData()
        editing = false
        if prevState == PAUSED then
          state, focus, scroll = PAUSED, 4, 0
        else
          state, focus, scroll = MENU, 6, 0
        end
      end
    elseif state == PAUSED then
      if tapI then
        pauseSelect(tapI)
        return 0
      end
      listNav(event, #PAUSE_ITEMS)
      if event == EV.ENTER then pauseSelect(focus)
      elseif event == EV.EXIT then state = pausedFrom end
    elseif state == DONE then
      -- Again or Menu: the wheel or the page keys pick one, ENTER (or a tap) takes it, EXIT is Menu
      listNav(event, 2)
      if event == EV.PGN or event == EV.PGP then focus = 3 - focus end
      if tapI then focus = tapI end
      if tapI or event == EV.ENTER then
        if focus == 2 then toMenu() else startRace(gmode) end
      elseif event == EV.EXIT then toMenu() end
    else
      -- flying: EXIT or the on-screen pause button pauses
      if event == EV.EXIT or (EV.TAP and event == EV.TAP and touch and pauseHit(touch.x, touch.y)) then
        pausedFrom, prevState, state, focus, scroll = state, state, PAUSED, 1, 0
        R.flush()
      end
    end
    return 0
  end
end)()

-- ------------------------------------------------------------ entry
local function init()
  readSticks(true)
  loadData()
  initGfx()
  initUI()
  applySettings()
  selectTrack(S.track)
  lastT = getTime()
  R.fpsT = lastT
end

local function run(event, touch)
  local now = getTime()
  local dtk = now - lastT
  lastT = now
  if dtk > 10 then dtk = 10 elseif dtk < 0 then dtk = 0 end
  -- frame interval in 10 ms ticks, smoothed: getTime() only ticks every 10 ms, so when the
  -- firmware runs the script faster than 20 fps the raw steps jitter (0, 1, 2, 3 ticks...)
  R.fi = R.fi + (dtk - R.fi) * 0.2
  local paused = state == PAUSED or state == SETUP
  if paused then dtk = 0 end
  gt = gt + dtk
  -- simulation time advances by the smoothed interval, kept within a tick of the clock
  local pt = R.pt + (paused and 0 or R.fi)
  if pt > gt + 1 then pt = gt + 1 elseif pt < gt - 1 then pt = gt - 1 end
  local dts = (pt - R.pt) * 0.01
  if dts < 0 then dts = 0 end
  R.pt = pt
  readSticks()
  if handleEvent(event or 0, touch) ~= 0 then return 1 end
  update(dts)
  render()
  R.fpsN = R.fpsN + 1
  if now - R.fpsT >= 100 then
    R.fps, R.fpsN, R.fpsT = R.fpsN, 0, now
  end
  return 0
end

return { init = init, run = run }
