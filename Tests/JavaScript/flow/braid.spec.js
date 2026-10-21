// Two connectors do not cross each other twice.
//
// The defect this file exists for: a visual review of sixteen sources ranked "hop-bump chains and
// shared corridors" second of ten -- rows of bridge bumps where a reader cannot follow a line
// through. Measured on the emitted paths, a large share of those bumps were not crossings the
// drawing needed: they were PAIRS of connectors that crossed, ran side by side, and crossed back.
// Two orthogonal routes that cross twice can always be redrawn crossing zero times by swapping the
// coordinates of their two parallel runs, so every such pair is two bumps paid for nothing.
//
// The state machine (review 03) and the two-region mesh (review 14) each had two such pairs, and
// `reported/cand` in Scripts/differential.mjs had the six crossings that came from them. All three
// are asserted here to have none; the generated SWEEP is asserted to stay at none.
//
// What this must not buy: a bend. The swap moves two runs along their own normal and nothing else;
// the corpus-wide bend total is Scripts/differential.mjs's business and is not re-counted here.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SWEEP } from './corpus.js';
import { measureText } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  monoFontFamily: "'Geist', sans-serif",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

const STATE_MACHINE = [
  'flowchart TD',
  '    idle[Idle] -->|connect| connecting[Connecting]',
  '    connecting -->|success| online[Online]',
  '    connecting -->|timeout| retry[Retry wait]',
  '    connecting -->|auth error| failed[Failed]',
  '    retry -->|backoff elapsed| connecting',
  '    online -->|heartbeat lost| retry',
  '    online -->|user logout| idle',
  '    failed -->|user retries| connecting',
  '    failed -->|give up| idle',
  '    online -->|server shutdown notice| draining[Draining]',
  '    draining -->|drained| idle',
].join('\n');

const MESH = [
  'flowchart RL',
  '    subgraph east[East Region]',
  '        e1[Ingress East] --> e2[Router East]',
  '        e2 --> e3[Worker East A]',
  '        e2 --> e4[Worker East B]',
  '    end',
  '    subgraph west[West Region]',
  '        w1[Ingress West] --> w2[Router West]',
  '        w2 --> w3[Worker West A]',
  '        w2 --> w4[Worker West B]',
  '    end',
  '    e3 -->|replicate| w3',
  '    w3 -->|replicate| e3',
  '    e4 -.->|failover| w2',
  '    w4 -.->|failover| e2',
  '    e3 ==> q[(Global Queue)]',
  '    w3 ==> q',
  '    e4 ==> q',
  '    w4 ==> q',
].join('\n');

// `reported/cand` from Scripts/differential.mjs, verbatim.
const CANDIDATES = [
  'flowchart TB',
  '    O["Original (Hauler1)<br/>category: Original"]',
  '    subgraph candidates["Candidate 생성 (market group 내 hauler별)"]',
  '        C2["Candidate-H2<br/>category: Original<br/>isDiscarded: true"]',
  '        C3["Candidate-H3<br/>category: Original<br/>isDiscarded: true"]',
  '    end',
  '    subgraph negotiations["Negotiation Quotes"]',
  '        N1["Nego-H1<br/>category: Negotiation<br/>discardedQuoteId: (없음)"]',
  '        N2["Nego-H2<br/>category: Negotiation<br/>discardedQuoteId: Candidate-H2.id"]',
  '        N3["Nego-H3<br/>category: Negotiation<br/>discardedQuoteId: Candidate-H3.id"]',
  '    end',
  '    O -- "negotiate(adjustRate, original)" --> N1',
  '    C2 -- "negotiate(adjustRate, original)" --> N2',
  '    C3 -- "negotiate(adjustRate, original)" --> N3',
  '    N1 -. "originalQuoteId" .-> O',
  '    N2 -. "originalQuoteId" .-> O',
  '    N3 -. "originalQuoteId" .-> O',
  '    N2 -. "discardedQuoteId" .-> C2',
  '    N3 -. "discardedQuoteId" .-> C3',
  '    O -- "derivedQuoteId (representative)" --> N1',
].join('\n');

