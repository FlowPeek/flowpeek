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
