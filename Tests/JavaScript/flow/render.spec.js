// FlowPeek's own routing and emission, tested on the properties they exist to have.
//
// Every assertion below is one of the two things mermaid cannot be asked for -- the 4px grid and
// orthogonal connectors with rounded elbows -- or one of the guarantees that makes self-emitted
// markup safer to attach than a third-party bundle's. None of it is a snapshot: a golden would
// pass while the drawing was wrong, and these are supposed to fail when it is.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureText } from './measure.js';
import { nodeOutlines, segmentEntersShape } from './outline.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));
const THEME_SWIFT = readFileSync(join(root, 'Sources/FlowPeekCore/MacMermaidTheme.swift'), 'utf8');

// What MacMermaidTheme.swift ships, reduced to the keys the projection reads. The stylesheet is a
// stand-in for the real one in every test except the stylesheet-contract block, which reads the
// Swift source itself.
// `monoFontFamily` is among them because the editorial theme paints edge labels in a monospace
// stack and the renderer measures a label in the face it will be painted in: a theme that sent only
// the sans sized every backing rect for type nobody sees.
const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  monoFontFamily: "'Geist Mono', ui-monospace, monospace",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }\n.node rect.basic:not([rx]) { rx: 6px; ry: 6px; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

function render(source, overrides = {}) {
  return flow.render({
    source,
    renderID: 'fp-0',
    diagramType: 'flowchart-v2',
    theme: EDITORIAL,
    measureText,
    ...overrides,
  });
}

function drawn(source, overrides = {}) {
  const out = render(source, overrides);
  expect(out.reason || 'ok').toBe('ok');
  return out;
}

/** The ten sources every structural property is checked against. */
const CORPUS = [
  'flowchart TD\n  A[Start] --> B{Is it ready?}\n  B -->|yes| C[(Store)]\n  B -->|no| D((Retry))',
  'flowchart LR\n  A --> B --> C --> D --> E',
  'flowchart TD\n  subgraph edge["Edge tier"]\n    CDN[CDN] --> LB[Load balancer]\n  end\n  LB --> API[API] --> DB[(Postgres)]',
  'flowchart BT\n  A[one] --> B[two]\n  A --> C[three]\n  B --> D[four]\n  C --> D',
  'flowchart RL\n  A>note] --- B[/skew/] -.-> C[\\other\\]',
  'graph TD\n  A --- B\n  A ---- C\n  B ==> C\n  C --> A',
  [
    'flowchart TD',
    '  Client[Browser] --> CDN[CDN edge]',
    '  CDN --> API{Cache hit?}',
    '  API -->|yes| Cache[(Redis)]',
    '  API -->|no| Origin[Origin service]',
    '  Origin --> DB[(Postgres)]',
    '  Cache --> Client',
    '  DB --> Origin',
  ].join('\n'),
  'flowchart TD\n  A --> B --> C --> D --> E\n  A --> E\n  A --> D\n  B --> E',
  'flowchart LR\n  subgraph a\n   subgraph b\n    X --> Y\n   end\n  end\n  Y --> Z\n  Z --> X',
  'flowchart TD\n  H{Hub} --> A\n  H --> B\n  H --> C\n  H --> D\n  A --> Z\n  B --> Z\n  C --> Z\n  D --> Z',
  'flowchart TD\n  A --> A\n  A --> B\n  B --> B\n  B --> C',
  [
    'flowchart TD',
    '  subgraph a[Frontend]', '   A1 --> A2 --> A3', '  end',
    '  subgraph b[Backend]', '   B1 --> B2 --> B3', '  end',
    '  A3 --> B1', '  B3 --> A1',
  ].join('\n'),
];

const name = (source) => `${JSON.stringify(source.split('\n')[0])} (${source.split('\n').length} lines)`;

// --- reading the emitted markup back --------------------------------------------------------
//
// A regex reader rather than a DOM: the point of these tests is what the string says, and the
// string is what gets attached. Parsing it into a document first would test the parser's tolerance.

const NUMBER = /-?\d+(?:\.\d+)?/g;

/** Every `d` in document order, with the class attribute that precedes it. */
function edgePaths(svg) {
  const found = [];
  const re = /<path class="(edge-thickness-[^"]*)" data-id="([^"]*)" d="([^"]*)"/g;
  let m;
  while ((m = re.exec(svg)) !== null) found.push({ classes: m[1].split(' '), id: m[2], d: m[3] });
  return found;
}

/** Every command of a `d`, as [letter, numbers]. */
function commandsOf(d) {
  return (d.match(/[MLQA][^MLQA]*/g) || []).map((c) => [c[0], (c.slice(1).match(NUMBER) || []).map(Number)]);
}

/**
 * The corner-to-corner polyline a `d` describes. A quarter arc is read as its two tangent legs --
 * the control point IS the corner the arc was cut from -- so an assertion about axis alignment sees
 * the route rather than the rounding. A bridge (`A`) is read as its chord, which is the run it
 * interrupts: a hop is a decoration ON a straight stretch, not a change of direction, and every
 * assertion about routing wants the stretch.
 */
function polyline(d) {
  const points = [];
  for (const [letter, numbers] of commandsOf(d)) {
    if (letter === 'Q') points.push({ x: numbers[0], y: numbers[1] }, { x: numbers[2], y: numbers[3] });
    else if (letter === 'A') points.push({ x: numbers[5], y: numbers[6] });
    else points.push({ x: numbers[0], y: numbers[1] });
  }
  const merged = [];
  for (const p of points) {
    const last = merged[merged.length - 1];
    if (last && last.x === p.x && last.y === p.y) continue;
    merged.push(p);
  }
  return merged;
}

/** Every bridge in a `d`: its radius, and the point on the run it is centred on. */
function bridges(d) {
  const found = [];
  let at = null;
  for (const [letter, n] of commandsOf(d)) {
    if (letter === 'A') {
      const to = { x: n[5], y: n[6] };
      found.push({ rx: n[0], ry: n[1], sweep: n[4], from: at, to, at: { x: (at.x + to.x) / 2, y: (at.y + to.y) / 2 } });
      at = to;
    } else if (letter === 'Q') at = { x: n[2], y: n[3] };
    else at = { x: n[0], y: n[1] };
  }
  return found;
}

/** Where two routes cross at a point, as {x, y}. A shared endpoint is not a crossing. */
function crossings(a, b) {
  const found = [];
  for (const [p, q] of segmentsOf(polyline(a))) {
    for (const [r, s] of segmentsOf(polyline(b))) {
      const aHorizontal = p.y === q.y;
      if (aHorizontal === (r.y === s.y)) continue;
      const [h1, h2] = aHorizontal ? [p, q] : [r, s];
      const [v1, v2] = aHorizontal ? [r, s] : [p, q];
      const x = v1.x;
      const y = h1.y;
      if (x <= Math.min(h1.x, h2.x) || x >= Math.max(h1.x, h2.x)) continue;
      if (y <= Math.min(v1.y, v2.y) || y >= Math.max(v1.y, v2.y)) continue;
      found.push({ x, y, horizontal: [h1, h2], vertical: [v1, v2] });
    }
  }
  return found;
}

function segmentsOf(points) {
  const out = [];
  for (let i = 0; i + 1 < points.length; i += 1) out.push([points[i], points[i + 1]]);
  return out;
}

/** The markup with every text node removed, so an assertion about attributes sees only attributes. */
function attributesOnly(svg) {
  return svg.replace(/>[^<]*/g, '>');
}

function overlapLength(a, b) {
  return Math.min(a[1], b[1]) - Math.max(a[0], b[0]);
}

/** Two axis-aligned segments sharing a stretch of one line. A crossing point is not an overlap. */
function runsAlong([p, q], [r, s]) {
  if (p.x === q.x && r.x === s.x && p.x === r.x) {
    return overlapLength([Math.min(p.y, q.y), Math.max(p.y, q.y)], [Math.min(r.y, s.y), Math.max(r.y, s.y)]) > 0;
  }
  if (p.y === q.y && r.y === s.y && p.y === r.y) {
    return overlapLength([Math.min(p.x, q.x), Math.max(p.x, q.x)], [Math.min(r.x, s.x), Math.max(r.x, s.x)]) > 0;
  }
  return false;
}

/**
 * The straight stretches a `d` actually draws, in order: from the start, or from where a corner
 * arc let go, to where the next one takes hold. A bridge is transparent here -- it is a decoration
 * on a stretch, and what a bridge needs to know is how much of that stretch it has.
 */
function straightSpans(d) {
  const spans = [];
  let at = null;
  let start = null;
  for (const [letter, n] of commandsOf(d)) {
    if (letter === 'M') { at = { x: n[0], y: n[1] }; start = at; }
    else if (letter === 'L') at = { x: n[0], y: n[1] };
    else if (letter === 'A') at = { x: n[5], y: n[6] };
    else { spans.push([start, at]); at = { x: n[2], y: n[3] }; start = at; }
  }
  spans.push([start, at]);
  return spans.filter(([a, b]) => a && b && (a.x !== b.x || a.y !== b.y));
}

/** How much straight run a span has on each side of a point that lies on it. */
function clearance([a, b], point) {
  const horizontal = a.y === b.y;
  const at = horizontal ? point.x : point.y;
  const lo = Math.min(horizontal ? a.x : a.y, horizontal ? b.x : b.y);
  const hi = Math.max(horizontal ? a.x : a.y, horizontal ? b.x : b.y);
  return Math.min(at - lo, hi - at);
}

/** Every crossing between two routes, read off their drawn straight stretches. */
function spanCrossings(da, db) {
  const found = [];
  for (const spanA of straightSpans(da)) {
    for (const spanB of straightSpans(db)) {
      const aHorizontal = spanA[0].y === spanA[1].y;
      if (aHorizontal === (spanB[0].y === spanB[1].y)) continue;
      const [h, v] = aHorizontal ? [spanA, spanB] : [spanB, spanA];
      const x = v[0].x;
      const y = h[0].y;
      if (x <= Math.min(h[0].x, h[1].x) || x >= Math.max(h[0].x, h[1].x)) continue;
      if (y <= Math.min(v[0].y, v[1].y) || y >= Math.max(v[0].y, v[1].y)) continue;
      found.push({ at: { x, y }, horizontal: h, vertical: v });
    }
  }
  return found;
}

/**
 * Which face of which box each connector attaches to, and where along it. The face is read from the
 * direction the stroke leaves in -- a stub runs along the face normal (dd-arch.md's port rule) --
 * so this works for a port that has sunk to a rhombus's outline as well as for one on a flat face.
 */
function attachments(svg) {
  const boxes = [];
  const re = /<g class="node[^"]*" id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)"><(?:rect|circle|path|g)[^>]*?(?: x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)")?/g;
  let m;
  while ((m = re.exec(svg)) !== null) {
    if (m[6] === undefined) continue;
    boxes.push({
      id: m[1], x: Number(m[2]) + Number(m[4]), y: Number(m[3]) + Number(m[5]),
      width: Number(m[6]), height: Number(m[7]),
    });
  }
  const found = [];
  for (const path of edgePaths(svg)) {
    const line = polyline(path.d);
    for (const [point, next] of [[line[0], line[1]], [line[line.length - 1], line[line.length - 2]]]) {
      if (!next) continue;
      const side = next.y < point.y ? 'top' : next.y > point.y ? 'bottom' : next.x < point.x ? 'left' : 'right';
      for (const box of boxes) {
        if (point.x < box.x - 4 || point.x > box.x + box.width + 4) continue;
        if (point.y < box.y - 4 || point.y > box.y + box.height + 4) continue;
        const along = (side === 'top' || side === 'bottom') ? point.x : point.y;
        found.push({ box: box.id, side, along });
      }
    }
  }
  return found;
}

