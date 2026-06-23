// Storyboard.jsx — galaxy↔system drill-down transition, 5 key frames on one
// board. Schematic snapshots of the zoom-into-system animation we'd build in
// SceneKit. <DrillStoryboard theme/>.

(function () {
  const M = window.RD_MONO, F = window.RD_FONT;
  const { rcMap, GAL_SYSTEMS, makeStars } = window;

  const BOARD = { w: 1248, h: 560 };
  const FW = 212, FH = 360;

  function Mini({ children, w = FW, h = FH }) { return <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ display: 'block' }}>{children}</svg>; }

  function frameBg(c) {
    return c.theme === 'light'
      ? 'radial-gradient(120% 100% at 50% 30%, #f4efe6, #e3dccf)'
      : 'radial-gradient(120% 100% at 50% 30%, #101a30, #07090f)';
  }

  function MiniStars({ c, seed, w = FW, h = FH }) {
    const stars = React.useMemo(() => makeStars(40, seed), [seed]);
    const ink = c.theme === 'light' ? '#1b2230' : '#dfe8ff';
    return <g>{stars.map((s, i) => <circle key={i} cx={s.x * w} cy={s.y * h} r={s.r * 0.8} fill={ink} opacity={s.o * 0.8} />)}</g>;
  }

  // disc projection (top-down squashed) at a given zoom centered on Chamakuy.
  function discPts(cx, cy, scale, squash) {
    return GAL_SYSTEMS.map((s) => { const a = s.a * Math.PI / 180; return { s, x: cx + Math.cos(a) * s.r * scale, y: cy + Math.sin(a) * s.r * scale * squash, d: (Math.sin(a) + 1) / 2 }; });
  }
  const CHK = GAL_SYSTEMS.find((s) => s.id === 'CHK');
  const chkBase = (() => { const a = CHK.a * Math.PI / 180; return { ux: Math.cos(a) * CHK.r, uy: Math.sin(a) * CHK.r }; })();

  function Frame({ c, n, title, caption, children }) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, width: FW }}>
        <div style={{ position: 'relative', width: FW, height: FH, borderRadius: 14, overflow: 'hidden', background: frameBg(c), boxShadow: `inset 0 0 0 0.5px ${c.glassLine}` }}>
          {children}
          <div style={{ position: 'absolute', top: 10, left: 11, fontFamily: M, fontSize: 10, fontWeight: 700, letterSpacing: 1, color: c.accent }}>{n}</div>
        </div>
        <div>
          <div style={{ fontSize: 12.5, fontWeight: 700, color: c.t1 }}>{title}</div>
          <div style={{ fontSize: 11, color: c.t3, lineHeight: 1.45, marginTop: 3 }}>{caption}</div>
        </div>
      </div>
    );
  }

  function Chip({ c, x, y, children, accent }) {
    return (
      <div style={{ position: 'absolute', left: x, top: y, transform: 'translate(-50%,-50%)', fontFamily: M, fontSize: 8.5, fontWeight: 700, letterSpacing: 0.4, color: accent ? c.accent : c.t2, background: c.glass, backdropFilter: 'blur(10px)', WebkitBackdropFilter: 'blur(10px)', padding: '3px 7px', borderRadius: 6, boxShadow: `inset 0 0 0 0.5px ${accent ? c.accentLine : c.glassLine}`, whiteSpace: 'nowrap' }}>{children}</div>
    );
  }

  function star(c, cx, cy, r, col, bloom) {
    return <g>
      {bloom && <circle cx={cx} cy={cy} r={r * 2.6} fill={col} opacity="0.16" />}
      <circle cx={cx} cy={cy} r={r} fill={col} style={{ filter: `drop-shadow(0 0 ${bloom ? 10 : 5}px ${col})` }} />
      <circle cx={cx} cy={cy} r={r * 0.5} fill="#fff" opacity="0.9" />
    </g>;
  }

  function DrillStoryboard({ theme = 'dark' }) {
    const c = rcMap(theme);
    const cxC = FW / 2, cyC = FH / 2;

    // F1: galaxy overview, Chamakuy highlighted
    const f1 = discPts(cxC, cyC * 0.92, 120, 0.42);
    // F2: zoomed in, Chamakuy approaching center, others streaking
    const zoom2 = 320; const off2x = -chkBase.ux * zoom2, off2y = -chkBase.uy * zoom2 * 0.42;
    const f2 = discPts(cxC + off2x, cyC * 0.92 + off2y, zoom2, 0.42);

    const planets = [40, 64, 92, 120];

    return (
      <div style={{ width: BOARD.w, height: BOARD.h, background: c.space, borderRadius: 4, fontFamily: F, color: c.t1, padding: '26px 28px', boxSizing: 'border-box', position: 'relative' }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 4 }}>
          <span style={{ fontSize: 17, fontWeight: 700, letterSpacing: -0.2 }}>Drill-down transition</span>
          <span style={{ fontFamily: M, fontSize: 11, color: c.t3 }}>galaxy → star system · select · push-in · materialize</span>
        </div>
        <div style={{ display: 'flex', gap: 12, marginTop: 18, alignItems: 'flex-start' }}>

          <Frame c={c} n="01" title="Select in galaxy" caption="Tap Chamakuy on the tilted disc. Inspector offers “Drill into system”.">
            <Mini><MiniStars c={c} seed={3} />
              <ellipse cx={cxC} cy={cyC * 0.92} rx={120} ry={50} fill="none" stroke={c.planeSoft} />
              {f1.map(({ s, x, y, d }) => <circle key={s.id} cx={x} cy={y} r={s.id === 'CHK' ? 3.4 : 1.6 + d * 1.4} fill={s.id === 'CHK' ? c.accent : s.presence === 'mine' ? c.accent : c.starDim} opacity={s.id === 'CHK' ? 1 : 0.7} style={s.id === 'CHK' ? { filter: `drop-shadow(0 0 5px ${c.accent})` } : null} />)}
              <circle cx={f1.find(p => p.s.id === 'CHK').x} cy={f1.find(p => p.s.id === 'CHK').y} r="9" fill="none" stroke={c.accentLine} strokeWidth="1.3" />
            </Mini>
            <Chip c={c} x={f1.find(p => p.s.id === 'CHK').x + 4} y={f1.find(p => p.s.id === 'CHK').y - 22} accent>CHAMAKUY ●</Chip>
            <Chip c={c} x={FW / 2} y={FH - 26}>DRILL IN →</Chip>
          </Frame>

          <Arrow c={c} />

          <Frame c={c} n="02" title="Push in" caption="Camera dives toward the star; sibling systems streak outward with parallax.">
            <Mini><MiniStars c={c} seed={9} />
              {/* motion streaks */}
              {[...Array(10)].map((_, i) => { const a = (i / 10) * Math.PI * 2; return <line key={i} x1={cxC + Math.cos(a) * 30} y1={cyC + Math.sin(a) * 30} x2={cxC + Math.cos(a) * 120} y2={cyC + Math.sin(a) * 120} stroke={c.starDim} strokeWidth="1" opacity="0.4" />; })}
              {f2.filter(p => p.s.id !== 'CHK').map(({ s, x, y }) => <circle key={s.id} cx={x} cy={y} r="1.6" fill={c.starDim} opacity="0.5" />)}
              {star(c, cxC, cyC, 7, c.accent, true)}
            </Mini>
            <Chip c={c} x={FW / 2} y={cyC - 26} accent>CHAMAKUY</Chip>
          </Frame>

          <Arrow c={c} />

          <Frame c={c} n="03" title="Materialize" caption="Star blooms; orbital rings and the habitable-zone band fade up around it.">
            <Mini><MiniStars c={c} seed={15} />
              <ellipse cx={cxC} cy={cyC} rx={SafeR(86)} ry={SafeR(80)} fill={c.hzBand} opacity="0.8" />
              {planets.map((rr, i) => <ellipse key={i} cx={cxC} cy={cyC} rx={rr} ry={rr * 0.92} fill="none" stroke={c.planeSoft} strokeWidth="1" opacity={0.3 + i * 0.12} strokeDasharray="3 4" />)}
              {star(c, cxC, cyC, 11, c.accent, true)}
            </Mini>
          </Frame>

          <Arrow c={c} />

          <Frame c={c} n="04" title="Planets arrive" caption="Bodies settle onto their orbits; vessels and devices populate. HUD edges slide in.">
            <Mini><MiniStars c={c} seed={21} />
              {planets.map((rr, i) => <ellipse key={i} cx={cxC} cy={cyC} rx={rr} ry={rr * 0.92} fill="none" stroke={c.planeSoft} strokeWidth="1" />)}
              {star(c, cxC, cyC, 9, '#ffb648', true)}
              {[[40, 0.6, '#b08868', 3], [64, 2.2, '#5fa3b0', 5], [92, 4.0, '#c98b5a', 4], [120, 1.2, '#caa06a', 8]].map(([rr, ang, col, pr], i) => (
                <g key={i}><circle cx={cxC + Math.cos(ang) * rr} cy={cyC + Math.sin(ang) * rr * 0.92} r={pr} fill={col} /></g>
              ))}
              <circle cx={cxC + 30} cy={cyC - 44} r="2.5" fill={c.accent} style={{ filter: `drop-shadow(0 0 4px ${c.accent})` }} />
            </Mini>
            <Chip c={c} x={cxC + 36} y={cyC - 52} accent>HEAVEN</Chip>
          </Frame>

          <Arrow c={c} />

          <Frame c={c} n="05" title="Star system view" caption="Live orrery with full HUD. Reverse the move (pinch out) to fly back to the galaxy.">
            <Mini><MiniStars c={c} seed={27} />
              <ellipse cx={cxC} cy={cyC} rx={SafeR(86)} ry={SafeR(80)} fill={c.hzBand} opacity="0.7" />
              {planets.map((rr, i) => <ellipse key={i} cx={cxC} cy={cyC} rx={rr} ry={rr * 0.92} fill="none" stroke={c.planeSoft} strokeWidth="1" />)}
              {star(c, cxC, cyC, 9, '#ffb648', true)}
              {[[40, 0.6, '#b08868', 3], [64, 2.2, '#5fa3b0', 5], [92, 4.0, '#c98b5a', 4], [120, 1.2, '#caa06a', 8]].map(([rr, ang, col, pr], i) => (
                <circle key={i} cx={cxC + Math.cos(ang) * rr} cy={cyC + Math.sin(ang) * rr * 0.92} r={pr} fill={col} />
              ))}
            </Mini>
            {/* faux HUD edges */}
            <div style={{ position: 'absolute', top: 30, left: 10, width: 52, height: 46, borderRadius: 7, background: c.glass, boxShadow: `inset 0 0 0 0.5px ${c.glassLine}` }} />
            <div style={{ position: 'absolute', top: 30, right: 10, width: 58, height: 64, borderRadius: 7, background: c.glass, boxShadow: `inset 0 0 0 0.5px ${c.glassLine}` }} />
            <Chip c={c} x={FW / 2} y={FH - 24} accent>CHAMAKUY · LIVE</Chip>
          </Frame>
        </div>
      </div>
    );
  }

  function SafeR(v) { return v; }

  function Arrow({ c }) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', height: FH, flexShrink: 0 }}>
        <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke={c.t3} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.7 }}><path d="M4 10h11M11 5l5 5-5 5" /></svg>
      </div>
    );
  }

  Object.assign(window, { DrillStoryboard });
})();
