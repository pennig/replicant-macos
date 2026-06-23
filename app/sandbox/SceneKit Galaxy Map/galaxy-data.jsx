// galaxy-data.jsx — shared universe model + tokens for the Galaxy Explorer
// and Star System views. Pure data + math helpers (no JSX). Exported to window.
// Builds on data.js naming (Sylphrena / Chamakuy belt) and the Replicant
// color tokens. Loaded as text/babel like data.js.

// ── Tokens (theme-aware) ────────────────────────────────────────
// Map views are predominantly dark; the light appearance is a warm
// "celestial-atlas on parchment" reading of the same palette.
function rcMap(theme) {
  if (theme === 'light') return {
    theme,
    space: 'radial-gradient(1200px 760px at 30% 8%, #f4efe6, #e7e0d4 70%, #ded6c8 100%)',
    ink: '#1b2230', t1: '#1b2230', t2: '#5a6478', t3: '#8b94a6',
    accent: '#cf8418', accentSoft: 'rgba(207,132,24,0.14)', accentLine: 'rgba(207,132,24,0.55)',
    glass: 'rgba(249,245,238,0.78)', glassLine: 'rgba(28,34,48,0.12)', glassLineSoft: 'rgba(28,34,48,0.07)',
    glassShadow: '0 24px 70px rgba(40,30,15,0.18)',
    star: '#cf8418', starDim: 'rgba(28,34,48,0.34)', plane: 'rgba(28,34,48,0.13)', planeSoft: 'rgba(28,34,48,0.07)',
    relay: '#cf8418', life: '#1f9d63', resource: '#9a6f1e', npc: '#7b4fd6', transit: '#2f6fd0', sense: '#0f978f',
    field: 'rgba(28,34,48,0.04)', chipBg: 'rgba(28,34,48,0.05)',
    hzBand: 'rgba(31,157,99,0.10)', hzLine: 'rgba(31,157,99,0.35)',
  };
  return {
    theme,
    space: 'radial-gradient(1100px 720px at 24% 4%, #142036 0%, #0a0f1b 52%, #06080f 100%)',
    ink: '#e9eef7', t1: '#e9eef7', t2: '#9aa6bc', t3: '#6a7488',
    accent: '#ffb23e', accentSoft: 'rgba(255,178,62,0.13)', accentLine: 'rgba(255,178,62,0.5)',
    glass: 'rgba(13,18,28,0.62)', glassLine: 'rgba(255,255,255,0.1)', glassLineSoft: 'rgba(255,255,255,0.055)',
    glassShadow: '0 30px 80px rgba(0,0,0,0.55)',
    star: '#ffe6b0', starDim: 'rgba(180,196,224,0.5)', plane: 'rgba(150,180,230,0.14)', planeSoft: 'rgba(150,180,230,0.06)',
    relay: '#ffb23e', life: '#62d39a', resource: '#d8b06a', npc: '#b58bff', transit: '#5aa9ff', sense: '#3fd3cb',
    field: 'rgba(255,255,255,0.05)', chipBg: 'rgba(255,255,255,0.05)',
    hzBand: 'rgba(98,211,154,0.09)', hzLine: 'rgba(98,211,154,0.3)',
  };
}

// Layer legend — the toggleable information overlays for the galaxy.
const GAL_LAYERS = [
  { key: 'presence', label: 'My presence',      color: 'accent', desc: 'Systems with my devices & vessels' },
  { key: 'relay',    label: 'FTL relay network', color: 'relay',  desc: 'Superluminal links between nodes' },
  { key: 'recon',    label: 'Recon state',       color: 't2',     desc: 'Scanned · visited · only aware' },
  { key: 'life',     label: 'Life',              color: 'life',   desc: 'Biosignatures detected' },
  { key: 'resource', label: 'Resources',         color: 'resource', desc: 'Mineable richness' },
  { key: 'npc',      label: 'Other replicants',  color: 'npc',    desc: 'Foreign probe presence' },
];

