// DirectionA.jsx — "Instrument" (refined). Rigid three-pane pro tool.
// Theme-aware (dark / light). Replicant switcher, XP, account footer in
// sidebar; ported location map + parameterized commands in the inspector.
// Exports window.DirectionA. Pass <DirectionA theme="dark|light" />.

(function () {
  const F = window.RD_FONT, M = window.RD_MONO;
  const {
    rdStatusOf, rdType, DeviceGlyph, RingGauge,
    RD_REPLICANT, RD_REPLICANTS, RD_DEVICES, RD_ACCOUNT, RD_LOCATIONS, RD_RESOURCES,
  } = window;

  function tokens(theme) {
    if (theme === 'light') return {
      theme, win: '#f1ece3', sidebar: 'rgba(233,227,217,0.96)', content: '#f9f5ee',
      panel: 'rgba(28,34,48,0.035)', panel2: 'rgba(28,34,48,0.06)',
      line: 'rgba(28,34,48,0.12)', lineSoft: 'rgba(28,34,48,0.07)',
      t1: '#1b2230', t2: '#5a6478', t3: '#929bad',
      accent: '#cf8418', accentBtn: 'linear-gradient(180deg,#eaa835,#cf8418)', accentText: '#fff',
      accentGlow: 'rgba(207,132,24,0.28)', selBg: 'rgba(207,132,24,0.13)', selRing: 'rgba(207,132,24,0.45)',
      glyph: '#5a6478', glyphSel: '#cf8418', ringTrack: 'rgba(28,34,48,0.10)',
      nebula: 'radial-gradient(680px 380px at 90% -10%, rgba(207,132,24,0.07), transparent 62%)',
      mapStar: 'radial-gradient(circle at 38% 32%, #ffcf7a, #cf8418)',
      danger: '#bb463c', dangerBg: 'rgba(187,70,60,0.09)', dangerRing: 'rgba(187,70,60,0.30)',
      shadow: '0 0 0 0.5px rgba(28,34,48,0.10), 0 40px 110px rgba(40,30,15,0.22)',
      fieldBg: 'rgba(255,255,255,0.7)',
    };
    return {
      theme, win: '#0b1019', sidebar: 'rgba(15,21,33,0.92)', content: '#0a1019',
      panel: 'rgba(255,255,255,0.035)', panel2: 'rgba(255,255,255,0.06)',
      line: 'rgba(255,255,255,0.085)', lineSoft: 'rgba(255,255,255,0.05)',
      t1: '#e9eef7', t2: '#9aa6bc', t3: '#6a7488',
      accent: '#ffb23e', accentBtn: 'linear-gradient(180deg,#ffc05c,#ff9e2c)', accentText: '#2a1a05',
      accentGlow: 'rgba(255,158,44,0.32)', selBg: 'rgba(255,178,62,0.12)', selRing: 'rgba(255,178,62,0.34)',
      glyph: '#c2ccde', glyphSel: '#ffb23e', ringTrack: 'rgba(255,255,255,0.10)',
      nebula: 'radial-gradient(680px 380px at 88% -8%, rgba(255,178,62,0.10), transparent 62%), radial-gradient(620px 520px at 112% 116%, rgba(63,211,203,0.06), transparent 60%)',
      mapStar: 'radial-gradient(circle at 38% 32%, #ffe6b0, #d39433)',
      danger: '#e58a83', dangerBg: 'rgba(224,114,106,0.12)', dangerRing: 'rgba(224,114,106,0.30)',
      shadow: '0 0 0 0.5px rgba(255,255,255,0.10), 0 40px 120px rgba(0,0,0,0.6)',
      fieldBg: 'rgba(255,255,255,0.05)',
    };
  }
  const Ctx = React.createContext(tokens('dark'));
  const useC = () => React.useContext(Ctx);

  function Traffic() {
    const dot = (col) => <span style={{ width: 12, height: 12, borderRadius: '50%', background: col, display: 'block', boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.25)' }} />;
    return <div style={{ display: 'flex', gap: 8 }}>{dot('#ff5f57')}{dot('#febc2e')}{dot('#28c840')}</div>;
  }

  function CatIcon({ kind, color }) {
    const s = { fill: 'none', stroke: color, strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' };
    const P = { stars: <g {...s}><circle cx="9" cy="9" r="2.4" /><line x1="9" y1="1.5" x2="9" y2="4" /><line x1="9" y1="14" x2="9" y2="16.5" /><line x1="1.5" y1="9" x2="4" y2="9" /><line x1="14" y1="9" x2="16.5" y2="9" /></g>,
      devices: <g {...s}><path d="M9 2 L14.5 5.2 L14.5 12.8 L9 16 L3.5 12.8 L3.5 5.2 Z" /><circle cx="9" cy="9" r="1.8" fill={color} stroke="none" /></g>,
      replicants: <g {...s}><circle cx="9" cy="9" r="7" /><circle cx="9" cy="9" r="1.8" fill={color} stroke="none" /><circle cx="15.4" cy="9" r="1.3" fill={color} stroke="none" /></g>,
      blueprints: <g {...s}><rect x="3" y="2.5" width="12" height="13" rx="1.5" /><line x1="6" y1="6" x2="12" y2="6" /><line x1="6" y1="9" x2="12" y2="9" /><line x1="6" y1="12" x2="9.5" y2="12" /></g>,
      queue: <g {...s}><line x1="4" y1="5" x2="14" y2="5" /><line x1="4" y1="9" x2="14" y2="9" /><line x1="4" y1="13" x2="10" y2="13" /></g>,
      signals: <g {...s}><circle cx="9" cy="11" r="1.6" fill={color} stroke="none" /><path d="M5.5 11a3.5 3.5 0 0 1 7 0" /><path d="M3 11a6 6 0 0 1 12 0" opacity="0.55" /></g> };
    return <svg width="18" height="18" viewBox="0 0 18 18">{P[kind]}</svg>;
  }

  function NavItem({ kind, label, count, selected, soon, onClick }) {
    const c = useC();
    const col = selected ? c.accent : c.t2;
    return (
      <button onClick={onClick} style={{
        display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left',
        height: 34, padding: '0 10px', borderRadius: 8, border: 'none', cursor: soon ? 'default' : 'pointer',
        background: selected ? c.selBg : 'transparent', position: 'relative', fontFamily: F,
        color: soon ? c.t3 : (selected ? c.t1 : c.t2), opacity: soon ? 0.6 : 1,
        boxShadow: selected ? `inset 0 0 0 0.5px ${c.selRing}` : 'none',
      }}>
        {selected && <span style={{ position: 'absolute', left: -8, top: 9, bottom: 9, width: 3, borderRadius: 3, background: c.accent, boxShadow: `0 0 8px ${c.accent}` }} />}
        <CatIcon kind={kind} color={col} />
        <span style={{ fontSize: 13, fontWeight: selected ? 600 : 500, flex: 1 }}>{label}</span>
        {soon ? <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.4, color: c.t3, textTransform: 'uppercase' }}>soon</span>
          : count != null && <span style={{ fontFamily: M, fontSize: 11, color: selected ? c.accent : c.t3, fontWeight: 600 }}>{count}</span>}
      </button>
    );
  }

  // ── Replicant switcher header ──────────────────────────────────
  function ReplicantHeader({ active, onSwitch, onViewInList }) {
    const c = useC();
    const [open, setOpen] = React.useState(false);
    return (
      <div style={{ padding: '4px 16px 14px', position: 'relative' }}>
        <div style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: c.t3, marginBottom: 7, paddingLeft: 2 }}>Active Replicant</div>
        {/* switcher button */}
        <button onClick={() => setOpen((o) => !o)} style={{
          display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
          padding: '8px 10px', borderRadius: 10, border: 'none', background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.line}`,
        }}>
          <span style={{ width: 26, height: 26, borderRadius: 7, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: c.selBg, boxShadow: `inset 0 0 0 0.5px ${c.selRing}` }}>
            <DeviceGlyph kind="orbit" size={16} color={c.accent} />
          </span>
          <span style={{ flex: 1, minWidth: 0 }}>
            <span style={{ display: 'block', fontSize: 15, fontWeight: 700, color: c.t1, letterSpacing: -0.2 }}>{active.name}</span>
            <span style={{ display: 'block', fontFamily: M, fontSize: 10.5, color: c.t3, marginTop: 1 }}>{active.id}</span>
          </span>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}><path d="M2 4.5l4 4 4-4" /></svg>
        </button>
        {open && (
          <div style={{ position: 'absolute', left: 16, right: 16, top: 78, zIndex: 30, background: c.theme === 'light' ? '#fff' : '#161d2c', borderRadius: 10, boxShadow: `0 12px 36px rgba(0,0,0,${c.theme === 'light' ? 0.18 : 0.5}), inset 0 0 0 0.5px ${c.line}`, padding: 5 }}>
            {RD_REPLICANTS.map((r) => (
              <button key={r.id} onClick={() => { setOpen(false); onSwitch(r); }} style={{
                display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
                padding: '8px 9px', borderRadius: 7, border: 'none', background: r.id === active.id ? c.selBg : 'transparent', fontFamily: F,
              }}>
                <span style={{ width: 22, height: 22, borderRadius: 6, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: c.panel2 }}>
                  <DeviceGlyph kind="orbit" size={13} color={r.id === active.id ? c.accent : c.t2} />
                </span>
                <span style={{ flex: 1, minWidth: 0 }}>
                  <span style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: c.t1 }}>{r.name}</span>
                  <span style={{ display: 'block', fontFamily: M, fontSize: 10, color: c.t3 }}>{r.location}</span>
                </span>
                <span style={{ textAlign: 'right' }}>
                  <span style={{ display: 'block', fontFamily: M, fontSize: 11, fontWeight: 700, color: c.t2 }}>Lv {r.level}</span>
                  <span style={{ display: 'block', fontFamily: M, fontSize: 9.5, color: c.t3 }}>{r.devices} dev</span>
                </span>
              </button>
            ))}
            <div style={{ borderTop: `1px solid ${c.lineSoft}`, margin: '5px 4px 4px', paddingTop: 4 }}>
              <button style={{ display: 'flex', alignItems: 'center', gap: 7, width: '100%', padding: '7px 9px', borderRadius: 7, border: 'none', background: 'transparent', cursor: 'pointer', color: c.t2, fontFamily: F, fontSize: 12, fontWeight: 500 }}>
                <span style={{ fontSize: 14, lineHeight: 1 }}>+</span> Commission new replicant
              </button>
            </div>
          </div>
        )}

        {/* xp + level */}
        <div style={{ marginTop: 10, padding: '10px 12px', borderRadius: 10, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.line}` }}>
          <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: 7 }}>
            <span style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
              <span style={{ fontFamily: M, fontSize: 15, fontWeight: 700, color: c.t1 }}>{active.xp.toLocaleString()}</span>
              <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: 0.4, color: c.t3 }}>XP</span>
            </span>
            <span style={{ fontFamily: M, fontSize: 11, fontWeight: 700, color: c.accent }}>Lv {active.level}</span>
          </div>
          <div style={{ height: 5, borderRadius: 3, background: c.ringTrack, overflow: 'hidden' }}><div style={{ width: `${Math.round(active.xpInto * 100)}%`, height: '100%', background: c.accent, borderRadius: 3, boxShadow: `0 0 8px ${c.accent}88` }} /></div>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 5 }}>
            <span style={{ fontFamily: M, fontSize: 9.5, color: c.t3 }}>{Math.round((active.xpNext - active.xp) / 1).toLocaleString()} to Lv {active.level + 1}</span>
            <button onClick={onViewInList} style={{ display: 'inline-flex', alignItems: 'center', gap: 3, border: 'none', background: 'transparent', cursor: 'pointer', color: c.accent, fontFamily: F, fontSize: 10.5, fontWeight: 600, padding: 0 }}>
              View in Replicants <span style={{ fontSize: 11 }}>↗</span>
            </button>
          </div>
        </div>

        {/* directive */}
        <div style={{ marginTop: 9, padding: '10px 12px', borderRadius: 10, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.line}` }}>
          <div style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase', color: c.t3, marginBottom: 4 }}>Directive</div>
          <div style={{ fontSize: 12, lineHeight: 1.45, color: c.t1, marginBottom: 8 }}>{active.directive}</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, borderTop: `1px solid ${c.lineSoft}`, paddingTop: 8 }}>
            <CatIcon kind="devices" color={c.t3} />
            <span style={{ fontSize: 10.5, color: c.t3 }}>Stationed at</span>
            <span style={{ fontFamily: M, fontSize: 11, color: c.t1, marginLeft: 'auto' }}>{active.location}</span>
          </div>
        </div>
      </div>
    );
  }

  // ── Account footer ─────────────────────────────────────────────
  function AccountFooter() {
    const c = useC();
    const a = RD_ACCOUNT;
    return (
      <button style={{
        display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
        padding: '10px 14px', border: 'none', borderTop: `1px solid ${c.line}`, background: 'transparent', fontFamily: F,
      }}>
        <span style={{ width: 30, height: 30, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: c.theme === 'light' ? '#2a3445' : 'rgba(255,255,255,0.08)', boxShadow: `inset 0 0 0 0.5px ${c.line}`, fontFamily: M, fontSize: 11.5, fontWeight: 700, color: c.theme === 'light' ? '#fff' : c.t1 }}>{a.initials}</span>
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: c.t1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name}</span>
          <span style={{ display: 'block', fontSize: 10.5, color: c.t3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.email}</span>
        </span>
        <span style={{ textAlign: 'right', flexShrink: 0 }}>
          <span style={{ display: 'block', fontFamily: M, fontSize: 11.5, fontWeight: 700, color: c.accent }}>{(a.xp / 1000).toFixed(1)}k</span>
          <span style={{ display: 'block', fontSize: 9, letterSpacing: 0.4, color: c.t3, textTransform: 'uppercase' }}>Total XP</span>
        </span>
      </button>
    );
  }

  function StatusPill({ d, big }) {
    const c = useC();
    const s = rdStatusOf(d, c.theme);
    return (
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: big ? '4px 10px' : '2px 8px', borderRadius: 20, background: `${s.color}1f`, boxShadow: `inset 0 0 0 0.5px ${s.color}66` }}>
        <span style={{ width: 6, height: 6, borderRadius: '50%', background: s.color, boxShadow: `0 0 6px ${s.color}` }} />
        <span style={{ fontFamily: F, fontSize: big ? 12 : 11, fontWeight: 600, color: s.color }}>{s.label}</span>
      </span>
    );
  }

  function MiniBar({ pct, color }) {
    const c = useC();
    return <div style={{ width: 48, height: 4, borderRadius: 3, background: c.ringTrack, overflow: 'hidden' }}><div style={{ width: `${pct}%`, height: '100%', background: color, borderRadius: 3 }} /></div>;
  }

  function DeviceRow({ d, selected, onClick }) {
    const c = useC();
    const t = rdType(d), s = rdStatusOf(d, c.theme);
    const off = d.status === 'stowed' || d.status === 'inactive';
    return (
      <button onClick={onClick} style={{
        display: 'flex', alignItems: 'center', gap: 11, width: '100%', textAlign: 'left',
        padding: '10px 12px', border: 'none', cursor: 'pointer', position: 'relative',
        background: selected ? c.selBg : 'transparent', borderBottom: `1px solid ${c.lineSoft}`, fontFamily: F,
      }}>
        {selected && <span style={{ position: 'absolute', left: 0, top: 8, bottom: 8, width: 3, borderRadius: 3, background: c.accent, boxShadow: `0 0 8px ${c.accent}` }} />}
        <span style={{ width: 38, height: 38, borderRadius: 10, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: selected ? c.selBg : c.panel2, boxShadow: `inset 0 0 0 0.5px ${selected ? c.selRing : c.line}` }}>
          <DeviceGlyph kind={t.glyph} size={22} color={selected ? c.glyphSel : c.glyph} dim={off} />
        </span>
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: c.t1 }}>{t.label}</span>
            <span style={{ fontFamily: M, fontSize: 10.5, color: c.t3 }}>{d.code}</span>
          </span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 4 }}>
            <span style={{ width: 5, height: 5, borderRadius: '50%', background: s.color, flexShrink: 0 }} />
            <span style={{ fontSize: 11, color: c.t2 }}>{s.label}</span>
            <span style={{ fontSize: 11, color: c.t3, fontFamily: M, marginLeft: 'auto', whiteSpace: 'nowrap' }}>{d.location}</span>
          </span>
        </span>
        <span style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5, flexShrink: 0 }}>
          <span style={{ fontFamily: M, fontSize: 11, color: c.t2, fontWeight: 600 }}>{d.capacity}%</span>
          <MiniBar pct={d.capacity} color={d.capacity > 30 ? s.color : '#d8645c'} />
        </span>
      </button>
    );
  }

  function SectionLabel({ children, right }) {
    const c = useC();
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '0 0 12px' }}>
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: 1.2, textTransform: 'uppercase', color: c.t3 }}>{children}</span>
        {right}
      </div>
    );
  }

  function KeyVal({ k, children, last }) {
    const c = useC();
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 3, padding: '8px 0', borderBottom: last ? 'none' : `1px solid ${c.lineSoft}` }}>
        <span style={{ fontSize: 10, fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase', color: c.t3 }}>{k}</span>
        <span style={{ fontSize: 12.5, color: c.t1 }}>{children}</span>
      </div>
    );
  }

  // ── Position map (ported from Cosmic, theme-aware) ─────────────
  function OrbitMap({ d }) {
    const c = useC();
    const s = rdStatusOf(d, c.theme);
    const gid = 'amap-' + c.theme;
    return (
      <svg width="100%" height="148" viewBox="0 0 300 148" style={{ display: 'block' }}>
        <defs><radialGradient id={gid} cx="50%" cy="50%" r="50%"><stop offset="0%" stopColor={c.theme === 'light' ? '#ffcf7a' : '#ffe6b0'} /><stop offset="100%" stopColor={c.theme === 'light' ? '#cf8418' : '#d39433'} /></radialGradient></defs>
        {[32, 56, 82].map((r, i) => <ellipse key={i} cx="112" cy="74" rx={r} ry={r * 0.46} fill="none" stroke={c.ringTrack} strokeWidth="1" />)}
        <line x1="60" y1="74" x2="182" y2="74" stroke={c.line} strokeWidth="1" strokeDasharray="3 4" />
        <circle cx="112" cy="74" r="6" fill={`url(#${gid})`} />
        <circle cx="112" cy="74" r="11" fill="none" stroke={`${c.accent}66`} strokeWidth="1" />
        <circle cx="56" cy="74" r="3" fill="#43b884" />
        <g>
          <circle cx="194" cy="74" r="13" fill={`${s.color}22`} />
          <circle cx="194" cy="74" r="4.5" fill={s.color} style={{ filter: `drop-shadow(0 0 6px ${s.color})` }} />
        </g>
        <text x="194" y="100" textAnchor="middle" fill={c.t2} fontSize="9.5" fontFamily={M} letterSpacing="0.3">{d.location}</text>
        <text x="56" y="100" textAnchor="middle" fill={c.t3} fontSize="9" fontFamily={M}>{RD_REPLICANT.location.split('-')[0]}</text>
      </svg>
    );
  }

  function Metric({ k, v, bar }) {
    const c = useC();
    return (
      <div style={{ flex: 1 }}>
        <div style={{ fontFamily: M, fontSize: 13, fontWeight: 700, color: c.t1 }}>{v}</div>
        <div style={{ fontSize: 9.5, color: c.t3, letterSpacing: 0.5, textTransform: 'uppercase', marginTop: 1 }}>{k}</div>
        {bar != null && <div style={{ height: 3, borderRadius: 2, background: c.ringTrack, marginTop: 5, overflow: 'hidden' }}><div style={{ width: `${Math.round(bar * 100)}%`, height: '100%', background: c.accent, borderRadius: 2 }} /></div>}
      </div>
    );
  }

  // ── Combobox (autocomplete) for command parameters ─────────────
  function Combo({ options, value, onChange, placeholder, startOpen }) {
    const c = useC();
    const [open, setOpen] = React.useState(!!startOpen);
    const [q, setQ] = React.useState('');
    const list = options.filter((o) => o.toLowerCase().includes(q.toLowerCase()));
    return (
      <div style={{ position: 'relative' }}>
        <div onClick={() => setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', gap: 8, height: 38, padding: '0 12px', borderRadius: 9, background: c.fieldBg, boxShadow: `inset 0 0 0 1px ${open ? c.selRing : c.line}`, cursor: 'pointer' }}>
          <DeviceGlyph kind="orbit" size={15} color={c.t3} />
          <span style={{ flex: 1, fontFamily: M, fontSize: 13, color: value ? c.t1 : c.t3 }}>{value || placeholder}</span>
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={c.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: open ? 'rotate(180deg)' : 'none' }}><path d="M2 4.5l4 4 4-4" /></svg>
        </div>
        {open && (
          <div style={{ position: 'absolute', left: 0, right: 0, top: 44, zIndex: 40, background: c.theme === 'light' ? '#fff' : '#141b29', borderRadius: 10, boxShadow: `0 16px 40px rgba(0,0,0,${c.theme === 'light' ? 0.16 : 0.55}), inset 0 0 0 0.5px ${c.line}`, padding: 6, maxHeight: 226, overflow: 'auto' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 7, height: 32, padding: '0 9px', marginBottom: 4, borderRadius: 7, background: c.panel }}>
              <svg width="12" height="12" viewBox="0 0 13 13" fill="none"><circle cx="5.5" cy="5.5" r="4" stroke={c.t3} strokeWidth="1.4" /><path d="M8.5 8.5l3 3" stroke={c.t3} strokeWidth="1.4" strokeLinecap="round" /></svg>
              <input autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search or type a destination…"
                style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: M, fontSize: 12.5, color: c.t1 }} />
            </div>
            {list.map((o) => (
              <button key={o} onClick={() => { onChange(o); setOpen(false); }} style={{
                display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', cursor: 'pointer',
                padding: '8px 9px', borderRadius: 7, border: 'none', background: o === value ? c.selBg : 'transparent', fontFamily: M, fontSize: 12.5, color: c.t1,
              }}>
                <span style={{ width: 6, height: 6, borderRadius: '50%', background: o === value ? c.accent : c.t3 }} />
                {o}
              </button>
            ))}
            {q && !list.includes(q) && (
              <button onClick={() => { onChange(q.toUpperCase()); setOpen(false); }} style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '8px 9px', borderRadius: 7, border: 'none', background: 'transparent', fontFamily: F, fontSize: 12, color: c.t2 }}>
                <span style={{ fontSize: 13 }}>+</span> Use “{q}”
              </button>
            )}
          </div>
        )}
      </div>
    );
  }

  function Chips({ options, value, onChange }) {
    const c = useC();
    return (
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 7 }}>
        {options.map((o) => {
          const on = o === value;
          return (
            <button key={o} onClick={() => onChange(o)} style={{
              padding: '7px 13px', borderRadius: 18, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12.5, fontWeight: 600,
              background: on ? c.accentBtn : c.panel2, color: on ? c.accentText : c.t2,
              boxShadow: on ? `0 3px 12px ${c.accentGlow}` : `inset 0 0 0 0.5px ${c.line}`,
            }}>{o}</button>
          );
        })}
      </div>
    );
  }

  // Per-command parameter metadata.
  const CMD = {
    travel:       { label: 'Travel',       title: 'Set destination',     kind: 'location', sub: 'transport' },
    retarget:     { label: 'Retarget',     title: 'Choose target site',  kind: 'location' },
    recall:       { label: 'Recall',       title: 'Recall destination',  kind: 'location' },
    start_mining: { label: 'Start mining', title: 'Select resource',     kind: 'resource' },
    stow:         { label: 'Stow',         title: 'Stow into container',  kind: 'hauler' },
    change_owner: { label: 'Change owner', title: 'Transfer to replicant', kind: 'replicant' },
    deactivate:   { label: 'Deactivate',   title: 'Deactivate device',   kind: 'confirm', danger: true, warn: 'The device suspends all tasks and stops reporting until reactivated.' },
    decommission: { label: 'Decommission', title: 'Decommission device', kind: 'confirm', danger: true, warn: 'Permanently retires the device. It travels to the nearest forge to be reclaimed.' },
  };

  function CommandPanel({ cmdKey, device, onClose }) {
    const c = useC();
    const meta = CMD[cmdKey];
    const haulers = RD_DEVICES.filter((x) => x.type === 'hauler').map((x) => `Hauler · ${x.code}`);
    const init = { location: device.location, resource: device.param || 'Iron', hauler: haulers[0], replicant: RD_REPLICANTS[1].name }[meta.kind];
    const [val, setVal] = React.useState(init);
    const [mode, setMode] = React.useState('Cruise');
    return (
      <div style={{ marginTop: 12, borderRadius: 12, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${meta.danger ? c.dangerRing : c.selRing}`, padding: 16, position: 'relative', overflow: 'visible' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 12 }}>
          <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: 0.5, textTransform: 'uppercase', color: meta.danger ? c.danger : c.accent }}>{meta.label}</span>
          <span style={{ width: 3, height: 3, borderRadius: '50%', background: c.t3 }} />
          <span style={{ fontSize: 12.5, fontWeight: 600, color: c.t1 }}>{meta.title}</span>
          <button onClick={onClose} style={{ marginLeft: 'auto', width: 24, height: 24, borderRadius: 7, border: 'none', cursor: 'pointer', background: c.panel2, color: c.t2, fontSize: 15, lineHeight: 1, boxShadow: `inset 0 0 0 0.5px ${c.line}` }}>×</button>
        </div>

        {meta.kind === 'location' && <><Combo options={RD_LOCATIONS} value={val} onChange={setVal} placeholder="Choose a destination" startOpen />
          {meta.sub === 'transport' && (
            <div style={{ marginTop: 12 }}>
              <div style={{ fontSize: 10, fontWeight: 600, letterSpacing: 0.5, textTransform: 'uppercase', color: c.t3, marginBottom: 7 }}>Transport mode</div>
              <Chips options={['Cruise', 'Surge']} value={mode} onChange={setMode} />
            </div>
          )}</>}
        {meta.kind === 'resource' && <Chips options={RD_RESOURCES} value={val} onChange={setVal} />}
        {meta.kind === 'hauler' && <Combo options={haulers} value={val} onChange={setVal} placeholder="Choose a hauler" startOpen />}
        {meta.kind === 'replicant' && <Combo options={RD_REPLICANTS.map((r) => `${r.name} · ${r.id}`)} value={val} onChange={setVal} placeholder="Choose a replicant" startOpen />}
        {meta.kind === 'confirm' && <p style={{ fontSize: 12.5, lineHeight: 1.5, color: c.t2, margin: 0 }}>{meta.warn}</p>}

        <div style={{ display: 'flex', gap: 9, marginTop: 16, justifyContent: 'flex-end' }}>
          <button onClick={onClose} style={{ padding: '9px 16px', borderRadius: 9, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12.5, fontWeight: 600, background: 'transparent', color: c.t2, boxShadow: `inset 0 0 0 0.5px ${c.line}` }}>Cancel</button>
          <button style={{ padding: '9px 18px', borderRadius: 9, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12.5, fontWeight: 700, color: meta.danger ? '#fff' : c.accentText, background: meta.danger ? c.danger : c.accentBtn, boxShadow: `0 4px 14px ${meta.danger ? 'rgba(187,70,60,0.32)' : c.accentGlow}` }}>
            {meta.kind === 'confirm' ? meta.label : `${meta.label}${val ? ` → ${String(val).split(' · ')[0]}` : ''}`}
          </button>
        </div>
      </div>
    );
  }

  function Cmd({ cmdKey, active, disabled, note, running, onClick }) {
    const c = useC();
    const meta = CMD[cmdKey];
    const st = active
      ? { background: c.accentBtn, color: c.accentText, boxShadow: `0 4px 14px ${c.accentGlow}` }
      : { background: c.panel2, color: c.t1, boxShadow: `inset 0 0 0 0.5px ${c.line}` };
    return (
      <button disabled={disabled} onClick={onClick} style={{
        display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 2, padding: '9px 12px',
        borderRadius: 9, cursor: disabled ? 'default' : 'pointer', fontFamily: F, fontSize: 13, fontWeight: 600,
        border: 'none', textAlign: 'left', opacity: disabled ? 0.4 : 1, ...st,
      }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          {running && <span style={{ width: 6, height: 6, borderRadius: '50%', background: active ? c.accentText : c.accent, boxShadow: active ? 'none' : `0 0 6px ${c.accent}` }} />}
          {meta.label}
        </span>
        {note && <span style={{ fontSize: 10, fontWeight: 500, color: active ? (c.theme === 'light' ? 'rgba(255,255,255,0.8)' : 'rgba(42,26,5,0.6)') : c.t3 }}>{note}</span>}
      </button>
    );
  }

  function SmallCmd({ cmdKey, active, onClick }) {
    const c = useC();
    const meta = CMD[cmdKey];
    const danger = meta.danger;
    return <button onClick={onClick} style={{ flex: 1, padding: '8px 10px', borderRadius: 8, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 12, fontWeight: 600, background: active ? (danger ? c.dangerBg : c.selBg) : 'transparent', color: danger ? c.danger : c.t2, boxShadow: `inset 0 0 0 0.5px ${active ? (danger ? c.dangerRing : c.selRing) : (danger ? c.dangerRing : c.line)}` }}>{meta.label}</button>;
  }

  function Inspector({ d }) {
    const c = useC();
    const t = rdType(d), s = rdStatusOf(d, c.theme);
    const [cmd, setCmd] = React.useState('travel'); // demo: Travel param panel open
    const toggle = (k) => setCmd((x) => (x === k ? null : k));
    return (
      <div style={{ height: '100%', overflow: 'auto', padding: '20px 24px 28px' }}>
        {/* header */}
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
          <div style={{ width: 54, height: 54, borderRadius: 14, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: c.selBg, boxShadow: `inset 0 0 0 0.5px ${c.selRing}` }}>
            <DeviceGlyph kind={t.glyph} size={30} color={c.accent} />
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ fontSize: 20, fontWeight: 700, color: c.t1, letterSpacing: -0.2 }}>{t.label}</span>
              <StatusPill d={d} big />
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 6 }}>
              <span style={{ fontFamily: M, fontSize: 12, color: c.t2 }}>{d.code}</span>
              <span style={{ width: 3, height: 3, borderRadius: '50%', background: c.t3 }} />
              <span style={{ fontFamily: M, fontSize: 12, color: c.t2 }}>{d.location}</span>
            </div>
          </div>
          <button style={{ width: 30, height: 30, borderRadius: 8, border: 'none', background: c.panel2, boxShadow: `inset 0 0 0 0.5px ${c.line}`, color: c.t2, cursor: 'pointer', fontSize: 16, lineHeight: 1 }}>⋯</button>
        </div>

        <p style={{ fontSize: 12.5, lineHeight: 1.5, color: c.t2, margin: '14px 0 18px' }}>{t.blurb}</p>

        {/* readouts */}
        <div style={{ display: 'flex', gap: 16, marginBottom: 20 }}>
          <div style={{ width: 168, flexShrink: 0, background: c.panel, borderRadius: 14, boxShadow: `inset 0 0 0 0.5px ${c.line}`, padding: 16, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
            <RingGauge pct={d.capacity} size={104} stroke={9} color={c.accent} track={c.ringTrack}>
              <span style={{ fontFamily: M, fontSize: 24, fontWeight: 700, color: c.t1 }}>{d.capacity}<span style={{ fontSize: 13, color: c.t2 }}>%</span></span>
            </RingGauge>
            <span style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: 0.8, textTransform: 'uppercase', color: c.t3 }}>Op. Capacity</span>
            <div style={{ display: 'flex', gap: 14, width: '100%', justifyContent: 'center', paddingTop: 6, borderTop: `1px solid ${c.lineSoft}` }}>
              <div style={{ textAlign: 'center' }}><div style={{ fontFamily: M, fontSize: 14, fontWeight: 700, color: c.t1 }}>{d.integrity}%</div><div style={{ fontSize: 9.5, color: c.t3, letterSpacing: 0.4 }}>INTEG</div></div>
              <div style={{ textAlign: 'center' }}><div style={{ fontFamily: M, fontSize: 14, fontWeight: 700, color: d.signal ? c.t1 : c.t3 }}>{d.signal}%</div><div style={{ fontSize: 9.5, color: c.t3, letterSpacing: 0.4 }}>SIGNAL</div></div>
            </div>
          </div>

          <div style={{ flex: 1, background: c.panel, borderRadius: 14, boxShadow: `inset 0 0 0 0.5px ${c.line}`, padding: 16, display: 'flex', flexDirection: 'column' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <span style={{ fontSize: 10.5, fontWeight: 700, letterSpacing: 0.8, textTransform: 'uppercase', color: c.t3 }}>Active Task</span>
              {d.task && <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: s.color, boxShadow: `0 0 6px ${s.color}` }} /><span style={{ fontSize: 11, color: s.color, fontWeight: 600 }}>{s.short}</span></span>}
            </div>
            {d.task ? (
              <>
                <div style={{ fontSize: 15, fontWeight: 600, color: c.t1, margin: '10px 0 12px' }}>{d.task.label}{d.task.site && <span style={{ fontFamily: M, fontSize: 11, color: c.t3, marginLeft: 8 }}>{d.task.site}</span>}</div>
                <div style={{ height: 8, borderRadius: 5, background: c.ringTrack, overflow: 'hidden' }}><div style={{ width: `${Math.round(d.task.progress * 100)}%`, height: '100%', background: `linear-gradient(90deg, ${s.color}aa, ${s.color})`, borderRadius: 5, boxShadow: `0 0 10px ${s.color}88` }} /></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6 }}><span style={{ fontFamily: M, fontSize: 11, color: c.t2 }}>{Math.round(d.task.progress * 100)}% complete</span>{d.task.eta && <span style={{ fontFamily: M, fontSize: 11, color: c.t3 }}>ETA {d.task.eta}</span>}</div>
                <div style={{ display: 'flex', gap: 10, marginTop: 'auto', paddingTop: 14 }}>
                  {d.task.rate && <Metric k="Rate" v={d.task.rate} />}
                  {d.task.cargo != null && <Metric k="Cargo hold" v={`${Math.round(d.task.cargo * 100)}%`} bar={d.task.cargo} />}
                  <Metric k="Deployed" v={d.deployedFor} />
                </div>
              </>
            ) : (
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 6, color: c.t3, minHeight: 120 }}>
                <DeviceGlyph kind="orbit" size={30} color={c.t3} dim />
                <span style={{ fontSize: 12 }}>{d.status === 'stowed' ? `Stowed in ${d.stowedIn}` : 'No active task — awaiting command'}</span>
              </div>
            )}
          </div>
        </div>

        {/* details + position */}
        <div style={{ display: 'flex', gap: 16, marginBottom: 22, alignItems: 'stretch' }}>
          <div style={{ flex: 1.25, background: c.panel, borderRadius: 14, boxShadow: `inset 0 0 0 0.5px ${c.line}`, padding: '14px 16px' }}>
            <SectionLabel>Details</SectionLabel>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', columnGap: 20 }}>
              <KeyVal k="Type">{t.label}</KeyVal>
              <KeyVal k="Device ID"><span style={{ fontFamily: M }}>{d.code}</span></KeyVal>
              <KeyVal k="Owner"><span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}><DeviceGlyph kind="orbit" size={13} color={c.accent} />{RD_REPLICANT.name} <span style={{ fontFamily: M, color: c.t3, fontSize: 11 }}>{RD_REPLICANT.id}</span></span></KeyVal>
              <KeyVal k="Deployed">{d.deployedFor}</KeyVal>
              <div style={{ gridColumn: '1 / -1' }}>
                <KeyVal k="Features" last>
                  <span style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 2 }}>
                    {d.features.map((f) => <span key={f} style={{ fontFamily: M, fontSize: 11, color: c.t2, padding: '3px 9px', borderRadius: 6, background: c.panel2, boxShadow: `inset 0 0 0 0.5px ${c.line}` }}>{f}</span>)}
                  </span>
                </KeyVal>
              </div>
            </div>
          </div>
          <div style={{ flex: 1, background: c.panel, borderRadius: 14, boxShadow: `inset 0 0 0 0.5px ${c.line}`, padding: '14px 16px 8px' }}>
            <SectionLabel right={<span style={{ fontFamily: M, fontSize: 10.5, color: c.t3 }}>orbit view</span>}>Position</SectionLabel>
            <OrbitMap d={d} />
          </div>
        </div>

        {/* commands */}
        <SectionLabel right={<span style={{ fontSize: 11, color: c.t3, fontFamily: M }}>{d.commands.length} available</span>}>Commands</SectionLabel>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 9 }}>
          <Cmd cmdKey="retarget" note="Send to new site" active={cmd === 'retarget'} onClick={() => toggle('retarget')} />
          <Cmd cmdKey="recall" note="Return to base" active={cmd === 'recall'} onClick={() => toggle('recall')} />
          <Cmd cmdKey="travel" note="Move to location" active={cmd === 'travel'} onClick={() => toggle('travel')} />
          <Cmd cmdKey="start_mining" running note="Running · Iron" active={cmd === 'start_mining'} onClick={() => toggle('start_mining')} />
          <Cmd cmdKey="stow" note="Pack into hauler" active={cmd === 'stow'} onClick={() => toggle('stow')} />
          <Cmd cmdKey="travel" note="Already deployed" disabled />
        </div>
        {cmd && CMD[cmd] && <CommandPanel key={cmd} cmdKey={cmd} device={d} onClose={() => setCmd(null)} />}

        <div style={{ display: 'flex', gap: 9, marginTop: 14, paddingTop: 14, borderTop: `1px solid ${c.lineSoft}` }}>
          <SmallCmd cmdKey="change_owner" active={cmd === 'change_owner'} onClick={() => toggle('change_owner')} />
          <SmallCmd cmdKey="deactivate" active={cmd === 'deactivate'} onClick={() => toggle('deactivate')} />
          <SmallCmd cmdKey="decommission" active={cmd === 'decommission'} onClick={() => toggle('decommission')} />
        </div>
      </div>
    );
  }

  function DirectionA({ theme = 'dark' }) {
    const c = tokens(theme);
    const [sel, setSel] = React.useState('B58FCC78');
    const [cat, setCat] = React.useState('devices');
    const [active, setActive] = React.useState(RD_REPLICANT);
    const d = RD_DEVICES.find((x) => x.code === sel) || RD_DEVICES[0];
    const deployed = RD_DEVICES.filter((x) => x.status !== 'stowed' && x.status !== 'inactive').length;
    // merge switched replicant's headline fields onto the base for header display
    const activeRep = { ...RD_REPLICANT, ...active };

    return (
      <Ctx.Provider value={c}>
        <div style={{ width: 1280, height: 800, borderRadius: 13, overflow: 'hidden', position: 'relative', fontFamily: F, background: c.win, boxShadow: c.shadow, display: 'flex', color: c.t1 }}>
          {/* ── sidebar ── */}
          <div style={{ width: 256, flexShrink: 0, background: c.sidebar, backdropFilter: 'blur(30px)', borderRight: `1px solid ${c.line}`, display: 'flex', flexDirection: 'column' }}>
            <div style={{ height: 44, display: 'flex', alignItems: 'center', padding: '0 18px', flexShrink: 0 }}><Traffic /></div>
            <ReplicantHeader active={activeRep} onSwitch={(r) => setActive(r)} onViewInList={() => setCat('replicants')} />
            <div style={{ padding: '0 16px', flex: 1, overflow: 'auto' }}>
              <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: c.t3, padding: '4px 10px 8px' }}>Catalog</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                <NavItem kind="stars" label="Stars" count={48} selected={cat === 'stars'} onClick={() => setCat('stars')} />
                <NavItem kind="devices" label="Devices" count={activeRep.devices} selected={cat === 'devices'} onClick={() => setCat('devices')} />
                <NavItem kind="replicants" label="Replicants" count={RD_REPLICANTS.length} selected={cat === 'replicants'} onClick={() => setCat('replicants')} />
                <NavItem kind="blueprints" label="Blueprints" count={activeRep.blueprints} selected={cat === 'blueprints'} onClick={() => setCat('blueprints')} />
              </div>
              <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: c.t3, padding: '16px 10px 8px' }}>Operations</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                <NavItem kind="queue" label="Print Queue" count={3} selected={cat === 'queue'} onClick={() => setCat('queue')} />
                <NavItem kind="signals" label="Signals" soon />
              </div>
            </div>
            <AccountFooter />
          </div>

          {/* ── list ── */}
          <div style={{ width: 352, flexShrink: 0, borderRight: `1px solid ${c.line}`, display: 'flex', flexDirection: 'column', background: c.theme === 'light' ? 'rgba(0,0,0,0.012)' : 'rgba(255,255,255,0.012)' }}>
            <div style={{ padding: '16px 16px 12px', borderBottom: `1px solid ${c.line}` }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 12 }}>
                <span style={{ fontSize: 19, fontWeight: 700, color: c.t1, letterSpacing: -0.2 }}>Devices</span>
                <span style={{ fontFamily: M, fontSize: 12, color: c.t3 }}>{RD_DEVICES.length}</span>
                <span style={{ marginLeft: 'auto', fontSize: 11, color: c.t2, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: rdStatusOf({ status: 'idle' }, c.theme).color }} />{deployed} deployed</span>
              </div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <div style={{ flex: 1, height: 30, borderRadius: 8, background: c.panel, boxShadow: `inset 0 0 0 0.5px ${c.line}`, display: 'flex', alignItems: 'center', gap: 7, padding: '0 10px' }}>
                  <svg width="13" height="13" viewBox="0 0 13 13" fill="none"><circle cx="5.5" cy="5.5" r="4" stroke={c.t3} strokeWidth="1.4" /><path d="M8.5 8.5l3 3" stroke={c.t3} strokeWidth="1.4" strokeLinecap="round" /></svg>
                  <span style={{ fontSize: 12.5, color: c.t3 }}>Filter devices</span>
                </div>
                <div style={{ display: 'flex', background: c.panel, borderRadius: 8, boxShadow: `inset 0 0 0 0.5px ${c.line}`, padding: 2 }}>
                  {['All', 'Active'].map((x, i) => <span key={x} style={{ fontSize: 11.5, fontWeight: 600, padding: '5px 10px', borderRadius: 6, color: i === 0 ? c.t1 : c.t3, background: i === 0 ? c.panel2 : 'transparent' }}>{x}</span>)}
                </div>
              </div>
            </div>
            <div style={{ flex: 1, overflow: 'auto' }}>
              {RD_DEVICES.map((dev) => <DeviceRow key={dev.code} d={dev} selected={dev.code === sel} onClick={() => setSel(dev.code)} />)}
            </div>
          </div>

          {/* ── inspector ── */}
          <div style={{ flex: 1, minWidth: 0, position: 'relative', background: c.content }}>
            <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none', backgroundImage: c.nebula }} />
            <div style={{ position: 'relative', height: '100%' }}><Inspector d={d} /></div>
          </div>
        </div>
      </Ctx.Provider>
    );
  }

  window.DirectionA = DirectionA;
})();
