// Labels that share one face's gap stand in columns, not end to end.
//
// The second held-out set's b04 sends five labelled links out of one face and takes two back, and
// drew the gap 830pt deep where Pele's is about 295: every plate in the corridor was given its own
// stretch of the gap, so the drawing came out 1.7 times as wide and, fitted to a window, every word
// in it that much smaller. Two plates on lines far enough apart across the gap can stand at the same
// place along it; `layoutLevel` now asks the gap for the plates of that many lines side by side
// rather than for all of them.
//
// The source here is a request/response exchange of the same shape, written for this file -- not
// b04, which is a measuring stick -- and the property is the reader's: the gap is shallower than the
// corridor's plates laid end to end.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SWEEP } from './corpus.js';
import { measureFace, measureText } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

// What the app ships, as differential.mjs renders it: the face `measureFace` was read from and the
// 20px outer margin of MacMermaidTheme.swift.
const FACE = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif";
const EDITORIAL = {
  dark: false,
  fontFamily: FACE,
  monoFontFamily: FACE,
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 20,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

const exchange = (dir) => [
  `flowchart ${dir}`,
  '  C[Client] -->|ask the platform for a code| P[Platform]', '  P -->|code valid for five minutes| C',
  '  C -->|send the code| S[Server]', '  S -->|signed token| C', '  C -->|keep the token| K[Local store]',
  '  C -->|call with the token| S',
].join('\n');

function measured(source) {
  const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measureFace });
  expect(out.reason || 'ok').toBe('ok');
  expect(out.warnings).toEqual([]);
  const boxes = new Map();
  for (const m of out.svg.matchAll(/id="fp-0-flowchart-(\w+)-\d+" transform="translate\(([-\d.]+),([-\d.]+)\)"><rect class="basic label-container" x="([-\d.]+)" y="[-\d.]+" width="([\d.]+)"/g)) {
    boxes.set(m[1], { lo: +m[2] + +m[4], hi: +m[2] + +m[4] + +m[5] });
  }
  const widths = [...out.svg.matchAll(/<rect class="background" x="[-\d.]+" y="[-\d.]+" width="([\d.]+)"/g)].map((m) => +m[1]);
  return { boxes, widths };
}

describe('the plates of one face in one gap', () => {
  for (const dir of ['LR', 'RL']) {
    it(`stand side by side across the gap rather than end to end along it: ${dir}`, () => {
      const { boxes, widths } = measured(exchange(dir));
      const client = boxes.get('C');
      const far = ['P', 'S', 'K'].map((id) => boxes.get(id));
      const gap = dir === 'LR'
        ? Math.min(...far.map((b) => b.lo)) - client.hi
        : client.lo - Math.max(...far.map((b) => b.hi));
      // All six labels are on links into or out of the client's one face, so all six share its gap.
      expect(widths.length).toBe(6);
      const endToEnd = widths.reduce((a, b) => a + b, 0) + (widths.length - 1) * 16;
      expect(gap).toBeLessThan(endToEnd);
    });
  }
});

// And the plates of one gap stand in ONE column, each on its own line.
//
// Columns let the gap be shallower; they did not put the plates in a list. Each plate went to the
// middle of its own run, nearest first, and the runs of one gap start and stop at different places,
// so three or four plates in a gap stood at three or four places along it and a reader had to hunt
// for each one: the third held-out set's b04 and b16. Now the plates whose extents along the gap
// overlap are offered one place together, ON their own lines, and take it when none of them pays
// more than it did. `labelled fan with a return` LR and RL draw a staggered field at 4dc89d0.
const LABEL = /data-id="([^"]*)" transform="translate\((-?[\d.]+),(-?[\d.]+)\)"><rect class="background" x="(-?[\d.]+)" y="(-?[\d.]+)" width="([\d.]+)" height="([\d.]+)"/g;
const LINK = /<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"/g;

/** The plates of a horizontal drawing, grouped where their extents along x overlap. */
function fields(svg) {
  const runs = new Map();
  for (const [, id, d] of svg.matchAll(LINK)) {
    // Every command ends at its last coordinate pair; an L is a straight stretch from the last end.
    const out = [];
    let at = null;
    for (const [, c, args] of d.matchAll(/([MLQA])([^MLQA]*)/g)) {
      const n = args.match(/-?[\d.]+/g).map(Number);
      const end = { x: n[n.length - 2], y: n[n.length - 1] };
      if (c === 'L' && at) out.push([at, end]);
      at = end;
    }
    runs.set(id, out);
  }
  const plates = [...svg.matchAll(LABEL)].map((m) => {
    const p = { id: m[1], cx: +m[2], cy: +m[3], x: +m[2] + +m[4], w: +m[6] };
    // ON: a drawn horizontal stretch of its own line runs through the plate's middle, end to end.
    p.on = (runs.get(p.id) || []).some(([a, b]) => a.y === b.y && a.y === p.cy
      && Math.min(a.x, b.x) <= p.x && Math.max(a.x, b.x) >= p.x + p.w);
    return p;
  });
  const groups = [];
  for (const p of plates) {
    const hit = groups.filter((g) => g.some((q) => p.x < q.x + q.w && q.x < p.x + p.w));
    const merged = [p, ...hit.flat()];
    for (const g of hit) groups.splice(groups.indexOf(g), 1);
    groups.push(merged);
  }
  return groups.filter((g) => g.length >= 2);
}

