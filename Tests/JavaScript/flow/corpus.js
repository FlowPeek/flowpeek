// The sources every structural property is checked against.
//
// There are two kinds here and the difference is the point of the file.
//
// EXAMPLES are written by hand and ORDERED. Tests reach into them by index -- `EXAMPLES[2]` is the
// nested-subgraph drawing whose eyebrow placement render.spec.js pins -- so an entry may be added
// at the end but never reordered or removed. They are specimens, not coverage.
//
// SWEEP is generated, and it is what a test means by "on every source". It is the same shape as
// the corpus `arrival.spec.js` built for itself: every node geometry on every rank direction, each
// one also drawn with two more edges onto the same face so the port is fanned off centre, plus the
// structural families -- back edges, rank skips, fans, self loops, crossings, nested subgraphs.
//
// WHY THE SPLIT EXISTS. Until this file, "the corpus" was twelve literals in render.spec.js, and a
// sweep over them was an assertion about twelve drawings rather than about the renderer. Three
// defects found by eye this session were all in that gap: two square corners and an 8px arrival
// shaft turned up in sources invented to look for them, and the label-ownership metric that read
// 0 wrong owners over a 53-source scratch corpus was never a property the suite held. A generated
// space does not make those impossible -- it makes them findable by running the suite rather than
// by someone thinking to try the right diagram.
//
// WHAT IT STILL IS NOT. The space is the grammar's, not the reader's: it covers the shapes and
// link forms mermaid accepts in the combinations this file names, and says nothing about the
// diagrams people actually write. Labels in particular are thin here -- the crowded sources that
// exposed the label defects live beside the tests that need them, because they were reported, and
// a generator that produced them would be a generator written backwards from the answer.

/** Every node geometry the renderer draws, as a node `X` ready to be the target of an edge. */
export const SHAPES = [
  'X[rect]', 'X(round)', 'X([stadium])', 'X[[subroutine]]', 'X[(cylinder)]', 'X((circle))',
  'X>odd]', 'X{rhombus}', 'X{{hexagon}}', 'X[/lean right/]', 'X[\\lean left\\]',
  'X[/trapezoid\\]', 'X[\\inv trapezoid/]', 'X(((double circle)))',
];

/** The four rank directions. Every family below is generated once per direction. */
export const DIRECTIONS = ['TD', 'LR', 'BT', 'RL'];

/**
 * The structural families, as functions of the direction. Each is a shape of graph rather than a
 * drawing: what varies between them is which routing decisions the layout is forced into, not what
 * the boxes say.
 */
const FAMILIES = {
  'return across subgraphs': (dir) => [
    `flowchart ${dir}`, '  subgraph front[Frontend]', '    web[Web app] --> router[Router]', '  end',
    '  subgraph back[Backend]', '    handler[Handler] --> worker[Worker]', '  end',
    '  router --> handler', '  worker --> web',
  ].join('\n'),
  'back edge': (dir) => `flowchart ${dir}\n  A --> B --> C --> D\n  D --> A\n`,
  'two back edges': (dir) =>
    `flowchart ${dir}\n  A[Alpha] --> B[Beta] --> C[Gamma] --> D[Delta] --> E[Epsilon]\n  E --> A\n  D --> B\n`,
  'rank skip': (dir) => `flowchart ${dir}\n  A --> B --> C --> D\n  A --> D\n  B --> D\n`,
  'fan in': (dir) => `flowchart ${dir}\n  N0 --> Z[Sink]\n  N1 --> Z\n  N2 --> Z\n  N3 --> Z\n  N4 --> Z\n`,
  'fan out': (dir) => `flowchart ${dir}\n  H{Hub} --> A\n  H --> B\n  H --> C\n  H --> D\n`,
  'self loop': (dir) => `flowchart ${dir}\n  A --> B\n  B --> B\n  B --> C\n`,
  crossing: (dir) =>
    `flowchart ${dir}\n  A1 --> B1\n  A2 --> B2\n  A1 --> B2\n  A2 --> B1\n  B1 --> C\n  B2 --> C\n`,
  'nested subgraphs': (dir) =>
    `flowchart ${dir}\n  subgraph a\n   subgraph b\n    X --> Y\n   end\n  end\n  Y --> Z\n  Z --> X\n`,
  'labelled fork': (dir) => [
    `flowchart ${dir}`, '  A[Start] -->|first| B{Is it ready?}', '  B -->|yes| C[(Store)]',
    '  B -->|no| D((Retry))', '  D --> A',
  ].join('\n'),
  'wide and narrow': (dir) =>
    `flowchart ${dir}\n  A[A very wide starting box indeed] --> B[b]\n  B --> C[Another extremely wide terminal box]\n`,
  ladder: (dir) => [
    `flowchart ${dir}`, '  R[Request] --> V{Valid?}', '  V -->|no| E[Reject]', '  V -->|yes| P[Process]',
    '  P --> S[(Store)]', '  S --> N[Notify]', '  N --> R', '  E --> R',
  ].join('\n'),
};

/**
 * The generated space, as `{ name, source }`. The name is what a failure prints, so it names the
 * family and the direction rather than the index -- an index tells a reader to go and count.
 */
