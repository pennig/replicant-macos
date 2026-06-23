// GalaxyDirections.jsx — three full-bleed tilted-3D galaxy explorer directions.
// A · Atlas (grounded, dark+light) — left legend, right inspector, course bar.
// B · Relay Mesh — network/reach-forward, top filter rail + compass minimap.
// C · Observatory — bold cinematic cockpit, bloom + instrument readouts.
// Each: <GalaxyAtlas theme/>, <GalaxyMesh theme/>, <GalaxyObservatory theme/>.

(function () {
  const M = window.RD_MONO, F = window.RD_FONT;
  const { rcMap, GAL_SYSTEMS, GAL_LINKS, GAL_BY_ID, GAL_LAYERS, RECON, LIFE } = window;
  const { useClock, Glass, Eyebrow, Stat, ReconPip, LayerToggle, GlassButton, StarField, GalaxyDisc, prefersStill } = window;

  const SIZE = { w: 1240, h: 800 };
  const allOn = Object.fromEntries(GAL_LAYERS.map((l) => [l.key, true]));

  // Shared scene: bg + starfield + parallax + slow spin + disc.
  function useScene(speed = 0.018) {
    const t = useClock(1);
    const [par, setPar] = React.useState({ x: 0, y: 0 });
    const onMove = (e) => {
      const r = e.currentTarget.getBoundingClientRect();
      setPar({ x: ((e.clientX - r.left) / r.width - 0.5) * 26, y: ((e.clientY - r.top) / r.height - 0.5) * 18 });
    };
    return { rot: t * speed, par, onMove, onLeave: () => setPar({ x: 0, y: 0 }) };
  }

  function Frame({ c, children, onSelect }) {
    return (
      <div onClick={() => onSelect && onSelect(null)} style={{ position: 'relative', width: SIZE.w, height: SIZE.h, overflow: 'hidden', background: c.space, fontFamily: F, color: c.t1, userSelect: 'none' }}>
        {children}
      </div>
    );
  }

  function reconLine(c, s) { const r = RECON[s.recon]; return r.label + ' · ' + r.note; }
  function lifeLabel(s) { return s.life ? (LIFE[s.life] ? LIFE[s.life].label : s.life) : 'No biosignatures'; }
  function relayCount(id) { return GAL_LINKS.filter((l) => l.owner === 'mine' && (l.a === id || l.b === id)).length; }

  // ── A · Atlas ──────────────────────────────────────────────────
  function GalaxyAtlas({ theme = 'dark' }) {
    const c = rcMap(theme);
    const [layers, setLayers] = React.useState(allOn);
    const [sel, setSel] = React.useState('VLZ');
    const sc = useScene();
    const s = sel ? GAL_BY_ID[sel] : null;
    const toggle = (k) => setLayers((L) => ({ ...L, [k]: !L[k] }));

    return (
      <Frame c={c} onSelect={setSel}>
        <div style={{ position: 'absolute', inset: 0 }} onPointerMove={sc.onMove} onPointerLeave={sc.onLeave}>
          <StarField c={c} parallax={sc.par} />
          <GalaxyDisc c={c} systems={GAL_SYSTEMS} links={GAL_LINKS} layers={layers} selected={sel} onSelect={setSel} rot={sc.rot} scale={300} variant="atlas" size={SIZE} />
        </div>

        {/* title */}
        <div style={{ position: 'absolute', top: 22, left: 24, pointerEvents: 'none' }}>
          <div style={{ fontSize: 20, fontWeight: 700, letterSpacing: -0.3 }}>Galaxy Explorer</div>
          <div style={{ fontFamily: M, fontSize: 11, color: c.t3, marginTop: 3 }}>Orion Spur · 16 charted systems</div>
        </div>

        {/* left: layer legend */}
        <Glass c={c} style={{ position: 'absolute', top: 78, left: 24, width: 244 }} pad={12}>
          <Eyebrow c={c} right={<span style={{ fontFamily: M, fontSize: 10, color: c.accent }}>{Object.values(layers).filter(Boolean).length}/{GAL_LAYERS.length}</span>}>Display layers</Eyebrow>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            {GAL_LAYERS.map((l) => <LayerToggle key={l.key} c={c} layer={l} on={layers[l.key]} onToggle={() => toggle(l.key)} />)}
          </div>
        </Glass>

        {/* right: system inspector */}
        {s && (
          <Glass c={c} style={{ position: 'absolute', top: 78, right: 24, width: 296 }} pad={16}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <ReconPip c={c} recon={s.recon} size={11} />
              <span style={{ fontSize: 18, fontWeight: 700, letterSpacing: -0.2 }}>{s.name}</span>
              {s.home && <span style={{ fontFamily: M, fontSize: 9, fontWeight: 700, color: c.accent, padding: '2px 6px', borderRadius: 5, background: c.accentSoft }}>HOME</span>}
              <span style={{ marginLeft: 'auto', fontFamily: M, fontSize: 11, color: c.t3 }}>{s.cls}</span>
            </div>
            <div style={{ fontSize: 11.5, color: c.t2, marginTop: 6 }}>{reconLine(c, s)}</div>

            <div style={{ display: 'flex', gap: 12, marginTop: 14, padding: '12px 0', borderTop: `1px solid ${c.glassLineSoft}`, borderBottom: `1px solid ${c.glassLineSoft}` }}>
              <Stat c={c} k="Devices" v={s.presence === 'mine' ? s.devices : '—'} accent={s.devices > 0} />
              <Stat c={c} k="Vessels" v={s.vessels || '—'} />
              <Stat c={c} k="Relays" v={s.relay ? relayCount(s.id) : '—'} />
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 9, margin: '13px 0 4px' }}>
              <Row c={c} k="Life" v={lifeLabel(s)} dot={s.life ? c.life : null} />
              <Row c={c} k="Resources" v={`${Math.round(s.resource * 100)}% richness`} bar={s.resource} barCol={c.resource} />
              <Row c={c} k="Presence" v={s.presence === 'mine' ? 'Sylphrena (mine)' : s.presence === 'npc' ? 'Foreign probe' : 'None'} dot={s.presence === 'npc' ? c.npc : s.presence ? c.accent : null} />
            </div>

            <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
              <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Plot course</GlassButton>
              {s.recon !== 'aware'
                ? <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Drill into system →</GlassButton>
                : <GlassButton c={c} style={{ flex: 1, justifyContent: 'center', opacity: 0.5 }}>Uncharted</GlassButton>}
            </div>
          </Glass>
        )}

        {/* bottom: course bar */}
        <Glass c={c} style={{ position: 'absolute', bottom: 22, left: '50%', transform: 'translateX(-50%)', display: 'flex', alignItems: 'center', gap: 14 }} pad={10} radius={13}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 7, paddingLeft: 4 }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', background: c.accent, boxShadow: `0 0 8px ${c.accent}` }} />
            <span style={{ fontFamily: M, fontSize: 11.5, color: c.t1 }}>Sylphrena · <span style={{ color: c.t3 }}>HEAVEN</span></span>
          </span>
          <span style={{ width: 1, height: 22, background: c.glassLineSoft }} />
          <span style={{ fontFamily: M, fontSize: 11, color: c.t2 }}>Chamakuy → Tarazedar</span>
          <span style={{ width: 120, height: 4, borderRadius: 3, background: c.chipBg, overflow: 'hidden' }}><span style={{ display: 'block', width: '64%', height: '100%', background: c.transit, boxShadow: `0 0 8px ${c.transit}` }} /></span>
          <span style={{ fontFamily: M, fontSize: 11, color: c.t3 }}>2h 14m</span>
          <GlassButton c={c} style={{ padding: '7px 12px' }}>Re-route</GlassButton>
        </Glass>
      </Frame>
    );
  }

  function Row({ c, k, v, dot, bar, barCol }) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 11, color: c.t3, width: 74, flexShrink: 0 }}>{k}</span>
        {dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: dot, boxShadow: `0 0 6px ${dot}`, flexShrink: 0 }} />}
        <span style={{ fontSize: 12, color: c.t1, flex: 1 }}>{v}</span>
        {bar != null && <span style={{ width: 56, height: 4, borderRadius: 3, background: c.chipBg, overflow: 'hidden', flexShrink: 0 }}><span style={{ display: 'block', width: `${Math.round(bar * 100)}%`, height: '100%', background: barCol }} /></span>}
      </div>
    );
  }

  // ── B · Relay Mesh ─────────────────────────────────────────────
  // Network-forward. Top segmented filter rail, presence/reach readout,
  // bottom-left compass minimap. Single-tap a system to focus.
  function GalaxyMesh({ theme = 'dark' }) {
    const c = rcMap(theme);
    const [focus, setFocus] = React.useState('relay'); // which filter rail tab
    const [sel, setSel] = React.useState('NRK');
    const sc = useScene(0.014);
    // Filter tabs drive which layers are emphasized.
    const TABS = [
      { key: 'relay', label: 'Relay mesh', layers: { presence: true, relay: true, recon: false, life: false, resource: false, npc: true } },
      { key: 'recon', label: 'Recon', layers: { presence: false, relay: false, recon: true, life: false, resource: false, npc: false } },
      { key: 'life', label: 'Life & resources', layers: { presence: false, relay: false, recon: false, life: true, resource: true, npc: false } },
      { key: 'all', label: 'All signals', layers: allOn },
    ];
    const layers = TABS.find((t) => t.key === focus).layers;
    const s = sel ? GAL_BY_ID[sel] : null;
    const mine = GAL_SYSTEMS.filter((x) => x.presence === 'mine');
    const relays = GAL_SYSTEMS.filter((x) => x.relay && x.presence === 'mine');

    return (
      <Frame c={c} onSelect={setSel}>
        <div style={{ position: 'absolute', inset: 0 }} onPointerMove={sc.onMove} onPointerLeave={sc.onLeave}>
          <StarField c={c} seed={31} parallax={sc.par} />
          <GalaxyDisc c={c} systems={GAL_SYSTEMS} links={GAL_LINKS} layers={layers} selected={sel} onSelect={setSel} rot={sc.rot} scale={300} variant="mesh" size={SIZE} />
        </div>

        {/* top filter rail */}
        <div style={{ position: 'absolute', top: 20, left: '50%', transform: 'translateX(-50%)' }}>
          <Glass c={c} pad={5} radius={13} style={{ display: 'flex', gap: 3 }}>
            {TABS.map((t) => (
              <button key={t.key} onClick={() => setFocus(t.key)} style={{
                padding: '8px 16px', borderRadius: 9, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12.5, fontWeight: 600,
                background: focus === t.key ? c.accentSoft : 'transparent', color: focus === t.key ? c.accent : c.t2,
                boxShadow: focus === t.key ? `inset 0 0 0 0.5px ${c.accentLine}` : 'none',
              }}>{t.label}</button>
            ))}
          </Glass>
        </div>

        {/* top-left reach readout */}
        <Glass c={c} style={{ position: 'absolute', top: 20, left: 24, width: 210 }} pad={14}>
          <Eyebrow c={c}>My reach</Eyebrow>
          <div style={{ display: 'flex', gap: 10 }}>
            <Stat c={c} k="Systems" v={mine.length} accent />
            <Stat c={c} k="Relays" v={relays.length} />
            <Stat c={c} k="Devices" v={mine.reduce((a, x) => a + x.devices, 0)} />
          </div>
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: `1px solid ${c.glassLineSoft}`, fontSize: 11, color: c.t2, lineHeight: 1.5 }}>
            Relay mesh spans <b style={{ color: c.t1 }}>3 systems</b>. One planned link to Corvan awaits a relay print.
          </div>
        </Glass>

        {/* selected node card (compact, anchored bottom-right) */}
        {s && (
          <Glass c={c} style={{ position: 'absolute', bottom: 24, right: 24, width: 268 }} pad={15}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <ReconPip c={c} recon={s.recon} size={11} />
              <span style={{ fontSize: 16, fontWeight: 700 }}>{s.name}</span>
              <span style={{ marginLeft: 'auto', fontFamily: M, fontSize: 10.5, color: c.t3 }}>{s.cls}</span>
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginTop: 11 }}>
              {s.relay && <Tag c={c} col={c.relay}>{relayCount(s.id)} relay links</Tag>}
              {s.presence === 'mine' && <Tag c={c} col={c.accent}>{s.devices} devices</Tag>}
              {s.presence === 'npc' && <Tag c={c} col={c.npc}>Foreign probe</Tag>}
              {s.life && <Tag c={c} col={c.life}>{lifeLabel(s)}</Tag>}
              <Tag c={c} col={c.resource}>{Math.round(s.resource * 100)}% res</Tag>
            </div>
            <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
              <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Plot course</GlassButton>
              {s.relay
                ? <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Manage relay</GlassButton>
                : <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Extend mesh</GlassButton>}
            </div>
          </Glass>
        )}

        {/* compass minimap, bottom-left */}
        <Glass c={c} style={{ position: 'absolute', bottom: 24, left: 24, width: 150, height: 150, padding: 0, overflow: 'hidden' }} radius={75}>
          <svg width="150" height="150" viewBox="0 0 150 150">
            <circle cx="75" cy="75" r="62" fill="none" stroke={c.glassLineSoft} />
            <circle cx="75" cy="75" r="40" fill="none" stroke={c.glassLineSoft} />
            <line x1="75" y1="13" x2="75" y2="137" stroke={c.glassLineSoft} /><line x1="13" y1="75" x2="137" y2="75" stroke={c.glassLineSoft} />
            {GAL_SYSTEMS.map((x) => { const a = x.a * Math.PI / 180; return (
              <circle key={x.id} cx={75 + Math.cos(a) * x.r * 60} cy={75 + Math.sin(a) * x.r * 60} r={x.id === sel ? 3 : x.presence === 'mine' ? 2.2 : 1.4}
                fill={x.id === sel ? c.accent : x.presence === 'mine' ? c.accent : x.presence === 'npc' ? c.npc : c.starDim} />
            ); })}
            <text x="75" y="26" textAnchor="middle" fill={c.t3} fontSize="8" fontFamily={M}>CORE-RELATIVE</text>
          </svg>
        </Glass>
      </Frame>
    );
  }

  function Tag({ c, col, children }) {
    return <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontFamily: M, fontSize: 10.5, fontWeight: 600, color: col, padding: '4px 9px', borderRadius: 7, background: c.chipBg, boxShadow: `inset 0 0 0 0.5px ${c.glassLineSoft}` }}>
      <span style={{ width: 5, height: 5, borderRadius: '50%', background: col }} />{children}</span>;
  }

  // ── C · Observatory (bold cinematic) ───────────────────────────
  function GalaxyObservatory({ theme = 'dark' }) {
    const c = rcMap(theme);
    const [layers, setLayers] = React.useState(allOn);
    const [sel, setSel] = React.useState('OBR');
    const sc = useScene(0.02);
    const s = sel ? GAL_BY_ID[sel] : null;
    const toggle = (k) => setLayers((L) => ({ ...L, [k]: !L[k] }));

    return (
      <Frame c={c} onSelect={setSel}>
        {/* deep cinematic backdrop */}
        <div style={{ position: 'absolute', inset: 0, background: c.theme === 'light' ? c.space : 'radial-gradient(900px 700px at 50% 60%, #0c1426, #060810 70%)' }} />
        <div style={{ position: 'absolute', inset: 0 }} onPointerMove={sc.onMove} onPointerLeave={sc.onLeave}>
          <StarField c={c} seed={53} n={220} parallax={sc.par} />
          <GalaxyDisc c={c} systems={GAL_SYSTEMS} links={GAL_LINKS} layers={layers} selected={sel} onSelect={setSel} rot={sc.rot} scale={320} squash={0.34} variant="cinematic" size={SIZE} />
          {/* vignette + scanline */}
          <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', background: 'radial-gradient(120% 90% at 50% 50%, transparent 52%, rgba(0,0,0,0.55) 100%)' }} />
          {c.theme !== 'light' && <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', backgroundImage: 'repeating-linear-gradient(0deg, rgba(255,255,255,0.018) 0 1px, transparent 1px 3px)' }} />}
        </div>

        {/* cinematic header */}
        <div style={{ position: 'absolute', top: 24, left: 28, pointerEvents: 'none' }}>
          <div style={{ fontFamily: M, fontSize: 10.5, letterSpacing: 3, color: c.accent }}>OBSERVATORY</div>
          <div style={{ fontSize: 26, fontWeight: 700, letterSpacing: -0.4, marginTop: 4 }}>The Orion Spur</div>
        </div>

        {/* vertical instrument stack — layer toggles as a HUD column */}
        <div style={{ position: 'absolute', top: 110, left: 28, display: 'flex', flexDirection: 'column', gap: 7 }}>
          {GAL_LAYERS.map((l) => {
            const on = layers[l.key]; const col = c[l.color] || l.color;
            return (
              <button key={l.key} onClick={() => toggle(l.key)} style={{
                display: 'flex', alignItems: 'center', gap: 9, padding: '7px 12px 7px 10px', borderRadius: 9, border: 'none', cursor: 'pointer', fontFamily: M, fontSize: 11, fontWeight: 600, letterSpacing: 0.4,
                background: c.glass, backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', color: on ? c.t1 : c.t3,
                boxShadow: `inset 0 0 0 0.5px ${on ? (c[l.color] || c.glassLine) : c.glassLine}`, opacity: on ? 1 : 0.55, textTransform: 'uppercase', minWidth: 168,
              }}>
                <span style={{ width: 8, height: 8, borderRadius: '50%', flexShrink: 0, background: on ? col : 'transparent', boxShadow: on ? `0 0 8px ${col}` : `inset 0 0 0 1.4px ${c.t3}` }} />
                {l.label}
                <span style={{ marginLeft: 'auto', fontSize: 9, opacity: 0.7 }}>{on ? 'ON' : 'OFF'}</span>
              </button>
            );
          })}
        </div>

        {/* cinematic selected-system card, right */}
        {s && (
          <div style={{ position: 'absolute', top: 0, bottom: 0, right: 0, width: 360, display: 'flex', alignItems: 'center', paddingRight: 28 }}>
            <Glass c={c} style={{ width: '100%' }} pad={22} radius={18}>
              <div style={{ fontFamily: M, fontSize: 10, letterSpacing: 2, color: c.t3, display: 'flex', alignItems: 'center', gap: 8 }}>
                <ReconPip c={c} recon={s.recon} size={10} /> {RECON[s.recon].label.toUpperCase()} · {s.cls}
              </div>
              <div style={{ fontSize: 40, fontWeight: 700, letterSpacing: -1, margin: '8px 0 2px', lineHeight: 1 }}>{s.name}</div>
              <div style={{ fontSize: 12.5, color: c.t2, marginBottom: 18 }}>{s.presence === 'npc' ? 'Foreign probe detected in-system' : s.presence === 'mine' ? 'Under Sylphrena’s control' : 'No probe presence'}</div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 18 }}>
                <Gauge c={c} label="Resources" pct={s.resource} col={c.resource} />
                <Gauge c={c} label="Recon" pct={RECON[s.recon].dim} col={c.accent} />
              </div>

              <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginBottom: 18 }}>
                <Row c={c} k="Life" v={lifeLabel(s)} dot={s.life ? c.life : null} />
                <Row c={c} k="Relay" v={s.relay ? `${relayCount(s.id)} FTL links` : 'No relay'} dot={s.relay ? c.relay : null} />
                <Row c={c} k="Devices" v={s.presence === 'mine' ? `${s.devices} stationed` : '—'} />
              </div>

              <GlassButton c={c} primary style={{ width: '100%', justifyContent: 'center', padding: '12px 16px', fontSize: 13 }}>
                {s.recon === 'aware' ? 'Plot survey course' : 'Drill into system →'}
              </GlassButton>
            </Glass>
          </div>
        )}
      </Frame>
    );
  }

  function Gauge({ c, label, pct, col }) {
    const R = 26, C = 2 * Math.PI * R, off = C * (1 - pct);
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ position: 'relative', width: 60, height: 60, flexShrink: 0 }}>
          <svg width="60" height="60" style={{ transform: 'rotate(-90deg)' }}>
            <circle cx="30" cy="30" r={R} fill="none" stroke={c.chipBg} strokeWidth="5" />
            <circle cx="30" cy="30" r={R} fill="none" stroke={col} strokeWidth="5" strokeDasharray={C} strokeDashoffset={off} strokeLinecap="round" style={{ filter: `drop-shadow(0 0 5px ${col}88)` }} />
          </svg>
          <span style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: M, fontSize: 14, fontWeight: 700, color: c.t1 }}>{Math.round(pct * 100)}</span>
        </div>
        <span style={{ fontSize: 11, color: c.t3, letterSpacing: 0.5, textTransform: 'uppercase' }}>{label}</span>
      </div>
    );
  }

  Object.assign(window, { GalaxyAtlas, GalaxyMesh, GalaxyObservatory });
})();
