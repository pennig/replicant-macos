// galaxy3d-engine.jsx — vanilla canvas 3D galaxy. Thousands of ambient stars
// in a barred spiral + bulge, a small set of charted systems with rich data,
// and a perspective camera you can rotate / zoom / pan (mouse + trackpad +
// touch). Draws everything to one canvas at devicePixelRatio for crispness;
// React only owns the HUD overlay. createGalaxy(canvas, opts) -> controller.
//
// Layers modulate how the FIELD reads (cluster-level signal); selection always
// returns the full system so the dossier can show everything regardless.

(function () {
  const { GAL_SYSTEMS, GAL_LINKS, rcMap } = window;
  const C = rcMap('dark');

  // spectral palette for ambient stars (weighted toward cool/common)
  const SPECTRAL = [
    { c: [255, 244, 234], w: 30 }, // warm white
    { c: [210, 224, 255], w: 14 }, // blue-white
    { c: [255, 226, 180], w: 22 }, // amber
    { c: [255, 198, 150], w: 16 }, // orange
    { c: [255, 170, 150], w: 10 }, // red
    { c: [190, 210, 255], w: 8 },  // blue
  ];
  function pickSpectral(rnd) {
    let total = 0; for (const s of SPECTRAL) total += s.w;
    let r = rnd() * total;
    for (const s of SPECTRAL) { r -= s.w; if (r <= 0) return s.c; }
    return SPECTRAL[0].c;
  }

  // layer colors (rgb)
  const LC = {
    presence: [255, 178, 62], relay: [255, 178, 62], life: [98, 211, 154],
    resource: [216, 176, 106], npc: [181, 139, 255], transit: [90, 169, 255],
  };

  function mulberry(seed) { let s = seed >>> 0; return () => { s |= 0; s = (s + 0x6D2B79F5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }

  // Build a soft round sprite once (controls bloom shape).
  function makeSprite(coreTight) {
    const S = 64, cv = document.createElement('canvas'); cv.width = cv.height = S;
    const x = cv.getContext('2d');
    const g = x.createRadialGradient(S / 2, S / 2, 0, S / 2, S / 2, S / 2);
    g.addColorStop(0, 'rgba(255,255,255,1)');
    g.addColorStop(coreTight ? 0.12 : 0.2, 'rgba(255,255,255,0.9)');
    g.addColorStop(0.42, 'rgba(255,255,255,0.18)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    x.fillStyle = g; x.fillRect(0, 0, S, S);
    return cv;
  }

  function createGalaxy(canvas, opts = {}) {
    const ctx = canvas.getContext('2d', { alpha: false });
    const sprite = makeSprite(true);
    const state = {
      yaw: 0.5, pitch: -0.92, zoom: 1.18, dist: 2.5,
      tween: null,
      panX: 0, panY: 0,
      starCount: opts.starCount || 1800,
      startZoom: opts.startZoom || 1.18,
      bloom: opts.bloom != null ? opts.bloom : 0.5, // 0..1
      autoRotate: opts.autoRotate !== false,
      layers: opts.layers || {},
      selected: null,
    };
    let W = 0, H = 0, DPR = 1;
    let stars = [];      // ambient field
    let charted = [];    // rich systems (world coords + data)
    let lastInteract = 0;

    // ── world generation ──────────────────────────────────────────
    function genField() {
      const rnd = mulberry(20240617);
      const N = state.starCount;
      const arms = 2, swirl = 2.6, R = 1.18;
      stars = new Array(N);
      for (let i = 0; i < N; i++) {
        const bulge = rnd() < 0.16;
        let t, ang, y;
        if (bulge) {
          t = Math.pow(rnd(), 1.8) * 0.34;
          ang = rnd() * Math.PI * 2;
          y = (rnd() - 0.5) * 0.34 * (1 - t);
        } else {
          t = Math.pow(rnd(), 0.62) * R;
          const arm = i % arms;
          const spread = (1 - t / R) * 0.34 + 0.04;
          ang = t * swirl + arm * Math.PI + (rnd() - 0.5) * spread * 2 + (rnd() - 0.5) * 0.5;
          y = (rnd() - 0.5) * (0.05 + (1 - t / R) * 0.07);
        }
        const col = pickSpectral(rnd);
        // inner stars run brighter so the bulge glows and arms fade outward
        const radial = Math.min(1, t / R);
        stars[i] = {
          x: Math.cos(ang) * t, y, z: Math.sin(ang) * t,
          col, mag: (0.28 + Math.pow(rnd(), 2.2) * 0.95) * (1.15 - radial * 0.4),
          tw: rnd() * Math.PI * 2, // twinkle phase
        };
      }
      // charted systems mapped into disc coords
      charted = GAL_SYSTEMS.map((s) => {
        const ang = (s.a * Math.PI) / 180;
        const t = 0.18 + s.r * 0.92;
        return { s, x: Math.cos(ang) * t, y: s.h * 0.34, z: Math.sin(ang) * t, sx: 0, sy: 0, sc: 0, vis: true };
      });
    }
    const chartedById = () => Object.fromEntries(charted.map((c) => [c.s.id, c]));

    // ── projection ────────────────────────────────────────────────
    function project(x, y, z) {
      const cy = Math.cos(state.yaw), sy = Math.sin(state.yaw);
      const cp = Math.cos(state.pitch), sp = Math.sin(state.pitch);
      // yaw about Y
      const x1 = x * cy + z * sy;
      const z1 = -x * sy + z * cy;
      const y1 = y;
      // pitch about X
      const y2 = y1 * cp - z1 * sp;
      const z2 = y1 * sp + z1 * cp;
      const denom = state.dist - z2;
      const scale = denom > 0.05 ? (2.4 / denom) : 0;
      const view = Math.min(W, H) * 0.5 * state.zoom;
      return {
        sx: W / 2 + x1 * scale * view + state.panX,
        sy: H / 2 + y2 * scale * view + state.panY,
        sc: scale, z2,
      };
    }

    // ── render ────────────────────────────────────────────────────
    function frame(now) {
      // camera tween (flyTo / flyBack)
      if (state.tween) {
        const tw = state.tween;
        const p = Math.min(1, (now - tw.t0) / tw.dur);
        const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
        state.zoom = tw.fromZoom + (tw.toZoom - tw.fromZoom) * e;
        if (tw.targetId) {
          const c = charted.find((x) => x.s.id === tw.targetId);
          if (c) {
            const raw = project(c.x, c.y, c.z); // includes current pan
            const rawX = raw.sx - state.panX, rawY = raw.sy - state.panY;
            const wantX = W / 2 - rawX, wantY = H / 2 - rawY;
            state.panX = tw.fromPanX + (wantX - tw.fromPanX) * e;
            state.panY = tw.fromPanY + (wantY - tw.fromPanY) * e;
          }
        } else {
          state.panX = tw.fromPanX * (1 - e);
          state.panY = tw.fromPanY * (1 - e);
        }
        if (!tw.midFired && p >= tw.midAt) { tw.midFired = true; tw.onMid && tw.onMid(); }
        if (p >= 1) { const done = tw.onDone; state.tween = null; done && done(); }
      }
      const L = state.layers;
      ctx.globalCompositeOperation = 'source-over';
      ctx.fillStyle = '#05070d';
      ctx.fillRect(0, 0, W, H);

      // faint galactic haze
      const hz = project(0, 0, 0);
      const hr = Math.min(W, H) * 0.42 * state.zoom * hz.sc;
      const hg = ctx.createRadialGradient(hz.sx, hz.sy, 0, hz.sx, hz.sy, Math.max(60, hr));
      hg.addColorStop(0, 'rgba(255,231,196,0.22)');
      hg.addColorStop(0.18, 'rgba(180,170,235,0.16)');
      hg.addColorStop(0.55, 'rgba(96,86,180,0.07)');
      hg.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.globalCompositeOperation = 'lighter';
      ctx.fillStyle = hg; ctx.fillRect(0, 0, W, H);

      // ambient field (additive)
      ctx.globalCompositeOperation = 'lighter';
      const bloomK = 0.5 + state.bloom * 1.8;
      const tw = now * 0.0012;
      for (let i = 0; i < stars.length; i++) {
        const st = stars[i];
        const p = project(st.x, st.y, st.z);
        if (p.sc <= 0 || p.sx < -40 || p.sx > W + 40 || p.sy < -40 || p.sy > H + 40) continue;
        const depth = Math.min(1.5, p.sc / 1.3);
        const tk = 0.84 + 0.16 * Math.sin(tw + st.tw);
        let a = Math.min(1, st.mag * depth * 1.5) * tk;
        if (a < 0.015) continue;
        const sz = (0.8 + st.mag * 2.2) * depth * bloomK;
        ctx.globalAlpha = a;
        // tint sprite via temporary fill: use drawImage then colored overlay is costly;
        // instead approximate color by drawing a small filled disc + sprite glow.
        ctx.drawImage(sprite, p.sx - sz, p.sy - sz, sz * 2, sz * 2);
      }
      // colored cores for brighter ambient stars (cheap pass)
      ctx.globalCompositeOperation = 'lighter';
      for (let i = 0; i < stars.length; i += 1) {
        const st = stars[i];
        if (st.mag < 0.7) continue;
        const p = project(st.x, st.y, st.z);
        if (p.sc <= 0) continue;
        const depth = Math.min(1.4, p.sc / 1.4);
        ctx.globalAlpha = Math.min(1, st.mag * depth) * 0.5;
        ctx.fillStyle = `rgb(${st.col[0]},${st.col[1]},${st.col[2]})`;
        const r = 0.5 + st.mag * depth * 0.9;
        ctx.beginPath(); ctx.arc(p.sx, p.sy, r, 0, 6.283); ctx.fill();
      }

      // relay links
      ctx.globalCompositeOperation = 'lighter';
      const byId = chartedById();
      if (L.relay) {
        for (const lk of GAL_LINKS) {
          const A = byId[lk.a], B = byId[lk.b]; if (!A || !B) continue;
          const pa = project(A.x, A.y, A.z), pb = project(B.x, B.y, B.z);
          const col = lk.owner === 'npc' ? LC.npc : LC.relay;
          ctx.strokeStyle = `rgba(${col[0]},${col[1]},${col[2]},${lk.owner === 'npc' ? 0.32 : 0.5})`;
          ctx.lineWidth = lk.planned ? 1 : 1.6;
          if (lk.planned) ctx.setLineDash([5, 6]); else ctx.setLineDash([]);
          // arc the link slightly off the straight line
          const mx = (pa.sx + pb.sx) / 2, my = (pa.sy + pb.sy) / 2 - Math.hypot(pb.sx - pa.sx, pb.sy - pa.sy) * 0.12;
          ctx.beginPath(); ctx.moveTo(pa.sx, pa.sy); ctx.quadraticCurveTo(mx, my, pb.sx, pb.sy); ctx.stroke();
        }
        ctx.setLineDash([]);
      }

      // charted systems
      ctx.globalCompositeOperation = 'lighter';
      // depth sort for label legibility
      const order = charted.map((c) => { const p = project(c.x, c.y, c.z); c.sx = p.sx; c.sy = p.sy; c.sc = p.sc; c.z2 = p.z2; return c; })
        .sort((a, b) => a.z2 - b.z2);
      for (const c of order) {
        if (c.sc <= 0) continue;
        const s = c.s;
        const depth = Math.min(1.5, c.sc / 1.4);
        const sel = state.selected === s.id;
        // base appearance
        let rgb = [255, 236, 200];
        let emphasis = 0.6;
        if (L.presence && s.presence === 'mine') { rgb = LC.presence; emphasis = 1; }
        else if (L.npc && s.presence === 'npc') { rgb = LC.npc; emphasis = 0.95; }
        else if (L.life && s.life) { rgb = LC.life; emphasis = 0.9; }
        else if (L.recon && s.recon === 'aware') { rgb = [150, 168, 200]; emphasis = 0.4; }
        // any layer on dims non-matching to add contrast
        const anyLayer = L.presence || L.relay || L.life || L.resource || L.npc;
        const matches = (L.presence && s.presence) || (L.relay && s.relay) || (L.life && s.life) || (L.resource && s.resource > 0.6) || (L.npc && s.presence === 'npc') || (L.recon);
        if (anyLayer && !matches) emphasis *= 0.45;

        const baseSz = (1.4 + (s.home ? 1.4 : 0.7)) * depth;
        const glow = baseSz * (2.2 + state.bloom * 2.2) * (sel ? 1.5 : 1);
        ctx.globalAlpha = (sel ? 1 : 0.5 + emphasis * 0.5);
        ctx.drawImage(sprite, c.sx - glow, c.sy - glow, glow * 2, glow * 2);
        // colored core
        ctx.globalAlpha = Math.min(1, 0.5 + emphasis * 0.6);
        ctx.fillStyle = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
        ctx.beginPath(); ctx.arc(c.sx, c.sy, Math.max(1, baseSz), 0, 6.283); ctx.fill();

        // resource ring
        if (L.resource && s.resource > 0.55) {
          ctx.globalAlpha = 0.5; ctx.globalCompositeOperation = 'source-over';
          ctx.strokeStyle = `rgba(${LC.resource[0]},${LC.resource[1]},${LC.resource[2]},0.7)`; ctx.lineWidth = 1;
          ctx.beginPath(); ctx.arc(c.sx, c.sy, baseSz + 5 + s.resource * 4, 0, 6.283); ctx.stroke();
          ctx.globalCompositeOperation = 'lighter';
        }
        // life pip
        if (L.life && s.life) {
          ctx.globalAlpha = 1; ctx.fillStyle = `rgb(${LC.life[0]},${LC.life[1]},${LC.life[2]})`;
          ctx.beginPath(); ctx.arc(c.sx + baseSz + 4, c.sy - baseSz - 4, 1.8, 0, 6.283); ctx.fill();
        }
      }
      // selection + labels (source-over for crisp text)
      ctx.globalCompositeOperation = 'source-over';
      for (const c of order) {
        if (c.sc <= 0) continue;
        const s = c.s; const sel = state.selected === s.id;
        const depth = Math.min(1.5, c.sc / 1.4);
        const showLabel = sel || s.home || s.presence === 'mine' || (state.zoom > 1.4 && c.sc > 1.0);
        if (sel) {
          ctx.strokeStyle = 'rgba(255,178,62,0.9)'; ctx.lineWidth = 1.3;
          ctx.beginPath(); ctx.arc(c.sx, c.sy, 13 + depth * 4, 0, 6.283); ctx.stroke();
          ctx.strokeStyle = 'rgba(255,178,62,0.25)';
          ctx.beginPath(); ctx.arc(c.sx, c.sy, 20 + depth * 5, 0, 6.283); ctx.stroke();
        }
        if (showLabel) {
          const reconMark = s.recon === 'scanned' ? '●' : s.recon === 'visited' ? '◐' : '○';
          ctx.font = `${s.home ? 700 : 500} 11px ${'ui-monospace, SF Mono, Menlo, monospace'}`;
          ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
          const tx = c.sx + 10, ty = c.sy - 9;
          ctx.fillStyle = 'rgba(0,0,0,0.55)';
          const label = s.name + '  ' + reconMark;
          const wm = ctx.measureText(label).width;
          ctx.fillRect(tx - 3, ty - 8, wm + 6, 16);
          ctx.fillStyle = sel ? '#ffb23e' : (s.presence === 'mine' ? '#ffd79a' : '#aeb8cc');
          ctx.fillText(label, tx, ty);
          if (s.presence === 'mine' && s.devices > 0) {
            ctx.fillStyle = '#ffb23e'; ctx.font = `700 9px ui-monospace, monospace`;
            ctx.fillText(s.devices + ' dev', tx, ty + 12);
          }
        }
      }

      // auto rotate
      if (state.autoRotate && !state.tween && now - lastInteract > 2200) state.yaw += 0.0006;
      ctx.globalAlpha = 1;
      raf = requestAnimationFrame(frame);
    }

    // ── interaction ───────────────────────────────────────────────
    const pointers = new Map();
    let dragMode = null, downPt = null, moved = 0, pinchD0 = 0, zoom0 = 1;
    function localXY(e) { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; }

    function onDown(e) {
      try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
      pointers.set(e.pointerId, localXY(e));
      lastInteract = performance.now(); moved = 0;
      if (pointers.size === 2) {
        const pts = [...pointers.values()]; pinchD0 = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y); zoom0 = state.zoom; dragMode = 'pinch';
      } else {
        downPt = localXY(e);
        dragMode = (e.shiftKey || e.button === 2 || e.button === 1) ? 'pan' : 'rotate';
      }
    }
    function onMove(e) {
      if (!pointers.has(e.pointerId)) return;
      const prev = pointers.get(e.pointerId); const cur = localXY(e);
      pointers.set(e.pointerId, cur);
      lastInteract = performance.now();
      if (dragMode === 'pinch' && pointers.size === 2) {
        const pts = [...pointers.values()]; const d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
        state.zoom = Math.max(0.35, Math.min(7, zoom0 * (d / pinchD0)));
        return;
      }
      const dx = cur.x - prev.x, dy = cur.y - prev.y; moved += Math.abs(dx) + Math.abs(dy);
      if (dragMode === 'pan') { state.panX += dx; state.panY += dy; }
      else { state.yaw += dx * 0.006; state.pitch = Math.max(-1.5, Math.min(1.5, state.pitch + dy * 0.006)); }
    }
    function onUp(e) {
      const wasClick = moved < 5 && dragMode !== 'pinch';
      pointers.delete(e.pointerId);
      if (pointers.size < 2 && dragMode === 'pinch') dragMode = null;
      if (wasClick && downPt) hitTest(downPt);
      if (pointers.size === 0) dragMode = null;
    }
    function onWheel(e) {
      e.preventDefault(); lastInteract = performance.now();
      if (e.ctrlKey || Math.abs(e.deltaY) < 50 && e.deltaX === 0 && !Number.isInteger(e.deltaY)) {
        state.zoom = Math.max(0.35, Math.min(7, state.zoom * Math.exp(-e.deltaY * 0.01)));
      } else if (e.shiftKey) { state.panX -= e.deltaX; state.panY -= e.deltaY; }
      else { state.zoom = Math.max(0.35, Math.min(7, state.zoom * Math.exp(-e.deltaY * 0.0016))); }
    }
    function hitTest(pt) {
      let best = null, bestD = 22;
      for (const c of charted) {
        if (c.sc <= 0) continue;
        const d = Math.hypot(c.sx - pt.x, c.sy - pt.y);
        if (d < bestD) { bestD = d; best = c.s.id; }
      }
      state.selected = best;
      opts.onSelect && opts.onSelect(best ? GAL_SYSTEMS.find((s) => s.id === best) : null);
    }

    function resize() {
      DPR = Math.min(2, window.devicePixelRatio || 1);
      const r = canvas.getBoundingClientRect();
      W = r.width; H = r.height;
      canvas.width = Math.round(W * DPR); canvas.height = Math.round(H * DPR);
      ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    }

    canvas.addEventListener('pointerdown', onDown);
    canvas.addEventListener('pointermove', onMove);
    canvas.addEventListener('pointerup', onUp);
    canvas.addEventListener('pointercancel', onUp);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    window.addEventListener('resize', resize);

    genField(); resize();
    let raf = requestAnimationFrame(frame);

    return {
      setLayers: (l) => { state.layers = l; },
      setOption: (k, v) => {
        if (k === 'starCount') { state.starCount = v; genField(); }
        else state[k] = v;
      },
      select: (id) => { state.selected = id; },
      focus: (id) => { const c = charted.find((x) => x.s.id === id); if (c) { state.selected = id; } },
      // Animate the camera to centre + zoom into a charted system, then back.
      flyTo: (id, o = {}) => {
        state.selected = id; lastInteract = performance.now() + 1e7; // suspend auto-rotate
        state.tween = { t0: performance.now(), dur: o.dur || 1150, fromZoom: state.zoom, toZoom: o.zoom || 5.2,
          fromPanX: state.panX, fromPanY: state.panY, targetId: id, midAt: o.midAt != null ? o.midAt : 0.55,
          midFired: false, onMid: o.onMid, onDone: o.onDone };
      },
      flyBack: (o = {}) => {
        state.tween = { t0: performance.now(), dur: o.dur || 950, fromZoom: state.zoom, toZoom: state.startZoom,
          fromPanX: state.panX, fromPanY: state.panY, targetId: null, midAt: o.midAt != null ? o.midAt : 0.25,
          midFired: false, onMid: o.onMid, onDone: () => { lastInteract = performance.now(); o.onDone && o.onDone(); } };
      },
      resetView: () => { state.yaw = 0.5; state.pitch = -0.92; state.zoom = state.startZoom; state.panX = 0; state.panY = 0; state.tween = null; },
      getState: () => state,
      getCharted: () => charted.map((x) => ({ id: x.s.id, sx: x.sx, sy: x.sy, sc: x.sc })),
      destroy: () => {
        cancelAnimationFrame(raf);
        canvas.removeEventListener('pointerdown', onDown); canvas.removeEventListener('pointermove', onMove);
        canvas.removeEventListener('pointerup', onUp); canvas.removeEventListener('pointercancel', onUp);
        canvas.removeEventListener('wheel', onWheel); window.removeEventListener('resize', resize);
      },
    };
  }

  window.createGalaxy = createGalaxy;
})();