/** Each connector's corner skeleton, bridges read as their chord. */
function routes(source) {
  const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText });
  expect(out.reason || 'ok').toBe('ok');
  const re = /<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"/g;
  return [...out.svg.matchAll(re)].map(([, id, d]) => {
    const tokens = d.match(/[A-Za-z]|-?\d+(?:\.\d+)?/g) ?? [];
    const points = [];
    let command = null;
    for (let i = 0; i < tokens.length;) {
      if (/^[A-Za-z]$/.test(tokens[i])) command = tokens[i++];
      const take = (n) => tokens.slice(i, (i += n)).map(Number);
      if (command === 'M' || command === 'L') { const [x, y] = take(2); points.push({ x, y }); }
      else if (command === 'Q') { const [cx, cy, x, y] = take(4); points.push({ x: cx, y: cy }, { x, y }); }
      else if (command === 'A') { const v = take(7); points.push({ x: v[5], y: v[6] }); }
      else throw new Error(`unexpected path command ${command} in ${d}`);
    }
    const legs = [];
    for (let i = 0; i + 1 < points.length; i += 1) {
      const p = points[i], q = points[i + 1];
      if (p.x === q.x && p.y === q.y) continue;
      const last = legs[legs.length - 1];
      const horizontal = p.y === q.y;
      // A bridge splits one run in two; join them back so a leg is a leg.
      if (last && last.horizontal === horizontal && (horizontal ? last.q.y === p.y : last.q.x === p.x)) last.q = q;
      else legs.push({ p, q, horizontal });
    }
    return { id, legs };
  });
}

function crosses(a, b) {
  if (a.horizontal === b.horizontal) return false;
  const h = a.horizontal ? a : b;
  const v = a.horizontal ? b : a;
  return v.p.x > Math.min(h.p.x, h.q.x) && v.p.x < Math.max(h.p.x, h.q.x)
    && h.p.y > Math.min(v.p.y, v.q.y) && h.p.y < Math.max(v.p.y, v.q.y);
}

/** Every pair of connectors that crosses more than once, by data-id. */
function braids(source) {
  const all = routes(source);
  const found = [];
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      let n = 0;
      for (const a of all[i].legs) for (const b of all[j].legs) if (crosses(a, b)) n += 1;
      if (n >= 2) found.push(`${all[i].id} x ${all[j].id} (${n})`);
    }
  }
  return found;
}

describe('[Braid] two connectors do not cross each other twice', () => {
  it('the labelled state machine has no pair that crosses back', () => {
    expect(braids(STATE_MACHINE)).toEqual([]);
  });

  it('the two-region mesh has no pair that crosses back', () => {
    expect(braids(MESH)).toEqual([]);
  });

  it('the reported candidates drawing has no pair that crosses back', () => {
    expect(braids(CANDIDATES)).toEqual([]);
  });

  it('holds on every SWEEP source', () => {
    const found = SWEEP.flatMap(({ name, source }) => braids(source).map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });
});

// The lanes into one face nest in the order of the face's ports.
//
// Ports have been ordered by where each end lands since 028efde; the lanes in the gap before a face
// were not, so two routes arriving from one side could turn onto the face in the wrong order and
// cross twice there -- the held-out review's h20, two hops at Closed. Two SWEEP families and the
// fixture below bring several routes into one face from sources at different depths, and at
// e5d9490 they drew 2 to 6 hops each; this asks that no two routes ending on one node cross.
function sharedEndCrossings(source) {
  const all = routes(source);
  const found = [];
  const ends = (id) => id.replace(/^L_/, '').replace(/_\d+$/, '').split('_').pop();
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      if (ends(all[i].id) !== ends(all[j].id)) continue;
      let n = 0;
      for (const a of all[i].legs) for (const b of all[j].legs) if (crosses(a, b)) n += 1;
      if (n > 0) found.push(`${all[i].id} x ${all[j].id} (${n})`);
    }
  }
  return found;
}

// Three arms on one side of the face with the nearest source between them, in all four directions.
// A pair swap moves the middle arm's run across the outer arm's last leg, so the three have to take
// each other's lanes at once; at e5d9490 it draws 4 to 6 hops in every direction. Kept out of
// SWEEP: with its crossings gone it shows two defects of its own, there at e5d9490 too -- a 4px
// jog on Article's route that the bridge pass had been widening to 8 only because a bump needed
// the room (render.spec's square corners), and Second line's six-corner route LR and RL
// (straight.spec's four-corner cap) -- which are not the lanes' to fix.
const ROUND_A_FAN = ['TD', 'LR', 'BT', 'RL'].map((dir) => ({
  name: `returns round a fan ${dir}`,
  source: [`flowchart ${dir}`, '  a[Intake] --> s[Review queue] --> d[Review team] --> c([Done])', '  b[Article] --> c',
    '  r[Triage] --> e[Second line]', '  f[Approval] --> c', '  e --> c', '  e --> j[Ticket] --> n[Notify owner] --> c',
    '  e --> m[Escalation] --> c'].join('\n'),
}));

