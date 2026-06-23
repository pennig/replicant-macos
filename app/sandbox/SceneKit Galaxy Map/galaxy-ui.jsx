// galaxy-ui.jsx — shared visual primitives for the Galaxy Explorer & Star
// System directions. Glass HUD chrome, deterministic starfield, the tilted
// galactic-disc renderer, and the animated orrery. Composed by the direction
// files. Exports to window. Relies on galaxy-data.jsx + data.js (DeviceGlyph).

(function () {
  const M = window.RD_MONO, F = window.RD_FONT;
  const { projDisc, makeStars, RECON, LIFE,
    SYS_STAR, SYS_HZ, SYS_PLANETS, SYS_BELT, SYS_LAGRANGE, SYS_DEVICES, SYS_VESSELS } = window;
  const DeviceGlyph = window.DeviceGlyph;

  const prefersStill = typeof window.matchMedia === 'function'
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Slow animation clock (seconds). Gated on reduced-motion → frozen pose.
  function useClock(speed = 1, frozen = false) {
    const [t, setT] = React.useState(0);
    React.useEffect(() => {
      if (frozen || prefersStill) return;
      let raf, start = performance.now();
      const tick = (now) => { setT(((now - start) / 1000) * speed); raf = requestAnimationFrame(tick); };
      raf = requestAnimationFrame(tick);
      return () => cancelAnimationFrame(raf);
    }, [speed, frozen]);
    return frozen || prefersStill ? 6.2 : t; // fixed pleasing pose when still
  }

  const cx = (...a) => a.filter(Boolean).join(' ');
  const colOf = (c, key) => c[key] || key;

  // ── Glass HUD chrome ────────────────────────────────────────────
  function Glass({ c, children, style, pad = 14, radius = 16 }) {
    return (
      <div style={{
        background: c.glass, backdropFilter: 'blur(26px) saturate(1.2)', WebkitBackdropFilter: 'blur(26px) saturate(1.2)',
        borderRadius: radius, padding: pad, boxShadow: `inset 0 0 0 0.5px ${c.glassLine}, ${c.glassShadow}`,
        color: c.t1, fontFamily: F, ...style,
      }}>{children}</div>
    );
  }

  function Eyebrow({ c, children, right }) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
        <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1.4, textTransform: 'uppercase', color: c.t3 }}>{children}</span>
        {right}
      </div>
    );
  }

  function Stat({ c, k, v, accent }) {
    return (
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: M, fontSize: 16, fontWeight: 700, color: accent ? c.accent : c.t1, lineHeight: 1 }}>{v}</div>
        <div style={{ fontSize: 9.5, color: c.t3, letterSpacing: 0.5, textTransform: 'uppercase', marginTop: 4 }}>{k}</div>
      </div>
    );
  }

  // Recon pip — filled (scanned) / half (visited) / open (aware).
  function ReconPip({ c, recon, size = 9 }) {
    const r = RECON[recon] || RECON.aware;
    const col = recon === 'aware' ? c.t3 : c.t2;
    return (
      <svg width={size} height={size} viewBox="0 0 10 10" style={{ display: 'block', flexShrink: 0 }}>
        <circle cx="5" cy="5" r="4" fill="none" stroke={col} strokeWidth="1.2" />
        {r.pip === 'full' && <circle cx="5" cy="5" r="4" fill={col} />}
        {r.pip === 'half' && <path d="M5 1 A4 4 0 0 1 5 9 Z" fill={col} />}
      </svg>
    );
  }

  function LayerToggle({ c, layer, on, onToggle }) {
    const col = colOf(c, layer.color);
    return (
      <button onClick={onToggle} style={{
        display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
        padding: '8px 10px', borderRadius: 9, border: 'none', fontFamily: F,
        background: on ? c.field : 'transparent', boxShadow: on ? `inset 0 0 0 0.5px ${c.glassLineSoft}` : 'none',
        opacity: on ? 1 : 0.5, transition: 'opacity .15s, background .15s',
      }}>
        <span style={{ width: 9, height: 9, borderRadius: 3, flexShrink: 0, background: on ? col : 'transparent', boxShadow: on ? `0 0 8px ${col}` : `inset 0 0 0 1.4px ${c.t3}` }} />
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: c.t1 }}>{layer.label}</span>
          <span style={{ display: 'block', fontSize: 10, color: c.t3, marginTop: 1 }}>{layer.desc}</span>
        </span>
        <span style={{ width: 26, height: 15, borderRadius: 8, flexShrink: 0, position: 'relative', background: on ? col : c.chipBg, boxShadow: on ? 'none' : `inset 0 0 0 0.5px ${c.glassLine}`, transition: 'background .15s' }}>
          <span style={{ position: 'absolute', top: 2, left: on ? 13 : 2, width: 11, height: 11, borderRadius: '50%', background: '#fff', transition: 'left .15s', boxShadow: '0 1px 2px rgba(0,0,0,0.3)' }} />
        </span>
      </button>
    );
  }

  function GlassButton({ c, children, primary, onClick, style }) {
    return (
      <button onClick={onClick} style={{
        display: 'inline-flex', alignItems: 'center', gap: 7, padding: '9px 15px', borderRadius: 10, border: 'none', cursor: 'pointer',
        fontFamily: F, fontSize: 12.5, fontWeight: 700, letterSpacing: 0.2,
        background: primary ? `linear-gradient(180deg, ${c.accent}, ${c.theme === 'light' ? '#cf8418' : '#ff9e2c'})` : c.field,
        color: primary ? (c.theme === 'light' ? '#fff' : '#2a1a05') : c.t1,
        boxShadow: primary ? `0 6px 18px ${c.accentSoft}` : `inset 0 0 0 0.5px ${c.glassLine}`, ...style,
      }}>{children}</button>
    );
  }

  // ── Starfield + nebula backdrop ────────────────────────────────
  function StarField({ c, seed = 7, n = 150, parallax = { x: 0, y: 0 }, nebula = true }) {
    const stars = React.useMemo(() => makeStars(n, seed), [n, seed]);
    const ink = c.theme === 'light' ? '#1b2230' : '#dfe8ff';
    return (
      <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', pointerEvents: 'none' }}>
        {nebula && c.theme !== 'light' && (
          <div style={{ position: 'absolute', inset: '-10%', background:
            'radial-gradient(620px 460px at 72% 22%, rgba(123,79,214,0.16), transparent 60%),'
            + 'radial-gradient(560px 520px at 24% 82%, rgba(63,211,203,0.12), transparent 62%),'
            + 'radial-gradient(680px 380px at 50% -8%, rgba(255,178,62,0.08), transparent 60%)',
            transform: `translate(${parallax.x * 0.6}px, ${parallax.y * 0.6}px)` }} />
        )}
        <svg width="100%" height="100%" style={{ position: 'absolute', inset: 0, opacity: c.theme === 'light' ? 0.5 : 0.85, transform: `translate(${parallax.x}px, ${parallax.y}px)` }}>
          {stars.map((s, i) => (
            <circle key={i} cx={`${s.x * 100}%`} cy={`${s.y * 100}%`} r={s.r} fill={ink} opacity={s.o} />
          ))}
        </svg>
      </div>
    );
  }

  // ── Galaxy disc renderer ───────────────────────────────────────
  // Projects GAL_SYSTEMS onto a tilted disc and draws plane rings, relay
  // links, and per-system markers honoring the active layers. variant tunes
  // the look ('atlas' clean rings, 'mesh' link-forward, 'cinematic' bloom).
  function GalaxyDisc({ c, systems, links, layers, selected, onSelect, rot = 0, scale, squash = 0.42, variant = 'atlas', size }) {
    const W = size.w, H = size.h;
    const ox = W * 0.46, oy = H * 0.52;
    const L = layers || {};
    const proj = systems.map((s) => ({ s, p: projDisc(s, scale, rot, squash) }));
    const byId = Object.fromEntries(proj.map((x) => [x.s.id, x]));
    const sorted = [...proj].sort((a, b) => a.p.depth - b.p.depth);

    const linkColor = (owner) => (owner === 'npc' ? c.npc : c.relay);

    return (
      <div style={{ position: 'absolute', inset: 0 }}>
        {/* plane rings */}
        {variant !== 'cinematic' && (
          <svg width={W} height={H} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
            {[0.4, 0.7, 1.0].map((rr, i) => (
              <ellipse key={i} cx={ox} cy={oy} rx={scale * rr} ry={scale * rr * squash} fill="none" stroke={c.planeSoft} strokeWidth="1" />
            ))}
            <ellipse cx={ox} cy={oy} rx={scale} ry={scale * squash} fill="none" stroke={c.plane} strokeWidth="1.2" strokeDasharray="2 6" />
          </svg>
        )}

        {/* relay links (under markers, depth-aware glow) */}
        <svg width={W} height={H} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          <defs>
            <filter id={`glow-${variant}`} x="-40%" y="-40%" width="180%" height="180%">
              <feGaussianBlur stdDeviation="3.4" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
            </filter>
          </defs>
          {L.relay && links.map((lk, i) => {
            const A = byId[lk.a], B = byId[lk.b]; if (!A || !B) return null;
            const col = linkColor(lk.owner);
            const dim = lk.owner === 'npc' ? 0.5 : 1;
            const mx = (A.p.x + B.p.x) / 2, my = Math.min(A.p.y, B.p.y) - 26 - Math.abs(A.p.x - B.p.x) * 0.06;
            return (
              <path key={i} d={`M ${ox + A.p.x} ${oy + A.p.y} Q ${ox + mx} ${oy + my} ${ox + B.p.x} ${oy + B.p.y}`}
                fill="none" stroke={col} strokeWidth={lk.planned ? 1.2 : 1.8} strokeDasharray={lk.planned ? '4 5' : 'none'}
                opacity={0.42 * dim} filter={`url(#glow-${variant})`} strokeLinecap="round" />
            );
          })}
        </svg>

        {/* system markers */}
        {sorted.map(({ s, p }) => (
          <GalaxySystem key={s.id} c={c} s={s} p={p} ox={ox} oy={oy} layers={L} variant={variant}
            selected={selected === s.id} onSelect={onSelect} />
        ))}
      </div>
    );
  }

  function GalaxySystem({ c, s, p, ox, oy, layers, variant, selected, onSelect }) {
    const L = layers || {};
    const recon = RECON[s.recon] || RECON.aware;
    const reconDim = L.recon ? recon.dim : 0.92;
    const base = 2.6 + p.depth * 3.4 + (s.home ? 2 : 0) + s.resource * (L.resource ? 2.4 : 0);
    const presenceCol = s.presence === 'npc' ? c.npc : c.accent;
    const showPresence = L.presence && s.presence;
    const showNpc = L.npc && s.presence === 'npc';
    const lifeCol = c.life;
    const starCol = s.home ? c.accent : (L.recon && s.recon === 'aware' ? c.starDim : c.star);

    return (
      <div onClick={(e) => { e.stopPropagation(); onSelect && onSelect(s.id); }}
        style={{ position: 'absolute', left: ox + p.x, top: oy + p.y, transform: 'translate(-50%,-50%)', cursor: 'pointer', zIndex: Math.round(p.depth * 100) + 10 }}>
        {/* altitude stem to plane */}
        {Math.abs(p.stem) > 6 && (
          <span style={{ position: 'absolute', left: '50%', top: '50%', width: 1, height: Math.abs(p.stem), background: `linear-gradient(${p.stem < 0 ? 180 : 0}deg, ${c.plane}, transparent)`, transform: `translateX(-0.5px) ${p.stem < 0 ? '' : 'translateY(-100%)'}` }} />
        )}
        {/* selection halo */}
        {selected && <span style={{ position: 'absolute', left: '50%', top: '50%', width: base * 6 + 22, height: base * 6 + 22, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.accentLine}`, animation: prefersStill ? 'none' : 'rcPulse 2.4s ease-in-out infinite' }} />}
        {/* resource ring */}
        {L.resource && s.resource > 0.55 && <span style={{ position: 'absolute', left: '50%', top: '50%', width: base * 4 + 8, height: base * 4 + 8, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.resource}`, opacity: 0.5 }} />}
        {/* presence ring */}
        {showPresence && <span style={{ position: 'absolute', left: '50%', top: '50%', width: base * 4 + 18, height: base * 4 + 18, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${presenceCol}`, opacity: 0.8 }} />}
        {/* the star */}
        <span style={{ position: 'absolute', left: '50%', top: '50%', width: base * 2, height: base * 2, borderRadius: '50%', transform: 'translate(-50%,-50%)',
          background: `radial-gradient(circle at 38% 34%, #fff, ${starCol})`, opacity: reconDim,
          boxShadow: variant === 'cinematic'
            ? `0 0 ${10 + p.depth * 18}px ${base * 1.6}px ${starCol}cc, 0 0 4px 1px #fff`
            : `0 0 ${6 + p.depth * 8}px ${starCol}aa` }} />
        {/* life dot */}
        {L.life && s.life ? <span style={{ position: 'absolute', left: `calc(50% + ${base + 3}px)`, top: `calc(50% - ${base + 3}px)`, width: 5, height: 5, borderRadius: '50%', background: lifeCol, boxShadow: `0 0 6px ${lifeCol}`, transform: 'translate(-50%,-50%)' }} /> : null}
        {/* device tick */}
        {L.presence && s.presence === 'mine' && s.devices > 0 ? <span style={{ position: 'absolute', left: `calc(50% - ${base + 4}px)`, top: `calc(50% + ${base + 2}px)`, fontFamily: M, fontSize: 8.5, fontWeight: 700, color: c.accent, transform: 'translate(-50%,-50%)' }}>{s.devices}</span> : null}
        {/* label */}
        {(p.depth > 0.32 || s.home || selected || s.presence) && (
          <span style={{ position: 'absolute', left: '50%', top: `calc(50% + ${base + 6}px)`, transform: 'translateX(-50%)', whiteSpace: 'nowrap', fontFamily: M, fontSize: 10, fontWeight: s.home ? 700 : 500, letterSpacing: 0.3, color: selected ? c.accent : (s.recon === 'aware' && L.recon ? c.t3 : c.t2), textShadow: c.theme === 'light' ? 'none' : '0 1px 6px rgba(0,0,0,0.8)' }}>
            {s.name}{L.recon && <span style={{ marginLeft: 4, opacity: 0.7 }}>{recon.pip === 'full' ? '●' : recon.pip === 'half' ? '◐' : '○'}</span>}
          </span>
        )}
      </div>
    );
  }

  // ── Orrery (star-system) renderer ──────────────────────────────
  const D2R = Math.PI / 180;
  function planetAngle(pl, t) { return (pl.phase0 + (360 * t) / pl.period) * D2R; }
  function ellipsePos(a, ecc, ang) { return { x: Math.cos(ang) * a, y: Math.sin(ang) * a * ecc }; }

  function Orrery({ c, t, selected, onSelect, variant = 'orrery', size, showLabels = true, show }) {
    const W = size.w, H = size.h, ox = W * 0.5, oy = H * 0.52;
    const SH = Object.assign({ hz: true, belt: true, kuiper: false, oort: false }, show || {});
    const planetById = Object.fromEntries(SYS_PLANETS.map((p) => [p.id, p]));

    // Far-system fields, placed on a compressed (log-ish) scale so the inner
    // planets stay legible while the outer structure is still indicated.
    const KUIPER = { inner: 470, outer: 560 };
    const OORT = { inner: 700, outer: 760 };
    const kuiper = React.useMemo(() => {
      let s = 7; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
      return Array.from({ length: 240 }, () => ({ a: KUIPER.inner + rnd() * (KUIPER.outer - KUIPER.inner), ang: rnd() * 360, r: rnd() * 0.9 + 0.3, o: rnd() * 0.45 + 0.18 }));
    }, []);
    const oort = React.useMemo(() => {
      let s = 41; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
      return Array.from({ length: 320 }, () => { const rr = OORT.inner + rnd() * (OORT.outer - OORT.inner); const ang = rnd() * 360; return { x: Math.cos(ang * D2R) * rr, y: Math.sin(ang * D2R) * rr * 0.96, r: rnd() * 0.8 + 0.2, o: rnd() * 0.3 + 0.08 }; });
    }, []);

    const posOf = (id) => {
      if (id === 'belt') { const a = (SYS_BELT.inner + SYS_BELT.outer) / 2; const ang = (t * 14 + 40) * D2R; return ellipsePos(a, 0.94, ang); }
      const pl = planetById[id]; if (!pl) return { x: 0, y: 0 };
      return ellipsePos(pl.orbit, pl.ecc, planetAngle(pl, t));
    };

    // Course arc: bow the path AWAY from the star so it never crosses the
    // sun (or cuts straight through the inner system). Control point is the
    // midpoint pushed radially outward from the star centre.
    const routeArc = (fromId, toId) => {
      const a = posOf(fromId), b = posOf(toId);
      const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      const mlen = Math.hypot(mx, my) || 1;
      let dx = mx / mlen, dy = my / mlen;
      if (mlen < 8) { const lx = b.x - a.x, ly = b.y - a.y, ll = Math.hypot(lx, ly) || 1; dx = -ly / ll; dy = lx / ll; }
      const reach = Math.max(Math.hypot(a.x, a.y), Math.hypot(b.x, b.y));
      const clear = Math.max(60, reach * 0.34);
      return { a, b, cx: mx + dx * clear, cy: my + dy * clear };
    };
    const bez = (a, cx, cy, b, u) => { const k = 1 - u; return { x: k * k * a.x + 2 * k * u * cx + u * u * b.x, y: k * k * a.y + 2 * k * u * cy + u * u * b.y }; };

    // belt asteroids (deterministic)
    const belt = React.useMemo(() => {
      let s = 99; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
      return Array.from({ length: SYS_BELT.count }, () => {
        const a = SYS_BELT.inner + rnd() * (SYS_BELT.outer - SYS_BELT.inner);
        return { a, ang: rnd() * 360, r: rnd() * 0.9 + 0.3, o: rnd() * 0.5 + 0.2 };
      });
    }, []);

    const cinematic = variant === 'cinematic';
    const orbitStroke = variant === 'instrument' ? c.plane : c.planeSoft;

    return (
      <div style={{ position: 'absolute', inset: 0 }}>
        <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
          <defs>
            <radialGradient id={`star-${variant}`} cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor="#fff" /><stop offset="34%" stopColor={SYS_STAR.color} /><stop offset="100%" stopColor={SYS_STAR.glow} />
            </radialGradient>
            <radialGradient id={`hz-${variant}`} cx="50%" cy="50%" r="50%">
              <stop offset="0%" stopColor="transparent" /><stop offset={`${(SYS_HZ.inner / SYS_HZ.outer) * 100}%`} stopColor="transparent" />
              <stop offset={`${(SYS_HZ.inner / SYS_HZ.outer) * 100}%`} stopColor={c.hzBand} /><stop offset="100%" stopColor={c.hzBand} />
            </radialGradient>
            <filter id={`obloom-${variant}`} x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="5" result="b" /><feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge></filter>
          </defs>

          {/* Oort cloud — diffuse spherical shell (compressed scale) */}
          {SH.oort && <g>
            <circle cx={ox} cy={oy} r={(OORT.inner + OORT.outer) / 2} fill="none" stroke={c.theme === 'light' ? 'rgba(28,34,48,0.10)' : 'rgba(150,180,230,0.10)'} strokeWidth={OORT.outer - OORT.inner} opacity="0.4" />
            {oort.map((b, i) => <circle key={i} cx={ox + b.x} cy={oy + b.y} r={b.r} fill={c.theme === 'light' ? '#5a6478' : '#aebbd6'} opacity={b.o} />)}
            <text x={ox} y={oy - (OORT.inner + OORT.outer) / 2 - 8} textAnchor="middle" fill={c.t3} fontSize="12" fontFamily={M} letterSpacing="1">OORT CLOUD<tspan fill={c.t3} opacity="0.7">  · log scale</tspan></text>
          </g>}

          {/* Kuiper belt — icy ring band (compressed scale) */}
          {SH.kuiper && <g>
            <ellipse cx={ox} cy={oy} rx={KUIPER.inner} ry={KUIPER.inner * 0.96} fill="none" stroke={c.planeSoft} strokeWidth="1" strokeDasharray="2 6" />
            <ellipse cx={ox} cy={oy} rx={KUIPER.outer} ry={KUIPER.outer * 0.96} fill="none" stroke={c.planeSoft} strokeWidth="1" strokeDasharray="2 6" />
            {kuiper.map((b, i) => { const pos = ellipsePos(b.a, 0.96, (b.ang + t * 2) * D2R); return (
              <circle key={i} cx={ox + pos.x} cy={oy + pos.y} r={b.r} fill={c.theme === 'light' ? '#7b8aa3' : '#9fb3d6'} opacity={b.o} />
            ); })}
            <text x={ox} y={oy - (KUIPER.inner + KUIPER.outer) / 2 + 3} textAnchor="middle" fill={c.t3} fontSize="11" fontFamily={M} letterSpacing="1">KUIPER BELT</text>
          </g>}
          {SH.hz && <g>
            <ellipse cx={ox} cy={oy} rx={SYS_HZ.outer} ry={SYS_HZ.outer * 0.94} fill={`url(#hz-${variant})`} opacity="0.9" />
            <ellipse cx={ox} cy={oy} rx={SYS_HZ.inner} ry={SYS_HZ.inner * 0.94} fill="none" stroke={c.hzLine} strokeWidth="1" strokeDasharray="2 5" />
            <ellipse cx={ox} cy={oy} rx={SYS_HZ.outer} ry={SYS_HZ.outer * 0.94} fill="none" stroke={c.hzLine} strokeWidth="1" strokeDasharray="2 5" />
          </g>}

          {/* orbits */}
          {SYS_PLANETS.map((pl) => (
            <ellipse key={pl.id} cx={ox} cy={oy} rx={pl.orbit} ry={pl.orbit * pl.ecc} fill="none"
              stroke={selected === pl.id ? c.accentLine : orbitStroke} strokeWidth={selected === pl.id ? 1.5 : 1} />
          ))}

          {/* belt */}
          {SH.belt && belt.map((b, i) => { const pos = ellipsePos(b.a, 0.94, (b.ang + t * 8) * D2R); return (
            <circle key={i} cx={ox + pos.x} cy={oy + pos.y} r={b.r} fill={c.theme === 'light' ? '#9a6f1e' : '#cdb38a'} opacity={b.o} />
          ); })}

          {/* the star */}
          <circle cx={ox} cy={oy} r={SYS_STAR.r * (cinematic ? 1.2 : 1)} fill={`url(#star-${variant})`} filter={cinematic ? `url(#obloom-${variant})` : 'none'} />
          {cinematic && <circle cx={ox} cy={oy} r={SYS_STAR.r * 2.4} fill={SYS_STAR.glow} opacity="0.12" />}
        </svg>

        {/* course arcs for vessels — bowed clear of the star */}
        <svg width={W} height={H} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          {SYS_VESSELS.map((v) => { const r = routeArc(v.from, v.to); const u = (v.t + t * 0.018) % 1; const p = bez(r.a, r.cx, r.cy, r.b, u); return (
            <g key={v.code}>
              <path d={`M ${ox + r.a.x} ${oy + r.a.y} Q ${ox + r.cx} ${oy + r.cy} ${ox + r.b.x} ${oy + r.b.y}`} fill="none" stroke={c.transit} strokeWidth="1" strokeDasharray="3 6" opacity="0.4" strokeLinecap="round" />
              <circle cx={ox + p.x} cy={oy + p.y} r="2.4" fill={c.transit} opacity="0.5" />
            </g>
          ); })}
        </svg>

        {/* lagrange points */}
        {SYS_LAGRANGE.map((lp) => {
          const host = planetById[lp.host]; const hang = planetAngle(host, t);
          let pos;
          if (lp.kind === 'trojan') pos = ellipsePos(host.orbit, host.ecc, hang + lp.lead * D2R);
          else pos = ellipsePos(host.orbit * lp.t, host.ecc, hang);
          return <LagrangeMark key={lp.id} c={c} lp={lp} x={ox + pos.x} y={oy + pos.y} selected={selected === lp.id} onSelect={onSelect} />;
        })}

        {/* planets + moons */}
        {SYS_PLANETS.map((pl) => {
          const pos = ellipsePos(pl.orbit, pl.ecc, planetAngle(pl, t));
          return <Planet key={pl.id} c={c} pl={pl} x={ox + pos.x} y={oy + pos.y} t={t} variant={variant}
            selected={selected === pl.id} onSelect={onSelect} showLabel={showLabels} />;
        })}

        {/* devices stationed at belt */}
        {SYS_DEVICES.filter((d) => d.at === 'belt').map((d, i) => {
          const pos = posOf('belt'); const off = i * 26 - 13;
          return <DeviceMark key={d.code} c={c} d={d} x={ox + pos.x + off} y={oy + pos.y - 8} selected={selected === d.code} onSelect={onSelect} />;
        })}

        {/* vessels in transit (positioned along the arc) */}
        {SYS_VESSELS.map((v) => { const r = routeArc(v.from, v.to); const u = (v.t + t * 0.018) % 1; const p = bez(r.a, r.cx, r.cy, r.b, u); return (
          <VesselMark key={v.code} c={c} v={v} x={ox + p.x} y={oy + p.y} selected={selected === v.code} onSelect={onSelect} />
        ); })}
      </div>
    );
  }

  function Planet({ c, pl, x, y, t, variant, selected, onSelect }) {
    const cinematic = variant === 'cinematic';
    return (
      <div onClick={(e) => { e.stopPropagation(); onSelect && onSelect(pl.id); }} style={{ position: 'absolute', left: x, top: y, transform: 'translate(-50%,-50%)', cursor: 'pointer', zIndex: 20 }}>
        {selected && <span style={{ position: 'absolute', left: '50%', top: '50%', width: pl.r * 2 + 18, height: pl.r * 2 + 18, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.accentLine}`, animation: prefersStill ? 'none' : 'rcPulse 2.4s ease-in-out infinite' }} />}
        {pl.ring && <span style={{ position: 'absolute', left: '50%', top: '50%', width: pl.r * 3.4, height: pl.r * 1.5, borderRadius: '50%', transform: 'translate(-50%,-50%) rotate(-18deg)', boxShadow: `inset 0 0 0 1.4px ${c.theme === 'light' ? 'rgba(154,111,30,0.5)' : 'rgba(205,179,138,0.6)'}` }} />}
        <span style={{ display: 'block', width: pl.r * 2, height: pl.r * 2, borderRadius: '50%', background: `radial-gradient(circle at 34% 30%, ${mix(pl.color, '#ffffff', 0.5)}, ${pl.color} 64%, ${mix(pl.color, '#000', 0.45)})`, boxShadow: cinematic ? `0 0 14px ${pl.color}88, inset -2px -2px 6px rgba(0,0,0,0.5)` : `inset -2px -2px 5px rgba(0,0,0,0.45)` }} />
        {/* moons */}
        {(pl.moons || []).map((m, i) => { const ang = (m.phase0 + (360 * t) / m.period) * D2R; const mx = Math.cos(ang) * m.orbit, my = Math.sin(ang) * m.orbit * 0.85; return (
          <span key={i} style={{ position: 'absolute', left: `calc(50% + ${mx}px)`, top: `calc(50% + ${my}px)`, width: m.r * 2, height: m.r * 2, borderRadius: '50%', background: m.color, transform: 'translate(-50%,-50%)', boxShadow: 'inset -1px -1px 2px rgba(0,0,0,0.5)' }} />
        ); })}
        {pl.devices > 0 ? <span style={{ position: 'absolute', left: `calc(50% + ${pl.r + 4}px)`, top: `calc(50% - ${pl.r + 4}px)`, width: 6, height: 6, borderRadius: 2, background: c.accent, boxShadow: `0 0 6px ${c.accent}`, transform: 'translate(-50%,-50%)' }} /> : null}
        {pl.life ? <span style={{ position: 'absolute', left: `calc(50% - ${pl.r + 4}px)`, top: `calc(50% - ${pl.r + 4}px)`, width: 5, height: 5, borderRadius: '50%', background: c.life, boxShadow: `0 0 6px ${c.life}`, transform: 'translate(-50%,-50%)' }} /> : null}
        <span style={{ position: 'absolute', left: '50%', top: `calc(50% + ${pl.r + 9}px)`, transform: 'translateX(-50%)', whiteSpace: 'nowrap', fontFamily: M, fontSize: 9.5, fontWeight: selected ? 700 : 500, color: selected ? c.accent : c.t2, textShadow: c.theme === 'light' ? 'none' : '0 1px 5px rgba(0,0,0,0.8)' }}>{pl.name}</span>
      </div>
    );
  }

  function LagrangeMark({ c, lp, x, y, selected, onSelect }) {
    const active = !!lp.device;
    return (
      <div onClick={(e) => { e.stopPropagation(); onSelect && onSelect(lp.id); }} style={{ position: 'absolute', left: x, top: y, transform: 'translate(-50%,-50%)', cursor: 'pointer', zIndex: 18 }}>
        {selected && <span style={{ position: 'absolute', left: '50%', top: '50%', width: 22, height: 22, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.accentLine}` }} />}
        <svg width="14" height="14" viewBox="0 0 14 14" style={{ display: 'block' }}>
          <path d="M7 1 L13 7 L7 13 L1 7 Z" fill="none" stroke={active ? c.accent : c.t3} strokeWidth="1.2" opacity={active ? 0.95 : 0.6} />
          {active && <circle cx="7" cy="7" r="1.6" fill={c.accent} />}
        </svg>
        <span style={{ position: 'absolute', left: '50%', top: '100%', transform: 'translateX(-50%)', fontFamily: M, fontSize: 8.5, fontWeight: 700, color: active ? c.accent : c.t3, letterSpacing: 0.4 }}>{lp.id}</span>
      </div>
    );
  }

  function DeviceMark({ c, d, x, y, selected, onSelect }) {
    const tone = d.status === 'mining' || d.status === 'printing' ? c.accent : d.status === 'inactive' ? c.t3 : c.sense;
    return (
      <div onClick={(e) => { e.stopPropagation(); onSelect && onSelect(d.code); }} style={{ position: 'absolute', left: x, top: y, transform: 'translate(-50%,-50%)', cursor: 'pointer', zIndex: 22 }}>
        {selected && <span style={{ position: 'absolute', left: '50%', top: '50%', width: 30, height: 30, borderRadius: 9, transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.accentLine}` }} />}
        <span style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', width: 20, height: 20, borderRadius: 6, background: c.glass, boxShadow: `inset 0 0 0 0.5px ${c.glassLine}` }}>
          {DeviceGlyph && <DeviceGlyph kind={({ mining_drone: 'hex', forge: 'grid', survey_probe: 'orbit', ftl_relay: 'concentric', surge_plate: 'diamond' })[d.type] || 'hex'} size={13} color={tone} />}
        </span>
      </div>
    );
  }

  function VesselMark({ c, v, x, y, selected, onSelect }) {
    const hero = v.name === 'HEAVEN';
    const col = hero ? c.accent : c.transit;
    return (
      <div onClick={(e) => { e.stopPropagation(); onSelect && onSelect(v.code); }} style={{ position: 'absolute', left: x, top: y, transform: 'translate(-50%,-50%)', cursor: 'pointer', zIndex: 30 }}>
        {selected && <span style={{ position: 'absolute', left: '50%', top: '50%', width: 30, height: 30, borderRadius: '50%', transform: 'translate(-50%,-50%)', boxShadow: `inset 0 0 0 1.4px ${c.accentLine}`, animation: prefersStill ? 'none' : 'rcPulse 2s ease-in-out infinite' }} />}
        <span style={{ position: 'absolute', left: '50%', top: '50%', width: 7, height: 7, borderRadius: '50%', background: col, transform: 'translate(-50%,-50%)', boxShadow: `0 0 ${hero ? 12 : 7}px ${col}` }} />
        {hero && <span style={{ position: 'absolute', left: '50%', top: `calc(50% - 13px)`, transform: 'translateX(-50%)', whiteSpace: 'nowrap', fontFamily: M, fontSize: 9, fontWeight: 700, letterSpacing: 0.6, color: c.accent, textShadow: c.theme === 'light' ? 'none' : '0 1px 5px rgba(0,0,0,0.9)' }}>HEAVEN</span>}
      </div>
    );
  }

  function mix(a, b, t) {
    const pa = parseInt(a.slice(1), 16), pb = parseInt(b.slice(1), 16);
    const ar = pa >> 16, ag = (pa >> 8) & 255, ab = pa & 255;
    const br = pb >> 16, bg = (pb >> 8) & 255, bb = pb & 255;
    const r = Math.round(ar + (br - ar) * t), g = Math.round(ag + (bg - ag) * t), bl = Math.round(ab + (bb - ab) * t);
    return `rgb(${r},${g},${bl})`;
  }

  // keyframes (once)
  if (!document.getElementById('rc-map-kf')) {
    const st = document.createElement('style'); st.id = 'rc-map-kf';
    st.textContent = '@keyframes rcPulse{0%,100%{opacity:.9}50%{opacity:.35}}@keyframes rcDrift{from{transform:translateY(0)}to{transform:translateY(-6px)}}';
    document.head.appendChild(st);
  }

  Object.assign(window, {
    useClock, Glass, Eyebrow, Stat, ReconPip, LayerToggle, GlassButton, StarField,
    GalaxyDisc, Orrery, prefersStill,
  });
})();
