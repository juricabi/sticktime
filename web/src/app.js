/* Web UI around the EdgeTX engine: radio picker, gimbals, keys, gamepad, sound,
   radio load estimate. Exposes window.sim for automation. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const { Engine, ColorFonts, RADIOS, CPU } = EdgeTX;
  const lua = (id) => $(id).textContent.replace(/^\n/, '');
  // bwcolor / litecolor: the B&W loaders' color.lua, which runs the B&W core on a color screen
  const LUA = { color: lua('lua-color'), bw: lua('lua-bw'), lite: lua('lua-lite'),
                bwcolor: lua('lua-bwcolor'), litecolor: lua('lua-litecolor') };

  const store = {
    // (the key prefix is from StickTime's old name, FPV Sim: kept so saved settings stay)
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
    vol: store.get('vol', 0.8),
    mode: store.get('mode', 2),
    input: 'mix',
    cpu: null,
    sd: new Map(Object.entries(store.get('sd', {}))),
    pad: store.get('padmap', { ail: [0, false], ele: [1, false], thr: [2, false], rud: [3, false] }),
    padKey: store.get('padKey', ''),
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
  let actx = null, toneEnd = 0, live = [], motor = null;
  // EdgeTX's background channel (the vario's, StickTime's motor sound): one tone that each call
  // retunes and keeps going for its duration; a call with duration 0 silences it
  function bgTone(freq, dur, vol) {
    const now = actx.currentTime;
    if (!motor) {
      const o = actx.createOscillator(), g = actx.createGain();
      o.type = 'triangle';
      o.frequency.value = Math.max(50, freq);
      g.gain.value = 0;
      o.connect(g).connect(actx.destination);
      o.start();
      motor = { o, g };
    }
    const g = motor.g.gain;
    g.cancelScheduledValues(now);
    g.setValueAtTime(g.value, now);
    if (dur <= 0) { g.setTargetAtTime(0, now, 0.008); return; }
    motor.o.frequency.setTargetAtTime(Math.max(50, freq), now, 0.012);
    g.setTargetAtTime([0.018, 0.006, 0.011, 0.018, 0.026, 0.034][vol] || 0.018, now, 0.01);
    g.setTargetAtTime(0, now + dur / 1000, 0.01);
  }
  function tone(freq, dur, pause, flags, incr, vol) {
    if (!(app.vol > 0) || !actx) return;
    if (flags & 0x20) { bgTone(freq, dur, vol); return; }        // PLAY_BACKGROUND
    const now = actx.currentTime;
    if (flags & 0x10) { live.forEach((o) => { try { o.stop(); } catch (e) { /* already stopped */ } }); live = []; toneEnd = now; }
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

  // Motor sound v3, synthesized in the browser (the radio itself can't do better than the
  // plain tone that was removed in 1.6.4). What makes a quad sound like a quad, per motor:
  //   - the blade-pass buzz: a custom periodic wave (fundamental + 5 harmonics, not a raw saw)
  //     through a lowpass that opens with rpm - dark at idle, raspy at speed
  //   - the shaft tone at rotation frequency (the low growl)
  //   - the electrical whine at 7x shaft speed (12N14P motors; the whoop's scream at 4-6.6 kHz)
  //   - a narrow noise band: air rush with speed, prop wash when sinking through dirty air
  // Each motor runs at its own rpm from a Quad-X stick mix (inputs are audible), has its own
  // timbre and sits left/right (heard from the camera: FL/FR wide, RR/RL narrow), and an
  // irregular ~2-7 Hz flutter (random-walk gain and detune, like turbulence over the discs)
  // replaces the steady drone. The master swells on spool-up and dips on chop, into a high
  // shelf and a compressor. Class rpm/timbre from each class's measured hover/full rpm.
  const ACLASS = [
    { rpm: 31679, blades: 3, poles: 7, buzz: 1.0, whine: 0.14, shaft: 0.1, noise: 0.45 },  // 5" racer
    { rpm: 31679, blades: 3, poles: 7, buzz: 0.9, whine: 0.16, shaft: 0.12, noise: 0.55 }, // 5" freestyle
    { rpm: 36301, blades: 3, poles: 7, buzz: 0.8, whine: 0.18, shaft: 0.1, noise: 0.65 },  // 3" toothpick
    { rpm: 56381, blades: 3, poles: 7, buzz: 0.4, whine: 0.4, shaft: 0.05, noise: 1.0 },   // 65 mm whoop
  ];
  const MIX = [[-1, 1, -1], [1, 1, 1], [1, -1, 1], [-1, -1, -1]];   // [roll, pitch, yaw] weight per motor
  const PAN = [-0.55, 0.55, -0.3, 0.3];                              // FL, FR, RR, RL as heard from the camera
  const TIMBRE = [[1, 1], [0.9, 0.85], [1.08, 1.12], [0.94, 0.88]];  // per-motor buzz / whine scale
  let synth = null;
  function startSynth() {
    const master = actx.createGain();
    master.gain.value = 0;
    const shelf = actx.createBiquadFilter();
    shelf.type = 'highshelf'; shelf.frequency.value = 3800; shelf.gain.value = -6;
    const comp = actx.createDynamicsCompressor();
    comp.threshold.value = -20; comp.knee.value = 18; comp.ratio.value = 5;
    comp.attack.value = 0.004; comp.release.value = 0.18;
    master.connect(shelf); shelf.connect(comp); comp.connect(actx.destination);
    const sum = actx.createGain();                                  // the flutter modulates this node
    sum.gain.value = 1;
    const shaper = actx.createWaveShaper();                         // soft saturation: warmth and grit
    const curve = new Float32Array(257);
    for (let i = 0; i < 257; i++) { const x = i / 128 - 1; curve[i] = Math.tanh(2.2 * x) / Math.tanh(2.2); }
    shaper.curve = curve; shaper.oversample = '2x';
    const drive = actx.createGain(); drive.gain.value = 1.6;        // into the shaper, then back off after
    const trim = actx.createGain(); trim.gain.value = 0.62;
    sum.connect(drive); drive.connect(shaper); shaper.connect(trim); trim.connect(master);
    const wave = actx.createPeriodicWave(new Float32Array(7), new Float32Array([0, 1, 0.6, 0.28, 0.14, 0.07, 0.03]));
    const buf = actx.createBuffer(1, actx.sampleRate * 2, actx.sampleRate);
    const ch = buf.getChannelData(0);
    for (let i = 0; i < ch.length; i++) ch[i] = Math.random() * 2 - 1;
    const motors = [];
    for (let m = 0; m < 4; m++) {
      let dest = sum;
      if (actx.createStereoPanner) {
        const p = actx.createStereoPanner();
        p.pan.value = PAN[m]; p.connect(sum); dest = p;
      }
      const lp = actx.createBiquadFilter();
      lp.type = 'lowpass'; lp.frequency.value = 1500; lp.Q.value = 0.8; lp.connect(dest);
      const buzz = actx.createOscillator(), bg = actx.createGain();
      buzz.setPeriodicWave(wave); buzz.frequency.value = 200; bg.gain.value = 0;
      buzz.connect(bg); bg.connect(lp); buzz.start();
      const buzz2 = actx.createOscillator(), b2g = actx.createGain();   // chorus: thickens the buzz
      buzz2.setPeriodicWave(wave); buzz2.frequency.value = 201.4; b2g.gain.value = 0;
      buzz2.connect(b2g); b2g.connect(lp); buzz2.start();
      const shaft = actx.createOscillator(), sg = actx.createGain();
      shaft.type = 'sine'; shaft.frequency.value = 70; sg.gain.value = 0;
      shaft.connect(sg); sg.connect(lp); shaft.start();
      const whine = actx.createOscillator(), wg = actx.createGain();
      whine.type = 'sine'; whine.frequency.value = 1400; wg.gain.value = 0;
      whine.connect(wg); wg.connect(dest); whine.start();
      const whine2 = actx.createOscillator(), w2g = actx.createGain();  // second, slightly sharp partial
      whine2.type = 'sine'; whine2.frequency.value = 2830; w2g.gain.value = 0;
      whine2.connect(w2g); w2g.connect(dest); whine2.start();
      const ns = actx.createBufferSource();
      ns.buffer = buf; ns.loop = true; ns.playbackRate.value = 0.9 + 0.05 * m;
      const bp = actx.createBiquadFilter();
      bp.type = 'bandpass'; bp.frequency.value = 600; bp.Q.value = 1.4;
      const ng = actx.createGain(); ng.gain.value = 0;
      ns.connect(bp); bp.connect(ng); ng.connect(dest); ns.start();
      motors.push({ buzz, bg, buzz2, b2g, shaft, sg, whine, wg, whine2, w2g, ns, bp, ng, lp });
    }
    // airflow: the wind rush over the frame grows with airspeed (its own voice, not the motors')
    const ws = actx.createBufferSource();
    ws.buffer = buf; ws.loop = true; ws.playbackRate.value = 0.8;
    const wf = actx.createBiquadFilter();
    wf.type = 'lowpass'; wf.frequency.value = 200; wf.Q.value = 0.5;
    const wgn = actx.createGain(); wgn.gain.value = 0;
    ws.connect(wf); wf.connect(wgn); wgn.connect(master); ws.start();
    synth = { master, sum, motors, buf, ws, wf, wgn, rpmS: [0, 0, 0, 0], prev: 0, state: 0,
              vol: 0, flT: 0, flG: 1, flD: [1, 1, 1, 1] };
  }
  function stopSynth() {
    if (!synth) return;
    const s = synth;
    synth = null;
    try {
      s.master.gain.setTargetAtTime(0, actx.currentTime, 0.04);
      setTimeout(() => {
        s.motors.forEach((m) => {
          try { m.buzz.stop(); m.buzz2.stop(); m.shaft.stop(); m.whine.stop(); m.whine2.stop(); m.ns.stop(); s.ws.stop(); } catch (e) { /* gone */ }
        });
      }, 300);
    } catch (e) { /* context closed */ }
  }
  function motorSound(dt) {
    if (!actx || !(app.vol > 0)) return;
    if (!synth) startSynth();
    const now = actx.currentTime;
    let a = null;
    if (app.engine && !app.engine.error) { try { a = app.engine.callTest('audio'); } catch (e) { /* hook absent */ } }
    const live = a && a.length >= 10;
    const c = live ? ACLASS[Math.max(1, Math.min(4, a[1] | 0)) - 1] : ACLASS[0];
    let on = 0, frac = 0, load = 0, speed = 0, chop = 0;
    if (live) {
      frac = Math.max(0, Math.min(1, a[3]));                  // lagged thrust / Tmax
      load = 0.35 * (a[4] - a[5]) - a[6] * 6;                 // PropLoad: dirty air is negative
      speed = Math.abs(a[4]) + a[5];                          // airspeed over the discs
      on = (a[2] === 4 && !app.paused) ? 1 : 0;               // motors live only while flying
      for (let i = 0; i < 4; i++) {
        const mix = MIX[i][0] * a[7] * 0.3 + MIX[i][1] * a[8] * 0.3 + MIX[i][2] * a[9] * 0.22;
        const tf = Math.max(0.008, Math.min(1.15, frac * (1 + mix)));
        const rpm = c.rpm * Math.max(0.1, Math.sqrt(tf)) * (1 - 0.15 * a[6]);  // wash loads the motors
        synth.rpmS[i] += 0.12 * (rpm - synth.rpmS[i]);        // rpm smoothing EMA (0.12/frame)
      }
    } else {
      for (let i = 0; i < 4; i++) synth.rpmS[i] *= 0.92;
    }
    // a crash: a short thud, and the motors cut with it
    if (live && synth.state === 4 && a[2] === 5) {
      const t = actx.currentTime;
      const bs = actx.createBufferSource();
      bs.buffer = synth.buf;
      const f = actx.createBiquadFilter();
      f.type = 'lowpass'; f.frequency.value = 420;
      const g = actx.createGain();
      g.gain.setValueAtTime(0.9, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.2);
      bs.connect(f); f.connect(g); g.connect(synth.master);
      bs.start(t); bs.stop(t + 0.22);
      for (let i = 0; i < 4; i++) synth.rpmS[i] *= 0.3;
    }
    if (live) synth.state = a[2];
    const mean = (synth.rpmS[0] + synth.rpmS[1] + synth.rpmS[2] + synth.rpmS[3]) / 4;
    const slope = Math.max(-0.5, Math.min(0.5, (synth.prev - mean) / 2000));
    synth.prev = mean;
    chop = Math.max(0, slope);
    const swell = Math.max(0.6, Math.min(1.4, 1 - slope));    // spool-up swells, chop dips
    synth.vol += (on * swell - synth.vol) * Math.min(1, dt / 90);
    synth.master.gain.setTargetAtTime(0.5 * app.vol * synth.vol, now, 0.06);
    // irregular flutter (random walk, new target every ~140 ms): gain +-13%, detune +-0.4%
    synth.flT -= dt;
    if (synth.flT <= 0) {
      synth.flT = 110 + Math.random() * 60;
      const rough = 0.13 + 0.22 * (1 - Math.min(1, mean / c.rpm));   // lumpy idle
      synth.flG = 1 + (Math.random() - 0.5) * 2 * rough;
      for (let i = 0; i < 4; i++) synth.flD[i] = 1 + (Math.random() - 0.5) * 0.008;
      synth.sum.gain.setTargetAtTime(synth.flG, now, 0.05);
    }
    const nAmt = c.noise * Math.max(0.08, Math.min(1.3, 0.2 + 0.5 * frac - Math.min(0, load) * 0.05
      + speed * 0.02 + chop * 0.6));
    for (let i = 0; i < 4; i++) {
      const m = synth.motors[i];
      const mech = synth.rpmS[i] / 60;
      const bpf = mech * c.blades * synth.flD[i];
      const rf = Math.min(1, synth.rpmS[i] / c.rpm);
      m.buzz.frequency.setTargetAtTime(Math.max(30, bpf), now, 0.02);
      m.buzz2.frequency.setTargetAtTime(Math.max(30, bpf * 1.0068), now, 0.02);
      m.shaft.frequency.setTargetAtTime(Math.max(20, mech), now, 0.02);
      const elec = mech * c.poles * (1 + (synth.flD[i] - 1) * 2);
      m.whine.frequency.setTargetAtTime(Math.min(11000, elec), now, 0.03);
      m.whine2.frequency.setTargetAtTime(Math.min(14000, elec * 2.02), now, 0.03);
      m.lp.frequency.setTargetAtTime(Math.min(9500, 250 + bpf * 2.2), now, 0.05);
      m.bp.frequency.setTargetAtTime(Math.min(9000, 300 + bpf * 1.5 + speed * 8), now, 0.05);
      m.bg.gain.setTargetAtTime(on * c.buzz * TIMBRE[i][0] * (0.12 + 0.3 * rf), now, 0.04);
      m.b2g.gain.setTargetAtTime(on * c.buzz * TIMBRE[i][0] * 0.55 * (0.12 + 0.3 * rf), now, 0.04);
      m.sg.gain.setTargetAtTime(on * c.shaft * (0.1 + 0.9 * rf), now, 0.04);
      const loadW = 1 + 0.3 * Math.max(0, Math.min(1, load / 6));      // a loaded motor whines louder
      m.wg.gain.setTargetAtTime(on * c.whine * TIMBRE[i][1] * (0.2 + 0.8 * rf) * loadW, now, 0.04);
      m.w2g.gain.setTargetAtTime(on * c.whine * TIMBRE[i][1] * 0.3 * (0.2 + 0.8 * rf), now, 0.04);
      m.ng.gain.setTargetAtTime(on * 0.1 * nAmt * TIMBRE[i][0], now, 0.07);
    }
    // the wind rush: quiet to 15 m/s, loud by 30, brighter with speed
    synth.wgn.gain.setTargetAtTime(on * Math.min(0.3, (speed / 28) * (speed / 28)) * 0.9, now, 0.1);
    synth.wf.frequency.setTargetAtTime(Math.min(4000, 180 + speed * 36), now, 0.1);
  }

  // ----------------------------------------------------------- engine
  function scriptFor() {
    if (app.custom) return { text: app.custom.text, name: app.custom.name };
    const kind = app.script === 'auto' ? (app.radio.color ? 'color' : 'bw') : app.script;
    const dir = kind === 'lite' ? 'StickTimeLite/' : 'StickTimeBW/';
    // on a color screen the B&W loader runs <dir>color.lua, which loads <dir>core.lua
    if (kind !== 'color' && app.radio.color) return { text: LUA[kind + 'color'], name: dir + 'color.lua' };
    return { text: LUA[kind], name: kind === 'color' ? 'StickTime.lua' : dir + 'core.lua' };
  }

  function boot() {
    const r = app.radio;
    const eng = new Engine(fengari, r, {
      colorFonts, bwFonts: BW_FONTS, sd: app.sd,
      files: Object.assign({ '/SCRIPTS/TOOLS/StickTimeBW/core.lua': LUA.bw, '/SCRIPTS/TOOLS/StickTimeLite/core.lua': LUA.lite }, LITE_TRACKS),
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
    const globals = { STICKTIME_TEST: 'table' };
    if (r.color && !eng.displayDelay) globals.STICKTIME_LAT = 0;   // nothing to predict when frames show at once
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
    canvas.classList.toggle('bw', !r.color);             // B&W pixels stay sharp in fullscreen too
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
  // Every connected gamepad is listed. The chosen one is remembered by its slot and name
  // (by name alone when it comes back in another slot); with none chosen, the first one
  // with four axes is used.
  let padBlocked = false, padSig = '', padShown = '';
  const padKey = (g) => g.index + ':' + g.id;
  function readPad() {
    let pads = [];
    try { pads = navigator.getGamepads ? Array.from(navigator.getGamepads()) : []; padBlocked = false; } catch (e) { padBlocked = true; }
    pads = pads.filter((g) => g && g.connected);
    const name = app.padKey.slice(app.padKey.indexOf(':') + 1);
    const p = pads.find((g) => padKey(g) === app.padKey) || (name && pads.find((g) => g.id === name))
      || pads.find((g) => g.axes.length >= 4) || pads[0] || null;
    listPads(pads, p);
    return p;
  }
  function listPads(pads, p) {
    const sig = pads.map(padKey).join('|');
    const sel = $('padSel');
    if (sig !== padSig) {
      padSig = sig;
      sel.textContent = '';
      for (const g of pads) {
        const o = document.createElement('option');
        o.value = padKey(g);
        // the name without the USB ids (Chrome: "Name (Vendor: … Product: …)", Firefox: "vvvv-pppp-Name")
        const name = g.id.replace(/\s*\((?:STANDARD GAMEPAD\s*)?Vendor:[^)]*\)\s*$/i, '').replace(/^[0-9a-f]{4}-[0-9a-f]{4}-/i, '');
        o.textContent = (g.index + 1) + ': ' + (name || g.id).slice(0, 40) + ' (' + g.axes.length + ' axes)';
        sel.appendChild(o);
      }
      $('padPick').hidden = pads.length === 0;
      padShown = '';
    }
    const k = p ? padKey(p) : '';
    if (k !== padShown) {
      padShown = k;
      if (p) sel.value = k;
      // as many axes to map as the chosen gamepad has (at least 8)
      const n = Math.max(8, p ? p.axes.length : 0);
      for (const s of document.querySelectorAll('.axis select')) {
        while (s.options.length < n) { const o = document.createElement('option'); o.value = s.options.length; o.textContent = 'axis ' + s.options.length; s.appendChild(o); }
      }
    }
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
    else { st.textContent = 'Move a stick: the bars below follow the chosen gamepad.'; st.className = 'note'; }
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
    motorSound(dt);
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
    // the screens by kind: StickTime runs on color screens (the PC screen too); StickTime BW
    // and StickTime Lite are made for black & white ones and also run on color screens
    for (const [label, color] of [['Color screens', true], ['Black & white screens', false]]) {
      const g = document.createElement('optgroup');
      g.label = label;
      for (const r of RADIOS.filter((x) => x.color === color)) {
        const o = document.createElement('option');
        o.value = r.id; o.textContent = r.label;
        g.appendChild(o);
      }
      rs.appendChild(g);
    }
    const ss = $('scriptSel');
    // StickTime.lua only runs on color screens: picking it with a B&W screen moves to the last
    // color screen, and picking a B&W screen while it is selected switches the script to Auto
    // (the one made for that screen). StickTime BW and Lite run on any screen.
    const COLOR_SCRIPT = { color: true };
    const last = { true: store.get('lastColor', 'tx16s'), false: store.get('lastBW', 'tx12') };
    const setRadio = (id) => {
      app.radio = RADIOS.find((r) => r.id === id) || app.radio;
      rs.value = app.radio.id;
      store.set('radio', app.radio.id);
      last[app.radio.color] = app.radio.id;
      store.set(app.radio.color ? 'lastColor' : 'lastBW', app.radio.id);
    };
    const setScript = (id) => { app.script = id; ss.value = id; store.set('script', id); };
    const fit = (by) => {
      const color = COLOR_SCRIPT[app.script];
      if (!app.custom && color !== undefined && color !== app.radio.color) {
        if (by === 'radio') setScript('auto'); else setRadio(last[color]);
      }
      // the Lite on a B&W screen: an STM32F2 radio; on a color screen, that radio's own CPU
      app.cpu = app.script === 'lite' && !app.radio.color ? 'F2' : null;
    };
    setRadio(app.radio.id);
    setScript(app.script);
    fit('script');
    rs.addEventListener('change', () => {
      setRadio(rs.value);
      fit('radio');
      boot();
    });
    ss.addEventListener('change', () => {
      if (ss.value === 'custom') return;
      app.custom = null;
      setScript(ss.value);
      fit('script');
      boot();
    });
    $('restartBtn').addEventListener('click', boot);
    $('ovBtn').addEventListener('click', boot);
    // one control: the slider is the switch too (0 = off); moving it is the user gesture
    // the browser needs before audio may start
    const vol = $('soundVol');
    const volLbl = vol.parentElement;
    const volShow = () => {
      volLbl.classList.toggle('snd-off', !(app.vol > 0));
      volLbl.title = app.vol > 0 ? 'Sound volume: ' + Math.round(app.vol * 100) + '%' : 'Sound off';
    };
    vol.value = app.vol;
    volShow();
    vol.addEventListener('input', () => {
      app.vol = parseFloat(vol.value) || 0;
      store.set('vol', app.vol);
      volShow();
      if (app.vol > 0 && !actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { app.vol = 0; vol.value = 0; volShow(); } }
      if (actx && actx.state === 'suspended') actx.resume();
      if (app.vol <= 0) { if (motor && actx) bgTone(0, 0, 0); stopSynth(); }
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
    $('padSel').addEventListener('change', () => { app.padKey = $('padSel').value; store.set('padKey', app.padKey); });
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
      if (e && !app.radio.pc) { e.displayDelay = app.delay; e.setGlobal('STICKTIME_LAT', app.delay ? null : 0); }
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
