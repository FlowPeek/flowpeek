// Every arrowhead gets a shaft to sit on.
//
// The defect a reader reported, looking at the drawings rather than at the code: on some
// connectors the head is not legible as a head. `worker --> web` in the two-subgraph drawing came
// out `... L96,120 Q92,120 92,116 L92,112` -- a 4px straight under an 8px arrowhead. The head is
// `markerWidth 8` with `refX 8` at the tip (EditorialArrowheadTests pins both), so it covers the
// last 8px of the path whatever is underneath; with 4px of line there, the elbow's arc runs
// straight into the head and the two read as one bulge on the stroke.
//
// Three families produced it, all the same arithmetic and all legal under every rule the renderer
// already enforced. Measured over 300 drawings and 675 arrivals before the fix: 59 of them, 8.7%.
//   * the route's last station was one departure stub from the face (8px), and the corner took 4
//     of the 8 -- 12 arrivals, including the reported one;
//   * the gap's lane band reserved 2*STUB on each side, so the lane nearest the target sat 16px
//     off its face and the 8px corner took half -- 38 arrivals, shaft 0;
//   * a self-loop's return leg was 16px, same arithmetic -- 9 of 9 self-loops.
//
// THE NUMBER. The final straight has to be at least 16px: the 8px head, plus one head-length of
// visible shaft behind it. That makes the polyline leg 16 + the 8px corner radius = 24px, which is
// `ARRIVE` in the layout and `ARRIVE_PX` in the router. It was picked by rendering the two-subgraph
// drawing through DiagramExporter at 1x and at 2x at five settings and looking at the arrival into
// `Web app`: at 4px of straight, what shipped, the head and the elbow are one shape and the head
// reads as a barb on the horizontal run; at 12px the arc still lets go inside the head's own
// length; at 16px the head reads as head-plus-stem, the same as the straight `web --> router`
// arrival beside it; 20 and 24px add nothing and cost a further 2.4% and 4.7% of drawing area.
//
// What this file must not let the fix buy: an approach run taken out of the other end of the same
// route. A 24px arrival leg reached by moving the turn towards the node the edge LEAVES puts the
// 4px fillet against that node instead, which is the shape RENDERER-SPEC.md §7.2 and two earlier
// reviews were about. So the departure end is checked too.

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
  monoFontFamily: "'Geist Mono', ui-monospace, monospace",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

/** The arrowhead's own length, `markerWidth`, with `refX` at the tip. */
const HEAD = 8;
/** The shaft that has to show behind it: one more head-length. */
const SHAFT = 8;
/** So this much of the final straight, and `ARRIVE` is this plus the 8px corner radius. */
const RUN = HEAD + SHAFT;

function theme(overrides) {
  if (!overrides) return EDITORIAL;
  return { ...EDITORIAL, arrangement: { ...EDITORIAL.arrangement, ...overrides } };
}

function drawn(source, overrides) {
  const out = flow.render({
    source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: theme(overrides), measureText,
  });
  expect(out.reason || 'ok').toBe('ok');
  return out;
}

/** Every connector that carries an end arrowhead, as `{ id, d }`. `---` links have no head. */
function arrivals(svg) {
  const out = [];
  const re = /<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"([^>]*)\/>/g;
  let m;
  while ((m = re.exec(svg)) !== null) {
    if (!/marker-end=/.test(m[3])) continue;
    out.push({ id: m[1], d: m[2] });
  }
  return out;
}

const NUM = /-?\d+(?:\.\d+)?/g;

/**
 * The polyline the path was rounded from. A `Q`'s control point IS the corner it was cut off, so
 * reading the control points back gives the legs the router actually chose.
 */
function polyline(d) {
  const out = [];
  for (const cmd of d.match(/[MLQAZz][^MLQAZz]*/g) || []) {
    const n = (cmd.slice(1).match(NUM) || []).map(Number);
    if (cmd[0] === 'M' || cmd[0] === 'L') out.push({ x: n[0], y: n[1] });
    // the arc of a bridge hop rejoins the same leg, so its end is not a corner
    else if (cmd[0] === 'Q') { out.pop(); out.push({ x: n[0], y: n[1] }); }
  }
  return out;
}

/**
 * The last straight stretch of a path, and what precedes it.
 *
 * `run` is the drawn `L` the head sits on -- the only part of the approach a reader sees as a
 * line. `radius` is what the corner ahead of it took, 0 when the approach is straight all the way
 * from the port it left. `leg` is the polyline leg the two came out of, and `before` the leg that
 * feeds it, which is what `cornerRadius` shares the fillet with.
 */