describe('[Braid] routes into one face take their lanes in the order of its ports', () => {
  it('holds where arms come in past a nearer source, in pairs and in threes', () => {
    const families = [...SWEEP.filter(({ name }) => /^returns past /.test(name)), ...ROUND_A_FAN];
    expect(families.length).toBe(12);
    const found = families.flatMap(({ name, source }) => sharedEndCrossings(source).map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });

  // The lane the nest hands B --> E runs along D --> G, which the nest does not move, so the order
  // only holds with B --> E on a free lane beside it. At bbfbea3 B --> E crosses D --> E in every
  // direction.
  it('holds where the nested lane would run along a third route', () => {
    const family = SWEEP.filter(({ name }) => /^nesting past a third route /.test(name));
    expect(family.length).toBe(4);
    const found = family.flatMap(({ name, source }) => sharedEndCrossings(source).map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });
});

// A fork's arm lands on the near side of a corridor into the same face.
//
// `mirrorForks` sends a fork's outer arms to mirrored ports, and it read nothing but the two
// targets' runs: where a long-edge corridor lands on the same face from the apex's side, the
// mirrored port was past it, and the arm met the corridor in the last gap. Across the gap it is a
// crossing -- `fork beside corridors` TD and BT drew one at 9071d73 -- and where the corridor's
// last jog runs on the arm's own lane it is a shared stretch, which reads as one line joining the
// other: `opposed answers beside a skip` TD and BT, where the corridor into Pay the holding
// deposit ran 12px along "granted" under differential.mjs's face ruler. This file measures with the
// flat budget, which sizes those boxes so the two clear each other at 9071d73 too; the overlap
// check guards that shape here rather than reproducing it.
function sharedEndOverlaps(source) {
  const all = routes(source);
  const found = [];
  const ends = (id) => id.replace(/^L_/, '').replace(/_\d+$/, '').split('_').pop();
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      if (ends(all[i].id) !== ends(all[j].id)) continue;
      for (const a of all[i].legs) {
        for (const b of all[j].legs) {
          if (a.horizontal !== b.horizontal) continue;
          const on = a.horizontal ? a.p.y === b.p.y : a.p.x === b.p.x;
          const k = a.horizontal ? 'x' : 'y';
          const lo = Math.max(Math.min(a.p[k], a.q[k]), Math.min(b.p[k], b.q[k]));
          const hi = Math.min(Math.max(a.p[k], a.q[k]), Math.max(b.p[k], b.q[k]));
          if (on && hi > lo) found.push(`${all[i].id} along ${all[j].id} (${hi - lo}px)`);
        }
      }
    }
  }
  return found;
}

describe('[Braid] a fork arm lands on the near side of a corridor into the same face', () => {
  it('neither crosses the corridor nor runs along it', () => {
    const families = SWEEP.filter(({ name }) => /^(fork beside corridors|opposed answers beside a skip) /.test(name));
    expect(families.length).toBe(8);
    const found = families.flatMap(({ name, source }) =>
      [...sharedEndCrossings(source), ...sharedEndOverlaps(source)].map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });
});

// Two links between one pair of nodes do not cross each other at all.
//
// A two-way pair is the one pair a reader most wants to see as a matched there-and-back, and two
// orthogonal routes between the same two boxes can always be drawn nested: their ends stand on
// the same faces, so trading which route takes which port, or which lane, undoes any crossing
// between them. `uncrossPairs` offered neither for a pair that crossed only once, never traded
// ports, and refused every trade whose route ended on a round outline. The third held-out set's
// b11 had Esc and Resume crossing twice; `two-way pairs in a state machine` crosses a pair once in
// every direction at 019e21e.
function selfCrossingPairs(source) {
  const all = routes(source);
  const found = [];
  const ends = (id) => id.replace(/^L_/, '').replace(/_\d+$/, '');
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      const a = ends(all[i].id), b = ends(all[j].id);
      if (a !== b && a !== b.split('_').reverse().join('_')) continue;
      let n = 0;
      for (const p of all[i].legs) for (const q of all[j].legs) if (crosses(p, q)) n += 1;
      if (n > 0) found.push(`${all[i].id} x ${all[j].id} (${n})`);
    }
  }
  return found;
}

describe('[Braid] two links between one pair of nodes do not cross each other', () => {
  it('holds on every SWEEP source, the two-way family in every direction among them', () => {
    expect(SWEEP.filter(({ name }) => /^two-way pairs in a state machine /.test(name)).length).toBe(4);
    const found = SWEEP.flatMap(({ name, source }) => selfCrossingPairs(source).map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });

  // Every trade `uncrossPairs` offers this pair moves a run onto a lane another route holds, so the
  // trade only holds with one of the pair's runs slid to a lane nobody does. At 14a73f8 Recovering
  // <-> Checking crosses itself twice LR and RL.
  it('holds where the trade needs a run slid past a held lane, LR and RL', () => {
    const family = SWEEP.filter(({ name }) => /^two-way pair past a held lane /.test(name));
    expect(family.length).toBe(2);
    const found = family.flatMap(({ name, source }) => selfCrossingPairs(source).map((b) => `${name}: ${b}`));
    expect(found).toEqual([]);
  });
});
