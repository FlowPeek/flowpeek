// When a connector has no reason to bend, it does not bend.
//
// The defect this file exists for: an edge between two boxes the layout had already put on one
// centre line, with nothing between them, still stepped 8-12px sideways and paid for it with a pair
// of 4px-radius corners. Magnified it does not read as a routing decision, it reads as a bug. Two
// causes, and the file asserts both are gone:
//
//   1. The fan spread every face's attach points at L*k/(N+1) whether or not anything collided, so
//      one connector arriving on a face pushed an unrelated one off centre. `Web --> Router` with a
//      second edge landing on Router's top face is that case.
//   2. The fan centred itself on the run of the face that `portSpan` left usable, not on the box.
//      On the four skewed geometries that run is not centred under the node, so a LONE connector
//      came out two grid units off. `[/Parallelogram/]` is that case, and it needs no second edge
//      anywhere in the drawing to show it.
//
// The assertion is deliberately the strictest form: one `M`, one `L`, nothing else. A path with a
// corner in it has a `Q`; a path that steps and comes back has two. Counting corners would pass a
// route that wandered and returned, and the whole complaint is about the wander.
//
// What this must not buy: the 12px of SKILL.md §6 rule 4. Every block below that asks for a
// straight line also checks that a face carrying more than one connector still separates them.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureText } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

function drawn(source) {
  const out = flow.render({
    source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText,
  });
  expect(out.reason || 'ok').toBe('ok');
  return out;
}

/** The geometry behind a drawing, so a precondition is read off the layout and not off the paint. */
function laidOut(source) {
  const db = new flow.FlowDB();
  db.clear();
  flow.parse(source, db);
  return flow.layout(db, { measureText, theme: flow.buildFlowTheme(EDITORIAL) });
}

/**
 * Every connector's `d`, in the order `layout` returned the edges. `emit` paints them in that order
 * and the count is checked here, so an index is the same edge in both halves of a test.
 */
