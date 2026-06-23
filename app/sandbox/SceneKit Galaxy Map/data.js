// data.js — shared universe model for the Replicant dashboard.
// A von Neumann probe ("replicant") named Sylphrena manages the devices she
// has printed and deployed across nearby belts. Exported to window for both
// design directions to consume.

const RD_FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Helvetica Neue", Helvetica, Arial, sans-serif';
const RD_MONO = 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Monaco, "Cascadia Code", monospace';

// ── Status tones ────────────────────────────────────────────────
// matched chroma, varied hue — each maps to a semantic activity class.
// c = color on dark bg, cl = darker variant for legibility on light bg.
const RD_TONES = {
  ready:  { c: '#62d39a', cl: '#1f9d63', label: 'ready'   },
  work:   { c: '#ffb23e', cl: '#c47a12', label: 'working' },
  motion: { c: '#5aa9ff', cl: '#2f6fd0', label: 'transit' },
  sense:  { c: '#3fd3cb', cl: '#0f978f', label: 'sensing' },
  relay:  { c: '#b58bff', cl: '#7b4fd6', label: 'relay'   },
  wait:   { c: '#d8b06a', cl: '#9a6f1e', label: 'waiting' },
  off:    { c: '#7e879b', cl: '#6b7488', label: 'offline' },
};

// status key -> { label, tone }. Some statuses carry a parameter (resource /
// device_type) supplied per-device.
const RD_STATUS = {
  stowed:                { label: 'Stowed',            tone: 'off'    },
  idle:                  { label: 'Idle',              tone: 'ready'  },
  travelling:            { label: 'Travelling',        tone: 'motion' },
  cruising:              { label: 'Cruising',          tone: 'motion' },
  surging:               { label: 'Surging',           tone: 'motion' },
  recalling:             { label: 'Recalling',         tone: 'motion' },
  recall_waiting:        { label: 'Recall · waiting',  tone: 'wait'   },
  decommissioning:       { label: 'Decommissioning',   tone: 'off'    },
  collecting:            { label: 'Collecting',        tone: 'work'   },
  depositing:            { label: 'Depositing',        tone: 'work'   },
  waiting_for_surge_plate:{ label: 'Awaiting surge',   tone: 'wait'   },
  mining:                { label: 'Mining',            tone: 'work'   },
  prospecting:           { label: 'Prospecting',       tone: 'sense'  },
  tracking:              { label: 'Tracking',          tone: 'sense'  },
  scanning:              { label: 'Scanning',          tone: 'sense'  },
  monitoring:            { label: 'Monitoring',        tone: 'sense'  },
  printing:              { label: 'Printing',          tone: 'work'   },
  waiting_for_resources: { label: 'Awaiting resources',tone: 'wait'   },
  repairing:             { label: 'Repairing',         tone: 'work'   },
  diverting:             { label: 'Diverting',         tone: 'work'   },
  patrolling:            { label: 'Patrolling',        tone: 'sense'  },
  coordinating:          { label: 'Coordinating',      tone: 'sense'  },
  relaying:              { label: 'Relaying',          tone: 'relay'  },
  inactive:              { label: 'Inactive',          tone: 'off'    },
};

// device_type -> { label, glyph kind, blurb }
const RD_TYPES = {
  mining_drone: { label: 'Mining Drone',  glyph: 'hex',        blurb: 'Extracts and ferries raw ore from belt bodies.' },
  survey_probe: { label: 'Survey Probe',  glyph: 'orbit',      blurb: 'Prospects uncharted bodies for viable resource sites.' },
  ftl_relay:    { label: 'FTL Relay',     glyph: 'concentric', blurb: 'Maintains the superluminal signal mesh between nodes.' },
  forge:        { label: 'Forge',         glyph: 'grid',       blurb: 'Prints new devices from a blueprint and raw stock.' },
  hauler:       { label: 'Hauler',        glyph: 'capsule',    blurb: 'Transports cargo and stowed devices between sites.' },
  scanner:      { label: 'Scanner Array', glyph: 'radar',      blurb: 'Runs deep scans and tracks resource signatures.' },
  repair_drone: { label: 'Repair Drone',  glyph: 'cross',      blurb: 'Patrols a system and restores damaged devices.' },
  surge_plate:  { label: 'Surge Plate',   glyph: 'diamond',    blurb: 'Anchors a surge corridor for rapid transit.' },
};