// ── Galaxy: star systems ────────────────────────────────────────
// a = bearing on the galactic plane (deg), r = radius from core (0..1),
// h = height above/below plane (-0.3..0.3). recon: scanned|visited|aware.
// life: 0 | microbial | flora | fauna. resource 0..1. presence: mine|npc|null.
const GAL_SYSTEMS = [
  { id: 'CHK', name: 'Chamakuy',  a: 202, r: 0.12, h: 0.00, recon: 'scanned', life: 'flora',     resource: 0.72, devices: 6,  vessels: 1, presence: 'mine', relay: true,  home: true,  cls: 'K2 V' },
  { id: 'TRZ', name: 'Tarazedar', a: 150, r: 0.33, h: 0.06, recon: 'scanned', life: 0,           resource: 0.86, devices: 4,  vessels: 1, presence: 'mine', relay: true,  cls: 'G8 V' },
  { id: 'VLZ', name: 'Velzan',    a: 256, r: 0.31, h: -0.09,recon: 'scanned', life: 'fauna',     resource: 0.5,  devices: 14, vessels: 0, presence: 'mine', relay: true,  cls: 'M1 V' },
  { id: 'SEL', name: 'Selay',     a: 108, r: 0.53, h: 0.13, recon: 'visited', life: 'microbial', resource: 0.4,  devices: 3,  vessels: 1, presence: 'mine', relay: false, cls: 'K5 V' },
  { id: 'NRK', name: 'Narak',     a: 302, r: 0.5,  h: -0.16,recon: 'visited', life: 0,           resource: 0.3,  devices: 2,  vessels: 0, presence: 'mine', relay: true,  cls: 'M3 V' },
  { id: 'COR', name: 'Corvan',    a: 238, r: 0.42, h: 0.17, recon: 'scanned', life: 0,           resource: 0.55, devices: 1,  vessels: 0, presence: 'mine', relay: false, cls: 'F9 V' },
  { id: 'OBR', name: 'Obros',     a: 32,  r: 0.46, h: 0.05, recon: 'scanned', life: 'flora',     resource: 0.62, devices: 0,  vessels: 0, presence: 'npc',  relay: true,  cls: 'G2 V' },
  { id: 'PEN', name: 'Penh',      a: 94,  r: 0.27, h: -0.12,recon: 'scanned', life: 'fauna',     resource: 0.45, devices: 0,  vessels: 0, presence: 'npc',  relay: false, cls: 'K0 V' },
  { id: 'TYR', name: 'Tyrrho',    a: 272, r: 0.74, h: -0.2, recon: 'aware',   life: 0,           resource: 0.6,  devices: 0,  vessels: 0, presence: 'npc',  relay: true,  cls: 'B7 V' },
  { id: 'KET', name: 'Kethra',    a: 68,  r: 0.7,  h: -0.1, recon: 'aware',   life: 0,           resource: 0.92, devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'M0 V' },
  { id: 'SIL', name: 'Silane',    a: 344, r: 0.66, h: 0.19, recon: 'aware',   life: 'microbial', resource: 0.5,  devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'A3 V' },
  { id: 'DRO', name: 'Drost',     a: 220, r: 0.62, h: 0.21, recon: 'visited', life: 0,           resource: 0.38, devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'G0 V' },
  { id: 'VEY', name: 'Veyln',     a: 178, r: 0.82, h: -0.05,recon: 'aware',   life: 0,           resource: 0.78, devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'K3 V' },
  { id: 'MOR', name: 'Morrow',    a: 18,  r: 0.86, h: 0.11, recon: 'aware',   life: 0,           resource: 0.42, devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'M4 V' },
  { id: 'ACH', name: 'Achen',     a: 128, r: 0.9,  h: 0.16, recon: 'aware',   life: 'flora',     resource: 0.5,  devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'F2 V' },
  { id: 'ULX', name: 'Ulix',      a: 320, r: 0.9,  h: 0.04, recon: 'aware',   life: 0,           resource: 0.66, devices: 0,  vessels: 0, presence: null,   relay: false, cls: 'O9 V' },
];

// FTL relay links. mine = my superluminal mesh; npc = a detected foreign mesh.
const GAL_LINKS = [
  { a: 'CHK', b: 'TRZ', owner: 'mine' },
  { a: 'CHK', b: 'VLZ', owner: 'mine' },
  { a: 'VLZ', b: 'NRK', owner: 'mine' },
  { a: 'CHK', b: 'COR', owner: 'mine', planned: true },
  { a: 'OBR', b: 'TYR', owner: 'npc' },
];

const GAL_BY_ID = Object.fromEntries(GAL_SYSTEMS.map((s) => [s.id, s]));

const RECON = {
  scanned: { label: 'Scanned', pip: 'full', dim: 1.0,  note: 'Full intel' },
  visited: { label: 'Visited', pip: 'half', dim: 0.78, note: 'Been there · partial intel' },
  aware:   { label: 'Aware',   pip: 'open', dim: 0.5,  note: 'Detected only · uncharted' },
};
const LIFE = {
  microbial: { label: 'Microbial', tier: 1 },
  flora:     { label: 'Flora',     tier: 2 },
  fauna:     { label: 'Fauna',     tier: 3 },
};

// Project a galaxy system onto the tilted disc. squash flattens the plane;
// rot spins it; tiltX nudges the whole disc. Returns screen offset from the
// disc centre (caller adds cx/cy), plus depth 0(back)..1(front) and the stem
// length down to the plane (for the vertical "altitude" line).
function projDisc(sys, scale, rot, squash) {
  const ang = (sys.a * Math.PI) / 180 + rot;
  const px = Math.cos(ang) * sys.r * scale;
  const planeY = Math.sin(ang) * sys.r * scale * squash;
  const lift = -sys.h * scale * 0.62;
  return { x: px, y: planeY + lift, planeY, stem: lift, depth: (Math.sin(ang) + 1) / 2 };
}

