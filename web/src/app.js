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
    // true when it was kept (false: storage blocked or full)
    set(k, v) { try { localStorage.setItem('fpvsim.' + k, JSON.stringify(v)); return true; } catch (e) { return false; } },
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
    lastVol: store.get('lastVol', 0.8),            // what unmuting goes back to
    musicOn: store.get('musicOn', false),
    musicVol: store.get('musicVol', 0.6),
    mode: store.get('mode', 2),
    input: store.get('input', 'mix') === 'pad' ? 'pad' : 'mix',
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
  let actx = null, toneEnd = 0, live = [], motor = null, outGain = null;
  // every sound goes through one gain, set from the slider on a loudness curve (ears hear power
  // logarithmically: half way is about -12 dB) and eased, so beeps and motors follow it alike
  const volGain = (v) => v * v;
  function audioOut() {
    if (!outGain) {
      outGain = actx.createGain();
      outGain.gain.value = volGain(app.vol);
      outGain.connect(actx.destination);
    }
    return outGain;
  }
  // EdgeTX's background channel (the vario's, StickTime's motor sound): one tone that each call
  // retunes and keeps going for its duration; a call with duration 0 silences it
  function bgTone(freq, dur, vol) {
    const now = actx.currentTime;
    if (!motor) {
      const o = actx.createOscillator(), g = actx.createGain();
      o.type = 'triangle';
      o.frequency.value = Math.max(50, freq);
      g.gain.value = 0;
      o.connect(g).connect(audioOut());
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
    o.connect(g).connect(audioOut());
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

  // Motor sound v4, synthesized in the browser (the radio itself can't do better than the
  // plain tone that was removed in 1.6.4). Tuned against recordings of real quads, measured the
  // same way (tone vs noise share, harmonic levels, amplitude wobble, pitch wander). Per motor:
  //   - the blade-pass tone: nearly a pure tone (2nd harmonic ~15 dB down, the rest far below;
  //     the whoop's is much buzzier), through a lowpass that opens with rpm
  //   - the shaft tone at rotation frequency, and the props' imbalance wobbling the level at it
  //   - the electrical whine at 7x shaft speed (12N14P motors; the whoop's scream at 4-6.6 kHz)
  //   - air noise, a whoosh up to ~2x blade pass (a tenth to a fifth of the sound; no hiss)
  //   - a slow pitch wander (~25 cents) and, in prop wash, the rpm chatter of a real quad's
  //     motors fighting it (a few % at the class's wash frequency, from blackbox logs), plus
  //     the dark, fluttering rumble of dirty air the recordings have when descending
  // Each motor runs at its own rpm from a Quad-X stick mix (inputs are audible), has its own
  // timbre and sits left/right (heard from the camera: FL/FR wide, RR/RL narrow); together they
  // beat and flutter like four real props. The master swells on spool-up and dips on chop, into
  // gentle saturation, a high shelf and a compressor. Class rpm from each class's hover/full rpm.
  const ACLASS = [
    { rpm: 31679, blades: 3, poles: 7, buzz: 1.0, whine: 0.14, shaft: 0.1, noise: 0.45, wave: 0 },  // 5" racer
    { rpm: 31679, blades: 3, poles: 7, buzz: 0.9, whine: 0.16, shaft: 0.12, noise: 0.5, wave: 0 },  // 5" freestyle
    { rpm: 36301, blades: 3, poles: 7, buzz: 0.8, whine: 0.18, shaft: 0.1, noise: 0.5, wave: 0 },   // 3" toothpick
    { rpm: 56381, blades: 3, poles: 7, buzz: 0.4, whine: 0.4, shaft: 0.05, noise: 0.4, wave: 1 },   // 65 mm whoop
    { rpm: 46605, blades: 4, poles: 7, buzz: 0.5, whine: 0.32, shaft: 0.06, noise: 0.4, wave: 1 },  // 75 mm whoop (2S)
  ];
  // blade-pass harmonics: a prop's tone, and the whoop's buzz (from the recordings' spectra)
  const WAVES = [[0, 1, 0.2, 0.08, 0.06, 0.04, 0.02], [0, 1, 0.8, 0.6, 0.35, 0.3, 0.15]];
  const MIX = [[-1, 1, -1], [1, 1, 1], [1, -1, 1], [-1, -1, -1]];   // [roll, pitch, yaw] weight per motor
  const PAN = [-0.55, 0.55, -0.3, 0.3];                              // FL, FR, RR, RL as heard from the camera
  const TIMBRE = [[1, 1], [0.9, 0.85], [1.08, 1.12], [0.94, 0.88]];  // per-motor buzz / whine scale
  const CENTS = 1731;                                                // cents per unit of rpm fraction
  // a seamless looping modulator: random sines on an 8 s grid with a smooth band shape, rms 1
  // (at 8 kHz, made by the two-term sine recurrence: fast to build)
  function modBuffer(lo, hi, centre) {
    const sr = 8000, n = sr * 8, buf = actx.createBuffer(1, n, sr), d = buf.getChannelData(0);
    for (let k = Math.ceil(lo * 8); k <= hi * 8; k++) {
      const f = k / 8, a = centre ? Math.exp(-0.5 * ((f - centre) / (centre / 6)) ** 2) : 1 / Math.sqrt(f);
      const ph = Math.random() * 2 * Math.PI, w = 2 * Math.PI * f / sr, c2 = 2 * Math.cos(w);
      let y1 = a * Math.sin(ph - w), y2 = a * Math.sin(ph - 2 * w);
      for (let i = 0; i < n; i++) { const y = c2 * y1 - y2; d[i] += y; y2 = y1; y1 = y; }
    }
    let s = 0;
    for (let i = 0; i < n; i++) s += d[i] * d[i];
    const g = 1 / Math.sqrt(s / n);
    for (let i = 0; i < n; i++) d[i] *= g;
    return buf;
  }
  function loopSrc(buf, rate, all) {
    const s = actx.createBufferSource();
    s.buffer = buf; s.loop = true; s.playbackRate.value = rate; s.start();
    all.push(s);
    return s;
  }
  const gainNode = (v) => { const g = actx.createGain(); g.gain.value = v; return g; };
  let synth = null;
  function startSynth() {
    const srcs = [], loop = (b, r) => loopSrc(b, r, srcs);         // every source, to stop them all
    const master = gainNode(0);
    const shelf = actx.createBiquadFilter();
    shelf.type = 'highshelf'; shelf.frequency.value = 3800; shelf.gain.value = -6;
    const comp = actx.createDynamicsCompressor();
    comp.threshold.value = -20; comp.knee.value = 18; comp.ratio.value = 5;
    comp.attack.value = 0.004; comp.release.value = 0.18;
    master.connect(shelf); shelf.connect(comp); comp.connect(audioOut());
    const sum = gainNode(1);                                        // the flutter modulates this node
    const shaper = actx.createWaveShaper();                         // gentle saturation: warmth
    const curve = new Float32Array(257);
    for (let i = 0; i < 257; i++) { const x = i / 128 - 1; curve[i] = Math.tanh(1.2 * x) / Math.tanh(1.2); }
    shaper.curve = curve; shaper.oversample = '2x';
    const drive = gainNode(1);
    sum.connect(drive); drive.connect(shaper); shaper.connect(gainNode(0.62)).connect(master);
    const waves = WAVES.map((w) => actx.createPeriodicWave(new Float32Array(w.length), new Float32Array(w)));
    const buf = actx.createBuffer(1, actx.sampleRate * 2, actx.sampleRate);
    const ch = buf.getChannelData(0);
    for (let i = 0; i < ch.length; i++) ch[i] = Math.random() * 2 - 1;
    // modulators: slow wander/flutter (0.5-6 Hz) and the prop wash chatter (around 30 Hz,
    // retuned to the class's wash frequency by playback rate), one per roll / pitch axis
    const slow = modBuffer(0.5, 6), chat = [modBuffer(15, 60, 30), modBuffer(15, 60, 30)];
    const chatSrc = chat.map((b) => loop(b, 1));
    const chatAm = chatSrc.map((s) => { const g = gainNode(0); s.connect(g); return g; });  // per axis, x depth
    const chatFm = chatSrc.map((s) => { const g = gainNode(0); s.connect(g); return g; });
    const flut = gainNode(0);
    loop(slow, 1).connect(flut); flut.connect(sum.gain);
    const motors = [];
    for (let m = 0; m < 4; m++) {
      let dest = sum;
      if (actx.createStereoPanner) {
        const p = actx.createStereoPanner();
        p.pan.value = PAN[m]; p.connect(sum); dest = p;
      }
      const amp = gainNode(1);                                      // level wobble: imbalance, chatter
      amp.connect(dest);
      const lp = actx.createBiquadFilter();
      lp.type = 'lowpass'; lp.frequency.value = 1500; lp.Q.value = 0.8; lp.connect(amp);
      const buzz = actx.createOscillator(), bg = gainNode(0);
      srcs.push(buzz);
      buzz.setPeriodicWave(waves[0]); buzz.frequency.value = 200;
      buzz.connect(bg); bg.connect(lp); buzz.start();
      const buzz2 = actx.createOscillator(), b2g = gainNode(0);   // chorus: thickens the tone
      srcs.push(buzz2);
      buzz2.setPeriodicWave(waves[0]); buzz2.frequency.value = 201.4;
      buzz2.connect(b2g); b2g.connect(lp); buzz2.start();
      const shaft = actx.createOscillator(), sg = gainNode(0);
      srcs.push(shaft);
      shaft.type = 'sine'; shaft.frequency.value = 70;
      shaft.connect(sg); sg.connect(lp); shaft.start();
      shaft.connect(gainNode(0.12)).connect(amp.gain);             // the imbalance wobble
      const whine = actx.createOscillator(), wg = gainNode(0);
      srcs.push(whine);
      whine.type = 'sine'; whine.frequency.value = 1400;
      whine.connect(wg); wg.connect(amp); whine.start();
      const whine2 = actx.createOscillator(), w2g = gainNode(0);  // second, slightly sharp partial
      srcs.push(whine2);
      whine2.type = 'sine'; whine2.frequency.value = 2830;
      whine2.connect(w2g); w2g.connect(amp); whine2.start();
      const ns = loop(buf, 0.9 + 0.05 * m);                      // broadband air noise
      const nlp = actx.createBiquadFilter(), nhp = actx.createBiquadFilter();
      nlp.type = 'lowpass'; nlp.Q.value = 0; nhp.type = 'highpass'; nhp.Q.value = 0;
      const ng = gainNode(0);
      ns.connect(nlp); nlp.connect(nhp); nhp.connect(ng); ng.connect(amp);
      // pitch: this motor's own slow wander, plus the chatter of the axes it sits on
      const wand = gainNode(0);
      loop(slow, 0.8 + 0.17 * m).connect(wand);
      const det = [buzz, buzz2, shaft, whine, whine2].map((o) => o.detune);
      det.forEach((d) => wand.connect(d));
      for (let ax = 0; ax < 2; ax++) {
        const sAm = gainNode(MIX[m][ax] / Math.SQRT2), sFm = gainNode(MIX[m][ax] / Math.SQRT2);
        chatAm[ax].connect(sAm); sAm.connect(amp.gain);
        chatFm[ax].connect(sFm); det.forEach((d) => sFm.connect(d));
      }
      motors.push({ buzz, bg, buzz2, b2g, shaft, sg, whine, wg, whine2, w2g, ns, nlp, nhp, ng, lp, wand });
    }
    // dirty air: a dark rumble that flutters, when descending into the wash
    const dv = loop(buf, 0.71);
    const dvf = actx.createBiquadFilter();
    dvf.type = 'lowpass'; dvf.frequency.value = 400; dvf.Q.value = 0;
    const dvg = gainNode(0), dvam = gainNode(1);
    dv.connect(dvf); dvf.connect(dvg); dvg.connect(dvam); dvam.connect(drive);
    const dvFl = gainNode(0.6);
    loop(slow, 3.3).connect(dvFl); dvFl.connect(dvam.gain);
    const dvCh = gainNode(0);
    chatSrc[0].connect(dvCh); dvCh.connect(dvam.gain);
    // airflow: the wind rush over the frame grows with airspeed (its own voice, not the motors')
    const ws = loop(buf, 0.8);
    const wf = actx.createBiquadFilter();
    wf.type = 'lowpass'; wf.frequency.value = 200; wf.Q.value = 0.5;
    const wgn = gainNode(0);
    ws.connect(wf); wf.connect(wgn); wgn.connect(master);
    synth = { master, sum, motors, buf, waves, wave: 0, chatSrc, chatAm, chatFm, flut, dvf, dvg, dvCh, wf, wgn,
              rpmS: [0, 0, 0, 0], prev: 0, state: 0, hits: -1, vol: 0, dirty: 0, stop: srcs };
  }
  function stopSynth() {
    if (!synth) return;
    const s = synth;
    synth = null;
    try {
      s.master.gain.setTargetAtTime(0, actx.currentTime, 0.04);
      setTimeout(() => {
        s.stop.forEach((o) => { try { o.stop(); } catch (e) { /* gone */ } });
        try { s.master.disconnect(); } catch (e) { /* gone */ }
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
    const c = live ? ACLASS[Math.max(1, Math.min(ACLASS.length, a[1] | 0)) - 1] : ACLASS[0];
    if (c.wave !== synth.wave) {
      synth.wave = c.wave;
      synth.motors.forEach((m) => { m.buzz.setPeriodicWave(synth.waves[c.wave]); m.buzz2.setPeriodicWave(synth.waves[c.wave]); });
    }
    let on = 0, frac = 0, speed = 0, chop = 0, dirty = 0, shake = 0, pf = 26;
    if (live) {
      frac = Math.max(0, Math.min(1, a[3]));                  // lagged thrust / Tmax
      speed = Math.abs(a[4]) + a[5];                          // airspeed over the discs
      on = (a[2] === 4 && !app.paused) ? 1 : 0;               // motors live only while flying
      // dirty air: sinking down the prop axis, cleared by edgewise speed; stronger with the prop
      // wash setting on (its build-up), and the shake's rms (deg) drives the motors' chatter
      dirty = Math.max(0, Math.min(1, (-a[4] - 0.5) / 3)) * Math.max(0, 1 - a[5] / 6) * (0.5 + 0.5 * a[6]);
      shake = a.length >= 12 ? Math.max(0, a[10]) : 0;
      pf = a.length >= 12 && a[11] > 0 ? a[11] : 26;
      for (let i = 0; i < 4; i++) {
        const mix = MIX[i][0] * a[7] * 0.3 + MIX[i][1] * a[8] * 0.3 + MIX[i][2] * a[9] * 0.22;
        const tf = Math.max(0.008, Math.min(1.15, frac * (1 + mix)));
        const rpm = c.rpm * Math.max(0.1, Math.sqrt(tf)) * (1 - 0.06 * dirty);  // dirty air loads them
        synth.rpmS[i] += 0.12 * (rpm - synth.rpmS[i]);        // rpm smoothing EMA (0.12/frame)
      }
    } else {
      for (let i = 0; i < 4; i++) synth.rpmS[i] *= 0.92;
    }
    synth.dirty += (dirty - synth.dirty) * Math.min(1, dt / 120);
    // a crash: a short thud, and the motors cut with it; a hit (the quad flies on) thuds as hard
    // as it hit, its props struck
    const hits = live && a.length >= 14 ? a[12] : -1;
    const hit = hits > synth.hits && synth.hits >= 0 ? Math.min(1, 0.3 + a[13] / 12) : 0;
    if (live) synth.hits = hits;
    if (live && ((synth.state === 4 && a[2] === 5) || hit > 0)) {
      const t = actx.currentTime;
      const bs = actx.createBufferSource();
      bs.buffer = synth.buf;
      const f = actx.createBiquadFilter();
      f.type = 'lowpass'; f.frequency.value = 420;
      const g = actx.createGain();
      g.gain.setValueAtTime(hit > 0 ? 0.9 * hit : 0.9, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.2);
      bs.connect(f); f.connect(g); g.connect(synth.master);
      bs.start(t); bs.stop(t + 0.22);
      for (let i = 0; i < 4; i++) synth.rpmS[i] *= hit > 0 ? 1 - 0.5 * hit : 0.3;
    }
    if (live) synth.state = a[2];
    const mean = (synth.rpmS[0] + synth.rpmS[1] + synth.rpmS[2] + synth.rpmS[3]) / 4;
    const slope = Math.max(-0.5, Math.min(0.5, (synth.prev - mean) / 2000));
    synth.prev = mean;
    chop = Math.max(0, slope);
    const swell = Math.max(0.6, Math.min(1.4, 1 - slope));    // spool-up swells, chop dips
    synth.vol += (on * swell - synth.vol) * Math.min(1, dt / 90);
    synth.master.gain.setTargetAtTime(0.5 * synth.vol, now, 0.06);
    const dw = synth.dirty;
    const rough = 1 + 0.8 * (1 - Math.min(1, mean / c.rpm));             // lumpy idle
    synth.flut.gain.setTargetAtTime(0.09 * rough * (1 + 1.6 * dw), now, 0.1);
    // the chatter: rpm a few % at the wash frequency (~2.3% rms at 0.19 deg of shake), level 2.5x
    const rpmCh = Math.min(0.12, 0.12 * shake);
    for (let ax = 0; ax < 2; ax++) {
      synth.chatSrc[ax].playbackRate.setTargetAtTime(pf / 30, now, 0.1);
      synth.chatFm[ax].gain.setTargetAtTime(on * CENTS * rpmCh, now, 0.05);
      synth.chatAm[ax].gain.setTargetAtTime(on * 2.5 * rpmCh, now, 0.05);
    }
    const nAmt = c.noise * Math.max(0.08, Math.min(1.6, 0.2 + 0.3 * frac + 0.1 * dw + speed * 0.004 + chop * 0.6));
    for (let i = 0; i < 4; i++) {
      const m = synth.motors[i];
      const mech = synth.rpmS[i] / 60;
      const bpf = mech * c.blades;
      const rf = Math.min(1, synth.rpmS[i] / c.rpm);
      m.buzz.frequency.setTargetAtTime(Math.max(30, bpf), now, 0.02);
      m.buzz2.frequency.setTargetAtTime(Math.max(30, bpf * 1.0068), now, 0.02);
      m.shaft.frequency.setTargetAtTime(Math.max(20, mech), now, 0.02);
      m.whine.frequency.setTargetAtTime(Math.min(11000, mech * c.poles), now, 0.03);
      m.whine2.frequency.setTargetAtTime(Math.min(14000, mech * c.poles * 2.02), now, 0.03);
      m.wand.gain.setTargetAtTime(CENTS * 0.002 * (1 + 3 * dw), now, 0.1);    // 3.5 cents, 14 in dirty air
      m.lp.frequency.setTargetAtTime(Math.min(12000, 250 + bpf * 3), now, 0.05);
      m.nlp.frequency.setTargetAtTime(Math.min(3000, 300 + bpf * 2.2), now, 0.05);
      m.nhp.frequency.setTargetAtTime(Math.max(40, bpf * 0.3), now, 0.05);
      m.bg.gain.setTargetAtTime(on * c.buzz * TIMBRE[i][0] * (0.12 + 0.3 * rf), now, 0.04);
      m.b2g.gain.setTargetAtTime(on * c.buzz * TIMBRE[i][0] * 0.55 * (0.12 + 0.3 * rf), now, 0.04);
      m.sg.gain.setTargetAtTime(on * c.shaft * (0.1 + 0.9 * rf), now, 0.04);
      m.wg.gain.setTargetAtTime(on * c.whine * TIMBRE[i][1] * (0.2 + 0.8 * rf), now, 0.04);
      m.w2g.gain.setTargetAtTime(on * c.whine * TIMBRE[i][1] * 0.3 * (0.2 + 0.8 * rf), now, 0.04);
      m.ng.gain.setTargetAtTime(on * 2.5 * nAmt * TIMBRE[i][0], now, 0.07);
    }
    // the dirty-air rumble: below the blade pass, louder the dirtier, fluttering with the chatter
    const dvc = 120 + 0.4 * mean / 60 * c.blades;
    synth.dvf.frequency.setTargetAtTime(dvc, now, 0.1);
    const dvn = Math.sqrt(1.11 * dvc / (1.5 * actx.sampleRate));           // that noise's rms
    synth.dvg.gain.setTargetAtTime(on * 0.1 * dw * (0.5 + frac) / dvn, now, 0.08);
    synth.dvCh.gain.setTargetAtTime(Math.min(0.8, 2 * shake), now, 0.05);
    // the wind rush: a dark whoosh under the motors, from ~15 m/s, never hissing
    synth.wgn.gain.setTargetAtTime(on * Math.min(0.1, 0.1 * (speed / 35) * (speed / 35)), now, 0.1);
    synth.wf.frequency.setTargetAtTime(Math.min(900, 150 + speed * 15), now, 0.1);
  }

  // ------------------------------------------------------------- music
  // Built-in music, generated live (free by construction: nothing to license or download), in
  // the spirit of FPV edits: melodic electronic tracks. Each song (~2.5 min) picks a minor key, a tempo, a progression of seventh chords voiced with smooth voice leading,
  // a bass groove, an arpeggio and a hook: a two-bar motif developed over eight bars (A A' B A''),
  // landing on chord tones. Arranged like a real track: a pad and a muffled kick swell in through
  // an opening filter, the groove, a build with a riser and snare roll, the drop with the hook,
  // a breakdown, a second drop, an outro that closes the filter; then the next song. Or the
  // player's own files (Songs...). Music has its own on/off and level, apart from Sound.
  const MUSIC = { bus: null, gen: null, el: null, src: null, files: [], idx: 0 };
  const midiHz = (m) => 440 * Math.pow(2, (m - 69) / 12);
  const pick = (a) => a[Math.floor(Math.random() * a.length)];
  const AEOLIAN = [0, 2, 3, 5, 7, 8, 10];
  // progressions as scale degrees (0 = i, 2 = III, 3 = iv, 4 = v, 5 = VI, 6 = VII)
  const PROGS = [[0, 5, 2, 6], [0, 6, 5, 6], [5, 6, 0, 0], [0, 3, 5, 4], [0, 5, 3, 4], [5, 3, 0, 6], [3, 5, 0, 6],
                 [0, 2, 6, 5]];
  const BASSES = [
    [1, 0, 1, 0, 1, 0, 2, 0, 1, 0, 1, 0, 1, 0, 2, 0],    // driving eighths, octave jumps
    [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1],    // offbeat
    [1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 2, 0],    // rolling
  ];
  const ARPS = [[0, 1, 2, 3, 1, 2, 3, 4, 2, 3, 4, 5, 3, 2, 1, 2], [0, 2, 1, 3, 2, 4, 3, 5, 4, 3, 2, 4, 1, 3, 0, 2],
                [0, 1, 2, 1, 3, 2, 4, 3, 5, 4, 3, 2, 4, 3, 2, 1]];
  // two-bar hook rhythms: [step, length] in sixteenths
  const RHY = [
    [[0, 3], [3, 3], [6, 2], [8, 4], [12, 2], [14, 2], [16, 3], [19, 3], [22, 2], [24, 8]],
    [[0, 2], [2, 2], [4, 4], [10, 2], [12, 4], [16, 2], [18, 2], [20, 4], [26, 6]],
    [[2, 2], [4, 2], [6, 4], [12, 2], [14, 2], [16, 6], [24, 2], [26, 2], [28, 4]],
    [[0, 6], [6, 6], [12, 4], [16, 3], [19, 3], [22, 2], [24, 8]],
    [[0, 3], [3, 3], [6, 4], [10, 2], [12, 4], [16, 3], [19, 3], [22, 4], [28, 4]],
  ];
  // the arrangement: bars, then what plays (k kick, c clap, h hats 1/2, b bass, p pad, a arp,
  // l lead, r riser, x crash + impact at the start) and the filter (in, out, build)
  const FORM = [
    { n: 8, k: 1, h: 1, p: 1, f: 'in', hFrom: 4 },
    { n: 8, k: 1, c: 1, h: 1, b: 1, p: 1, a: 1, x: 1 },
    { n: 8, k: 1, c: 1, h: 2, b: 1, p: 1, a: 1, r: 1, kickStop: 1 },
    { n: 16, k: 1, c: 1, h: 2, b: 1, p: 1, a: 1, l: 1, x: 2 },
    { n: 8, p: 1, a: 1, l: 1, f: 'build', r: 1, soft: 1 },
    { n: 16, k: 1, c: 1, h: 2, b: 1, p: 1, a: 1, l: 1, x: 2 },
    { n: 8, k: 1, h: 1, b: 1, p: 1, f: 'out' },
  ];
  const BARS = FORM.reduce((n, f) => n + f.n, 0);
  function musicBus() {
    if (!MUSIC.bus) {
      MUSIC.bus = actx.createGain();
      MUSIC.bus.gain.value = 0.6 * volGain(app.musicVol);
      const comp = actx.createDynamicsCompressor();
      comp.threshold.value = -16; comp.knee.value = 10; comp.ratio.value = 3; comp.attack.value = 0.01; comp.release.value = 0.2;
      MUSIC.bus.connect(comp); comp.connect(actx.destination);
    }
    return MUSIC.bus;
  }
  // ---- the song: harmony, voicings, hook
  function newSong(prev) {
    const tonic = prev ? (prev.tonic + pick([5, 7, 3, 9])) % 12 : Math.floor(Math.random() * 12);
    const scale = AEOLIAN;
    const prog = pick(PROGS);
    const deg = (d, i) => { const k = d + i; return scale[((k % 7) + 7) % 7] + 12 * Math.floor(k / 7); };
    // each chord: its scale degree and the root, 3rd, 5th, 7th, 9th above the tonic (in semitones)
    const chords = prog.map((d) => ({ d, t: [0, 2, 4, 6, 8].map((i) => deg(d, i)) }));
    // pads: 4 voices (3rd, 5th, 7th, 9th or root) placed nearest to the previous chord's voices
    let prevV = [57, 60, 64, 67];
    chords.forEach((c) => {
      const pcs = [c.t[1], c.t[2], c.t[3], Math.random() < 0.5 ? c.t[4] : c.t[0]];
      c.v = pcs.map((pc, i) => {
        let best = 0, bd = 99;
        for (let o = 3; o <= 6; o++) {
          const m = 12 * o + ((tonic + pc) % 12 + 12) % 12;
          if (m >= 52 && m <= 76 && Math.abs(m - prevV[i]) < bd) { bd = Math.abs(m - prevV[i]); best = m; }
        }
        return best;
      }).sort((a, b) => a - b);
      prevV = c.v;
      c.bass = 36 + ((tonic + c.t[0]) % 12 + 12) % 12;       // C2..B2
    });
    // the hook, in scale steps around the tonic (index 0 = tonic, D4..C#5)
    const leadBase = 62 + (((tonic - 62) % 12) + 12) % 12;      // the tonic between D4 and C#5
    const tones = (c) => [c.d, c.d + 2, c.d + 4];             // chord tones as scale indices
    const nearest = (x, c, set) => {
      let best = x, bd = 99;
      for (const s of set.map((j) => tones(c)[j])) for (let o = -14; o <= 14; o += 7) {
        const v = s + o;
        if (v >= -3 && v <= 11 && Math.abs(v - x) < bd) { bd = Math.abs(v - x); best = v; }
      }
      return best;
    };
    function phrase(rhy, b0, start, endRoot) {
      let x = start;
      return rhy.map(([st, len], k) => {
        const c = chords[(b0 + (st >> 4)) % 4];
        if (k === rhy.length - 1 && endRoot) x = nearest(x, c, [0]);
        else if (st % 8 === 0 || len >= 4) x = nearest(x + (Math.random() < 0.5 ? 1 : -1), c, [0, 1, 2]);
        else x = Math.max(-3, Math.min(11, x + pick([-1, 1, 1, 2, -2, -1])));
        return { st: st + 16 * b0, len, x };
      });
    }
    const rA = pick(RHY), rB = pick(RHY);
    const A = phrase(rA, 0, 4, false);
    const fit = (ph, b0, endRoot) => ph.map((nt, k) => {          // the motif again over other chords
      const st = nt.st % 32, c = chords[(b0 + (st >> 4)) % 4];
      const x = (k === ph.length - 1 && endRoot) ? nearest(nt.x, c, [0]) : ((st % 8 === 0 || nt.len >= 4) ? nearest(nt.x, c, [0, 1, 2]) : nt.x);
      return { st: st + 16 * b0, len: nt.len, x };
    });
    const B = phrase(rB, 4, A[A.length - 1].x + 2, false);
    const hook = [...A, ...fit(A, 2, false), ...B, ...fit(A, 6, true)];
    const toMidi = (x) => leadBase + scale[((x % 7) + 7) % 7] + 12 * Math.floor(x / 7);
    hook.forEach((nt) => { nt.m = toMidi(nt.x); });
    return { tonic, scale, chords, hook, bpm: 120 + Math.floor(Math.random() * 7), bass: pick(BASSES), arp: pick(ARPS),
             swing: 0.02 + Math.random() * 0.03, padCut: 1300 + Math.random() * 900 };
  }
  // ---- the mixer: everything into a filter (the intro/outro sweeps), reverb and a dotted-eighth delay
  function genStart() {
    const sr = actx.sampleRate;
    const lp = actx.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 18000; lp.Q.value = 0.5;
    const out = actx.createGain(); out.gain.value = 1;
    lp.connect(out); out.connect(musicBus());
    const noise = actx.createBuffer(1, sr, sr), nd = noise.getChannelData(0);
    for (let i = 0; i < sr; i++) nd[i] = Math.random() * 2 - 1;
    const ir = actx.createBuffer(2, Math.floor(sr * 2.6), sr);
    for (let c = 0; c < 2; c++) {
      const d = ir.getChannelData(c);
      for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / d.length, 3.5);
    }
    const verb = actx.createConvolver(); verb.buffer = ir;
    const verbOut = actx.createGain(); verbOut.gain.value = 0.3; verb.connect(verbOut); verbOut.connect(lp);
    const delay = actx.createDelay(2), fb = actx.createGain(), dlp = actx.createBiquadFilter();
    fb.gain.value = 0.35; dlp.type = 'lowpass'; dlp.frequency.value = 2400;
    delay.connect(dlp); dlp.connect(fb); fb.connect(delay); dlp.connect(lp); dlp.connect(verb);
    const duck = actx.createGain(); duck.connect(lp);           // bass, pad and arp pump with the kick
    const send = (g) => { const s = actx.createGain(); s.gain.value = g; return s; };
    const dSend = send(1), vSend = send(1);
    dSend.connect(delay); vSend.connect(verb);
    const g = { lp, out, noise, verb: vSend, delay: dSend, duck, song: newSong(null), bar: 0, step: 0, t: actx.currentTime + 0.1 };
    delay.delayTime.value = 0.75 * 60 / g.song.bpm;
    g.delayNode = delay;
    MUSIC.gen = g;
  }
  function genStop() {
    const g = MUSIC.gen;
    if (!g) return;
    MUSIC.gen = null;
    g.out.gain.setTargetAtTime(0, actx.currentTime, 0.05);
    setTimeout(() => { try { g.out.disconnect(); } catch (e) { /* gone */ } }, 400);
  }
  // ---- instruments
  function panTo(dest, pan) {
    if (!pan || !actx.createStereoPanner) return dest;
    const p = actx.createStereoPanner();
    p.pan.value = pan; p.connect(dest);
    return p;
  }
  function env(gn, t, v, a, d) {                       // attack to v, exponential decay over d
    gn.gain.setValueAtTime(0.0001, t);
    gn.gain.exponentialRampToValueAtTime(v, t + a);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + a + d);
  }
  function osc(type, f, t, end, dest, detune) {
    const o = actx.createOscillator();
    o.type = type; o.frequency.value = f; if (detune) o.detune.value = detune;
    o.connect(dest); o.start(t); o.stop(end);
    return o;
  }
  function noiseHit(g, t, dur, type, freq, q, v, dest, pan) {
    const s = actx.createBufferSource(), f = actx.createBiquadFilter(), gn = actx.createGain();
    s.buffer = g.noise; f.type = type; f.frequency.value = freq; f.Q.value = q;
    s.connect(f); f.connect(gn); gn.connect(panTo(dest || g.lp, pan));
    env(gn, t, v, 0.002, dur);
    s.start(t, Math.random() * 0.5); s.stop(t + dur + 0.05);
  }
  function kick(g, t) {
    const o = actx.createOscillator(), gn = actx.createGain();
    o.frequency.setValueAtTime(160, t); o.frequency.exponentialRampToValueAtTime(48, t + 0.1);
    o.connect(gn); gn.connect(g.lp); env(gn, t, 0.85, 0.003, 0.38); o.start(t); o.stop(t + 0.45);
    noiseHit(g, t, 0.01, 'highpass', 2500, 0.7, 0.1);
    const d = g.duck.gain;                             // side-chain pump
    d.cancelScheduledValues(t); d.setValueAtTime(0.35, t); d.linearRampToValueAtTime(1, t + 0.24);
  }
  function clap(g, t, v) {
    for (let k = 0; k < 3; k++) noiseHit(g, t + k * 0.011, k < 2 ? 0.02 : 0.18, 'bandpass', 1500, 1.1, 0.6 * v);
    noiseHit(g, t, 0.3, 'bandpass', 1500, 1, 0.2 * v, g.verb);
  }
  function hat(g, t, v, open) {
    noiseHit(g, t + (Math.random() - 0.5) * 0.004, open ? 0.3 : 0.05, 'highpass', 6500, 0.7,
      (open ? 0.75 : 0.7) * v * (0.9 + Math.random() * 0.2), null, open ? -0.2 : 0.25);
  }
  function crash(g, t) {
    noiseHit(g, t, 1.8, 'highpass', 4500, 0.5, 0.35, null, 0.15);
    noiseHit(g, t, 2.2, 'highpass', 4500, 0.5, 0.15, g.verb);
  }
  function impact(g, t) {                              // the drop: a sub boom under the crash
    const o = actx.createOscillator(), gn = actx.createGain();
    o.frequency.setValueAtTime(70, t); o.frequency.exponentialRampToValueAtTime(38, t + 0.9);
    o.connect(gn); gn.connect(g.lp); env(gn, t, 0.5, 0.005, 1.1); o.start(t); o.stop(t + 1.2);
  }
  function bassNote(g, t, m, dur) {
    const f = actx.createBiquadFilter(), gn = actx.createGain();
    f.type = 'lowpass'; f.Q.value = 5;
    f.frequency.setValueAtTime(200, t); f.frequency.exponentialRampToValueAtTime(900, t + 0.012);
    f.frequency.exponentialRampToValueAtTime(280, t + dur);
    f.connect(gn); gn.connect(g.duck);
    gn.gain.setValueAtTime(0.0001, t); gn.gain.exponentialRampToValueAtTime(0.17, t + 0.006);
    gn.gain.setValueAtTime(0.17, t + dur * 0.8); gn.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.04);
    osc('sawtooth', midiHz(m), t, t + dur + 0.06, f, -6); osc('sawtooth', midiHz(m), t, t + dur + 0.06, f, 6);
    const sub = actx.createGain(); sub.gain.value = 0.9; sub.connect(gn);
    osc('sine', midiHz(m - 12), t, t + dur + 0.06, sub);
  }
  function padChord(g, t, notes, dur, cut) {
    const f = actx.createBiquadFilter(), gn = actx.createGain();
    f.type = 'lowpass'; f.Q.value = 1;
    f.frequency.setValueAtTime(cut * 0.6, t); f.frequency.linearRampToValueAtTime(cut, t + dur * 0.6);
    f.connect(gn); gn.connect(g.duck); gn.connect(g.verb);
    gn.gain.setValueAtTime(0.0001, t); gn.gain.exponentialRampToValueAtTime(0.045, t + 0.4);
    gn.gain.setValueAtTime(0.045, t + dur - 0.05); gn.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.9);
    notes.forEach((m, i) => {
      const p = panTo(f, i % 2 ? 0.3 : -0.3);
      for (const dt of [-11, 0, 11]) osc('sawtooth', midiHz(m), t, t + dur + 1, p, dt + (Math.random() - 0.5) * 4);
    });
  }
  function pluck(g, t, m, v, pan, bright) {
    const f = actx.createBiquadFilter(), gn = actx.createGain();
    f.type = 'lowpass'; f.Q.value = 2;
    f.frequency.setValueAtTime(1200 + 1800 * bright, t); f.frequency.exponentialRampToValueAtTime(500, t + 0.15);
    f.connect(gn); gn.connect(panTo(g.duck, pan)); gn.connect(g.delay);
    env(gn, t, 0.075 * v, 0.004, 0.2);
    osc('sawtooth', midiHz(m), t, t + 0.25, f, -5); osc('square', midiHz(m), t, t + 0.25, f, 5);
  }
  function leadNote(g, t, m, dur, soft) {
    const f = actx.createBiquadFilter(), gn = actx.createGain(), vib = actx.createOscillator(), vg = actx.createGain();
    f.type = 'lowpass'; f.Q.value = 1.5;
    f.frequency.setValueAtTime(soft ? 1600 : 3800, t); f.frequency.exponentialRampToValueAtTime(soft ? 1000 : 2300, t + dur);
    f.connect(gn); gn.connect(g.lp); gn.connect(g.delay); gn.connect(g.verb);
    const lv = soft ? 0.06 : 0.1;
    gn.gain.setValueAtTime(0.0001, t); gn.gain.exponentialRampToValueAtTime(lv, t + 0.012);
    gn.gain.setValueAtTime(lv * 0.85, t + Math.max(0.02, dur - 0.03)); gn.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.12);
    vib.frequency.value = 5.5; vg.gain.setValueAtTime(0, t); vg.gain.linearRampToValueAtTime(dur > 0.3 ? 14 : 0, t + Math.min(dur, 0.5));
    vib.connect(vg); vib.start(t); vib.stop(t + dur + 0.15);
    const end = t + dur + 0.15;
    for (const [type, dt, lvl] of [['sawtooth', -8, 1], ['sawtooth', 8, 1], ['square', 0, 0.4]]) {
      const o = actx.createOscillator(), og = actx.createGain();
      o.type = type; o.frequency.value = midiHz(type === 'square' ? m - 12 : m); o.detune.value = dt;
      vg.connect(o.detune); og.gain.value = lvl; o.connect(og); og.connect(f); o.start(t); o.stop(end);
    }
  }
  function riser(g, t, dur) {
    const s = actx.createBufferSource(), f = actx.createBiquadFilter(), gn = actx.createGain();
    s.buffer = g.noise; s.loop = true; f.type = 'bandpass'; f.Q.value = 2;
    f.frequency.setValueAtTime(300, t); f.frequency.exponentialRampToValueAtTime(8000, t + dur);
    gn.gain.setValueAtTime(0.0001, t); gn.gain.exponentialRampToValueAtTime(0.12, t + dur);
    gn.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.2);
    s.connect(f); f.connect(gn); gn.connect(g.lp); gn.connect(g.verb); s.start(t); s.stop(t + dur + 0.25);
  }
  // ---- the sequencer: one sixteenth at a time
  function genStep(g, t) {
    const sg = g.song, s = g.step;
    let b = g.bar, sec = FORM[0];
    for (const f of FORM) { if (b < f.n) { sec = f; break; } b -= f.n; }
    const ch = sg.chords[g.bar % 4];
    const bar = 16 * 60 / sg.bpm / 4, secDur = sec.n * bar;
    if (s === 0) {
      if (b === 0) {                                   // a section starts: its filter move, crash
        const lf = g.lp.frequency;
        lf.cancelScheduledValues(t);
        if (sec.f === 'in') { lf.setValueAtTime(320, t); lf.exponentialRampToValueAtTime(18000, t + secDur); }
        else if (sec.f === 'out') { lf.setValueAtTime(18000, t); lf.exponentialRampToValueAtTime(380, t + secDur); }
        else if (sec.f === 'build') { lf.setValueAtTime(1500, t); lf.exponentialRampToValueAtTime(18000, t + secDur); }
        else lf.setValueAtTime(18000, t);
        if (sec.x) { crash(g, t); if (sec.x === 2) impact(g, t); }
        if (sec.r) riser(g, t + (sec.n > 4 ? (sec.n - 4) * bar : 0), Math.min(4, sec.n) * bar);
      }
      if (sec.p) padChord(g, t, ch.v, bar, sg.padCut);
    }
    const lastBar = b === sec.n - 1;
    if (sec.k && s % 4 === 0 && !(sec.kickStop && lastBar)) kick(g, t);
    if (sec.c && (s === 4 || s === 12) && !(sec.kickStop && lastBar)) clap(g, t, 1);
    if (sec.kickStop && b >= sec.n - 2 && (s % 2 === 0 || lastBar)) clap(g, t, 0.25 + 0.6 * ((b - sec.n + 2) * 16 + s) / 32);  // the roll
    if (sec.h && b >= (sec.hFrom || 0)) {
      if (sec.h === 1 && s % 2 === 0) hat(g, t, s % 4 === 2 ? 1 : 0.55, false);
      if (sec.h === 2) hat(g, t, s % 4 === 2 ? 1 : (s % 2 ? 0.45 : 0.65), s % 8 === 6);
    }
    if (sec.b && sg.bass[s]) bassNote(g, t, ch.bass + (sg.bass[s] === 2 ? 12 : 0), 60 / sg.bpm / 4 * 1.6);
    if (sec.a && (sec.soft ? s % 2 === 0 : true)) {
      const ar = [...ch.v, ...ch.v.map((m) => m + 12)], m = ar[sg.arp[s] % ar.length];
      pluck(g, t, m, s % 4 === 0 ? 1 : 0.7, s % 2 ? -0.35 : 0.35, sec.soft ? 0.2 : Math.min(1, b / 8 + 0.3));
    }
    if (sec.l) {
      const pos = (g.bar % 8) * 16 + s;
      for (const nt of sg.hook) if (nt.st === pos) leadNote(g, t, nt.m, nt.len * 60 / sg.bpm / 4 * 0.92, sec.soft);
    }
  }
  function musicTick() {
    const g = MUSIC.gen;
    if (!g || !actx) return;
    const now = actx.currentTime;
    if (g.t < now) g.t = now + 0.05;                    // after a stall (hidden tab): carry on from now
    while (g.t < now + 0.2) {
      const sd = 60 / g.song.bpm / 4;
      genStep(g, g.t + (g.step % 2 ? g.song.swing * sd : 0));
      g.t += sd;
      g.step = (g.step + 1) % 16;
      if (g.step === 0 && ++g.bar >= BARS) {
        g.song = newSong(g.song); g.bar = 0;
        g.delayNode.delayTime.setValueAtTime(0.75 * 60 / g.song.bpm, g.t);
        musicTitle();
      }
    }
  }
  const KEYS = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];
  function musicTitle() {
    let t = 'Music';
    if (app.musicOn) {
      if (MUSIC.files.length) t = 'Playing ' + MUSIC.files[MUSIC.idx].name;
      else if (MUSIC.gen) {
        const sg = MUSIC.gen.song;
        t = 'Generated: ' + KEYS[sg.tonic] + ' minor, ' + sg.bpm + ' BPM';
      }
    }
    const b = document.getElementById('musicBox');
    if (b) b.title = t + ' (wheel: level)';
  }
  function musicPlay() {
    if (!actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { return; } }
    if (actx.state === 'suspended') actx.resume();
    musicBus();
    if (MUSIC.files.length) {
      genStop();
      if (!MUSIC.el) {
        MUSIC.el = new Audio();
        MUSIC.el.addEventListener('ended', () => musicNext());
        MUSIC.src = actx.createMediaElementSource(MUSIC.el);
        MUSIC.src.connect(MUSIC.bus);
      }
      MUSIC.el.src = MUSIC.files[MUSIC.idx].url;
      MUSIC.el.play().catch(() => { /* needs a click first */ });
    } else {
      if (MUSIC.el) MUSIC.el.pause();
      if (!MUSIC.gen) genStart();
    }
    musicTitle();
  }
  function musicStop() {
    genStop();
    if (MUSIC.el) MUSIC.el.pause();
    musicTitle();
  }
  function musicNext() {
    if (!app.musicOn) return;
    if (MUSIC.files.length) { MUSIC.idx = (MUSIC.idx + 1) % MUSIC.files.length; musicPlay(); }
    else if (MUSIC.gen) {
      const g = MUSIC.gen;
      g.song = newSong(g.song); g.bar = 0; g.step = 0;
      g.delayNode.delayTime.setValueAtTime(0.75 * 60 / g.song.bpm, actx.currentTime);
      musicTitle();
    }
  }
  function musicFiles(list) {
    MUSIC.files.forEach((f) => URL.revokeObjectURL(f.url));
    MUSIC.files = Array.from(list).filter((f) => /^audio\//.test(f.type) || /\.(mp3|ogg|wav|m4a|aac|flac|opus)$/i.test(f.name))
      .map((f) => ({ url: URL.createObjectURL(f), name: f.name.replace(/\.[^.]+$/, '') }));
    MUSIC.idx = 0;
    if (app.musicOn) musicPlay();
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
  // form fields keep their keys, and so do the Tracks and Install panels (editor.js): what is typed
  // there (R to turn a gate, Delete, Enter on a button) never flies the quad. The panels take the
  // focus themselves (tabindex -1) when their plain text is clicked, so it doesn't fall to the page.
  const isField = (t) => t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA'
    || (t.closest && t.closest('#editor, #radioPanel') !== null));
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
    musicTick();
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
    // the slider is the switch too (0 = off), the speaker mutes and unmutes (back to the last
    // level), the wheel steps it by 5%; any of them is the user gesture the browser needs before
    // audio may start
    const vol = $('soundVol');
    const volBox = $('soundBox');
    const volShow = () => {
      const on = app.vol > 0;
      volBox.classList.toggle('snd-off', !on);
      $('volOut').textContent = on ? Math.round(app.vol * 100) + '%' : 'Off';
      $('muteBtn').setAttribute('aria-pressed', String(!on));
      $('muteBtn').title = on ? 'Mute' : 'Unmute';
    };
    const applyVol = (v) => {
      app.vol = Math.round(Math.max(0, Math.min(1, v)) * 20) / 20;
      vol.value = app.vol;
      store.set('vol', app.vol);
      if (app.vol > 0) { app.lastVol = app.vol; store.set('lastVol', app.vol); }
      volShow();
      if (app.vol > 0 && !actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { app.vol = 0; vol.value = 0; volShow(); } }
      if (actx && actx.state === 'suspended') actx.resume();
      if (outGain) outGain.gain.setTargetAtTime(volGain(app.vol), actx.currentTime, 0.03);
      if (app.vol <= 0) { if (motor && actx) bgTone(0, 0, 0); stopSynth(); }
    };
    vol.value = app.vol;
    volShow();
    vol.addEventListener('input', () => applyVol(parseFloat(vol.value) || 0));
    $('muteBtn').addEventListener('click', () => applyVol(app.vol > 0 ? 0 : (app.lastVol || 0.8)));
    volBox.addEventListener('wheel', (e) => { e.preventDefault(); applyVol(app.vol + (e.deltaY < 0 ? 0.05 : -0.05)); }, { passive: false });
    // music: the note switches it on and off, the slider is its level (apart from Sound), next
    // skips to a new song, Songs plays your own files instead of the generated music
    const mBox = $('musicBox'), mVol = $('musicVol');
    const musicShow = () => {
      mBox.classList.toggle('snd-off', !app.musicOn);
      $('songsClear').hidden = !MUSIC.files.length;             // only with your own songs loaded
      $('musicBtn').setAttribute('aria-pressed', String(app.musicOn));
      $('musicBtn').title = app.musicOn ? 'Music off' : 'Music on';
      musicTitle();
    };
    const musicOn = (on) => {
      app.musicOn = on; store.set('musicOn', on);
      if (on) musicPlay(); else musicStop();
      musicShow();
    };
    const setMusicVol = (v) => {
      app.musicVol = Math.round(Math.max(0, Math.min(1, v)) * 20) / 20;
      mVol.value = app.musicVol; store.set('musicVol', app.musicVol);
      if (MUSIC.bus) MUSIC.bus.gain.setTargetAtTime(0.6 * volGain(app.musicVol), actx.currentTime, 0.03);
    };
    mVol.value = app.musicVol;
    mVol.addEventListener('input', () => { setMusicVol(parseFloat(mVol.value) || 0); if (!app.musicOn && app.musicVol > 0) musicOn(true); });
    $('musicBtn').addEventListener('click', () => musicOn(!app.musicOn));
    $('musicNext').addEventListener('click', () => { if (app.musicOn) musicNext(); else musicOn(true); });
    $('songIn').addEventListener('change', (ev) => {
      musicFiles(ev.target.files);
      ev.target.value = '';
      if (!app.musicOn) musicOn(true); else musicShow();
    });
    // x: forget your own songs, back to the generated music
    $('songsClear').addEventListener('click', () => { musicFiles([]); musicShow(); });
    mBox.addEventListener('wheel', (e) => { e.preventDefault(); setMusicVol(app.musicVol + (e.deltaY < 0 ? 0.05 : -0.05)); }, { passive: false });
    musicShow();
    // browsers only start audio after a user gesture: with the volume already up (the saved
    // setting), the first click, tap or key press anywhere turns the sound on
    const unlock = () => {
      if ((app.vol > 0 || app.musicOn) && !actx) { try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { /* no audio */ } }
      if (actx && actx.state === 'suspended') actx.resume();
      if (actx && app.musicOn && !MUSIC.gen && !(MUSIC.el && !MUSIC.el.paused)) musicPlay();
      if (actx) ['pointerdown', 'keydown'].forEach((t) => window.removeEventListener(t, unlock, true));
    };
    ['pointerdown', 'keydown'].forEach((t) => window.addEventListener(t, unlock, true));
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
    const copyLabel = $('copyBtn').textContent;
    $('copyBtn').addEventListener('click', async () => {
      const s = scriptFor();
      const btn = $('copyBtn');
      try { await navigator.clipboard.writeText(s.text); btn.textContent = 'Copied ' + s.name; }
      catch (e) { btn.textContent = 'Copy blocked'; }
      setTimeout(() => { btn.textContent = copyLabel; }, 1800);
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
        store.set('input', app.input);
        document.querySelectorAll('#inputSeg button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
        $('padBox').hidden = app.input !== 'pad';
      });
    });
    $('padBox').hidden = app.input !== 'pad';
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

  // automation hook (used by the test suite), and the track editor's way in (editor.js)
  const saveSD = () => store.set('sd', Object.fromEntries(app.sd));
  window.sim = {
    get app() { return app; },
    get engine() { return app.engine; },
    radio(id) { $('radioSel').value = id; $('radioSel').dispatchEvent(new Event('change')); },
    script(id) { $('scriptSel').value = id; $('scriptSel').dispatchEvent(new Event('change')); },
    sticks(a, e, t, r) { stick.ail = a; stick.ele = e; stick.thr = t; stick.rud = r; },
    key, pause(p) { app.paused = p; $('pauseChk').checked = p; },
    // a file on the virtual SD card, kept (localStorage) like the game's own saves; the game
    // reads it when it next starts (boot)
    // (true when kept; false: the browser's storage is full or blocked, the file lasts this visit)
    writeSD(path, text) { app.sd.set(path, String(text)); return saveSD(); },
    removeSD(path) { app.sd.delete(path); return saveSD(); },
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