function approach(d) {
  const cmds = d.match(/[MLQAZz][^MLQAZz]*/g) || [];
  const last = cmds[cmds.length - 1];
  const prev = cmds[cmds.length - 2];
  if (!last || !prev || last[0] !== 'L') return null;
  const n = (last.slice(1).match(NUM) || []).map(Number);
  const p = (prev.slice(1).match(NUM) || []).map(Number);
  const from = prev[0] === 'Q' ? { x: p[2], y: p[3] }
    : prev[0] === 'A' ? { x: p[5], y: p[6] }
      : { x: p[0], y: p[1] };
  const run = Math.abs(n[0] - from.x) + Math.abs(n[1] - from.y);
  const radius = prev[0] === 'Q' ? Math.abs(p[2] - p[0]) + Math.abs(p[3] - p[1]) : 0;
  const legs = polyline(d);
  const span = (i) => Math.abs(legs[i].x - legs[i - 1].x) + Math.abs(legs[i].y - legs[i - 1].y);
  return {
    run,
    radius,
    hopped: prev[0] === 'A',
    kind: prev[0],
    leg: legs.length > 1 ? span(legs.length - 1) : 0,
    before: legs.length > 2 ? span(legs.length - 2) : null,
  };
}

/**
 * Sources covering every family the measurement found, and the ones it found nothing in -- the
 * geometries whose ports sink to an outline bought their approach run by accident, from the inset,
 * and a change to the arrival constant is exactly the kind of change that could take it away again.
 */
const SHAPES = [
  'X[rect]', 'X(round)', 'X([stadium])', 'X[[subroutine]]', 'X[(cylinder)]', 'X((circle))',
  'X>odd]', 'X{rhombus}', 'X{{hexagon}}', 'X[/lean right/]', 'X[\\lean left\\]',
  'X[/trapezoid\\]', 'X[\\inv trapezoid/]', 'X(((double circle)))',
];

function corpus() {
  const out = [];
  const add = (name, source) => out.push({ name, source });
  for (const dir of ['TD', 'LR', 'BT', 'RL']) {
    SHAPES.forEach((shape) => {
      add(`shape ${shape} ${dir}`, `flowchart ${dir}\n  A[Source] --> ${shape}\n`);
      // and again with a second edge on the same face, so the port is fanned off centre
      add(`shape fan ${shape} ${dir}`,
        `flowchart ${dir}\n  A[Source] --> ${shape}\n  B[Other] --> X\n  C[Third] --> X\n`);
    });
    add(`return across subgraphs ${dir}`, [
      `flowchart ${dir}`, '  subgraph front[Frontend]', '    web[Web app] --> router[Router]', '  end',
      '  subgraph back[Backend]', '    handler[Handler] --> worker[Worker]', '  end',
      '  router --> handler', '  worker --> web',
    ].join('\n'));
    add(`back edge ${dir}`, `flowchart ${dir}\n  A --> B --> C --> D\n  D --> A\n`);
    add(`two back edges ${dir}`,
      `flowchart ${dir}\n  A[Alpha] --> B[Beta] --> C[Gamma] --> D[Delta] --> E[Epsilon]\n  E --> A\n  D --> B\n`);
    add(`rank skip ${dir}`, `flowchart ${dir}\n  A --> B --> C --> D\n  A --> D\n  B --> D\n`);
    add(`fan in ${dir}`, `flowchart ${dir}\n  N0 --> Z[Sink]\n  N1 --> Z\n  N2 --> Z\n  N3 --> Z\n  N4 --> Z\n`);
    add(`fan out ${dir}`, `flowchart ${dir}\n  H{Hub} --> A\n  H --> B\n  H --> C\n  H --> D\n`);
    add(`self loop ${dir}`, `flowchart ${dir}\n  A --> B\n  B --> B\n  B --> C\n`);
    add(`crossing ${dir}`,
      `flowchart ${dir}\n  A1 --> B1\n  A2 --> B2\n  A1 --> B2\n  A2 --> B1\n  B1 --> C\n  B2 --> C\n`);
    add(`nested subgraphs ${dir}`,
      `flowchart ${dir}\n  subgraph a\n   subgraph b\n    X --> Y\n   end\n  end\n  Y --> Z\n  Z --> X\n`);
    add(`labelled fork ${dir}`, [
      `flowchart ${dir}`, '  A[Start] -->|first| B{Is it ready?}', '  B -->|yes| C[(Store)]',
      '  B -->|no| D((Retry))', '  D --> A',
    ].join('\n'));
    add(`wide and narrow ${dir}`,
      `flowchart ${dir}\n  A[A very wide starting box indeed] --> B[b]\n  B --> C[Another extremely wide terminal box]\n`);
    add(`ladder ${dir}`, [
      `flowchart ${dir}`, '  R[Request] --> V{Valid?}', '  V -->|no| E[Reject]', '  V -->|yes| P[Process]',
      '  P --> S[(Store)]', '  S --> N[Notify]', '  N --> R', '  E --> R',
    ].join('\n'));
  }
  return out;
}

