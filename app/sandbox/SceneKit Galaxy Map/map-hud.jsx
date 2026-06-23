// map-hud.jsx — shared glass HUD components for the unified Star Map
// (galaxy rail/dossier + system rail/dossier/inset/dock). Dark only.
// Exports to window. Relies on galaxy-data.jsx + galaxy-ui.jsx.

(function () {
  const { rcMap, GAL_LAYERS, GAL_SYSTEMS, GAL_LINKS, RECON, LIFE,
    SYS_PLANETS, SYS_LAGRANGE, SYS_DEVICES, SYS_VESSELS } = window;
  const M = window.RD_MONO, F = window.RD_FONT;
  const c = rcMap('dark');
  const planetById = Object.fromEntries(SYS_PLANETS.map((p) => [p.id, p]));

  const glass = (extra) => ({ background: c.glass, backdropFilter: 'blur(26px) saturate(1.2)', WebkitBackdropFilter: 'blur(26px) saturate(1.2)', boxShadow: `inset 0 0 0 0.5px ${c.glassLine}, ${c.glassShadow}`, color: c.t1, fontFamily: F, ...extra });
  const colOf = (key) => c[key] || c.t2;
  const relayCount = (id) => GAL_LINKS.filter((l) => l.owner === 'mine' && (l.a === id || l.b === id)).length;
  const lifeLabel = (s) => s.life ? (LIFE[s.life] ? LIFE[s.life].label : s.life) : 'No biosignatures';

  function Btn({ children, primary, onClick }) {
    return <button onClick={onClick} style={{ flex: 1, display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6, padding: '10px 14px', borderRadius: 10, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12.5, fontWeight: 700, background: primary ? `linear-gradient(180deg, ${c.accent}, #ff9e2c)` : 'rgba(255,255,255,0.05)', color: primary ? '#2a1a05' : c.t1, boxShadow: primary ? `0 6px 18px ${c.accentSoft}` : `inset 0 0 0 0.5px ${c.glassLine}` }}>{children}</button>;
  }
  function Line({ k, v, dot, bar, barCol }) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 11, color: c.t3, width: 76, flexShrink: 0 }}>{k}</span>
        {dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: dot, boxShadow: `0 0 6px ${dot}`, flexShrink: 0 }} />}
        <span style={{ fontSize: 12, color: c.t1, flex: 1 }}>{v}</span>
        {bar != null && <span style={{ width: 54, height: 4, borderRadius: 3, background: 'rgba(255,255,255,0.08)', overflow: 'hidden', flexShrink: 0 }}><span style={{ display: 'block', width: `${Math.round(bar * 100)}%`, height: '100%', background: barCol }} /></span>}
      </div>
    );
  }

  // ── icons ──────────────────────────────────────────────────────
  function LIcon({ k, color, size = 20 }) {
    const p = { fill: 'none', stroke: color, strokeWidth: 1.5, strokeLinecap: 'round', strokeLinejoin: 'round' };
    const G = {
      presence: <g {...p}><circle cx="9" cy="9" r="3" /><circle cx="9" cy="9" r="7" opacity="0.5" /></g>,
      relay: <g {...p}><circle cx="4" cy="9" r="1.6" fill={color} stroke="none" /><circle cx="14" cy="9" r="1.6" fill={color} stroke="none" /><path d="M5.4 9h7.2" /></g>,
      recon: <g {...p}><circle cx="9" cy="9" r="6.5" /><path d="M9 9 L13.5 5.5" /><circle cx="9" cy="9" r="1.4" fill={color} stroke="none" /></g>,
      life: <g {...p}><path d="M9 15c0-4 0-6 4-9-1 5-2 6-4 9z" /><path d="M9 15c0-3 0-4-3-6.5" /></g>,
      resource: <g {...p}><path d="M9 3 L14.5 6 L14.5 12 L9 15 L3.5 12 L3.5 6 Z" /></g>,
      npc: <g {...p}><circle cx="9" cy="9" r="6.5" /><circle cx="9" cy="9" r="2" fill={color} stroke="none" /><circle cx="15.5" cy="9" r="1.3" fill={color} stroke="none" /></g>,
    };
    return <svg width={size} height={size} viewBox="0 0 18 18">{G[k]}</svg>;
  }
  function SLIcon({ k, color, size = 20 }) {
    const p = { fill: 'none', stroke: color, strokeWidth: 1.5, strokeLinecap: 'round', strokeLinejoin: 'round' };
    const dots = (n, rad) => Array.from({ length: n }, (_, i) => { const a = (i / n) * Math.PI * 2; return <circle key={i} cx={9 + Math.cos(a) * rad} cy={9 + Math.sin(a) * rad} r="0.9" fill={color} stroke="none" />; });
    const G = {
      hz: <g {...p}><circle cx="9" cy="9" r="2" fill={color} stroke="none" /><circle cx="9" cy="9" r="6.6" /></g>,
      belt: <g {...p}><circle cx="9" cy="9" r="2" fill={color} stroke="none" />{dots(7, 6.4)}</g>,
      kuiper: <g {...p}><circle cx="9" cy="9" r="7.2" strokeDasharray="1.5 2.5" opacity="0.7" />{dots(9, 7.2)}<circle cx="9" cy="9" r="1.4" fill={color} stroke="none" /></g>,
      oort: <g {...p}><circle cx="9" cy="9" r="7.4" opacity="0.7" /><circle cx="9" cy="9" r="1.4" fill={color} stroke="none" />{dots(6, 4.4)}</g>,
    };
    return <svg width={size} height={size} viewBox="0 0 18 18">{G[k]}</svg>;
  }

  // ── rail (shared layout) ───────────────────────────────────────
  function Rail({ items, isOn, toggle, Icon, eyebrow, top }) {
    const [hover, setHover] = React.useState(null);
    return (
      <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', top: top || '50%', left: 24, transform: top ? 'none' : 'translateY(-50%)', display: 'flex', flexDirection: 'column', gap: 7 }}>
        {eyebrow && <span style={{ fontFamily: M, fontSize: 9, letterSpacing: 1.4, color: c.t3, paddingLeft: 3, marginBottom: 1 }}>{eyebrow}</span>}
        {items.map((l) => {
          const on = isOn(l.key); const col = l.color ? colOf(l.color) : colOf(l.color);
          const cc = l.col || colOf(l.color);
          return (
            <div key={l.key} onMouseEnter={() => setHover(l.key)} onMouseLeave={() => setHover(null)} style={{ position: 'relative', display: 'flex', alignItems: 'center' }}>
              <button onClick={() => toggle(l.key)} style={glass({ width: 44, height: 44, borderRadius: 12, border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', position: 'relative', boxShadow: `inset 0 0 0 0.5px ${on ? cc : c.glassLine}`, opacity: on ? 1 : 0.6 })}>
                {on && <span style={{ position: 'absolute', left: 0, top: 10, bottom: 10, width: 3, borderRadius: 3, background: cc, boxShadow: `0 0 8px ${cc}` }} />}
                <Icon k={l.key} color={on ? cc : c.t3} />
              </button>
              {hover === l.key && (
                <div style={glass({ position: 'absolute', left: 54, whiteSpace: 'nowrap', borderRadius: 9, padding: '7px 11px', pointerEvents: 'none', zIndex: 5 })}>
                  <span style={{ fontSize: 12, fontWeight: 600, color: c.t1 }}>{l.label}</span>
                  <span style={{ fontSize: 10.5, color: c.t3, marginLeft: 8 }}>{on ? (l.desc || 'on') : 'off'}</span>
                </div>
              )}
            </div>
          );
        })}
      </div>
    );
  }
  function GalaxyRail({ layers, toggle }) {
    return <Rail items={GAL_LAYERS.map((l) => ({ ...l, col: colOf(l.color) }))} isOn={(k) => layers[k]} toggle={toggle} Icon={LIcon} eyebrow="LAYERS" />;
  }
  const SYS_LAYERS = [
    { key: 'hz', label: 'Habitable zone', desc: 'Liquid-water band', col: c.life },
    { key: 'belt', label: 'Asteroid belt', desc: 'Chamakuy belt', col: c.resource },
    { key: 'kuiper', label: 'Kuiper belt', desc: 'Log scale', col: c.sense },
    { key: 'oort', label: 'Oort cloud', desc: 'Log scale', col: c.transit },
  ];
  function SystemRail({ show, toggle, top }) {
    return <Rail items={SYS_LAYERS} isOn={(k) => show[k]} toggle={toggle} Icon={SLIcon} eyebrow="SHOW" top={top || 250} />;
  }

  // ── galaxy dossier ─────────────────────────────────────────────
  function GalaxyDossier({ s, onDrill }) {
    const recon = RECON[s.recon];
    const reconMark = s.recon === 'scanned' ? '●' : s.recon === 'visited' ? '◐' : '○';
    return (
      <div className="fade-in" key={s.id} onClick={(e) => e.stopPropagation()} style={glass({ position: 'absolute', bottom: 22, right: 22, width: 312, borderRadius: 18, padding: 18 })}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ fontFamily: M, fontSize: 13, color: s.recon === 'aware' ? c.t3 : c.t2 }}>{reconMark}</span>
          <span style={{ fontSize: 21, fontWeight: 700, letterSpacing: -0.3 }}>{s.name}</span>
          {s.home && <span style={{ fontFamily: M, fontSize: 9, fontWeight: 700, color: c.accent, padding: '2px 6px', borderRadius: 5, background: c.accentSoft }}>HOME</span>}
          <span style={{ marginLeft: 'auto', fontFamily: M, fontSize: 11, color: c.t3 }}>{s.cls}</span>
        </div>
        <div style={{ fontSize: 11.5, color: c.t2, marginTop: 6 }}>{recon.label} · {recon.note}</div>
        <div style={{ display: 'flex', gap: 12, margin: '14px 0', padding: '13px 0', borderTop: `1px solid ${c.glassLineSoft}`, borderBottom: `1px solid ${c.glassLineSoft}` }}>
          {[['Devices', s.presence === 'mine' ? s.devices : '—', s.presence === 'mine' && s.devices > 0], ['Vessels', s.vessels || '—', false], ['Relays', s.relay ? relayCount(s.id) : '—', false]].map(([k, v, hot]) => (
            <div key={k} style={{ flex: 1 }}><div style={{ fontFamily: M, fontSize: 17, fontWeight: 700, color: hot ? c.accent : c.t1 }}>{v}</div><div style={{ fontSize: 9.5, color: c.t3, letterSpacing: 0.5, textTransform: 'uppercase', marginTop: 3 }}>{k}</div></div>
          ))}
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
          <Line k="Life" v={lifeLabel(s)} dot={s.life ? c.life : null} />
          <Line k="Resources" v={`${Math.round(s.resource * 100)}% richness`} bar={s.resource} barCol={c.resource} />
          <Line k="Presence" v={s.presence === 'mine' ? 'Sylphrena (mine)' : s.presence === 'npc' ? 'Foreign probe' : 'None'} dot={s.presence === 'npc' ? c.npc : s.presence ? c.accent : null} />
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          <Btn primary>Plot course</Btn>
          {s.recon !== 'aware' ? <Btn onClick={() => onDrill(s)}>Drill into system →</Btn> : <Btn>Plot survey</Btn>}
        </div>
      </div>
    );
  }

  // ── system dossier ─────────────────────────────────────────────
  function resolve(id) {
    if (!id) return null;
    if (planetById[id]) return { kind: 'planet', d: planetById[id] };
    const lp = SYS_LAGRANGE.find((x) => x.id === id); if (lp) return { kind: 'lagrange', d: lp };
    const v = SYS_VESSELS.find((x) => x.code === id); if (v) return { kind: 'vessel', d: v };
    const dv = SYS_DEVICES.find((x) => x.code === id); if (dv) return { kind: 'device', d: dv };
    return null;
  }
  function Title({ eyebrow, name, right }) {
    return <div style={{ marginBottom: 12 }}><div style={{ fontFamily: M, fontSize: 10, letterSpacing: 1.6, textTransform: 'uppercase', color: c.t3 }}>{eyebrow}</div><div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginTop: 4 }}><span style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.3 }}>{name}</span>{right}</div></div>;
  }
  function KV({ k, v, dot }) {
    return <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: `1px solid ${c.glassLineSoft}` }}><span style={{ fontSize: 11, color: c.t3, width: 88, flexShrink: 0 }}>{k}</span>{dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: dot, boxShadow: `0 0 6px ${dot}`, flexShrink: 0 }} />}<span style={{ fontSize: 12.5, color: c.t1, flex: 1 }}>{v}</span></div>;
  }
  function SystemDossier({ sel }) {
    const r = resolve(sel); if (!r) return null;
    let body;
    if (r.kind === 'vessel') { const v = r.d; const hero = v.name === 'HEAVEN';
      body = <><Title eyebrow={hero ? 'Replicant host vessel' : 'Vessel'} name={v.name} right={<span style={{ fontFamily: M, fontSize: 11, color: c.transit, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.transit, boxShadow: `0 0 6px ${c.transit}` }} />Cruising</span>} />
        <KV k="Replicant" v={hero ? 'Sylphrena · 30B93F2F' : '—'} dot={hero ? c.accent : null} />
        <KV k="Course" v={`${planetById[v.from] ? planetById[v.from].name : v.from} → ${planetById[v.to] ? planetById[v.to].name : v.to}`} />
        <KV k="Progress" v={`${Math.round(v.t * 100)}% · ETA 41m`} /><KV k="Code" v={v.code} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}><Btn primary>Set destination</Btn><Btn>Open vessel →</Btn></div>
        <div style={{ fontSize: 10.5, color: c.t3, marginTop: 10, textAlign: 'center' }}>Tap any body or point on the map to retarget</div></>;
    } else if (r.kind === 'planet') { const p = r.d;
      body = <><Title eyebrow={`${p.type} · ${p.id}`} name={p.name} right={p.life ? <span style={{ fontFamily: M, fontSize: 11, color: c.life, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.life }} />Life</span> : null} />
        <KV k="Class" v={p.type} /><KV k="Moons" v={(p.moons || []).length || '—'} /><KV k="Devices" v={p.devices ? `${p.devices} stationed` : 'None'} dot={p.devices ? c.accent : null} />{p.lagrange ? <KV k="Lagrange" v="L1–L5 plotted" dot={c.accent} /> : null}
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}><Btn primary>Travel here</Btn><Btn>Scan</Btn></div></>;
    } else if (r.kind === 'lagrange') { const lp = r.d; const host = planetById[lp.host];
      body = <><Title eyebrow={`Lagrange point · ${host.name}`} name={lp.id} right={lp.device ? <span style={{ fontFamily: M, fontSize: 11, color: c.accent }}>occupied</span> : null} />
        <div style={{ fontSize: 12.5, color: c.t2, lineHeight: 1.5, marginBottom: 12 }}>{lp.label}</div>
        <KV k="Stability" v={lp.kind === 'trojan' ? 'Stable (trojan)' : 'Metastable'} /><KV k="Station" v={lp.device ? ({ ftl_relay: 'FTL Relay', surge_plate: 'Surge Plate' })[lp.device] : 'Vacant'} dot={lp.device ? c.accent : null} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}><Btn primary>Travel to {lp.id}</Btn><Btn>{lp.device ? 'Open device →' : 'Deploy here'}</Btn></div></>;
    } else { const d = r.d;
      body = <><Title eyebrow="Device" name={d.label} right={<span style={{ fontFamily: M, fontSize: 11, color: c.accent, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: c.accent }} />{d.status}</span>} />
        <KV k="Code" v={d.code} /><KV k="Station" v={d.at === 'belt' ? 'Chamakuy belt' : d.at} />
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}><Btn primary>Retarget</Btn><Btn>Open device →</Btn></div></>;
    }
    return <div className="fade-in" key={sel} onClick={(e) => e.stopPropagation()} style={glass({ position: 'absolute', bottom: 22, right: 22, width: 312, borderRadius: 18, padding: 18 })}>{body}</div>;
  }

  function TrackedDock({ sel, setSel }) {
    return (
      <div onClick={(e) => e.stopPropagation()} style={{ position: 'absolute', top: 24, right: 24, display: 'flex', flexDirection: 'column', gap: 8, alignItems: 'flex-end' }}>
        <span style={{ fontFamily: M, fontSize: 10, letterSpacing: 1.4, color: c.t3, marginRight: 4 }}>TRACKED</span>
        {SYS_VESSELS.map((v) => { const on = sel === v.code; const col = v.name === 'HEAVEN' ? c.accent : c.transit;
          return (
            <button key={v.code} onClick={() => setSel(v.code)} style={glass({ display: 'flex', alignItems: 'center', gap: 9, padding: '9px 13px', borderRadius: 11, border: 'none', cursor: 'pointer', minWidth: 168, boxShadow: `inset 0 0 0 0.5px ${on ? c.accentLine : c.glassLine}`, textAlign: 'left' })}>
              <span style={{ width: 8, height: 8, borderRadius: '50%', flexShrink: 0, background: col, boxShadow: `0 0 7px ${col}` }} />
              <span style={{ flex: 1 }}><span style={{ display: 'block', fontSize: 12, fontWeight: 600, color: c.t1 }}>{v.name}</span><span style={{ display: 'block', fontFamily: M, fontSize: 9.5, color: c.t3 }}>{v.status}</span></span>
            </button>
          );
        })}
      </div>
    );
  }

  function InsetCard({ onBack, sysId = 'CHK', label = 'CHAMAKUY' }) {
    return (
      <div onClick={(e) => e.stopPropagation()} style={glass({ width: 188, borderRadius: 14, padding: 8, marginTop: 12 })}>
        <div style={{ position: 'relative', height: 78, borderRadius: 9, overflow: 'hidden', background: 'rgba(255,255,255,0.02)' }}>
          <svg width="172" height="78" viewBox="0 0 172 78" style={{ display: 'block' }}>
            <ellipse cx="86" cy="40" rx="68" ry="26" fill="none" stroke={c.glassLineSoft} />
            {GAL_SYSTEMS.map((s) => { const a = s.a * Math.PI / 180; const here = s.id === sysId; return (
              <circle key={s.id} cx={86 + Math.cos(a) * s.r * 66} cy={40 + Math.sin(a) * s.r * 26} r={here ? 3.4 : 1.6} fill={here ? c.accent : s.presence === 'mine' ? c.accent : c.starDim} opacity={here ? 1 : 0.65} style={here ? { filter: `drop-shadow(0 0 5px ${c.accent})` } : null} />
            ); })}
          </svg>
          <span style={{ position: 'absolute', left: 8, bottom: 6, fontFamily: M, fontSize: 8.5, letterSpacing: 0.6, color: c.t3 }}>{label.toUpperCase()} · ORION SPUR</span>
        </div>
        <button onClick={onBack} style={{ display: 'flex', width: '100%', alignItems: 'center', justifyContent: 'center', gap: 7, marginTop: 8, padding: '9px 12px', borderRadius: 9, border: 'none', cursor: 'pointer', background: 'rgba(255,255,255,0.05)', boxShadow: `inset 0 0 0 0.5px ${c.glassLine}`, color: c.t1, fontFamily: F, fontSize: 12, fontWeight: 600 }}>
          <span style={{ fontSize: 13 }}>↖</span> Back to Galaxy
        </button>
      </div>
    );
  }

  Object.assign(window, { mapHud: { glass, GalaxyRail, SystemRail, GalaxyDossier, SystemDossier, TrackedDock, InsetCard, resolve } });
})();