describe('the plates of one gap', () => {
  const fan = SWEEP.filter(({ name }) => /^labelled fan with a return (LR|RL)$/.test(name));
  it('is checked on a fan of three or more labelled runs, both horizontal directions', () => {
    expect(fan.length).toBe(2);
  });
  for (const { name, source } of fan) {
    for (const [ruler, measure] of [['face', measureFace], ['budget', measureText]]) {
      it(`stand in one column, each ON its own line: ${name}, ${ruler}`, () => {
        const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measure });
        expect(out.warnings).toEqual([]);
        const big = fields(out.svg).filter((g) => g.length >= 3);
        expect(big.length).toBeGreaterThan(0);
        for (const g of big) {
          expect(new Set(g.map((p) => p.cx)).size, g.map((p) => `${p.id}@${p.cx}`).join(' ')).toBe(1);
          expect(g.filter((p) => !p.on).map((p) => p.id)).toEqual([]);
        }
      });
    }
  }
});

// And each plate in that column has a line of its own to stand ON.
//
// A column needs the lines under it at least a plate's height plus rule 2's gap apart, or the plate
// on the middle line covers its neighbours. Three labelled links between one pair of nodes left one
// face 12pt apart under 24pt plates, so two plates went beside their lines and one lay across two
// -- the held-out set's b04, whose three such links ran 24, 20 and 12pt apart. `seatPitch` now
// spaces a face's labelled ends that far apart before the placer looks.
describe('the labelled lines under one column', () => {
  const pair = SWEEP.filter(({ name }) => /^labelled links between one pair (LR|RL)$/.test(name));
  it('is checked on three labelled links between one pair, both horizontal directions', () => {
    expect(pair.length).toBe(2);
  });
  for (const { name, source } of pair) {
    for (const [ruler, measure] of [['face', measureFace], ['budget', measureText]]) {
      it(`stand a plate's height plus 8 apart, each plate ON its own: ${name}, ${ruler}`, () => {
        const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measure });
        expect(out.warnings).toEqual([]);
        const [field] = fields(out.svg);
        expect(field.length).toBe(3);
        expect(new Set(field.map((p) => p.cx)).size).toBe(1);
        expect(field.filter((p) => !p.on).map((p) => p.id)).toEqual([]);
        const heights = [...out.svg.matchAll(LABEL)].map((m) => +m[7]);
        const ys = field.map((p) => p.cy).sort((a, b) => a - b);
        for (let k = 1; k < ys.length; k += 1) expect(ys[k] - ys[k - 1]).toBeGreaterThanOrEqual(Math.max(...heights) + 8);
      });
    }
  }
});

// And the straight a seated plate stands on is long enough to hold it.
//
// A face's labelled exits that step onto a lane run the rest of the gap straight into their heads,
// and the placer charges a plate nearer a head than rule 2's gap more than one standing BESIDE its
// line. The gap was sized for the widest plate and the two stubs, not for the step's elbow and the
// head, so both plates went beside: the held-out set's b02, at 14a73f8.
describe('the straight after a step', () => {
  const steps = SWEEP.filter(({ name }) => /^labelled exits that step into heads (LR|RL)$/.test(name));
  it('is checked on two labelled exits that step, both horizontal directions', () => {
    expect(steps.length).toBe(2);
  });
  for (const { name, source } of steps) {
    for (const [ruler, measure] of [['face', measureFace], ['budget', measureText]]) {
      it(`holds each exit's plate ON its line: ${name}, ${ruler}`, () => {
        const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measure });
        expect(out.warnings).toEqual([]);
        const exits = fields(out.svg).flat().filter((p) => /^L_a_[bc]_0$/.test(p.id));
        expect(exits.length).toBe(2);
        expect(exits.filter((p) => !p.on).map((p) => p.id)).toEqual([]);
      });
    }
  }
});

// And a face that takes a line back keeps the seats of the lines it sends.
//
// The third held-out set's review asked that a busy face pay its seat only in the gaps beside a
// head and stand two leaving ends 12px apart, as a face every end leaves from does in `keyed menu`.
// Those keys are taller than wide and seat nothing; a one-line plate is wider than tall, and two
// exits that run on side by side out of a hub hold their plates in one column only a seat apart.
// Measured at b4caf70 with that rule: c05's 同行评审 144 to 104, b11's Resume laid along Stage
// clear's border, and here "right" beside its line.
describe('a face that sends and takes back', () => {
  const hubs = SWEEP.filter(({ name }) => /^hub that takes back what it sends (LR|RL)$/.test(name));
  it('is checked on one hub, both horizontal directions', () => {
    expect(hubs.length).toBe(2);
  });
  for (const { name, source } of hubs) {
    for (const [ruler, measure] of [['face', measureFace], ['budget', measureText]]) {
      it(`holds each exit's plate ON its line: ${name}, ${ruler}`, () => {
        const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measure });
        expect(out.warnings).toEqual([]);
        const exits = fields(out.svg).flat().filter((p) => /^L_hub_[abe]_0$/.test(p.id));
        expect(exits.length).toBe(3);
        expect(exits.filter((p) => !p.on).map((p) => p.id)).toEqual([]);
      });
    }
  }
});
