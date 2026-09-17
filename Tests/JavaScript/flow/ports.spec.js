// Where a connector meets the shape it is attached to.
//
// The defect this file exists for: a port was put on the BOUNDING BOX's face, which is the outline
// for two of the fifteen geometries -- the rectangle, and the subroutine that is a rectangle with
// two bars drawn inside it. A rhombus meets its bottom face at the single point of its apex, a
// stadium only between its two end radii, a cylinder only where its lid crests. So both branches of
// a rendered decision diagram left the diamond in mid-air, with daylight between the line and the
// shape it was drawn from.
//
// So nothing here asks the renderer where it thinks its outlines are. Every shape is read back out
// of the `d`, `points`, `r` or `x/y/width/height` the emitter actually wrote (outline.js) and every
// port is measured against that. A model of a diamond agrees with a port on the bounding box; the
// drawing does not, and the drawing is what a reader sees.
//
// The three properties, and they are in tension -- holding all three exactly is impossible, which
// is the interesting part:
//
//   1. The port is on the outline. Reached by sinking it INWARD ALONG THE FACE NORMAL, never
//      sideways along the face: the route's first segment leaves on that normal, so a port slid
//      sideways to a point where the outline happens to touch the box would need a diagonal to
//      reach it (SKILL.md §6 rule 1, an automatic fail).
//   2. Every coordinate is a multiple of 4 (SKILL.md §7).
//   3. Connectors sharing a face keep their own attach points, ≥12px apart (§6 rule 4).
//
// (1) and (2) cannot both be exact: an outline crosses the 4px lattice only where its slope is
// rational in the right way, and an 88x48 rhombus meets it at its four apexes and nowhere else.
// Give up (3) and every port on a face collapses onto the one apex, which rule 4 calls a hard
// fail. So the sink is rounded, and the direction is the whole decision: DEEPER, never shallower.
// A port a fraction proud of the outline draws the gap this is all about; a port a fraction inside
// it is covered, because nodes are painted after every edge. The assertions below pin both halves
// -- the port is never outside the shape, never more than one grid step inside it -- and they pin the
// rounding itself against the depth measured off the emitted path, so a sink that is one unit too
// generous fails here even though it would look right.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureText } from './measure.js';
import { distanceToOutline, insideOutline, nodeOutlines, rayDepth } from './outline.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  monoFontFamily: "'Geist Mono', ui-monospace, monospace",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

const GRID = 4;

/** Every geometry in SHAPE_GEOMETRY, written the way a source reaches it. */
const SHAPES = [
  ['rect', 'X[node]'],
  ['round', 'X(node)'],
  ['stadium', 'X([node])'],
  ['circle', 'X((node))'],
  ['doublecircle', 'X(((node)))'],
  ['ellipse', 'X(-node-)'],
  ['diamond', 'X{node}'],
  ['hexagon', 'X{{node}}'],
  ['cylinder', 'X[(node)]'],
  ['subroutine', 'X[[node]]'],
  ['lean-r', 'X[/node/]'],
  ['lean-l', 'X[\\node\\]'],
  ['trap-t', 'X[/node\\]'],
  ['trap-b', 'X[\\node/]'],
  ['odd', 'X>node]'],
];

// Three connectors in and three out, so every face carries a fan rather than one centred port --
// the centre of a face is the one offset every geometry touches, and a test that only looked there
// would pass on the bounding box. TD puts the fans on the top and bottom faces and LR on the left
// and right ones, because the rank axis is what decides which faces a ranked edge uses.
const board = (direction, syntax) => [
  `flowchart ${direction}`,
  `  T1[one] --> ${syntax}`,
  '  T2[two] --> X',
  '  T3[three] --> X',
  '  X --> B1[four]',
  '  X --> B2[five]',
  '  X --> B3[six]',
].join('\n');

const NUMBER = /-?\d+(?:\.\d+)?/g;