describe('[Render] orthogonality', () => {
  for (const source of CORPUS) {
    it(`never emits a diagonal: ${name(source)}`, () => {
      // SKILL.md §6 rule 1 -- "diagonal connectors are an automatic fail". It cannot fail here
      // because the router has no primitive that moves both coordinates, and this is what says so.
      const offAxis = [];
      for (const path of edgePaths(drawn(source).svg)) {
        for (const [p, q] of segmentsOf(polyline(path.d))) {
          if (p.x !== q.x && p.y !== q.y) offAxis.push(`${p.x},${p.y}->${q.x},${q.y}`);
        }
      }
      expect(offAxis).toEqual([]);
    });
  }

  it('uses only M, L, Q and A', () => {
    // Not cosmetic. EditorialElbowTests.straightRuns parses M, L and Q and steps over anything else
    // WITHOUT MOVING ITS CURSOR, so an H, V or C would make its axis-alignment assertion pass
    // without examining anything. `A` is safe there for one reason only, and it is a property of
    // where a bridge is allowed to be rather than of the letter: a bridge begins and ends on the
    // straight run it interrupts, so the run that parser measures across it is the same
    // axis-aligned run. The next test is what holds that.
    for (const source of CORPUS) {
      for (const path of edgePaths(drawn(source).svg)) {
        expect(path.d.replace(/[-0-9,. ]/g, '')).toMatch(/^[MLQA]*$/);
      }
    }
  });

  it('begins and ends every bridge on the run it interrupts', () => {
    for (const source of CORPUS) {
      for (const path of edgePaths(drawn(source).svg)) {
        for (const hop of bridges(path.d)) {
          expect(hop.from.x === hop.to.x || hop.from.y === hop.to.y).toBe(true);
          expect(Math.abs(hop.to.x - hop.from.x) + Math.abs(hop.to.y - hop.from.y)).toBe(2 * hop.rx);
        }
      }
    }
  });

  it('rounds every bend, with no square corner anywhere in the corpus', () => {
    // SKILL.md §6 rule 1: "every bend must be a quarter-arc". A vertex that joins two segments
    // running in different directions and has no arc between them is the hard fail, and this reads
    // the emitted `d` rather than the router's points so that a radius rounded down to nothing
    // shows up as what it draws.
    //
    // It caught three separate causes. `cornerRadius` capped the radius at a third of each
    // neighbouring run, which floors to zero at two grid units -- and two grid units is the stub
    // every route leaves its port on. A one-unit sidestep between two ports 4px apart has no
    // on-grid radius at all and is now closed in the layout (`alignUnitJog`). And a fan of seven
    // or more connectors on an 80px face packed its ports 8px apart, which made short runs
    // commonplace.
    const square = [];
    for (const source of CORPUS) {
      for (const path of edgePaths(drawn(source).svg)) {
        const commands = commandsOf(path.d);
        for (let i = 1; i + 1 < commands.length; i += 1) {
          if (commands[i][0] !== 'L') continue;
          const tail = (c) => (c[0] === 'A'
            ? { x: c[1][5], y: c[1][6] }
            : { x: c[1][c[1].length - 2], y: c[1][c[1].length - 1] });
          const head = (c) => (c[0] === 'A' ? { x: c[1][5], y: c[1][6] } : { x: c[1][0], y: c[1][1] });
          const before = tail(commands[i - 1]);
          const corner = head(commands[i]);
          const after = head(commands[i + 1]);
          const inDir = [Math.sign(corner.x - before.x), Math.sign(corner.y - before.y)];
          const outDir = [Math.sign(after.x - corner.x), Math.sign(after.y - corner.y)];
          if (!(inDir[0] || inDir[1]) || !(outDir[0] || outDir[1])) continue;
          if (inDir[0] === outDir[0] && inDir[1] === outDir[1]) continue;
          square.push(`(${corner.x},${corner.y}) in ${path.d}`);
        }
      }
    }
    expect(square).toEqual([]);
  });

  it('rounds every corner into a quarter arc of 4 or 8 px', () => {
    const radii = new Set();
    for (const source of CORPUS) {
      for (const path of edgePaths(drawn(source).svg)) {
        const commands = path.d.match(/[MLQ][^MLQ]*/g) || [];
        for (let i = 0; i < commands.length; i += 1) {
          if (commands[i][0] !== 'Q') continue;
          const before = (commands[i - 1].slice(1).match(NUMBER) || []).map(Number);
          const from = { x: before[before.length - 2], y: before[before.length - 1] };
          const n = (commands[i].slice(1).match(NUMBER) || []).map(Number);
          const corner = { x: n[0], y: n[1] };
          const to = { x: n[2], y: n[3] };
          const inLeg = Math.abs(corner.x - from.x) + Math.abs(corner.y - from.y);
          const outLeg = Math.abs(to.x - corner.x) + Math.abs(to.y - corner.y);
          // A quarter arc: equal legs, each perpendicular to the other.
          expect(inLeg).toBe(outLeg);
          expect((corner.x === from.x) !== (corner.x === to.x)).toBe(true);
          radii.add(inLeg);
        }
      }
    }
    expect([...radii].sort((a, b) => a - b)).toEqual([4, 8]);
  });

  it('never lets two arcs overrun the run between them', () => {
    // RENDERER-SPEC.md §7.2: the radius is capped at HALF of each neighbouring run. Half is the
    // exact condition -- two corners sharing a run take r each -- and an 8px run between two
    // corners therefore has no straight stretch left and reads as a rounded step. That is
    // deliberate: rule 1 calls a square corner an automatic fail and says nothing about a tight
    // step. What is NOT allowed is the arcs eating more than the run, which would put a segment
    // into reverse, so this asserts that no emitted segment doubles back.
    for (const source of CORPUS) {
      for (const path of edgePaths(drawn(source).svg)) {
        const line = polyline(path.d);
        for (let i = 0; i + 1 < line.length; i += 1) {
          const [p, q] = [line[i], line[i + 1]];
          expect(Math.abs(q.x - p.x) + Math.abs(q.y - p.y)).toBeGreaterThan(0);
          if (i + 2 < line.length) {
            const r = line[i + 2];
            // Consecutive segments turn a corner; they never reverse along one axis.
            expect(Math.sign(q.x - p.x) === -Math.sign(r.x - q.x) && q.x !== p.x).toBe(false);
            expect(Math.sign(q.y - p.y) === -Math.sign(r.y - q.y) && q.y !== p.y).toBe(false);
          }
        }
      }
    }
  });
});

