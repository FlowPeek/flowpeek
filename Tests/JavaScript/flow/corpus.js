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

// --- what the generated space found ---------------------------------------------------------
//
// Widening the sweep from twelve literals to 172 drawings turned up four failures on the first
// run, none of them regressions: each had been there since the renderer shipped and no source in
// the old corpus provoked it. All four are fixed, and these lists are kept EMPTY rather than
// deleted, because each test compares the exact set -- a new failure of any of these kinds fails
// here with the drawing named, which is what the lists were for.
//
// What fixed them, all in flowpeek-flow.js:
//   * `straightenDetours` -- offers any two stations that share a coordinate the straight run
//     between them, longest span first, and takes the first that `routeIsClear` accepts.
//   * `closeUnitJogs` -- moves the run beside a one-unit sidestep rather than the port, which is
//     the lever `alignUnitJog` does not have once a face is full.
//   * one direction added to `laneLabelLo`, settled by counting warnings over the sweep.
// The first two moved 9 drawings of 169 and the third moved 2, none of which failed to render.

/**
 * Square corners: a one-grid-unit sidestep drawn with no fillet, because two corners sharing a 4px
 * leg could have at most a 2px radius and that is off the grid.
 *
 * Was four, in `rank skip LR` and its RL mirror. `alignUnitJog` had already tried to remove them
 * in the layout by sliding a port and reported failure on both passes -- the destination face
 * carried three ports at the minimum pitch -- so the fix moves the RUN instead.
 */
export const SQUARE_CORNERS = [];

/**
 * The router could not find a cross-line clearing every stroke already drawn, and said so. One
 * source in 172, and an unremarkable one: a four-node fork with four edge labels, drawn bottom-up.
 */
/**
 * Drawings where the label placer could not find a position with no penalty and said so.
 *
 * Was one, `labelled fork BT`, and the cause was upstream of the placer: the drawing is the exact
 * vertical mirror of `labelled fork TD`, which is clean, except that one edge turned 24px after
 * leaving its node where TD turns it at 44px. See the note on `laneLabelLo`.
 */
export const CROWDED_LABELS = [];

/**
 * A label mask closer than 8px to a stroke it does not belong to. Same source as CROWDED_LABELS
 * and almost certainly the same cause -- the warning says the router had already run out of room
 * -- but they are recorded apart because one is the router reporting and the other is the drawing
 * measured, and a fix could close either without closing the other.
 */
/**
 * Label masks closer than 8px to a stroke they do not belong to. Was one, the same drawing as
 * CROWDED_LABELS and the same cause; they are kept apart because one is the router reporting and
 * the other is the drawing measured, and a future fix could close either without the other.
 */
export const TIGHT_MASKS = [];

/**
 * Pairs of boxes that share a centre line with nothing between them and are nonetheless drawn with
 * a step. The property is "an aligned, unobstructed pair is one segment", and it is measured over
 * 188 pairs in the generated space, against 23 in the twelve literals it replaced.
 *
 * Empty, and the one entry that was here before the sweep went in is worth recording as gone. The
 * back edge `C --> A` in `graph TD` was written up as a permitted exception -- its corridor was
 * reserved outside either box, so the port was hard against the end of its face and the step was
 * said to belong to the corridor rather than to the fan. `straightenDetours` straightens it too,
 * and `routeIsClear` agrees the straight run is clear of every box, zone and stroke. The exception
 * was a description of what the router happened to do, not a rule it had to obey.
 */
export const STEPPED_PAIRS = [];

export const ALIGNED_PAIRS = 188;

// --- what seven visual reviews left ----------------------------------------------------------
//
// Separately from the records above, which are properties of the generated space, this renderer
// was compared against Pele -- the other engine in this app, drawing the same sources under the
// `.pele` theme -- by seven reader-facing reviews of the same eighteen drawings. The per-source
// verdict, "which would a reader rather have", moved PELE 9 : OURS 3 : TIE 4, then 5:5:6, 3:5:8,
// 2:5:9, 1:6:9 and finally OURS 7 : PELE 1 : TIE 10 across all eighteen, counting the two a reader
// had actually sent in as broken.
//
// The one drawing the seventh review still gave to Pele was the dense DAG, for its 15 hops rather
// than for a defect; it has since stopped marking its crossings (`crossingsAreCommon` in
// flowpeek-flow.js), which also took away the one face-pressed hop recorded here, and no review has
// been run since. The items below are recorded rather than open: they are written beside the corpus
// so the next person finds them from the tests rather than from `git log`, and none is a reason to
// change the renderer again without a reader asking for it.
//
// ONE PLATE ON ITS OWN ELBOW. The reported drawing that mixed ON and BESIDE is now all BESIDE: the
// layout keeps a margin between two labelled columns side by side (`facingColumns`). One plate in
// it, "negotiate(adjustRate, self)", is placed beside its first leg and still lies over its own
// elbow, as it did before; the placer charges it 18 for that leg. It covers its own line, not
// another's, and render.spec.js names it in an exact set.
//
// WHY THE TWO LABEL-DISTANCE METRICS STILL FAVOUR PELE, AND WHY THAT IS NOT A DEFECT. After the
// differential was taught to measure both engines with the same ruler, two numbers were left where
// Pele led: mean distance from a label's plate to the nearest stroke that is not its own, 45.32
// against our 41.03, and the minimum, 10 against our 8. Both were taken apart rather than chased.
//
// The MEAN is a trade, not a loss. Pele puts all 39 of its plates on their own line. On the 24
// where we do the same, WE lead -- 33.00 against 23.95 -- so where the two engines make the same
// choice ours leaves more room. The whole gap comes from 15 plates in the two reported sources
// where we place BESIDE and Pele places ON, and Pele buys that with 52% more drawing area and, on
// one of them, 62 bends against our 12. The metric also rewards the wrong thing on its own terms:
// a plate that floats away from every stroke scores well, and a label that cannot be matched to
// its edge was the defect the first reader-facing review ranked FIRST of ten.
//
// The MINIMUM is plate size. The 8px is the `no` plate in `labelled fork`, in all four directions,
// sitting on its own line with another edge one port over on the same circular face running
// parallel the whole leg; every clean placement there scores the same rival distance. Our plate is
// 32x24 and Pele's is 23x21, so the two pixels are the box, not where it was put.
//
// Levers were swept and each breaks something that matters more: LABEL_GAP 3 reaches 12 and 45.44
// but takes labels off their lines and adds 105,056 px2 of content area, MIN_PITCH 4 leaves the
// minimum at 8, and raising LABEL_MARGIN_PX lowers the mean it was meant to raise.