export function generate() {
  const out = [];
  for (const dir of DIRECTIONS) {
    for (const shape of SHAPES) {
      out.push({ name: `shape ${shape} ${dir}`, source: `flowchart ${dir}\n  A[Source] --> ${shape}\n` });
      // The same geometry with its face shared, because a port that is correct at the centre of a
      // face is not thereby correct once two more edges push it off centre.
      out.push({
        name: `shape fan ${shape} ${dir}`,
        source: `flowchart ${dir}\n  A[Source] --> ${shape}\n  B[Other] --> X\n  C[Third] --> X\n`,
      });
    }
    for (const [family, build] of Object.entries(FAMILIES)) {
      out.push({ name: `${family} ${dir}`, source: build(dir) });
    }
  }
  return out;
}

/**
 * The hand-written specimens. ORDER IS LOAD-BEARING: render.spec.js indexes into this list, so
 * append only.
 */
export const EXAMPLES = [
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

/** A name for a bare source string, for the specimens, which have no name of their own. */
export const describeSource = (source) =>
  `${JSON.stringify(source.split('\n')[0])} (${source.split('\n').length} lines)`;

/**
 * What a sweep runs over: the specimens first, so a failure a reader already knows how to picture
 * is reported before the generated ones, then the generated space.
 */
export const SWEEP = [
  ...EXAMPLES.map((source) => ({ name: describeSource(source), source })),
  ...generate(),
];

// --- what the generated space found, and has not fixed ---------------------------------------
//
// Widening the sweep from twelve literals to 172 drawings turned up three failures on the first
// run. They are recorded here rather than asserted away, and each test below checks the EXACT set
// rather than a count: a new one fails, and so does fixing one without editing this record, which
// is the only way a baseline stays honest.
//
// None is a regression. Each has been there since the renderer shipped and was invisible because
// no source in the old corpus provoked it. All three are in `flowpeek-flow.js`; nothing in the
// Pele path or the mermaid path is involved.

/**
 * A one-grid-unit sidestep that `alignUnitJog` could not close, drawn square because an on-grid
 * radius does not exist at that size.
 *
 * Diagnosed, not guessed: with the layout instrumented, `alignUnitJog` sees `delta: 1` on this
 * edge and reports `closed: false` on BOTH of its passes -- `slideAlongFace` refuses to close the
 * step and refuses to widen it to three or two units, because the face cannot spare the move. The
 * route then reaches the emitter as `... L244,108 L340,108 L340,104 L396,104`, and `cornerRadius`
 * returns `4 * Math.floor((4 / 4) / 2)` = 0 for a 4px leg, so `pathOf` takes its `r <= 0` branch
 * and writes the corner square. Two corners sharing a 4px leg can have at most a 2px radius, which
 * is off the grid, so there is no fix at the emitter: the jog has to stop reaching it.
 *
 * The shape of a fix, for whoever takes it: the lane carrying the long run sits one unit off the
 * port it ends at. `alignUnitJog` tries to move the PORT and gives up when the face is full; the
 * lane is the other thing that could move, and widening the jog to two units makes it a pair of
 * touching 4px arcs, which the emitter's own comment already calls legal under rule 1.
 */
export const SQUARE_CORNERS = [
  'rank skip LR at 340,108',
  'rank skip LR at 340,104',
  'rank skip RL at 164,108',
  'rank skip RL at 164,104',
];

/**
 * The router could not find a cross-line clearing every stroke already drawn, and said so. One
 * source in 172, and an unremarkable one: a four-node fork with four edge labels, drawn bottom-up.
 */
export const CROWDED_LABELS = ['labelled fork BT'];

/**
 * A label mask closer than 8px to a stroke it does not belong to. Same source as CROWDED_LABELS
 * and almost certainly the same cause -- the warning says the router had already run out of room
 * -- but they are recorded apart because one is the router reporting and the other is the drawing
 * measured, and a fix could close either without closing the other.
 */
export const TIGHT_MASKS = ['labelled fork BT'];

/**
 * Pairs of boxes that share a centre line with nothing between them and are nonetheless drawn with
 * a step. The property is "an aligned, unobstructed pair is one segment", and over the twelve
 * literals it held for 23 pairs with one named exception; over the generated space it is measured
 * against 188 pairs and finds two more.
 *
 * `"graph TD" (5 lines): C->A` is not a defect and never was: it is a back edge whose corridor the
 * layout reserved outside either box, so the port is already hard against the end of its face and
 * the step belongs to the corridor rather than to the fan.
 *
 * The two `two back edges` entries are new and ARE defects, of the kind a reader sees as a line
 * that wanders when it had no reason to. They appear in LR and RL and not in TD or BT, which is
 * the same left-right asymmetry the square corners show, and suggests one cause behind both.
 */
export const STEPPED_PAIRS = [
  '"graph TD" (5 lines): C->A',
  'two back edges LR: D->B',
  'two back edges RL: D->B',
];

/** How many aligned, unobstructed pairs the sweep finds. Recorded so that a change in coverage is
 * visible rather than silent: if the generator grows, this grows, and a reviewer sees it move. */
export const ALIGNED_PAIRS = 188;