// ── The replicant herself ───────────────────────────────────────
const RD_REPLICANT = {
  name: 'Sylphrena',
  id: '30B93F2F',
  location: 'CHAMAKUY-BELT-1',
  plan: 'Seed the Chamakuy belt with self-sustaining infrastructure.',
  host: { type: 'vessel', name: 'Windrunner', code: 'C1D9F0A2' },
  status: 'traveling',
  travel: { to: 'TARAZEDAR-BELT-1', mode: 'Cruise', progress: 0.64, remaining: '2h 14m' },
  xp: 12840, devices: 10, blueprints: 23, npc: false, generation: 4,
};

// The human operator's logged-in account (distinct from the replicants).
const RD_ACCOUNT = {
  name: 'K. Pennig', email: 'kell@pennig.name', initials: 'KP', xp: 128400, replicants: 5, plan: 'Surveyor',
};

// Host kinds — a replicant always lives inside exactly one of these.
const RD_HOSTS = {
  vessel: { label: 'Vessel',     glyph: 'vessel', mobile: true,  note: 'Spacecraft · can travel' },
  matrix: { label: 'Matrix',     glyph: 'matrix', mobile: false, note: 'Container · cannot move on its own' },
  hub:    { label: 'System Hub', glyph: 'hub',    mobile: false, note: 'Claims a star system' },
};

// Replicants this account commands — the active-replicant switcher.
const RD_REPLICANTS = [
  { name: 'Sylphrena', id: '30B93F2F', host: { type: 'vessel', name: 'Windrunner' }, status: 'traveling', travel: { to: 'TARAZEDAR-BELT-1', mode: 'Cruise', remaining: '2h 14m', progress: 0.64 }, location: 'CHAMAKUY-BELT-1', xp: 12840, devices: 10, npc: true, plan: 'Seed the Chamakuy belt with self-sustaining infrastructure.' },
  { name: 'Pattern',   id: '9F22A1C7', host: { type: 'matrix', name: 'Lattice C-7' }, status: 'idle', location: 'TARAZEDAR-BELT-1', xp: 8420,  devices: 6,  npc: true,  plan: 'Hold and harden the Tarazedar lattice.' },
  { name: 'Ivory',     id: '5D0E88B3', host: { type: 'hub',    name: 'Velzan Claim' }, status: 'idle', location: 'VELZAN-REACH',     xp: 21030, devices: 14, npc: false, plan: 'Expand the Velzan claim; survey adjacent systems.' },
  { name: 'Wyndle',    id: 'B7740E15', host: { type: 'vessel', name: 'Cultivation' }, status: 'idle', location: 'SELAY-DRIFT',      xp: 4200,  devices: 3,  npc: false, plan: 'Cultivate resource sites along the Selay drift.' },
  { name: 'Glys',      id: 'A0C3F6D9', host: { type: 'matrix', name: 'Lattice D-2' }, status: 'idle', location: 'NARAK-VEIL',       xp: 1500,  devices: 2,  npc: false, plan: 'Maintain the Narak relay network.' },
];

// Known destinations (for Travel / Retarget / Recall dropdowns).
const RD_LOCATIONS = [
  'CHAMAKUY-BELT-1', 'CHAMAKUY-GATE', 'TARAZEDAR-BELT-1', 'TARAZEDAR-BELT-2',
  'VELZAN-REACH', 'SELAY-DRIFT', 'NARAK-VEIL',
];

// Mineable resources (for Start mining / Retarget).
const RD_RESOURCES = ['Iron', 'Rares', 'Conductive', 'Carbon', 'Ice', 'Silicates'];