// Deterministic starfield points. Returns [{x,y,r,o}] in 0..1 space.
function makeStars(n, seed) {
  let s = seed >>> 0; const rnd = () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
  const out = [];
  for (let i = 0; i < n; i++) out.push({ x: rnd(), y: rnd(), r: rnd() * 1.3 + 0.2, o: rnd() * 0.6 + 0.12 });
  return out;
}

// ── Star System: Chamakuy ───────────────────────────────────────
// 2D orrery model. orbit = semi-major axis (px in a 1000-wide field),
// ecc squashes the ellipse, period in arbitrary units, phase0 in deg.
const SYS_STAR = { name: 'Chamakuy', cls: 'K2 V', kelvin: 4800, color: '#ffb648', glow: '#ff9e2c', r: 26 };
const SYS_HZ = { inner: 150, outer: 232 }; // habitable-zone band radii

const SYS_PLANETS = [
  { id: 'I',   name: 'Vash',     orbit: 96,  ecc: 0.97, period: 22,  phase0: 35,  r: 5.5,  color: '#b08868', type: 'Rocky',     devices: 0, life: 0 },
  { id: 'II',  name: 'Orrun',    orbit: 188, ecc: 0.95, period: 48,  phase0: 205, r: 9,    color: '#5fa3b0', type: 'Terran',    devices: 2, life: 'flora',
    moons: [{ orbit: 18, period: 7, phase0: 80, r: 2.2, color: '#9aa6bc' }] },
  { id: 'III', name: 'Cael',     orbit: 300, ecc: 0.93, period: 96,  phase0: 320, r: 7,    color: '#c98b5a', type: 'Arid',      devices: 1, life: 0 },
  { id: 'IV',  name: 'Thessaly', orbit: 408, ecc: 0.9,  period: 168, phase0: 122, r: 17,   color: '#caa06a', type: 'Gas giant', devices: 0, life: 0, ring: true, lagrange: true,
    moons: [{ orbit: 30, period: 9, phase0: 20, r: 2.6, color: '#cdd6e6' }, { orbit: 44, period: 15, phase0: 200, r: 3, color: '#a89a86' }] },
];

// Asteroid belt sits between Cael (III) and Thessaly (IV) — the Chamakuy belt.
const SYS_BELT = { inner: 332, outer: 372, count: 150, mined: true };

// Lagrange points belong to a host planet (here Thessaly IV). L4/L5 lead/trail
// by 60°; L1/L2/L3 lie on the star–planet line. selectable ones can be travelled to.
const SYS_LAGRANGE = [
  { id: 'L1', host: 'IV', t: 0.86, kind: 'inner',   device: 'surge_plate', label: 'Surge corridor anchor' },
  { id: 'L2', host: 'IV', t: 1.14, kind: 'outer',   device: null,          label: 'Shadow station candidate' },
  { id: 'L4', host: 'IV', lead: 60,  kind: 'trojan', device: null,         label: 'Trojan cluster · stable' },
  { id: 'L5', host: 'IV', lead: -60, kind: 'trojan', device: 'ftl_relay',  label: 'Relay node · Chamakuy-Gate' },
];

// Devices stationed in-system (rendered at a body or point).
const SYS_DEVICES = [
  { code: 'B58FCC78', type: 'mining_drone', at: 'belt',  status: 'mining',     label: 'Mining Drone' },
  { code: '1A9C77E2', type: 'mining_drone', at: 'belt',  status: 'idle',       label: 'Mining Drone' },
  { code: '22D7E5A9', type: 'forge',        at: 'II',    status: 'printing',    label: 'Forge' },
  { code: 'A1F00C2D', type: 'survey_probe', at: 'III',   status: 'prospecting', label: 'Survey Probe' },
  { code: '7C0E9B41', type: 'ftl_relay',    at: 'L5',    status: 'relaying',    label: 'FTL Relay' },
  { code: 'E70D4491', type: 'surge_plate',  at: 'L1',    status: 'inactive',    label: 'Surge Plate' },
];

// Vessels in transit — live position interpolates between from/to along a
// course. HEAVEN is the active replicant's host vessel.
const SYS_VESSELS = [
  { code: 'C1D9F0A2', name: 'HEAVEN',    kind: 'vessel', from: 'II',   to: 'IV',   t: 0.42, status: 'cruising', replicant: 'Sylphrena' },
  { code: '9E33B70F', name: 'Hauler',    kind: 'hauler', from: 'belt', to: 'II',   t: 0.66, status: 'cruising' },
  { code: 'D4A2110B', name: 'Drone',     kind: 'mining_drone', from: 'belt', to: 'III', t: 0.2, status: 'travelling' },
];

Object.assign(window, {
  rcMap, GAL_LAYERS, GAL_SYSTEMS, GAL_LINKS, GAL_BY_ID, RECON, LIFE,
  projDisc, makeStars,
  SYS_STAR, SYS_HZ, SYS_PLANETS, SYS_BELT, SYS_LAGRANGE, SYS_DEVICES, SYS_VESSELS,
});
