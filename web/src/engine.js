/* EdgeTX Lua emulator core.
 * Runs real EdgeTX tool scripts (init/run) on fengari (Lua 5.3) against a virtual
 * radio: LCD drawing follows the firmware (color: RGB565, Liang-Barsky + Bresenham
 * lines, per-scanline triangle fill, opacity; B&W: 1-bit / 4-bit grey with
 * FORCE / ERASE / XOR and the Lua API's off-screen line rejection), getTime() in
 * 10 ms ticks, sticks through getValue(), io on a virtual SD card. It also counts
 * Lua VM instructions and drawing work per frame to estimate radio CPU load. */
'use strict';

const EdgeTX = (() => {
  const RADIOS = [
    { id: 'pc', label: '1280×720  PC screen · 60 fps, no radio limits', w: 1280, h: 720, color: true, fonts: 'pc', cpu: 'H7', pc: true },
    { id: 'tx16s', label: '480×272  TX16S · T16 · T18 · X10 · X12S · V16', w: 480, h: 272, color: true, fonts: 'std', cpu: 'F4' },
    { id: 'tx15', label: '480×320  TX15 · T15 · PL18 · ST16 · GX15 · T22', w: 480, h: 320, color: true, fonts: 'std', cpu: 'H7' },
    { id: 'nv14', label: '320×480  NV14 · EL18 · NB4+ (portrait)', w: 320, h: 480, color: true, fonts: 'std', cpu: 'F4' },
    { id: 'pa01', label: '320×240  PA01 · V12', w: 320, h: 240, color: true, fonts: 'sml', cpu: 'H7' },
    { id: 'mk3', label: '800×480  TX16S MK3', w: 800, h: 480, color: true, fonts: 'lrg', cpu: 'H7' },
    { id: 'x9d', label: '212×64 grey  X9D · X9D+ · X9E', w: 212, h: 64, color: false, depth: 4, cpu: 'BW' },
    { id: 'tx12', label: '128×64  TX12 · Zorro · Boxer · Pocket · X7 · T-Lite…', w: 128, h: 64, color: false, depth: 1, cpu: 'BW' },
  ];

  // Rough per-operation costs (microseconds) used for the radio CPU estimate.
  // Derived from how the firmware implements each call; real radios vary.
  const CPU = {
    F4: { name: 'STM32F429 (TX16S class)', instr: 0.32, call: 3.0, linePx: 0.03, scan: 5.0, scanPx: 0.006, rect: 9, rectPx: 0.006, blendPx: 0.03, text: 35, glyph: 6, frame: 4000 },
    H7: { name: 'STM32H750 (TX15 / MK3 class)', instr: 0.11, call: 7.0, linePx: 0.012, scan: 2.0, scanPx: 0.003, rect: 4, rectPx: 0.002, blendPx: 0.012, text: 14, glyph: 2.5, frame: 2500 },
    BW: { name: 'STM32F4 B&W (TX12 class)', instr: 0.32, call: 2.5, linePx: 0.06, scan: 0, scanPx: 0, rect: 3, rectPx: 0.06, blendPx: 0, text: 12, glyph: 2, frame: 1200 },
    // 120 MHz Cortex-M3 without FPU: slower clock, and Lua's floats run in software
    F2: { name: 'STM32F2 B&W (X7 / X9D+ class)', instr: 0.55, call: 3.5, linePx: 0.08, scan: 0, scanPx: 0, rect: 4, rectPx: 0.08, blendPx: 0, text: 16, glyph: 3, frame: 1500 },
  };

  // ---------------------------------------------------------------- flags
  const COLOR_FLAGS = {
    INVERS: 0x01, VCENTER: 0x02, CENTER: 0x04, RIGHT: 0x08, LEFT: 0x00, SHADOWED: 0x80, BLINK: 0x1000,
    TIMEHOUR: 0x2000, LEADING0: 0x10, PREC1: 0x20, PREC2: 0x30, SOLID: 0xff, DOTTED: 0x55,
    BOLD: 0x100, TINSIZE: 0x200, SMLSIZE: 0x300, MIDSIZE: 0x400, DBLSIZE: 0x500, XXLSIZE: 0x600,
  };
  const BW_FLAGS = {
    BLINK: 0x01, INVERS: 0x02, BOLD: 0x40, LEFT: 0x00, RIGHT: 0x04, CENTER: 0x20, FIXEDWIDTH: 0x10,
    LEADING0: 0x10, PREC1: 0x20, PREC2: 0x30, FORCE: 0x02, ERASE: 0x04, ROUND: 0x08, FILL_WHITE: 0x10,
    TINSIZE: 0x100, SMLSIZE: 0x200, MIDSIZE: 0x300, DBLSIZE: 0x400, XXLSIZE: 0x500, TIMEHOUR: 0x2000,
    SOLID: 0xff, DOTTED: 0x55,
  };
  // theme / named colors (index << 16, no RGB flag) -> RGB
  const NAMED = [
    ['COLOR_THEME_PRIMARY1', 0, 0, 0], ['COLOR_THEME_PRIMARY2', 255, 255, 255], ['COLOR_THEME_PRIMARY3', 12, 63, 102],
    ['COLOR_THEME_SECONDARY1', 18, 94, 153], ['COLOR_THEME_SECONDARY2', 182, 224, 255], ['COLOR_THEME_SECONDARY3', 228, 238, 242],
    ['COLOR_THEME_FOCUS', 20, 161, 229], ['COLOR_THEME_EDIT', 0, 153, 9], ['COLOR_THEME_ACTIVE', 255, 222, 0],
    ['COLOR_THEME_WARNING', 224, 0, 0], ['COLOR_THEME_DISABLED', 140, 140, 140],
    ['BLACK', 0, 0, 0], ['WHITE', 255, 255, 255], ['LIGHTWHITE', 238, 238, 238], ['LIGHTGREY', 192, 192, 192],
    ['GREY', 150, 150, 150], ['DARKGREY', 64, 64, 64], ['RED', 229, 32, 30], ['DARKRED', 160, 0, 6],
    ['LIGHTRED', 255, 128, 128], ['GREEN', 25, 150, 50], ['DARKGREEN', 0, 120, 0], ['BRIGHTGREEN', 0, 180, 60],
    ['BLUE', 0x30, 0xA0, 0xE0], ['DARKBLUE', 0, 0, 140], ['CYAN', 0, 210, 255], ['YELLOW', 0xF0, 0xD0, 0x10],
    ['LIGHTBROWN', 156, 109, 32], ['DARKBROWN', 106, 72, 16], ['ORANGE', 229, 100, 30], ['MAGENTA', 255, 0, 255],
  ];
  const rgb565 = (r, g, b) => ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
  const NAMED565 = NAMED.map(c => rgb565(c[1], c[2], c[3]));

  // events (values are internal; scripts use the constants)
  const K = { EXIT: 1, ENTER: 2, PAGEUP: 3, PAGEDN: 4, MODEL: 6, SYS: 7, TELE: 8 };
  const BREAK = k => 0x200 | k, LONG = k => 0x800 | k, FIRST = k => 0x600 | k, REPT = k => 0x400 | k;
  const ROT_L = 0x1D00, ROT_R = 0x1E00;
  const TOUCH = { FIRST: 0x1001, BREAK: 0x1002, SLIDE: 0x1003, TAP: 0x1004 };
  const EVENTS = {
    EVT_VIRTUAL_PREV: ROT_L, EVT_VIRTUAL_NEXT: ROT_R, EVT_VIRTUAL_DEC: ROT_L, EVT_VIRTUAL_INC: ROT_R,
    EVT_VIRTUAL_PREV_PAGE: BREAK(K.PAGEUP), EVT_VIRTUAL_NEXT_PAGE: BREAK(K.PAGEDN),
    EVT_VIRTUAL_MENU: BREAK(K.MODEL), EVT_VIRTUAL_MENU_LONG: LONG(K.MODEL),
    EVT_VIRTUAL_ENTER: BREAK(K.ENTER), EVT_VIRTUAL_ENTER_LONG: LONG(K.ENTER), EVT_VIRTUAL_EXIT: BREAK(K.EXIT),
    EVT_EXIT_BREAK: BREAK(K.EXIT), EVT_ENTER_FIRST: FIRST(K.ENTER), EVT_ENTER_BREAK: BREAK(K.ENTER),
    EVT_ENTER_LONG: LONG(K.ENTER), EVT_ENTER_REPT: REPT(K.ENTER),
    EVT_PAGEUP_FIRST: FIRST(K.PAGEUP), EVT_PAGEUP_BREAK: BREAK(K.PAGEUP), EVT_PAGEUP_LONG: LONG(K.PAGEUP),
    EVT_PAGEDN_FIRST: FIRST(K.PAGEDN), EVT_PAGEDN_BREAK: BREAK(K.PAGEDN), EVT_PAGEDN_LONG: LONG(K.PAGEDN),
    EVT_MODEL_FIRST: FIRST(K.MODEL), EVT_MODEL_BREAK: BREAK(K.MODEL), EVT_MODEL_LONG: LONG(K.MODEL),
    EVT_SYS_FIRST: FIRST(K.SYS), EVT_SYS_BREAK: BREAK(K.SYS), EVT_SYS_LONG: LONG(K.SYS),
    EVT_TELEM_FIRST: FIRST(K.TELE), EVT_TELEM_BREAK: BREAK(K.TELE), EVT_TELEM_LONG: LONG(K.TELE),
    EVT_ROT_LEFT: ROT_L, EVT_ROT_RIGHT: ROT_R,
  };
  const KEY_EVENT = {
    enter: BREAK(K.ENTER), enterLong: LONG(K.ENTER), exit: BREAK(K.EXIT), exitLong: LONG(K.EXIT),
    prev: ROT_L, next: ROT_R, menu: BREAK(K.MODEL), pageUp: BREAK(K.PAGEUP), pageDn: BREAK(K.PAGEDN),
  };

  // color font sizes (px) per screen class: STD, BOLD, XXS, XS, L, XL, XXL, LXL
  const FONT_PX = {
    std: [16, 16, 9, 13, 24, 32, 64, 48], sml: [13, 13, 8, 10, 19, 25, 48, 36], lrg: [22, 22, 12, 18, 33, 44, 88, 66],
    pc: [32, 32, 18, 26, 48, 64, 128, 96],
  };
  const FONT_BOLD = [false, true, false, false, false, true, true, true];

  // ---------------------------------------------------------- color fonts
  // Glyph masks rasterised once per size with canvas (Roboto, like EdgeTX)
  class ColorFonts {
    constructor(family) {
      this.family = family || 'RobotoEmu, Roboto, Arial, sans-serif';
      this.cache = new Map();
      this.canvas = typeof document !== 'undefined' ? document.createElement('canvas') : null;
    }
    face(px, bold) {
      const key = px + (bold ? 'b' : '');
      let f = this.cache.get(key);
      if (!f) {
        f = { px, bold, glyphs: new Map(), asc: Math.round(px * 0.93), lh: Math.round(px * 1.17) };
        this.cache.set(key, f);
      }
      return f;
    }
    glyph(f, ch) {
      let g = f.glyphs.get(ch);
      if (g) return g;
      const c = this.canvas;
      const pad = Math.ceil(f.px * 0.4);
      const cw = Math.ceil(f.px * 1.6) + pad * 2, chh = Math.ceil(f.px * 1.5) + pad * 2;
      c.width = cw; c.height = chh;
      const ctx = c.getContext('2d', { willReadFrequently: true });
      ctx.clearRect(0, 0, cw, chh);
      ctx.font = (f.bold ? '700 ' : '400 ') + f.px + 'px ' + this.family;
      ctx.fillStyle = '#fff';
      ctx.textBaseline = 'alphabetic';
      ctx.fillText(ch, pad, pad + f.asc);
      const adv = ctx.measureText(ch).width;
      const data = ctx.getImageData(0, 0, cw, chh).data;
      let x0 = cw, y0 = chh, x1 = -1, y1 = -1;
      for (let y = 0; y < chh; y++) for (let x = 0; x < cw; x++) {
        if (data[(y * cw + x) * 4 + 3] > 8) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
      }
      if (x1 < 0) { g = { adv, w: 0, h: 0, ox: 0, oy: 0, a: null }; }
      else {
        const w = x1 - x0 + 1, h = y1 - y0 + 1, a = new Uint8Array(w * h);
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) a[y * w + x] = data[((y + y0) * cw + x + x0) * 4 + 3];
        g = { adv, w, h, ox: x0 - pad, oy: y0 - pad, a };
      }
      f.glyphs.set(ch, g);
      return g;
    }
    measure(text, px, bold) {
      const f = this.face(px, bold);
      let w = 0;
      for (const ch of text) w += this.glyph(f, ch).adv;
      return { w: Math.round(w), h: f.lh };
    }
  }

  // --------------------------------------------------------------- engine
  class Engine {
    constructor(fengari, radio, opts = {}) {
      this.fe = fengari;
      this.radio = radio;
      this.W = radio.w; this.H = radio.h;
      this.color = radio.color;
      this.depth = radio.depth || 16;
      this.colorFonts = opts.colorFonts || new ColorFonts();
      this.bwFonts = opts.bwFonts || null;
      this.sd = opts.sd || new Map();
      this.files = opts.files || {};      // read-only files on the virtual SD card (bundled scripts)
      this.displayDelay = true;           // color radios show a frame one cycle after it is drawn
      this.onTone = opts.onTone || null;
      this.onHaptic = opts.onHaptic || null;
      this.onSave = opts.onSave || null;
      this.touchEnabled = this.color;
      this.fb = this.color ? new Uint16Array(this.W * this.H) : new Uint8Array(this.W * this.H);
      this.sticks = { ail: 0, ele: 0, thr: -1024, rud: 0 };
      this.stickMode = 1; // 0..3 = mode 1..4
      this.queue = [];
      this.clock = 0;          // ms
      this.error = null;
      this.exited = false;
      this.L = null;
      this.frames = 0;
      this.stats = this.newStats();
      this.last = this.newStats();
      this.hookStep = 50;
    }

    newStats() {
      return { instr: 0, calls: 0, lines: 0, linePx: 0, tris: 0, scan: 0, scanPx: 0, rects: 0, rectPx: 0, blendPx: 0, texts: 0, glyphs: 0, rejected: 0 };
    }

    // ---------------------------------------------------------- Lua setup
    load(source, chunkName, globals) {
      const { lua, lauxlib, lualib, to_luastring } = this.fe;
      const L = lauxlib.luaL_newstate();
      this.L = L;
      lualib.luaL_openlibs(L);
      this.error = null; this.exited = false; this.frames = 0;
      this.initRef = this.runRef = null;
      this.installApi(globals || {});
      lua.lua_sethook(L, () => { this.stats.instr += this.hookStep; }, lua.LUA_MASKCOUNT, this.hookStep);
      const st = lauxlib.luaL_loadbuffer(L, to_luastring(source), null, to_luastring('@' + (chunkName || 'script.lua')));
      if (st !== lua.LUA_OK) return this.fail('Syntax error', this.popString());
      if (this.pcall(0, 1) !== lua.LUA_OK) return this.fail('Script error', this.popString());
      if (!lua.lua_istable(L, -1)) return this.fail('Script error', 'script must return a table with init/run');
      lua.lua_getfield(L, -1, to_luastring('init'));
      this.initRef = lua.lua_isfunction(L, -1) ? lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX) : (lua.lua_pop(L, 1), null);
      lua.lua_getfield(L, -1, to_luastring('run'));
      this.runRef = lua.lua_isfunction(L, -1) ? lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX) : (lua.lua_pop(L, 1), null);
      lua.lua_pop(L, 1);
      if (this.initRef !== null) {
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, this.initRef);
        if (this.pcall(0, 0) !== lua.LUA_OK) return this.fail('init() error', this.popString());
      }
      return true;
    }

    pcall(nargs, nres) {
      const { lua, lauxlib } = this.fe;
      const L = this.L;
      const base = lua.lua_gettop(L) - nargs;
      lua.lua_pushcfunction(L, (L2) => {
        const msg = lua.lua_tostring(L2, 1);
        lauxlib.luaL_traceback(L2, L2, msg, 1);
        return 1;
      });
      lua.lua_insert(L, base);
      const st = lua.lua_pcall(L, nargs, nres, base);
      lua.lua_remove(L, base);
      return st;
    }

    popString() {
      const { lua, to_jsstring } = this.fe;
      const s = lua.lua_tostring(this.L, -1);
      lua.lua_pop(this.L, 1);
      return s ? to_jsstring(s) : '(no message)';
    }

    fail(title, msg) {
      this.error = { title, msg };
      return false;
    }

    // run one radio cycle: advance the clock, call run(event, touch)
    frame(dtMs) {
      if (!this.L || this.error || this.exited || this.runRef === null) return;
      const { lua, to_luastring } = this.fe;
      const L = this.L;
      this.clock += dtMs;
      // the color UI (LVGL) flushes the canvas at the start of the next cycle:
      // what is on screen during this cycle is what the script drew in the last one
      if (this.color) {
        if (!this.shown) this.shown = new Uint16Array(this.fb.length);
        this.shown.set(this.fb);
      }
      this.stats = this.newStats();
      const ev = this.queue.length ? this.queue.shift() : null;
      lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, this.runRef);
      lua.lua_pushinteger(L, ev ? ev.code : 0);
      let n = 1;
      if (ev && ev.touch) {
        lua.lua_newtable(L);
        for (const k in ev.touch) {
          const v = ev.touch[k];
          if (typeof v === 'boolean') lua.lua_pushboolean(L, v); else lua.lua_pushinteger(L, Math.round(v));
          lua.lua_setfield(L, -2, to_luastring(k));
        }
        n = 2;
      }
      const st = this.pcall(n, 1);
      if (st !== lua.LUA_OK) { this.fail('Script error', this.popString()); return; }
      const r = lua.lua_isnumber(L, -1) ? lua.lua_tonumber(L, -1) : 0;
      lua.lua_pop(L, 1);
      this.frames++;
      this.last = this.stats;
      if (r !== 0) this.exited = true;
    }

    // set (number) or clear (null) a global inside the running script
    setGlobal(name, value) {
      const { lua, to_luastring } = this.fe;
      if (!this.L) return;
      if (typeof value === 'number') lua.lua_pushnumber(this.L, value); else lua.lua_pushnil(this.L);
      lua.lua_setglobal(this.L, to_luastring(name));
    }

    // call FPVSIM_TEST.<name>(...) inside the script (automation / tests)
    callTest(name, ...args) {
      const { lua, to_luastring } = this.fe;
      const L = this.L;
      if (!L) return null;
      const top0 = lua.lua_gettop(L);
      lua.lua_getglobal(L, to_luastring('FPVSIM_TEST'));
      if (!lua.lua_istable(L, -1)) { lua.lua_settop(L, top0); return null; }
      lua.lua_getfield(L, -1, to_luastring(name));
      lua.lua_remove(L, -2);
      if (!lua.lua_isfunction(L, -1)) { lua.lua_settop(L, top0); return null; }
      for (const a of args) {
        if (typeof a === 'string') lua.lua_pushstring(L, to_luastring(a));
        else if (typeof a === 'boolean') lua.lua_pushboolean(L, a);
        else if (Number.isInteger(a)) lua.lua_pushinteger(L, a);
        else lua.lua_pushnumber(L, a);
      }
      if (lua.lua_pcall(L, args.length, lua.LUA_MULTRET, 0) !== lua.LUA_OK) throw new Error(this.popString());
      const res = [];
      for (let i = top0 + 1; i <= lua.lua_gettop(L); i++) {
        res.push(lua.lua_isnumber(L, i) ? lua.lua_tonumber(L, i) : lua.lua_isboolean(L, i) ? lua.lua_toboolean(L, i) : null);
      }
      lua.lua_settop(L, top0);
      return res;
    }

    key(name) {
      const code = KEY_EVENT[name];
      if (code !== undefined) this.queue.push({ code });
    }

    touch(type, t) {
      if (!this.touchEnabled) return;
      this.queue.push({ code: TOUCH[type], touch: t });
    }

    estimate(cpuId) {
      const c = CPU[cpuId || this.radio.cpu] || CPU.F4;
      const s = this.last;
      const us = c.frame + s.instr * c.instr + s.calls * c.call + s.linePx * c.linePx + s.scan * c.scan + s.scanPx * c.scanPx +
        s.rects * c.rect + s.rectPx * c.rectPx + s.blendPx * c.blendPx + s.texts * c.text + s.glyphs * c.glyph;
      return { ms: us / 1000, cpu: c };
    }

    // ------------------------------------------------------------ the API
    installApi(globals) {
      const { lua, lauxlib, to_luastring, to_jsstring } = this.fe;
      const L = this.L;
      const self = this;
      const W = this.W, H = this.H;
      const num = (i) => lauxlib.luaL_checknumber(L, i);
      const int = (i) => Math.floor(lauxlib.luaL_checknumber(L, i));
      const opt = (i, d) => (lua.lua_isnoneornil(L, i) ? d : Math.floor(lauxlib.luaL_checknumber(L, i)));
      const u32 = (v) => v >>> 0;
      const str = (i) => to_jsstring(lauxlib.luaL_checkstring(L, i));
      const fn = (f) => (L2) => { self.stats.calls++; return f(L2) || 0; };
      const setfn = (name, f) => { lua.lua_pushcfunction(L, fn(f)); lua.lua_setfield(L, -2, to_luastring(name)); };
      const setnum = (name, v) => { lua.lua_pushinteger(L, v | 0); lua.lua_setfield(L, -2, to_luastring(name)); };
      const global = (name, f) => { lua.lua_pushcfunction(L, fn(f)); lua.lua_setglobal(L, to_luastring(name)); };
      const gnum = (name, v) => { lua.lua_pushinteger(L, v | 0); lua.lua_setglobal(L, to_luastring(name)); };
      const pushStr = (s) => lua.lua_pushstring(L, to_luastring(s));

      // constants
      gnum('LCD_W', W); gnum('LCD_H', H);
      const flags = this.color ? COLOR_FLAGS : BW_FLAGS;
      for (const k in flags) gnum(k, flags[k]);
      if (this.color) NAMED.forEach((c, i) => gnum(c[0], i << 16));
      for (const k in EVENTS) gnum(k, EVENTS[k]);
      if (this.touchEnabled) { gnum('EVT_TOUCH_FIRST', TOUCH.FIRST); gnum('EVT_TOUCH_BREAK', TOUCH.BREAK); gnum('EVT_TOUCH_SLIDE', TOUCH.SLIDE); gnum('EVT_TOUCH_TAP', TOUCH.TAP); }
      gnum('PLAY_NOW', 0x01); gnum('PLAY_BACKGROUND', 0x02);
      if (!this.color && this.depth > 1) {
        global('GREY', () => { lua.lua_pushinteger(L, (int(1) & 0xF) * 0x10000); return 1; });
        gnum('GREY_DEFAULT', 11 * 0x10000);
      }

      // general functions
      global('getTime', () => { lua.lua_pushinteger(L, Math.floor(self.clock / 10)); return 1; });
      const SRC = { ail: 1, ele: 2, thr: 3, rud: 4 };
      global('getValue', () => {
        let id = 0;
        if (lua.lua_type(L, 1) === lua.LUA_TNUMBER) id = int(1); else id = SRC[str(1).toLowerCase()] || 0;
        const s = self.sticks;
        const v = id === 1 ? s.ail : id === 2 ? s.ele : id === 3 ? s.thr : id === 4 ? s.rud : 0;
        lua.lua_pushinteger(L, Math.max(-1024, Math.min(1024, Math.round(v))));
        return 1;
      });
      global('getFieldInfo', () => {
        const name = str(1).toLowerCase();
        if (!SRC[name]) { lua.lua_pushnil(L); return 1; }
        lua.lua_newtable(L);
        lua.lua_pushinteger(L, SRC[name]); lua.lua_setfield(L, -2, to_luastring('id'));
        pushStr(name); lua.lua_setfield(L, -2, to_luastring('name'));
        pushStr(name); lua.lua_setfield(L, -2, to_luastring('desc'));
        return 1;
      });
      global('getStickMode', () => { lua.lua_pushinteger(L, self.stickMode); return 1; });
      global('playTone', () => { if (self.onTone) self.onTone(int(1), int(2), opt(3, 0), opt(4, 0)); });
      global('playHaptic', () => { if (self.onHaptic) self.onHaptic(int(1)); });
      global('playFile', () => 0); global('playNumber', () => 0); global('killEvents', () => 0);
      global('getUsage', () => { lua.lua_pushinteger(L, 0); return 1; });
      global('getAvailableMemory', () => { lua.lua_pushinteger(L, 4 * 1024 * 1024); return 1; });
      global('getRSSI', () => { lua.lua_pushinteger(L, 0); return 1; });
      global('getVersion', () => { pushStr('2.12.0-emu'); pushStr('emulator'); lua.lua_pushinteger(L, 2); lua.lua_pushinteger(L, 12); lua.lua_pushinteger(L, 0); pushStr('EdgeTX'); return 6; });
      global('print', () => {
        const n = lua.lua_gettop(L); const parts = [];
        for (let i = 1; i <= n; i++) parts.push(to_jsstring(lauxlib.luaL_tolstring(L, i)));
        console.log('[lua]', parts.join('\t'));
      });
      lua.lua_newtable(L);
      setfn('getInfo', () => { lua.lua_newtable(L); pushStr('SIM'); lua.lua_setfield(L, -2, to_luastring('name')); return 1; });
      lua.lua_setglobal(L, to_luastring('model'));

      // io on the virtual SD card (EdgeTX signatures: io.read(f, n), io.write(f, ...))
      const files = new Map();
      let fid = 1;
      lua.lua_newtable(L);
      setfn('open', () => {
        const path = str(1), mode = lua.lua_isnoneornil(L, 2) ? 'r' : str(2);
        if (mode[0] === 'r' && !self.sd.has(path)) { lua.lua_pushnil(L); return 1; }
        const f = { path, mode, pos: 0, data: mode[0] === 'w' ? '' : (self.sd.get(path) || '') };
        if (mode[0] === 'a') f.pos = f.data.length;
        const id = fid++;
        files.set(id, f);
        lua.lua_newtable(L); lua.lua_pushinteger(L, id); lua.lua_setfield(L, -2, to_luastring('__fid'));
        return 1;
      });
      const getf = () => { lua.lua_getfield(L, 1, to_luastring('__fid')); const id = lua.lua_tointeger(L, -1); lua.lua_pop(L, 1); return files.get(id); };
      setfn('read', () => {
        const f = getf(); if (!f) { lua.lua_pushnil(L); return 1; }
        const n = opt(2, 1);
        const s = f.data.substr(f.pos, n); f.pos += s.length;
        pushStr(s); return 1;
      });
      setfn('write', () => {
        const f = getf(); if (!f) return 0;
        const n = lua.lua_gettop(L);
        for (let i = 2; i <= n; i++) f.data += to_jsstring(lauxlib.luaL_tolstring(L, i)), lua.lua_pop(L, 1);
        return 0;
      });
      setfn('seek', () => { const f = getf(); if (f) f.pos = opt(2, 0); return 0; });
      setfn('close', () => {
        const f = getf(); if (!f) return 0;
        if (f.mode[0] !== 'r') { self.sd.set(f.path, f.data); if (self.onSave) self.onSave(f.path, f.data); }
        return 0;
      });
      lua.lua_setglobal(L, to_luastring('io'));

      // loadScript(path [, mode [, env]]): scripts from the virtual SD card
      global('loadScript', () => {
        const path = str(1);
        const src = self.files[path] !== undefined ? self.files[path] : self.sd.get(path);
        if (src === undefined) { lua.lua_pushnil(L); pushStr(path + ': file not found'); return 2; }
        if (lauxlib.luaL_loadbuffer(L, to_luastring(src), null, to_luastring('@' + path.replace(/^.*\//, ''))) !== lua.LUA_OK) {
          const msg = lua.lua_tostring(L, -1); lua.lua_pop(L, 1);
          lua.lua_pushnil(L); lua.lua_pushstring(L, msg); return 2;
        }
        return 1;
      });

      // extra globals (e.g. test hooks, FPVSIM_LAT)
      for (const k in globals) {
        if (globals[k] === 'table') { lua.lua_newtable(L); lua.lua_setglobal(L, to_luastring(k)); }
        else if (typeof globals[k] === 'number') { lua.lua_pushnumber(L, globals[k]); lua.lua_setglobal(L, to_luastring(k)); }
      }

      // ---- lcd
      lua.lua_newtable(L);
      if (this.color) this.colorLcd(setfn, { L, lua, int, opt, num, u32, str, pushStr });
      else this.bwLcd(setfn, { L, lua, int, opt, num, u32, str, pushStr });
      lua.lua_setglobal(L, to_luastring('lcd'));
    }

    // ============================================================ COLOR LCD
    colorLcd(setfn, A) {
      const { L, lua, int, opt, u32, str } = A;
      const self = this, W = this.W, H = this.H, fb = this.fb, st = () => self.stats;
      const colorOf = (flags) => {
        flags = u32(flags);
        if (flags & 0x8000) return flags >>> 16;
        const idx = flags >>> 16;
        return idx < NAMED565.length ? NAMED565[idx] : 0;
      };
      const blend565 = (dst, src, a) => { // a 0..255
        const r1 = dst >> 11, g1 = (dst >> 5) & 63, b1 = dst & 31;
        const r2 = src >> 11, g2 = (src >> 5) & 63, b2 = src & 31;
        const r = (r2 * a + r1 * (255 - a) + 127) / 255 | 0, g = (g2 * a + g1 * (255 - a) + 127) / 255 | 0, b = (b2 * a + b1 * (255 - a) + 127) / 255 | 0;
        return (r << 11) | (g << 5) | b;
      };
      const hline = (x, y, w, c, opa) => { // opacity 0..15 like EdgeTX (0 = opaque)
        if (y < 0 || y >= H || w <= 0) return;
        if (x < 0) { w += x; x = 0; }
        if (x + w > W) w = W - x;
        if (w <= 0) return;
        const o = y * W + x;
        if (!opa) { fb.fill(c, o, o + w); }
        else { const a = Math.round((15 - opa) * 255 / 15); for (let i = 0; i < w; i++) fb[o + i] = blend565(fb[o + i], c, a); st().blendPx += w; }
        st().scanPx += w;
      };
      const fillRect = (x, y, w, h, c, opa) => {
        if (opa >= 15) return;
        if (w < 0) { x += w; w = -w; }
        if (h < 0) { y += h; h = -h; }
        if (x < 0) { w += x; x = 0; } if (y < 0) { h += y; y = 0; }
        if (x + w > W) w = W - x; if (y + h > H) h = H - y;
        if (w <= 0 || h <= 0) return;
        st().rects++; st().rectPx += w * h;
        if (!opa) { for (let j = 0; j < h; j++) { const o = (y + j) * W + x; fb.fill(c, o, o + w); } }
        else { const a = Math.round((15 - opa) * 255 / 15); st().blendPx += w * h; for (let j = 0; j < h; j++) { const o = (y + j) * W + x; for (let i = 0; i < w; i++) fb[o + i] = blend565(fb[o + i], c, a); } }
      };
      // EdgeTX BitmapBuffer::drawLine: Liang-Barsky clip, then Bresenham with pattern
      const line = (x1, y1, x2, y2, pat, c) => {
        st().lines++;
        let t0 = 0, t1 = 1;
        const dx = x2 - x1, dy = y2 - y1;
        const clip = (p, q) => {
          if (p === 0) return q >= 0;
          const r = q / p;
          if (p < 0) { if (r > t1) return false; if (r > t0) t0 = r; }
          else { if (r < t0) return false; if (r < t1) t1 = r; }
          return true;
        };
        if (!clip(-dx, x1) || !clip(dx, W - 1 - x1) || !clip(-dy, y1) || !clip(dy, H - 1 - y1)) return;
        let ax = x1 + t0 * dx, ay = y1 + t0 * dy, bx = x1 + t1 * dx, by = y1 + t1 * dy;
        ax = Math.round(ax); ay = Math.round(ay); bx = Math.round(bx); by = Math.round(by);
        let ddx = bx - ax, ddy = by - ay;
        const adx = Math.abs(ddx), ady = Math.abs(ddy), sx = Math.sign(ddx), sy = Math.sign(ddy);
        let x = ady >> 1, y = adx >> 1, px = ax, py = ay;
        if (adx >= ady) {
          for (let i = 0; i <= adx; i++) {
            if (((1 << (px & 7)) & pat) && px >= 0 && px < W && py >= 0 && py < H) fb[py * W + px] = c;
            y += ady; if (y >= adx) { y -= adx; py += sy; } px += sx;
          }
        } else {
          for (let i = 0; i <= ady; i++) {
            if (((1 << (py & 7)) & pat) && px >= 0 && px < W && py >= 0 && py < H) fb[py * W + px] = c;
            x += adx; if (x >= ady) { x -= ady; px += sx; } py += sy;
          }
        }
        st().linePx += Math.max(adx, ady) + 1;
      };
      // Adafruit GFX fill as in BitmapBuffer::drawFilledTriangle (one hline per row)
      const tri = (x0, y0, x1, y1, x2, y2, c, opa) => {
        st().tris++;
        let t;
        if (y0 > y1) { t = y0; y0 = y1; y1 = t; t = x0; x0 = x1; x1 = t; }
        if (y1 > y2) { t = y2; y2 = y1; y1 = t; t = x2; x2 = x1; x1 = t; }
        if (y0 > y1) { t = y0; y0 = y1; y1 = t; t = x0; x0 = x1; x1 = t; }
        const row = (a, b, y) => { if (a > b) { const q = a; a = b; b = q; } st().scan++; hline(a, y, b - a + 1, c, opa); };
        if (y0 === y2) { row(Math.min(x0, x1, x2), Math.max(x0, x1, x2), y0); return; }
        const dx01 = x1 - x0, dy01 = y1 - y0, dx02 = x2 - x0, dy02 = y2 - y0, dx12 = x2 - x1, dy12 = y2 - y1;
        let sa = 0, sb = 0, y;
        const last = y1 === y2 ? y1 : y1 - 1;
        // rows outside the screen are skipped cheaply (firmware does the same work in its clip test)
        for (y = y0; y <= last; y++) {
          if (y >= 0 && y < H) row(x0 + Math.trunc(sa / dy01), x0 + Math.trunc(sb / dy02), y); else st().scan += 0.03;
          sa += dx01; sb += dx02;
        }
        sa = dx12 * (y - y1); sb = dx02 * (y - y0);
        for (; y <= y2; y++) {
          if (y >= 0 && y < H) row(x1 + Math.trunc(sa / dy12), x0 + Math.trunc(sb / dy02), y); else st().scan += 0.03;
          sa += dx12; sb += dx02;
        }
      };
      const px = this.radio.fonts || 'std';
      const fonts = this.colorFonts;
      const textFace = (flags) => { const i = (flags >> 8) & 0xF; return { px: FONT_PX[px][i] || 16, bold: FONT_BOLD[i] }; };
      const drawStr = (x, y, s, flags) => {
        flags = u32(flags);
        const f = textFace(flags);
        const face = fonts.face(f.px, f.bold);
        const m = fonts.measure(s, f.px, f.bold);
        if (flags & COLOR_FLAGS.RIGHT) x -= m.w; else if (flags & COLOR_FLAGS.CENTER) x -= m.w / 2;
        if (flags & COLOR_FLAGS.VCENTER) y -= m.h / 2;
        x = Math.round(x); y = Math.round(y);
        st().texts++;
        const put = (ox, oy, c) => {
          let cx = ox;
          for (const ch of s) {
            const g = fonts.glyph(face, ch);
            st().glyphs++;
            if (g.a) {
              const gx = Math.round(cx + g.ox), gy = oy + g.oy;
              for (let j = 0; j < g.h; j++) {
                const yy = gy + j; if (yy < 0 || yy >= H) continue;
                for (let i = 0; i < g.w; i++) {
                  const a = g.a[j * g.w + i]; if (!a) continue;
                  const xx = gx + i; if (xx < 0 || xx >= W) continue;
                  const o = yy * W + xx; fb[o] = a >= 250 ? c : blend565(fb[o], c, a);
                }
              }
            }
            cx += g.adv;
          }
        };
        if (flags & COLOR_FLAGS.INVERS) fillRect(x - 1, y, m.w + 2, m.h, colorOf(flags), 0);
        if (flags & COLOR_FLAGS.SHADOWED) put(x + 1, y + 1, 0);
        put(x, y, (flags & COLOR_FLAGS.INVERS) ? 0xFFFF : colorOf(flags));
        return m;
      };
      const numStr = (v, flags) => {
        const prec = flags & 0x30;
        let s;
        if (prec === 0x20) s = (v / 10).toFixed(1); else if (prec === 0x30) s = (v / 100).toFixed(2); else s = String(v);
        return s;
      };

      setfn('clear', () => { const c = lua.lua_isnoneornil(L, 1) ? NAMED565[5] : colorOf(int(1)); fb.fill(c); st().rects++; st().rectPx += W * H; });
      setfn('refresh', () => 0);
      setfn('resetBacklightTimeout', () => 0);
      setfn('exitFullScreen', () => 0);
      setfn('RGB', () => {
        let r, g, b;
        if (lua.lua_gettop(L) === 1) { const v = int(1); r = (v >> 16) & 255; g = (v >> 8) & 255; b = v & 255; }
        else { r = int(1); g = int(2); b = int(3); }
        lua.lua_pushinteger(L, (((rgb565(r, g, b) << 16) | 0x8000) | 0));
        return 1;
      });
      setfn('setColor', () => 0);
      setfn('getColor', () => { lua.lua_pushinteger(L, int(1)); return 1; });
      setfn('drawPoint', () => { const x = int(1), y = int(2); if (x >= 0 && y >= 0 && x < W && y < H) fb[y * W + x] = colorOf(opt(3, 0)); });
      // luaLcdDrawLine: an end beyond the right or bottom edge (x > LCD_W, y > LCD_H) -> nothing drawn
      setfn('drawLine', () => {
        const x1 = int(1), y1 = int(2), x2 = int(3), y2 = int(4);
        if (x1 > W || y1 > H || x2 > W || y2 > H) { st().lines++; st().rejected++; return; }
        line(x1, y1, x2, y2, int(5) & 255, colorOf(opt(6, 0)));
      });
      setfn('drawLineWithClipping', () => {
        const x1 = int(1), y1 = int(2), x2 = int(3), y2 = int(4), xmin = int(5), xmax = int(6), ymin = int(7), ymax = int(8);
        // approximate: clip then draw
        line(x1, y1, x2, y2, int(9) & 255, colorOf(opt(10, 0)));
        void xmin; void xmax; void ymin; void ymax;
      });
      setfn('drawFilledRectangle', () => fillRect(int(1), int(2), int(3), int(4), colorOf(opt(5, 0)), opt(6, 0) & 15));
      setfn('drawRectangle', () => {
        const x = int(1), y = int(2), w = int(3), h = int(4), c = colorOf(opt(5, 0)), t = opt(6, 1), o = opt(7, 0) & 15;
        fillRect(x, y, t, h, c, o); fillRect(x + w - t, y, t, h, c, o); fillRect(x + t, y, w - 2 * t, t, c, o); fillRect(x + t, y + h - t, w - 2 * t, t, c, o);
      });
      setfn('invertRect', () => {
        const x = int(1), y = int(2), w = int(3), h = int(4);
        for (let j = Math.max(0, y); j < Math.min(H, y + h); j++) for (let i = Math.max(0, x); i < Math.min(W, x + w); i++) fb[j * W + i] ^= 0xFFFF;
      });
      setfn('drawFilledTriangle', () => tri(int(1), int(2), int(3), int(4), int(5), int(6), colorOf(opt(7, 0)), opt(8, 0) & 15));
      setfn('drawTriangle', () => {
        const c = colorOf(opt(7, 0)), x1 = int(1), y1 = int(2), x2 = int(3), y2 = int(4), x3 = int(5), y3 = int(6);
        line(x1, y1, x2, y2, 255, c); line(x2, y2, x3, y3, 255, c); line(x3, y3, x1, y1, 255, c);
      });
      setfn('drawFilledCircle', () => {
        const cx = int(1), cy = int(2), r = int(3), c = colorOf(opt(4, 0));
        for (let dy = -r; dy <= r; dy++) { const dx = Math.floor(Math.sqrt(r * r - dy * dy)); hline(cx - dx, cy + dy, dx * 2 + 1, c, 0); }
      });
      setfn('drawCircle', () => {
        const cx = int(1), cy = int(2), r = int(3), c = colorOf(opt(4, 0));
        for (let a = 0; a < 360; a += 1) { const x = Math.round(cx + r * Math.cos(a * Math.PI / 180)), y = Math.round(cy + r * Math.sin(a * Math.PI / 180)); if (x >= 0 && y >= 0 && x < W && y < H) fb[y * W + x] = c; }
      });
      setfn('drawText', () => { drawStr(int(1), int(2), str(3), opt(4, 0)); });
      setfn('sizeText', () => {
        const flags = u32(opt(2, 0)); const f = textFace(flags);
        const m = fonts.measure(str(1), f.px, f.bold);
        lua.lua_pushinteger(L, m.w); lua.lua_pushinteger(L, m.h); return 2;
      });
      setfn('drawNumber', () => { const flags = opt(4, 0); drawStr(int(1), int(2), numStr(int(3), flags), flags); });
      setfn('drawTimer', () => {
        let v = int(3); const neg = v < 0; v = Math.abs(v);
        const s = (neg ? '-' : '') + String(Math.floor(v / 60)).padStart(2, '0') + ':' + String(v % 60).padStart(2, '0');
        drawStr(int(1), int(2), s, opt(4, 0));
      });
      setfn('drawGauge', () => {
        const x = int(1), y = int(2), w = int(3), h = int(4), n = int(5), d = int(6), c = colorOf(opt(7, 0));
        fillRect(x, y, w, h, NAMED565[10], 0); fillRect(x, y, Math.round(w * Math.max(0, Math.min(1, n / d))), h, c, 0);
      });
      setfn('drawHudRectangle', () => 0);
      setfn('drawBitmap', () => 0);
      setfn('drawSource', () => 0); setfn('drawSwitch', () => 0); setfn('drawChannel', () => 0);
    }

    // ============================================================== B&W LCD
    bwLcd(setfn, A) {
      const { L, lua, int, opt, u32, str } = A;
      const self = this, W = this.W, H = this.H, fb = this.fb, st = () => self.stats;
      const grey = this.depth > 1;
      const F = BW_FLAGS;
      // lcdMaskPoint: FORCE sets, ERASE clears, otherwise XOR (4-bit: grey mask)
      const point = (x, y, att) => {
        if (x < 0 || y < 0 || x >= W || y >= H) return;
        const o = y * W + x;
        const mask = grey ? (0x0F - ((att >> 16) & 0x0F)) : 0x0F;
        if (att & F.FORCE) fb[o] |= mask;
        else if (att & F.ERASE) fb[o] &= ~mask & 0x0F;
        else fb[o] ^= mask;
      };
      const hline = (x, y, w, pat, att) => {
        if (y < 0 || y >= H || w === 0) return;
        if (w < 0) { x = x + w + 1; w = -w; }
        if (x + w <= 0 || x >= W) return;
        if (x < 0) { w += x; x = 0; }
        if (x + w > W) w = W - x;
        st().linePx += w;
        while (w--) {
          if (pat & 1) { point(x, y, att); pat = (pat >> 1) | 0x80; } else pat >>= 1;
          x++;
        }
      };
      const vline = (x, y, h, pat, att) => {
        if (x < 0 || x >= W || h === 0) return;
        if (h < 0) { y = y + h + 1; h = -h; }
        if (y + h <= 0 || y >= H) return;
        if (y < 0) { h += y; y = 0; }
        if (y + h > H) h = H - y;
        st().linePx += h;
        for (let i = 0; i < h; i++) if (pat === 0xff || ((1 << ((y + i) & 7)) & pat)) point(x, y + i, att);
      };
      const bres = (x1, y1, x2, y2, pat, att) => {
        const dx = x2 - x1, dy = y2 - y1, adx = Math.abs(dx), ady = Math.abs(dy), sx = Math.sign(dx), sy = Math.sign(dy);
        let x = ady >> 1, y = adx >> 1, px = x1, py = y1;
        st().linePx += Math.max(adx, ady) + 1;
        if (adx >= ady) {
          for (let i = 0; i <= adx; i++) { if ((1 << (px % 8)) & pat) point(px, py, att); y += ady; if (y >= adx) { y -= adx; py += sy; } px += sx; }
        } else {
          for (let i = 0; i <= ady; i++) { if ((1 << (py % 8)) & pat) point(px, py, att); x += adx; if (x >= ady) { x -= ady; px += sx; } py += sy; }
        }
      };
      const fillRect = (x, y, w, h, att) => {
        st().rects++;
        let pat = 0xff;
        for (let i = y; i < y + h; i++) {
          if ((att & F.ROUND) && (i === y || i === y + h - 1)) hline(x + 1, i, w - 2, pat, att); else hline(x, i, w, pat, att);
          pat = (pat >> 1) + ((pat & 1) << 7);
        }
        st().rectPx += Math.max(0, w * h);
      };
      // text with the bitmap fonts: glyph cells are opaque (FORCE/ERASE), INVERS swaps
      const FONT_KEYS = ['std', 'tin', 'sml', 'mid', 'dbl', 'xxl'];
      const fontOf = (flags) => self.bwFonts[FONT_KEYS[(flags >> 8) & 0xF] || 'std'];
      const textW = (s, f) => s.length * f.adv;
      const drawStr = (x, y, s, flags) => {
        flags = u32(flags);
        const f = fontOf(flags);
        const w = textW(s, f);
        if (flags & F.RIGHT) x -= w; else if (flags & F.CENTER) x -= Math.floor(w / 2);
        const inv = (flags & F.INVERS) !== 0;
        const lh = f.y1 - f.y0, base = -f.y0;
        st().texts++;
        if (inv) fillRect(x - 1, y - 1, w + 2, lh + 1, F.FORCE);
        else for (let j = 0; j < lh; j++) hline(x, y + j, w, 0xff, F.ERASE);
        let cx = x;
        for (const ch of s) {
          const code = ch.charCodeAt(0);
          const g = f.g[(code >= 32 && code < 127) ? code - 32 : 31];
          st().glyphs++;
          if (g && g[4]) {
            const rows = g[5].split(',');
            for (let j = 0; j < g[4]; j++) {
              const bits = +rows[j];
              if (!bits) continue;
              for (let i = 0; i < g[3]; i++) if (bits & (1 << i)) {
                point(cx + g[1] + i, y + base + g[2] + j, inv ? F.ERASE : F.FORCE);
                if (flags & F.BOLD) point(cx + g[1] + i + 1, y + base + g[2] + j, inv ? F.ERASE : F.FORCE);
              }
            }
          }
          cx += f.adv;
        }
      };
      const numStr = (v, flags) => {
        const prec = flags & 0x30;
        if (prec === 0x20) return (v / 10).toFixed(1);
        if (prec === 0x30) return (v / 100).toFixed(2);
        return String(v);
      };
      const uarg = (i) => u32(int(i));

      setfn('clear', () => { fb.fill(0); });
      setfn('refresh', () => 0);
      setfn('resetBacklightTimeout', () => 0);
      setfn('drawPoint', () => point(int(1), int(2), opt(3, 0)));
      // luaLcdDrawLine: unsigned args, any point beyond the screen -> nothing drawn
      setfn('drawLine', () => {
        const x1 = uarg(1), y1 = uarg(2), x2 = uarg(3), y2 = uarg(4), pat = uarg(5) & 255, att = uarg(6);
        st().lines++;
        if (x1 > W || y1 > H || x2 > W || y2 > H) { st().rejected = (st().rejected || 0) + 1; return; }
        if (pat === 0xff) {
          if (x1 === x2) { vline(x1, Math.min(y1, y2), Math.abs(y2 - y1) + 1, 0xff, att); return; }
          if (y1 === y2) { hline(Math.min(x1, x2), y1, Math.abs(x2 - x1) + 1, 0xff, att); return; }
        }
        bres(x1, y1, x2, y2, pat, att);
      });
      setfn('drawFilledRectangle', () => fillRect(int(1), int(2), int(3), int(4), u32(opt(5, 0))));
      setfn('drawRectangle', () => {
        const x = int(1), y = int(2), w = int(3), h = int(4), att = u32(opt(5, 0));
        vline(x, y, h, 0xff, att); vline(x + w - 1, y, h, 0xff, att);
        hline(x + 1, y + h - 1, w - 2, 0xff, att); hline(x + 1, y, w - 2, 0xff, att);
      });
      setfn('drawText', () => drawStr(int(1), int(2), str(3), opt(4, 0)));
      setfn('drawNumber', () => { const flags = opt(4, 0); drawStr(int(1), int(2), numStr(int(3), flags), flags & ~0x30); });
      setfn('drawTimer', () => {
        let v = int(3); const neg = v < 0; v = Math.abs(v);
        drawStr(int(1), int(2), (neg ? '-' : '') + String(Math.floor(v / 60)).padStart(2, '0') + ':' + String(v % 60).padStart(2, '0'), opt(4, 0));
      });
      setfn('drawScreenTitle', () => { fillRect(0, 0, W, 9, F.FORCE); drawStr(1, 1, str(1), F.INVERS); });
      setfn('drawGauge', () => {
        const x = int(1), y = int(2), w = int(3), h = int(4), n = int(5), d = int(6);
        fillRect(x, y, w, h, F.ERASE);
        fillRect(x, y, Math.round(w * Math.max(0, Math.min(1, n / d))), h, F.FORCE);
      });
      setfn('getLastPos', () => { lua.lua_pushinteger(L, 0); return 1; });
      setfn('getLastRightPos', () => { lua.lua_pushinteger(L, 0); return 1; });
      setfn('getLastLeftPos', () => { lua.lua_pushinteger(L, 0); return 1; });
      setfn('drawSource', () => 0); setfn('drawSwitch', () => 0); setfn('drawChannel', () => 0);
      setfn('drawPixmap', () => 0); setfn('drawCombobox', () => 0);
    }

    // RGBA output for display -------------------------------------------
    toRGBA(out, opts = {}) {
      const n = this.W * this.H;
      const fb = (this.color && this.displayDelay && this.shown) ? this.shown : this.fb;
      if (this.color) {
        const lut = Engine.lut || (Engine.lut = (() => {
          const t = new Uint32Array(65536);
          for (let v = 0; v < 65536; v++) {
            const r = v >> 11, g = (v >> 5) & 63, b = v & 31;
            t[v] = (255 << 24) | (((b << 3) | (b >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | ((r << 3) | (r >> 2));
          }
          return t;
        })());
        for (let i = 0; i < n; i++) out[i] = lut[fb[i]];
        return;
      }
      // B&W LCD: optional slow-response ghosting (real B&W panels smear)
      const ghost = opts.ghost ? 0.55 : 1;
      if (!this.lcdLevel || this.lcdLevel.length !== n) this.lcdLevel = new Float32Array(n);
      const lv = this.lcdLevel;
      const bg = opts.bg || [200, 208, 190], ink = opts.ink || [24, 30, 26];
      for (let i = 0; i < n; i++) {
        const t = fb[i] / 15;
        lv[i] += (t - lv[i]) * ghost;
        const k = lv[i];
        const r = bg[0] + (ink[0] - bg[0]) * k, g = bg[1] + (ink[1] - bg[1]) * k, b = bg[2] + (ink[2] - bg[2]) * k;
        out[i] = (255 << 24) | ((b | 0) << 16) | ((g | 0) << 8) | (r | 0);
      }
    }
  }

  return { Engine, ColorFonts, RADIOS, CPU, KEY_EVENT };
})();

if (typeof module !== 'undefined') module.exports = EdgeTX;