// ── Devices Sylphrena has printed & deployed ────────────────────
// operational_capacity is a 0–100 readout; `task` carries live progress for
// working states.
const RD_DEVICES = [
  {
    code: 'B58FCC78', type: 'mining_drone', location: 'TARAZEDAR-BELT-1',
    status: 'mining', param: 'Iron', capacity: 67,
    features: ['cruise', 'mine', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','retarget','start_mining','stow','travel'],
    task: { label: 'Mining Iron', progress: 0.42, cargo: 0.58, rate: '2.4 kt/h', eta: '6h 12m', site: 'Vein 7C-Iron' },
    deployedFor: '14d 6h', uptime: 99.2, integrity: 96, signal: 88,
  },
  {
    code: 'A1F00C2D', type: 'survey_probe', location: 'CHAMAKUY-BELT-1',
    status: 'prospecting', capacity: 88, features: ['cruise', 'scan', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','retarget','prospect','travel'],
    task: { label: 'Prospecting', progress: 0.71 }, deployedFor: '3d 11h', integrity: 99, signal: 94,
  },
  {
    code: '7C0E9B41', type: 'ftl_relay', location: 'CHAMAKUY-GATE',
    status: 'relaying', capacity: 100, features: ['relay'],
    commands: ['change_owner','deactivate','decommission','deploy','recall'],
    deployedFor: '61d 2h', integrity: 100, signal: 100,
  },
  {
    code: '22D7E5A9', type: 'forge', location: 'CHAMAKUY-BELT-1',
    status: 'printing', param: 'Mining Drone', capacity: 54, features: ['print', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','print'],
    task: { label: 'Printing Mining Drone', progress: 0.33 }, deployedFor: '9d 0h', integrity: 91, signal: 90,
  },
  {
    code: '9E33B70F', type: 'hauler', location: 'TARAZEDAR-BELT-1',
    status: 'cruising', capacity: 73, features: ['cruise', 'carry', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','retarget','travel','stow'],
    task: { label: 'En route · Chamakuy-Gate', progress: 0.55 }, deployedFor: '2d 4h', integrity: 88, signal: 76,
  },
  {
    code: 'D4A2110B', type: 'mining_drone', location: 'TARAZEDAR-BELT-2',
    status: 'idle', capacity: 91, features: ['cruise', 'mine', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','retarget','start_mining','stow','travel'],
    deployedFor: '20d 8h', integrity: 97, signal: 82,
  },
  {
    code: '5B8FA6C0', type: 'scanner', location: 'VELZAN-REACH',
    status: 'scanning', capacity: 80, features: ['scan', 'track', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','scan','track','travel'],
    task: { label: 'Deep scan', progress: 0.19 }, deployedFor: '5d 17h', integrity: 94, signal: 70,
  },
  {
    code: '0F62CC18', type: 'repair_drone', location: 'CHAMAKUY-BELT-1',
    status: 'patrolling', capacity: 64, features: ['cruise', 'repair', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','recall','repair','patrol','travel'],
    task: { label: 'Patrolling', progress: 0.6 }, deployedFor: '7d 1h', integrity: 79, signal: 85,
  },
  {
    code: 'E70D4491', type: 'surge_plate', location: 'CHAMAKUY-GATE',
    status: 'inactive', capacity: 100, features: ['surge'],
    commands: ['change_owner','deactivate','decommission','deploy','recall'],
    deployedFor: '61d 2h', integrity: 100, signal: 99,
  },
  {
    code: '1A9C77E2', type: 'mining_drone', location: 'TARAZEDAR-BELT-1',
    status: 'stowed', capacity: 45, features: ['cruise', 'mine', 'stow'],
    commands: ['change_owner','deactivate','decommission','deploy','retarget','start_mining','travel'],
    stowedIn: 'Hauler · 9E33B70F', deployedFor: '—', integrity: 73, signal: 0,
  },
];

// Friendly label for a command key.
const RD_CMD = {
  deploy: 'Deploy', recall: 'Recall', retarget: 'Retarget', travel: 'Travel',
  stow: 'Stow', start_mining: 'Start mining', prospect: 'Prospect', scan: 'Scan',
  track: 'Track', repair: 'Repair', patrol: 'Patrol', print: 'Print',
  change_owner: 'Change owner', deactivate: 'Deactivate', decommission: 'Decommission',
};

// ── helpers ─────────────────────────────────────────────────────
function rdStatusOf(d, theme) {
  const m = RD_STATUS[d.status] || { label: d.status, tone: 'off' };
  const tone = RD_TONES[m.tone];
  const label = d.param ? `${m.label} · ${d.param}` : m.label;
  return { label, short: m.label, color: theme === 'light' ? tone.cl : tone.c, tone: m.tone };
}
function rdType(d) { return RD_TYPES[d.type] || { label: d.type, glyph: 'hex', blurb: '' }; }

// ── Device glyphs — built only from circles / rings / dots / lines /
// diamonds, kept deliberately schematic (data-viz, not illustration). ──
function DeviceGlyph({ kind = 'hex', size = 26, color = '#cfd8e8', stroke = 1.5, dim = false }) {
  const o = dim ? 0.55 : 1;
  const common = { fill: 'none', stroke: color, strokeWidth: stroke, strokeLinecap: 'round', strokeLinejoin: 'round' };
  let body;
  switch (kind) {
    case 'orbit':
      body = (<g {...common}><circle cx="12" cy="12" r="8.5" /><circle cx="12" cy="12" r="2" fill={color} stroke="none" /><circle cx="20.5" cy="12" r="1.6" fill={color} stroke="none" /></g>);
      break;
    case 'concentric':
      body = (<g {...common}><circle cx="12" cy="12" r="3" /><circle cx="12" cy="12" r="6.5" opacity="0.7" /><circle cx="12" cy="12" r="10" opacity="0.4" /></g>);
      break;
    case 'grid':
      body = (<g {...common}><rect x="4" y="4" width="16" height="16" rx="2.5" /><circle cx="9" cy="9" r="1.4" fill={color} stroke="none" /><circle cx="15" cy="9" r="1.4" fill={color} stroke="none" /><circle cx="9" cy="15" r="1.4" fill={color} stroke="none" /><circle cx="15" cy="15" r="1.4" fill={color} stroke="none" /></g>);
      break;
    case 'capsule':
      body = (<g {...common}><rect x="3.5" y="7.5" width="17" height="9" rx="4.5" /><line x1="9" y1="12" x2="15" y2="12" /></g>);
      break;
    case 'radar':
      body = (<g {...common}><circle cx="12" cy="12" r="9" opacity="0.35" /><path d="M12 12 L20 8" /><path d="M5 15a8 8 0 0 1 11-7" opacity="0.7" /><circle cx="12" cy="12" r="1.8" fill={color} stroke="none" /></g>);
      break;
    case 'cross':
      body = (<g {...common}><circle cx="12" cy="12" r="8.5" /><line x1="12" y1="7.5" x2="12" y2="16.5" /><line x1="7.5" y1="12" x2="16.5" y2="12" /></g>);
      break;
    case 'diamond':
      body = (<g {...common}><path d="M12 3.5 L20.5 12 L12 20.5 L3.5 12 Z" /><circle cx="12" cy="12" r="2" fill={color} stroke="none" /></g>);
      break;
    case 'vessel': // spacecraft host — schematic pod + fins
      body = (<g {...common}><rect x="8" y="4.5" width="8" height="15" rx="4" /><circle cx="12" cy="9.5" r="1.7" fill={color} stroke="none" /><line x1="8" y1="14" x2="5.5" y2="18.5" /><line x1="16" y1="14" x2="18.5" y2="18.5" /></g>);
      break;
    case 'matrix': // immobile container — nested squares
      body = (<g {...common}><rect x="4" y="4" width="16" height="16" rx="2" /><rect x="8.5" y="8.5" width="7" height="7" rx="1.2" /><circle cx="12" cy="12" r="1" fill={color} stroke="none" /></g>);
      break;
    case 'hub': // system hub — claimed star + orbiting body
      body = (<g {...common}><circle cx="12" cy="12" r="2.6" fill={color} stroke="none" /><circle cx="12" cy="12" r="8" /><circle cx="20" cy="12" r="1.5" fill={color} stroke="none" /></g>);
      break;
    case 'hex':
    default:
      body = (<g {...common}><path d="M12 3.5 L19 7.5 L19 16.5 L12 20.5 L5 16.5 L5 7.5 Z" /><circle cx="12" cy="12" r="2.4" fill={color} stroke="none" /></g>);
  }
  return (<svg width={size} height={size} viewBox="0 0 24 24" style={{ opacity: o, display: 'block' }}>{body}</svg>);
}

// Radial gauge ring (operational capacity etc). pct 0–100.
function RingGauge({ pct = 0, size = 96, stroke = 8, color = '#ffb23e', track = 'rgba(255,255,255,0.10)', children }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const off = c * (1 - Math.max(0, Math.min(100, pct)) / 100);
  return (
    <div style={{ position: 'relative', width: size, height: size }}>
      <svg width={size} height={size} style={{ display: 'block', transform: 'rotate(-90deg)' }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={track} strokeWidth={stroke} />
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke}
          strokeDasharray={c} strokeDashoffset={off} strokeLinecap="round"
          style={{ filter: `drop-shadow(0 0 6px ${color}66)` }} />
      </svg>
      {children && (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>{children}</div>
      )}
    </div>
  );
}

Object.assign(window, {
  RD_FONT, RD_MONO, RD_TONES, RD_STATUS, RD_TYPES, RD_REPLICANT, RD_DEVICES, RD_CMD,
  RD_ACCOUNT, RD_REPLICANTS, RD_LOCATIONS, RD_RESOURCES, RD_HOSTS,
  rdStatusOf, rdType, DeviceGlyph, RingGauge,
});