const CORPUS = corpus();

describe('the approach run an arrowhead arrives on', () => {
  it('leaves a head-length of shaft behind the head, on every arrival in every family', () => {
    const short = [];
    let counted = 0;
    for (const { name, source } of CORPUS) {
      for (const edge of arrivals(drawn(source).svg)) {
        const a = approach(edge.d);
        if (a === null) continue;
        counted += 1;
        if (a.run < RUN) short.push(`${name} / ${edge.id}: ${a.run}px of straight -- ${edge.d}`);
      }
    }
    expect(counted).toBeGreaterThan(400);
    expect(short).toEqual([]);
  });

  // The reported drawing, by name and by its exact shape, because a corpus assertion passes the
  // day somebody stops generating the case that produced the complaint.
  it('gives the reported worker --> web arrival its shaft', () => {
    const source = [
      'flowchart TD', '  subgraph front[Frontend]', '    web[Web app] --> router[Router]', '  end',
      '  subgraph back[Backend]', '    handler[Handler] --> worker[Worker]', '  end',
      '  router --> handler', '  worker --> web',
    ].join('\n');
    const edge = arrivals(drawn(source).svg).find((e) => e.id === 'L_worker_web_0');
    expect(edge).toBeTruthy();
    const a = approach(edge.d);
    // It shipped as `L96,120 Q92,120 92,116 L92,112`: a 4px run under an 8px head, and a 4px
    // fillet because the 8px leg could not pay for more.
    expect(a.run).toBeGreaterThanOrEqual(RUN);
    expect(a.radius).toBe(8);
    expect(a.leg).toBeGreaterThanOrEqual(RUN + 8);
  });

  it('gives a self-loop the same run on the way back in', () => {
    for (const dir of ['TD', 'LR']) {
      const source = `flowchart ${dir}\n  A --> B\n  B --> B\n  B --> C\n`;
      const loop = arrivals(drawn(source).svg).find((e) => e.id === 'L_B_B_0');
      expect(loop).toBeTruthy();
      expect(approach(loop.d).run).toBeGreaterThanOrEqual(RUN);
    }
  });

  // The run is not taken out of the other end of the same route, which is the way this defect is
  // easy to "fix" and hard to fix. `connect` clamps its cross-line between the two stations, so
  // pushing the arrival station back without widening the gap moves the turn towards the node the
  // edge LEAVES and the fillet that was against the target ends up against the source instead --
  // the shape RENDERER-SPEC.md §7.2 and two earlier reviews were about.
  //
  // A route that turns once between two ranks leaves its node by 16px at least, which is the run
  // an 8px fillet needs on both of its sides. Nothing below broke that before the change and
  // nothing does after it; moving the arrival station without widening the gap to match breaks it
  // 29 times in this file's own sources, at 12px and a 4px fillet. A bridge hop is not a turn, so a
  // path carrying one is not one of these routes.
  it('does not pay for the run at the end the route leaves by', () => {
    const tight = [];
    for (const { name, source } of CORPUS) {
      for (const edge of arrivals(drawn(source).svg)) {
        if (/A/.test(edge.d)) continue;
        const bends = polyline(edge.d);
        if (bends.length !== 4) continue;
        const first = Math.abs(bends[1].x - bends[0].x) + Math.abs(bends[1].y - bends[0].y);
        if (first < 16) tight.push(`${name} / ${edge.id}: turns ${first}px after leaving -- ${edge.d}`);
      }
    }
    expect(tight).toEqual([]);
  });

  it('never rounds the corner into a head square', () => {
    const square = [];
    for (const { name, source } of CORPUS) {
      for (const edge of arrivals(drawn(source).svg)) {
        const a = approach(edge.d);
        if (a === null || a.kind !== 'Q') continue;
        if (a.radius < 4) square.push(`${name} / ${edge.id}: r=${a.radius} -- ${edge.d}`);
      }
    }
    expect(square).toEqual([]);
  });

  // The gap is sized from lane demand, so a reader who has set the ranks tighter than the approach
  // run needs still gets the approach run -- the gap grows to hold it rather than the head losing
  // its shaft. And a reader who has set them wider pays nothing for it.
  it('holds at every rank spacing, tight and loose', () => {
    const short = [];
    for (const [rankSpacing, nodeSpacing] of [[8, 8], [16, 8], [24, 16], [64, 48], [100, 80]]) {
      for (const { name, source } of CORPUS) {
        for (const edge of arrivals(drawn(source, { rankSpacing, nodeSpacing }).svg)) {
          const a = approach(edge.d);
          if (a === null) continue;
          if (a.run < RUN) short.push(`rank=${rankSpacing} ${name} / ${edge.id}: ${a.run}px`);
        }
      }
    }
    expect(short).toEqual([]);
  });
});