describe('[Render] the 4px grid', () => {
  for (const source of CORPUS) {
    it(`puts every coordinate in the drawing on the grid: ${name(source)}`, () => {
      // Markers are excluded on purpose: their numbers are in marker space, a 8x6 box scaled by the
      // stroke width, where the grid means nothing. Everything in `g.root` is page geometry.
      const svg = drawn(source).svg;
      const body = svg.slice(svg.indexOf('<g class="root">'), svg.indexOf('<defs>'));
      const offGrid = [];
      const re = /(?:\btransform="translate\(|\b(?:x|y|width|height|rx|ry|r|cx|cy)="|\bpoints="|\bd=")([^"]*)/g;
      let m;
      while ((m = re.exec(body)) !== null) {
        // An arc's three flags -- rotation, large-arc, sweep -- are not coordinates; its rx and ry
        // are, and they stay in.
        const value = m[1].replace(/A(-?\d+),(-?\d+) \d+ [01] [01] /g, 'A$1,$2 ');
        for (const raw of value.match(NUMBER) || []) {
          if (Number(raw) % 4 !== 0) offGrid.push(`${m[0].slice(0, 12)}… ${raw}`);
        }
      }
      expect(offGrid).toEqual([]);
    });
  }

  it('reports a canvas that matches its own viewBox', () => {
    // width/height must be > 0 and equal to the viewBox or Swift turns the success into
    // .renderProducedNoSVG and a PNG export crops (MermaidRenderer.swift:502-522).
    for (const source of CORPUS) {
      const out = drawn(source);
      expect(out.svg).toContain(`viewBox="0 0 ${out.width} ${out.height}"`);
      expect(out.width).toBeGreaterThan(0);
      expect(out.height).toBeGreaterThan(0);
      expect(out.size).toEqual({ width: out.width, height: out.height });
    }
  });
});

describe('[Render] bridges at crossings', () => {
  // Sources whose routes actually cross. SKILL.md §6 rule 3 sends a crossing to dd-arch.md's
  // bridge primitive, and none of the shapes in CORPUS is what is under test here -- the crossing
  // is.
  const CROSSING = [
    'flowchart TD\n  A --> B --> C --> D\n  A --> D\n  B --> D\n  C --> A',
    'flowchart TD\n  A --> B --> C --> D --> E\n  A --> E\n  A --> D\n  B --> E',
    'flowchart TD\n  H --> A\n  H --> B\n  H --> C\n  H --> D\n  H --> E\n  A --> Z\n  B --> Z\n  C --> Z\n  D --> Z\n  E --> Z',
    'flowchart LR\n  A1 --> B1\n  A2 --> B2\n  A1 --> B2\n  A2 --> B1\n  B1 --> C\n  B2 --> C',
  ];
  const ALL = [...CORPUS, ...CROSSING];

  it('draws a bridge only where two connectors really cross', () => {
    for (const source of ALL) {
      const paths = edgePaths(drawn(source).svg);
      for (let i = 0; i < paths.length; i += 1) {
        for (const hop of bridges(paths[i].d)) {
          const crossed = paths.some((other, j) => j !== i
            && spanCrossings(paths[i].d, other.d).some((c) => c.at.x === hop.at.x && c.at.y === hop.at.y));
          expect(crossed, `bridge at ${hop.at.x},${hop.at.y} crosses nothing`).toBe(true);
        }
      }
    }
  });

  it('never bridges both sides of one crossing', () => {
    // dd-arch.md: "Never bridge both." Two bumps at one point is a knot, not a crossing.
    for (const source of ALL) {
      const paths = edgePaths(drawn(source).svg);
      for (let i = 0; i < paths.length; i += 1) {
        for (let j = i + 1; j < paths.length; j += 1) {
          for (const crossing of spanCrossings(paths[i].d, paths[j].d)) {
            const on = [paths[i], paths[j]]
              .filter((p) => bridges(p.d).some((h) => h.at.x === crossing.at.x && h.at.y === crossing.at.y));
            expect(on.length).toBeLessThanOrEqual(1);
          }
        }
      }
    }
  });

  it('gives every bridge the run it needs, and leaves a crossing plain when neither has it', () => {
    // 8px of bump each side plus a grid step of straight, measured against the stretch that is
    // DRAWN rather than corner to corner. The second half is the one that matters: a crossing with
    // no bump has to be one where neither connector had the room, or the pass is just skipping
    // work.
    let bridged = 0;
    let plain = 0;
    for (const source of ALL) {
      const paths = edgePaths(drawn(source).svg);
      for (let i = 0; i < paths.length; i += 1) {
        for (const hop of bridges(paths[i].d)) {
          const span = straightSpans(paths[i].d).find(([a, b]) => (a.y === b.y
            ? hop.at.y === a.y && hop.at.x > Math.min(a.x, b.x) && hop.at.x < Math.max(a.x, b.x)
            : hop.at.x === a.x && hop.at.y > Math.min(a.y, b.y) && hop.at.y < Math.max(a.y, b.y)));
          expect(span, `bridge at ${hop.at.x},${hop.at.y} is not on a straight run`).toBeTruthy();
          expect(clearance(span, hop.at)).toBeGreaterThanOrEqual(12);
        }
        for (let j = i + 1; j < paths.length; j += 1) {
          for (const crossing of spanCrossings(paths[i].d, paths[j].d)) {
            const on = [paths[i], paths[j]]
              .some((p) => bridges(p.d).some((h) => h.at.x === crossing.at.x && h.at.y === crossing.at.y));
            if (on) { bridged += 1; continue; }
            plain += 1;
            const room = Math.max(clearance(crossing.horizontal, crossing.at), clearance(crossing.vertical, crossing.at));
            expect(room, `crossing at ${crossing.at.x},${crossing.at.y} had ${room}px and no bridge`).toBeLessThan(12);
          }
        }
      }
    }
    expect(bridged).toBeGreaterThan(0);
    expect(plain).toBeGreaterThan(0);
  });

  it('keeps a grid step of air between every bump and every node', () => {
    // The nodes are painted after the strokes, so a crest that reaches a node's border comes back
    // with its top shaved off -- and one that stops ON the border reads as part of it. A negative
    // margin is the outline grown outwards, which is the clearance rather than the overlap.
    for (const source of ALL) {
      const out = drawn(source);
      const shapes = nodeOutlines(out.svg);
      let crests = 0;
      for (const path of edgePaths(out.svg)) {
        for (const hop of bridges(path.d)) {
          // The bump reaches 8px off the run, on the -y side of a horizontal one and the -x side of
          // a vertical one; its far edge is the part most likely to be swallowed.
          const crest = hop.from.y === hop.to.y
            ? [{ x: hop.at.x - 8, y: hop.at.y - 8 }, { x: hop.at.x + 8, y: hop.at.y - 8 }]
            : [{ x: hop.at.x - 8, y: hop.at.y - 8 }, { x: hop.at.x - 8, y: hop.at.y + 8 }];
          crests += 1;
          for (const shape of shapes) {
            expect(segmentEntersShape(crest, shape.points, -4), `crest at ${hop.at.x},${hop.at.y}`).toBe(false);
          }
        }
      }
      expect(crests).toBeGreaterThanOrEqual(0);
    }
  });

  it('bridges the less important connector: dashed under solid, normal under thick', () => {
    // dd-arch.md: "bridge the one that is less semantically important (passive, secondary,
    // write-back), or the one with lighter stroke weight (dashed, muted)". One crossing, held
    // fixed, with the weight of one of its two edges changed underneath it.
    //
    // A four-way fan-in, where `A --> Z`'s cross-line and `B --> Z`'s stub cross in the gap above Z.
    // What makes the choice between them a choice at all is that BOTH have the room a bump needs --
    // 8px of straight either side of the crossing, which is a 16px bump's own width. Measured over
    // the 300-source corpus: 4 crossings in the whole of it have that on both strokes, and this fan
    // is two of them. Most crossings can only be bridged one way round, and a fixture like that
    // asserts nothing about importance however its edges are weighted.
    //
    // The crossing is one point, so which edge carries the bump is the whole assertion: the bridged
    // path is the one that has an arc in it at all. Either way the bump is centred on that point --
    // `A --> Z` is interrupted along its horizontal there and `B --> Z` along its vertical.
    const where = (source, index) => bridges(edgePaths(drawn(source).svg)[index].d).map((h) => `${h.at.x},${h.at.y}`);
    const body = (first, second) => [
      'flowchart TD', `  A ${first} Z`, `  B ${second} Z`, '  C --> Z', '  D --> Z',
    ].join('\n');
    const AT = '204,88';

    // Nothing separates two solid edges, so the tie goes to the one declared later and the first
    // one written stays whole. A tie-break, not a judgement; the four below are the judgement.
    const solid = body('-->', '-->');
    expect(where(solid, 0)).toEqual([]);
    expect(where(solid, 1)).toEqual([AT]);

    const dashedFirst = body('-.->', '-->');
    expect(where(dashedFirst, 0)).toEqual([AT]);
    expect(where(dashedFirst, 1)).toEqual([]);

    const dashedSecond = body('-->', '-.->');
    expect(where(dashedSecond, 0)).toEqual([]);
    expect(where(dashedSecond, 1)).toEqual([AT]);

    const thickFirst = body('==>', '-->');
    expect(where(thickFirst, 0)).toEqual([]);
    expect(where(thickFirst, 1)).toEqual([AT]);

    const thickSecond = body('-->', '==>');
    expect(where(thickSecond, 0)).toEqual([AT]);
    expect(where(thickSecond, 1)).toEqual([]);
  });
});

describe('[Render] fanning a face', () => {
  const fanIn = (n) => ['flowchart TD', ...Array.from({ length: n }, (_, i) => `  N${i} --> Z[Sink]`)].join('\n');

  it('keeps SKILL.md rule 4\'s 12px between adjacent attach points', () => {
    for (const source of [...CORPUS, ...[3, 5, 7, 9, 12, 16, 24].map(fanIn)]) {
      const faces = new Map();
      for (const a of attachments(drawn(source).svg)) {
        const key = `${a.box} ${a.side}`;
        if (!faces.has(key)) faces.set(key, []);
        faces.get(key).push(a.along);
      }
      for (const [key, offsets] of faces) {
        const sorted = [...offsets].sort((p, q) => p - q);
        expect(new Set(sorted).size, `two connectors share a point on ${key}`).toBe(sorted.length);
        for (let i = 1; i < sorted.length; i += 1) {
          expect(sorted[i] - sorted[i - 1], `${key} pitch`).toBeGreaterThanOrEqual(12);
        }
      }
    }
  });

  it('widens a box only when its face runs out of room', () => {
    // The pitch is floor(L / (N + 1)), so rule 4's 12px needs a face of 12(N + 1). An 80px box
    // holds five connectors at exactly 12px and a sixth at 8px, which is where the layout starts
    // growing it -- and an 80px face has only 21 whole grid steps, so a twenty-second connector had
    // nowhere distinct to go at all. Measured widths, which are also what the arrowheads need: the
    // head is 6px across the face, so 12px of pitch leaves 6px of paper between two heads.
    const widthOf = (n) => {
      const svg = drawn(fanIn(n)).svg;
      const m = /<g class="node[^"]*" id="fp-0-flowchart-Z-\d+"[^>]*><rect class="basic label-container" x="-?\d+" y="-?\d+" width="(\d+)"/.exec(svg);
      return Number(m[1]);
    };
    expect(widthOf(3)).toBe(80);
    expect(widthOf(5)).toBe(80);
    expect(widthOf(6)).toBe(88);
    expect(widthOf(7)).toBe(96);
    expect(widthOf(22)).toBe(280);
    expect(widthOf(12)).toBe(160);
    expect(widthOf(24)).toBe(304);
  });

  it('draws an arrowhead narrower than the pitch, in user space', () => {
    // The head used to scale with the stroke; five of them fanned onto one face at 12px touched.
    // 8x6 in user space is what makes 12px enough, and this is the half of that the grid test
    // cannot see -- markers are exempt from it.
    const svg = drawn(fanIn(5)).svg;
    const marker = /<marker id="fp-0-flowchart-pointEnd"[^>]*>/.exec(svg)[0];
    expect(marker).toContain('markerWidth="8"');
    expect(marker).toContain('markerHeight="6"');
    expect(marker).toContain('markerUnits="userSpaceOnUse"');
  });
});

describe('[Render] the six connector rules', () => {
  for (const source of CORPUS) {
    it(`never runs two connectors along one another: ${name(source)}`, () => {
      // SKILL.md §6 rule 3. The router searches for a cross-line that clears every stroke already
      // drawn and says so in `warnings` when it cannot find one; nothing in this corpus needs to.
      const out = drawn(source);
      expect(out.warnings).toEqual([]);
      const routes = edgePaths(out.svg).map((p) => segmentsOf(polyline(p.d)));
      const shared = [];
      for (let i = 0; i < routes.length; i += 1) {
        for (let j = i + 1; j < routes.length; j += 1) {
          for (const a of routes[i]) {
            for (const b of routes[j]) if (runsAlong(a, b)) shared.push(`${i}/${j}`);
          }
        }
      }
      expect(shared).toEqual([]);
    });
  }

  for (const source of CORPUS) {
    it(`never passes a connector behind a box: ${name(source)}`, () => {
      // SKILL.md §6 rule 5. The shapes include the connector's own endpoints -- a stroke crossing
      // the node it starts from is the same defect seen from the other side.
      //
      // Against the emitted OUTLINE, not the bounding box, and the difference is the whole
      // geometry: a port sits on the shape's own outline, which for fourteen of the fifteen
      // geometries is inside the box, so the leg that carries it crosses that rect through canvas
      // the node does not paint. Reading the box would fail every rhombus and every cylinder for a
      // stroke the reader cannot see. The margin is one grid step, which is the most a port's sink
      // is rounded by (ports.spec.js measures it); anything deeper than that is a stroke running
      // under a fill.
      const out = drawn(source);
      const shapes = nodeOutlines(out.svg);
      const behind = [];
      for (const path of edgePaths(out.svg)) {
        for (const segment of segmentsOf(polyline(path.d))) {
          for (const shape of shapes) {
            if (segmentEntersShape(segment, shape.points, 4)) behind.push(path.d);
          }
        }
      }
      expect(behind).toEqual([]);
    });
  }

  for (const source of CORPUS) {
    it(`gives every connector its own attach point: ${name(source)}`, () => {
      // SKILL.md §6 rule 4: no two connectors may share a single point on a box.
      const points = [];
      for (const path of edgePaths(drawn(source).svg)) {
        const line = polyline(path.d);
        points.push(`${line[0].x},${line[0].y}`, `${line[line.length - 1].x},${line[line.length - 1].y}`);
      }
      expect(points.length).toBe(new Set(points).size);
    });
  }

  it('keeps a label off its own connector and out of every box', () => {
    // SKILL.md §6 rule 2 (a visible gap between mask and stroke) and rule 6 (nodes are painted
    // after labels, so a mask inside one is covered and its text becomes a fragment on a border).
    const source = CORPUS[0];
    const out = drawn(source);
    // The bounding boxes come from the same reader rule 5 uses: a shape's own emitted geometry,
    // read as geometry. Scraping the numbers out of a `d` in pairs cannot do it -- an arc's five
    // parameters are not two coordinates -- and a cylinder is what proved it.
    const boxes = nodeOutlines(out.svg).map((shape) => shape.box);
    const labels = [];
    const re = /<g class="label[^"]*" data-id="[^"]*" transform="translate\((-?\d+),(-?\d+)\)"><rect class="background" x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
    let m;
    while ((m = re.exec(out.svg)) !== null) {
      labels.push({
        x: Number(m[1]) + Number(m[3]), y: Number(m[2]) + Number(m[4]),
        width: Number(m[5]), height: Number(m[6]),
      });
    }
    expect(labels.length).toBe(2);
    for (const label of labels) {
      for (const box of boxes) {
        const hits = label.x < box.x + box.width && box.x < label.x + label.width
          && label.y < box.y + box.height && box.y < label.y + label.height;
        expect(`${label.x},${label.y} in a node: ${hits}`).toBe(`${label.x},${label.y} in a node: false`);
      }
      // The mask must clear every stroke, its own included, by the 6-10px rule 2 asks for.
      for (const path of edgePaths(out.svg)) {
        for (const [p, q] of segmentsOf(polyline(path.d))) {
          const hits = Math.max(p.x, q.x) > label.x && Math.min(p.x, q.x) < label.x + label.width
            && Math.max(p.y, q.y) > label.y && Math.min(p.y, q.y) < label.y + label.height;
          expect(`mask over a stroke: ${hits}`).toBe('mask over a stroke: false');
        }
      }
    }
  });

  for (const source of CORPUS) {
    it(`keeps every mask a visible distance from every stroke: ${name(source)}`, () => {
      // SKILL.md §6 rule 2 wants 6-10px. Everything here moves in fours, so the reachable answers
      // are 8 or nothing -- and the annotated segment sits at exactly 8 by construction.
      const out = drawn(source);
      const strokes = edgePaths(out.svg).flatMap((p) => segmentsOf(polyline(p.d)));
      const re = /<g class="label[^"]*" data-id="[^"]*" transform="translate\((-?\d+),(-?\d+)\)"><rect class="background" x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
      let m;
      while ((m = re.exec(out.svg)) !== null) {
        const box = {
          x: Number(m[1]) + Number(m[3]), y: Number(m[2]) + Number(m[4]),
          width: Number(m[5]), height: Number(m[6]),
        };
        for (const [p, q] of strokes) {
          let gap = null;
          if (p.y === q.y && Math.max(p.x, q.x) > box.x && Math.min(p.x, q.x) < box.x + box.width) {
            gap = p.y < box.y ? box.y - p.y : (p.y > box.y + box.height ? p.y - box.y - box.height : 0);
          }
          if (p.x === q.x && Math.max(p.y, q.y) > box.y && Math.min(p.y, q.y) < box.y + box.height) {
            gap = p.x < box.x ? box.x - p.x : (p.x > box.x + box.width ? p.x - box.x - box.width : 0);
          }
          if (gap === null) continue;
          expect(`${box.x},${box.y} gap ${gap >= 8}`).toBe(`${box.x},${box.y} gap true`);
        }
      }
    });
  }

  it('gives a self-loop two distinct ports and three right angles', () => {
    const svg = drawn('flowchart TD\n  A --> A\n  A --> B').svg;
    const [loop] = edgePaths(svg).filter((p) => p.d.split(' ').length > 2);
    const points = polyline(loop.d);
    expect(points[0]).not.toEqual(points[points.length - 1]);
    for (const [p, q] of segmentsOf(points)) expect(p.x === q.x || p.y === q.y).toBe(true);
  });

  it('dashes a connector it cannot route clear, rather than hiding it behind a box', () => {
    // Rule 5's declared exception, and the only route by which `fp-transit` is ever written. It
    // takes a deliberately hostile shape to reach: a self-loop on a node hemmed in on every side.
    const out = drawn('flowchart LR\n  A --> B --> C\n  B --> B\n  D --> B\n  B --> E');
    if (out.warnings.indexOf('edge-transit') !== -1) {
      expect(out.svg).toContain('fp-transit');
      expect(out.svg).toContain('.flowchart-link.fp-transit{stroke-dasharray:4,3}');
    } else {
      expect(out.svg).not.toContain('fp-transit"');
    }
  });
});

describe('[Render] determinism', () => {
  it('renders the same source to the same bytes, twice and from a fresh module', () => {
    // RENDERER-SPEC.md §5. The pooled web view keeps one JS context across renders, so anything
    // that survives a render and reaches the output is a determinism bug waiting for a second
    // diagram; requiring a fresh require() to agree is what catches module-level state.
    const fresh = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));
    for (const source of CORPUS) {
      const first = drawn(source).svg;
      expect(drawn(source).svg).toBe(first);
      expect(fresh.render({
        source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText,
      }).svg).toBe(first);
    }
  });

  it('puts the render id, and nothing else, into every id it writes', () => {
    const a = drawn(CORPUS[0], { renderID: 'fp-0' }).svg;
    const b = drawn(CORPUS[0], { renderID: 'fp-99' }).svg;
    expect(b.split('fp-99').length - 1).toBe(a.split('fp-0').length - 1);
    expect(a.replace(/fp-0/g, 'fp-99')).toBe(b);
  });

  it('does not depend on the seed', () => {
    expect(drawn(CORPUS[0], { seed: 'a' }).svg).toBe(drawn(CORPUS[0], { seed: 'b' }).svg);
  });
});

