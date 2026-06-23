// Sidebars.jsx — 3 interactive dark-mode sidebar explorations for the
// Replicant dashboard. Host-aware replicant icon, travel/idle status (no
// levels), editable Plan, NPC declaration, Messages/Bobnet/Event Log, and a
// low-footprint account chip. Exports window.SidebarA/B/C.

(function () {
  const F = window.RD_FONT, M = window.RD_MONO;
  const { rdStatusOf, DeviceGlyph, RD_REPLICANTS, RD_ACCOUNT, RD_HOSTS } = window;

  const D = {
    win: '#0b1019', panel: 'rgba(255,255,255,0.04)', panel2: 'rgba(255,255,255,0.065)',
    line: 'rgba(255,255,255,0.09)', lineSoft: 'rgba(255,255,255,0.055)',
    t1: '#e9eef7', t2: '#9aa6bc', t3: '#697488',
    accent: '#ffb23e', accentText: '#2a1a05', accentBtn: 'linear-gradient(180deg,#ffc05c,#ff9e2c)',
    selBg: 'rgba(255,178,62,0.12)', selRing: 'rgba(255,178,62,0.34)',
    motion: '#5aa9ff', ready: '#62d39a',
  };

  // ── shared atoms ───────────────────────────────────────────────
  function Traffic() {
    const dot = (c) => <span style={{ width: 12, height: 12, borderRadius: '50%', background: c, display: 'block', boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.25)' }} />;
    return <div style={{ display: 'flex', gap: 8 }}>{dot('#ff5f57')}{dot('#febc2e')}{dot('#28c840')}</div>;
  }

  function HostGlyph({ type, size = 20, color }) {
    return <DeviceGlyph kind={RD_HOSTS[type].glyph} size={size} color={color} />;
  }

  function NavIcon({ kind, color }) {
    const s = { fill: 'none', stroke: color, strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' };
    const P = {
      stars: <g {...s}><circle cx="9" cy="9" r="2.4" /><line x1="9" y1="1.5" x2="9" y2="4" /><line x1="9" y1="14" x2="9" y2="16.5" /><line x1="1.5" y1="9" x2="4" y2="9" /><line x1="14" y1="9" x2="16.5" y2="9" /></g>,
      devices: <g {...s}><path d="M9 2 L14.5 5.2 L14.5 12.8 L9 16 L3.5 12.8 L3.5 5.2 Z" /><circle cx="9" cy="9" r="1.8" fill={color} stroke="none" /></g>,
      replicants: <g {...s}><circle cx="9" cy="9" r="7" /><circle cx="9" cy="9" r="1.8" fill={color} stroke="none" /><circle cx="15.4" cy="9" r="1.3" fill={color} stroke="none" /></g>,
      blueprints: <g {...s}><rect x="3" y="2.5" width="12" height="13" rx="1.5" /><line x1="6" y1="6" x2="12" y2="6" /><line x1="6" y1="9" x2="12" y2="9" /><line x1="6" y1="12" x2="9.5" y2="12" /></g>,
      queue: <g {...s}><line x1="4" y1="5" x2="14" y2="5" /><line x1="4" y1="9" x2="14" y2="9" /><line x1="4" y1="13" x2="10" y2="13" /></g>,
      signals: <g {...s}><circle cx="9" cy="11" r="1.6" fill={color} stroke="none" /><path d="M5.5 11a3.5 3.5 0 0 1 7 0" /><path d="M3 11a6 6 0 0 1 12 0" opacity="0.55" /></g>,
      messages: <g {...s}><rect x="2.5" y="4" width="13" height="10" rx="1.8" /><path d="M3 5l6 4.2L15 5" /></g>,
      bobnet: <g {...s}><path d="M3 4.5h12a1.5 1.5 0 0 1 1.5 1.5v5a1.5 1.5 0 0 1-1.5 1.5H7l-3 2.5V13H3a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 3 4.5Z" /><circle cx="6.5" cy="8.7" r="0.9" fill={color} stroke="none" /><circle cx="9" cy="8.7" r="0.9" fill={color} stroke="none" /><circle cx="11.5" cy="8.7" r="0.9" fill={color} stroke="none" /></g>,
      log: <g {...s}><line x1="5" y1="3" x2="5" y2="15" /><circle cx="5" cy="5" r="1.7" fill={color} stroke="none" /><circle cx="5" cy="9" r="1.7" fill={color} stroke="none" /><circle cx="5" cy="13" r="1.7" fill={color} stroke="none" /><line x1="9.5" y1="5" x2="14.5" y2="5" /><line x1="9.5" y1="9" x2="14.5" y2="9" /><line x1="9.5" y1="13" x2="13" y2="13" /></g>,
    };
    return <svg width="18" height="18" viewBox="0 0 18 18">{P[kind]}</svg>;
  }

  // key/identity glyph — low-footprint "this is your account" marker
  function AcctMark({ color, size = 16 }) {
    return <svg width={size} height={size} viewBox="0 0 16 16" fill="none" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><circle cx="5.5" cy="5.5" r="3" /><path d="M7.6 7.6L13 13M11 11l1.4-1.4M12.4 12.4l1-1" /></svg>;
  }

  const NAV = [
    { section: 'Catalog', items: [
      { k: 'stars', label: 'Stars', icon: 'stars', count: 48 },
      { k: 'devices', label: 'Devices', icon: 'devices', count: 10 },
      { k: 'replicants', label: 'Replicants', icon: 'replicants', count: 5 },
      { k: 'blueprints', label: 'Blueprints', icon: 'blueprints', count: 23 },
    ] },
    { section: 'Operations', items: [
      { k: 'queue', label: 'Print Queue', icon: 'queue', count: 3 },
      { k: 'signals', label: 'Signals', icon: 'signals', soon: true },
    ] },
    { section: 'Comms', items: [
      { k: 'messages', label: 'Messages', icon: 'messages', badge: 3 },
      { k: 'bobnet', label: 'Bobnet', icon: 'bobnet', live: true },
      { k: 'log', label: 'Event Log', icon: 'log' },
    ] },
  ];

  // ── shared state ───────────────────────────────────────────────
  function useSidebar() {
    const [idx, setIdx] = React.useState(0);
    const [navSel, setNavSel] = React.useState('devices');
    const [open, setOpen] = React.useState(false);
    const [plans, setPlans] = React.useState(() => Object.fromEntries(RD_REPLICANTS.map((r) => [r.id, r.plan])));
    const [npc, setNpc] = React.useState(() => Object.fromEntries(RD_REPLICANTS.map((r) => [r.id, r.npc])));
    const wrapRef = React.useRef(null);
    React.useEffect(() => {
      if (!open) return undefined;
      const h = (e) => { if (wrapRef.current && !wrapRef.current.contains(e.target)) setOpen(false); };
      document.addEventListener('pointerdown', h, true);
      return () => document.removeEventListener('pointerdown', h, true);
    }, [open]);
    const r = RD_REPLICANTS[idx];
    const active = { ...r, plan: plans[r.id], npc: npc[r.id] };
    return {
      idx, setIdx, navSel, setNavSel, open, setOpen, active, wrapRef,
      setPlan: (v) => setPlans((p) => ({ ...p, [r.id]: v })),
      toggleNpc: (val) => setNpc((n) => ({ ...n, [r.id]: val })),
    };
  }

  // ── switcher dropdown ──────────────────────────────────────────
  function SwitcherMenu({ activeId, onPick, onClose }) {
    return (
      <div onMouseDown={(e) => e.stopPropagation()} style={{ position: 'absolute', left: 0, right: 0, top: '100%', marginTop: 6, zIndex: 50, background: '#141b29', borderRadius: 12, boxShadow: `0 18px 44px rgba(0,0,0,0.55), inset 0 0 0 0.5px ${D.line}`, padding: 5, maxHeight: 322, overflow: 'auto' }}>
        {RD_REPLICANTS.map((r) => {
          const on = r.id === activeId;
          const st = rdStatusOf(r, 'dark');
          return (
            <button key={r.id} onClick={() => { onPick(RD_REPLICANTS.indexOf(r)); onClose(); }} style={{
              display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer',
              padding: '9px 10px', borderRadius: 8, border: 'none', background: on ? D.selBg : 'transparent', fontFamily: F,
            }}>
              <span style={{ width: 30, height: 30, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: D.panel2, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
                <HostGlyph type={r.host.type} size={18} color={on ? D.accent : D.t2} />
              </span>
              <span style={{ flex: 1, minWidth: 0 }}>
                <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                  <span style={{ fontSize: 13, fontWeight: 600, color: D.t1 }}>{r.name}</span>
                  {r.npc && <NpcIcon size={12} />}
                </span>
                <span style={{ display: 'block', fontSize: 10.5, color: D.t3, marginTop: 1 }}>{RD_HOSTS[r.host.type].label} · {r.host.name}</span>
              </span>
              <span style={{ textAlign: 'right', flexShrink: 0 }}>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}><span style={{ width: 5, height: 5, borderRadius: '50%', background: st.color }} /><span style={{ fontSize: 10.5, color: D.t2 }}>{r.status === 'traveling' ? 'Transit' : 'Idle'}</span></span>
                <span style={{ display: 'block', fontFamily: M, fontSize: 9.5, color: D.t3, marginTop: 2 }}>{r.devices} dev</span>
              </span>
            </button>
          );
        })}
        <div style={{ borderTop: `1px solid ${D.lineSoft}`, margin: '5px 4px 3px', paddingTop: 4 }}>
          <button style={{ display: 'flex', alignItems: 'center', gap: 7, width: '100%', padding: '8px 10px', borderRadius: 8, border: 'none', background: 'transparent', cursor: 'pointer', color: D.t2, fontFamily: F, fontSize: 12, fontWeight: 500 }}>
            <span style={{ fontSize: 14, lineHeight: 1 }}>+</span> Commission new replicant
          </button>
        </div>
      </div>
    );
  }

  function NpcTag({ small }) {
    return <span style={{ fontFamily: M, fontSize: small ? 8.5 : 9, fontWeight: 700, letterSpacing: 0.5, color: '#b58bff', padding: small ? '1px 4px' : '2px 5px', borderRadius: 4, background: 'rgba(181,139,255,0.14)', boxShadow: 'inset 0 0 0 0.5px rgba(181,139,255,0.4)' }}>NPC</span>;
  }

  // NPC = autonomous; shown as a small chip glyph (read-only here, edited elsewhere)
  function NpcIcon({ size = 12, color = '#b58bff' }) {
    return (
      <svg width={size} height={size} viewBox="0 0 14 14" fill="none" stroke={color} strokeWidth="1.2" strokeLinecap="round" style={{ display: 'block' }}>
        <title>NPC · autonomous</title>
        <rect x="3.6" y="3.6" width="6.8" height="6.8" rx="1.5" />
        <circle cx="7" cy="7" r="1.1" fill={color} stroke="none" />
        <line x1="5.4" y1="1.9" x2="5.4" y2="3.6" /><line x1="8.6" y1="1.9" x2="8.6" y2="3.6" />
        <line x1="5.4" y1="10.4" x2="5.4" y2="12.1" /><line x1="8.6" y1="10.4" x2="8.6" y2="12.1" />
        <line x1="1.9" y1="5.4" x2="3.6" y2="5.4" /><line x1="1.9" y1="8.6" x2="3.6" y2="8.6" />
        <line x1="10.4" y1="5.4" x2="12.1" y2="5.4" /><line x1="10.4" y1="8.6" x2="12.1" y2="8.6" />
      </svg>
    );
  }

  // ── travel / idle status ───────────────────────────────────────
  function TravelStatus({ active, variant }) {
    const st = rdStatusOf(active, 'dark');
    const traveling = active.status === 'traveling' && active.travel;
    if (variant === 'hero') {
      return (
        <div style={{ borderRadius: 12, padding: '12px 14px', background: traveling ? 'rgba(90,169,255,0.08)' : D.panel, boxShadow: `inset 0 0 0 0.5px ${traveling ? 'rgba(90,169,255,0.3)' : D.line}` }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: traveling ? 9 : 0 }}>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 7 }}>
              <span style={{ width: 7, height: 7, borderRadius: '50%', background: st.color, boxShadow: `0 0 8px ${st.color}` }} />
              <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: st.color }}>{traveling ? 'En route' : 'Idle'}</span>
            </span>
            {traveling
              ? <span style={{ fontFamily: M, fontSize: 12, fontWeight: 700, color: D.t1 }}>{active.travel.remaining}<span style={{ color: D.t3, fontWeight: 500 }}> left</span></span>
              : <span style={{ fontFamily: M, fontSize: 11, color: D.t3 }}>{active.location}</span>}
          </div>
          {traveling && <>
            <div style={{ height: 7, borderRadius: 5, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}><div style={{ width: `${Math.round(active.travel.progress * 100)}%`, height: '100%', background: `linear-gradient(90deg, ${st.color}aa, ${st.color})`, borderRadius: 5, boxShadow: `0 0 10px ${st.color}` }} /></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6 }}><span style={{ fontFamily: M, fontSize: 10.5, color: D.t2 }}>{active.travel.mode} → {active.travel.to}</span><span style={{ fontFamily: M, fontSize: 10.5, color: D.t3 }}>{Math.round(active.travel.progress * 100)}%</span></div>
          </>}
        </div>
      );
    }
    // compact (B) inline bar
    if (variant === 'compact') {
      return traveling ? (
        <div style={{ marginTop: 8 }}>
          <div style={{ height: 4, borderRadius: 3, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}><div style={{ width: `${Math.round(active.travel.progress * 100)}%`, height: '100%', background: st.color, borderRadius: 3 }} /></div>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 4 }}>
            <span style={{ fontSize: 10.5, color: D.t2, display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 5, height: 5, borderRadius: '50%', background: st.color }} />→ {active.travel.to}</span>
            <span style={{ fontFamily: M, fontSize: 10.5, color: D.t3 }}>{active.travel.remaining}</span>
          </div>
        </div>
      ) : (
        <div style={{ marginTop: 7, display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{ width: 5, height: 5, borderRadius: '50%', background: st.color }} />
          <span style={{ fontSize: 10.5, color: D.t2 }}>Idle</span>
          <span style={{ fontFamily: M, fontSize: 10.5, color: D.t3, marginLeft: 'auto' }}>{active.location}</span>
        </div>
      );
    }
    // card (A)
    return (
      <div style={{ borderRadius: 10, padding: '9px 11px', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginBottom: traveling ? 8 : 0 }}>
          <span style={{ width: 6, height: 6, borderRadius: '50%', background: st.color, boxShadow: `0 0 6px ${st.color}` }} />
          <span style={{ fontSize: 11.5, fontWeight: 600, color: D.t1 }}>{traveling ? `${active.travel.mode} → ${active.travel.to}` : 'Idle'}</span>
          <span style={{ marginLeft: 'auto', fontFamily: M, fontSize: 11, color: D.t3 }}>{traveling ? active.travel.remaining : active.location}</span>
        </div>
        {traveling && <div style={{ height: 5, borderRadius: 3, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}><div style={{ width: `${Math.round(active.travel.progress * 100)}%`, height: '100%', background: st.color, borderRadius: 3, boxShadow: `0 0 8px ${st.color}88` }} /></div>}
      </div>
    );
  }

  // ── editable plan ──────────────────────────────────────────────
  function PlanField({ value, onChange, variant }) {
    const ref = React.useRef(null);
    const [editing, setEditing] = React.useState(false);
    const start = () => { setEditing(true); setTimeout(() => { const el = ref.current; if (el) { el.focus(); const r = document.createRange(); r.selectNodeContents(el); r.collapse(false); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); } }, 0); };
    const commit = () => { setEditing(false); onChange(ref.current.textContent.trim() || value); };
    const Pencil = () => <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={editing ? D.accent : D.t3} strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round"><path d="M8 1.5l2.5 2.5M2 8l6-6 2.5 2.5-6 6H2V8z" /></svg>;

    if (variant === 'hero') {
      return (
        <div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
            <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3 }}>Plan</span>
            <button onClick={editing ? commit : start} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, border: 'none', background: 'transparent', cursor: 'pointer', color: editing ? D.accent : D.t3, fontFamily: F, fontSize: 10.5, fontWeight: 600 }}>{editing ? 'Done' : 'Edit'} <Pencil /></button>
          </div>
          <div ref={ref} contentEditable={editing} suppressContentEditableWarning onBlur={commit}
            style={{ fontSize: 12.5, lineHeight: 1.45, color: D.t1, outline: 'none', borderRadius: 9, padding: '10px 12px', background: editing ? 'rgba(255,255,255,0.06)' : D.panel, boxShadow: `inset 0 0 0 0.5px ${editing ? D.selRing : D.line}`, cursor: editing ? 'text' : 'default' }}>{value}</div>
        </div>
      );
    }
    if (variant === 'compact') {
      return (
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 6, marginTop: 9 }}>
          <span ref={ref} contentEditable={editing} suppressContentEditableWarning onBlur={commit}
            style={{ flex: 1, fontSize: 11.5, lineHeight: 1.4, color: editing ? D.t1 : D.t2, outline: 'none', borderRadius: 6, padding: editing ? '4px 6px' : '0', background: editing ? 'rgba(255,255,255,0.06)' : 'transparent', boxShadow: editing ? `inset 0 0 0 0.5px ${D.selRing}` : 'none' }}>{value}</span>
          <button onClick={editing ? commit : start} title="Edit plan" style={{ flexShrink: 0, width: 20, height: 20, display: 'flex', alignItems: 'center', justifyContent: 'center', border: 'none', background: 'transparent', cursor: 'pointer', marginTop: -1 }}><Pencil /></button>
        </div>
      );
    }
    // card (A)
    return (
      <div style={{ borderRadius: 10, padding: '9px 11px', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 5 }}>
          <span style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase', color: D.t3 }}>Plan</span>
          <button onClick={editing ? commit : start} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, border: 'none', background: 'transparent', cursor: 'pointer', color: editing ? D.accent : D.t3, fontFamily: F, fontSize: 10, fontWeight: 600 }}>{editing ? 'Done' : 'Edit'} <Pencil /></button>
        </div>
        <div ref={ref} contentEditable={editing} suppressContentEditableWarning onBlur={commit}
          style={{ fontSize: 12, lineHeight: 1.45, color: D.t1, outline: 'none', borderRadius: 6, padding: editing ? '4px 6px' : 0, margin: editing ? '0 -6px' : 0, background: editing ? 'rgba(255,255,255,0.06)' : 'transparent', boxShadow: editing ? `inset 0 0 0 0.5px ${D.selRing}` : 'none', cursor: editing ? 'text' : 'default' }}>{value}</div>
      </div>
    );
  }

  // ── NPC control ────────────────────────────────────────────────
  function NpcControl({ npc, onToggle, variant }) {
    const seg = (label, on, val) => (
      <button onClick={() => onToggle(val)} style={{ flex: 1, padding: variant === 'hero' ? '6px 0' : '4px 0', borderRadius: 6, border: 'none', cursor: 'pointer', fontFamily: F, fontSize: 11, fontWeight: 600, background: on ? (val ? 'rgba(181,139,255,0.16)' : D.panel2) : 'transparent', color: on ? (val ? '#c4a4ff' : D.t1) : D.t3, boxShadow: on ? `inset 0 0 0 0.5px ${val ? 'rgba(181,139,255,0.4)' : D.line}` : 'none' }}>{label}</button>
    );
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 10.5, color: D.t3, fontWeight: 500 }}>Control</span>
        <div style={{ flex: 1, display: 'flex', gap: 3, padding: 3, borderRadius: 8, background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
          {seg('You', !npc, false)}{seg('NPC', npc, true)}
        </div>
      </div>
    );
  }

  // ── nav ────────────────────────────────────────────────────────
  function Badge({ item, selected }) {
    if (item.soon) return <span style={{ fontSize: 9, fontWeight: 700, letterSpacing: 0.4, color: D.t3, textTransform: 'uppercase' }}>soon</span>;
    if (item.live) return <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}><span style={{ width: 6, height: 6, borderRadius: '50%', background: D.ready, boxShadow: `0 0 7px ${D.ready}` }} /><span style={{ fontSize: 10, color: D.ready, fontWeight: 600 }}>live</span></span>;
    if (item.badge) return <span style={{ fontFamily: M, fontSize: 10.5, fontWeight: 700, color: D.accentText, background: D.accentBtn, padding: '1px 7px', borderRadius: 9, minWidth: 18, textAlign: 'center', boxShadow: '0 2px 8px rgba(255,158,44,0.3)' }}>{item.badge}</span>;
    if (item.count != null) return <span style={{ fontFamily: M, fontSize: 11, color: selected ? D.accent : D.t3, fontWeight: 600 }}>{item.count}</span>;
    return null;
  }

  function NavRow({ item, selected, onClick, dense }) {
    const col = selected ? D.accent : D.t2;
    return (
      <button onClick={onClick} style={{
        display: 'flex', alignItems: 'center', gap: dense ? 9 : 10, width: '100%', textAlign: 'left',
        height: dense ? 30 : 34, padding: dense ? '0 9px' : '0 10px', borderRadius: 8, border: 'none', cursor: 'pointer',
        background: selected ? D.selBg : 'transparent', position: 'relative', fontFamily: F,
        color: selected ? D.t1 : D.t2, boxShadow: selected ? `inset 0 0 0 0.5px ${D.selRing}` : 'none',
      }}>
        {selected && <span style={{ position: 'absolute', left: -8, top: 8, bottom: 8, width: 3, borderRadius: 3, background: D.accent, boxShadow: `0 0 8px ${D.accent}` }} />}
        <NavIcon kind={item.icon} color={col} />
        <span style={{ fontSize: dense ? 12.5 : 13, fontWeight: selected ? 600 : 500, flex: 1 }}>{item.label}</span>
        <Badge item={item} selected={selected} />
      </button>
    );
  }

  function SectionHead({ children }) {
    return <div style={{ fontSize: 10, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3, padding: '14px 10px 7px' }}>{children}</div>;
  }

  function Nav({ sel, onSel, dense }) {
    return (
      <div style={{ padding: '2px 16px 8px' }}>
        {NAV.map((grp) => (
          <div key={grp.section}>
            <SectionHead>{grp.section}</SectionHead>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              {grp.items.map((it) => <NavRow key={it.k} item={it} selected={sel === it.k} onClick={() => onSel(it.k)} dense={dense} />)}
            </div>
          </div>
        ))}
      </div>
    );
  }

  // ── shell ──────────────────────────────────────────────────────
  function Shell({ children, footer, height = 760 }) {
    return (
      <div style={{ width: 268, height, borderRadius: 14, overflow: 'hidden', position: 'relative', fontFamily: F, color: D.t1, background: D.win, boxShadow: `0 0 0 0.5px ${D.line}, 0 30px 80px rgba(0,0,0,0.5)`, borderRight: `1px solid ${D.line}`, display: 'flex', flexDirection: 'column' }}>
        {children}
        {footer}
      </div>
    );
  }

  // ── Account chips (low-footprint identity affordance) ──────────
  function AccountA() {
    const a = RD_ACCOUNT;
    return (
      <button style={{ display: 'block', width: '100%', textAlign: 'left', cursor: 'pointer', padding: '11px 14px', border: 'none', borderTop: `1px solid ${D.line}`, background: 'transparent', fontFamily: F, flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 5 }}>
          <AcctMark color={D.t3} size={12} />
          <span style={{ fontSize: 9, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3 }}>Your account</span>
          <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke={D.t3} strokeWidth="1.5" strokeLinecap="round" style={{ marginLeft: 'auto' }}><path d="M3 9.5l4-4-4-4" /></svg>
        </div>
        <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between' }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: D.t1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name}</div>
            <div style={{ fontSize: 10.5, color: D.t3 }}>{a.email}</div>
          </div>
          <div style={{ display: 'flex', gap: 12, flexShrink: 0 }}>
            <span style={{ textAlign: 'right' }}><span style={{ display: 'block', fontFamily: M, fontSize: 12, fontWeight: 700, color: D.accent }}>{(a.xp / 1000).toFixed(1)}k</span><span style={{ display: 'block', fontSize: 8.5, letterSpacing: 0.4, color: D.t3, textTransform: 'uppercase' }}>XP</span></span>
            <span style={{ textAlign: 'right' }}><span style={{ display: 'block', fontFamily: M, fontSize: 12, fontWeight: 700, color: D.t1 }}>{a.replicants}</span><span style={{ display: 'block', fontSize: 8.5, letterSpacing: 0.4, color: D.t3, textTransform: 'uppercase' }}>Repl</span></span>
          </div>
        </div>
      </button>
    );
  }

  function AccountBC() {
    const a = RD_ACCOUNT;
    return (
      <button style={{ display: 'flex', alignItems: 'center', gap: 10, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '11px 16px', border: 'none', borderTop: `1px solid ${D.line}`, background: 'transparent', fontFamily: F, flexShrink: 0 }}>
        <span style={{ width: 26, height: 26, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: D.panel2, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><AcctMark color={D.t2} size={14} /></span>
        <span style={{ flex: 1, minWidth: 0 }}>
          <span style={{ display: 'block', fontSize: 12.5, fontWeight: 600, color: D.t1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name}</span>
          <span style={{ display: 'block', fontFamily: M, fontSize: 10, color: D.t3 }}>{(a.xp / 1000).toFixed(1)}k XP · {a.replicants} replicants</span>
        </span>
        <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke={D.t3} strokeWidth="1.5" strokeLinecap="round"><path d="M3 9.5l4-4-4-4" /></svg>
      </button>
    );
  }

  // ═══ Variation A — "Briefing" (panel-based, refined) ═══════════
  function SidebarA() {
    const s = useSidebar();
    const a = s.active;
    return (
      <Shell footer={<AccountA />}>
        <div style={{ height: 40, display: 'flex', alignItems: 'center', padding: '0 18px', flexShrink: 0 }}><Traffic /></div>
        <div style={{ padding: '2px 16px 12px', position: 'relative', flexShrink: 0 }} ref={s.wrapRef}>
          <div style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3, margin: '0 0 7px 2px' }}>Active Replicant</div>
          <button onClick={() => s.setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', gap: 11, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '9px 11px', borderRadius: 11, border: 'none', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
            <span style={{ width: 34, height: 34, borderRadius: 9, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: D.selBg, boxShadow: `inset 0 0 0 0.5px ${D.selRing}` }}><HostGlyph type={a.host.type} size={20} color={D.accent} /></span>
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><span style={{ fontSize: 15.5, fontWeight: 700, color: D.t1, letterSpacing: -0.2 }}>{a.name}</span>{a.npc && <NpcTag />}</span>
              <span style={{ display: 'block', fontSize: 10.5, color: D.t3, marginTop: 1 }}>{RD_HOSTS[a.host.type].label} · {a.host.name}</span>
            </span>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={D.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: s.open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}><path d="M2 4.5l4 4 4-4" /></svg>
          </button>
          {s.open && <SwitcherMenu activeId={a.id} onPick={s.setIdx} onClose={() => s.setOpen(false)} />}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 9 }}>
            <TravelStatus active={a} variant="card" />
            <div style={{ display: 'flex', gap: 8 }}>
              <span style={{ flex: 1, display: 'flex', alignItems: 'baseline', gap: 5, padding: '7px 11px', borderRadius: 9, background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><span style={{ fontFamily: M, fontSize: 13, fontWeight: 700, color: D.t1 }}>{a.xp.toLocaleString()}</span><span style={{ fontSize: 9.5, color: D.t3, fontWeight: 600 }}>XP</span></span>
              <span style={{ flex: 1, display: 'flex', alignItems: 'baseline', gap: 5, padding: '7px 11px', borderRadius: 9, background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><span style={{ fontFamily: M, fontSize: 13, fontWeight: 700, color: D.t1 }}>{a.devices}</span><span style={{ fontSize: 9.5, color: D.t3, fontWeight: 600 }}>Devices</span></span>
            </div>
            <PlanField value={a.plan} onChange={s.setPlan} variant="card" />
            <NpcControl npc={a.npc} onToggle={s.toggleNpc} variant="card" />
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'auto', borderTop: `1px solid ${D.lineSoft}` }}><Nav sel={s.navSel} onSel={s.setNavSel} /></div>
      </Shell>
    );
  }

  // ═══ Variation B — "Source list" (compact, native) ════════════
  function SidebarB() {
    const s = useSidebar();
    const a = s.active;
    return (
      <Shell footer={<AccountBC />}>
        <div style={{ height: 38, display: 'flex', alignItems: 'center', padding: '0 16px', flexShrink: 0 }}><Traffic /></div>
        <div style={{ padding: '2px 14px 12px', position: 'relative', flexShrink: 0 }} ref={s.wrapRef}>
          <button onClick={() => s.setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', gap: 9, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '7px 8px', borderRadius: 9, border: 'none', background: 'transparent' }}>
            <span style={{ width: 28, height: 28, borderRadius: 8, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: D.panel2, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><HostGlyph type={a.host.type} size={17} color={D.accent} /></span>
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><span style={{ fontSize: 14, fontWeight: 700, color: D.t1 }}>{a.name}</span>{a.npc && <NpcTag small />}</span>
              <span style={{ display: 'block', fontSize: 10, color: D.t3, fontFamily: M, marginTop: 1 }}>{a.host.name}</span>
            </span>
            <svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke={D.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: s.open ? 'rotate(180deg)' : 'none' }}><path d="M2 4.5l4 4 4-4" /></svg>
          </button>
          {s.open && <SwitcherMenu activeId={a.id} onPick={s.setIdx} onClose={() => s.setOpen(false)} />}
          <div style={{ padding: '0 2px' }}>
            <TravelStatus active={a} variant="compact" />
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 9, fontFamily: M, fontSize: 10.5, color: D.t3 }}>
              <span><span style={{ color: D.t1, fontWeight: 700 }}>{a.xp.toLocaleString()}</span> XP</span>
              <span style={{ width: 2.5, height: 2.5, borderRadius: '50%', background: D.t3 }} />
              <span><span style={{ color: D.t1, fontWeight: 700 }}>{a.devices}</span> devices</span>
              <button onClick={() => s.toggleNpc(!a.npc)} style={{ marginLeft: 'auto', border: 'none', cursor: 'pointer', background: a.npc ? 'rgba(181,139,255,0.14)' : D.panel2, color: a.npc ? '#c4a4ff' : D.t2, boxShadow: `inset 0 0 0 0.5px ${a.npc ? 'rgba(181,139,255,0.4)' : D.line}`, padding: '2px 7px', borderRadius: 5, fontFamily: F, fontSize: 9.5, fontWeight: 700, letterSpacing: 0.3 }}>{a.npc ? 'NPC' : 'Mark NPC'}</button>
            </div>
            <PlanField value={a.plan} onChange={s.setPlan} variant="compact" />
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'auto', borderTop: `1px solid ${D.lineSoft}` }}><Nav sel={s.navSel} onSel={s.setNavSel} dense /></div>
      </Shell>
    );
  }

  // ═══ Variation C — "Status hero" (travel-forward, visual) ══════
  function SidebarC() {
    const s = useSidebar();
    const a = s.active;
    return (
      <Shell footer={<AccountBC />}>
        <div style={{ height: 40, display: 'flex', alignItems: 'center', padding: '0 18px', flexShrink: 0 }}><Traffic /></div>
        <div style={{ padding: '4px 16px 14px', position: 'relative', flexShrink: 0 }} ref={s.wrapRef}>
          <button onClick={() => s.setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '4px 4px 10px', border: 'none', background: 'transparent' }}>
            <span style={{ width: 46, height: 46, borderRadius: 13, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'radial-gradient(circle at 38% 32%, rgba(255,178,62,0.22), rgba(255,178,62,0.05))', boxShadow: `inset 0 0 0 0.5px ${D.selRing}` }}><HostGlyph type={a.host.type} size={26} color={D.accent} /></span>
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ display: 'flex', alignItems: 'center', gap: 7 }}><span style={{ fontSize: 19, fontWeight: 700, color: D.t1, letterSpacing: -0.3 }}>{a.name}</span>{a.npc && <NpcTag />}</span>
              <span style={{ display: 'block', fontSize: 11, color: D.t2, marginTop: 2 }}>{RD_HOSTS[a.host.type].label} · {a.host.name}</span>
            </span>
            <svg width="13" height="13" viewBox="0 0 12 12" fill="none" stroke={D.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: s.open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}><path d="M2 4.5l4 4 4-4" /></svg>
          </button>
          {s.open && <SwitcherMenu activeId={a.id} onPick={s.setIdx} onClose={() => s.setOpen(false)} />}
          <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
            <TravelStatus active={a} variant="hero" />
            <div style={{ display: 'flex', gap: 9 }}>
              <div style={{ flex: 1, borderRadius: 11, padding: '9px 12px', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><div style={{ fontFamily: M, fontSize: 15, fontWeight: 700, color: D.t1 }}>{a.xp.toLocaleString()}</div><div style={{ fontSize: 9, letterSpacing: 0.6, textTransform: 'uppercase', color: D.t3, marginTop: 1 }}>Experience</div></div>
              <div style={{ flex: 1, borderRadius: 11, padding: '9px 12px', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}><div style={{ fontFamily: M, fontSize: 15, fontWeight: 700, color: D.t1 }}>{a.devices}</div><div style={{ fontSize: 9, letterSpacing: 0.6, textTransform: 'uppercase', color: D.t3, marginTop: 1 }}>Devices</div></div>
            </div>
            <PlanField value={a.plan} onChange={s.setPlan} variant="hero" />
            <NpcControl npc={a.npc} onToggle={s.toggleNpc} variant="hero" />
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'auto', borderTop: `1px solid ${D.lineSoft}` }}><Nav sel={s.navSel} onSel={s.setNavSel} /></div>
      </Shell>
    );
  }

  // ═══ Account chip — converged (key + "Logged in" from A, density &
  // affordance alignment from B/C, bold accent stat values) ══════
  function AccountV4() {
    const a = RD_ACCOUNT;
    const stat = (v, label) => (
      <div style={{ textAlign: 'right', lineHeight: 1.25 }}>
        <span style={{ fontFamily: M, fontSize: 12, fontWeight: 700, color: D.accent }}>{v}</span>
        <span style={{ fontSize: 10.5, color: D.t3, marginLeft: 4 }}>{label}</span>
      </div>
    );
    return (
      <button style={{ display: 'block', width: '100%', textAlign: 'left', cursor: 'pointer', padding: '10px 14px 11px', border: 'none', borderTop: `1px solid ${D.line}`, background: 'transparent', fontFamily: F, flexShrink: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 6 }}>
          <AcctMark color={D.t3} size={12} />
          <span style={{ fontSize: 9, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3 }}>Logged in</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 600, color: D.t1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.name}</div>
            <div style={{ fontSize: 10.5, color: D.t3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.email}</div>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2, flexShrink: 0 }}>
            {stat((a.xp / 1000).toFixed(1) + 'k', 'XP')}
            {stat(a.replicants, 'repl')}
          </div>
          <svg width="12" height="12" viewBox="0 0 11 11" fill="none" stroke={D.t3} strokeWidth="1.5" strokeLinecap="round" style={{ flexShrink: 0 }}><path d="M3 9.5l4-4-4-4" /></svg>
        </div>
      </button>
    );
  }

  // ═══ Converged sidebar (V4) ════════════════════════════════════
  function SidebarV4() {
    const s = useSidebar();
    const a = s.active;
    const host = RD_HOSTS[a.host.type];
    return (
      <Shell footer={<AccountV4 />}>
        <div style={{ height: 40, display: 'flex', alignItems: 'center', padding: '0 18px', flexShrink: 0 }}><Traffic /></div>
        <div style={{ padding: '2px 16px 12px', position: 'relative', flexShrink: 0 }} ref={s.wrapRef}>
          <div style={{ fontSize: 9.5, fontWeight: 700, letterSpacing: 1, textTransform: 'uppercase', color: D.t3, margin: '0 0 7px 2px' }}>Active Replicant</div>
          {/* bounded picker box (from A) */}
          <button onClick={() => s.setOpen((o) => !o)} style={{ display: 'flex', alignItems: 'center', gap: 11, width: '100%', textAlign: 'left', cursor: 'pointer', padding: '9px 11px', borderRadius: 11, border: 'none', background: D.panel, boxShadow: `inset 0 0 0 0.5px ${D.line}` }}>
            <span style={{ width: 34, height: 34, borderRadius: 9, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: D.selBg, boxShadow: `inset 0 0 0 0.5px ${D.selRing}` }}><HostGlyph type={a.host.type} size={20} color={D.accent} /></span>
            <span style={{ flex: 1, minWidth: 0 }}>
              <span style={{ fontSize: 15.5, fontWeight: 700, color: D.t1, letterSpacing: -0.2 }}>{a.name}</span>
              <span style={{ display: 'flex', alignItems: 'center', gap: 5, marginTop: 2 }}>
                <span style={{ fontSize: 11, color: D.t2 }}>{host.label}</span>
                {a.npc && <><span style={{ color: D.t3, fontSize: 11 }}>•</span><NpcIcon size={12} /></>}
              </span>
            </span>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke={D.t2} strokeWidth="1.6" strokeLinecap="round" style={{ transform: s.open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }}><path d="M2 4.5l4 4 4-4" /></svg>
          </button>
          {s.open && <SwitcherMenu activeId={a.id} onPick={s.setIdx} onClose={() => s.setOpen(false)} />}
          {/* density below (from B) */}
          <div style={{ padding: '0 2px' }}>
            <TravelStatus active={a} variant="compact" />
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 10 }}>
              <span style={{ fontFamily: M, fontSize: 10.5, color: D.t3, whiteSpace: 'nowrap' }}><span style={{ color: D.t1, fontWeight: 700 }}>{a.xp.toLocaleString()}</span> XP<span style={{ margin: '0 6px', opacity: 0.5 }}>·</span><span style={{ color: D.t1, fontWeight: 700 }}>{a.devices}</span> dev</span>
              <button style={{ marginLeft: 'auto', flexShrink: 0, display: 'inline-flex', alignItems: 'center', gap: 3, border: 'none', background: 'transparent', cursor: 'pointer', color: D.accent, fontFamily: F, fontSize: 10.5, fontWeight: 600, padding: 0, whiteSpace: 'nowrap' }}>Show in Replicants <span style={{ fontSize: 11 }}>↗</span></button>
            </div>
            <PlanField value={a.plan} onChange={s.setPlan} variant="compact" />
          </div>
        </div>
        <div style={{ flex: 1, overflow: 'auto', borderTop: `1px solid ${D.lineSoft}` }}><Nav sel={s.navSel} onSel={s.setNavSel} dense /></div>
      </Shell>
    );
  }

  // close switcher on outside click (applies to all variants)
  window.SidebarV4 = SidebarV4;
  window.SidebarA = SidebarA;
  window.SidebarB = SidebarB;
  window.SidebarC = SidebarC;
})();