/** The corner-to-corner polyline of every edge, in the order the edges were laid out. */
function routes(svg) {
  const found = [];
  const re = /<path class="edge-thickness-[^"]*"[^>]*? d="([^"]*)"/g;
  let m;
  while ((m = re.exec(svg)) !== null) {
    const points = [];
    for (const command of m[1].match(/[MLQ][^MLQ]*/g) || []) {
      const n = (command.slice(1).match(NUMBER) || []).map(Number);
      if (command[0] === 'Q') points.push({ x: n[0], y: n[1] }, { x: n[2], y: n[3] });
      else points.push({ x: n[0], y: n[1] });
    }
    found.push(points);
  }
  return found;
}

const OUTWARD = {
  top: { x: 0, y: -1 },
  bottom: { x: 0, y: 1 },
  left: { x: -1, y: 0 },
  right: { x: 1, y: 0 },
};

/** The point on the bounding box's face that the port sank from. */
function facePoint(node, side, port) {
  if (side === 'top') return { x: port.x, y: node.y };
  if (side === 'bottom') return { x: port.x, y: node.y + node.height };
  if (side === 'left') return { x: node.x, y: port.y };
  return { x: node.x + node.width, y: port.y };
}

function drawing(source) {
  const db = new flow.FlowDB();
  db.clear();
  flow.parse(source, db);
  const laid = flow.layout(db, { measureText, theme: EDITORIAL });
  const out = flow.render({
    source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText,
  });
  expect(out.reason || 'ok').toBe('ok');
  const outlines = new Map(nodeOutlines(out.svg).map((shape) => [shape.id, shape]));
  const nodes = new Map(laid.nodes.map((node) => [node.id, node]));
  const paths = routes(out.svg);
  expect(paths.length).toBe(laid.edges.length);

  const ports = [];
  laid.edges.forEach((edge, index) => {
    const path = paths[index];
    for (const end of ['start', 'end']) {
      const node = nodes.get(end === 'start' ? edge.from : edge.to);
      if (!node) continue;
      ports.push({
        edge,
        end,
        port: edge[end],
        node,
        outline: outlines.get(`fp-0-${node.domId}`),
        // The two points the emitted route ends with, nearest first: where the line really is.
        drawn: end === 'start'
          ? [path[0], path[1]]
          : [path[path.length - 1], path[path.length - 2]],
      });
    }
  });
  return { laid, svg: out.svg, outlines, nodes, ports };
}

/** What the implementation should have rounded the measured depth to. */
const sunk = (depth) => GRID * Math.ceil(depth / GRID - 1e-9);

describe('[Ports] every port is on the shape, not on the box', () => {
  for (const [geometry, syntax] of SHAPES) {
    for (const direction of ['TD', 'LR']) {
      const faces = direction === 'TD' ? ['top', 'bottom'] : ['left', 'right'];
      it(`lands on the ${geometry} outline it was emitted with: ${faces.join(' and ')}`, () => {
        const out = drawing(board(direction, syntax));
        expect(out.nodes.get('X').geometry).toBe(geometry);

        const onX = out.ports.filter((p) => p.node.id === 'X');
        expect(new Set(onX.map((p) => p.port.side))).toEqual(new Set(faces));
        expect(onX.length).toBe(6);

        // The shape fills the box the ports are measured from, to the pixel. Without this the
        // sink below would be measured from a face that is not where the drawing's edge is, and a
        // shape drawn past its box would pass every assertion under it while swallowing its own
        // arrowhead. The tolerance is for the arc sampling, which is four orders under it.
        const box = out.nodes.get('X');
        const extent = out.outlines.get(`fp-0-${box.domId}`).box;
        for (const [key, want] of [['x', box.x], ['y', box.y], ['width', box.width], ['height', box.height]]) {
          expect(`${geometry} ${key} ${Math.abs(extent[key] - want) < 0.01}`).toBe(`${geometry} ${key} true`);
        }

        for (const { port, node, outline, drawn } of onX) {
          const where = `${geometry} ${port.side} ${port.x},${port.y}`;
          // The port the layout computed is the point the path was actually drawn from.
          expect(`${where} drawn at ${drawn[0].x},${drawn[0].y}`).toBe(`${where} drawn at ${port.x},${port.y}`);
          // And the segment carrying it still leaves on the face normal, which is what the sink
          // had to preserve: a port moved along the face instead would need a diagonal to reach.
          const out0 = OUTWARD[port.side];
          const step = { x: Math.sign(drawn[1].x - drawn[0].x), y: Math.sign(drawn[1].y - drawn[0].y) };
          expect(`${where} leaves ${step.x},${step.y}`).toBe(`${where} leaves ${out0.x},${out0.y}`);

          // SKILL.md §7: on the grid, both coordinates, no exceptions.
          expect(`${where} on grid ${port.x % GRID},${port.y % GRID}`).toBe(`${where} on grid 0,0`);

          // The measurement that decides it: how deep the emitted outline runs under the face the
          // port sank from, cast as a ray along that face's normal.
          const from = facePoint(node, port.side, port);
          const inward = { x: -out0.x, y: -out0.y };
          const depth = rayDepth(from, inward, outline.points);
          expect(Number.isFinite(depth)).toBe(true);
          expect(`${where} inset ${port.inset}`).toBe(`${where} inset ${sunk(depth)}`);

          // Which leaves the port on the outline: inside it or on it, never outside, and never
          // more than the one grid step the rounding is allowed to cost.
          const distance = distanceToOutline(port, outline.points);
          expect(`${where} off outline by ${distance < GRID}`).toBe(`${where} off outline by true`);
          const proud = !insideOutline(port, outline.points) && distance > 1e-9;
          expect(`${where} proud ${proud}`).toBe(`${where} proud false`);

          // And where the outline does cross the grid under a port, the sink is exact -- the
          // rounding may not spend a unit it does not need.
          if (Math.abs(depth - sunk(depth)) < 1e-9) {
            expect(`${where} exact ${distance < 1e-6}`).toBe(`${where} exact true`);
          }
        }
      });
    }
  }
});

describe('[Ports] a shape that is drawn outside its box has no outline to land on', () => {
  it('keeps a stadium inside the box its ports are measured from', () => {
    // The one geometry that could be drawn past its own box, and the port is what it cost. The cap
    // is an arc of radius min(W,H) between ends 2H apart, and SVG scales a radius too small to
    // reach both ends up until it does -- so a box taller than it is wide was drawn H-W past both
    // sides, and the port on the side face, with the arrowhead on it, sat inside the fill that is
    // painted over them. shapeBox widens the box instead; this is the check that it did.
    const out = drawing([
      'flowchart LR',
      '  A[in] --> B(["one<br/>two<br/>three<br/>four<br/>five"])',
      '  B --> C[out]',
    ].join('\n'));
    const node = out.nodes.get('B');
    const outline = out.outlines.get(`fp-0-${node.domId}`);
    const drawnWidth = `${outline.box.x},${outline.box.width}`;
    expect(drawnWidth).toBe(`${node.x},${node.width}`);
    expect(node.width).toBeGreaterThanOrEqual(node.height);
    for (const { port } of out.ports.filter((p) => p.node.id === 'B')) {
      expect(`${port.side} ${distanceToOutline(port, outline.points) < 1e-6}`).toBe(`${port.side} true`);
    }
  });
});

describe('[Ports] a fan on one face keeps rule 4', () => {
  for (const [geometry, syntax] of SHAPES) {
    for (const direction of ['TD', 'LR']) {
      it(`spreads three connectors along a ${geometry} face: ${direction}`, () => {
        // SKILL.md §6 rule 4: distinct attach points, "≥12px between adjacent points (8px minimum
        // for very small boxes)". Three ports on a face need 48px for the 12, and the one face in
        // this matrix that has not got it is the 40px side of an ellipse, which takes the floor.
        // Measured along the face, which is the axis the fan spreads on -- two ports 12px apart
        // along a slanted outline are further apart than that in the drawing, never nearer.
        const out = drawing(board(direction, syntax));
        const byFace = new Map();
        for (const entry of out.ports.filter((p) => p.node.id === 'X')) {
          const key = entry.port.side;
          if (!byFace.has(key)) byFace.set(key, []);
          byFace.get(key).push(entry.port);
        }
        expect(byFace.size).toBe(2);
        const node = out.nodes.get('X');
        for (const [side, group] of byFace) {
          expect(group.length).toBe(3);
          const vertical = side === 'top' || side === 'bottom';
          const along = (vertical ? group.map((p) => p.x) : group.map((p) => p.y)).sort((a, b) => a - b);
          const want = (vertical ? node.width : node.height) >= 48 ? 12 : 8;
          expect(`${geometry} ${side} gaps ${along[1] - along[0] >= want} ${along[2] - along[1] >= want}`)
            .toBe(`${geometry} ${side} gaps true true`);
          const points = group.map((p) => `${p.x},${p.y}`);
          expect(new Set(points).size).toBe(3);
        }
      });
    }
  }
});

describe('[Ports] what the rounding costs', () => {
  it('never rounds a port out of the shape, and never by a whole grid step', () => {
    // The numbers the renderer's own comment claims, measured here so they cannot rot silently.
    // Every port of every geometry on every face, and both halves of the compromise: how many land
    // exactly on the outline, and how far past it the rest sank. The exact count is asserted rather
    // than printed -- if port placement moves, this is where it says so, and the comment beside
    // portInset is what has to be corrected.
    let exact = 0;
    let total = 0;
    let worst = 0;
    let proud = 0;
    for (const [, syntax] of SHAPES) {
      for (const direction of ['TD', 'LR']) {
        const out = drawing(board(direction, syntax));
        for (const { port, node, outline } of out.ports) {
          const from = facePoint(node, port.side, port);
          const outward = OUTWARD[port.side];
          const depth = rayDepth(from, { x: -outward.x, y: -outward.y }, outline.points);
          total += 1;
          if (port.inset - depth < 1e-9) exact += 1;
          worst = Math.max(worst, port.inset - depth);
          if (!insideOutline(port, outline.points) && distanceToOutline(port, outline.points) > 1e-9) {
            proud += 1;
          }
        }
      }
    }
    expect(`${exact} of ${total} exact, ${proud} outside`).toBe('308 of 360 exact, 0 outside');
    expect(`deepest ${worst.toFixed(2)}px, under the grid step ${worst < GRID}`)
      .toBe('deepest 3.63px, under the grid step true');
  });
});

// --- where on the face, as opposed to how deep ------------------------------------------------
//
// Everything above is about the sink: a port on the shape's outline rather than on its bounding
// box. The blocks below are about the other half of the same question, and the two sources they
// use are the two drawings the defects were found in.
//
//   DECISION -- a Korean decision flowchart. Every connector to its rhombus attached partway along
//   a SLOPE: the arrow in landed 36px down the upper-right one and the two branches left 16px and
//   52px along the lower ones. Each of those ports was on the outline and none of them was where a
//   reader would draw one -- a vertical arrow meeting a 12.5° edge reads as a mistake. In the same
//   drawing `E --> B` ended on B's exact bounding-box corner, where the theme's CSS rounds the
//   paint to rx=6 and left the arrowhead about 2.5px outside the border.
//
//   PIPELINE -- the same architecture sample drawn LR. Both arrows into its stadium landed on the
//   tangent points of the left cap, where the painted outline runs PARALLEL to the arrow, so the
//   heads grazed the pill rather than entering it.

const DECISION = [
  'flowchart TD',
  '  A([주문 접수]) --> B[재고 확인]',
  '  B --> C{재고가 충분한가?}',
  '  C -->|충분함| D[결제 진행]',
  '  C -->|부족함| E[입고 대기 알림]',
  '  D --> F([배송 시작])',
  '  E --> B',
].join('\n');

const PIPELINE = [
  'flowchart LR',
  '  GW[API Gateway] --> AUTH[Auth Service]',
  '  GW --> ORD[Order Service]',
  '  AUTH --> DB[(Postgres)]',
  '  ORD --> DB',
  '  ORD -.-> CACHE[(Redis cache)]',
  '  DB --> DONE([Response])',
  '  CACHE -.-> DONE',
].join('\n');

const ALONG = { top: 'x', bottom: 'x', left: 'y', right: 'y' };

/** The outline's extreme point along `side`'s outward normal, and how many points share it. */
function vertexOf(outline, side) {
  const reach = (p) => (side === 'top' ? -p.y : side === 'bottom' ? p.y : side === 'left' ? -p.x : p.x);
  let best = -Infinity;
  for (const p of outline.points) best = Math.max(best, reach(p));
  const at = outline.points.filter((p) => best - reach(p) < 0.01);
  return { point: at[0], shared: at.length };
}

/** How far along its face a port sits from the end of that face. */
function cornerMargin(port, node) {
  const vertical = port.side === 'top' || port.side === 'bottom';
  const along = vertical ? port.x : port.y;
  const lo = vertical ? node.x : node.y;
  const length = vertical ? node.width : node.height;
  return Math.min(along - lo, lo + length - along);
}

/** The painted outline's direction where it passes nearest the port. */
function outlineDirectionAt(port, points) {
  let best = Infinity;
  let direction = null;
  for (let i = 0; i < points.length; i += 1) {
    const a = points[i];
    const b = points[(i + 1) % points.length];
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const len = vx * vx + vy * vy;
    if (len === 0) continue;
    let t = ((port.x - a.x) * vx + (port.y - a.y) * vy) / len;
    t = Math.max(0, Math.min(1, t));
    const away = Math.hypot(port.x - (a.x + t * vx), port.y - (a.y + t * vy));
    if (away < best) {
      best = away;
      direction = { x: vx / Math.sqrt(len), y: vy / Math.sqrt(len) };
    }
  }
  return direction;
}

/** 1 where the outline at the port runs straight along the arrow, 0 where the arrow meets it square. */
function parallelness(port, outline) {
  const normal = OUTWARD[port.side];
  const along = outlineDirectionAt(port, outline.points);
  return Math.abs(along.x * normal.x + along.y * normal.y);
}

describe('[Ports] a pointed shape attaches at its vertex', () => {
  it('lands the arrow into a rhombus on its apex, not a third of the way down the slope', () => {
    const out = drawing(DECISION);
    const arriving = out.ports.filter((p) => p.node.geometry === 'diamond' && p.end === 'end');
    expect(arriving).toHaveLength(1);
    const [{ port, outline }] = arriving;
    const vertex = vertexOf(outline, port.side);
    // One point, so "the vertex" is not a choice between two of them, and the port IS it.
    expect(`${port.side} shares ${vertex.shared}`).toBe(`${port.side} shares 1`);
    expect(`${port.side} at ${port[ALONG[port.side]]}`).toBe(`${port.side} at ${vertex.point[ALONG[port.side]]}`);
    // It was 36px along the slope from there, which is the measurement this test exists for.
    expect(port.inset).toBe(0);
  });

  it('forks the two branches around the apex at the pitch, symmetrically', () => {
    // Rule 4 will not let two connectors share the one point a pointed face offers. Rejected:
    // moving one branch to another face -- on this source the left vertex is 76px the wrong side
    // of the box that branch feeds. So they straddle the apex at the minimum pitch, 16px for an
    // even count so that the block stays symmetric about it AND on the 4px grid.
    const out = drawing(DECISION);
    const leaving = out.ports.filter((p) => p.node.geometry === 'diamond' && p.end === 'start');
    expect(leaving).toHaveLength(2);
    const axis = ALONG[leaving[0].port.side];
    const vertex = vertexOf(leaving[0].outline, leaving[0].port.side).point[axis];
    const at = leaving.map((p) => p.port[axis]).sort((a, b) => a - b);
    expect(`gap ${at[1] - at[0]}`).toBe('gap 16');
    expect(`middle ${(at[0] + at[1]) / 2}`).toBe(`middle ${vertex}`);
    // Neither may slide further down the slope towards what it connects to: both branches feed
    // boxes 40px and 60px off the apex, and both ports are still 8px from it.
    expect(at.map((v) => v - vertex)).toEqual([-8, 8]);
  });

  it('leaves a flat face to fan across it: the same drawing keeps its rectangles spread', () => {
    // The rule is about faces whose outline is a point, not about drawings that contain one. Every
    // rectangle in this source still fans on its face, at rule 4's pitch, with no port pulled to a
    // middle it had no reason to take.
    const out = drawing(DECISION);
    const faces = new Map();
    for (const entry of out.ports.filter((p) => p.node.geometry === 'rect')) {
      const key = `${entry.node.id}.${entry.port.side}`;
      if (!faces.has(key)) faces.set(key, []);
      faces.get(key).push(entry.port[ALONG[entry.port.side]]);
    }
    const shared = [...faces.entries()].filter(([, list]) => list.length > 1);
    expect(shared.length).toBeGreaterThan(0);
    for (const [key, list] of shared) {
      const sorted = [...list].sort((a, b) => a - b);
      for (let i = 1; i < sorted.length; i += 1) {
        expect(`${key} pitch ${sorted[i] - sorted[i - 1] >= 12}`).toBe(`${key} pitch true`);
      }
    }
  });
});

describe('[Ports] a port never lands where the outline turns', () => {
  for (const [label, source] of [['decision', DECISION], ['pipeline', PIPELINE]]) {
    it(`never leaves a port on an outline that runs along its own arrow: ${label}`, () => {
      // The stadium's cap and the rectangle's corner are the same fault in two shapes: the port is
      // on the box, but not on a part of the outline that faces the direction the arrow arrives
      // from. Both drawings had ports at 1.00 here -- the outline and the arrow in line.
      for (const { port, node, outline } of drawing(source).ports) {
        const parallel = parallelness(port, outline);
        expect(`${node.id}.${port.side} ${port.x},${port.y} parallel ${parallel > 0.9}`)
          .toBe(`${node.id}.${port.side} ${port.x},${port.y} parallel false`);
      }
    });

    it(`keeps every port clear of the corner its face ends at: ${label}`, () => {
      // 8px for a rectangle, whose 6px CSS radius -- `.node rect.basic:not([rx])` in
      // MacMermaidTheme.swift -- no reader of the emitted markup can see; 4px elsewhere, which is
      // what puts the 6px-wide arrowhead wholly inside the face. Both sources had ports at 0.
      for (const { port, node } of drawing(source).ports) {
        const want = node.geometry === 'rect' ? 8 : 4;
        expect(`${node.id}.${port.side} margin ${cornerMargin(port, node) >= want}`)
          .toBe(`${node.id}.${port.side} margin true`);
      }
    });
  }

  it('holds the same two rules across every geometry, on every face', () => {
    // The matrix the sink is measured on, measured again for where along the face the ports went:
    // three connectors in and three out, so no face is carrying a single centred port that would
    // pass on the bounding box.
    let worst = 0;
    let tightest = Infinity;
    for (const [geometry, syntax] of SHAPES) {
      for (const direction of ['TD', 'LR']) {
        for (const { port, node, outline } of drawing(board(direction, syntax)).ports) {
          const where = `${geometry} ${port.side} ${port.x},${port.y}`;
          const parallel = parallelness(port, outline);
          expect(`${where} parallel ${parallel > 0.9}`).toBe(`${where} parallel false`);
          worst = Math.max(worst, parallel);
          tightest = Math.min(tightest, cornerMargin(port, node));
        }
      }
    }
    // The two numbers the blocks above assert one drawing at a time, over the whole matrix.
    expect(`worst parallel ${worst.toFixed(2)}, tightest corner ${tightest}px`)
      .toBe('worst parallel 0.86, tightest corner 8px');
  });
});