describe('[Render] what reaches the markup', () => {
  it('writes a label as character data, never as markup', () => {
    const out = drawn('flowchart TD\n  A["<b>bold</b> & <i>x</i>"] --> B["a > b"]');
    expect(out.svg).not.toContain('<b>');
    expect(out.svg).not.toContain('<i>');
    // The sanitizer unwrapped the tags and kept their text; what is left is escaped on the way out.
    // What the reader sees is the tags, as words. The sanitizer escaped them and `esc` escapes them
    // again on the way out, so the angle brackets survive as text and never as markup.
    expect(out.svg).toContain('<tspan x="0" y="4">&lt;b&gt;bold&lt;/b&gt; &amp; &lt;i&gt;x&lt;/i&gt;</tspan>');
    expect(out.svg).toContain('a &gt; b</tspan>');
  });

  it('draws a script tag as nothing, and an attribute injection as text', () => {
    const out = drawn('flowchart TD\n  A["<script>alert(1)</script>"] --> B["x&quot; onload=&quot;y"]');
    expect(out.svg).not.toContain('<script');
    // The quote that would have closed the attribute is a character reference, so what would have
    // been a new attribute is four words inside a <tspan>.
    expect(attributesOnly(out.svg)).not.toMatch(/\son[a-z]+\s*=/i);
    expect(out.svg).toContain('>x&quot; onload=&quot;y<');
  });

  it('shows an author what they typed, not what the sanitizer encoded', () => {
    // mermaid's sanitizer is an HTML serializer, so `a & b` arrives as `a &amp; b`. Painting that
    // verbatim would show five characters where one was written.
    const out = drawn('flowchart LR\n  A["a & b < c"] --> B[ok]');
    expect(out.svg).toContain('>a &amp; b &lt; c<');
  });

  it('honours <br/> as a line break and nothing else as markup', () => {
    const out = drawn('flowchart TD\n  A["one<br/>two"] --> B["three&lt;br/&gt;four"]');
    expect(out.svg).toContain('<tspan x="0" y="-4">one</tspan><tspan x="0" y="12">two</tspan>');
    expect(out.svg).toContain('three&lt;br/&gt;four');
  });

  it('emits none of the banned elements and no url() but its own markers', () => {
    const banned = ['script', 'foreignObject', 'iframe', 'object', 'embed', 'link', 'meta',
      'image', 'img', 'use', 'animate', 'animateTransform', 'animateMotion', 'set', 'a'];
    for (const source of CORPUS.concat(['flowchart TD\n  A["<img src=x onerror=alert(1)>"] --> B'])) {
      const svg = drawn(source).svg;
      for (const tag of banned) expect(svg).not.toMatch(new RegExp(`<${tag}[\\s/>]`, 'i'));
      // Text stripped first: a label may legitimately contain the word `src=`, and it is the
      // attribute names that matter.
      expect(attributesOnly(svg)).not.toMatch(/\bxlink:href=|\bhref=|\bsrc=/i);
      for (const url of svg.match(/url\([^)]*\)/g) || []) expect(url).toMatch(/^url\(#fp-0-[A-Za-z-]+\)$/);
    }
  });

  it('refuses a font stack that could close the declaration it sits in', () => {
    // The one theme value that is not a colour, and the only string interpolated straight into a
    // declaration. A `;` or a `}` in it would end the rule and open whatever came next.
    const theme = { ...EDITORIAL, fontFamily: "X;} * {display:none} .y{" };
    const out = drawn(CORPUS[0], { theme });
    expect(out.svg).toContain('font-family:sans-serif');
    expect(out.svg).not.toContain('display:none');
  });

  it('drops an at-rule that is not a block of rules, @import among them', () => {
    const theme = { ...EDITORIAL, themeCSS: '.fp-ladder{--fp-ladder:on}\n@import url(http://evil);' };
    expect(drawn(CORPUS[0], { theme }).svg).not.toContain('@import');
  });

  it('declines rather than emitting a stylesheet it would have to be scrubbed out of', () => {
    // RENDERER-SPEC.md §4.2: themeCSS is app-authored and a source cannot reach it, so a hazard
    // reaching the output means the app shipped one. Declining is honest; emitting a <style> the
    // glue's own scrub then strips from under us is not. The hazards are the glue's own list
    // (flowpeek-glue.js:22) -- an off-document url() is the one a rule body can still carry.
    const theme = { ...EDITORIAL, themeCSS: '.fp-ladder{--fp-ladder:on}\n.node rect{fill:url(http://evil)}' };
    expect(render(CORPUS[0], { theme })).toEqual({ ok: false, reason: 'unsupported:theme-css' });
  });

  it('carries exactly one <style>, as the first child of the svg', () => {
    // Asserted for all ten adversarial rows at MermaidEngineTests.swift:88-92.
    for (const source of CORPUS) {
      const svg = drawn(source).svg;
      expect(svg.split('<style>').length - 1).toBe(1);
      expect(svg.slice(svg.indexOf('>') + 1, svg.indexOf('>') + 8)).toBe('<style>');
    }
  });

  it('paints an author colour inline, where both live passes can read it', () => {
    // Not as a class: the focal-abstention rule and the label-contrast pass both detect author
    // intent by reading `style="fill:…"` off the shape (flowpeek-glue.js:702, :260-265).
    const out = drawn('flowchart TD\n  A --> B\n  style A fill:#ff0000,stroke:#000\n  classDef hot fill:#00ff00\n  class B hot');
    expect(out.svg).toContain('style="fill:#ff0000 !important;stroke:#000 !important"');
    expect(out.svg).toContain('fill:#00ff00 !important');
  });

  it('drops a declaration outside the property allowlist', () => {
    // RENDERER-SPEC.md §6.1: author declarations are validated against a property allowlist and a
    // value grammar, not escaped -- escaping keeps `expression(...)` intact and merely spells it
    // safely. Only the two that address the shape survive.
    const out = drawn('flowchart TD\n  A --> B\n  style A font-family:Comic,fill:#ff0000');
    expect(out.svg).not.toContain('font-family:Comic');
    expect(out.svg).toContain('fill:#ff0000 !important');
  });

  it('does not honour a linkStyle fill, which would wedge a solid under an elbow', () => {
    const out = drawn('flowchart TD\n  A --> B\n  linkStyle 0 stroke:#ff0000,fill:#00ff00');
    expect(out.svg).toContain('stroke:#ff0000 !important');
    expect(out.svg).not.toContain('#00ff00');
  });

  it('never lets a source name itself into the ladder', () => {
    // A classDef called `fp-focal` would take the theme's one accent from the node that earned it.
    const out = drawn('flowchart TD\n  A --> B --> C --> D\n  classDef fp-focal fill:#123456\n  class A fp-focal');
    expect(out.svg).not.toContain('class="node default fp-focal"');
  });
});

describe('[Render] the classes the editorial stylesheet paints', () => {
  // The rule that keeps one palette: emit what MacMermaidTheme.swift already selects, so a colour
  // change there reaches this renderer with no JS edit. These read the Swift source rather than a
  // copy of it, so renaming a selector on either side fails here rather than in a screenshot.
  const shapes = [
    ['flowchart TD\n  A[rect] --> B', '<rect class="basic label-container"', '.node.fp-\\(rung.token) rect.basic'],
    ['flowchart TD\n  A(round) --> B', 'rx="8"', '.node rect.basic:not([rx])'],
    ['flowchart TD\n  A{diamond} --> B', '<polygon class="label-container"', '.node.fp-\\(rung.token) polygon.label-container'],
    ['flowchart TD\n  A[(store)] --> B', '<path class="basic label-container outer-path"', '.node.fp-\\(rung.token) path.basic.label-container'],
    ['flowchart TD\n  A([stadium]) --> B', '<g class="basic label-container outer-path"', '.node.fp-\\(rung.token) g.label-container circle'],
    ['flowchart TD\n  A((circle)) --> B', '<circle class="basic label-container"', '.node.fp-\\(rung.token) circle.basic'],
  ];
  for (const [source, emitted, selector] of shapes) {
    it(`emits ${emitted.slice(0, 34)}…, which the stylesheet selects`, () => {
      expect(drawn(source).svg).toContain(emitted);
      expect(THEME_SWIFT).toContain(selector);
    });
  }

  it('paints a stadium as two paths in a group, so fill and outline stay separate elements', () => {
    // `g.outer-path path:nth-child(1)` fills and `:nth-child(2)` strokes; one element carrying both
    // would stroke the fill and double-paint the edge (MacMermaidTheme.swift, rungCSS).
    const svg = drawn('flowchart TD\n  A([stadium]) --> B').svg;
    const group = /<g class="basic label-container outer-path">(.*?)<\/g>/.exec(svg);
    expect((group[1].match(/<path /g) || []).length).toBe(2);
    expect(THEME_SWIFT).toContain('g.outer-path path:nth-child(1)');
  });

  it('tells a cylinder from a stadium by tag name, which is the whole discriminator', () => {
    // flowpeek-glue.js:697-700 reads exactly this to decide `fp-store`, and both shapes carry the
    // same classes.
    expect(drawn('flowchart TD\n  A[(db)] --> B').svg).toMatch(/<path class="basic label-container outer-path"/);
    expect(drawn('flowchart TD\n  A([pill]) --> B').svg).toMatch(/<g class="basic label-container outer-path"/);
  });

  it('writes the rung ladder the theme defines, and at most one focal', () => {
    for (const source of CORPUS) {
      const out = drawn(source);
      const rungs = (out.svg.match(/class="node default fp-([a-z]+)"/g) || [])
        .map((s) => /fp-([a-z]+)/.exec(s)[1]);
      for (const rung of rungs) expect(THEME_SWIFT).toContain(`.node.fp-\\(rung.token)`);
      expect(rungs.filter((r) => r === 'focal').length).toBeLessThanOrEqual(1);
      const total = Object.keys(out.counts.rungs)
        .filter((k) => k !== 'accent' && k !== 'cross')
        .reduce((sum, k) => sum + out.counts.rungs[k], 0);
      expect(rungs.length).toBe(total);
    }
  });

  it('gives an accent edge its own arrowhead, dropping mermaid\'s marker class', () => {
    // Per-edge arrowhead colour is the one thing CSS cannot do when every arrow shares one marker.
    const source = [
      'flowchart TD',
      '  A --> Hub', '  B --> Hub', '  C --> Hub', '  D --> Hub',
      '  Hub --> E', '  A --> B', '  A --> C',
    ].join('\n');
    const out = drawn(source);
    if (out.counts.rungs.accent > 0) {
      expect(out.svg).toContain('id="fp-0-fp-accent-head" class="fp-marker fp-marker-accent"');
      expect(out.svg).toContain('marker-end="url(#fp-0-fp-accent-head)"');
      expect(THEME_SWIFT).toContain('marker.fp-marker-accent path');
    }
    expect(out.counts.rungs.focal).toBeLessThanOrEqual(1);
  });

  it('gives a zone-crossing edge its own arrowhead too', () => {
    const out = drawn(CORPUS[CORPUS.length - 1]);
    expect(out.counts.rungs.cross).toBe(2);
    expect(out.svg).toContain('flowchart-link fp-cross"');
    expect(out.svg).toContain('id="fp-0-fp-cross-head" class="fp-marker fp-marker-cross"');
    expect(out.svg).toContain('marker-end="url(#fp-0-fp-cross-head)"');
    expect(THEME_SWIFT).toContain('marker.fp-marker-cross path');
    expect(THEME_SWIFT).toContain('.flowchart-link.fp-cross');
  });

  it('names the edge classes the theme keys its weight and pattern off', () => {
    const svg = drawn('graph TD\n  A ==> B\n  B -.-> C\n  C --> D').svg;
    expect(svg).toContain('class="edge-thickness-thick edge-pattern-solid flowchart-link"');
    expect(svg).toContain('class="edge-thickness-normal edge-pattern-dotted flowchart-link"');
    expect(THEME_SWIFT).toContain('.flowchart-link.edge-thickness-thick');
  });

  it('draws an invisible link as nothing at all', () => {
    // `~~~` asks for the layout constraint without the line; a stroke-less path would only be in
    // the way of every geometric assertion above.
    const svg = drawn('flowchart TD\n  A ~~~ B').svg;
    expect(edgePaths(svg)).toEqual([]);
  });

  it('scopes the theme stylesheet to its own root', () => {
    const svg = drawn(CORPUS[0]).svg;
    expect(svg).toContain('#fp-0 .fp-ladder{--fp-ladder: on;}');
    expect(svg).toContain('#fp-0 :root{--mermaid-font-family:');
    expect(svg).not.toMatch(/<style>[^<]*[^0-9] \.fp-ladder/);
  });

  it('keeps the arrowhead geometry EditorialArrowheadTests reads', () => {
    const svg = drawn('flowchart TD\n  A --- B').svg;
    expect(svg).toContain('<marker id="fp-0-flowchart-pointEnd" class="marker flowchart" viewBox="0 0 8 6"'
      + ' markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto" markerUnits="userSpaceOnUse">'
      + '<path d="M 0 0 L 8 3 L 0 6 z"/></marker>');
  });

  it('paints in painters order: clusters, edges, edge labels, nodes', () => {
    // `paperUnder` scans EARLIER siblings for the fill beneath a label (flowpeek-glue.js:313-345),
    // so this order is what makes a node's own fill the paper under its own label.
    const svg = drawn(CORPUS[2]).svg;
    const order = ['<g class="clusters">', '<g class="edgePaths">', '<g class="edgeLabels">', '<g class="nodes">', '<defs>'];
    const at = order.map((tag) => svg.indexOf(tag));
    expect(at).toEqual([...at].sort((a, b) => a - b));
    expect(at.every((i) => i > 0)).toBe(true);
  });
});

describe('[Render] declining', () => {
  const declines = [
    ['wrong-type', { diagramType: 'stateDiagram' }],
    ['no-measure', { measureText: undefined }],
    ['bad-render-id', { renderID: '9 bad id' }],
    ['no-source', { source: '' }],
    ['no-ladder', { theme: { ...EDITORIAL, themeCSS: '.node rect { fill: red }' } }],
    ['limit:nodes', { limits: { maxNodes: 2 } }],
    ['limit:edges', { limits: { maxEdges: 1 } }],
  ];
  for (const [reason, overrides] of declines) {
    it(`declines with ${reason}`, () => {
      const out = render(CORPUS[0], overrides);
      expect(out).toEqual({ ok: false, reason });
    });
  }

  it('declines a click rather than binding behaviour it does not own', () => {
    expect(render('flowchart TD\n  A --> B\n  click A "https://example.com"').reason)
      .toBe('unsupported:click');
  });

  it('declines an icon or an image, whose size it would get wrong', () => {
    expect(render('flowchart TD\n  A@{ shape: icon, icon: "x" } --> B').reason)
      .toBe('unsupported:asset');
  });

  it('never throws, whatever it is handed', () => {
    const hostile = [
      undefined, null, {}, { source: 42 }, { source: 'flowchart TD\n  A -->' },
      { source: 'not a diagram at all', renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText },
      { source: 'flowchart TD\n A --> B', renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: () => null },
      { source: 'flowchart TD\n A --> B', renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: () => { throw new Error('boom'); } },
    ];
    for (const input of hostile) {
      const out = flow.render(input);
      expect(out.ok === true || typeof out.reason === 'string').toBe(true);
    }
  });

  it('keeps every diagnostic anonymous', () => {
    // RENDERER-SPEC.md §4.3: what the reader is previewing never leaves the renderer.
    const secret = 'CommerciallySensitiveNodeName';
    const out = drawn(`flowchart TD\n  ${secret}[${secret}] --> B`);
    expect(JSON.stringify({ counts: out.counts, warnings: out.warnings })).not.toContain(secret);
    const declined = flow.render({ source: `flowchart TD\n  ${secret} --> B`, renderID: 'fp-0', diagramType: 'x' });
    expect(JSON.stringify(declined)).not.toContain(secret);
  });
});

describe('[Render] the zone eyebrow', () => {
  // A zone title is the one piece of text in the drawing with nowhere else to be: it names the box
  // it sits in, so it belongs at the top of that box, and a connector INTO the zone has to cross
  // that same band. The reader reported both halves of it on reelect.mmd -- a dashed connector
  // straight through the middle of "QuoteStatusChangedEvent" -- and on cand.mmd, where an edge label
  // landed on "Negotiation Quotes" as well. The route cannot move once its ports and lanes are
  // settled; the title can, along a band that is several times its own width.

  const GAP = 8;

  /** Every zone and its eyebrow, as the two rects the emitter actually wrote. */
  function eyebrows(svg) {
    const style = { fontFamily: "'Geist', sans-serif", fontSizePX: 12, fontWeight: 600, letterSpacing: '0.06em' };
    const found = [];
    const re = /<g class="cluster" id="([^"]*)"><rect x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"\/><g class="cluster-label" transform="translate\((-?\d+),(-?\d+)\)"><text text-anchor="start">(.*?)<\/text>/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      const lines = [...m[8].matchAll(/<tspan[^>]*>(.*?)<\/tspan>/g)].map((t) => t[1]);
      // The same two roundings `shapeLabel` applied: a line box is a whole number of grid units and
      // so is the widest line. Reading them back is what makes this an assertion about the drawing
      // rather than about the layout's own bookkeeping.
      const width = Math.ceil(Math.max(...lines.map((l) => measureText(l, style).width)) / 4) * 4;
      const lineHeight = Math.ceil(measureText('X', style).height / 4) * 4;
      found.push({
        id: m[1],
        zone: { x: Number(m[2]), y: Number(m[3]), width: Number(m[4]), height: Number(m[5]) },
        title: { x: Number(m[6]), y: Number(m[7]), width, height: lineHeight * lines.length },
        lines,
      });
    }
    return found;
  }

  const crosses = ([p, q], r) => Math.max(p.x, q.x) > r.x && Math.min(p.x, q.x) < r.x + r.width
    && Math.max(p.y, q.y) > r.y && Math.min(p.y, q.y) < r.y + r.height;

  const grow = (r, by) => ({ x: r.x - by, y: r.y - by, width: r.width + 2 * by, height: r.height + 2 * by });

  const REELECT = [
    'flowchart TB',
    '    OPa["Original (Hauler1)<br/>derivedQuoteId: Nego-H3"]',
    '    subgraph reelect["QuoteStatusChangedEvent 수신 후 재선정"]',
    '        N3a["Nego-H3<br/>status: Quoted<br/>isRepresentative: true"]',
    '        N2a["Nego-H2<br/>status: Requested<br/>isRepresentative: false"]',
    '        N1a["Nego-H1<br/>status: Requested<br/>isRepresentative: false"]',
    '    end',
    '    OPa -. "derivedQuoteId 갱신" .-> N3a',
  ].join('\n');

  it('leaves the eyebrow at the zone padding when nothing crosses it', () => {
    // The home position dd-arch.md asks for, and the one every zone in the corpus keeps. The slide
    // is a response to a crossing, not a new layout rule.
    const [edge] = eyebrows(drawn(CORPUS[2]).svg);
    expect(edge.lines).toEqual(['Edge tier']);
    expect(edge.title.x - edge.zone.x).toBe(16);
  });

  it('steps the eyebrow aside from a connector that would run through it', () => {
    const out = drawn(REELECT);
    const [zone] = eyebrows(out.svg);
    expect(zone.lines).toEqual(['QuoteStatusChangedEvent 수신 후 재선정']);
    // It moved, and it moved along its own band rather than out of it.
    expect(zone.title.x).toBeGreaterThan(zone.zone.x + 16);
    expect(zone.title.x + zone.title.width).toBeLessThanOrEqual(zone.zone.x + zone.zone.width - 16);
    // 8px is what §6 rule 2 asks between a stroke and the text it passes: a connector 2px from a
    // letter reads as touching it.
    const through = [];
    for (const path of edgePaths(out.svg)) {
      for (const segment of segmentsOf(polyline(path.d))) {
        if (crosses(segment, grow(zone.title, GAP))) through.push(path.id);
      }
    }
    expect(through).toEqual([]);
  });

  it('keeps an edge label off the title wherever the title ends up', () => {
    // The eyebrow is in the label set before any edge label is placed, and the rect that set holds
    // is the one the slide moves -- so a label cannot chase the title into its new position.
    const out = drawn(REELECT);
    const [zone] = eyebrows(out.svg);
    const re = /<g class="label[^"]*" data-id="[^"]*" transform="translate\((-?\d+),(-?\d+)\)"><rect class="background" x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
    let m;
    const over = [];
    while ((m = re.exec(out.svg)) !== null) {
      const r = {
        x: Number(m[1]) + Number(m[3]), y: Number(m[2]) + Number(m[4]),
        width: Number(m[5]), height: Number(m[6]),
      };
      const t = zone.title;
      if (r.x < t.x + t.width && t.x < r.x + r.width && r.y < t.y + t.height && t.y < r.y + r.height) over.push(r);
    }
    expect(over).toEqual([]);
  });
});

