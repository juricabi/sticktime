/* Track editor (the Tracks button): a top-down map of a custom track with its gates in race order,
   its structures, the start pad and the trees, checked against what the game takes. It writes the
   track to the emulator's SD card as /SCRIPTS/TOOLS/StickTimeTracks/c<slot>.txt and flies it, or
   saves the file for the radio's SD card. StickTime and StickTime BW read those files as tracks
   9-16 (src/sticktime.lua: TRACKS, buildTrack); TRACK_DATA (made by tools/bundle_web.py from that
   source) brings the built-in tracks and the gate sizes. The emulator is reached through window.sim
   (app.js). */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const root = $('editor');
  if (!root || typeof TRACK_DATA !== 'object') return;
  const D = TRACK_DATA;

  // ---------------------------------------------------------------- the game's rules
  const GT = D.GT, FLAGH = D.FLAGH;                 // frame thickness, flag pole height (m)
  const GHW = [0, ...D.GHW], GHH = [0, ...D.GHH];   // by gate type 1-8: inner half width, half height
  const GCY = [0, ...D.GCY];                        // centre height when the file says 0
  const TYPES = ['', 'Gate', 'High gate', 'Dive gate', 'Hoop', 'Arch', 'Flag, pass right', 'Flag, pass left', 'Gap in a wall'];
  const KINDS = ['', 'Concrete', 'Red container', 'Blue container'];
  const MAX_GATES = 24, MAX_BOXES = 16, MAX_BYTES = 999, SLOTS = 8;
  const TOL = 0.02;          // faces this close count as touching (the game's draw-order rule)
  const GRID = 0.5;          // drags snap to it; Alt drags to the cm
  const DIR = '/SCRIPTS/TOOLS/StickTimeTracks/';
  const STORE = 'fpvsim.editor';
  const D2R = Math.PI / 180;
  const SMIN = 0.3, SMAX = 80;                      // map zoom (px per m)

  // ---------------------------------------------------------------- numbers
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const r2 = (v) => Math.round(v * 100) / 100 + 0;  // to the cm (+0: never -0)
  const snapTo = (v, s) => Math.round(v / s) * s;
  const normYaw = (y) => ((Math.round(y) % 360) + 360) % 360;
  // a number as the file has it: plain decimal, at most 2 places, no trailing zeros, no exponent
  function dec(v) {
    const s = r2(v).toFixed(2).replace(/\.?0+$/, '');
    return s === '-0' ? '0' : s;
  }
  // 32-bit FNV-1a: the track's id comes from its numbers, so an unchanged track keeps its bests
  function fnv1a(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193);
    return h >>> 0;
  }
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  // the ranges the editor keeps every item in (an opened file, a stored work in progress, an edit),
  // so that reading a track back never changes it
  const pos = (v) => r2(clamp(v, -999, 999));
  const gateOf = (x, z, t, yaw, h) => ({ x: pos(x), z: pos(z), t, yaw: normYaw(yaw), h: r2(clamp(h, 0, 100)) });
  const boxOf = (x, z, hx, hz, y0, y1, k) => ({ x: pos(x), z: pos(z), hx: r2(clamp(Math.abs(hx), 0.05, 200)), hz: r2(clamp(Math.abs(hz), 0.05, 200)),
    y0: r2(clamp(y0, 0, 200)), y1: r2(clamp(y1, 0.1, 300)), k });

  // ---------------------------------------------------------------- the file
  // A track: { name, seed, trees, gates: [{ id, g, x, z, t, yaw, h }], boxes: [{ id, g, x, z, hx, hz,
  // y0, y1, k }] }. id is the editor's handle on an item and g its group (0: none): not in the file.
  function numbersOf(T) {
    const a = [String(T.seed), String(T.trees)];
    for (const g of T.gates) a.push(dec(g.x), dec(g.z), String(g.t), String(normYaw(g.yaw)), dec(g.h));
    let s = a.join(' ');
    if (T.boxes.length) {
      s += ' / ' + T.boxes.map((b) => [dec(b.x), dec(b.z), dec(b.hx), dec(b.hz), dec(b.y0), dec(b.y1), String(b.k)].join(' ')).join(' ');
    }
    return s;
  }
  // name, then: format 1, the id (FNV-1a of everything after it, mod 999999, + 1), the numbers
  function fileOf(T) {
    const nums = numbersOf(T);
    const id = fnv1a(nums) % 999999 + 1;
    const text = T.name.trim() + '\n1 ' + id + ' ' + nums + '\n';
    return { text, id, bytes: new TextEncoder().encode(text).length };
  }

  const NUM = /^[-+]?(\d+\.?\d*|\.\d+)$/;
  // a track file (c1.txt ...) back into a track; CR LF and numbers over several lines are fine
  function parseFile(text) {
    const s = String(text).replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
    const nl = s.indexOf('\n');
    const name = (nl < 0 ? s : s.slice(0, nl)).trim();
    if (!name) return { error: 'the first line should be the name of the track.' };
    const rest = nl < 0 ? '' : s.slice(nl + 1);
    const cut = rest.indexOf('/');
    const head = (cut < 0 ? rest : rest.slice(0, cut)).split(/\s+/).filter(Boolean);
    const tail = cut < 0 ? [] : rest.slice(cut + 1).split(/\s+/).filter(Boolean);
    if (head.length < 4) return { error: 'after the name come the format (1), an id, the tree seed and the trees.' };
    if (head[0] !== '1') return { error: 'it is format ' + head[0].slice(0, 12) + ': the editor reads format 1.' };
    const bad = head.concat(tail).find((v) => !NUM.test(v));
    if (bad !== undefined) return { error: '"' + bad.slice(0, 24) + '" is not a number.' };
    const g = head.slice(4).map(Number), b = tail.map(Number);
    if (g.length % 5) return { error: 'gates are 5 numbers each (x z type yaw height): ' + (g.length % 5) + ' left over.' };
    if (b.length % 7) return { error: 'structures are 7 numbers each (x z half-x half-z bottom top kind): ' + (b.length % 7) + ' left over.' };
    const T = { name, seed: clamp(Math.round(+head[2]), 1, 99), trees: clamp(Math.round(+head[3]), 0, 30), gates: [], boxes: [] };
    for (let i = 0; i < g.length; i += 5) {
      const t = g[i + 2];
      if (!(Number.isInteger(t) && t >= 1 && t <= 8)) return { error: 'gate ' + (i / 5 + 1) + ' is of type ' + t + ': the types are 1 to 8.' };
      T.gates.push(gateOf(g[i], g[i + 1], t, g[i + 3], g[i + 4]));
    }
    for (let i = 0; i < b.length; i += 7) {
      const k = b[i + 6];
      if (!(Number.isInteger(k) && k >= 1 && k <= 3)) return { error: 'structure ' + (i / 7 + 1) + ' is of kind ' + k + ': the kinds are 1 to 3.' };
      T.boxes.push(boxOf(b[i], b[i + 1], b[i + 2], b[i + 3], b[i + 4], b[i + 5], k));
    }
    const notes = [];
    if (new TextEncoder().encode(s).length > 1000) notes.push('The game reads only the first 1000 bytes of a track file: make it smaller.');
    // numbers the editor writes otherwise (rounded, kept in range, another format): a new id
    if (head.slice(2).concat(cut < 0 ? [] : ['/'].concat(tail)).join(' ') !== numbersOf(T)) {
      notes.push('Some values were adjusted to what the editor writes (rounded or kept in range): saving gives the track a new id, so its best times on the radio start over.');
    }
    return { T, note: notes.join(' ') };
  }
  // a track file the editor (and so the game) can't read: marked in the slot lists, never copied
  const unreadable = (t) => !!parseFile(t).error;

  // ---------------------------------------------------------------- geometry (buildTrack's)
  function gateGeom(g) {
    const k = g.t, a = g.yaw * D2R;
    const hx = Math.sin(a), hz = Math.cos(a);         // facing: the way through
    const rx = hz, rz = -hx;                           // right
    const iw = GHW[k], ih = GHH[k];
    let x = g.x, z = g.z, y = g.h > 0 ? g.h : GCY[k];
    let ax = x, ay = y, az = z;                        // aim point: racing line, start pad
    const legs = [];                                   // pillars: legs, stands, the flag's pole
    if (k === 2) {
      const o = iw + GT * 0.5;
      legs.push([x + rx * o, z + rz * o], [x - rx * o, z - rz * o]);
    } else if (k === 3) {
      const ow = iw + GT * 0.5, oh = ih + GT * 0.5;
      for (const sx of [-1, 1]) for (const sz of [-1, 1]) legs.push([x + rx * ow * sx + hx * oh * sz, z + rz * ow * sx + hz * oh * sz]);
    } else if (k === 4) {
      legs.push([x, z]);
    } else if (k === 5) {
      ay = 1.4;
    } else if (k === 6 || k === 7) {
      // (x, z) is the pole; the gate is the pass zone beside it
      const s = k === 6 ? 1 : -1;
      legs.push([x, z]);
      ax = x + rx * s * 2.5; ay = 1.8; az = z + rz * s * 2.5;
      x += rx * s * iw; z += rz * s * iw; y = 0;
    }
    // the bounds the game orders it by against structures (GB in buildTrack)
    let w = iw + GT, d = 0.2, y0 = y - ih - GT, y1 = y + ih + GT;
    if (k === 3) { d = ih + GT; y0 = 0; y1 = y + GT; }
    else if (k === 2) y0 = 0;
    else if (k === 4 || k === 5) { y0 = 0; y1 = y + iw + GT; }
    else if (k === 8) { w = iw; d = 0; y0 = y - ih; y1 = y + ih; }
    let bx = x, bz = z;
    if (k === 6 || k === 7) {
      const o = (k === 6 ? -1 : 1) * iw;
      bx = x + rx * o; bz = z + rz * o; w = 1; d = 1; y0 = 0; y1 = FLAGH;
    }
    const ex = Math.abs(hz) * w + Math.abs(hx) * d, ez = Math.abs(hx) * w + Math.abs(hz) * d;
    const box = { x0: bx - ex, x1: bx + ex, z0: bz - ez, z1: bz + ez, y0, y1 };
    // a dive gate faces down: no direction on the ground
    const nx = k === 3 ? 0 : hx, nz = k === 3 ? 0 : hz;
    return { k, x, z, y, hx, hz, rx, rz, iw, ih, ax, ay, az, nx, nz, legs, box };
  }
  // the start pad: 14 m behind gate 1's aim point, facing it
  const padOf = (G) => (G.length ? { x: G[0].ax - G[0].nx * 14, z: G[0].az - G[0].nz * 14, hx: G[0].nx, hz: G[0].nz } : null);
  const bbOf = (b) => ({ x0: b.x - b.hx, x1: b.x + b.hx, z0: b.z - b.hz, z1: b.z + b.hz, y0: b.y0, y1: b.y1 });
  const ov = (a0, a1, b0, b1) => Math.min(a1, b1) - Math.max(a0, b0);
  const cuts = (a, b) => ov(a.x0, a.x1, b.x0, b.x1) > TOL && ov(a.z0, a.z1, b.z0, b.z1) > TOL && ov(a.y0, a.y1, b.y0, b.y1) > TOL;
  const rectDist = (x, z, r) => Math.hypot(Math.max(r.x0 - x, 0, x - r.x1), Math.max(r.z0 - z, 0, z - r.z1));
  function segDist2(x, z, ax, az, bx, bz) {
    let dx = bx - ax, dz = bz - az;
    const l = dx * dx + dz * dz;
    const t = l > 0 ? clamp(((x - ax) * dx + (z - az) * dz) / l, 0, 1) : 0;
    dx = ax + dx * t - x; dz = az + dz * t - z;
    return dx * dx + dz * dz;
  }
  // the wind and the trees, as buildTrack makes them from the seed (trees: the color edition's count)
  function windOf(seed) {
    const a = (seed * 171 % 30269) / 30269 * 6.2832;
    return { x: Math.sin(a), z: Math.cos(a) };
  }
  function treesOf(T, G, pad) {
    const out = [];
    if (!G.length || !pad) return out;
    let seed = T.seed;
    const rnd = () => (seed = seed * 171 % 30269) / 30269;
    rnd();                                             // (the wind's)
    const P = [];
    for (const g of G) for (const l of g.legs) P.push(l);
    const B = T.boxes.map(bbOf);
    let x0 = pad.x, x1 = pad.x, z0 = pad.z, z1 = pad.z;
    for (const g of G) { x0 = Math.min(x0, g.x); x1 = Math.max(x1, g.x); z0 = Math.min(z0, g.z); z1 = Math.max(z1, g.z); }
    for (const b of B) { x0 = Math.min(x0, b.x0); x1 = Math.max(x1, b.x1); z0 = Math.min(z0, b.z0); z1 = Math.max(z1, b.z1); }
    const want = D.TREES * (T.trees / 9);
    let n = 0, tries = 0;
    while (n < want && tries < want * 16) {
      tries++;
      const x = x0 - 30 + rnd() * (x1 - x0 + 60);
      const z = z0 - 30 + rnd() * (z1 - z0 + 60);
      let ok = segDist2(x, z, pad.x, pad.z, G[0].ax, G[0].az) > 100 && B.every((b) => rectDist(x, z, b) ** 2 > 16);
      for (let i = 0; ok && i < G.length; i++) {
        const j = (i + 1) % G.length;
        if (segDist2(x, z, G[i].ax, G[i].az, G[j].ax, G[j].az) < 100) ok = false;
      }
      for (let i = 0; ok && i < P.length; i++) if ((x - P[i][0]) ** 2 + (z - P[i][1]) ** 2 < 36) ok = false;
      if (ok) {
        n++;
        const h = 6 + rnd() * 6;
        P.push([x, z]);
        out.push({ x, z, h });
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- checks
  function check(T, G, pad, file) {
    const P = [];
    const add = (msg, ids) => P.push({ msg, ids: ids || [] });
    const name = T.name.trim();
    if (!name) add('Give the track a name.');
    else {
      if (name.length > 16) add('The name has ' + name.length + ' characters: 16 at most.');
      if (/[^\x20-\x7e]|\//.test(name)) add('The name takes plain letters, digits and punctuation, without "/".');
    }
    const ng = T.gates.length, nb = T.boxes.length;
    if (ng < 2) add('A track needs at least 2 gates.');
    if (ng > MAX_GATES) add(ng + ' gates: ' + MAX_GATES + ' at most.');
    if (nb > MAX_BOXES) add(nb + ' structures: ' + MAX_BOXES + ' at most.');
    if (file.bytes > MAX_BYTES) add('The file would be ' + file.bytes + ' bytes: ' + MAX_BYTES + ' at most. Fewer items or rounder numbers make it smaller.');
    if (ng && T.gates[0].t === 3) add('Gate 1 can\'t be a dive gate: the start pad faces gate 1 across the ground.', [T.gates[0].id]);
    const B = T.boxes.map(bbOf);
    T.boxes.forEach((b, i) => { if (!(b.hx > 0 && b.hz > 0 && b.y1 > b.y0)) add('Structure ' + (i + 1) + ' has no size.', [b.id]); });
    for (let i = 0; i < nb; i++) {
      for (let j = i + 1; j < nb; j++) if (cuts(B[i], B[j])) add('Structures ' + (i + 1) + ' and ' + (j + 1) + ' overlap.', [T.boxes[i].id, T.boxes[j].id]);
    }
    G.forEach((g, i) => {
      for (let j = 0; j < nb; j++) {
        if (!cuts(g.box, B[j])) continue;
        const ids = [T.gates[i].id, T.boxes[j].id];
        if (g.k === 8) add('Structure ' + (j + 1) + ' blocks the gap of gate ' + (i + 1) + '.', ids);
        else if (g.k === 6 || g.k === 7) add('The flag of gate ' + (i + 1) + ' stands in or against structure ' + (j + 1) + '.', ids);
        else add('Gate ' + (i + 1) + ' cuts into structure ' + (j + 1) + '.', ids);
      }
    });
    if (pad) {
      T.boxes.forEach((b, j) => {
        if (b.y0 < 1.5 && rectDist(pad.x, pad.z, B[j]) < 2) add('Structure ' + (j + 1) + ' stands on the start pad (14 m behind gate 1).', [b.id]);
      });
    }
    return P;
  }

  // ---------------------------------------------------------------- tracks to start from
  function fromBuiltin(t) {
    return {
      name: ('My ' + t.name).slice(0, 16), seed: t.seed, trees: t.trees,
      gates: t.gates.map(([x, z, k, yaw, h]) => ({ x: r2(x), z: r2(z), t: k, yaw: normYaw(yaw), h: r2(h) })),
      boxes: t.boxes.map(([x, z, hx, hz, y0, y1, k]) => ({ x: r2(x), z: r2(z), hx: r2(hx), hz: r2(hz), y0: r2(y0), y1: r2(y1), k })),
    };
  }
  const blankTrack = () => ({
    name: 'My Track', seed: 1 + Math.floor(Math.random() * 99), trees: 9, boxes: [],
    gates: [{ x: 0, z: 0, t: 1, yaw: 0, h: 0 }, { x: 12, z: 40, t: 1, yaw: 180, h: 0 }],
  });
  // a stored work in progress, checked number by number
  function clean(T) {
    if (!T || typeof T !== 'object' || !Array.isArray(T.gates) || !Array.isArray(T.boxes)) return null;
    const n = (v, d) => (Number.isFinite(+v) ? +v : d);
    const id = (v) => (Number.isInteger(v) && v > 0 ? v : 0);
    const out = { name: typeof T.name === 'string' ? T.name.slice(0, 40) : 'My Track',
      seed: clamp(Math.round(n(T.seed, 1)), 1, 99), trees: clamp(Math.round(n(T.trees, 9)), 0, 30), gates: [], boxes: [] };
    for (const g of T.gates.slice(0, 64)) {
      if (g && typeof g === 'object') {
        out.gates.push(Object.assign({ id: id(g.id), g: id(g.g) }, gateOf(n(g.x, 0), n(g.z, 0), clamp(Math.round(n(g.t, 1)), 1, 8), n(g.yaw, 0), n(g.h, 0))));
      }
    }
    for (const b of T.boxes.slice(0, 64)) {
      if (b && typeof b === 'object') {
        out.boxes.push(Object.assign({ id: id(b.id), g: id(b.g) },
          boxOf(n(b.x, 0), n(b.z, 0), n(b.hx, 1), n(b.hz, 1), n(b.y0, 0), n(b.y1, 4), clamp(Math.round(n(b.k, 1)), 1, 3))));
      }
    }
    const seen = new Set();
    for (const it of out.gates.concat(out.boxes)) { if (it.id && seen.has(it.id)) it.id = 0; seen.add(it.id); }
    return out;
  }

  // ---------------------------------------------------------------- state
  const ed = {
    T: null, sel: new Set(), focus: null, hover: null,
    undo: [], redo: [], nextId: 1, nextGroup: 1,
    slot: 1, showTrees: false, open: false, fitted: false, hadView: false,
    G: [], pad: null, file: null, probs: [], bad: new Set(), trees: null, wind: null,
    // the track as it came (a template, a file), and what was saved (Save file, Send to radio, Fly
    // it): replacing a track that is in neither, nor in a slot, asks first
    pristine: '', saved: new Set(),
  };
  const V = { x: 0, z: 30, s: 4 };                  // map centre (m) and scale (px per m)
  const gal = { list: [], open: false, mine: false, asked: false }; // the gallery's tracks; Open or My tracks shown; the site's list asked for

  function withIds(T) {
    const all = T.gates.concat(T.boxes);
    for (const it of all) {
      if (it.id) ed.nextId = Math.max(ed.nextId, it.id + 1);
      if (it.g) ed.nextGroup = Math.max(ed.nextGroup, it.g + 1); else it.g = 0;
    }
    for (const it of all) if (!it.id) it.id = ed.nextId++;
    return T;
  }
  // a gap gate and the structures around its opening move together (the Bando's walls)
  function inferGroups(T) {
    const up = new Map();
    const top = (a) => { while (up.get(a) !== a) a = up.get(a); return a; };
    const all = T.gates.concat(T.boxes);
    for (const it of all) up.set(it.id, it.id);
    for (const g of T.gates) {
      if (g.t !== 8) continue;
      const o = gateGeom(g).box;
      for (const b of T.boxes) {
        const B = bbOf(b);
        if (ov(o.x0, o.x1, B.x0, B.x1) > -0.03 && ov(o.z0, o.z1, B.z0, B.z1) > -0.03 && ov(o.y0, o.y1, B.y0, B.y1) > -0.03) up.set(top(b.id), top(g.id));
      }
    }
    const size = new Map(), num = new Map();
    for (const it of all) size.set(top(it.id), (size.get(top(it.id)) || 0) + 1);
    for (const it of all) {
      const r = top(it.id);
      if (size.get(r) < 2) { it.g = 0; continue; }
      if (!num.has(r)) num.set(r, ed.nextGroup++);
      it.g = num.get(r);
    }
  }
  function find(id) {
    let i = ed.T.gates.findIndex((g) => g.id === id);
    if (i >= 0) return { kind: 'gate', it: ed.T.gates[i], i };
    i = ed.T.boxes.findIndex((b) => b.id === id);
    return i >= 0 ? { kind: 'box', it: ed.T.boxes[i], i } : null;
  }
  const items = () => ed.T.gates.concat(ed.T.boxes);
  function groupOf(id) {
    const f = find(id);
    return f && f.it.g ? items().filter((o) => o.g === f.it.g).map((o) => o.id) : [id];
  }
  function selected() {
    const gates = ed.T.gates.filter((g) => ed.sel.has(g.id)), boxes = ed.T.boxes.filter((b) => ed.sel.has(b.id));
    return { gates, boxes, all: gates.concat(boxes) };
  }
  // one item, or one whole group: the form shows the focused item of it
  function selOne() {
    const s = selected().all;
    if (s.length === 1) return true;
    const g = s.length && s[0].g;
    return !!g && s.every((o) => o.g === g) && s.length === items().filter((o) => o.g === g).length;
  }
  function setSel(ids, focus) {
    ed.sel = new Set(ids);
    ed.focus = focus !== undefined && focus !== null && ed.sel.has(focus) ? focus : (ids.length ? ids[0] : null);
  }
  function prune() {
    const ok = new Set(items().map((o) => o.id));
    for (const id of [...ed.sel]) if (!ok.has(id)) ed.sel.delete(id);
    if (!ed.sel.has(ed.focus)) ed.focus = ed.sel.size ? [...ed.sel][0] : null;
  }

  // undo: whole-track snapshots (a track is a few hundred numbers)
  const snap = () => JSON.stringify(ed.T);
  function pushUndo() {
    ed.undo.push(snap());
    if (ed.undo.length > 200) ed.undo.shift();
    ed.redo.length = 0;
  }
  function undo() {
    if (!ed.undo.length) return;
    ed.redo.push(snap());
    ed.T = JSON.parse(ed.undo.pop());
    prune();
    changed();
  }
  function redo() {
    if (!ed.redo.length) return;
    ed.undo.push(snap());
    ed.T = JSON.parse(ed.redo.pop());
    prune();
    changed();
  }

  function derive() {
    const T = ed.T;
    ed.G = T.gates.map(gateGeom);
    ed.pad = padOf(ed.G);
    ed.file = fileOf(T);
    ed.probs = check(T, ed.G, ed.pad, ed.file);
    ed.bad = new Set(ed.probs.flatMap((p) => p.ids));
    ed.wind = windOf(T.seed);
    ed.trees = null;
  }
  function changed() { derive(); refresh(); saveSoon(); }   // after any change to the track
  function refresh() { renderSide(); redraw(); }

  // ---------------------------------------------------------------- the emulator
  const sim = () => (window.sim && window.sim.app ? window.sim : null);
  const slotPath = (n) => DIR + 'c' + n + '.txt';
  const MAX_FILE = 32768;                          // a track file is far smaller: a bigger one isn't read
  // a track file's name, as the game reads it (its first line, 16 characters)
  const nameOf = (t) => (t.replace(/^\s+/, '').split(/[\r\n]/)[0] || '').trim().slice(0, 16) || '(no name)';
  const norm = (t) => t.replace(/\r\n?/g, '\n');       // (a file with CR LF line ends is the same track)
  // the slots that hold this very track: here (the emulator) and on the radio (once its slots are read)
  function homes(text) {
    const here = [], there = [];
    for (let i = 1; i <= SLOTS; i++) {
      const t = emuSlot(i), e = radioRead() ? radioSlots[i - 1] : null;
      if (t !== null && norm(t) === text) here.push(i);
      if (e && !e.bad && norm(e.text) === text) there.push(i);
    }
    return { here, there };
  }
  const homeOf = (text) => { const h = homes(text); return h.here[0] || h.there[0] || 0; };
  const emuSlot = (n) => {
    const s = sim(), t = s && s.app.sd ? s.app.sd.get(slotPath(n)) : undefined;
    return typeof t === 'string' ? t : null;
  };
  // a slot's file: null (none), else { text, bad }: bad says why the game and the editor can't use it
  // ('big': too big to be read at all, text null; 'parse': the editor's checks reject it)
  const BAD = { big: 'too big to be a track', parse: 'can\'t be read' };
  const asEntry = (t) => (t === null ? null : { text: t, bad: unreadable(t) ? 'parse' : '' });
  // a slot's file in a question: "its name", or what is wrong with it
  const what = (e) => (e.bad === 'big' ? 'a file too big to be a track' : e.bad ? 'a file that can\'t be read' : '"' + nameOf(e.text) + '"');
  // what a slot's file is called in the lists: its name, or that it can't be read
  const slotText = (t) => (unreadable(t) ? BAD.parse : nameOf(t));
  const slotName = (n) => { const t = emuSlot(n); return t === null ? null : slotText(t); };

  // The game reads the slots' names when it starts: when they change (a copy from the radio, Empty
  // slot, a gallery update) and the game is in its menus, it starts again at once, so that its Track
  // list has them; in a race it goes on (true: started again)
  function freshGame() {
    const s = sim();
    if (!s || !s.engine || s.engine.error || s.app.custom || s.app.script === 'lite') return false;
    let st = 0;
    try { const a = s.test('audio'); st = a && a[2]; } catch (e) { return false; }
    if (st !== 1 && st !== 2) return false;                // (MENU, SETUP)
    s.boot();
    return true;
  }

  // ---------------------------------------------------------------- the page
  const el = {};
  for (const k of ['tracksBtn', 'edClose', 'radioBtn', 'rpClose',
    'edOpen', 'edGalBtn', 'edMineBtn', 'edMine', 'edMineStatus', 'edMineNote', 'edOpenList', 'edUpdList', 'edSyncMine', 'edNewCards', 'edSlotList', 'edEditing', 'edGallery', 'edCards', 'edGrid', 'edGalStatus', 'edGalSync', 'edGalSyncText', 'edGalSyncAll', 'edGateType', 'edAddGate', 'edAddBox', 'edAddWall',
    'edRotL', 'edRotR', 'edDup', 'edDel', 'edUndo', 'edRedo', 'edFit', 'edTrees', 'edMap', 'edMapBox', 'edReadout',
    'edSlot', 'edFly', 'edFlyText', 'edSendEmu', 'edSave', 'edSize', 'edLite', 'edStatus', 'edEmuHas', 'edFileHas',
    'edSyncLine', 'edSyncText', 'edSendText', 'edName', 'edSeed', 'edShuffle', 'edTreesN',
    'edSel', 'edProblems', 'edProbPill', 'edOrder', 'edSend', 'edRadioLine', 'edRadioLineText',
    // the Install panel
    'radioPanel', 'rpStatus', 'rpInstWait', 'rpInstSec', 'rpTracksSec', 'rpShowTracks', 'edAllFrom', 'edAllTo',
    'edRadio', 'edRadioState', 'edConnect', 'edRefresh', 'edForget', 'edRadioNote', 'edInstallNote', 'edInstallMore', 'edInstallPanel', 'edInstallHead', 'edEditions', 'edInstallHint',
    'edInstallGo', 'edInstallBar']) el[k] = $(k);
  const rp = el.radioPanel;
  const cv = el.edMap, ctx = cv.getContext('2d');
  const UP = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3.5 10l4.5-4.5 4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const DOWN = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M3.5 6l4.5 4.5 4.5-4.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function status(msg, kind) {
    el.edStatus.textContent = msg || '';
    el.edStatus.className = 'ed-status' + (kind ? ' ' + kind : '');
  }
  function setVal(input, v) {
    const s = String(v);
    if (document.activeElement !== input && input.value !== s) input.value = s;
  }
  // rebuild part of the panel without dropping the keyboard focus on the page (where the keys
  // would fly the quad): back on the same control, or on the map
  function keepFocus(box, rebuild) {
    const a = document.activeElement;
    let key = null;
    if (a && a !== box && box.contains(a)) {
      for (const k of ['pick', 'f', 'a', 'prob', 'new', 'sopen', 'sdel', 'scopy', 'connect', 'gfly', 'gopen', 'gsync']) if (a.dataset[k] !== undefined) { key = '[data-' + k + '="' + a.dataset[k] + '"]'; break; }
      if (!key) key = '-';
    }
    rebuild();
    if (key) {
      const n = key !== '-' && box.querySelector(key);
      if (n && !n.disabled) n.focus({ preventScroll: true }); else cv.focus({ preventScroll: true });
    }
  }

  function renderSide() {
    setVal(el.edName, ed.T.name);
    setVal(el.edSeed, ed.T.seed);
    setVal(el.edTreesN, ed.T.trees);
    el.edTrees.checked = ed.showTrees;
    renderSel();
    renderProblems();
    renderOrder();
    renderFly();
    renderButtons();
  }

  // the selected item's form: rebuilt when the selection changes, its values kept up to date
  let selSig = null;
  function renderSel() {
    const s = selected();
    const f = ed.focus !== null ? find(ed.focus) : null;
    const one = f && selOne();
    const sig = s.all.map((o) => o.id).join(',') + '|' + (one ? f.it.id + ':' + (f.kind === 'gate' ? f.it.t : 'b') : '');
    if (sig !== selSig) {
      selSig = sig;
      keepFocus(el.edSel, () => buildSel(s, f, one));
    }
    fillSel(s, f, one);
  }
  function buildSel(s, f, one) {
    const box = el.edSel;
    if (!s.all.length) {
      box.innerHTML = '<p class="note">Nothing selected. Tap a gate or a structure on the map, or add one with the buttons above the map.</p>';
    } else if (!one) {
      box.innerHTML = '<p class="ed-selhead"><strong data-v="what"></strong></p><p class="note">Drag them together on the map; R turns them (structures in 90° steps).</p>' +
        '<div class="ed-row"><button class="btn" type="button" data-a="group">Group</button><button class="btn" type="button" data-a="ungroup">Ungroup</button></div>';
    } else if (f.kind === 'gate') {
      const flag = f.it.t === 6 || f.it.t === 7;
      box.innerHTML = '<p class="ed-selhead"><strong data-v="what"></strong> <span class="note" data-v="sub"></span></p><div class="ed-form">' +
        '<label class="ed-f wide"><span>Type</span><select data-f="t">' + TYPES.slice(1).map((n, i) => '<option value="' + (i + 1) + '">' + n + '</option>').join('') + '</select></label>' +
        '<label class="ed-f"><span>X (m)</span><input type="number" step="0.5" data-f="x"></label>' +
        '<label class="ed-f"><span>Z (m)</span><input type="number" step="0.5" data-f="z"></label>' +
        '<label class="ed-f"><span>Yaw (°)</span><input type="number" step="5" data-f="yaw"></label>' +
        (flag ? '' : '<label class="ed-f"><span>Height (m)</span><input type="number" step="0.1" min="0" data-f="h"></label>') +
        '</div><p class="note" data-v="note"></p>' +
        '<div class="ed-row"><button class="btn" type="button" data-a="earlier">Earlier</button><button class="btn" type="button" data-a="later">Later</button>' +
        '<button class="btn" type="button" data-a="ungroup" data-v="ungroup">Ungroup</button></div>';
    } else {
      box.innerHTML = '<p class="ed-selhead"><strong data-v="what"></strong> <span class="note" data-v="sub"></span></p><div class="ed-form">' +
        '<label class="ed-f wide"><span>Kind</span><select data-f="k">' + KINDS.slice(1).map((n, i) => '<option value="' + (i + 1) + '">' + n + '</option>').join('') + '</select></label>' +
        '<label class="ed-f"><span>X (m)</span><input type="number" step="0.5" data-f="x"></label>' +
        '<label class="ed-f"><span>Z (m)</span><input type="number" step="0.5" data-f="z"></label>' +
        '<label class="ed-f"><span>Width X (m)</span><input type="number" step="0.5" min="0.1" data-f="w"></label>' +
        '<label class="ed-f"><span>Depth Z (m)</span><input type="number" step="0.5" min="0.1" data-f="d"></label>' +
        '<label class="ed-f"><span>Bottom (m)</span><input type="number" step="0.1" min="0" data-f="y0"></label>' +
        '<label class="ed-f"><span>Top (m)</span><input type="number" step="0.1" min="0.1" data-f="y1"></label>' +
        '</div><p class="note">X and Z are its middle. A bottom above 0 makes a lintel or a roof to fly under.</p>' +
        '<div class="ed-row"><button class="btn" type="button" data-a="ungroup" data-v="ungroup">Ungroup</button></div>';
    }
  }
  function fillSel(s, f, one) {
    const box = el.edSel;
    const v = (name) => box.querySelector('[data-v="' + name + '"]');
    const field = (name, val) => { const i = box.querySelector('[data-f="' + name + '"]'); if (i) setVal(i, val); };
    if (s.all.length && !one) {
      const parts = [];
      if (s.gates.length) parts.push(s.gates.length + (s.gates.length === 1 ? ' gate' : ' gates'));
      if (s.boxes.length) parts.push(s.boxes.length + (s.boxes.length === 1 ? ' structure' : ' structures'));
      v('what').textContent = parts.join(', ') + ' selected';
      box.querySelector('[data-a="group"]').disabled = s.all.length < 2 || (s.all[0].g && s.all.every((o) => o.g === s.all[0].g));
      box.querySelector('[data-a="ungroup"]').disabled = !s.all.some((o) => o.g);
    } else if (one) {
      const it = f.it, grouped = selected().all.length > 1;
      if (f.kind === 'gate') {
        v('what').textContent = 'Gate ' + (f.i + 1);
        v('sub').textContent = 'of ' + ed.T.gates.length + (grouped ? ' · in a group' : '');
        field('t', it.t); field('x', dec(it.x)); field('z', dec(it.z)); field('yaw', it.yaw); field('h', dec(it.h));
        const turnsWithBoxes = grouped && selected().boxes.length > 0;
        const yawIn = box.querySelector('[data-f="yaw"]');
        yawIn.disabled = turnsWithBoxes;
        let note = it.t === 6 || it.t === 7
          ? 'X and Z are the pole; you pass ' + (it.t === 6 ? 'right' : 'left') + ' of it, through the 12 m beside it.'
          : 'Height 0 is the type\'s own: ' + dec(it.t === 5 ? 0 : GCY[it.t]) + ' m to the middle of the opening.';
        if (it.t === 3) note += ' Flown down through.';
        if (turnsWithBoxes) note += ' It turns with its group: R or the turn buttons.';
        v('note').textContent = note + ' Yaw 0 goes up the map, 90 to the right.';
        box.querySelector('[data-a="earlier"]').disabled = f.i === 0;
        box.querySelector('[data-a="later"]').disabled = f.i === ed.T.gates.length - 1;
      } else {
        v('what').textContent = 'Structure ' + (f.i + 1);
        v('sub').textContent = 'of ' + ed.T.boxes.length + (grouped ? ' · in a group' : '');
        field('k', it.k); field('x', dec(it.x)); field('z', dec(it.z)); field('w', dec(2 * it.hx)); field('d', dec(2 * it.hz));
        field('y0', dec(it.y0)); field('y1', dec(it.y1));
      }
      const ug = v('ungroup');
      if (ug) ug.hidden = !grouped;
    }
  }
  function applyField(f, key, val) {
    const it = f.it;
    if (key === 'x' || key === 'z') {
      // the whole group moves with it
      const d = r2(clamp(val, -999, 999)) - it[key];
      for (const o of items()) if (o === it || (it.g && o.g === it.g && ed.sel.has(o.id))) o[key] = pos(o[key] + d);
    } else if (f.kind === 'gate') {
      if (key === 't') it.t = clamp(Math.round(val), 1, 8);
      else if (key === 'yaw') it.yaw = normYaw(val);
      else if (key === 'h') it.h = r2(clamp(val, 0, 100));
    } else if (key === 'k') it.k = clamp(Math.round(val), 1, 3);
    else if (key === 'w') it.hx = r2(clamp(val, 0.1, 400) / 2);
    else if (key === 'd') it.hz = r2(clamp(val, 0.1, 400) / 2);
    else if (key === 'y0') { it.y0 = r2(clamp(val, 0, 200)); if (it.y1 < it.y0 + 0.1) it.y1 = r2(it.y0 + 0.1); }
    else if (key === 'y1') { it.y1 = r2(clamp(val, 0.1, 300)); if (it.y0 > it.y1 - 0.1) it.y0 = Math.max(0, r2(it.y1 - 0.1)); }
  }

  let probSig = null;
  function renderProblems() {
    const sig = ed.probs.map((p) => p.msg).join('|');
    if (sig === probSig) return;
    probSig = sig;
    const n = ed.probs.length;
    el.edProbPill.textContent = n ? n + (n === 1 ? ' problem' : ' problems') : 'OK';
    el.edProbPill.className = 'pill ' + (n ? 'bad' : 'ok');
    keepFocus(el.edProblems, () => {
      el.edProblems.innerHTML = n
        ? ed.probs.map((p, i) => '<li>' + (p.ids.length ? '<button type="button" data-prob="' + i + '">' + esc(p.msg) + '</button>' : '<span>' + esc(p.msg) + '</span>') + '</li>').join('')
        : '<li class="ok"><span>Ready to fly: the game takes this track as it is.</span></li>';
    });
  }

  let orderSig = null;
  function renderOrder() {
    const T = ed.T;
    const sig = T.gates.map((g) => g.id + ':' + g.t + (ed.sel.has(g.id) ? 's' : '') + (ed.bad.has(g.id) ? 'b' : '')).join(',');
    if (sig === orderSig) return;
    orderSig = sig;
    const n = T.gates.length;
    keepFocus(el.edOrder, () => { el.edOrder.innerHTML = T.gates.map((g, i) =>
      '<li class="' + (ed.sel.has(g.id) ? 'sel' : '') + (ed.bad.has(g.id) ? ' bad' : '') + '">' +
      '<button type="button" class="ed-oname" data-pick="' + g.id + '"><b>' + (i + 1) + '</b>' + TYPES[g.t] + '</button>' +
      '<button type="button" class="ed-mini" data-move="' + i + ',-1"' + (i === 0 ? ' disabled' : '') + ' aria-label="Gate ' + (i + 1) + ' earlier" title="Earlier">' + UP + '</button>' +
      '<button type="button" class="ed-mini" data-move="' + i + ',1"' + (i === n - 1 ? ' disabled' : '') + ' aria-label="Gate ' + (i + 1) + ' later" title="Later">' + DOWN + '</button></li>').join(''); });
  }

  function renderFly() {
    const bad = ed.probs.length > 0, inSlot = asEntry(emuSlot(ed.slot));
    el.edSendEmu.disabled = bad;
    el.edSave.disabled = bad;
    el.edSendEmu.title = bad ? 'Fix the problems listed under Check first' : 'Put it in slot c' + ed.slot + ' of the emulator\'s SD card (track ' + (8 + ed.slot) + ')';
    el.edFlyText.textContent = 'Fly c' + ed.slot;
    el.edFly.disabled = !inSlot || !!inSlot.bad;
    el.edFly.title = !inSlot ? 'c' + ed.slot + ' of the emulator is empty: Send to emulator first' : inSlot.bad ? 'c' + ed.slot + ' of the emulator can\'t be read'
      : 'Fly c' + ed.slot + ' of the emulator in Practice (track ' + (8 + ed.slot) + '), as it is there';
    el.edSave.title = bad ? 'Fix the problems listed under Check first' : 'Download c' + ed.slot + '.txt for the radio\'s SD card';
    el.edSize.textContent = 'c' + ed.slot + '.txt · ' + ed.file.bytes + ' of ' + MAX_BYTES + ' bytes · id ' + ed.file.id;
    renderEditing();
    el.edSize.classList.toggle('bad', ed.file.bytes > MAX_BYTES);
    const c = 'c' + ed.slot;
    el.edEmuHas.textContent = c + ': ' + holds(inSlot);
    el.edEmuHas.classList.toggle('warn', stale(inSlot));
    el.edFileHas.textContent = c + '.txt, to copy to ' + DIR + ' on the radio\'s SD card yourself';
    const s = sim(), a = s && s.app;
    const lite = !!(a && !a.custom && a.script === 'lite');
    el.edLite.hidden = !(lite || (a && a.custom));
    el.edLite.textContent = lite
      ? 'StickTime Lite doesn\'t read custom tracks (its radios have no memory to spare): Fly switches the script to Auto.'
      : a && a.custom ? a.custom.name + ' is running: Fly switches back to StickTime.' : '';
    renderRadio();
  }
  // The editor works on its own copy of a track; the slots are what the game plays. The head says
  // which track this is and whether a slot has it as it is, an earlier version, or not at all.
  function renderEditing() {
    const h = homes(ed.file.text), name = ed.T.name.trim() || '(no name)';
    const at = (l, where) => (l.length ? cs(l) + ' ' + where : '');
    const both = h.here.filter((i) => h.there.includes(i));
    let say, kind;
    if (h.here.length || h.there.length) {
      const parts = both.length ? [at(both, 'in the emulator and on the radio')]
        : [at(h.here, 'in the emulator'), at(h.there, 'on the radio')].filter(Boolean);
      say = 'the same as ' + parts.join(' and ');
      kind = 'ok';
    } else {
      const low = name.slice(0, 16).toLowerCase(), earlier = [];
      for (let i = 1; i <= SLOTS; i++) {
        const t = emuSlot(i), e = radioRead() ? radioSlots[i - 1] : null;
        if ((t !== null && nameOf(t).toLowerCase() === low) || (e && !e.bad && nameOf(e.text).toLowerCase() === low)) earlier.push(i);
      }
      say = earlier.length ? 'changed, not sent yet (' + cs(earlier) + ' has the earlier version)' : 'in no slot yet';
      kind = 'warn';
    }
    el.edEditing.innerHTML = 'Editing a local copy of <b>' + esc(name) + '</b> (kept in this browser as you edit): <span class="' + kind + '">' + esc(say) + '</span>';
  }
  // what a slot holds (an entry as asEntry has it), said for the editor's track: this track, another
  // version of it (the same name), another track, nothing, or a file the game can't use
  function holds(e) {
    if (!e) return 'empty';
    if (e.bad) return BAD[e.bad];
    if (norm(e.text) === ed.file.text) return 'this track';
    return '"' + nameOf(e.text) + '"' + (stale(e) ? ', not the version you are editing' : '');
  }
  // a slot with the edited track's name, other numbers: not what is in the editor (changes not sent)
  const stale = (e) => !!(e && !e.bad && norm(e.text) !== ed.file.text && nameOf(e.text).toLowerCase() === ed.T.name.trim().slice(0, 16).toLowerCase());
  // the slot list: what each slot holds, in the emulator and (connected, its slots read) on the radio
  let slotsHtml = '';
  function renderSlots() {
    const rad = radioRead() ? radioSlots : null;
    let h = '';
    for (let i = 1; i <= SLOTS; i++) {
      const n = slotName(i), t = emuSlot(i), e = rad && rad[i - 1];
      const rn = !e ? null : e.bad ? BAD[e.bad] : nameOf(e.text);
      const what = !rad ? (n || 'empty') : n === null && rn === null ? 'empty'
        : n !== null && e && !e.bad && norm(t) === norm(e.text) ? n + ' (emulator and radio)'
          : rn === null ? n + ' (emulator only)' : n === null ? rn + ' (radio only)' : 'emulator: ' + n + ', radio: ' + rn;
      h += '<option value="' + i + '">c' + i + ' · track ' + (8 + i) + ' · ' + esc(what) + '</option>';
    }
    if (h !== slotsHtml) { slotsHtml = h; el.edSlot.innerHTML = h; }
    el.edSlot.value = String(ed.slot);
    if (ed.T) renderFly();
    if (gal.open) renderGallery();
    if (gal.mine) renderMine();
  }
  function renderButtons() {
    const s = selected(), n = s.all.length, T = ed.T;
    el.edRotL.disabled = el.edRotR.disabled = el.edDel.disabled = !n;
    el.edDup.disabled = !n || T.gates.length + s.gates.length > MAX_GATES || T.boxes.length + s.boxes.length > MAX_BOXES;
    el.edUndo.disabled = !ed.undo.length;
    el.edRedo.disabled = !ed.redo.length;
    el.edAddGate.disabled = T.gates.length >= MAX_GATES;
    el.edAddBox.disabled = T.boxes.length >= MAX_BOXES;
    el.edAddWall.disabled = T.gates.length >= MAX_GATES || T.boxes.length > MAX_BOXES - 3;
  }

  // ---------------------------------------------------------------- edits
  function insertAt() {
    const s = selected().gates;
    return s.length ? Math.max(...s.map((g) => ed.T.gates.indexOf(g))) + 1 : ed.T.gates.length;
  }
  // a new gate after the selected one (or the last): half way to the next, or 20 m on
  function addGate() {
    const T = ed.T;
    if (T.gates.length >= MAX_GATES) return;
    const t = clamp(parseInt(el.edGateType.value, 10) || 1, 1, 8), at = insertAt();
    let x = V.x, z = V.z, yaw = 0;
    const a = T.gates[at - 1], b = T.gates[at];
    if (a && b) {
      const A = gateGeom(a), B = gateGeom(b);
      x = (A.ax + B.ax) / 2; z = (A.az + B.az) / 2;
      yaw = Math.atan2(B.ax - A.ax, B.az - A.az) / D2R;
    } else if (a) {
      const A = gateGeom(a);
      x = a.x + A.hx * 20; z = a.z + A.hz * 20; yaw = a.yaw;
    }
    pushUndo();
    const g = { id: ed.nextId++, g: 0, x: pos(snapTo(x, GRID)), z: pos(snapTo(z, GRID)), t, yaw: normYaw(snapTo(yaw, 5)), h: 0 };
    T.gates.splice(at, 0, g);
    setSel([g.id], g.id);
    changed();
    reveal(g.x, g.z);
  }
  function addBox() {
    if (ed.T.boxes.length >= MAX_BOXES) return;
    pushUndo();
    const b = { id: ed.nextId++, g: 0, x: pos(snapTo(V.x - 2, GRID) + 2), z: pos(snapTo(V.z - 2, GRID) + 2), hx: 2, hz: 2, y0: 0, y1: 4, k: 1 };
    ed.T.boxes.push(b);
    setSel([b.id], b.id);
    changed();
  }
  // a wall with a gap: a gap gate (type 8) with a wall each side and a lintel over it, a group
  function addWall() {
    const T = ed.T;
    if (T.gates.length >= MAX_GATES || T.boxes.length > MAX_BOXES - 3) return;
    pushUndo();
    const cx = r2(clamp(snapTo(V.x, GRID), -990, 990)), cz = r2(clamp(snapTo(V.z, GRID), -990, 990)), g = ed.nextGroup++;
    const iw = GHW[8], open = 2 * GHH[8], top = 7, side = 4, th = 0.25;
    const gate = { id: ed.nextId++, g, x: cx, z: cz, t: 8, yaw: 0, h: GHH[8] };
    const mk = (x, hx, y0) => ({ id: ed.nextId++, g, x: r2(x), z: cz, hx: r2(hx), hz: th, y0: r2(y0), y1: top, k: 1 });
    const walls = [mk(cx - iw - side, side, 0), mk(cx + iw + side, side, 0), mk(cx, iw, open)];
    T.gates.splice(insertAt(), 0, gate);
    T.boxes.push(...walls);
    setSel([gate.id, ...walls.map((b) => b.id)], gate.id);
    changed();
  }
  function deleteSel() {
    if (!ed.sel.size) return;
    pushUndo();
    ed.T.gates = ed.T.gates.filter((g) => !ed.sel.has(g.id));
    ed.T.boxes = ed.T.boxes.filter((b) => !ed.sel.has(b.id));
    setSel([]);
    changed();
  }
  function boundsOf(list) {
    const b = { x0: Infinity, x1: -Infinity, z0: Infinity, z1: -Infinity };
    for (const o of list) {
      const r = o.hx !== undefined ? bbOf(o) : gateGeom(o).box;
      b.x0 = Math.min(b.x0, r.x0); b.x1 = Math.max(b.x1, r.x1); b.z0 = Math.min(b.z0, r.z0); b.z1 = Math.max(b.z1, r.z1);
    }
    return b;
  }
  // R: a gate turns 15° on its spot; with structures in it, the selection turns 90° (they stay
  // square to the axes) round its gap gate or its middle
  function rotateSel(dir) {
    const s = selected();
    if (!s.all.length) return;
    pushUndo();
    if (s.all.length === 1 && s.gates.length === 1) {
      s.gates[0].yaw = normYaw(s.gates[0].yaw + 15 * dir);
      changed();
      return;
    }
    const quarter = s.boxes.length > 0, step = quarter ? 90 : 15;
    let px, pz;
    if (s.gates.length === 1) { px = s.gates[0].x; pz = s.gates[0].z; }
    else { const b = boundsOf(s.all); px = snapTo((b.x0 + b.x1) / 2, GRID); pz = snapTo((b.z0 + b.z1) / 2, GRID); }
    const c = quarter ? 0 : Math.cos(step * dir * D2R), sn = quarter ? dir : Math.sin(step * dir * D2R);
    for (const o of s.all) {
      const dx = o.x - px, dz = o.z - pz;
      o.x = pos(px + dx * c + dz * sn);
      o.z = pos(pz - dx * sn + dz * c);
    }
    for (const g of s.gates) g.yaw = normYaw(g.yaw + step * dir);
    if (quarter) for (const b of s.boxes) [b.hx, b.hz] = [b.hz, b.hx];
    changed();
  }
  // a copy beside the selection (its gates go after the last selected one in the race)
  function duplicate() {
    const s = selected(), T = ed.T;
    if (!s.all.length) return;
    if (T.gates.length + s.gates.length > MAX_GATES || T.boxes.length + s.boxes.length > MAX_BOXES) {
      status('No room for a copy: ' + MAX_GATES + ' gates and ' + MAX_BOXES + ' structures at most.', 'bad');
      return;
    }
    pushUndo();
    const b = boundsOf(s.all), off = snapTo(b.x1 - b.x0, GRID) + 2, groups = new Map(), ids = [];
    const copy = (o) => {
      const c = Object.assign({}, o, { id: ed.nextId++, x: pos(o.x + off) });
      if (o.g) { if (!groups.has(o.g)) groups.set(o.g, ed.nextGroup++); c.g = groups.get(o.g); }
      ids.push(c.id);
      return c;
    };
    const ng = s.gates.map(copy), nb = s.boxes.map(copy);
    if (ng.length) T.gates.splice(insertAt(), 0, ...ng);
    T.boxes.push(...nb);
    setSel(ids, ids[0]);
    changed();
  }
  let nudgeT = 0;
  function nudge(dx, dz) {
    const s = selected().all;
    if (!s.length) return;
    const now = performance.now();
    if (now - nudgeT > 1000) pushUndo();             // a run of nudges is one undo step
    nudgeT = now;
    for (const o of s) { o.x = pos(o.x + dx); o.z = pos(o.z + dz); }
    changed();
  }
  function moveGate(i, d) {
    const G = ed.T.gates, j = i + d;
    if (j < 0 || j >= G.length) return false;
    pushUndo();
    [G[i], G[j]] = [G[j], G[i]];
    changed();
    return true;
  }
  function setGroup(on) {
    const s = selected().all;
    if (on ? s.length < 2 : !s.some((o) => o.g)) return;
    pushUndo();
    const g = on ? ed.nextGroup++ : 0;
    for (const o of s) o.g = g;
    changed();
  }
  function load(T, infer, unsure) {
    ed.T = withIds(T);
    ed.picked = false;                                 // (no slot picked for it yet)
    if (infer) inferGroups(ed.T);
    setSel([]);
    ed.hover = null;
    changed();
    ed.pristine = unsure ? '' : ed.file.text;          // (a stored work in progress may be unsaved)
  }
  // the track would be lost: changed since it came, and in no slot and no saved file (a slot's
  // file with CR LF line ends is the same track)
  function unsaved() {
    const t = ed.file.text;
    if (t === ed.pristine || ed.saved.has(t)) return false;
    for (let i = 1; i <= SLOTS; i++) { const f = emuSlot(i); if (f !== null && f.replace(/\r\n?/g, '\n') === t) return false; }
    return true;
  }
  function okToReplace(what) {
    return !unsaved() || window.confirm('Replace "' + ed.T.name.trim() + '" with ' + what + '? Your track isn\'t in a slot or a saved file ' +
      'yet (Send to emulator, Send to radio or Save file keeps it), and undo goes only as far back as this visit.');
  }

  // ---------------------------------------------------------------- map view
  let W = 0, H = 0, DPR = 1, raf = 0;
  const sx = (x) => W / 2 + (x - V.x) * V.s;
  const sy = (z) => H / 2 - (z - V.z) * V.s;
  const wx = (px) => V.x + (px - W / 2) / V.s;
  const wz = (py) => V.z - (py - H / 2) / V.s;
  function resize() {
    const r = el.edMapBox.getBoundingClientRect();
    const w = Math.round(r.width), h = Math.round(r.height), d = window.devicePixelRatio || 1;
    if (w === W && h === H && d === DPR) return;
    W = w; H = h; DPR = d;
    cv.width = Math.max(1, Math.round(W * d));
    cv.height = Math.max(1, Math.round(H * d));
    if (ed.open && W && H && !ed.fitted) { ed.fitted = true; if (!ed.hadView) fit(); }
    redraw();
  }
  function sceneBounds() {
    const T = ed.T, b = boundsOf(T.gates.concat(T.boxes));
    for (const g of ed.G) {
      if (g.k === 6 || g.k === 7) {
        // the pass zone reaches 2 * iw from the pole
        b.x0 = Math.min(b.x0, g.x - g.iw); b.x1 = Math.max(b.x1, g.x + g.iw); b.z0 = Math.min(b.z0, g.z - g.iw); b.z1 = Math.max(b.z1, g.z + g.iw);
      }
    }
    if (ed.pad) { b.x0 = Math.min(b.x0, ed.pad.x - 2); b.x1 = Math.max(b.x1, ed.pad.x + 2); b.z0 = Math.min(b.z0, ed.pad.z - 2); b.z1 = Math.max(b.z1, ed.pad.z + 2); }
    if (!(b.x1 >= b.x0)) return { x0: -20, x1: 20, z0: -20, z1: 20 };
    return b;
  }
  function fit() {
    if (!W || !H) return;
    const b = sceneBounds(), m = 10;
    V.s = clamp(Math.min(W / (b.x1 - b.x0 + 2 * m), H / (b.z1 - b.z0 + 2 * m)), SMIN, SMAX);
    V.x = (b.x0 + b.x1) / 2;
    V.z = (b.z0 + b.z1) / 2;
    redraw();
    saveSoon();
  }
  function reveal(x, z) {
    const px = sx(x), py = sy(z), m = 50;
    if (px < m || px > W - m || py < m || py > H - m) { V.x = x; V.z = z; redraw(); }
  }
  function zoomAt(px, py, k) {
    const x = wx(px), z = wz(py);
    V.s = clamp(V.s * k, SMIN, SMAX);
    V.x = x - (px - W / 2) / V.s;
    V.z = z + (py - H / 2) / V.s;
    redraw();
    saveSoon();
  }
  const redraw = () => { if (!raf) raf = requestAnimationFrame(draw); };

  // ---------------------------------------------------------------- drawing
  // the field is the cutting mat of the page (the same in both themes); the items in the game's colors
  const C = {
    gate: '#eceef4', edge: 'rgba(24,27,36,.92)', pole: '#46485a', cloth: '#e22830', zone: 'rgba(255,214,64,.9)',
    pad: '#ff8c14', line: 'rgba(255,255,255,.6)', bad: '#ff5f5f', ink: 'rgba(238,246,240,.62)',
    box: ['', '#cac5bb', '#ce4835', '#3c6ebb'], boxInk: ['', '#2a2722', '#fff3ef', '#eef4ff'],
    tree: 'rgba(52,112,52,.88)', treeEdge: 'rgba(16,44,22,.9)',
  };
  const FONT = '600 11px "IBM Plex Mono", ui-monospace, monospace';
  const FONT_S = '500 10px "IBM Plex Mono", ui-monospace, monospace';
  const cssVar = (n, d) => getComputedStyle(root).getPropertyValue(n).trim() || d;
  let ACC = '#ff7f2a';

  function draw() {
    raf = 0;
    if (!ed.open || !W || !H) return;
    ACC = cssVar('--accent', '#ff7f2a');
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.fillStyle = cssVar('--mat', '#2b5a4e');
    ctx.fillRect(0, 0, W, H);
    drawGrid();
    if (ed.showTrees) {
      if (!ed.trees) ed.trees = treesOf(ed.T, ed.G, ed.pad);
      drawTrees();
    }
    drawBoxes();
    drawRace();
    drawPad();
    ed.T.gates.forEach((g, i) => drawGate(g, ed.G[i], i));
    drawHandles();
    drawWind();
    drawScale();
  }
  function drawGrid() {
    const steps = [[1, 5], [2, 10], [5, 25], [10, 50], [25, 100], [50, 250], [100, 500]];
    const st = steps.find((s) => s[0] * V.s >= 11) || steps[steps.length - 1];
    const x0 = wx(0), x1 = wx(W), z0 = wz(H), z1 = wz(0);
    const lines = (color, step, width) => {
      ctx.strokeStyle = color; ctx.lineWidth = width; ctx.beginPath();
      for (let k = Math.ceil(x0 / step); k * step <= x1; k++) { const p = Math.round(sx(k * step)) + 0.5; ctx.moveTo(p, 0); ctx.lineTo(p, H); }
      for (let k = Math.ceil(z0 / step); k * step <= z1; k++) { const p = Math.round(sy(k * step)) + 0.5; ctx.moveTo(0, p); ctx.lineTo(W, p); }
      ctx.stroke();
    };
    lines(cssVar('--mat-line', 'rgba(238,246,240,.075)'), st[0], 1);
    lines(cssVar('--mat-line-strong', 'rgba(238,246,240,.16)'), st[1], 1);
    // the axes through 0, 0
    ctx.strokeStyle = 'rgba(238,246,240,.3)'; ctx.beginPath();
    const ox = Math.round(sx(0)) + 0.5, oz = Math.round(sy(0)) + 0.5;
    ctx.moveTo(ox, 0); ctx.lineTo(ox, H); ctx.moveTo(0, oz); ctx.lineTo(W, oz); ctx.stroke();
    // metres along the top and the left edge
    ctx.font = FONT_S; ctx.fillStyle = C.ink; ctx.textBaseline = 'top'; ctx.textAlign = 'left';
    for (let k = Math.ceil(x0 / st[1]); k * st[1] <= x1; k++) { const p = sx(k * st[1]); if (p > 30 && p < W - 30) ctx.fillText(String(k * st[1]), p + 3, 4); }
    ctx.textBaseline = 'bottom';
    for (let k = Math.ceil(z0 / st[1]); k * st[1] <= z1; k++) { const p = sy(k * st[1]); if (p > 30 && p < H - 24) ctx.fillText(String(k * st[1]), 4, p - 2); }
  }
  function drawTrees() {
    for (const t of ed.trees) {
      const r = Math.max(t.h * 0.25 * V.s, 2.5);
      ctx.fillStyle = C.tree; ctx.strokeStyle = C.treeEdge; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.arc(sx(t.x), sy(t.z), r, 0, 7); ctx.fill(); ctx.stroke();
      ctx.fillStyle = 'rgba(96,64,40,.95)';
      ctx.beginPath(); ctx.arc(sx(t.x), sy(t.z), Math.max(t.h * 0.03 * V.s, 1), 0, 7); ctx.fill();
    }
  }
  function drawBoxes() {
    const T = ed.T;
    // low ones first: from above, a taller one covers a lower one
    const order = T.boxes.map((b, i) => i).sort((a, b) => T.boxes[a].y1 - T.boxes[b].y1);
    for (const i of order) {
      const b = T.boxes[i];
      let X = sx(b.x - b.hx), Y = sy(b.z + b.hz), w = 2 * b.hx * V.s, h = 2 * b.hz * V.s;
      if (w < 3) { X -= (3 - w) / 2; w = 3; }          // a thin wall stays visible zoomed out
      if (h < 3) { Y -= (3 - h) / 2; h = 3; }
      const raised = b.y0 > 0.05;
      ctx.globalAlpha = raised ? 0.62 : 1;             // a lintel or a roof: what is under it shows
      ctx.fillStyle = C.box[b.k] || C.box[1];
      ctx.fillRect(X, Y, w, h);
      ctx.globalAlpha = 1;
      ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(20,22,26,.8)';
      ctx.setLineDash(raised ? [4, 3] : []);
      ctx.strokeRect(X + 0.5, Y + 0.5, Math.max(0, w - 1), Math.max(0, h - 1));
      ctx.setLineDash([]);
      const bad = ed.bad.has(b.id), sel = ed.sel.has(b.id);
      if (bad || sel || ed.hover === b.id) {
        ctx.lineWidth = 2;
        ctx.strokeStyle = sel ? ACC : bad ? C.bad : 'rgba(255,255,255,.7)';
        ctx.setLineDash(bad && !sel ? [5, 3] : []);
        ctx.strokeRect(X - 1, Y - 1, w + 2, h + 2);
        ctx.setLineDash([]);
        if (bad && sel) { ctx.strokeStyle = C.bad; ctx.setLineDash([5, 3]); ctx.strokeRect(X - 3, Y - 3, w + 6, h + 6); ctx.setLineDash([]); }
      }
      if (w >= 34 && h >= 16) {
        ctx.fillStyle = C.boxInk[b.k] || '#000'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
        const two = h >= 30;
        ctx.font = FONT; ctx.fillText('S' + (i + 1), X + w / 2, Y + h / 2 - (two ? 6 : 0));
        if (two) { ctx.font = FONT_S; ctx.fillText((raised ? dec(b.y0) + '-' : '') + dec(b.y1) + ' m', X + w / 2, Y + h / 2 + 7); }
      }
    }
  }
  function arrowHead(x, y, ux, uy, s, color) {
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(x + ux * s, y + uy * s);
    ctx.lineTo(x - ux * s - uy * s * 0.8, y - uy * s + ux * s * 0.8);
    ctx.lineTo(x - ux * s + uy * s * 0.8, y - uy * s - ux * s * 0.8);
    ctx.closePath(); ctx.fill();
  }
  // the race: aim point to aim point, round the lap
  function drawRace() {
    const G = ed.G, n = G.length;
    if (n < 2) return;
    ctx.lineWidth = 1.5; ctx.strokeStyle = C.line;
    for (let i = 0; i < n; i++) {
      const a = G[i], b = G[(i + 1) % n];
      const x0 = sx(a.ax), y0 = sy(a.az), x1 = sx(b.ax), y1 = sy(b.az), l = Math.hypot(x1 - x0, y1 - y0);
      ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); ctx.stroke();
      if (l > 34) arrowHead((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / l, (y1 - y0) / l, 5, C.line);
    }
  }
  function drawPad() {
    const p = ed.pad;
    if (!p) return;
    const g = ed.G[0];
    const X = sx(p.x), Y = sy(p.z);
    ctx.setLineDash([5, 4]); ctx.lineWidth = 1.5; ctx.strokeStyle = 'rgba(255,160,60,.9)';
    ctx.beginPath(); ctx.moveTo(X, Y); ctx.lineTo(sx(g.ax), sy(g.az)); ctx.stroke(); ctx.setLineDash([]);
    // a 3 m pad facing gate 1 (on screen: forward is (hx, -hz))
    const fx = p.hx, fy = -p.hz, rx = -fy, ry = fx, s = Math.max(1.5 * V.s, 7);
    ctx.fillStyle = C.pad; ctx.strokeStyle = '#fafafa'; ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(X + (fx + rx) * s, Y + (fy + ry) * s); ctx.lineTo(X + (fx - rx) * s, Y + (fy - ry) * s);
    ctx.lineTo(X - (fx + rx) * s, Y - (fy + ry) * s); ctx.lineTo(X - (fx - rx) * s, Y - (fy - ry) * s);
    ctx.closePath(); ctx.fill(); ctx.stroke();
    arrowHead(X + fx * s * 0.15, Y + fy * s * 0.15, fx, fy, s * 0.55, '#fafafa');
    ctx.font = '700 10px "Chakra Petch", "Bahnschrift", sans-serif'; ctx.fillStyle = '#ffd2a8';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.strokeStyle = cssVar('--mat', '#2b5a4e'); ctx.lineWidth = 4; ctx.lineJoin = 'round';   // over the grid's numbers
    ctx.strokeText('START', X - fx * (s + 11), Y - fy * (s + 11));
    ctx.lineJoin = 'miter';
    ctx.fillText('START', X - fx * (s + 11), Y - fy * (s + 11));
  }
  function bar(x0, y0, x1, y1, w, color, edge) {
    ctx.lineCap = 'round';
    ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1);
    ctx.strokeStyle = edge; ctx.lineWidth = w + 2; ctx.stroke();
    ctx.strokeStyle = color; ctx.lineWidth = w; ctx.stroke();
    ctx.lineCap = 'butt';
  }
  function dot(x, y, r, color, ring) {
    ctx.beginPath(); ctx.arc(x, y, r, 0, 7);
    ctx.fillStyle = color; ctx.fill();
    if (ring) { ctx.strokeStyle = ring; ctx.lineWidth = 1.2; ctx.stroke(); }
  }
  function chevron(x, y, fx, fy, color) {
    const s = 5;
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(x - fx * s - fy * s, y - fy * s + fx * s); ctx.lineTo(x, y); ctx.lineTo(x - fx * s + fy * s, y - fy * s - fx * s);
    ctx.stroke(); ctx.lineCap = 'butt'; ctx.lineJoin = 'miter';
  }
  // where things sit on screen around a gate (they are also what the pointer can grab)
  function frontPx(g, G) { return g.t === 3 ? (G.ih + GT) * V.s + 12 : Math.max(0.9 * V.s, 12); }
  function badgeAt(i) {
    const g = ed.T.gates[i], G = ed.G[i];
    const back = g.t === 3 ? (G.ih + GT) * V.s + 13 : g.t === 6 || g.t === 7 ? 15 : Math.max(1.7 * V.s, 16);
    return [sx(g.x) - G.hx * back, sy(g.z) + G.hz * back];
  }
  function drawGate(g, G, i) {
    const sel = ed.sel.has(g.id), bad = ed.bad.has(g.id), hov = ed.hover === g.id;
    const col = sel ? ACC : C.gate, edge = bad ? C.bad : C.edge;
    const X = sx(g.x), Y = sy(g.z), S = V.s;
    const rX = G.rx, rY = -G.rz, fX = G.hx, fY = -G.hz;   // right and facing, on screen
    const lw = Math.max(GT * S, 3);
    const k = g.t;
    if (hov && !sel) { ctx.fillStyle = 'rgba(255,255,255,.12)'; ctx.beginPath(); ctx.arc(X, Y, Math.max((G.iw + GT) * S, 10) + 6, 0, 7); ctx.fill(); }
    if (k === 6 || k === 7) {
      const s = k === 6 ? 1 : -1, L = 2 * G.iw * S;
      ctx.setLineDash([6, 5]); ctx.lineWidth = 2; ctx.strokeStyle = sel ? ACC : C.zone;
      ctx.beginPath(); ctx.moveTo(X, Y); ctx.lineTo(X + rX * s * L, Y + rY * s * L); ctx.stroke(); ctx.setLineDash([]);
      const ax = X + rX * s * 2.5 * S, ay = Y + rY * s * 2.5 * S;
      // the cloth hangs on the outer side, away from the pass zone
      const o = Math.max(0.9 * S, 9), hgt = Math.max(0.45 * S, 4.5);
      ctx.fillStyle = bad ? C.bad : C.cloth;
      ctx.beginPath(); ctx.moveTo(X, Y); ctx.lineTo(X - rX * s * o + fX * hgt, Y - rY * s * o + fY * hgt); ctx.lineTo(X - rX * s * o - fX * hgt, Y - rY * s * o - fY * hgt);
      ctx.closePath(); ctx.fill();
      dot(X, Y, Math.max(0.12 * S, 3.5), C.pole, sel ? ACC : '#fafafa');
      chevron(ax + fX * 7, ay + fY * 7, fX, fY, sel ? ACC : C.zone);
    } else if (k === 8) {
      const L = G.iw * S;
      ctx.setLineDash([5, 4]); ctx.lineWidth = 2.5; ctx.strokeStyle = col;
      ctx.beginPath(); ctx.moveTo(X - rX * L, Y - rY * L); ctx.lineTo(X + rX * L, Y + rY * L); ctx.stroke(); ctx.setLineDash([]);
      for (const e of [-1, 1]) bar(X + rX * L * e - fX * 5, Y + rY * L * e - fY * 5, X + rX * L * e + fX * 5, Y + rY * L * e + fY * 5, 2, col, edge);
      chevron(X + fX * frontPx(g, G), Y + fY * frontPx(g, G), fX, fY, col);
    } else if (k === 3) {
      const o = (G.iw + GT * 0.5) * S;
      const c = [[1, 1], [1, -1], [-1, -1], [-1, 1]].map(([a, b]) => [X + rX * o * a + fX * o * b, Y + rY * o * a + fY * o * b]);
      for (let j = 0; j < 4; j++) bar(c[j][0], c[j][1], c[(j + 1) % 4][0], c[(j + 1) % 4][1], lw, col, edge);
      for (const p of c) dot(p[0], p[1], Math.max(GT * 0.5 * S, 2), C.pole);
      // flown down through: a cross in a ring
      const r = Math.max(Math.min(o * 0.45, 9), 4);
      ctx.strokeStyle = col; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.arc(X, Y, r, 0, 7); ctx.moveTo(X - r * 0.7, Y - r * 0.7); ctx.lineTo(X + r * 0.7, Y + r * 0.7);
      ctx.moveTo(X + r * 0.7, Y - r * 0.7); ctx.lineTo(X - r * 0.7, Y + r * 0.7); ctx.stroke();
    } else {
      const o = Math.max((G.iw + GT) * S, 7);          // (zoomed far out it still shows its way)
      bar(X - rX * o, Y - rY * o, X + rX * o, Y + rY * o, lw, col, edge);
      if (k === 2) {
        const l = (G.iw + GT * 0.5) * S;
        for (const e of [-1, 1]) dot(X + rX * l * e, Y + rY * l * e, Math.max(GT * 0.5 * S, 2.2), C.pole, '#fafafa');
      } else if (k === 4) dot(X, Y, Math.max(0.12 * S, 2.2), C.pole, '#fafafa');
      else if (k === 5) for (const e of [-1, 1]) dot(X + rX * o * e, Y + rY * o * e, Math.max(GT * 0.6 * S, 2.6), col, edge);
      chevron(X + fX * frontPx(g, G), Y + fY * frontPx(g, G), fX, fY, col);
    }
    // its place in the race
    const [bx, by] = badgeAt(i);
    dot(bx, by, 8.5, sel ? ACC : bad ? C.bad : 'rgba(14,17,22,.85)', hov || sel ? '#fff' : 'rgba(255,255,255,.75)');
    ctx.font = FONT; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillStyle = sel ? '#1c0c00' : '#fff';
    ctx.fillText(String(i + 1), bx, by + 0.5);
  }
  // the turn handle of a single selected gate, and the size handles of the focused structure
  function turnHandle() {
    if (ed.sel.size !== 1) return null;
    const f = find([...ed.sel][0]);
    if (!f || f.kind !== 'gate') return null;
    const G = ed.G[f.i], d = frontPx(f.it, G) + 26;
    return { x: sx(f.it.x) + G.hx * d, y: sy(f.it.z) - G.hz * d, f };
  }
  function sizeHandles() {
    const f = ed.focus !== null ? find(ed.focus) : null;
    if (!f || f.kind !== 'box' || !selOne()) return [];
    const b = f.it;
    return [['x0', sx(b.x - b.hx), sy(b.z)], ['x1', sx(b.x + b.hx), sy(b.z)], ['z1', sx(b.x), sy(b.z + b.hz)], ['z0', sx(b.x), sy(b.z - b.hz)]];
  }
  function drawHandles() {
    const t = turnHandle();
    if (t) {
      const X = sx(t.f.it.x), Y = sy(t.f.it.z);
      ctx.strokeStyle = ACC; ctx.lineWidth = 1.5; ctx.setLineDash([3, 3]);
      ctx.beginPath(); ctx.moveTo(X, Y); ctx.lineTo(t.x, t.y); ctx.stroke(); ctx.setLineDash([]);
      dot(t.x, t.y, 7, ACC, '#fff');
      ctx.strokeStyle = '#1c0c00'; ctx.lineWidth = 1.4;
      ctx.beginPath(); ctx.arc(t.x, t.y, 3.4, -2.2, 1.6); ctx.stroke();
    }
    for (const [, x, y] of sizeHandles()) {
      ctx.fillStyle = '#fff'; ctx.strokeStyle = ACC; ctx.lineWidth = 2;
      ctx.fillRect(x - 4.5, y - 4.5, 9, 9); ctx.strokeRect(x - 4.5, y - 4.5, 9, 9);
    }
  }
  function drawWind() {
    const w = ed.wind, X = W - 30, Y = 32, r = 15;
    ctx.fillStyle = 'rgba(10,22,18,.45)'; ctx.beginPath(); ctx.arc(X, Y, r + 4, 0, 7); ctx.fill();
    ctx.strokeStyle = 'rgba(238,246,240,.35)'; ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(X, Y, r + 4, 0, 7); ctx.stroke();
    const ux = w.x, uy = -w.z;
    ctx.strokeStyle = '#eef6f0'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(X - ux * r * 0.8, Y - uy * r * 0.8); ctx.lineTo(X + ux * r * 0.35, Y + uy * r * 0.35); ctx.stroke();
    arrowHead(X + ux * r * 0.45, Y + uy * r * 0.45, ux, uy, 6, '#eef6f0');
    ctx.font = FONT_S; ctx.fillStyle = C.ink; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    ctx.fillText('wind', X, Y + r + 7);
  }
  function drawScale() {
    const L = [1, 2, 5, 10, 20, 50, 100, 200, 500].find((v) => v * V.s >= 48) || 500;
    const w = L * V.s, X = 12, Y = H - 14;
    ctx.strokeStyle = '#eef6f0'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(X, Y - 4); ctx.lineTo(X, Y); ctx.lineTo(X + w, Y); ctx.lineTo(X + w, Y - 4); ctx.stroke();
    ctx.font = FONT_S; ctx.fillStyle = '#eef6f0'; ctx.textAlign = 'left'; ctx.textBaseline = 'bottom';
    ctx.fillText(L + ' m', X + 4, Y - 4);
  }

  // ---------------------------------------------------------------- pointer
  function hitGate(i, x, z, tol) {
    const g = ed.T.gates[i], G = ed.G[i];
    const dx = x - g.x, dz = z - g.z;
    const lr = dx * G.rx + dz * G.rz, lf = dx * G.hx + dz * G.hz;
    if (g.t === 6 || g.t === 7) {
      if (Math.hypot(dx, dz) < 1 + tol) return true;
      const a = lr * (g.t === 6 ? 1 : -1);
      return a > 0 && a < 2 * G.iw && Math.abs(lf) < 0.5 + tol;
    }
    const hw = g.t === 8 ? G.iw : G.iw + GT, hd = g.t === 3 ? G.ih + GT : 0.6;
    return Math.abs(lr) < hw + tol && Math.abs(lf) < hd + tol;
  }
  function hit(px, py, tolPx) {
    const t = turnHandle();
    if (t && Math.hypot(px - t.x, py - t.y) <= 9 + tolPx) return { id: t.f.it.id, handle: 'turn' };
    for (const [e, hx, hy] of sizeHandles()) if (Math.abs(px - hx) <= 6 + tolPx && Math.abs(py - hy) <= 6 + tolPx) return { id: ed.focus, handle: 'size', edge: e };
    const T = ed.T, x = wx(px), z = wz(py), tol = tolPx / V.s;
    for (let i = T.gates.length - 1; i >= 0; i--) {
      const [bx, by] = badgeAt(i);
      if (Math.hypot(px - bx, py - by) <= 9 + tolPx * 0.5) return { id: T.gates[i].id };
    }
    for (let i = T.gates.length - 1; i >= 0; i--) if (hitGate(i, x, z, tol)) return { id: T.gates[i].id };
    const order = T.boxes.slice().sort((a, b) => b.y1 - a.y1);
    for (const b of order) {
      if (x >= b.x - b.hx - tol && x <= b.x + b.hx + tol && z >= b.z - b.hz - tol && z <= b.z + b.hz + tol) return { id: b.id };
    }
    return null;
  }
  const ptrs = new Map();
  let drag = null;
  function local(e) {
    const r = cv.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }
  function startPinch() {
    const [a, b] = [...ptrs.values()];
    const m = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    drag = { mode: 'pinch', d0: Math.max(10, Math.hypot(a.x - b.x, a.y - b.y)), s0: V.s, x: wx(m.x), z: wz(m.y) };
  }
  function endDrag() {
    if (drag && drag.moved && drag.mode !== 'pan') changed();
    drag = null;
    el.edProblems.setAttribute('aria-live', 'polite');  // (quiet while dragging: say it once, at the end)
  }
  cv.addEventListener('pointerdown', (e) => {
    e.preventDefault();                                // no text selection on the page while dragging
    cv.focus({ preventScroll: true });
    const p = local(e);
    ptrs.set(e.pointerId, p);
    try { cv.setPointerCapture(e.pointerId); } catch (err) { /* (a synthetic event) */ }
    if (ptrs.size === 2) { endDrag(); startPinch(); return; }
    if (ptrs.size > 2) return;
    const tolPx = e.pointerType === 'touch' ? 10 : 4;
    const pan = { mode: 'pan', px: p.x, py: p.y, x: V.x, z: V.z, moved: false, clear: !e.shiftKey };
    if (e.button === 1 || e.button === 2) { drag = Object.assign(pan, { clear: false }); return; }
    const h = hit(p.x, p.y, tolPx);
    if (!h) { drag = pan; return; }
    if (h.handle) { drag = { mode: h.handle, id: h.id, edge: h.edge, px: p.x, py: p.y, moved: false }; return; }
    if (e.shiftKey) {
      // Shift+click: add to or take from the selection (a group as a whole)
      const ids = groupOf(h.id);
      if (ed.sel.has(h.id)) ids.forEach((id) => ed.sel.delete(id)); else ids.forEach((id) => ed.sel.add(id));
      ed.focus = ed.sel.has(h.id) ? h.id : (ed.sel.size ? [...ed.sel][0] : null);
      refresh();
      drag = null;
      return;
    }
    if (!ed.sel.has(h.id)) setSel(groupOf(h.id), h.id); else ed.focus = h.id;
    refresh();
    const f = find(h.id);
    const orig = new Map(selected().all.map((o) => [o.id, { x: o.x, z: o.z }]));
    // the grabbed item snaps: a gate by its middle, a structure by its corner
    const ax = f.kind === 'box' ? f.it.x - f.it.hx : f.it.x, az = f.kind === 'box' ? f.it.z - f.it.hz : f.it.z;
    drag = { mode: 'move', px: p.x, py: p.y, x: wx(p.x), z: wz(p.y), ax, az, orig, moved: false };
  });
  cv.addEventListener('pointermove', (e) => {
    const p = local(e);
    if (ptrs.has(e.pointerId)) ptrs.set(e.pointerId, p);
    if (drag && drag.mode === 'pinch') {
      if (ptrs.size < 2) return;
      const [a, b] = [...ptrs.values()];
      const m = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      V.s = clamp(drag.s0 * Math.hypot(a.x - b.x, a.y - b.y) / drag.d0, SMIN, SMAX);
      V.x = drag.x - (m.x - W / 2) / V.s;
      V.z = drag.z + (m.y - H / 2) / V.s;
      redraw();
      return;
    }
    if (!drag) {
      const h = ptrs.size ? null : hit(p.x, p.y, 4);
      const id = h && !h.handle ? h.id : null;
      cv.style.cursor = !h ? 'grab' : h.handle === 'size' ? (h.edge[0] === 'x' ? 'ew-resize' : 'ns-resize') : h.handle === 'turn' ? 'crosshair' : 'move';
      if (id !== ed.hover) { ed.hover = id; redraw(); }
      el.edReadout.textContent = 'x ' + wx(p.x).toFixed(1) + '  z ' + wz(p.y).toFixed(1) + ' m';
      return;
    }
    if (!drag.moved && Math.hypot(p.x - drag.px, p.y - drag.py) < 4) return;
    if (drag.mode === 'pan') {
      drag.moved = true;
      V.x = drag.x - (p.x - drag.px) / V.s;
      V.z = drag.z + (p.y - drag.py) / V.s;
      cv.style.cursor = 'grabbing';
      redraw();
      return;
    }
    if (!drag.moved) { drag.moved = true; pushUndo(); el.edProblems.setAttribute('aria-live', 'off'); }
    const free = e.altKey, x = wx(p.x), z = wz(p.y);
    if (drag.mode === 'move') {
      let dx = x - drag.x, dz = z - drag.z;
      if (!free) { dx = snapTo(drag.ax + dx, GRID) - drag.ax; dz = snapTo(drag.az + dz, GRID) - drag.az; }
      for (const o of selected().all) {
        const q = drag.orig.get(o.id);
        if (q) { o.x = r2(clamp(q.x + dx, -999, 999)); o.z = r2(clamp(q.z + dz, -999, 999)); }
      }
    } else if (drag.mode === 'turn') {
      const f = find(drag.id);
      if (f) {
        const a = Math.atan2(x - f.it.x, z - f.it.z) / D2R;
        f.it.yaw = normYaw(free ? a : snapTo(a, 5));
      }
    } else if (drag.mode === 'size') {
      const f = find(drag.id);
      if (f) {
        const b = f.it, ax = drag.edge[0] === 'x', v0 = ax ? x : z, MIN = 0.1;
        const v = free ? v0 : snapTo(v0, GRID);
        const lo = ax ? b.x - b.hx : b.z - b.hz, hi = ax ? b.x + b.hx : b.z + b.hz;
        const a0 = drag.edge[1] === '0' ? Math.min(v, hi - MIN) : lo, a1 = drag.edge[1] === '1' ? Math.max(v, lo + MIN) : hi;
        if (ax) { b.x = r2((a0 + a1) / 2); b.hx = r2((a1 - a0) / 2); } else { b.z = r2((a0 + a1) / 2); b.hz = r2((a1 - a0) / 2); }
      }
    }
    derive();
    refresh();
  });
  function pointerEnd(e) {
    ptrs.delete(e.pointerId);
    if (drag && drag.mode === 'pinch') { if (ptrs.size < 2) { drag = null; saveSoon(); } return; }
    if (!drag) return;
    if (drag.mode === 'pan') {
      if (!drag.moved && drag.clear && ed.sel.size) { setSel([]); refresh(); }
      if (drag.moved) saveSoon();
      cv.style.cursor = 'grab';
    }
    endDrag();
  }
  cv.addEventListener('pointerup', pointerEnd);
  cv.addEventListener('pointercancel', pointerEnd);
  cv.addEventListener('pointerleave', () => {
    if (!drag && ed.hover !== null) { ed.hover = null; redraw(); }
    el.edReadout.textContent = '';
  });
  cv.addEventListener('contextmenu', (e) => e.preventDefault());
  cv.addEventListener('wheel', (e) => {
    e.preventDefault();
    const p = local(e);
    zoomAt(p.x, p.y, Math.exp(-(e.deltaMode === 1 ? e.deltaY * 33 : e.deltaY) * 0.0015));
  }, { passive: false });

  // ---------------------------------------------------------------- keys
  // Only keys typed inside the editor are its own (app.js leaves those alone), and fields keep theirs
  root.addEventListener('keydown', (e) => {
    const t = e.target, k = e.key;
    const typing = t && ((t.tagName === 'INPUT' && !/^(checkbox|radio|button|file)$/i.test(t.type)) || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA');
    // the gallery shown: the map's keys are not for it, Escape goes back to the map
    if ((gal.open || gal.mine) && !typing) {
      if (k === 'Escape' && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); const b = gal.open ? el.edGalBtn : el.edMineBtn; showPanel(null); b.focus(); }
      return;
    }
    if (e.ctrlKey || e.metaKey) {
      if (e.altKey || (typing && t.tagName !== 'SELECT')) return;   // the field's own undo, copy...
      const l = k.toLowerCase();
      if (l === 'z') { e.preventDefault(); if (e.shiftKey) redo(); else undo(); }
      else if (l === 'y') { e.preventDefault(); redo(); }
      else if (l === 'd') { e.preventDefault(); duplicate(); }
      else if (l === 'a' && t === cv) { e.preventDefault(); setSel(items().map((o) => o.id)); refresh(); }
      return;
    }
    if (typing || e.altKey) return;
    if (k === 'r' || k === 'R') { e.preventDefault(); rotateSel(e.shiftKey ? -1 : 1); }
    else if (k === 'Delete' || k === 'Backspace') { e.preventDefault(); deleteSel(); }
    else if (k === 'Escape') {
      // the first one lets go of the selection, the next closes the editor
      e.preventDefault();
      if (ed.sel.size) { setSel([]); refresh(); } else closeEditor(true);
    }
    else if (t === cv && k.startsWith('Arrow')) {
      // the selection moves (Shift: 5 m at a time); with nothing selected, the map does
      e.preventDefault();
      const ux = k === 'ArrowLeft' ? -1 : k === 'ArrowRight' ? 1 : 0, uz = k === 'ArrowUp' ? 1 : k === 'ArrowDown' ? -1 : 0;
      if (ed.sel.size) nudge(ux * (e.shiftKey ? 5 : GRID), uz * (e.shiftKey ? 5 : GRID));
      else { V.x += ux * 60 / V.s; V.z += uz * 60 / V.s; redraw(); saveSoon(); }
    } else if (t === cv && (k === '+' || k === '=')) zoomAt(W / 2, H / 2, 1.25);
    else if (t === cv && (k === '-' || k === '_')) zoomAt(W / 2, H / 2, 0.8);
    else if (t === cv && (k === 'f' || k === 'F')) fit();
  });

  // ---------------------------------------------------------------- the rest of the page
  el.edGateType.innerHTML = TYPES.slice(1).map((n, i) => '<option value="' + (i + 1) + '">' + n + '</option>').join('');

  // a tool button that its own action disables (Delete with nothing left selected...) hands the
  // keyboard to the map rather than to the page
  const tool = (b, fn) => b.addEventListener('click', () => { fn(); if (b.disabled) cv.focus({ preventScroll: true }); });
  tool(el.edAddGate, addGate);
  tool(el.edAddBox, addBox);
  tool(el.edAddWall, addWall);
  tool(el.edRotL, () => rotateSel(-1));
  tool(el.edRotR, () => rotateSel(1));
  tool(el.edDup, duplicate);
  tool(el.edDel, deleteSel);
  tool(el.edUndo, undo);
  tool(el.edRedo, redo);
  el.edFit.addEventListener('click', fit);
  // the note about StickTime Lite follows the header's script picker (app.js handles it first)
  for (const id of ['scriptSel', 'fileIn']) {
    const s = $(id);
    if (s) s.addEventListener('change', () => setTimeout(() => { if (ed.open) renderFly(); }, 300));
  }
  el.edTrees.addEventListener('change', () => { ed.showTrees = el.edTrees.checked; redraw(); saveSoon(); });

  let nameUndo = false;
  el.edName.addEventListener('input', () => {
    if (!nameUndo) { pushUndo(); nameUndo = true; }
    ed.T.name = el.edName.value;
    changed();
  });
  el.edName.addEventListener('change', () => {
    nameUndo = false;
    const v = el.edName.value.trim();
    el.edName.value = v;
    if (v !== ed.T.name) { ed.T.name = v; changed(); }
  });
  const intField = (input, key, lo, hi) => input.addEventListener('change', () => {
    const v = parseInt(input.value, 10);
    if (Number.isFinite(v) && clamp(v, lo, hi) !== ed.T[key]) { pushUndo(); ed.T[key] = clamp(v, lo, hi); changed(); }
    input.value = String(ed.T[key]);
  });
  intField(el.edSeed, 'seed', 1, 99);
  intField(el.edTreesN, 'trees', 0, 30);
  el.edShuffle.addEventListener('click', () => {
    pushUndo();
    let s;
    do s = 1 + Math.floor(Math.random() * 99); while (s === ed.T.seed);
    ed.T.seed = s;
    changed();
  });

  el.edSel.addEventListener('change', (e) => {
    const inp = e.target.closest('[data-f]');
    const f = inp && ed.focus !== null ? find(ed.focus) : null;
    if (!f) return;
    const val = parseFloat(inp.value);
    if (!Number.isFinite(val)) { selSig = null; renderSel(); return; }
    pushUndo();
    applyField(f, inp.dataset.f, val);
    changed();
    const v = inp.dataset.f;
    // the field shows what the track holds (rounded, clamped)
    if (v === 't' || v === 'k' || v === 'yaw') inp.value = String(f.it[v === 'yaw' ? 'yaw' : v]);
    else if (v === 'w' || v === 'd') inp.value = dec(2 * (v === 'w' ? f.it.hx : f.it.hz));
    else inp.value = dec(f.it[v]);
  });
  el.edSel.addEventListener('click', (e) => {
    const b = e.target.closest('[data-a]');
    if (!b || b.disabled) return;
    const a = b.dataset.a, f = ed.focus !== null ? find(ed.focus) : null;
    if (a === 'group') setGroup(true);
    else if (a === 'ungroup') setGroup(false);
    else if (f && f.kind === 'gate' && (a === 'earlier' || a === 'later')) moveGate(f.i, a === 'earlier' ? -1 : 1);
  });
  el.edOrder.addEventListener('click', (e) => {
    const pick = e.target.closest('[data-pick]'), mv = e.target.closest('[data-move]');
    if (pick) {
      const id = +pick.dataset.pick;
      setSel(groupOf(id), id);
      refresh();
      const f = find(id);
      if (f) reveal(f.it.x, f.it.z);
    } else if (mv && !mv.disabled) {
      const [i, d] = mv.dataset.move.split(',').map(Number);
      if (moveGate(i, d)) {
        // keep the keyboard where it was: on the same arrow of the gate's new row
        const n = el.edOrder.querySelector('[data-move="' + (i + d) + ',' + d + '"]');
        const other = el.edOrder.querySelector('[data-move="' + (i + d) + ',' + -d + '"]');
        (n && !n.disabled ? n : other || el.edOrder).focus();
      }
    }
  });
  el.edProblems.addEventListener('click', (e) => {
    const b = e.target.closest('[data-prob]');
    const p = b && ed.probs[+b.dataset.prob];
    if (!p || !p.ids.length) return;
    setSel(p.ids, p.ids[0]);
    refresh();
    const f = find(p.ids[0]);
    if (f) reveal(f.it.x, f.it.z);
  });

  // New track (Open): blank, or a copy of a built-in track, in a slot that is empty (in the
  // emulator, and on the radio when it is read) when there is one
  function newTrack(v) {
    const b = v === 'blank' ? null : D.tracks[+v];
    if (v !== 'blank' && !b) return;
    if (!okToReplace(b ? 'a copy of ' + b.name : 'a blank track')) { (gal.open ? galStatus : status)('Kept your track.'); return; }
    showGallery(false);
    pushUndo();
    load(b ? fromBuiltin(b) : blankTrack(), true);
    ed.slot = freeSlot();
    renderSlots();
    fit();
    status((b ? 'A copy of ' + b.name : 'A blank track') + ' to start from, for c' + ed.slot + ' (track ' + (8 + ed.slot) + '). Undo goes back to what you had.', 'ok');
  }
  el.edOpen.addEventListener('change', () => {
    const file = el.edOpen.files && el.edOpen.files[0];
    el.edOpen.value = '';
    if (!file) return;
    if (file.size > MAX_FILE) { status(file.name + ' is too big for a track file.', 'bad'); return; }
    const rd = new FileReader();
    rd.onload = () => {
      const m = /^c([1-8])\.txt$/i.exec(file.name);
      openText(String(rd.result), file.name, m ? +m[1] : 0);
    };
    rd.onerror = () => status('Can\'t read ' + file.name + '.', 'bad');
    rd.readAsText(file);
  });
  // ---------------------------------------------------------------- Open and My tracks
  // Two panels in place of the map, one job each. Open picks a track to edit: a new one (blank, a
  // copy of a built-in track), one of yours (a slot of the emulator or the radio), a file, or one
  // from the gallery. My tracks manages the slots, what the game plays: the emulator's and the
  // radio's side by side, Remove, a copy across, and the gallery's newer versions.
  // The gallery is tracks/ in the repo (tools/gallery.py checks them): the page has them built in
  // (GALLERY, from tools/bundle_web.py), and the hosted site also has tracks/index.json beside the
  // page, asked for when the editor opens, so a track added since the page was built is there too.
  // A gallery track opens as it is (its id kept: the same track everywhere).
  const GALLERY_AT = typeof GALLERY_FILES === 'string' && GALLERY_FILES && /^https?:$/.test(location.protocol) ? GALLERY_FILES : '';
  // a gallery's list, every entry checked as a track file is (a bad one is left out)
  function galleryOf(g) {
    const out = [];
    const str = (v, n) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, n) : '');
    for (const t of (g && Array.isArray(g.tracks) ? g.tracks : []).slice(0, 500)) {
      if (!t || typeof t.text !== 'string' || t.text.length > MAX_BYTES + 1) continue;
      const r = parseFile(t.text);
      if (r.error) continue;
      const src = str(t.source, 300);
      out.push({ T: r.T, text: t.text.replace(/\r\n?/g, '\n'), name: r.T.name, by: str(t.by, 60), about: str(t.about, 300),
        source: /^https:\/\/[^\s"'<>]+$/.test(src) ? src : '' });
    }
    return out;
  }
  gal.list = galleryOf(typeof GALLERY === 'object' ? GALLERY : null);
  // the slots (entries as asEntry has them, c1 first) that hold a gallery track: same, the very
  // file (CR LF line ends or not); old, another version of it
  function placesOf(t, slots) {
    const same = [], old = [], name = t.name.toLowerCase();
    slots.forEach((e, i) => {
      if (!e || e.bad || typeof e.text !== 'string') return;
      if (e.text.replace(/\r\n?/g, '\n') === t.text) same.push(i + 1);
      else if (nameOf(e.text).toLowerCase() === name) old.push(i + 1);
    });
    return { same, old };
  }
  const cs = (a) => andList(a.map((n) => 'c' + n));
  // a slot empty in the emulator and (read) on the radio: the editor's when it is, else the first;
  // else one empty in the emulator; else the editor's (sending to it asks)
  function freeSlot() {
    const free = (i) => emuSlot(i) === null && !(radioRead() && radioSlots[i - 1]);
    if (free(ed.slot)) return ed.slot;
    for (let i = 1; i <= SLOTS; i++) if (free(i)) return i;
    for (let i = 1; i <= SLOTS; i++) if (emuSlot(i) === null) return i;
    return ed.slot;
  }
  // where a gallery track goes: the slot that has it, else one with another version of it, else
  // an empty one
  function slotFor(t) {
    const pe = placesOf(t, emuEntries()), pr = placesOf(t, radioRead() ? radioSlots : []);
    return pe.same[0] || pr.same[0] || pe.old[0] || pr.old[0] || freeSlot();
  }
  // a small map of a track: its structures, the race, the gates and flags, the start pad
  function thumb(c, T) {
    const w = c.clientWidth, h = c.clientHeight, d = window.devicePixelRatio || 1;
    if (!w || !h) return;
    c.width = Math.round(w * d); c.height = Math.round(h * d);
    const x = c.getContext('2d');
    x.setTransform(d, 0, 0, d, 0, 0);
    x.fillStyle = cssVar('--mat', '#2b5a4e');
    x.fillRect(0, 0, w, h);
    const G = T.gates.map(gateGeom), pad = padOf(G);
    const b = boundsOf(T.gates.concat(T.boxes));
    if (pad) { b.x0 = Math.min(b.x0, pad.x); b.x1 = Math.max(b.x1, pad.x); b.z0 = Math.min(b.z0, pad.z); b.z1 = Math.max(b.z1, pad.z); }
    if (!(b.x1 >= b.x0)) return;
    const m = 12, s = Math.min((w - 2 * m) / Math.max(b.x1 - b.x0, 1), (h - 2 * m) / Math.max(b.z1 - b.z0, 1), 12);
    const X = (v) => w / 2 + (v - (b.x0 + b.x1) / 2) * s, Y = (v) => h / 2 - (v - (b.z0 + b.z1) / 2) * s;
    for (const o of T.boxes) {
      x.fillStyle = C.box[o.k] || C.box[1];
      x.fillRect(X(o.x - o.hx), Y(o.z + o.hz), Math.max(2 * o.hx * s, 1.5), Math.max(2 * o.hz * s, 1.5));
    }
    if (G.length > 1) {
      x.strokeStyle = C.line; x.lineWidth = 1; x.beginPath();
      G.forEach((g, i) => (i ? x.lineTo(X(g.ax), Y(g.az)) : x.moveTo(X(g.ax), Y(g.az))));
      x.closePath(); x.stroke();
    }
    x.lineCap = 'round';
    T.gates.forEach((g, i) => {
      const q = G[i];
      if (g.t === 6 || g.t === 7) {
        x.fillStyle = C.cloth; x.beginPath(); x.arc(X(g.x), Y(g.z), 2.4, 0, 7); x.fill();
        return;
      }
      const o = Math.max((q.iw + GT) * s, 3);
      x.strokeStyle = i ? C.gate : ACC; x.lineWidth = 2.2; x.beginPath();
      x.moveTo(X(g.x) - q.rx * o, Y(g.z) + q.rz * o); x.lineTo(X(g.x) + q.rx * o, Y(g.z) - q.rz * o); x.stroke();
    });
    x.lineCap = 'butt';
    if (pad) { x.fillStyle = C.pad; x.fillRect(X(pad.x) - 2.5, Y(pad.z) - 2.5, 5, 5); }
  }
  const sayIn = (node) => (msg, kind) => { node.textContent = msg || ''; node.className = 'ed-status' + (kind ? ' ' + kind : ''); };
  const galStatus = sayIn(el.edGalStatus), mineStatus = sayIn(el.edMineStatus);
  // the gallery tracks that some slot has another version of
  function outdated() {
    const emu = emuEntries(), rad = radioRead() ? radioSlots : [];
    return gal.list.map((t, i) => ({ i, here: placesOf(t, emu).old, radio: placesOf(t, rad).old })).filter((o) => o.here.length || o.radio.length);
  }
  const inWords = (here, radio) => [here.length ? cs(here) + ' in the emulator' : '', radio.length ? cs(radio) + ' on the radio' : ''].filter(Boolean).join(' and ');

  // ---- Open: New track, Your tracks, the gallery; each with Open and nothing else
  function renderNew() {
    const list = [{ v: 'blank', name: 'Blank', note: 'two gates', T: blankTrack() }].concat(D.tracks.map((t, i) => ({ v: String(i), name: t.name,
      note: t.gates.length + ' gates' + (t.boxes.length ? ', ' + t.boxes.length + ' structures' : ''), T: fromBuiltin(t) })));
    keepFocus(el.edNewCards, () => {
      el.edNewCards.innerHTML = list.map((n) => '<li class="ed-card"><canvas class="ed-thumb" aria-hidden="true"></canvas><div class="ed-cinfo">' +
        '<strong>' + esc(n.name) + '</strong><span class="ed-meta">' + n.note + '</span></div><div class="ed-cbtns"><button class="btn" type="button" data-new="' +
        n.v + '" aria-label="' + (n.v === 'blank' ? 'Open a blank track' : 'Open a copy of ' + esc(n.name)) + '">Open</button></div></li>').join('');
    });
    el.edNewCards.querySelectorAll('canvas').forEach((c, i) => thumb(c, list[i].T));
  }
  // your tracks: the emulator's slots and the radio's (one line for a track both have)
  function renderOpenMine() {
    const rad = radioRead() ? radioSlots : null, rows = [];
    for (let i = 1; i <= SLOTS; i++) {
      const e = asEntry(emuSlot(i)), r = rad ? rad[i - 1] : null;
      const ok = (x) => x && !x.bad;
      const same = ok(e) && ok(r) && norm(e.text) === norm(r.text);
      if (ok(e)) rows.push([i, e, same ? 'emulator and radio' : 'emulator', 'e']);
      if (ok(r) && !same) rows.push([i, r, 'radio', 'r']);
    }
    const on = radio.state === 'on';
    keepFocus(el.edOpenList, () => {
      el.edOpenList.innerHTML = (rows.length ? rows.map(([i, x, where, key]) => '<li><b>c' + i + '</b> <span class="ed-tn">' + esc(nameOf(x.text)) + '</span> <i>' + where + '</i> ' +
        (norm(x.text) === ed.file.text ? '<em>in the editor</em>'
          : '<button class="btn" type="button" data-sopen="' + key + i + '" aria-label="Open c' + i + (key === 'e' ? ' of the emulator' : ' of the radio') + '">Open</button>') +
        '</li>').join('') : '<li class="ed-cnone">No tracks in your slots yet.</li>') +
        (radio.ok && !rad ? '<li class="ed-cnone">' + (on ? 'Reading the radio…' : 'The radio\'s tracks show here once it is connected. ' +
          '<button class="btn" type="button" data-connect="1"' + (radio.busy ? ' disabled' : '') + '>' + (radio.state === 'ask' ? 'Reconnect radio' : 'Connect radio…') + '</button>') + '</li>' : '');
    });
  }
  let galSig = '';
  function renderGallery(force) {
    renderOpenMine();
    if (force) renderNew();
    const emu = emuEntries(), rad = radioRead() ? radioSlots : null;
    const sig = JSON.stringify([gal.list.map((t) => t.text), emu, rad]);
    if (!force && sig === galSig) return;                  // (the thumbnails stay as they are)
    galSig = sig;
    keepFocus(el.edCards, () => {
      el.edCards.innerHTML = gal.list.length ? gal.list.map((t, i) => {
        const ng = t.T.gates.length, nb = t.T.boxes.length;
        const size = ng + ' gates' + (nb ? ', ' + nb + ' structures' : '') + (t.T.trees ? ', ' + t.T.trees + ' trees' : '');
        const has = inWords(placesOf(t, emu).same, rad ? placesOf(t, rad).same : []);
        return '<li class="ed-card"><canvas class="ed-thumb" aria-hidden="true"></canvas><div class="ed-cinfo">' +
          '<strong>' + esc(t.name) + '</strong>' + (t.by ? '<span class="ed-by">by ' + esc(t.by) + '</span>' : '') +
          (t.about ? '<p>' + esc(t.about) + '</p>' : '') +
          '<span class="ed-meta">' + size + (t.source ? ' · <a href="' + esc(t.source) + '" target="_blank" rel="noopener noreferrer">source</a>' : '') + '</span>' +
          (has ? '<span class="ed-in">In ' + esc(has) + '</span>' : '') + '</div>' +
          '<div class="ed-cbtns"><button class="btn" type="button" data-gopen="' + i + '" aria-label="Open ' + esc(t.name) + '">Open</button></div></li>';
      }).join('') : '<li class="ed-cnone">No tracks in the gallery yet.</li>';
    });
    ACC = cssVar('--accent', '#ff7f2a');
    el.edCards.querySelectorAll('canvas').forEach((c, i) => thumb(c, gal.list[i].T));
  }

  // ---- My tracks: the slots, the emulator's and the radio's side by side; Remove, copy across,
  // the gallery's newer versions
  function renderMine() {
    const rad = radioRead() ? radioSlots : null, on = radio.state === 'on', name = radio.dir ? cardName(radio.dir) : '';
    const off = radio.busy ? ' disabled' : '';
    const of = (key) => (key === 'e' ? ' of the emulator' : ' of the radio');
    const cell = (e, key, i) => '<td>' + (!e ? '<span class="ed-none">—</span>' : (e.bad ? '<i class="bad">' + BAD[e.bad] + '</i>'
      : '<span class="ed-tn">' + esc(nameOf(e.text)) + '</span>' + (norm(e.text) === ed.file.text ? ' <i>(in the editor)</i>' : '')) +
      ' <button class="linkbtn ed-del" type="button" data-sdel="' + key + i + '" aria-label="Remove c' + i + of(key) + '"' + (key === 'r' ? off : '') + '>Remove</button>') + '</td>';
    const head = !radio.ok ? '' : rad ? 'Radio <small>' + esc(name) + '</small>'
      : 'Radio <small>' + (on ? esc(name) + (radio.busy ? ', reading…' : '') : radio.state === 'ask' ? esc(name) + ', to allow again' : 'not connected') + '</small>' +
        (on ? '' : ' <button class="btn" type="button" data-connect="1"' + off + '>' + (radio.state === 'ask' ? 'Reconnect radio' : 'Connect radio…') + '</button>');
    let h = '<table><thead><tr><th scope="col">Slot</th><th scope="col">Emulator <small>this browser</small></th>' +
      (radio.ok ? '<th scope="col" class="ed-x"><span class="ed-sr">Copy</span></th><th scope="col">' + head + '</th>' : '') + '</tr></thead><tbody>';
    let from = 0, to = 0;
    for (let i = 1; i <= SLOTS; i++) {
      const e = asEntry(emuSlot(i)), r = rad ? rad[i - 1] : null;
      const same = !!(e && r && !e.bad && !r.bad && norm(e.text) === norm(r.text));
      const right = rad && e && !e.bad && !same, left = rad && r && !r.bad && !same;
      if (right) to++;
      if (left) from++;
      const x = !rad ? '' : same ? '<span class="ed-same" title="The same track">=</span>'
        : (right ? '<button class="btn ed-arrow" type="button" data-scopy="r' + i + '" aria-label="Copy c' + i + ' emulator → radio" title="Copy c' + i + ' of the emulator to the radio"' + off + '>→</button>' : '') +
          (left ? '<button class="btn ed-arrow" type="button" data-scopy="e' + i + '" aria-label="Copy c' + i + ' radio → emulator" title="Copy c' + i + ' of the radio to the emulator"' + off + '>←</button>' : '');
      h += '<tr><th scope="row">c' + i + ' <small>track ' + (8 + i) + '</small></th>' + cell(e, 'e', i) +
        (radio.ok ? '<td class="ed-x">' + x + '</td>' + (rad ? cell(r, 'r', i) : '<td></td>') : '') + '</tr>';
    }
    keepFocus(el.edSlotList, () => { el.edSlotList.innerHTML = h + '</tbody></table>'; });
    el.edAllFrom.hidden = !from;
    el.edAllTo.hidden = !to;
    el.edAllFrom.disabled = el.edAllTo.disabled = radio.busy;
    el.edMineNote.hidden = radio.ok;
    // the gallery's newer versions
    const old = outdated();
    el.edGalSync.hidden = !old.length;
    el.edGalSyncAll.hidden = old.length < 2;
    el.edGalSyncAll.disabled = radio.busy;
    keepFocus(el.edUpdList, () => {
      el.edUpdList.innerHTML = old.map((o) => '<li><span>"' + esc(gal.list[o.i].name) + '": an older version in ' + esc(inWords(o.here, o.radio)) + '</span>' +
        '<button class="btn" type="button" data-gsync="' + o.i + '"' + (radio.busy && o.radio.length ? ' disabled' : '') + '>Update</button></li>').join('');
    });
  }

  // the hosted site's list (once a visit; the built-in one stays when it can't be had)
  async function fetchGallery() {
    if (!GALLERY_AT || gal.asked) return;
    gal.asked = true;
    try {
      const r = await fetch(new URL(GALLERY_AT + 'index.json', location.href), { cache: 'no-cache' });
      const list = r.ok ? galleryOf(await r.json()) : [];
      if (list.length) { gal.list = list; if (gal.open) renderGallery(); if (gal.mine) renderMine(); }
    } catch (e) { /* the built-in list */ }
  }
  // the panel in place of the map: 'open', 'mine' or null (the map)
  function showPanel(which) {
    gal.open = which === 'open';
    gal.mine = which === 'mine';
    el.edGallery.hidden = !gal.open;
    el.edMine.hidden = !gal.mine;
    el.edGrid.hidden = !!which;
    el.edGalBtn.setAttribute('aria-expanded', String(gal.open));
    el.edMineBtn.setAttribute('aria-expanded', String(gal.mine));
    if (!which) {
      resize();
      // (a track picked far down the list: back to the map at once)
      if (root.getBoundingClientRect().top < 0) intoView(root, true);
      return;
    }
    if (gal.open) { galStatus(''); renderGallery(true); } else { mineStatus(''); renderMine(); }
    fetchGallery();
    // the radio's slots read afresh (a card changed by hand shows as it is now)
    if (radio.state === 'on' && !radio.busy) job(listRadio, gal.open ? galStatus : mineStatus);
  }
  const showGallery = (on) => showPanel(on ? 'open' : null);
  // the slots with another version of these gallery tracks get the gallery's (asked first: their
  // best times start over); on the radio only while a slot still holds the file listed
  function update(which) {
    const s = sim();
    if (!s || !which.length) return;
    const emu = emuEntries(), rad = radioRead() ? radioSlots.slice() : [];
    const here = [], there = [], said = [];
    for (const i of which) {
      const t = gal.list[i], pe = placesOf(t, emu).old, pr = placesOf(t, rad).old;
      pe.forEach((n) => here.push([n, t]));
      pr.forEach((n) => there.push([n, t, rad[n - 1].text]));
      if (pe.length || pr.length) said.push('"' + t.name + '" in ' + inWords(pe, pr));
    }
    if (!said.length) return;
    if (there.length && radio.busy) { mineStatus('The radio\'s card is busy: try again in a moment.', 'bad'); return; }
    if (!window.confirm('Put the gallery\'s version of ' + andList(said) + '? Their best times and ghosts start over: to the game, a changed track is another track.')) return;
    let kept = true;
    for (const [n, t] of here) kept = s.writeSD(slotPath(n), t.text) !== false && kept;
    renderSlots();
    const fresh = here.length && freshGame();
    const done = here.length ? 'Updated ' + cs(here.map((h) => h[0])) + ' in the emulator' + (fresh ? '.' : ' (the game reads ' + (here.length > 1 ? 'them' : 'it') +
      ' at its next start: Restart).') + (kept ? '' : ' The browser\'s storage is full: that lasts only this visit.') : '';
    if (!there.length) { mineStatus(done, kept ? 'ok' : 'bad'); return; }
    const gen = radio.gen;
    job(async () => {
      if (gen !== radio.gen) return;
      const dir = await tracksDir(false), put = [], moved = [];
      for (const [n, t, was] of there) {
        const now = dir && await readSlot(dir, n);
        if (!now || now.text !== was) { moved.push(n); continue; }
        await writeSlot(dir, n, t.text);
        put.push(n);
      }
      await listRadio();
      mineStatus((done ? done + ' ' : '') + (put.length ? 'Updated ' + cs(put) + ' on the radio: restart StickTime on it.' : '') +
        (moved.length ? ' ' + cs(moved) + ' on the radio changed since it was read: left alone.' : ''), moved.length || !kept ? 'bad' : 'ok');
    }, mineStatus, true);
  }
  // a gallery track into the editor as it is, in the slot that is its (then the Send buttons)
  function fromGallery(i) {
    const t = gal.list[i];
    if (!t) return;
    if (!okToReplace('"' + t.name + '" from the gallery')) { (gal.open ? galStatus : status)('Kept your track: "' + t.name + '" not opened.'); return; }
    showPanel(null);
    pushUndo();
    load(parseFile(t.text).T, true);
    ed.slot = slotFor(t);
    renderSlots();
    renderFly();
    fit();
    saveSoon();
    status('"' + t.name + '" from the gallery' + (t.by ? ', by ' + t.by : '') + ': ' + slotSays(t.text), 'ok');
    cv.focus({ preventScroll: true });
  }
  el.edGalBtn.addEventListener('click', () => showPanel(gal.open ? null : 'open'));
  el.edMineBtn.addEventListener('click', () => showPanel(gal.mine ? null : 'mine'));
  el.edGalSyncAll.addEventListener('click', () => update(outdated().map((o) => o.i)));
  el.edAllFrom.addEventListener('click', () => radioToEmu(mineStatus));
  el.edAllTo.addEventListener('click', () => emuToRadio(mineStatus));
  el.edGallery.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const d = b.dataset;
    if (d.new !== undefined) newTrack(d.new);
    else if (d.connect !== undefined) connect(galStatus);
    else if (d.sopen !== undefined) {
      const n = clamp(+d.sopen.slice(1) || 1, 1, SLOTS), r = d.sopen[0] === 'r';
      const x = r ? (radioRead() ? radioSlots[n - 1] : null) : asEntry(emuSlot(n));
      if (x && !x.bad) openText(x.text, 'c' + n + (r ? ' on the radio' : ' of the emulator'), n);
    } else if (d.gopen !== undefined) fromGallery(+d.gopen);
  });
  el.edMine.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const d = b.dataset;
    if (d.connect !== undefined) connect(mineStatus);
    else if (d.sdel !== undefined) {
      const n = clamp(+d.sdel.slice(1) || 1, 1, SLOTS);
      if (d.sdel[0] === 'r') removeFromRadio(n, mineStatus); else removeEmu(n, mineStatus);
    } else if (d.scopy !== undefined) copySlot(clamp(+d.scopy.slice(1) || 1, 1, SLOTS), d.scopy[0] === 'r', mineStatus);
    else if (d.gsync !== undefined) update([+d.gsync]);
  });
  // The slot list picks where the editor's track goes (the Send buttons, Save file); it never changes
  // the track. What a slot holds is opened with the Open beside it, in the Emulator or the Radio row.
  el.edSlot.addEventListener('change', () => {
    ed.slot = clamp(parseInt(el.edSlot.value, 10) || 1, 1, SLOTS);
    ed.picked = true;
    renderFly();
    saveSoon();
  });

  // Send to emulator: the file into the slot on the emulator's SD card, asked first when it holds another track;
  // the slots when it starts), then the track picked and Practice begun
  function sendEmu() {
    if (ed.probs.length) return false;
    const s = sim();
    if (!s) return false;
    const slot = ed.slot, old = asEntry(emuSlot(slot));
    if (old && (old.bad || norm(old.text) !== ed.file.text) && !stale(old) && !window.confirm('Slot c' + slot + ' of the emulator holds ' + what(old) +
      '. Replace it with "' + ed.T.name.trim() + '"?')) {
      status('Not sent: c' + slot + ' keeps ' + what(old) + '. Pick another slot.');
      return false;
    }
    const kept = s.writeSD(slotPath(slot), ed.file.text) !== false;
    ed.saved.add(ed.file.text);
    renderSlots();
    freshGame();                                       // (in its menus the game lists it at once)
    status('Sent to c' + slot + ' in the emulator (track ' + (8 + slot) + '): Fly c' + slot + ' flies it.' + (kept ? ''
      : ' The browser\'s storage is full: c' + slot + ' lasts only this visit (Save file keeps the track).'), kept ? 'ok' : 'bad');
    return true;
  }
  // Fly: the game started again (it reads the slots when it starts) on the slot as the emulator has
  // it, in Practice; a slot without the edited version (changes not sent) is asked about first
  function fly() {
    const s = sim();
    if (!s || !s.engine) { status('The emulator is still starting: try again in a moment.', 'bad'); return; }
    const slot = ed.slot, t = 8 + slot, cur = asEntry(emuSlot(slot));
    if (!cur || cur.bad) { status('c' + slot + ' of the emulator ' + (cur ? 'can\'t be read' : 'is empty') + ': Send to emulator first.', 'bad'); return; }
    if (stale(cur) && !window.confirm('c' + slot + ' in the emulator has "' + nameOf(cur.text) + '", but not the version you are editing: your changes aren\'t sent. ' +
      'Fly c' + slot + ' as it is?\n\n(Send to emulator first to fly your changes.)')) {
      status('Not flown: Send to emulator puts your changes in c' + slot + ', then Fly c' + slot + '.');
      return;
    }
    // StickTime Lite (and any other script) doesn't read custom tracks: back to the screen's own
    if (s.app.custom || s.app.script === 'lite') s.script('auto'); else s.boot();
    s.pause(false);
    const eng = s.engine;
    if (!eng || eng.error) { status('The game did not start: ' + (eng && eng.error ? eng.error.msg.split('\n')[0] : 'no engine'), 'bad'); return; }
    let name = null;
    try {
      s.test('track', t);
      s.test('start', 2);
      const info = s.test('info');
      name = info && info[10];
    } catch (err) {
      status('The game could not build the track: ' + String(err && err.message || err).split('\n')[0], 'bad');
      return;
    }
    status('Flying ' + (name || nameOf(cur.text)) + ' (track ' + t + ', c' + slot + '.txt) in Practice.', 'ok');
    closeEditor(false);
    const radio = $('radio');
    if (radio) radio.scrollIntoView({ block: 'center', behavior: reduced() ? 'auto' : 'smooth' });
    // the keys fly the quad again
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  }
  function saveFile() {
    if (ed.probs.length) return;
    const url = URL.createObjectURL(new Blob([ed.file.text], { type: 'text/plain' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = 'c' + ed.slot + '.txt';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    ed.saved.add(ed.file.text);
    status('Saved c' + ed.slot + '.txt: copy it to ' + DIR + ' on the radio\'s SD card.', 'ok');
  }
  el.edFly.addEventListener('click', fly);
  el.edSendEmu.addEventListener('click', sendEmu);
  el.edSave.addEventListener('click', saveFile);
  function removeEmu(slot, say) {
    const s = sim(), t = emuSlot(slot);
    if (!s || t === null) return;
    if (!window.confirm('Remove c' + slot + ' from the emulator? ' + what(asEntry(t)).replace(/^a/, 'A') +
      ' goes from its SD card (the radio and a file you saved keep theirs).')) return;
    const kept = s.removeSD(slotPath(slot)) !== false;
    renderSlots();
    say('Removed c' + slot + ' from the emulator.' + (freshGame() ? '' : ' The game\'s track menu shows it at its next start (Restart).') +
      (kept ? '' : ' The browser\'s storage is blocked: the slot comes back at the next visit.'), kept ? 'ok' : 'bad');
  }
  el.edSyncMine.addEventListener('click', () => showPanel('mine'));
  // one slot copied across: the emulator's to the radio's same slot, or the other way (asked first
  // when it replaces another track there)
  function copySlot(n, toRadio, say) {
    const s = sim(), here = asEntry(emuSlot(n)), there = radioRead() ? radioSlots[n - 1] : null;
    const from = toRadio ? here : there, to = toRadio ? there : here, where = toRadio ? ' on the radio' : ' in the emulator';
    if (!s || !from || from.bad) return;
    if (to && (to.bad || norm(to.text) !== norm(from.text)) && !window.confirm('Replace c' + n + where + ', ' + what(to) + ', with "' + nameOf(from.text) + '"?')) return;
    if (!toRadio) {
      const kept = s.writeSD(slotPath(n), from.text) !== false;
      renderSlots();
      say('Copied c' + n + ' from the radio to the emulator.' + (freshGame() ? '' : ' The game reads it at its next start (Restart).') +
        (kept ? '' : ' The browser\'s storage is full: the emulator keeps it only for this visit.'), kept ? 'ok' : 'bad');
      return;
    }
    const gen = radio.gen;
    job(async () => {
      if (gen !== radio.gen) return;
      const dir = await tracksDir(true), now = await readSlot(dir, n);
      if ((now && now.text) !== (to && to.text)) { say('c' + n + ' on the radio changed since it was read: nothing copied. Look again.', 'bad'); await listRadio(); return; }
      await writeSlot(dir, n, from.text);
      await listRadio();
      say('Copied c' + n + ' to the radio. On the radio: restart StickTime.', 'ok');
    }, say, true);
  }

  // ---------------------------------------------------------------- the radio's SD card
  // Chrome, Edge and Opera on a computer can read and write a folder the user picks (File System
  // Access). A radio plugged in by USB in USB Storage mode is a drive: the user picks it once, the
  // handle is kept in IndexedDB, and a later visit reconnects with a click (or by itself while the
  // browser still allows it). Elsewhere (Firefox, Safari, phones, a page in another site's frame)
  // one line says to use Save file.
  const NO_RADIO = 'This browser can\'t write to the radio\'s SD card: use Save file and copy it to ' + DIR + ' on the radio.';
  const NOT_CARD = 'This doesn\'t look like the radio\'s SD card: no SCRIPTS folder. Pick the drive the radio shows up as.';
  function canPick() {
    if (typeof window.showDirectoryPicker !== 'function') return false;
    try { return window.top === window.self || !!window.top.location.href; } catch (e) { return false; }   // another site's frame
  }
  // dir: what the user picked; at: where that is on the card (the card, SCRIPTS, TOOLS, StickTimeTracks);
  // panel: the Install panel is open; listed: its list of the card's slots is read; writing: the
  // job under way writes to the card; gen: counts Disconnects (a job that outlives its card says nothing)
  const radio = { ok: canPick(), state: 'off', dir: null, at: null, busy: false, writing: false, panel: false, listed: false, gen: 0, again: false };
  // what the Install panel says (the editor has its own line: status)
  function rstatus(msg, kind) {
    el.rpStatus.textContent = msg || '';
    el.rpStatus.className = 'ed-status' + (kind ? ' ' + kind : '');
  }
  const STEPS = { card: ['SCRIPTS', 'TOOLS', 'StickTimeTracks'], scripts: ['TOOLS', 'StickTimeTracks'], tools: ['StickTimeTracks'], tracks: [] };
  const kv = {
    db: null,
    store(mode, fn) {
      if (!kv.db) {
        kv.db = new Promise((res, rej) => {
          const r = indexedDB.open('fpvsim', 1);
          r.onupgradeneeded = () => r.result.createObjectStore('handles');
          r.onsuccess = () => res(r.result);
          r.onerror = () => rej(r.error);
        });
      }
      return kv.db.then((db) => new Promise((res, rej) => {
        const t = db.transaction('handles', mode), r = fn(t.objectStore('handles'));
        t.oncomplete = () => res(r.result);
        t.onerror = t.onabort = () => rej(t.error);
      }));
    },
    get: (k) => kv.store('readonly', (s) => s.get(k)),
    set: (k, v) => kv.store('readwrite', (s) => s.put(v, k)),
    del: (k) => kv.store('readwrite', (s) => s.delete(k)),
  };
  // a folder or file in dir by name, in any case (the card is FAT: the radio doesn't mind case)
  async function child(dir, name, kind, create) {
    try { return kind === 'file' ? await dir.getFileHandle(name) : await dir.getDirectoryHandle(name); }
    catch (e) { if (e.name !== 'NotFoundError' && e.name !== 'TypeMismatchError') throw e; }
    const low = name.toLowerCase();
    for await (const h of dir.values()) if (h.kind === kind && h.name.toLowerCase() === low) return h;
    if (!create) return null;
    return kind === 'file' ? dir.getFileHandle(name, { create: true }) : dir.getDirectoryHandle(name, { create: true });
  }
  async function locate(dir) {
    const n = dir.name.toLowerCase();
    if (n === 'sticktimetracks') return 'tracks';
    if (await child(dir, 'SCRIPTS', 'directory')) return 'card';
    if (n === 'scripts') return 'scripts';
    if (n === 'tools' || await child(dir, 'StickTimeTracks', 'directory') || await child(dir, 'StickTime.lua', 'file')
      || await child(dir, 'StickTimeBW.lua', 'file')) return 'tools';
    return null;
  }
  async function walk(steps, create) {
    let d = radio.dir;
    for (const s of steps) if (!(d = await child(d, s, 'directory', create))) return null;
    return d;
  }
  const tracksDir = (create) => walk(STEPS[radio.at], create);
  // a slot's file on the card, as asEntry has it (one too big to be a track isn't read at all)
  async function readSlot(dir, n) {
    const f = dir && await child(dir, 'c' + n + '.txt', 'file');
    if (!f) return null;
    const file = await f.getFile();
    return file.size > MAX_FILE ? { text: null, bad: 'big' } : asEntry(await file.text());
  }
  async function writeSlot(dir, n, text) {
    const f = await child(dir, 'c' + n + '.txt', 'file', true);
    const w = await f.createWritable();
    await w.write(text);
    await w.close();
  }
  async function readAll() {
    const dir = await tracksDir(false), out = [];
    for (let i = 1; i <= SLOTS; i++) out.push(await readSlot(dir, i));
    return out;
  }
  // which StickTime is on the card (where we can see SCRIPTS/TOOLS)
  async function installed() {
    if (radio.at === 'tracks') return '';
    const tools = await walk(STEPS[radio.at].slice(0, -1), false);
    const has = async (f) => !!(tools && await child(tools, f, 'file'));
    if (await has('StickTime.lua') || await has('StickTimeBW.lua')) return '';
    if (await has('StickTimeLite.lua')) return ' Only StickTime Lite is on this card, and the Lite doesn\'t read custom tracks.';
    return GAME ? ' StickTime isn\'t on this card yet: Install puts it there.' : ' StickTime isn\'t on this card yet: copy it to /SCRIPTS/TOOLS/ too.';
  }

  // the card's name to show: a drive's root is called "\" (Windows) or "/", so then "SD card"
  const cardName = (dir) => (dir && !/^[\\/]*$/.test(dir.name) ? dir.name : 'SD card');

  function renderRadio() {
    const on = radio.state === 'on', ask = radio.state === 'ask', name = radio.dir ? cardName(radio.dir) : '';
    // the editor's Radio row: what the radio's slot holds, Send to radio (Connect radio… first), Remove,
    // and where the emulator's slots and the radio's differ, a copy either way
    const bad = !!ed.T && ed.probs.length > 0, listed = on && radio.listed && !!ed.T;
    const re = listed ? radioSlots[ed.slot - 1] : null;
    el.edSend.hidden = el.edRadioLine.hidden = !radio.ok;
    el.edSendText.textContent = on ? 'Send to radio' : ask ? 'Reconnect radio' : 'Connect radio…';
    el.edSend.disabled = radio.busy || (on && bad);
    el.edSend.title = !on ? 'Connect the radio\'s SD card first (the radio plugged in by USB, in USB Storage mode)'
      : bad ? 'Fix the problems listed under Check first' : 'Write c' + ed.slot + '.txt to the radio\'s SD card (track ' + (8 + ed.slot) + ')';
    el.edRadioLineText.classList.toggle('warn', listed && stale(re));
    el.edRadioLineText.textContent = listed ? 'c' + ed.slot + ': ' + holds(re) + ' · ' + name
      : on ? name + ' connected' + (radio.busy ? ', reading…' : '') : ask ? name + ': allow again' : 'not connected';
    const diff = [];
    if (listed) {
      for (let i = 1; i <= SLOTS; i++) {
        const t = emuSlot(i), e = radioSlots[i - 1];
        if ((t === null && !e) || (t !== null && e && !e.bad && norm(t) === norm(e.text))) continue;
        diff.push(i);
      }
    }
    el.edSyncLine.hidden = !diff.length;
    el.edSyncText.textContent = 'The emulator and the radio hold different tracks in ' + andList(diff.map((i) => 'c' + i)) + '.';
    // the panel: the connection
    el.edRadio.hidden = el.rpTracksSec.hidden = !radio.ok;
    el.edRadioNote.className = 'note ed-rnote' + (radio.ok ? '' : ' warn');
    el.edRadioNote.textContent = radio.ok ? 'Plug the radio in by USB and choose USB Storage (SD) on it, then Connect radio and pick its SD card ' +
      '(the drive). Eject the drive before you unplug the radio.' : NO_RADIO;
    // the game itself: from the site's sdcard/ where this browser can write to the card (not offline,
    // not in a hosted artifact), else the release zip
    el.edInstallNote.hidden = !!GAME && radio.ok;
    el.edInstallMore.textContent = '; in Chrome or Edge on a computer, ' + (GAME ? 'this page' : 'the emulator at juricabi.github.io/sticktime') + ' can install it for you';
    if (!radio.ok) {
      el.edInstallPanel.hidden = el.rpInstWait.hidden = true;
      return;
    }
    el.edRadioState.textContent = on ? name + ' connected' : ask ? name + ': allow again' : 'not connected';
    el.edRadioState.classList.toggle('on', on);
    el.edConnect.textContent = ask ? 'Reconnect' : 'Connect radio…';
    el.edConnect.hidden = on;
    el.edRefresh.hidden = !on;
    el.edForget.hidden = !(on || ask);
    el.edConnect.disabled = el.edRefresh.disabled = el.edForget.disabled = radio.busy;
    const noTools = radio.at === 'tracks', shown = !!(on && GAME && !noTools && inst.card);
    el.edInstallPanel.hidden = !shown;
    el.rpInstWait.hidden = !GAME || shown;
    el.rpInstWait.textContent = !on ? 'Connect the radio\'s SD card to install StickTime on it or bring it up to date.'
      : noTools ? 'Connect the card\'s drive (or its SCRIPTS/TOOLS folder) to install the game.'
        : inst.err || (radio.busy ? 'Reading the card…' : 'The game on the card isn\'t read yet: Read again.');
    el.edInstallGo.disabled = radio.busy || !inst.card || !Object.values(inst.pick).some(Boolean);
  }
  // a radio job: one at a time; a card that went away (unplugged) or lost its permission says so
  // (say: the panel's line, or the editor's for Send to radio; writes: leaving the page asks first)
  async function job(fn, say, writes) {
    say = say || rstatus;
    if (radio.busy) return;
    const gen = radio.gen;
    radio.busy = true;
    radio.writing = !!writes;
    renderRadio();
    try { await fn(); }
    catch (e) {
      if (gen !== radio.gen) { /* the card was let go meanwhile: nothing to say about it */ }
      else if (e && (e.name === 'NotFoundError' || e.name === 'NotAllowedError' || e.name === 'SecurityError')) {
        radio.state = 'ask';
        radio.listed = false;
        renderSlots();
        say('The radio\'s SD card isn\'t there any more: plug the radio in (USB Storage) and Reconnect, or Connect radio to pick it again.', 'bad');
      } else say(e && e.site ? e.message : 'The radio\'s SD card: ' + (e && e.message || e), 'bad');
    } finally {
      radio.busy = radio.writing = false;
      renderRadio();
      if (ed.T) renderSlots();                         // (the lists' buttons on again)
      if (radio.again) {
        radio.again = false;
        if (radio.panel && radio.state === 'on' && !radio.listed) job(refreshRadio);
      }
    }
  }
  window.addEventListener('beforeunload', (e) => {
    if (!radio.writing) return;
    e.preventDefault();
    e.returnValue = '';                                // a file half written on the card
  });
  async function useCard(dir, said, say) {
    const gen = radio.gen, at = await locate(dir);
    if (gen !== radio.gen) return;
    if (!at) {
      say(NOT_CARD, 'bad');
      return;
    }
    radio.dir = dir;
    radio.at = at;
    radio.state = 'on';
    radio.listed = false;
    inst.card = null;                                  // another card: looked at afresh
    try { await kv.set('radio', dir); } catch (e) { /* not kept: Connect radio again next time */ }
    if (gen !== radio.gen) { kv.del('radio').catch(() => { /* nothing kept */ }); return; }
    const where = at === 'card' ? '' : ' (' + ['SCRIPTS', 'SCRIPTS/TOOLS', 'SCRIPTS/TOOLS/StickTimeTracks'][['scripts', 'tools', 'tracks'].indexOf(at)] + ')';
    if (said) say('Radio SD: ' + cardName(dir) + where + ' connected.' + await installed(), 'ok');
    if (radio.panel) await refreshRadio();
    else if (ed.open) await listRadio();
  }
  // what the panel shows of the card: its tracks, and the game on it
  async function refreshRadio() {
    await listRadio();
    renderRadio();
    if (GAME && radio.at !== 'tracks') await loadInstall();
  }
  // Connect radio… (or Reconnect): the picker and the permission both need this click
  function connect(say) {
    say = say || rstatus;
    if (radio.state === 'ask' && radio.dir) {
      const dir = radio.dir;
      const ask = typeof dir.requestPermission === 'function' ? dir.requestPermission({ mode: 'readwrite' }) : Promise.resolve('granted');
      job(async () => {
        if (await ask === 'granted') await useCard(dir, true, say);
        else { radio.state = 'off'; say('The radio\'s SD card wasn\'t allowed: Connect radio to pick it again.', 'bad'); }
      }, say);
      return;
    }
    let picking;
    try { picking = window.showDirectoryPicker({ mode: 'readwrite', id: 'sticktime-radio' }); }
    catch (e) { picking = Promise.reject(e); }
    job(async () => {
      let dir;
      try { dir = await picking; }
      catch (e) {
        if (e && e.name === 'AbortError') return;          // the picker was closed
        if (e && (e.name === 'SecurityError' || e instanceof TypeError)) { radio.ok = false; say(NO_RADIO, 'bad'); return; }
        throw e;
      }
      await useCard(dir, true, say);
    }, say);
  }
  // the editor's Send to radio: connects first when it has to
  function sendToRadio() {
    if (radio.state !== 'on') { connect(status); return; }
    if (ed.probs.length) return;
    const slot = ed.slot, text = ed.file.text, name = ed.T.name.trim();
    job(async () => {
      const dir = await tracksDir(true);
      const old = await readSlot(dir, slot);
      if (!old || old.text !== text) {
        for (let i = 1; i <= SLOTS; i++) {
          const e = i === slot ? null : await readSlot(dir, i);
          if (e && !e.bad && e.text.replace(/\r\n?/g, '\n') === text) {
            status('The radio has this track already, in c' + i + ' (track ' + (8 + i) + '): nothing sent. To have it in c' + slot +
              ' instead, Remove c' + i + ' under Install first.');
            ed.saved.add(text);
            await listRadio();
            return;
          }
        }
      }
      if (old && old.text !== text && !window.confirm('Slot c' + slot + ' on the radio holds ' + what(old) + '. Replace it with "' + name + '"?')) {
        status('Nothing sent: c' + slot + '.txt on the radio stays as it was.');
        return;
      }
      if (!old || old.text !== text) await writeSlot(dir, slot, text);
      ed.saved.add(text);
      await listRadio();                               // (the lists show what is on the card now)
      status('Sent to the radio as track ' + (8 + slot) + ' (c' + slot + '.txt). On the radio: restart StickTime, the track is in the Track list.', 'ok');
    }, status, true);
  }
  let radioSlots = [];
  function radioRead() { return radio.state === 'on' && radio.listed; }
  async function listRadio() {
    radioSlots = await readAll();
    radio.listed = true;
    renderRadio();
    if (ed.T && !ed.picked) {
      const h = homes(ed.file.text);
      if (!h.here.includes(ed.slot) && !h.there.includes(ed.slot) && (h.here.length || h.there.length)) {
        ed.slot = h.here[0] || h.there[0];
        renderFly();
      }
    }
    renderSlots();
  }
  // Remove: a slot's file off the card, asked first; only c<n>.txt (n 1-8) in the StickTimeTracks
  // folder found, and only while it is the file the list showed
  function removeFromRadio(n, say) {
    say = say || rstatus;
    const e = radioSlots[n - 1], gen = radio.gen;
    if (!Number.isInteger(n) || n < 1 || n > SLOTS || !e || radio.busy || radio.state !== 'on') return;
    const name = 'c' + n + '.txt';
    if (!window.confirm(e.bad ? 'Remove ' + name + ' (track ' + (8 + n) + ', ' + what(e) + ') from the radio?'
      : 'Remove "' + nameOf(e.text) + '" (track ' + (8 + n) + ') from the radio? Its best times stay in the radio\'s save until a different track is put in that slot.')) return;
    job(async () => {
      if (gen !== radio.gen) return;                   // (another card since)
      const dir = await tracksDir(false), now = dir && await readSlot(dir, n);
      if (!now || now.text !== e.text || now.bad !== e.bad) {
        say(name + ' on the radio isn\'t the file listed any more: nothing removed. Look at the list again.', 'bad');
      } else if (await removeFile(dir, (await child(dir, name, 'file')).name)) {
        say('Removed ' + name + ' from the radio. Restart StickTime on the radio.', 'ok');
      } else say(name + ' was gone from the radio already.');
      await listRadio();
    }, say, true);
  }
  // where the editor's track is: in its slot here and/or on the radio, or where the Send buttons put it
  function slotSays(text) {
    const h = homes(text), c = 'c' + ed.slot + ' (track ' + (8 + ed.slot) + ')';
    const here = h.here.includes(ed.slot), there = h.there.includes(ed.slot);
    return here && there ? 'it is in ' + c + ' in the emulator and on the radio.' : here ? 'it is in ' + c + ' in the emulator' + (radioRead() ? ', not on the radio.' : '.')
      : there ? 'it is in ' + c + ' on the radio.' : 'Send to emulator, Send to radio or Save file puts it in ' + c + '.';
  }
  // a track file into the editor (Open file, a radio slot), checked as the game reads it
  function openText(text, what, slot) {
    const r = parseFile(text);
    if (r.error) { status('Can\'t open ' + what + ': ' + r.error, 'bad'); return; }
    if (!okToReplace('"' + r.T.name + '" (' + what + ')')) { (gal.open ? galStatus : status)('Kept your track: ' + what + ' not opened.'); return; }
    if (gal.open || gal.mine) showPanel(null);
    pushUndo();
    load(r.T, true);
    slot = slot || homeOf(ed.file.text);
    if (slot) { ed.slot = slot; renderSlots(); renderFly(); }
    fit();
    status('Opened ' + what + ': ' + r.T.gates.length + ' gates, ' + r.T.boxes.length + ' structures.' + (r.note ? ' ' + r.note : ''), r.note ? 'bad' : 'ok');
  }
  // the radio's tracks into the emulator's slots, or the emulator's onto the radio (same slots):
  // put, the slots to write; lose, a different file there that would be replaced (named first);
  // skip, the files the game can't read (never copied)
  function plan(from, to) {
    const put = [], lose = [], skip = [];
    from.forEach((f, i) => {
      const t = to[i], c = 'c' + (i + 1);
      if (!f || (t && t.text === f.text)) return;
      if (f.bad) { skip.push(c + ' (' + BAD[f.bad] + ')'); return; }
      put.push(i + 1);
      if (t) lose.push(c + (t.bad ? ' (' + BAD[t.bad] + ')' : ' "' + nameOf(t.text) + '"'));
    });
    return { put, lose, skip, none: !from.some((f) => f && !f.bad) };
  }
  const emuEntries = () => Array.from({ length: SLOTS }, (_, i) => asEntry(emuSlot(i + 1)));
  const skipped = (p) => (p.skip.length ? ' Not copied, the game can\'t read ' + (p.skip.length > 1 ? 'them' : 'it') + ': ' + andList(p.skip) + '.' : '');
  function radioToEmu(say) {
    say = say || rstatus;
    const s = sim();
    if (!s) return;
    job(async () => {
      const rad = await readAll(), p = plan(rad, emuEntries());
      if (!rad.some(Boolean)) { say('No tracks on the radio to copy.'); return; }
      if (p.none) { say('No tracks on the radio the game can read.' + skipped(p), 'bad'); return; }
      if (p.lose.length && !window.confirm('Replace in the emulator: ' + p.lose.join(', ') + '?')) return;
      let full = false;
      p.put.forEach((i) => { if (s.writeSD(slotPath(i), rad[i - 1].text) === false) full = true; });
      renderSlots();
      const fresh = p.put.length && freshGame();
      say((p.put.length ? 'Copied ' + slotList(p.put) + ' from the radio into the emulator. ' + (fresh ? 'They are in the game\'s Track list.'
        : 'Fly them from the track editor, or Restart the game to find them in its Track list.')
        : 'The emulator already has the radio\'s tracks.') + skipped(p) +
        (full ? ' The browser\'s storage is full or blocked: the emulator keeps them only for this visit.' : ''), full ? 'bad' : 'ok');
      await listRadio();
    }, say);
  }
  // c1, c3 and c5
  const andList = (l) => (l.length > 6 ? [...l.slice(0, 5), (l.length - 5) + ' more'] : l).join(', ').replace(/, ([^,]*)$/, ' and $1');
  const slotList = (l) => andList(l.map((i) => 'c' + i));
  function emuToRadio(say) {
    say = say || rstatus;
    job(async () => {
      const emu = emuEntries();
      if (!emu.some(Boolean)) { say('No tracks in the emulator\'s slots: Send to emulator in the track editor puts one there.'); return; }
      const dir = await tracksDir(true), rad = [];
      for (let i = 1; i <= SLOTS; i++) rad.push(await readSlot(dir, i));
      const p = plan(emu, rad);
      if (p.none) { say('No tracks in the emulator\'s slots the game can read.' + skipped(p), 'bad'); return; }
      if (p.lose.length && !window.confirm('Replace on the radio: ' + p.lose.join(', ') + '?')) return;
      for (const i of p.put) await writeSlot(dir, i, emu[i - 1].text);
      say((p.put.length ? 'Sent ' + slotList(p.put) + ' to the radio. On the radio: restart StickTime, the tracks are in the Track list.'
        : 'The radio already has the emulator\'s tracks.') + skipped(p), 'ok');
      await listRadio();
    }, say, true);
  }
  el.edConnect.addEventListener('click', () => connect(rstatus));
  el.edSend.addEventListener('click', sendToRadio);
  el.edRefresh.addEventListener('click', () => job(refreshRadio));
  el.edForget.addEventListener('click', () => {
    if (radio.busy) return;                            // (the button is off then)
    radio.gen++;
    radio.state = 'off';
    radio.dir = radio.at = null;
    radio.listed = false;
    inst.man = inst.card = null;                       // the site's files are asked for afresh too
    inst.err = '';
    kv.del('radio').catch(() => { /* nothing kept */ });
    renderRadio();
    renderSlots();
    rstatus('The radio\'s SD card is forgotten: Connect radio to pick it again.');
    el.edConnect.focus();
  });
  // a radio slot into the track editor, on that slot
  // Install's Show your tracks: the table of the slots, in the track editor's Open
  el.rpShowTracks.addEventListener('click', () => { openEditor(); showPanel('mine'); });

  // ---------------------------------------------------------------- the two panels
  // Tracks (the track editor) and Install (the radio's SD card), each with its toolbar button, in the
  // same place above the emulator: opening one closes the other
  function openEditor() {
    if (radio.panel) closeRadio(false);
    if (!ed.open) status('');                          // (what was said last time is old news)
    fetchGallery();
    if (radio.state === 'on' && !radio.busy) job(listRadio, status);                 // (as it is now)
    ed.open = true;
    root.hidden = false;
    el.tracksBtn.setAttribute('aria-expanded', 'true');
    renderSlots();
    selSig = probSig = orderSig = null;           // the side panel afresh
    resize();
    refresh();
    intoView(root);
    cv.focus({ preventScroll: true });
  }
  function closeEditor(focusButton) {
    if (ed.open) saveNow();
    ed.open = false;
    root.hidden = true;
    el.tracksBtn.setAttribute('aria-expanded', 'false');
    if (focusButton) el.tracksBtn.focus();
  }
  function openRadio() {
    if (ed.open) closeEditor(false);
    radio.panel = true;
    rp.hidden = false;
    el.radioBtn.setAttribute('aria-expanded', 'true');
    renderRadio();
    intoView(rp);
    (el.edConnect.hidden ? el.rpClose : el.edConnect).focus({ preventScroll: true });
    if (radio.state === 'on') { if (radio.busy) radio.again = true; else job(refreshRadio); }   // (after the job under way)
  }
  function closeRadio(focusButton) {
    radio.panel = false;
    rp.hidden = true;
    el.radioBtn.setAttribute('aria-expanded', 'false');
    if (focusButton) el.radioBtn.focus();
  }
  el.tracksBtn.addEventListener('click', () => (ed.open ? closeEditor(false) : openEditor()));
  el.edClose.addEventListener('click', () => closeEditor(true));
  el.radioBtn.addEventListener('click', () => (radio.panel ? closeRadio(false) : openRadio()));
  el.rpClose.addEventListener('click', () => closeRadio(true));
  // Escape closes the panel (not from a field: there it's the field's)
  rp.addEventListener('keydown', (e) => {
    const t = e.target;
    const typing = t && ((t.tagName === 'INPUT' && !/^(checkbox|radio|button|file)$/i.test(t.type)) || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA');
    if (e.key !== 'Escape' || typing || e.ctrlKey || e.metaKey || e.altKey) return;
    e.preventDefault();
    closeRadio(true);
  });
  // the card picked on an earlier visit: back at once if the browser still allows it, else Reconnect
  // (a job: Disconnect waits for it)
  function restoreRadio() {
    if (!radio.ok) return;
    job(async () => {
      let dir = null;
      try { dir = await kv.get('radio'); } catch (e) { return; }
      if (!dir || typeof dir.getDirectoryHandle !== 'function') return;
      let p = 'granted';
      try { if (typeof dir.queryPermission === 'function') p = await dir.queryPermission({ mode: 'readwrite' }); } catch (e) { p = 'prompt'; }
      if (p === 'granted') {
        try { await useCard(dir, false, rstatus); } catch (e) { radio.dir = dir; radio.state = 'ask'; }
      } else {
        radio.dir = dir;
        radio.state = p === 'denied' ? 'off' : 'ask';
      }
    });
  }

  // ---------------------------------------------------------------- the game on the radio
  // The hosted site has the game's SD card files beside the page (sdcard/manifest.json and
  // sdcard/SCRIPTS/TOOLS/..., made by tools/sd_manifest.py). Install / update writes the editions
  // picked and makes their folders match the release, as replacing the whole folder would (an old
  // core.luac left in StickTimeBW/ has EdgeTX compile core.lua on the radio, which runs it out of
  // memory). The player's own files are never touched: the saves (*.dat, StickTimeLite/data.txt),
  // the tracks and the ghosts. The manifest is asked for afresh each time (a new release may be out),
  // and what it may write is checked first: only the game's own files, all under SCRIPTS/TOOLS.
  const GAME = typeof GAME_FILES === 'string' && GAME_FILES && /^https?:$/.test(location.protocol) ? GAME_FILES : '';
  const inst = { man: null, card: null, pick: {}, hint: '', err: '' };
  // EdgeTX's board in RADIO/radio.yml, only as a hint (when unsure, nothing is picked)
  const BOARDS = {
    color: /^(tx16s|tx16smk3|tx15|t15|t15pro|t16|t18|x10|x10express|x12s|nv14|el18|pl18|pl18ev|pl18u|nb4p|v12|v16|pa01|f16|gx15|st16|t22)$/,
    lite: /^(x7|x9d|x9dp|x9lite|xlite|t12|t8|tlite|tpro|lr3pro|tx12)$/,
    bw: /^(x9dp2019|x9e|x7access|x9lites|xlites|tx12mk2|zorro|boxer|pocket|mt12|gx12|t14|t20|tprov2|tpros|t12max|bumblebee|commando8)$/,
  };
  const KIND = { color: 'a color radio', bw: 'a B&W radio with an STM32F4', lite: 'an older B&W radio (STM32F2)' };
  function cmpVer(a, b) {
    const x = a.split('.').map(Number), y = b.split('.').map(Number);
    for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0);
    return 0;
  }
  async function sha256(buf) {
    return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', buf)), (b) => b.toString(16).padStart(2, '0')).join('');
  }
  // the player's own (the saves, the tracks and the ghosts): never written, never removed
  const KEEP = /(^|\/)(c\d+\.txt|[^/]*\.dat|data\.txt)$/i;
  const keepFile = (path) => KEEP.test(path) || !!(inst.man && inst.man.keep.some((k) => k.toLowerCase() === path.toLowerCase()));
  // what the site may write: the loaders, the game's files in the B&W and Lite folders, and the
  // READMEs of the tracks' and ghosts' folders (those only where there is none)
  const LOADERS = ['StickTime.lua', 'StickTimeBW.lua', 'StickTimeLite.lua'];
  const ED_FOLDERS = ['StickTimeBW', 'StickTimeLite'];
  const SHARED = ['StickTimeTracks/README.txt', 'StickTimeGhosts/README.txt'];
  const GAME_NAME = /^[A-Za-z0-9_-]+\.(lua|luac|txt)$/;
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  // what is wrong with the site's manifest ('' when nothing): it says what goes on the card
  function manProblem(m) {
    if (!m || typeof m !== 'object' || !Array.isArray(m.files) || !m.editions || typeof m.editions !== 'object' || !Array.isArray(m.keep)) return 'not a list of files';
    if (typeof m.version !== 'string' || !/^\d+(\.\d+)+$/.test(m.version) || m.base !== 'SCRIPTS/TOOLS') return 'its version or its folder';
    if (!m.keep.every((k) => typeof k === 'string')) return 'its list of the player\'s files';
    for (const [e, info] of Object.entries(m.editions)) {
      if (!own(KIND, e) || !info || typeof info.label !== 'string' || !LOADERS.includes(info.loader)
        || (info.folder !== null && !ED_FOLDERS.includes(info.folder))) return 'the ' + e + ' edition';
    }
    const seen = new Set();
    for (const f of m.files) {
      const p = f && typeof f.path === 'string' ? f.path : '';
      if (!p || seen.has(p.toLowerCase())) return 'a file without a name, or twice';
      seen.add(p.toLowerCase());
      if (KEEP.test(p) || m.keep.some((k) => k.toLowerCase() === p.toLowerCase())) return p + ' is the player\'s own';
      const info = own(m.editions, f.edition) ? m.editions[f.edition] : null;
      const ok = f.edition === 'shared' ? SHARED.includes(p)
        : !!info && (p === info.loader || (!!info.folder && p.startsWith(info.folder + '/') && GAME_NAME.test(p.slice(info.folder.length + 1))));
      if (!ok) return p + ' isn\'t one of the game\'s files';
      if (!Number.isInteger(f.size) || f.size < 0 || f.size > 1048576 || typeof f.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(f.sha256)) return p + '\'s size';
    }
    for (const info of Object.values(m.editions)) if (!m.files.some((f) => f.path === info.loader)) return info.loader + ' is missing';
    return '';
  }
  const siteError = (msg) => Object.assign(new Error(msg), { site: true });
  async function getManifest() {
    let man = null;
    try {
      const r = await fetch(new URL(GAME + 'manifest.json', location.href), { cache: 'no-cache' });
      if (r.ok) man = await r.json();
    } catch (e) { man = null; }
    if (!man) throw siteError('Couldn\'t get the game\'s files from the site: check the connection and try again.');
    const why = manProblem(man);
    if (why) throw siteError('The site\'s list of the game\'s files isn\'t right (' + why + '), so nothing is written: try again later.');
    inst.man = man;
    return man;
  }
  const toolsDir = (create) => walk(STEPS[radio.at].slice(0, -1), create);
  async function fileAt(dir, path, create) {
    const p = path.split('/');
    for (const s of p.slice(0, -1)) if (!(dir = await child(dir, s, 'directory', create))) return null;
    return child(dir, p[p.length - 1], 'file', create);
  }
  const sameAs = async (h, f) => {
    const file = h && await h.getFile();
    return !!file && file.size === f.size && await sha256(await file.arrayBuffer()) === f.sha256;
  };
  // a file of the release from the site, checked against the manifest (bytes as they are)
  async function siteFile(man, f) {
    let buf = null;
    try {
      const r = await fetch(new URL(GAME + man.base + '/' + f.path, location.href), { cache: 'no-cache' });
      if (r.ok) buf = await r.arrayBuffer();
    } catch (e) { buf = null; }
    if (!buf) throw siteError('Couldn\'t get ' + f.path + ' from the site: check the connection and try again.');
    if (buf.byteLength !== f.size || await sha256(buf) !== f.sha256) throw siteError('The site\'s ' + f.path + ' didn\'t arrive whole: try again.');
    return buf;
  }
  // a file of the release onto the card, over the one there (Chrome writes a swap file beside it and
  // puts it in place when the write is done: a cable pulled midway leaves the old file whole)
  async function putFile(tools, path, buf) {
    const p = path.split('/'), name = p.pop();
    let dir = tools;
    for (const s of p) dir = await child(dir, s, 'directory', true);
    const h = await child(dir, name, 'file', true);
    const w = await h.createWritable();
    await w.write(buf);
    await w.close();
  }
  // a file that is gone already is fine (the card itself being gone shows at the next step)
  async function removeFile(dir, name) {
    try { await dir.removeEntry(name); return true; }
    catch (e) { if (e && e.name === 'NotFoundError') return false; throw e; }
  }
  // what is on the card, edition by edition: installed, its version, the same as the release, and
  // the files in its folder the release doesn't have (whether its loader is there or not: Install
  // removes them all the same)
  async function survey(man) {
    const tools = await toolsDir(false), card = {};
    const release = new Set(man.files.map((f) => f.path.toLowerCase()));
    for (const [e, info] of Object.entries(man.editions)) {
      const files = man.files.filter((f) => f.edition === e);
      const loader = tools && await fileAt(tools, info.loader);
      let version = null, same = 0;
      if (loader) {
        const m = /StickTime(?: BW| Lite)? v(\d+(?:\.\d+)+)/.exec(await (await loader.getFile()).slice(0, 600).text());
        version = m ? m[1] : null;
        for (const f of files) if (await sameAs(await fileAt(tools, f.path), f)) same++;
      }
      const stale = tools ? await staleIn(tools, info.folder, release) : [];
      card[e] = { installed: !!loader, version, current: !!loader && same === files.length && !stale.length, stale };
    }
    return card;
  }
  async function staleIn(tools, folder, release) {
    const dir = folder && await child(tools, folder, 'directory'), out = [];
    if (dir) {
      for await (const h of dir.values()) {
        const p = folder + '/' + h.name;
        if (h.kind === 'file' && !release.has(p.toLowerCase()) && !keepFile(p)) out.push(h.name);
      }
    }
    return out;
  }
  // name.new files an older version of this page left behind (it wrote a copy first, then moved it)
  async function leftovers(tools, release) {
    const out = [];
    for (const folder of ['', ...ED_FOLDERS, 'StickTimeTracks', 'StickTimeGhosts']) {
      const dir = folder ? await child(tools, folder, 'directory') : tools;
      if (!dir) continue;
      for await (const h of dir.values()) {
        const p = (folder ? folder + '/' : '') + h.name;
        if (h.kind === 'file' && /\.new$/i.test(h.name) && release.has(p.slice(0, -4).toLowerCase())) out.push({ dir, name: h.name, path: p });
      }
    }
    return out;
  }
  async function boardHint() {
    const f = radio.at === 'card' && await fileAt(radio.dir, 'RADIO/radio.yml');
    const m = f && /^board:\s*["']?([\w+-]+)/m.exec(await (await f.getFile()).slice(0, 4096).text());
    if (!m) return null;
    const b = m[1].toLowerCase();
    return { board: m[1], e: ['color', 'lite', 'bw'].find((e) => BOARDS[e].test(b)) || null };
  }
  async function loadInstall() {
    let man;
    try { man = await getManifest(); }
    catch (e) {
      if (!e.site) throw e;
      inst.man = inst.card = null;
      inst.err = e.message;
      renderRadio();
      return;
    }
    inst.err = '';
    const first = !inst.card;
    inst.card = await survey(man);
    if (first) {
      // what is on the card already; else what RADIO/radio.yml says the radio is; else the player picks
      inst.pick = {};
      inst.hint = '';
      const have = Object.keys(inst.card).filter((e) => inst.card[e].installed);
      have.forEach((e) => { inst.pick[e] = true; });
      if (!have.length) {
        const h = await boardHint();
        if (h && h.e) { inst.pick[h.e] = true; inst.hint = 'RADIO/radio.yml says ' + h.board + ': ' + KIND[h.e] + '. '; }
        else inst.hint = (h ? 'RADIO/radio.yml says ' + h.board + ', which this page doesn\'t know. ' : '') + 'Pick the edition for your radio. ';
      }
    }
    renderInstall();
  }
  function renderInstall() {
    const man = inst.man, card = inst.card;
    if (!man || !card) return;
    el.edInstallHead.textContent = 'StickTime ' + man.version + ' from this site, onto ' + cardName(radio.dir);
    el.edEditions.innerHTML = Object.entries(man.editions).map(([e, info]) => {
      const c = card[e], newer = c.version && cmpVer(c.version, man.version) > 0;
      const gone = c.stale.length ? 'removes ' + andList(c.stale) : '';
      const st = !c.installed ? 'not installed' + (gone ? ' (installing ' + gone + ' from ' + info.folder + '/)' : '')
        : newer ? 'newer on the card (' + c.version + ')' : c.current ? 'up to date'
          : 'will be updated' + (c.version ? ' (' + c.version + ' on the card)' : '') + (gone ? ', ' + gone : '');
      return '<li><label><input type="checkbox" data-ed="' + e + '"' + (inst.pick[e] ? ' checked' : '') + '><b>' + esc(info.label) + '</b> ' +
        esc(info.loader) + (info.folder ? ' + ' + esc(info.folder) + '/' : '') + '</label><span class="ed-estate' + (c.installed && c.current ? ' ok' : '') + '">' + esc(st) + '</span></li>';
    }).join('');
    el.edInstallHint.textContent = inst.hint + 'Color: color screens. B&W: B&W radios with an STM32F4 (TX12 MkII, Zorro, Boxer, X9D+ 2019...). ' +
      'Lite: older B&W radios with an STM32F2 (X7, X9D, X9D+, T12...). Your tracks, ghosts and saves stay as they are.';
    renderRadio();
  }
  function installGame() {
    job(async () => {
      const man = await getManifest(), eds = Object.keys(man.editions).filter((e) => inst.pick[e]);
      if (!eds.length) return;
      const card = inst.card = await survey(man);
      const newer = eds.filter((e) => card[e].version && cmpVer(card[e].version, man.version) > 0);
      if (newer.length && !window.confirm('The radio has a newer StickTime (' + newer.map((e) => man.editions[e].label + ' ' + card[e].version).join(', ') +
        ') than this site\'s ' + man.version + '. Replace it with ' + man.version + '?')) {
        rstatus('Nothing changed on the radio.');
        renderInstall();
        return;
      }
      const files = man.files.filter((f) => f.edition === 'shared' || eds.includes(f.edition));
      const release = new Set(man.files.map((f) => f.path.toLowerCase()));
      const tools = await toolsDir(true), bar = el.edInstallBar, removed = [];
      bar.hidden = false;
      bar.max = files.length;
      let n = 0, wrote = 0;
      try {
        for (const f of files) {
          bar.value = n++;
          rstatus('Writing ' + f.path + ' (' + n + ' of ' + files.length + ')…');
          const h = await fileAt(tools, f.path);
          if (h && (f.edition === 'shared' || keepFile(f.path))) continue;      // a README there already; never the player's own
          if (await sameAs(h, f)) continue;
          await putFile(tools, f.path, await siteFile(man, f));
          wrote++;
        }
        for (const o of await leftovers(tools, release)) if (await removeFile(o.dir, o.name)) removed.push(o.path);
        // the edition folders as in the release: the files it doesn't have go (not the player's own);
        // not when going back to an older version, whose list can't know what the newer one needs
        for (const e of eds) {
          const folder = man.editions[e].folder, dir = folder && !newer.includes(e) && await child(tools, folder, 'directory');
          if (!dir) continue;
          for (const name of await staleIn(tools, folder, release)) if (await removeFile(dir, name)) removed.push(folder + '/' + name);
        }
      } finally {
        bar.value = files.length;
        bar.hidden = true;
      }
      const list = andList(eds.map((e) => man.editions[e].label));
      rstatus(wrote || removed.length ? 'StickTime ' + man.version + ' is on the radio: ' + list + '.' + (removed.length ? ' Removed ' + andList(removed) + '.' : '') +
        ' Eject the drive before unplugging it.' : 'StickTime ' + man.version + ' was already on the radio: ' + list + '. Nothing to write.', 'ok');
      inst.card = await survey(man);
      renderInstall();
    }, rstatus, true);
  }
  el.edEditions.addEventListener('change', (e) => {
    const b = e.target.closest('[data-ed]');
    if (b) { inst.pick[b.dataset.ed] = b.checked; renderRadio(); }
  });
  el.edInstallGo.addEventListener('click', installGame);

  const reduced = () => window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // a panel's top just under the sticky header
  function intoView(node, now) {
    const head = document.querySelector('.top');
    const y = node.getBoundingClientRect().top + window.scrollY - (head ? head.offsetHeight : 0) - 10;
    window.scrollTo({ top: Math.max(0, y), behavior: now || reduced() ? 'auto' : 'smooth' });
  }
  // ---------------------------------------------------------------- the work in progress
  let saveT = 0;
  function saveNow() {
    clearTimeout(saveT);
    try {
      localStorage.setItem(STORE, JSON.stringify({ v: 1, T: ed.T, slot: ed.slot, trees: ed.showTrees, view: { x: V.x, z: V.z, s: V.s }, saved: !unsaved() }));
    } catch (e) { /* storage blocked or full: the work stays for this visit */ }
  }
  function saveSoon() { clearTimeout(saveT); saveT = setTimeout(saveNow, 400); }
  function restore() {
    let o = null;
    try { o = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (e) { o = null; }
    const T = o && clean(o.T);
    if (!T) return false;
    ed.slot = clamp(parseInt(o.slot, 10) || 1, 1, SLOTS);
    ed.showTrees = !!o.trees;
    const v = o.view;
    if (v && Number.isFinite(v.x) && Number.isFinite(v.z) && Number.isFinite(v.s)) {
      V.x = v.x; V.z = v.z; V.s = clamp(v.s, SMIN, SMAX);
      ed.hadView = true;
    }
    load(T, false, !o.saved);                         // unsaved work stays so after a reload
    return true;
  }
  window.addEventListener('pagehide', saveNow);

  if (!restore()) load(fromBuiltin(D.tracks[0]), true);
  ed.undo.length = 0;
  // for the test suite (test/editor_test.py), next to window.sim's own hooks
  if (window.sim) {
    window.sim.editor = {
      track: () => JSON.parse(snap()),
      file: () => ed.file.text,
      problems: () => ed.probs.map((p) => p.msg),
      selected: () => [...ed.sel],
      radio: () => ({ ok: radio.ok, state: radio.state, at: radio.at, name: radio.dir && radio.dir.name, busy: radio.busy, game: GAME }),
      at(x, z) { const r = cv.getBoundingClientRect(); return [r.left + sx(x), r.top + sy(z)]; },   // a map point on the page
    };
  }
  if (typeof ResizeObserver === 'function') new ResizeObserver(resize).observe(el.edMapBox);
  window.addEventListener('resize', resize);
  restoreRadio();
})();
