/* Web UI around the EdgeTX engine: radio picker, gimbals, keys, gamepad, sound,
   radio load estimate. Exposes window.sim for automation. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const { Engine, ColorFonts, RADIOS, CPU } = EdgeTX;
  const lua = (id) => $(id).textContent.replace(/^\n/, '');
  const LUA = { color: lua('lua-color'), bw: lua('lua-bw'), lite: lua('lua-lite') };

  const store = {
    get(k, d) { try { const v = localStorage.getItem('fpvsim.' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('fpvsim.' + k, JSON.stringify(v)); } catch (e) { /* storage blocked */ } },
  };

  const app = {
    radio: RADIOS.find((r) => r.id === store.get('radio', 'tx16s')) || RADIOS[0],
    script: store.get('script', 'auto'),
    custom: null,
    engine: null,
    paused: false,
    rate: store.get('rate', 50),
    ghost: store.get('ghost', true),
    delay: store.get('delay', true),
    sound: false,
    mode: store.get('mode', 2),
    input: 'mix',
    cpu: null,
    sd: new Map(Object.entries(store.get('sd', {}))),
    pad: store.get('padmap', { ail: [0, false], ele: [1, false], thr: [2, false], rud: [3, false] }),
  };
  const stick = { ail: 0, ele: 0, thr: -1, rud: 0 };   // -1..1
  const colorFonts = new ColorFonts('RobotoEmu, Roboto, Arial, sans-serif');
  const canvas = $('lcd');
  const ctx = canvas.getContext('2d');
  let img = null, img32 = null;

  // ------------------------------------------------------------ fonts
  async function loadFonts() {
    try {
      const buf = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
      const faces = [new FontFace('RobotoEmu', buf(ROBOTO.r), { weight: '400' }), new FontFace('RobotoEmu', buf(ROBOTO.b), { weight: '700' })];
      for (const f of faces) { await f.load(); document.fonts.add(f); }
    } catch (e) { console.warn('LCD font fallback', e); }
  }

  // ------------------------------------------------------------- sound
  let actx = null, toneEnd = 0, live = [];
  function tone(freq, dur, pause, flags) {
    if (!app.sound || !actx) return;
    const now = actx.currentTime;
    if (flags & 1) { live.forEach((o) => { try { o.stop(); } catch (e) { /* already stopped */ } }); live = []; toneEnd = now; }
    const t0 = Math.max(now, toneEnd), t1 = t0 + Math.max(0.02, dur / 1000);
    const o = actx.createOscillator(), g = actx.createGain();
    o.type = 'square';
    o.frequency.value = Math.max(50, freq);
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(0.045, t0 + 0.006);
    g.gain.setValueAtTime(0.045, Math.max(t0 + 0.007, t1 - 0.012));
    g.gain.exponentialRampToValueAtTime(0.0001, t1);
    o.connect(g).connect(actx.destination);
    o.start(t0); o.stop(t1 + 0.02);
    live.push(o);
    o.onended = () => { live = live.filter((x) => x !== o); };
    toneEnd = t1 + Math.max(0, pause) / 1000;
  }
  function haptic(ms) {
    const r = $('radio');
    r.classList.remove('buzz'); void r.offsetWidth; r.classList.add('buzz');
    try { if (navigator.vibrate) navigator.vibrate(Math.min(200, ms * 10)); } catch (e) { /* blocked */ }
  }

  // ----------------------------------------------------------- engine
  function scriptFor() {
    if (app.custom) return { text: app.custom.text, name: app.custom.name };
    const kind = app.script === 'auto' ? (app.radio.color ? 'color' : 'bw') : app.script;
    return { text: LUA[kind], name: kind === 'color' ? 'FPVSim.lua' : kind === 'lite' ? 'FPVLite/core.lua' : 'FPVSimBW/core.lua' };
  }

  function boot() {
    const r = app.radio;
    const eng = new Engine(fengari, r, {
      colorFonts, bwFonts: BW_FONTS, sd: app.sd,
      files: Object.assign({ '/SCRIPTS/TOOLS/FPVSimBW/core.lua': LUA.bw, '/SCRIPTS/TOOLS/FPVLite/core.lua': LUA.lite }, LITE_TRACKS),
      onTone: tone, onHaptic: haptic,
      onSave: () => store.set('sd', Object.fromEntries(app.sd)),
    });
    eng.stickMode = app.mode - 1;
    // PC mode: big screen, 60 fps, frames shown at once (no radio display delay)
    eng.displayDelay = !r.pc && app.delay;
    app.engine = eng;
    canvas.width = r.w; canvas.height = r.h;
    img = ctx.createImageData(r.w, r.h);
    img32 = new Uint32Array(img.data.buffer);
    $('lcdName').textContent = r.label.split('  ')[1].split(' · ')[0];
    $('lcdRes').textContent = r.w + '×' + r.h + (r.color ? ' color' : r.depth > 1 ? ' grey' : ' mono');
    const s = scriptFor();
    const globals = { FPVSIM_TEST: 'table' };
    if (r.color && !eng.displayDelay) globals.FPVSIM_LAT = 0;   // nothing to predict when frames show at once
    eng.load(s.text, s.name, globals);
    $('rateChk').disabled = !!r.pc;
    $('delayChk').disabled = !!r.pc;
    $('loadCard').classList.toggle('pc', !!r.pc);
    sizeCanvas();
    showOverlay();
    draw();
    updateCpuName();
  }

  function draw() {
    if (!app.engine) return;
    app.engine.toRGBA(img32, { ghost: app.ghost });
    ctx.putImageData(img, 0, 0);
  }

  function showOverlay() {
    const e = app.engine, o = $('overlay');
    if (e && e.error) {
      o.hidden = false;
      $('ovTitle').textContent = e.error.title;
      $('ovMsg').textContent = e.error.msg;
      $('ovMsg').hidden = false;
      $('ovBtn').textContent = 'Restart script';
    } else if (e && e.exited) {
      o.hidden = false;
      $('ovTitle').textContent = 'Script closed';
      $('ovMsg').hidden = true;
      $('ovBtn').textContent = 'Run it again';
    } else {
      o.hidden = true;
    }
  }

  function sizeCanvas() {
    const r = app.radio;
    const wide = window.innerWidth > 760;
    const stageW = $('stage').clientWidth - 40;
    const gimbalW = wide ? 2 * ($('gL').offsetWidth + 22) : 0;
    const avail = Math.max(160, stageW - gimbalW - 70);
    let k = avail / r.w;
    if (!r.color) k = Math.max(1, Math.min(6, Math.floor(k)));
    else if (k >= 2) k = 2;
    else if (k >= 1.5) k = 1.5;
    else if (k >= 1) k = 1;
    canvas.style.width = Math.floor(r.w * k) + 'px';
    canvas.classList.toggle('smooth', r.color && Math.abs(k - Math.round(k)) > 0.01);
  }

  // ---------------------------------------------------------- gimbals
  // stick function per gimbal axis, by stick mode (1..4)
  const MODES = { 1: ['rud', 'ele', 'ail', 'thr'], 2: ['rud', 'thr', 'ail', 'ele'], 3: ['ail', 'ele', 'rud', 'thr'], 4: ['ail', 'thr', 'rud', 'ele'] };
  const NAMES = { ail: 'Roll', ele: 'Pitch', thr: 'Throttle', rud: 'Yaw' };
  function gimbalAxes(side) {
    const m = MODES[app.mode];
    return side === 'L' ? [m[0], m[1]] : [m[2], m[3]];
  }
  function labelGimbals() {
    const l = gimbalAxes('L'), r = gimbalAxes('R');
    $('gLlabel').textContent = NAMES[l[1]] + ' · ' + NAMES[l[0]];
    $('gRlabel').textContent = NAMES[r[1]] + ' · ' + NAMES[r[0]];
  }
  const drag = { L: null, R: null };
  function setupGimbal(side) {
    const pad = $('g' + side).querySelector('.gimbal-pad');
    const apply = (ev) => {
      const b = pad.getBoundingClientRect();
      const x = ((ev.clientX - b.left) / b.width - 0.5) / 0.36;
      const y = -((ev.clientY - b.top) / b.height - 0.5) / 0.36;
      const [ax, ay] = gimbalAxes(side);
      stick[ax] = Math.max(-1, Math.min(1, x));
      stick[ay] = Math.max(-1, Math.min(1, y));
    };
    pad.addEventListener('pointerdown', (ev) => { pad.setPointerCapture(ev.pointerId); drag[side] = ev.pointerId; pad.classList.add('dragging'); apply(ev); ev.preventDefault(); });
    pad.addEventListener('pointermove', (ev) => { if (drag[side] === ev.pointerId) apply(ev); });
    const end = (ev) => {
      if (drag[side] !== ev.pointerId) return;
      drag[side] = null; pad.classList.remove('dragging');
      const [ax, ay] = gimbalAxes(side);
      if (ax !== 'thr') stick[ax] = 0;
      if (ay !== 'thr') stick[ay] = 0;
    };
    pad.addEventListener('pointerup', end);
    pad.addEventListener('pointercancel', end);
  }
  function renderGimbals() {
    for (const side of ['L', 'R']) {
      const [ax, ay] = gimbalAxes(side);
      const el = $('g' + side).querySelector('.stick');
      el.style.left = (50 + stick[ax] * 36) + '%';
      el.style.top = (50 - stick[ay] * 36) + '%';
    }
  }

  // ---------------------------------------------------------- keyboard
  const held = new Set();
  let exitDown = 0, exitLongSent = false;
  const isField = (t) => t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA');
  function key(name) { if (app.engine) app.engine.key(name); }
  window.addEventListener('keydown', (e) => {
    if (isField(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
    const k = e.key;
    const handled = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'w', 'a', 's', 'd', 'W', 'A', 'S', 'D', 'Enter', 'Escape', 'Backspace', ' ', 'PageUp', 'PageDown', '+', '-', '='].includes(k);
    if (handled) e.preventDefault();
    if (e.repeat) { held.add(k.toLowerCase()); return; }
    held.add(k.length === 1 ? k.toLowerCase() : k);
    if (k === 'Enter') key('enter');
    else if (k === 'Escape' || k === 'Backspace') { exitDown = performance.now(); exitLongSent = false; }
    else if (k === 'ArrowUp' || k === '-') key('prev');
    else if (k === 'ArrowDown' || k === '+' || k === '=') key('next');
    else if (k === 'ArrowLeft') key('prev');
    else if (k === 'ArrowRight') key('next');
    else if (k === 'PageUp') key('pageUp');
    else if (k === 'PageDown') key('pageDn');
    else if (k === 'm' || k === 'M') key('menu');
    else if (k === 'r' || k === 'R') boot();
    else if (k === 'p' || k === 'P') togglePause();
    else if (k === 'f' || k === 'F') toggleFullscreen();
  });
  window.addEventListener('keyup', (e) => {
    const k = e.key;
    held.delete(k.length === 1 ? k.toLowerCase() : k);
    if ((k === 'Escape' || k === 'Backspace') && exitDown) {
      if (!exitLongSent) key('exit');
      exitDown = 0;
    }
  });
  window.addEventListener('blur', () => held.clear());

  function keyboardSticks(dt) {
    if (exitDown && !exitLongSent && performance.now() - exitDown > 900) {
      // long EXIT closes a tool script on color radios (firmware behaviour)
      exitLongSent = true;
      if (app.engine && app.radio.color) { app.engine.exited = true; showOverlay(); } else key('exit');
    }
    if (app.input === 'pad') return;
    const fast = held.has('Shift');
    const defl = fast ? 1 : 0.6;
    const k = 1 - Math.exp(-dt / 70);
    const axis = (fn, neg, pos) => {
      if (gimbalOwns(fn)) return;
      const t = (held.has(pos) ? defl : 0) - (held.has(neg) ? defl : 0);
      stick[fn] += (t - stick[fn]) * k;
      if (t === 0 && Math.abs(stick[fn]) < 0.003) stick[fn] = 0;
    };
    axis('ail', 'ArrowLeft', 'ArrowRight');
    axis('ele', 'ArrowDown', 'ArrowUp');
    axis('rud', 'a', 'd');
    if (!gimbalOwns('thr')) {
      if (held.has('w')) stick.thr = Math.min(1, stick.thr + dt / (fast ? 500 : 1400));
      if (held.has('s')) stick.thr = Math.max(-1, stick.thr - dt / (fast ? 500 : 1400));
    }
  }
  function gimbalOwns(fn) {
    for (const side of ['L', 'R']) if (drag[side] !== null && gimbalAxes(side).includes(fn)) return true;
    return false;
  }

  // ----------------------------------------------------------- gamepad
  let padIndex = -1, padBlocked = false;
  function readPad() {
    let pads = [];
    try { pads = navigator.getGamepads ? Array.from(navigator.getGamepads()) : []; padBlocked = false; } catch (e) { padBlocked = true; }
    const p = pads.find((g) => g && g.connected && g.axes.length >= 4) || null;
    padIndex = p ? p.index : -1;
    return p;
  }
  function gamepadSticks() {
    const p = readPad();
    updatePadUI(p);
    if (!p || app.input !== 'pad') return;
    for (const fn of ['ail', 'ele', 'thr', 'rud']) {
      const [ax, inv] = app.pad[fn];
      let v = p.axes[ax] || 0;
      if (inv) v = -v;
      if (fn !== 'thr' && Math.abs(v) < 0.02) v = 0;
      stick[fn] = Math.max(-1, Math.min(1, v));
    }
  }
  let padUiT = 0;
  function updatePadUI(p) {
    const now = performance.now();
    if (now - padUiT < 120) return;
    padUiT = now;
    const st = $('padStatus');
    if (padBlocked) { st.textContent = 'This browser frame blocks gamepads. Open simulator.html from the repo directly in Chrome or Edge to fly with your radio over USB.'; st.className = 'note warn'; }
    else if (!p) { st.textContent = 'Plug in the radio, choose USB Joystick on it, then move a stick so the browser sees it.'; st.className = 'note'; }
    else { st.textContent = 'Connected: ' + p.id.slice(0, 60) + ' (' + p.axes.length + ' axes)'; st.className = 'note'; }
    for (const fn of ['ail', 'ele', 'thr', 'rud']) {
      const m = document.querySelector('.axis[data-fn="' + fn + '"] .meter i');
      const v = p ? (p.axes[app.pad[fn][0]] || 0) * (app.pad[fn][1] ? -1 : 1) : stick[fn];
      m.style.left = (50 + Math.max(-1, Math.min(1, v)) * 48) + '%';
    }
  }

  // ------------------------------------------------------- touch on LCD
  let touch0 = null;
  function lcdXY(ev) {
    const b = canvas.getBoundingClientRect();
    return { x: Math.round((ev.clientX - b.left) / b.width * app.radio.w), y: Math.round((ev.clientY - b.top) / b.height * app.radio.h) };
  }
  canvas.addEventListener('pointerdown', (ev) => {
    if (!app.radio.color) return;
    canvas.setPointerCapture(ev.pointerId);
    const p = lcdXY(ev);
    touch0 = { x: p.x, y: p.y, t: performance.now(), moved: false };
    app.engine.touch('FIRST', { x: p.x, y: p.y, startX: p.x, startY: p.y, slideX: 0, slideY: 0, tapCount: 0 });
  });
  canvas.addEventListener('pointermove', (ev) => {
    if (!touch0) return;
    const p = lcdXY(ev);
    if (Math.abs(p.x - touch0.x) + Math.abs(p.y - touch0.y) > 8) touch0.moved = true;
  });
  canvas.addEventListener('pointerup', (ev) => {
    if (!touch0) return;
    const p = lcdXY(ev);
    const quick = performance.now() - touch0.t < 600;
    const t = { x: p.x, y: p.y, startX: touch0.x, startY: touch0.y, slideX: p.x - touch0.x, slideY: p.y - touch0.y, tapCount: 1 };
    app.engine.touch(!touch0.moved && quick ? 'TAP' : 'BREAK', t);
    touch0 = null;
  });
  canvas.addEventListener('wheel', (ev) => { ev.preventDefault(); key(ev.deltaY > 0 ? 'next' : 'prev'); }, { passive: false });

  // --------------------------------------------------------- load panel
  function updateCpuName() {
    const id = app.cpu || app.radio.cpu;
    $('cpuName').textContent = CPU[id].name;
    $('cpuSel').value = id;
  }
  let statT = 0;
  function updateStats() {
    const now = performance.now();
    if (now - statT < 300 || !app.engine) return;
    statT = now;
    const e = app.engine, s = e.last;
    const est = e.estimate(app.cpu || app.radio.cpu);
    const ms = est.ms;
    $('loadMs').textContent = ms.toFixed(1);
    const bar = $('loadBar');
    bar.firstElementChild.style.width = Math.min(100, ms / 50 * 100) + '%';
    bar.className = 'load-bar' + (ms > 50 ? ' bad' : ms > 38 ? ' warn' : '');
    const pill = $('loadPill');
    const fps = ms <= 50 ? 20 : Math.max(1, Math.floor(1000 / ms));
    pill.textContent = fps + ' fps on radio';
    pill.className = 'pill ' + (ms > 50 ? 'bad' : ms > 38 ? 'warn' : 'ok');
    const k = (n) => (n >= 10000 ? (n / 1000).toFixed(1) + 'k' : String(Math.round(n)));
    $('stInstr').textContent = k(s.instr);
    $('stCalls').textContent = k(s.calls);
    $('stLines').textContent = k(s.lines) + ' · ' + k(s.linePx) + ' px';
    $('stTris').textContent = k(s.tris) + ' · ' + k(s.scan) + ' rows';
    $('stRects').textContent = k(s.rects) + ' · ' + k(s.rectPx) + ' px';
    $('stText').textContent = k(s.texts) + ' · ' + k(s.glyphs) + ' chars';
    $('stEmu').textContent = emuFps + ' fps · frame ' + emuMs.toFixed(1) + ' ms';
  }

  // ---------------------------------------------------------- main loop
  let last = performance.now(), acc = 0, emuFps = 0, emuN = 0, emuT = last, emuMs = 0;
  const frameMs = () => (app.radio.pc ? 1000 / 60 : app.rate);
  function frame() {
    const t0 = performance.now();
    app.engine.sticks = { ail: stick.ail * 1024, ele: stick.ele * 1024, thr: stick.thr * 1024, rud: stick.rud * 1024 };
    app.engine.frame(frameMs());
    emuMs = emuMs * 0.8 + (performance.now() - t0) * 0.2;
    emuN++;
  }
  function loop(ts) {
    const dt = Math.min(250, ts - last);
    last = ts;
    keyboardSticks(dt);
    gamepadSticks();
    renderGimbals();
    const e = app.engine;
    if (!app.paused && e && !e.error && !e.exited) {
      acc += dt;
      let n = 0;
      const fm = frameMs();
      while (acc >= fm && n < 3) { frame(); acc -= fm; n++; }
      if (n === 3) acc = 0;
      if (n) {
        draw();
        if (e.error || e.exited) showOverlay();
      }
    }
    if (ts - emuT >= 1000) { emuFps = emuN; emuN = 0; emuT = ts; }
    updateStats();
    requestAnimationFrame(loop);
  }

  // fullscreen for the screen (handy in PC mode); F toggles it
  function toggleFullscreen() {
    const el = document.querySelector('.bezel');
    try {
      if (document.fullscreenElement) document.exitFullscreen();
      else if (el.requestFullscreen) el.requestFullscreen();
    } catch (e) { /* blocked in this frame */ }
  }

  function togglePause() {
    app.paused = !app.paused;
    $('pauseChk').checked = app.paused;
  }

  // ------------------------------------------------------------ wiring
  function setupUI() {
    const rs = $('radioSel');
    for (const r of RADIOS) {
      const o = document.createElement('option');
      o.value = r.id; o.textContent = r.label;
      rs.appendChild(o);
    }
    rs.value = app.radio.id;
    const ss = $('scriptSel');
    // the Lite is for B&W radios (STM32F2 class): pick one for it, and its CPU for the estimate
    const liteFits = () => {
      if (app.script !== 'lite') return;
      if (app.radio.color) { app.radio = RADIOS.find((r) => r.id === 'tx12'); rs.value = app.radio.id; store.set('radio', app.radio.id); }
      app.cpu = 'F2';
    };
    rs.addEventListener('change', () => {
      app.radio = RADIOS.find((r) => r.id === rs.value); store.set('radio', app.radio.id); app.cpu = null;
      if (app.script === 'lite' && app.radio.color) { app.script = 'auto'; ss.value = 'auto'; store.set('script', 'auto'); }
      liteFits();
      boot();
    });
    ss.value = app.script;
    ss.addEventListener('change', () => {
      if (ss.value === 'custom') return;
      app.script = ss.value; app.custom = null; store.set('script', app.script); app.cpu = null;
      liteFits();
      boot();
    });
    liteFits();
    $('restartBtn').addEventListener('click', boot);
    $('ovBtn').addEventListener('click', boot);
    $('soundBtn').addEventListener('click', () => {
      app.sound = !app.sound;
      if (app.sound && !actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { app.sound = false; } }
      if (actx && actx.state === 'suspended') actx.resume();
      $('soundBtn').setAttribute('aria-pressed', String(app.sound));
      $('soundBtn').textContent = app.sound ? 'Sound on' : 'Sound off';
    });
    $('fileIn').addEventListener('change', (ev) => {
      const f = ev.target.files[0];
      if (!f) return;
      const rd = new FileReader();
      rd.onload = () => {
        app.custom = { name: f.name, text: String(rd.result) };
        let o = ss.querySelector('option[value="custom"]');
        if (!o) { o = document.createElement('option'); o.value = 'custom'; ss.appendChild(o); }
        o.textContent = f.name;
        ss.value = 'custom';
        boot();
      };
      rd.readAsText(f);
      ev.target.value = '';
    });
    $('copyBtn').addEventListener('click', async () => {
      const s = scriptFor();
      const btn = $('copyBtn');
      try { await navigator.clipboard.writeText(s.text); btn.textContent = 'Copied ' + s.name; }
      catch (e) { btn.textContent = 'Copy blocked'; }
      setTimeout(() => { btn.textContent = 'Copy .lua'; }, 1800);
    });
    document.querySelectorAll('.key[data-key]').forEach((b) => {
      let downT = 0;
      b.addEventListener('pointerdown', () => { downT = performance.now(); });
      b.addEventListener('click', () => {
        const name = b.dataset.key;
        if (name === 'exit' && performance.now() - downT > 900) { if (app.radio.color) { app.engine.exited = true; showOverlay(); } return; }
        if (name === 'enter' && performance.now() - downT > 900) { key('enterLong'); return; }
        key(name);
      });
    });
    // stick mode
    document.querySelectorAll('#modeSeg button').forEach((b) => {
      b.setAttribute('aria-pressed', String(+b.dataset.mode === app.mode));
      b.addEventListener('click', () => {
        app.mode = +b.dataset.mode; store.set('mode', app.mode);
        document.querySelectorAll('#modeSeg button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
        if (app.engine) app.engine.stickMode = app.mode - 1;
        labelGimbals();
      });
    });
    document.querySelectorAll('#inputSeg button').forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.input === app.input));
      b.addEventListener('click', () => {
        app.input = b.dataset.input;
        document.querySelectorAll('#inputSeg button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
        $('padBox').hidden = app.input !== 'pad';
      });
    });
    $('padBox').hidden = true;
    for (const fn of ['ail', 'ele', 'thr', 'rud']) {
      const row = document.querySelector('.axis[data-fn="' + fn + '"]');
      const sel = row.querySelector('select');
      for (let i = 0; i < 8; i++) { const o = document.createElement('option'); o.value = i; o.textContent = 'axis ' + i; sel.appendChild(o); }
      sel.value = app.pad[fn][0];
      const inv = row.querySelector('input');
      inv.checked = app.pad[fn][1];
      sel.addEventListener('change', () => { app.pad[fn][0] = +sel.value; store.set('padmap', app.pad); });
      inv.addEventListener('change', () => { app.pad[fn][1] = inv.checked; store.set('padmap', app.pad); });
    }
    $('rateChk').checked = app.rate === 50;
    $('rateChk').addEventListener('change', () => { app.rate = $('rateChk').checked ? 50 : 1000 / 60; store.set('rate', app.rate); });
    $('delayChk').checked = app.delay;
    $('delayChk').addEventListener('change', () => {
      app.delay = $('delayChk').checked; store.set('delay', app.delay);
      const e = app.engine;
      if (e && !app.radio.pc) { e.displayDelay = app.delay; e.setGlobal('FPVSIM_LAT', app.delay ? null : 0); }
    });
    $('fsBtn').addEventListener('click', toggleFullscreen);
    $('ghostChk').checked = app.ghost;
    $('ghostChk').addEventListener('change', () => { app.ghost = $('ghostChk').checked; store.set('ghost', app.ghost); });
    $('pauseChk').addEventListener('change', () => { app.paused = $('pauseChk').checked; });
    $('cpuSel').addEventListener('change', () => { app.cpu = $('cpuSel').value; updateCpuName(); });
    setupGimbal('L');
    setupGimbal('R');
    labelGimbals();
    window.addEventListener('resize', sizeCanvas);
  }

  // automation hook (used by the test suite)
  window.sim = {
    get app() { return app; },
    get engine() { return app.engine; },
    radio(id) { $('radioSel').value = id; $('radioSel').dispatchEvent(new Event('change')); },
    script(id) { $('scriptSel').value = id; $('scriptSel').dispatchEvent(new Event('change')); },
    sticks(a, e, t, r) { stick.ail = a; stick.ele = e; stick.thr = t; stick.rud = r; },
    key, pause(p) { app.paused = p; },
    touch(type, x, y) { app.engine.touch(type, { x, y, startX: x, startY: y, slideX: 0, slideY: 0, tapCount: 1 }); },
    step(n, ms) { for (let i = 0; i < (n || 1); i++) { if (ms) app.rate = ms; frame(); } draw(); showOverlay(); return app.engine.error; },
    test(name, ...args) { return app.engine.callTest(name, ...args); },
    shot() { return canvas.toDataURL('image/png'); },
    boot,
  };

  loadFonts().then(() => {
    setupUI();
    boot();
    requestAnimationFrame(loop);
  });
})();