describe('[Render] a connector it only passes', () => {
  // The defect: in the two-subgraph drawing two long legs ran down x=100 and x=196 while the API
  // Server box spanned exactly 100..196 -- 152px of connector drawn along a border, straight over
  // its rounded corners, with no way to tell the line from a doubled outline. `hitsBox` is strict
  // on every side, so a leg ON a border reported itself clear of it, and nothing else looked.
  //
  // SKILL.md §6 rule 3 asks for 12px between two lines a reader has to trace apart, and a line and
  // a box's border are two lines. A zone's is a 0.8px hairline painted first, and the space it
  // leaves between its own edge and the boxes inside it is two stubs -- so a zone asks for the
  // stub, 8px, which is what a connector leaving a box inside one can actually give.

  const ZONE = 8;
  const NODE = 12;

  /** Every zone rect, by the id the emitter wrote. */
  function zones(svg) {
    const found = [];
    const re = /<g class="cluster" id="([^"]*)"><rect x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      found.push({
        id: m[1], x: Number(m[2]), y: Number(m[3]), width: Number(m[4]), height: Number(m[5]),
      });
    }
    return found;
  }

  /** How far a straight leg runs from the nearer of a box's two borders on its own axis, or null. */
  function clearance([p, q], box) {
    if (p.x === q.x) {
      if (Math.max(p.y, q.y) <= box.y || Math.min(p.y, q.y) >= box.y + box.height) return null;
      return Math.min(Math.abs(p.x - box.x), Math.abs(p.x - (box.x + box.width)));
    }
    if (p.y === q.y) {
      if (Math.max(p.x, q.x) <= box.x || Math.min(p.x, q.x) >= box.x + box.width) return null;
      return Math.min(Math.abs(p.y - box.y), Math.abs(p.y - (box.y + box.height)));
    }
    return null;
  }

  const TWO_SUBGRAPHS = [
    'flowchart TD',
    '  subgraph Frontend', '    W[Web App]', '    M[Mobile App]', '  end',
    '  subgraph Backend', '    API[API Server]', '    WRK[Worker]', '  end',
    '  W --> API', '  M --> WRK', '  W --> WRK', '  M --> API', '  API --> WRK',
  ].join('\n');

  for (const source of [...CORPUS, TWO_SUBGRAPHS]) {
    it(`keeps every leg clear of the borders it runs beside: ${name(source)}`, () => {
      const out = drawn(source);
      // The ids the emitter writes: `fp-0-flowchart-<node>-<index>` on a node, `fp-0-<zone>` on a
      // zone, `L_<from>_<to>_<n>` on a connector. An endpoint is excused its own box, because every
      // route leaves one by a stub and a line beside the node it is attached to is traceable
      // BECAUSE it is attached.
      const boxes = nodeOutlines(out.svg).map((shape) => ({
        id: /^fp-0-flowchart-(.*)-\d+$/.exec(shape.id)[1], box: shape.box, clear: NODE,
      }));
      const rails = zones(out.svg).map((zone) => ({
        id: zone.id.replace(/^fp-0-/, ''), box: zone, clear: ZONE,
      }));
      const tight = [];
      for (const path of edgePaths(out.svg)) {
        const ends = /^L_(.*)_(.*)_\d+$/.exec(path.id);
        for (const segment of segmentsOf(polyline(path.d))) {
          for (const { id, box, clear } of [...boxes, ...rails]) {
            if (ends && (id === ends[1] || id === ends[2])) continue;
            const gap = clearance(segment, box);
            if (gap !== null && gap < clear) tight.push(`${path.id} vs ${id}: ${gap}px`);
          }
        }
      }
      expect(tight).toEqual([]);
    });
  }
});