function paths(source) {
  const out = [];
  const re = /<path class="[^"]*flowchart-link[^"]*" data-id="[^"]*" d="([^"]*)"/g;
  const svg = drawn(source).svg;
  let m;
  while ((m = re.exec(svg)) !== null) out.push(m[1]);
  return out;
}

const STRAIGHT = /^M-?\d+,-?\d+ L-?\d+,-?\d+$/;

/** Every attach point on one box's face, as a position along that face. */
function faceOffsets(drawing, boxId, side) {
  const along = (side === 'top' || side === 'bottom') ? 'x' : 'y';
  const found = [];
  for (const edge of drawing.edges) {
    if (edge.from === boxId && edge.start.side === side) found.push(edge.start[along]);
    if (edge.to === boxId && edge.end.side === side) found.push(edge.end[along]);
  }
  return found.sort((p, q) => p - q);
}

function pitches(offsets) {
  const out = [];
  for (let i = 1; i < offsets.length; i += 1) out.push(offsets[i] - offsets[i - 1]);
  return out;
}

/**
 * The pairs this file is about: two boxes whose centres agree on the axis the connector crosses,
 * with no third box overlapping the corridor between them. Read off `layout`, so "shared centre
 * line" is a fact about the placement rather than something inferred from the drawn route.
 */
function alignedAndClear(drawing) {
  const byId = new Map(drawing.nodes.map((n) => [n.id, n]));
  const found = [];
  drawing.edges.forEach((edge, index) => {
    if (edge.selfLoop) return;
    const a = byId.get(edge.from);
    const b = byId.get(edge.to);
    if (!a || !b) return;
    const vertical = edge.start.side === 'top' || edge.start.side === 'bottom';
    const centre = (box) => (vertical ? box.x + box.width / 2 : box.y + box.height / 2);
    if (centre(a) !== centre(b)) return;
    const near = (box) => (vertical ? box.y : box.x);
    const far = (box) => (vertical ? box.y + box.height : box.x + box.width);
    const gap = [Math.min(far(a), far(b)), Math.max(near(a), near(b))];
    if (gap[1] <= gap[0]) return;
    for (const other of drawing.nodes) {
      if (other === a || other === b) continue;
      const across = vertical
        ? [other.x, other.x + other.width]
        : [other.y, other.y + other.height];
      if (far(other) > gap[0] && near(other) < gap[1] && across[1] >= centre(a) && across[0] <= centre(a)) return;
    }
    found.push({ index, edge, from: edge.from, to: edge.to });
  });
  return found;
}

/** Every geometry in SHAPE_GEOMETRY, and a second node of the same shape to point it at. */
const SHAPES = [
  ['rect', '[rect]'],
  ['round', '(round)'],
  ['stadium', '([stadium])'],
  ['subroutine', '[[subroutine]]'],
  ['cylinder', '[(cylinder)]'],
  ['circle', '((circle))'],
  ['odd', '>odd]'],
  ['rhombus', '{rhombus}'],
  ['hexagon', '{{hexagon}}'],
  ['lean-right', '[/lean right/]'],
  ['lean-left', '[\\lean left\\]'],
  ['trapezoid', '[/trapezoid\\]'],
  ['inv-trapezoid', '[\\inv trapezoid/]'],
  ['doublecircle', '(((double circle)))'],
];

describe('[Straight] one connector, two boxes, one centre line', () => {
  for (const direction of ['TD', 'LR']) {
    for (const [geometry, syntax] of SHAPES) {
      it(`${direction} ${geometry}: a lone connector is a single segment`, () => {
        const source = `flowchart ${direction}\n  A${syntax} --> B${syntax}`;
        const drawing = laidOut(source);
        const [a, b] = drawing.nodes;
        // The precondition, asserted rather than assumed: a one-node-per-rank chain centres every
        // box on the level's order axis, whatever the boxes measure. If that ever stops being true
        // this test is about something else and should say so instead of passing vacuously.
        const centre = (box) => (direction === 'TD' ? box.x + box.width / 2 : box.y + box.height / 2);
        expect(`${geometry} centres ${centre(a)} ${centre(b)}`).toBe(`${geometry} centres ${centre(a)} ${centre(a)}`);
        expect(paths(source)).toEqual([expect.stringMatching(STRAIGHT)]);
      });
    }
  }

  it('holds for the skewed faces that are not centred under their box', () => {
    // Cause 2, on its own. A parallelogram's top face is outline only between its two skewed ends
    // and a trapezoid's is only its narrow end, so `portSpan` hands back a run that sits off to one
    // side of the box; the even spread centred itself on THAT and put a lone port two units wide of
    // the node's middle. Measured on this chain before the fix: `[/Trapezoid\\] --> [/Parallelogram/]`
    // bent 8px with a pair of 4px corners while its three neighbours ran straight.
    const source = [
      'flowchart TD',
      '  h{{Hexagon gate}} --> cyl[(Cylinder store)]',
      '  cyl --> trap[/Trapezoid\\]',
      '  trap --> para[/Parallelogram/]',
      '  para --> circ((Circle))',
      '  circ --> sub[[Subroutine]]',
    ].join('\n');
    const drawn5 = paths(source);
    expect(drawn5).toHaveLength(5);
    for (const d of drawn5) expect(d).toMatch(STRAIGHT);
  });
});

describe('[Straight] the fan separates only what collides', () => {
  it('leaves the aligned connector alone and moves the one that arrives beside it', () => {
    // `Web --> Router` with a second edge landing on Router's top face -- the shape that made this
    // worth fixing. Web sits directly over Router, so its connector has no reason to move, and the
    // one coming in from Worker has to go somewhere else on that face.
    const source = [
      'flowchart TD',
      '  subgraph s[Tier]',
      '    W[Web] --> R[Router]',
      '  end',
      '  K[Worker] --> R',
    ].join('\n');
    const drawing = laidOut(source);
    const web = drawing.nodes.find((n) => n.id === 'W');
    const router = drawing.nodes.find((n) => n.id === 'R');
    expect(web.x + web.width / 2).toBe(router.x + router.width / 2);

    const [webToRouter] = paths(source);
    expect(webToRouter).toMatch(STRAIGHT);

    const offsets = faceOffsets(drawing, 'R', 'top');
    expect(offsets).toHaveLength(2);
    for (const pitch of pitches(offsets)) expect(pitch).toBeGreaterThanOrEqual(12);
  });

  it('keeps two connectors between the same pair straight, 12px apart', () => {
    // Both ends of both edges want the one coordinate, which is the only case where the placement
    // has to move something that was already in line. Moving BOTH ends of each edge by the same
    // amount is what keeps them straight while it separates them.
    for (const source of [
      'flowchart TD\n  A[One] --> B[Two]\n  A --> B',
      'flowchart LR\n  A[One] --> B[Two]\n  A --> B',
      'flowchart TD\n  A[One] --> B[Two]\n  B --> A',
    ]) {
      const both = paths(source);
      expect(both).toHaveLength(2);
      for (const d of both) expect(d).toMatch(STRAIGHT);
      const drawing = laidOut(source);
      const vertical = source.indexOf('TD') !== -1;
      for (const [id, side] of [['A', vertical ? 'bottom' : 'right'], ['B', vertical ? 'top' : 'left']]) {
        const offsets = faceOffsets(drawing, id, side);
        expect(offsets).toHaveLength(2);
        for (const pitch of pitches(offsets)) expect(pitch).toBeGreaterThanOrEqual(12);
      }
    }
  });

  it('still spreads a face that seven connectors share', () => {
    // The other end of the trade. Nothing here is aligned with anything, so the placement is doing
    // what the even spread always did, and rule 4 is the only thing holding.
    const source = ['flowchart TD', ...Array.from({ length: 7 }, (_, i) => `  N${i} --> Z[Sink]`)].join('\n');
    const offsets = faceOffsets(laidOut(source), 'Z', 'top');
    expect(offsets).toHaveLength(7);
    for (const pitch of pitches(offsets)) expect(pitch).toBeGreaterThanOrEqual(12);
  });
});

describe('[Straight] over a corpus', () => {
  const CORPUS = [
    'flowchart TD\n  A[Start] --> B{Is it ready?}\n  B -->|yes| C[(Store)]\n  B -->|no| D((Retry))',
    'flowchart LR\n  A --> B --> C --> D --> E',
    'flowchart TD\n  subgraph edge["Edge tier"]\n    CDN[CDN] --> LB[Load balancer]\n  end\n  LB --> API[API] --> DB[(Postgres)]',
    'flowchart BT\n  A[one] --> B[two]\n  A --> C[three]\n  B --> D[four]\n  C --> D',
    'flowchart RL\n  A>note] --- B[/skew/] -.-> C[\\other\\]',
    'graph TD\n  A --- B\n  A ---- C\n  B ==> C\n  C --> A',
    'flowchart LR\n  subgraph a\n   subgraph b\n    X --> Y\n   end\n  end\n  Y --> Z\n  Z --> X',
    ['flowchart TD',
      '  subgraph a[Frontend]', '   A1 --> A2 --> A3', '  end',
      '  subgraph b[Backend]', '   B1 --> B2 --> B3', '  end',
      '  A3 --> B1', '  B3 --> A1'].join('\n'),
    ['flowchart TD',
      '  subgraph edge["Edge tier"]', '    CDN[CDN] --> LB[Load balancer]', '  end',
      '  subgraph core["Core"]', '    API[API] --> Store[(Store)]', '  end',
      '  LB --> API', '  Store -.-> LB'].join('\n'),
    'flowchart TD\n  A --> H[Hub]\n  B --> H\n  C --> H\n  H --> X\n  H --> Y\n  H --> Z',
  ];

  it('draws every aligned, unobstructed pair as one segment', () => {
    // Measured over this corpus before the change: 23 pairs of boxes sharing a centre line with
    // nothing between them, 7 of them drawn with a step in the line. The one exception below is not
    // a port that could have been aligned -- `C --> A` in the sixth source is a back edge whose
    // corridor the layout reserved outside either box, so the port is already hard against the end
    // of its face and the step is the corridor's, not the fan's.
    let aligned = 0;
    const stepped = [];
    for (const source of CORPUS) {
      const drawing = laidOut(source);
      const drawnPaths = paths(source);
      expect(drawnPaths).toHaveLength(drawing.edges.length);
      for (const pair of alignedAndClear(drawing)) {
        aligned += 1;
        if (!STRAIGHT.test(drawnPaths[pair.index])) stepped.push(`${pair.from}->${pair.to}`);
      }
    }
    expect(`${aligned} aligned, stepped ${stepped.join(',') || 'none'}`).toBe('23 aligned, stepped C->A');
  });
});
