// SystemDirections.jsx — three full-bleed animated star-system (orrery) views
// for Chamakuy. A · Orrery (grounded, dark+light), B · Instrument (schematic),
// C · Horizon (cinematic). Each: <SystemOrrery/>, <SystemInstrument/>, <SystemHorizon/>.

(function () {
  const M = window.RD_MONO, F = window.RD_FONT;
  const { rcMap, GAL_SYSTEMS, SYS_STAR, SYS_PLANETS, SYS_LAGRANGE, SYS_DEVICES, SYS_VESSELS, SYS_BELT } = window;
  const { useClock, Glass, Eyebrow, Stat, GlassButton, StarField, Orrery, prefersStill } = window;

  const SIZE = { w: 1240, h: 800 };
  const planetById = Object.fromEntries(SYS_PLANETS.map((p) => [p.id, p]));

  // Resolve a selection id to {kind, data}.
  function resolve(id) {
    if (!id) return null;
    if (planetById[id]) return { kind: 'planet', d: planetById[id] };
    const lp = SYS_LAGRANGE.find((x) => x.id === id); if (lp) return { kind: 'lagrange', d: lp };
    const v = SYS_VESSELS.find((x) => x.code === id); if (v) return { kind: 'vessel', d: v };
    const dv = SYS_DEVICES.find((x) => x.code === id); if (dv) return { kind: 'device', d: dv };
    return null;
  }

  function Frame({ c, children, onSelect }) {
    return (
      <div onClick={() => onSelect && onSelect(null)} style={{ position: 'relative', width: SIZE.w, height: SIZE.h, overflow: 'hidden', background: c.space, fontFamily: F, color: c.t1, userSelect: 'none' }}>{children}</div>
    );
  }

  function ClockReadout({ c, t }) {
    const cyc = (SYS_PLANETS[1].phase0 + (360 * t) / SYS_PLANETS[1].period) % 360;
    return (
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7, fontFamily: M, fontSize: 11, color: c.t2 }}>
        <span style={{ width: 6, height: 6, borderRadius: '50%', background: c.life, boxShadow: `0 0 7px ${c.life}`, animation: prefersStill ? 'none' : 'rcPulse 1.6s ease-in-out infinite' }} />
        LIVE · Orrun {Math.round(cyc)}°
      </span>
    );
  }

  // Tiny galaxy inset — current system highlighted (drill-up affordance).
  function GalaxyInset({ c, w = 132 }) {
    return (
      <Glass c={c} pad={0} radius={12} style={{ width: w, height: w, overflow: 'hidden', position: 'relative' }}>
        <svg width={w} height={w} viewBox="0 0 132 132">
          <ellipse cx="66" cy="66" rx="52" ry="22" fill="none" stroke={c.glassLineSoft} />
          {GAL_SYSTEMS.map((s) => { const a = s.a * Math.PI / 180; const home = s.id === 'CHK'; return (
            <circle key={s.id} cx={66 + Math.cos(a) * s.r * 50} cy={66 + Math.sin(a) * s.r * 22} r={home ? 3 : 1.5}
              fill={home ? c.accent : s.presence === 'mine' ? c.accent : c.starDim} opacity={home ? 1 : 0.7}
              style={home ? { filter: `drop-shadow(0 0 5px ${c.accent})` } : null} />
          ); })}
        </svg>
        <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, padding: '6px 9px', fontFamily: M, fontSize: 8.5, letterSpacing: 0.6, color: c.t3, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <span>GALAXY</span><span style={{ color: c.accent }}>↗ zoom out</span>
        </div>
      </Glass>
    );
  }

  // ── Shared inspector body (varies by selection kind) ───────────
  function Inspector({ c, sel, compact }) {
    const r = resolve(sel);
    if (!r) return (
      <div style={{ textAlign: 'center', color: c.t3, padding: '18px 8px' }}>
        <div style={{ fontSize: 12.5 }}>Select a body, vessel, device, or Lagrange point</div>
      </div>
    );
    if (r.kind === 'vessel') return <VesselBody c={c} v={r.d} />;
    if (r.kind === 'planet') return <PlanetBody c={c} p={r.d} />;
    if (r.kind === 'lagrange') return <LagrangeBody c={c} lp={r.d} />;
    if (r.kind === 'device') return <DeviceBody c={c} d={r.d} />;
    return null;
  }

  function Title({ c, eyebrow, name, right }) {
    return (
      <div style={{ marginBottom: 12 }}>
        <div style={{ fontFamily: M, fontSize: 10, letterSpacing: 1.6, textTransform: 'uppercase', color: c.t3 }}>{eyebrow}</div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginTop: 4 }}>
          <span style={{ fontSize: 21, fontWeight: 700, letterSpacing: -0.3 }}>{name}</span>
          {right}
        </div>
      </div>
    );
  }

  function KV({ c, k, v, dot }) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: `1px solid ${c.glassLineSoft}` }}>
        <span style={{ fontSize: 11, color: c.t3, width: 84, flexShrink: 0 }}>{k}</span>
        {dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: dot, boxShadow: `0 0 6px ${dot}`, flexShrink: 0 }} />}
        <span style={{ fontSize: 12.5, color: c.t1, flex: 1 }}>{v}</span>
      </div>
    );
  }

  function VesselBody({ c, v }) {
    const hero = v.name === 'HEAVEN';
    return (
      <>
        <Title c={c} eyebrow={hero ? 'Replicant host vessel' : 'Vessel'} name={v.name}
          right={<span style={{ fontFamily: M, fontSize: 11, color: c.transit, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.transit, boxShadow: `0 0 6px ${c.transit}` }} />Cruising</span>} />
        <KV c={c} k="Replicant" v={hero ? 'Sylphrena · 30B93F2F' : '—'} dot={hero ? c.accent : null} />
        <KV c={c} k="Course" v={`${planetById[v.from] ? planetById[v.from].name : v.from} → ${planetById[v.to] ? planetById[v.to].name : v.to}`} />
        <KV c={c} k="Progress" v={`${Math.round(v.t * 100)}% · ETA 41m`} />
        <KV c={c} k="Code" v={v.code} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Set destination</GlassButton>
          <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Open vessel →</GlassButton>
        </div>
        <div style={{ fontSize: 10.5, color: c.t3, marginTop: 10, textAlign: 'center' }}>Tap any body or point on the map to retarget</div>
      </>
    );
  }

  function PlanetBody({ c, p }) {
    return (
      <>
        <Title c={c} eyebrow={`${p.type} · Chamakuy ${p.id}`} name={p.name}
          right={p.life ? <span style={{ fontFamily: M, fontSize: 11, color: c.life, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.life }} />Life</span> : null} />
        <KV c={c} k="Class" v={p.type} />
        <KV c={c} k="Moons" v={(p.moons || []).length || '—'} />
        <KV c={c} k="Devices" v={p.devices ? `${p.devices} stationed` : 'None'} dot={p.devices ? c.accent : null} />
        {p.lagrange && <KV c={c} k="Lagrange" v="L1–L5 plotted" dot={c.accent} />}
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Travel here</GlassButton>
          <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Scan</GlassButton>
        </div>
      </>
    );
  }

  function LagrangeBody({ c, lp }) {
    const host = planetById[lp.host];
    return (
      <>
        <Title c={c} eyebrow={`Lagrange point · ${host.name}`} name={lp.id}
          right={lp.device ? <span style={{ fontFamily: M, fontSize: 11, color: c.accent }}>occupied</span> : null} />
        <div style={{ fontSize: 12.5, color: c.t2, lineHeight: 1.5, marginBottom: 12 }}>{lp.label}</div>
        <KV c={c} k="Stability" v={lp.kind === 'trojan' ? 'Stable (trojan)' : 'Metastable'} />
        <KV c={c} k="Station" v={lp.device ? ({ ftl_relay: 'FTL Relay', surge_plate: 'Surge Plate' })[lp.device] : 'Vacant'} dot={lp.device ? c.accent : null} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Travel to {lp.id}</GlassButton>
          <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>{lp.device ? 'Open device →' : 'Deploy here'}</GlassButton>
        </div>
      </>
    );
  }

  function DeviceBody({ c, d }) {
    return (
      <>
        <Title c={c} eyebrow="Device" name={d.label}
          right={<span style={{ fontFamily: M, fontSize: 11, color: c.accent, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.accent }} />{d.status}</span>} />
        <KV c={c} k="Code" v={d.code} />
        <KV c={c} k="Station" v={d.at === 'belt' ? 'Chamakuy belt' : d.at} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <GlassButton c={c} primary style={{ flex: 1, justifyContent: 'center' }}>Retarget</GlassButton>
          <GlassButton c={c} style={{ flex: 1, justifyContent: 'center' }}>Open device →</GlassButton>
        </div>
      </>
    );
  }

  // ── A · Orrery (grounded, dark + light) ────────────────────────
  function SystemOrrery({ theme = 'dark' }) {
    const c = rcMap(theme);
    const t = useClock(1);
    const [sel, setSel] = React.useState('C1D9F0A2');

    return (
      <Frame c={c} onSelect={setSel}>
        <StarField c={c} seed={11} n={90} nebula={false} />
        <Orrery c={c} t={t} selected={sel} onSelect={setSel} variant="orrery" size={SIZE} />

        {/* header */}
        <div style={{ position: 'absolute', top: 22, left: 24, pointerEvents: 'none' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ fontSize: 20, fontWeight: 700, letterSpacing: -0.3 }}>Chamakuy</span>
            <span style={{ fontFamily: M, fontSize: 11, color: c.t3 }}>{SYS_STAR.cls} · {SYS_STAR.kelvin}K</span>
          </div>
          <div style={{ marginTop: 5 }}><ClockReadout c={c} t={t} /></div>
        </div>

        {/* left body legend */}
        <Glass c={c} style={{ position: 'absolute', top: 92, left: 24, width: 210 }} pad={12}>
          <Eyebrow c={c} right={<span style={{ fontFamily: M, fontSize: 10, color: c.t3 }}>{SYS_PLANETS.length}</span>}>Bodies</Eyebrow>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            {SYS_PLANETS.map((p) => (
              <button key={p.id} onClick={(e) => { e.stopPropagation(); setSel(p.id); }} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 8px', borderRadius: 8, border: 'none', cursor: 'pointer', background: sel === p.id ? c.field : 'transparent', fontFamily: F, textAlign: 'left' }}>
                <span style={{ width: 14, height: 14, borderRadius: '50%', flexShrink: 0, background: p.color, boxShadow: 'inset -1px -1px 2px rgba(0,0,0,0.5)' }} />
                <span style={{ flex: 1 }}><span style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: c.t1 }}>{p.name}</span><span style={{ display: 'block', fontFamily: M, fontSize: 9.5, color: c.t3 }}>{p.type}</span></span>
                {p.devices > 0 && <span style={{ fontFamily: M, fontSize: 10, color: c.accent }}>{p.devices}</span>}
                {p.life && <span style={{ width: 5, height: 5, borderRadius: '50%', background: c.life, boxShadow: `0 0 5px ${c.life}` }} />}
              </button>
            ))}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, padding: '8px', borderTop: `1px solid ${c.glassLineSoft}` }}>
            <span style={{ width: 14, height: 14, borderRadius: 3, flexShrink: 0, border: `1.4px solid ${c.resource}`, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><span style={{ width: 4, height: 4, borderRadius: '50%', background: c.resource }} /></span>
            <span style={{ fontSize: 12, color: c.t2 }}>Asteroid belt</span>
            <span style={{ marginLeft: 'auto', fontFamily: M, fontSize: 10, color: c.accent }}>2 mining</span>
          </div>
        </Glass>

        {/* right inspector */}
        <div onClick={(e) => e.stopPropagation()}>
          <Glass c={c} style={{ position: 'absolute', top: 92, right: 24, width: 292 }} pad={16}>
            <Inspector c={c} sel={sel} />
          </Glass>
        </div>

        {/* galaxy inset bottom-left */}
        <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', bottom: 24, left: 24 }}><GalaxyInset c={c} /></div>

        {/* bottom command strip */}
        <Glass c={c} style={{ position: 'absolute', bottom: 24, left: '50%', transform: 'translateX(-50%)', display: 'flex', alignItems: 'center', gap: 12 }} pad={9} radius={12}>
          <span style={{ fontFamily: M, fontSize: 11, color: c.t3, paddingLeft: 4 }}>VESSELS</span>
          {SYS_VESSELS.map((v) => (
            <button key={v.code} onClick={(e) => { e.stopPropagation(); setSel(v.code); }} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 11px', borderRadius: 8, border: 'none', cursor: 'pointer', background: sel === v.code ? c.accentSoft : c.chipBg, boxShadow: sel === v.code ? `inset 0 0 0 0.5px ${c.accentLine}` : 'none', fontFamily: M, fontSize: 11, fontWeight: 600, color: v.name === 'HEAVEN' ? c.accent : c.t1 }}>
              <span style={{ width: 6, height: 6, borderRadius: '50%', background: v.name === 'HEAVEN' ? c.accent : c.transit, boxShadow: `0 0 6px ${v.name === 'HEAVEN' ? c.accent : c.transit}` }} />{v.name}
            </button>
          ))}
        </Glass>
      </Frame>
    );
  }

  // ── B · Instrument (schematic blueprint) ───────────────────────
  function SystemInstrument({ theme = 'dark' }) {
    const c = rcMap(theme);
    const t = useClock(0.8);
    const [sel, setSel] = React.useState('L5');

    return (
      <Frame c={c} onSelect={setSel}>
        <StarField c={c} seed={17} n={70} nebula={false} />
        {/* blueprint grid overlay */}
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', opacity: c.theme === 'light' ? 0.5 : 0.4, backgroundImage: `linear-gradient(${c.glassLineSoft} 1px, transparent 1px), linear-gradient(90deg, ${c.glassLineSoft} 1px, transparent 1px)`, backgroundSize: '44px 44px', maskImage: 'radial-gradient(120% 100% at 50% 50%, #000 40%, transparent 78%)', WebkitMaskImage: 'radial-gradient(120% 100% at 50% 50%, #000 40%, transparent 78%)' }} />
        <Orrery c={c} t={t} selected={sel} onSelect={setSel} variant="instrument" size={SIZE} />

        {/* crosshair frame on the star */}
        <svg width={SIZE.w} height={SIZE.h} style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}>
          <line x1={SIZE.w / 2 - 60} y1={SIZE.h * 0.52} x2={SIZE.w / 2 + 60} y2={SIZE.h * 0.52} stroke={c.accentLine} strokeWidth="0.7" strokeDasharray="2 4" opacity="0.5" />
          <line x1={SIZE.w / 2} y1={SIZE.h * 0.52 - 60} x2={SIZE.w / 2} y2={SIZE.h * 0.52 + 60} stroke={c.accentLine} strokeWidth="0.7" strokeDasharray="2 4" opacity="0.5" />
        </svg>

        {/* technical header */}
        <div style={{ position: 'absolute', top: 22, left: 26 }}>
          <div style={{ fontFamily: M, fontSize: 10, letterSpacing: 2, color: c.accent }}>SYSTEM CHART · CHK-1</div>
          <div style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.3, marginTop: 3 }}>Chamakuy</div>
          <div style={{ fontFamily: M, fontSize: 10.5, color: c.t3, marginTop: 4 }}>{SYS_PLANETS.length} planets · belt · 5 Lagrange · {SYS_DEVICES.length} devices</div>
        </div>

        {/* right: lagrange + device manifest */}
        <Glass c={c} style={{ position: 'absolute', top: 22, right: 24, width: 250 }} pad={13}>
          <Eyebrow c={c}>Lagrange points</Eyebrow>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2, marginBottom: 12 }}>
            {SYS_LAGRANGE.map((lp) => (
              <button key={lp.id} onClick={(e) => { e.stopPropagation(); setSel(lp.id); }} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 8px', borderRadius: 7, border: 'none', cursor: 'pointer', background: sel === lp.id ? c.accentSoft : 'transparent', boxShadow: sel === lp.id ? `inset 0 0 0 0.5px ${c.accentLine}` : 'none', fontFamily: F, textAlign: 'left' }}>
                <span style={{ fontFamily: M, fontSize: 11, fontWeight: 700, color: lp.device ? c.accent : c.t2, width: 20 }}>{lp.id}</span>
                <span style={{ flex: 1, fontSize: 11.5, color: c.t2 }}>{lp.device ? ({ ftl_relay: 'FTL Relay', surge_plate: 'Surge Plate' })[lp.device] : 'Vacant'}</span>
                {lp.device && <span style={{ width: 5, height: 5, borderRadius: '50%', background: c.accent, boxShadow: `0 0 5px ${c.accent}` }} />}
              </button>
            ))}
          </div>
          <Eyebrow c={c}>Inspector</Eyebrow>
          <Inspector c={c} sel={sel} compact />
        </Glass>

        {/* bottom-left readout strip */}
        <Glass c={c} style={{ position: 'absolute', bottom: 24, left: 24, display: 'flex', gap: 18 }} pad={13}>
          <Stat c={c} k="Belt yield" v="2.4 kt/h" accent />
          <span style={{ width: 1, background: c.glassLineSoft }} />
          <Stat c={c} k="In transit" v={SYS_VESSELS.length} />
          <span style={{ width: 1, background: c.glassLineSoft }} />
          <Stat c={c} k="Devices" v={SYS_DEVICES.length} />
        </Glass>

        <div style={{ position: 'absolute', bottom: 24, right: 24 }}><ClockReadout c={c} t={t} /></div>
      </Frame>
    );
  }

  // ── C · Horizon (cinematic) ────────────────────────────────────
  function SystemHorizon({ theme = 'dark' }) {
    const c = rcMap(theme);
    const t = useClock(1);
    const [sel, setSel] = React.useState('IV');
    const r = resolve(sel);

    return (
      <Frame c={c} onSelect={setSel}>
        <div style={{ position: 'absolute', inset: 0, background: c.theme === 'light' ? c.space : 'radial-gradient(1000px 800px at 50% 56%, #101a30, #070a12 72%)' }} />
        <StarField c={c} seed={23} n={200} />
        <Orrery c={c} t={t} selected={sel} onSelect={setSel} variant="cinematic" size={SIZE} />
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', background: 'radial-gradient(120% 95% at 50% 48%, transparent 50%, rgba(0,0,0,0.5) 100%)' }} />

        {/* header */}
        <div style={{ position: 'absolute', top: 26, left: 30, pointerEvents: 'none' }}>
          <div style={{ fontFamily: M, fontSize: 10.5, letterSpacing: 3, color: c.accent }}>STAR SYSTEM</div>
          <div style={{ fontSize: 30, fontWeight: 700, letterSpacing: -0.6, marginTop: 4 }}>Chamakuy</div>
          <div style={{ marginTop: 7 }}><ClockReadout c={c} t={t} /></div>
        </div>

        {/* cinematic inspector card, bottom-left */}
        {r && (
          <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', bottom: 28, left: 30, width: 330 }}>
            <Glass c={c} pad={20} radius={18}><Inspector c={c} sel={sel} /></Glass>
          </div>
        )}

        {/* device/vessel dock, right edge */}
        <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', top: 0, bottom: 0, right: 26, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 8 }}>
          {[...SYS_VESSELS, ...SYS_DEVICES.filter((d) => d.code === '7C0E9B41' || d.code === '22D7E5A9')].map((x) => {
            const isV = !!x.name; const id = x.code; const on = sel === id;
            return (
              <button key={id} onClick={() => setSel(id)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '9px 13px', borderRadius: 11, border: 'none', cursor: 'pointer', minWidth: 156,
                background: c.glass, backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', boxShadow: `inset 0 0 0 0.5px ${on ? c.accentLine : c.glassLine}`, fontFamily: F, textAlign: 'left' }}>
                <span style={{ width: 8, height: 8, borderRadius: '50%', flexShrink: 0, background: isV && x.name === 'HEAVEN' ? c.accent : isV ? c.transit : c.sense, boxShadow: `0 0 7px ${isV && x.name === 'HEAVEN' ? c.accent : isV ? c.transit : c.sense}` }} />
                <span style={{ flex: 1 }}>
                  <span style={{ display: 'block', fontSize: 12, fontWeight: 600, color: c.t1 }}>{isV ? x.name : x.label}</span>
                  <span style={{ display: 'block', fontFamily: M, fontSize: 9.5, color: c.t3 }}>{x.status}</span>
                </span>
              </button>
            );
          })}
        </div>

        {/* galaxy inset top-right */}
        <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', top: 26, right: 26 }}><GalaxyInset c={c} w={120} /></div>
      </Frame>
    );
  }

  Object.assign(window, { SystemOrrery, SystemInstrument, SystemHorizon });
})();