describe('[Render] where an edge label lands', () => {
  // The reader sent three drawings and named the same fault in all three: "negotiate(adjustRate,"
  // running into the Original box, two "originalQuoteId" masks on top of each other, a third over a
  // zone title. None of it was the placer being careless -- it scored every position it was offered
  // and took the least bad one. It was the layout, which sized the inter-rank gaps from the labels
  // and left the OTHER axis alone: in a TB drawing a label beside a vertical run needs room across
  // the rank, and nothing had reserved any.
  //
  // So these are assertions about the finished markup, at the 8px SKILL.md §6 rule 2 asks for
  // between a mask and a stroke. Measured at strict overlap they would have passed on reelect.mmd
  // while the mask ended at x=244 and the node began at x=244.

  const GAP = 8;
  const grow = (r, by) => ({ x: r.x - by, y: r.y - by, width: r.width + 2 * by, height: r.height + 2 * by });
  const hits = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width
    && a.y < b.y + b.height && b.y < a.y + a.height;

  /** Every edge label's backing rect, in the drawing's own frame. */
  function masks(svg) {
    const found = [];
    const re = /<g class="label[^"]*" data-id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)"><rect class="background" x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      found.push({
        id: m[1], x: Number(m[2]) + Number(m[4]), y: Number(m[3]) + Number(m[5]),
        width: Number(m[6]), height: Number(m[7]),
      });
    }
    return found;
  }

  /** Every node's own rect, which is what a mask may not be flush against. */
  function boxes(svg) {
    const found = [];
    const re = /<g class="node[^"]*" id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)">([\s\S]*?)<g class="label"/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      const r = /x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/.exec(m[4]);
      if (!r) continue;
      found.push({
        id: m[1], x: Number(m[2]) + Number(r[1]), y: Number(m[3]) + Number(r[2]),
        width: Number(r[3]), height: Number(r[4]),
      });
    }
    return found;
  }

  /** Every zone eyebrow's rect, measured back off the tspans the emitter wrote. */
  function titles(svg) {
    const style = { fontFamily: "'Geist', sans-serif", fontSizePX: 12, fontWeight: 600, letterSpacing: '0.06em' };
    const found = [];
    const re = /<g class="cluster-label" transform="translate\((-?\d+),(-?\d+)\)"><text[^>]*>(.*?)<\/text>/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      const lines = [...m[3].matchAll(/<tspan[^>]*>(.*?)<\/tspan>/g)].map((t) => t[1]);
      found.push({
        x: Number(m[1]), y: Number(m[2]),
        width: Math.ceil(Math.max(...lines.map((l) => measureText(l, style).width)) / 4) * 4,
        height: Math.ceil(measureText('X', style).height / 4) * 4 * lines.length,
      });
    }
    return found;
  }

  const NEGO = [
    'flowchart TB',
    '    subgraph tpt["요청 시점 자동 네고 (TPT) — Original별로 네고 하나씩"]',
    '        OT2["Original (TPT, Hauler2)<br/>isRepresentative: false"]',
    '        NT2["Negotiation<br/>isRepresentative: true<br/>derivedQuoteId: (없음)"]',
    '        OT3["Original (TPT, Hauler3)<br/>isRepresentative: false"]',
    '        NT3["Negotiation<br/>isRepresentative: true<br/>derivedQuoteId: (없음)"]',
    '        OT2 -- "negotiate(0, self)" --> NT2',
    '        OT3 -- "negotiate(0, self)" --> NT3',
    '    end',
    '    subgraph am["AM 네고 요청 (PT · VPT) — Original 하나 아래에서 경쟁"]',
    '        OP["Original (Hauler1)<br/>isRepresentative: true"]',
    '        C2["Candidate-H2<br/>isDiscarded: true"]',
    '        C3["Candidate-H3<br/>isDiscarded: true"]',
    '        N2["Nego-H2 = negotiatedQuotes[0]<br/>isRepresentative: true"]',
    '        N3["Nego-H3<br/>isRepresentative: false"]',
    '        N1["Nego-H1<br/>isRepresentative: false"]',
    '        C2 -- "negotiate(adjustRate, original)" --> N2',
    '        C3 -- "negotiate(adjustRate, original)" --> N3',
    '        OP -- "negotiate(adjustRate, self)" --> N1',
    '        OP -. "derivedQuoteId" .-> N2',
    '    end',
  ].join('\n');

  const CAND = [
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

  const REPORTED = [['nego', NEGO], ['cand', CAND]];
  const LABELLED = [
    'flowchart TD\n  A[Alpha] -->|publishes an event| B[Beta] -->|writes through| C[Gamma]',
    'flowchart TD\n  H{Hub} -->|route one| A\n  H -->|route two| B\n  H -->|route three| C',
    'flowchart TD\n  N0 -->|settled| Z[Sink]\n  N1 -->|settled| Z\n  N2 -->|settled| Z',
    'flowchart LR\n  A[Alpha] -->|publishes an event| B[Beta]\n  C[Gamma] --> D[Delta]',
    'flowchart BT\n  A[Start] -->|first| B{Is it ready?}\n  B -->|yes| C[(Store)]\n  B -->|no| D((Retry))',
    ['flowchart RL', '  subgraph z["A zone"]', '    P[One] -->|carries a long note| Q[Two]', '  end',
      '  Q -->|and another long note| R[Three]'].join('\n'),
  ];
  const ALL = [...CORPUS, ...LABELLED, ...REPORTED.map(([, src]) => src)];

  it('keeps every mask inside the drawing', () => {
    // The plainest failure of the old layout and the one with nothing to argue about: a label
    // outside the viewBox is clipped and the author's word is gone. There were 8 of them.
    const outside = [];
    for (const source of ALL) {
      const out = drawn(source);
      for (const mask of masks(out.svg)) {
        if (mask.x < 0 || mask.y < 0 || mask.x + mask.width > out.width || mask.y + mask.height > out.height) {
          outside.push(`${name(source)} / ${mask.id}`);
        }
      }
    }
    expect(outside).toEqual([]);
  });

  it('keeps every mask 8px clear of every node, zone title and other mask', () => {
    // One assertion for the three things a mask may not be sharing its place with, because the
    // reader reported all three on one drawing and a separate test for each would let two of them
    // pass while the third failed on the same label. 41 of 88 masks were within this of a node.
    const tight = [];
    for (const source of ALL) {
      const out = drawn(source);
      const found = masks(out.svg);
      const near = found.map((mask) => grow(mask, GAP));
      for (let i = 0; i < found.length; i += 1) {
        for (const box of boxes(out.svg)) {
          if (hits(near[i], box)) tight.push(`${name(source)} / ${found[i].id} vs node ${box.id}`);
        }
        for (const title of titles(out.svg)) {
          if (hits(near[i], title)) tight.push(`${name(source)} / ${found[i].id} vs a zone title`);
        }
        for (let j = i + 1; j < found.length; j += 1) {
          if (hits(near[i], found[j])) tight.push(`${name(source)} / ${found[i].id} vs ${found[j].id}`);
        }
      }
    }
    expect(tight).toEqual([]);
  });

  it('counts the masks it is checking, so an empty pass cannot pass', () => {
    // The assertions above are all "nothing is wrong", which a reader that found no labels at all
    // would satisfy. This is the count they are actually made over: 33 masks at the time of
    // writing, 15 of them on the two reported drawings.
    let counted = 0;
    for (const source of ALL) counted += masks(drawn(source).svg).length;
    expect(counted).toBeGreaterThanOrEqual(30);
  });

  it('stacks the labels of connectors that share one corridor, on the reported drawing', () => {
    // cand.mmd: five labelled connectors between one node and one zone, every one of them running
    // straight down the gap between them. `assignPorts` fans the five ports across the narrower
    // face, 28px apart against labels 128 to 168px wide, so side by side was never available --
    // the gap is what had to grow, and the five masks come out at five different heights.
    const out = drawn(CAND);
    const rising = masks(out.svg).filter((m) => /_O_|_O_0$|_N\d_O_/.test(m.id)).map((m) => m.y);
    expect(rising.length).toBeGreaterThanOrEqual(5);
    expect(new Set(rising).size).toBe(rising.length);
  });

  it('spaces two lanes of one gap far enough apart to write on both', () => {
    // The lane pitch is SKILL.md §6 rule 3's 12px, which is what two strokes need and not what a
    // label between them needs. `H -->|route one| A / |route two| B / |route three| C` drew its
    // three labels at one height because of it.
    const out = drawn('flowchart TD\n  H{Hub} -->|route one| A\n  H -->|route two| B\n  H -->|route three| C');
    const ys = masks(out.svg).map((m) => m.y + m.height / 2);
    expect(ys.length).toBe(3);
    const lanes = [...new Set(edgePaths(out.svg)
      .flatMap((p) => segmentsOf(polyline(p.d)))
      .filter(([a, b]) => a.y === b.y)
      .map(([a]) => a.y))];
    expect(lanes.length).toBeGreaterThan(0);
    for (const lane of lanes) {
      for (const mask of masks(out.svg)) {
        // >= and not >: the label that annotates a lane sits at exactly the gap, by
        // construction. Grazing the margin is the one placement allowed to be that close.
        const clear = mask.y >= lane + GAP || mask.y + mask.height <= lane - GAP;
        expect(`lane ${lane} vs ${mask.id}: ${clear}`).toBe(`lane ${lane} vs ${mask.id}: true`);
      }
    }
  });
});

describe('[Render] which connector a label belongs to', () => {
  // Reserving room stops labels landing on each other. It does not tell the reader whose label is
  // whose. On nego.mmd both halves of that failed at once: "negotiate(adjustRate, self)" sat 84px
  // to the left of the stroke it names and 8px from a different one, and the reader could not tell
  // which line either label went with. The mask is 152px wide because the author wrote thirty
  // characters where SKILL.md §6 asks for fourteen, and beside a vertical run a mask that wide puts
  // its own middle further from its own line than the next lane is.
  //
  // So ownership is scored, and where beside cannot be owned the mask sits ON the run instead --
  // the line enters one edge of it and leaves the opposite edge, which is what mermaid does on all
  // three of the drawings the reader sent us alongside ours.
  //
  // Scored as a MARGIN. The first cut of this block scored it as a verdict -- some rival is at
  // least as near, or it is not -- and measured from the mask's MIDDLE, and it left the reader's
  // own case passing: on cand.mmd the mask naming the solid O -> N1 edge had its own line nearer
  // its middle and a dotted edge touching its plate. Both halves of that are corrected below: the
  // measurement is taken from the plate, and what it yields is a number the placer can improve
  // rather than a pass mark it can reach and stop at.

  const GAP = 8;
  const grow = (r, by) => ({ x: r.x - by, y: r.y - by, width: r.width + 2 * by, height: r.height + 2 * by });
  const hits = (a, b) => a.x < b.x + b.width && b.x < a.x + a.width
    && a.y < b.y + b.height && b.y < a.y + a.height;
  const crosses = ([p, q], r) => Math.max(p.x, q.x) > r.x && Math.min(p.x, q.x) < r.x + r.width
    && Math.max(p.y, q.y) > r.y && Math.min(p.y, q.y) < r.y + r.height;

  function masks(svg) {
    const found = [];
    const re = /<g class="label[^"]*" data-id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)"><rect class="background" x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      found.push({
        id: m[1], cx: Number(m[2]), cy: Number(m[3]),
        x: Number(m[2]) + Number(m[4]), y: Number(m[3]) + Number(m[5]),
        width: Number(m[6]), height: Number(m[7]),
      });
    }
    return found;
  }

  function boxes(svg) {
    const found = [];
    const re = /<g class="node[^"]*" id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)">([\s\S]*?)<g class="label"/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      const r = /x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/.exec(m[4]);
      if (!r) continue;
      found.push({
        id: m[1], x: Number(m[2]) + Number(r[1]), y: Number(m[3]) + Number(r[2]),
        width: Number(r[3]), height: Number(r[4]),
      });
    }
    return found;
  }

  /** Every zone: its rect, and its eyebrow's rect measured back off the tspans that were written. */
  function zones(svg) {
    const style = { fontFamily: "'Geist', sans-serif", fontSizePX: 12, fontWeight: 600, letterSpacing: '0.06em' };
    const found = [];
    const re = /<g class="cluster" id="([^"]*)"><rect x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"\/>([\s\S]*?)<\/g>/g;
    let m;
    while ((m = re.exec(svg)) !== null) {
      const zone = { x: Number(m[2]), y: Number(m[3]), width: Number(m[4]), height: Number(m[5]) };
      const t = /<g class="cluster-label" transform="translate\((-?\d+),(-?\d+)\)"><text[^>]*>([\s\S]*?)<\/text>/.exec(m[6]);
      let title = null;
      if (t) {
        const lines = [...t[3].matchAll(/<tspan[^>]*>(.*?)<\/tspan>/g)].map((x) => x[1]);
        title = {
          x: Number(t[1]), y: Number(t[2]),
          width: Math.ceil(Math.max(...lines.map((l) => measureText(l, style).width)) / 4) * 4,
          height: Math.ceil(measureText('X', style).height / 4) * 4 * lines.length,
        };
      }
      found.push({ id: m[1], zone, title });
    }
    return found;
  }

  /** The four walls of a rect, as segments. A zone is drawn as an outline, not as a fill. */
  function walls(r) {
    const a = { x: r.x, y: r.y };
    const b = { x: r.x + r.width, y: r.y };
    const c = { x: r.x + r.width, y: r.y + r.height };
    const d = { x: r.x, y: r.y + r.height };
    return [[a, b], [b, c], [c, d], [d, a]];
  }

  function pointToSegment(x, y, [p, q]) {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const len = dx * dx + dy * dy;
    const t = len === 0 ? 0 : Math.max(0, Math.min(1, ((x - p.x) * dx + (y - p.y) * dy) / len));
    return Math.hypot(x - (p.x + t * dx), y - (p.y + t * dy));
  }

  const distanceTo = (mask, d) => Math.min(...segmentsOf(polyline(d)).map((s) => pointToSegment(mask.cx, mask.cy, s)));

  /**
   * The corner-to-corner runs of a route, with collinear pieces joined. `polyline` splits a run
   * at every arc control point, so the 64px stretch a label sits on arrives as a 56px piece and an
   * 8px one, and a question about how much stroke shows past a mask would be answered about the
   * wrong length.
   */
  function runsOf(d) {
    const out = [];
    for (const [p, q] of segmentsOf(polyline(d))) {
      const last = out[out.length - 1];
      if (last && ((last[0].x === last[1].x && p.x === q.x && p.x === last[0].x)
        || (last[0].y === last[1].y && p.y === q.y && p.y === last[0].y))) {
        last[1] = q;
        continue;
      }
      out.push([p, q]);
    }
    return out;
  }

  /**
   * Does this leg run THROUGH the mask -- in one edge and out of the opposite one? That is the
   * on-the-line placement, and it is a different thing from a leg that clips a corner of a mask
   * standing beside some other part of the same route.
   */
  function runsThrough([p, q], mask) {
    if (p.y === q.y) {
      return p.y > mask.y && p.y < mask.y + mask.height
        && Math.min(p.x, q.x) <= mask.x && Math.max(p.x, q.x) >= mask.x + mask.width;
    }
    return p.x > mask.x && p.x < mask.x + mask.width
      && Math.min(p.y, q.y) <= mask.y && Math.max(p.y, q.y) >= mask.y + mask.height;
  }

  const sitsOn = (mask, d) => runsOf(d).some((leg) => runsThrough(leg, mask));

  const REELECT = [
    'flowchart TB',
    '    OPa["Original (Hauler1)<br/>derivedQuoteId: Nego-H3"]',
    '    subgraph reelect["QuoteStatusChangedEvent 수신 후 재선정"]',
    '        N3a["Nego-H3<br/>status: Quoted<br/>isRepresentative: true"]',
    '        N2a["Nego-H2<br/>status: Requested<br/>isRepresentative: false"]',
    '        N1a["Nego-H1<br/>status: Requested<br/>isRepresentative: false"]',
    '    end',
    '    OPa -. "derivedQuoteId 갱신" .-> N3a',
  ].join('\n');

  const NEGO = [
    'flowchart TB',
    '    subgraph tpt["요청 시점 자동 네고 (TPT) — Original별로 네고 하나씩"]',
    '        OT2["Original (TPT, Hauler2)<br/>isRepresentative: false"]',
    '        NT2["Negotiation<br/>isRepresentative: true<br/>derivedQuoteId: (없음)"]',
    '        OT3["Original (TPT, Hauler3)<br/>isRepresentative: false"]',
    '        NT3["Negotiation<br/>isRepresentative: true<br/>derivedQuoteId: (없음)"]',
    '        OT2 -- "negotiate(0, self)" --> NT2',
    '        OT3 -- "negotiate(0, self)" --> NT3',
    '    end',
    '    subgraph am["AM 네고 요청 (PT · VPT) — Original 하나 아래에서 경쟁"]',
    '        OP["Original (Hauler1)<br/>isRepresentative: true"]',
    '        C2["Candidate-H2<br/>isDiscarded: true"]',
    '        C3["Candidate-H3<br/>isDiscarded: true"]',
    '        N2["Nego-H2 = negotiatedQuotes[0]<br/>isRepresentative: true"]',
    '        N3["Nego-H3<br/>isRepresentative: false"]',
    '        N1["Nego-H1<br/>isRepresentative: false"]',
    '        C2 -- "negotiate(adjustRate, original)" --> N2',
    '        C3 -- "negotiate(adjustRate, original)" --> N3',
    '        OP -- "negotiate(adjustRate, self)" --> N1',
    '        OP -. "derivedQuoteId" .-> N2',
    '    end',
  ].join('\n');

  const CAND = [
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

  const LONG = 'negotiate(adjustRate, original)';

  /** The label-heavy families: many labelled edges in one place, and labels longer than their runs. */
  const CROWDED = [];
  for (const dir of ['TD', 'LR', 'BT', 'RL']) {
    CROWDED.push(
      `flowchart ${dir}\n  H[Hub] -- "${LONG}" --> A[One]\n  H -- "${LONG}" --> B[Two]\n  H -- "${LONG}" --> C[Three]`,
      `flowchart ${dir}\n  A[One] -- "${LONG}" --> Z[Sink]\n  B[Two] -- "${LONG}" --> Z\n  C[Three] -- "${LONG}" --> Z`,
      `flowchart ${dir}\n  A -- "${LONG}" --> B\n  B -- "${LONG}" --> C\n  C -- "${LONG}" --> A`,
      [`flowchart ${dir}`,
        '  subgraph one["Zone one with a long name"]', '   A1[Alpha] --> A2[Beta]', '  end',
        '  subgraph two["Zone two with a long name"]', '   B1[Gamma] --> B2[Delta]', '  end',
        `  A1 -- "${LONG}" --> B1`, `  A2 -- "${LONG}" --> B2`,
        '  B2 -. "originalQuoteId" .-> A1', '  B1 -. "discardedQuoteId" .-> A2'].join('\n'),
      [`flowchart ${dir}`,
        '  subgraph s1["Left"]', '   L1[L1]', '   L2[L2]', '   L3[L3]', '  end',
        '  subgraph s2["Right"]', '   R1[R1]', '   R2[R2]', '   R3[R3]', '  end',
        '  L1 -- "alpha route" --> R1', '  L1 -- "beta route" --> R2', '  L2 -- "gamma route" --> R2',
        '  L2 -- "delta route" --> R3', '  L3 -- "epsilon route" --> R1', '  L3 -- "zeta route" --> R3',
        '  R1 -. "back one" .-> L3', '  R3 -. "back two" .-> L1'].join('\n'),
      [`flowchart ${dir}`, '  X[Outside]',
        '  subgraph z["A subgraph title long enough to fill its band"]', '   I1[Inner one]', '   I2[Inner two]', '  end',
        '  X -- "crosses the wall" --> I1', '  X -- "also crosses" --> I2', '  I2 -. "returns" .-> X'].join('\n'),
      `flowchart ${dir}\n  A1 -->|one| B1\n  A1 -->|two| B2\n  A2 -->|three| B1\n  A2 -->|four| B2\n  B1 -->|five| C1\n  B2 -->|six| C1`,
      `flowchart ${dir}\n  P[Source] -- "derivedQuoteId (representative)" --> Q[Target]\n  P -. "originalQuoteId" .-> Q`,
    );
  }

  const REPORTED = [['nego', NEGO], ['reelect', REELECT], ['cand', CAND]];
  const ALL = [...CORPUS, ...CROWDED, ...REPORTED.map(([, source]) => source)];

  it('draws enough labels for the assertions below to mean anything', () => {
    // Every property here is "nothing collides", which a reader that found no masks would satisfy.
    // 148 masks over 47 sources at the time of writing, 16 of them on the three reported drawings.
    let counted = 0;
    for (const source of ALL) counted += masks(drawn(source).svg).length;
    expect(counted).toBeGreaterThanOrEqual(148);
    let reported = 0;
    for (const [, source] of REPORTED) reported += masks(drawn(source).svg).length;
    expect(reported).toBe(16);
  });

  it('never lets one mask touch another, on any source in the corpus', () => {
    // Strict intersection, not the 8px margin the sibling block asserts: that one is the taste rule
    // and this one is the floor under it. Two masks that intersect make both words unreadable, and
    // the weight the placer gives that now sits above standing too close to a node -- which is the
    // trade it actually had to make on `P -- "..." --> Q / P -. "..." .-> Q`, where it had taken a
    // position that buried one label under the other.
    const stacked = [];
    for (const source of ALL) {
      const found = masks(drawn(source).svg);
      for (let i = 0; i < found.length; i += 1) {
        for (let j = i + 1; j < found.length; j += 1) {
          if (hits(found[i], found[j])) stacked.push(`${name(source)} / ${found[i].id} vs ${found[j].id}`);
        }
      }
    }
    expect(stacked).toEqual([]);
  });

  it('never lets a mask touch a node or a zone title, on any source in the corpus', () => {
    const touching = [];
    for (const source of ALL) {
      const svg = drawn(source).svg;
      for (const mask of masks(svg)) {
        for (const box of boxes(svg)) if (hits(mask, box)) touching.push(`${name(source)} / ${mask.id} vs node ${box.id}`);
        for (const z of zones(svg)) {
          if (z.title && hits(mask, z.title)) touching.push(`${name(source)} / ${mask.id} vs title of ${z.id}`);
        }
      }
    }
    expect(touching).toEqual([]);
  });

  it('never lets a mask sit on a zone wall', () => {
    // A zone is an outline and the masks are painted over it, so a mask straddling a wall erases
    // the stretch of border it covers: the box stops being a box at exactly the place a label drew
    // the eye to. Inside is fine and outside is fine -- rule 6 allows a mask over a zone, because
    // the zone's fill is painted first. It is the wall that is not allowed. Five masks over the
    // corpus were on one, `Q -->|and another long note| R` among them.
    const astride = [];
    for (const source of ALL) {
      const svg = drawn(source).svg;
      for (const mask of masks(svg)) {
        for (const z of zones(svg)) {
          if (walls(z.zone).some((w) => crosses(w, mask))) astride.push(`${name(source)} / ${mask.id} on ${z.id}`);
        }
      }
    }
    expect(astride).toEqual([]);
  });

  /**
   * How near a mask's PLATE comes to one stroke, signed: positive is the gap between them, and
   * where the stroke runs UNDER the plate it is minus the length the plate covers plus how far the
   * stroke runs from the nearest parallel edge of it.
   *
   * The plate rather than the middle, because the plate is what a reader sees: on cand.mmd the
   * mask the reader complained about -- "negotiate(adjustRate, original)", naming the solid
   * O -> N1 edge -- had its own line 96px from its middle and a dotted N2 -> O edge 104px from it,
   * so by the middle it was correctly owned, and its plate touched both at 8px. A middle 8px nearer
   * decides nothing across a plate 176px wide.
   *
   * Signed rather than clamped at zero, because half the corpus sits on its own line and zero is
   * not an answer there: a mask centred on its run has its own stroke at 0 and so has every foreign
   * stroke that crosses it. Under the plate the two facts a reader actually has are how much of the
   * stroke went under it and how near the middle it ran, and both terms are needed -- covered
   * length alone ties two parallel runs 12px apart, and distance-from-the-edge alone calls a 40px
   * vertical crossing of a 136x40 plate a deeper claim than the 136px horizontal it is sitting on.
   */
  function plateToSegment(mask, [p, q]) {
    const loX = Math.min(p.x, q.x);
    const hiX = Math.max(p.x, q.x);
    const loY = Math.min(p.y, q.y);
    const hiY = Math.max(p.y, q.y);
    const gx = Math.max(0, Math.max(mask.x - hiX, loX - (mask.x + mask.width)));
    const gy = Math.max(0, Math.max(mask.y - hiY, loY - (mask.y + mask.height)));
    if (gx > 0 || gy > 0) return Math.hypot(gx, gy);
    let covered;
    let depth;
    if (p.y === q.y) {
      covered = Math.min(hiX, mask.x + mask.width) - Math.max(loX, mask.x);
      depth = Math.min(p.y - mask.y, mask.y + mask.height - p.y);
    } else if (p.x === q.x) {
      covered = Math.min(hiY, mask.y + mask.height) - Math.max(loY, mask.y);
      depth = Math.min(p.x - mask.x, mask.x + mask.width - p.x);
    } else {
      return 0;
    }
    return -(Math.max(0, covered) + Math.max(0, depth));
  }

  const plateTo = (mask, d) => Math.min(...segmentsOf(polyline(d)).map((s) => plateToSegment(mask, s)));

  /** Every mask, with how near its own connector is and how near the nearest one that is not. */
  function ownership(source) {
    const svg = drawn(source).svg;
    const paths = edgePaths(svg);
    const out = [];
    for (const mask of masks(svg)) {
      const own = paths.find((p) => p.id === mask.id);
      if (!own) continue;
      let rival = Infinity;
      let who = null;
      for (const other of paths) {
        if (other.id === mask.id) continue;
        const d = plateTo(mask, other.d);
        if (d < rival) { rival = d; who = other.id; }
      }
      if (rival === Infinity) continue;
      out.push({ id: mask.id, mine: plateTo(mask, own.d), rival, who });
    }
    return out;
  }

  it('puts every mask nearer its own connector than any other, with nothing excused', () => {
    // The reader's complaint in one line, and the property this whole block exists for: you can
    // tell which line a label names without tracing it, because it is the nearest one to the plate.
    //
    // Before this pass, measured exactly this way: 29 of the 147 masks here that have a rival at
    // all stood no nearer their own connector than some other, 20 of them at an exact tie and 9
    // nearer a foreign line than their own, the worst by 64px. On cand.mmd the mask naming the
    // solid O -> N1 edge tied with a dotted edge running the other way, and the sentence read
    // backwards.
    //
    // No known-failure list. The two this test used to excuse -- `P -- "..." --> Q` with a second
    // labelled edge between the same pair -- were not the placer's to fix and are not fixed by the
    // placer: the layout now keeps room on BOTH sides of a face that carries two labelled runs, so
    // one mask goes left of the pair and one right of it, at 8px and 20px each.
    const orphans = [];
    for (const source of ALL) {
      for (const m of ownership(source)) {
        if (m.rival <= m.mine) orphans.push(`${name(source)} / ${m.id} vs ${m.who}: ${m.mine} and ${m.rival}`);
      }
    }
    expect(orphans).toEqual([]);
  });

  it('wins by a margin the eye can use, and names the four it does not', () => {
    // "Nearest" is not the promise; "clearly nearest" is. The margin is 12px, one and a half times
    // the gap rule 2 puts between a mask and its stroke -- a mask beside its line stands 8px off
    // it, so a rival 12px further away is at 20, and the line it belongs to is the near one by half
    // again. Swept at 8, 12, 16, 24 and 32: the corpus floor is 4px at all five, and what moves is
    // the reader's three drawings, which reach 8px at a target of 8, 12px at 12 and at 16, and
    // fall back to 4px at 24 and 32 where the target stops being reachable.
    //
    // 143 of 147 reach it. The four that do not are all margin 4 and all the same shape: a plate
    // lying over two long parallel runs of the drawing that are 4px apart, where the only thing
    // separating its own stroke from the other is 4px more of it being covered. Placement cannot
    // separate two lines 4px apart -- rule 3 asks for 12 between lanes and these are legs of two
    // routes that meet outside any gap, so nothing reserved a pitch for them.
    //
    // They could be bought. Running the ownership weight up until all 147 reach 12 was measured:
    // it puts 2 masks INSIDE a node, where the node's fill is painted over them and the author's
    // word is gone, and 4 astride a zone border. A label you cannot attribute is worse than one
    // that stands close to a box and better than one that is not there, which is where the weight
    // sits.
    const SHORT = [
      '"flowchart LR" (11 lines) / L_A2_B2_0',
      '"flowchart LR" (11 lines) / L_B2_A1_0',
      '"flowchart RL" (11 lines) / L_A2_B2_0',
      '"flowchart RL" (11 lines) / L_B2_A1_0',
    ];
    const MARGIN = 12;
    const short = [];
    for (const source of ALL) {
      for (const m of ownership(source)) {
        if (m.rival - m.mine < MARGIN) short.push(`${name(source)} / ${m.id}`);
      }
    }
    expect(short.sort()).toEqual(SHORT.slice().sort());
  });

  it('puts every mask nearer its own connector by its middle too', () => {
    // The plate is what the reader sees and the middle is where the words are, and the two
    // measurements are not the same question: a mask can be attached to its own line by its plate
    // and have its text leaning over somebody else's. This used to excuse two masks and now excuses
    // none: the two it excused were the `P -> Q` pair, and the room the layout now keeps on both
    // sides of a doubly-labelled face is what took them off the list.
    const orphans = [];
    for (const source of ALL) {
      const svg = drawn(source).svg;
      const paths = edgePaths(svg);
      for (const mask of masks(svg)) {
        const own = paths.find((p) => p.id === mask.id);
        if (!own) continue;
        const mine = distanceTo(mask, own.d);
        for (const other of paths) {
          if (other.id === mask.id) continue;
          if (distanceTo(mask, other.d) < mine) orphans.push(`${name(source)} / ${mask.id} is nearer ${other.id}`);
        }
      }
    }
    expect(orphans).toEqual([]);
  });

  it('owns every label on the three drawings the reader sent, by the full margin', () => {
    // The sources of the complaint, asserted on their own rather than only inside the corpus, so a
    // regression on them cannot hide in an aggregate. 16 masks between them; every one of them is
    // at least 12px nearer its own connector than any other, which is the best margin any position
    // on those connectors offers -- checked by running the ownership weight to 100000 and reading
    // the floor back off the drawings.
    for (const [label, source] of REPORTED) {
      const found = ownership(source);
      for (const m of found) {
        expect(`${label}/${m.id}: ${m.rival - m.mine >= 12}`).toBe(`${label}/${m.id}: true`);
      }
    }
    const counted = REPORTED.reduce((n, [, source]) => n + masks(drawn(source).svg).length, 0);
    expect(counted).toBe(16);
  });

  it('leaves the stroke showing past both ends of a mask that sits on it', () => {
    // The price of the on-the-line placement, and the limit on it. A mask centred on its run hides
    // the stretch it covers, which SKILL.md §6 rule 2 forbids and which is survivable only while
    // the line comes out the other side: the reader traces it in, reads the word, and picks it up
    // again. A mask longer than its run swallows the connector whole, and then there is nothing to
    // trace -- which is what an all-on-the-line placer did to `OT2 -- "negotiate(0, self)" --> NT2`,
    // leaving an arrowhead and a 4px stub of its own arrow.
    const swallowed = [];
    for (const source of ALL) {
      const svg = drawn(source).svg;
      const paths = edgePaths(svg);
      for (const mask of masks(svg)) {
        const own = paths.find((p) => p.id === mask.id);
        if (!own) continue;
        for (const leg of runsOf(own.d)) {
          if (!runsThrough(leg, mask)) continue;
          const [p, q] = leg;
          const shows = p.y === q.y
            ? Math.min(p.x, q.x) <= mask.x - GAP && Math.max(p.x, q.x) >= mask.x + mask.width + GAP
            : Math.min(p.y, q.y) <= mask.y - GAP && Math.max(p.y, q.y) >= mask.y + mask.height + GAP;
          if (!shows) swallowed.push(`${name(source)} / ${mask.id}`);
        }
      }
    }
    expect(swallowed).toEqual([]);
  });

  it('keeps the mask beside the stroke wherever beside is legible', () => {
    // Rule 2 is still the default and this is the count that says so: sitting on the line is what
    // the placer falls back to, not what it prefers. An all-on-the-line placer -- mermaid's rule,
    // tried and rendered -- put 179 of 216 masks over a stroke and stacked 18 of them on each
    // other; this one puts 49 of 148 over a stroke and stacks none. On a drawing with nothing
    // crowding it, none at all.
    //
    // 49 and not the 44 it was: scoring ownership as a margin rather than as a verdict made the
    // line worth taking in five more places, which is the price of the block above and is paid in
    // the currency rule 2 cares about. Buying them back was swept and costs more than it saves --
    // the price of an on-the-line placement is 16 in `placeEdgeLabel`, and at 30 the share falls
    // to 48 of 148 while the reader's three drawings drop from a 12px ownership floor to 8.
    let on = 0;
    let total = 0;
    for (const source of ALL) {
      const svg = drawn(source).svg;
      const paths = edgePaths(svg);
      for (const mask of masks(svg)) {
        const own = paths.find((p) => p.id === mask.id);
        if (!own) continue;
        total += 1;
        if (sitsOn(mask, own.d)) on += 1;
      }
    }
    expect(total).toBeGreaterThanOrEqual(148);
    expect(on / total).toBeLessThan(0.35);

    const plain = drawn('flowchart TD\n  A[Start] --> B{Is it ready?}\n  B -->|yes| C[(Store)]\n  B -->|no| D((Retry))');
    const plainPaths = edgePaths(plain.svg);
    for (const mask of masks(plain.svg)) {
      const own = plainPaths.find((p) => p.id === mask.id);
      const onLine = sitsOn(mask, own.d);
      expect(`${mask.id} on its line: ${onLine}`).toBe(`${mask.id} on its line: false`);
      // And rule 2's gap where it is beside, measured against its own stroke.
      for (const leg of segmentsOf(polyline(own.d))) {
        expect(`${mask.id} vs its own stroke: ${crosses(leg, grow(mask, GAP - 1))}`)
          .toBe(`${mask.id} vs its own stroke: false`);
      }
    }
  });
});
