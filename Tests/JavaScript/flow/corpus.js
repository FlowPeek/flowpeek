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
// structural families -- back edges, rank skips, fans, self loops, crossings, nested subgraphs --
// and the link forms: open links, heads at both ends, crosses, circles and the invisible link.
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
  // The link forms. Until these, every generated edge was `-->`, and the held-out review found
  // the cost: an open link `---` was drawn with an arrowhead on 6 of 6 occurrences. Two specimens
  // above already wrote `---`, but no assertion read the head on them -- one asserted that `A --- B`
  // HAD a pointEnd marker -- and none of the 18 reviewed sources wrote one. One family per kind of end:
  // open (no head, every stroke and length, labelled both ways), headed at both ends or with a
  // cross or circle, and open links that leave a zone, which is where `fp-cross` decides a head.
  //
  // 'open links' is `ladder` above with its links swapped, so that what it adds is the link forms
  // and not a new shape of graph. A first draft packed every open form and four labels onto five
  // nodes; it tripped label-crowded and the shared-corridor and mask rules in TD, BT and RL -- and
  // so did the same source with every link written `-->`, so that was density, the held-out
  // review's bundling weakness, rather than anything the link form decides.
  'open links': (dir) => [
    `flowchart ${dir}`, '  R[Request] --- V{Valid?}', '  V -- no --- E[Reject]', '  V ---|yes| P[Process]',
    '  P -.- S[(Store)]', '  S === N[Notify]', '  N ---- R', '  E -. retry .- R', '  P == bulk === N',
  ].join('\n'),
  'heads at both ends': (dir) => [
    `flowchart ${dir}`, '  A[Alpha] <--> B[Beta]', '  B x--x C[Gamma]', '  C o--o D[Delta]', '  A --x C',
    '  B --o D', '  D <-.-> E[Epsilon]', '  E <==> A', '  C -.-x E', '  D ==o A', '  A ~~~ E',
  ].join('\n'),
  'open links across zones': (dir) => [
    `flowchart ${dir}`, '  subgraph left[Left]', '    L1[Writer] --> L2[Queue]', '  end',
    '  subgraph right[Right]', '    R1[Reader] --> R2[Sink]', '  end', '  L2 --- R1', '  L1 === R2',
  ].join('\n'),
  // Long edges: one that spans three ranks or more beside other boxes, so its corridor has to
  // thread between them. 'back edge' above spans three ranks too, but down a single column, where
  // the corridor is straight whatever the layout does; nothing generated passed a long edge beside
  // a box until the held-out review counted 21 links with 6 or more corners on unseen sources. All
  // three drew one of their edges with 6 or 8 corners before `one lane for a long edge`.
  'long back edge': (dir) => [
    `flowchart ${dir}`, '  A[Start] --> B{Check}', '  B -->|left| C[Wide left step]', '  B -->|right| D[Right]',
    '  C --> E[Merge]', '  D --> E', '  E --> F[Finish]', '  F -->|retry| B',
  ].join('\n'),
  'long back edge past a fork': (dir) => [
    `flowchart ${dir}`, '  A[Start] --> B[Load]', '  B --> C[Parse]', '  B --> X[Side]', '  C --> D[Check]',
    '  X --> D', '  D --> E[Save]', '  E -.->|again| A', '  A --> E',
  ].join('\n'),
  // Decisions with three and four LABELLED answers. 'fan out' above is a four-way diamond too, but
  // with no labels it never asked whose line a label was on, and the held-out review's worst
  // drawings were exactly that question: three exits 12px apart off one tip, labels beside them.
  // The four-way one sends an answer back up as well, so a long edge leaves the same vertex.
  'three-way decision': (dir) => [
    `flowchart ${dir}`, '  A[Request] --> D{Status code}', '  D -->|2xx| B[Return body]',
    '  D -->|4xx| C[Do not retry]', '  D -->|5xx| E[Back off]', '  E --> F[Record]', '  B --> F',
  ].join('\n'),
  'four-way decision': (dir) => [
    `flowchart ${dir}`, '  A[Intake] --> D{Category}', '  D -->|billing| B[Billing queue]',
    '  D -->|bug| C[Technical queue]', '  D -->|account| E[Security queue]', '  D -->|how-to| K[Suggest article]',
    '  B --> Z[Closed]', '  C --> Z', '  E --> Z', '  K -->|still stuck| A',
  ].join('\n'),
  // Busy rectangular faces with labels on them. 'fan in' and 'heads at both ends' already put five
  // ends on one rect face, but with nothing written on any of the five, so the question the
  // held-out review asked of h04 and h20 -- which of six lines 12px apart does this label name --
  // never came up. One is a labelled fan-in of five; the other brings back edges onto the face its
  // own labelled out-edges leave from, which is the load the node sizing cannot see before ranks.
  'labelled fan in': (dir) => [
    `flowchart ${dir}`, '  A[Web] -->|signup| Z[Accounts]', '  B[Mobile] -->|login| Z',
    '  C[Partner] -->|token| Z', '  D[Admin] -->|reset| Z', '  E[Batch] -->|import| Z', '  Z --> Q[Audit]',
  ].join('\n'),
  'labelled returns to one face': (dir) => [
    `flowchart ${dir}`, '  S[Start] --> I[Idle]', '  I -->|wake| W[Working]', '  I -->|sync| Y[Syncing]',
    '  I -->|scan| C[Scanning]', '  W -->|done| I', '  Y -->|synced| I', '  C -->|nothing found| I',
    '  W --> F[Finish]',
  ].join('\n'),
  // A fork one of whose arms comes back. Two edges then join the same two boxes, one each way, and
  // the fork's own face carries both beside the other arm. Every two-way pair above is between
  // boxes with nothing else on the shared face, or rides a corridor; the held-out review's h04 had
  // this at Advertising and Deep sleep, and the two lines crossed beside the fork.
  'fork with a returning arm': (dir) => [
    `flowchart ${dir}`, '  A[Idle] -->|connect| B[Busy]', '  A -->|sleep| C[Paused]', '  C -->|wake| A',
  ].join('\n'),
  // Zones whose title a route has to pass. Every zone family above enters its zones where the
  // title is not: a single column wider than its title, or an edge arriving from below. None put a
  // zone's first-row node under a title that fills the band, with the route arriving from a lane
  // beside the zone or straight down a narrow one, and the held-out review found exactly that on
  // unseen sources: three titles struck through in h14 and one in h07. One family arrives from
  // the side into two sibling zones, one straight down into a zone narrower than twice its title,
  // and one into sibling zones nested inside a third.
  'entry beside a zone title': (dir) => [
    `flowchart ${dir}`, '  dns[Latency routing] --> ing1[Ingress]', '  dns --> ing2[Ingress]',
    '  subgraph blue[namespace: checkout]', '    ing1 --> api1[Checkout API]', '  end',
    '  subgraph green[namespace: checkout]', '    ing2 --> api2[Checkout API]', '  end',
  ].join('\n'),
  'entry through a zone title': (dir) => [
    `flowchart ${dir}`, '  A[Gateway] --> B[Handler]',
    '  subgraph back[Backend services]', '    B --> C[Worker]', '  end', '  C --> D[(Store)]',
  ].join('\n'),
  'nested entry under titles': (dir) => [
    `flowchart ${dir}`, '  R[Router] --> I[Ingress]', '  R --> J[Ingress]',
    '  subgraph region[us-east-1]', '    subgraph az[AZ us-east-1a]', '      I --> P[API pod]', '    end',
    '    subgraph db[AZ us-east-1b]', '      J --> Q[API pod]', '    end', '  end',
  ].join('\n'),
  // Several routes into one face from the same side, from sources at different depths, one of
  // them nearer the face than the lanes of the others. Every fan-in family above brings its arms
  // in from ranks that line up, so the lanes they are given already nest; none brings a route in
  // past a chain that ends next to the face, which is what tied h20's Closed into two hops in the
  // held-out review. At e5d9490 both draw 2 hops in TD and BT.
  'returns past a chain': (dir) => [
    `flowchart ${dir}`, '  s[Start] --> a[Agent]', '  a --> f[Finance]',
    '  a --> e[Engineer] --> j[Jira] --> n[Notify] --> z([Closed])', '  f --> z', '  s --> k[KB] --> z', '  a --> z',
  ].join('\n'),
  'returns past a queue': (dir) => [
    `flowchart ${dir}`, '  a[Agent] --> f[Finance approval] --> z([Closed])',
    '  a --> e[Engineer] --> j[Jira bug] --> n[Notify] --> z', '  q[Queue] --> a', '  q --> k[Suggest article] --> z',
    '  e --> z',
  ].join('\n'),
  'long forward edge': (dir) => [
    `flowchart ${dir}`, '  A[Start] --> B[One] --> C[Two] --> D[Three] --> E[End]',
    '  A --> P[Wide parallel step] --> Q[Another one] --> E', '  A -->|skip| E',
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
 * 222 pairs in the generated space, against 23 in the twelve literals it replaced. It was 188 until
 * the three link-form families went in; their 14 pairs are all one segment, and 202 until the three
 * long-edge families added 10 more, which were one segment before their fix as well as after, and
 * 212 until the two labelled-decision families added 10, 222 until the two busy labelled-face
 * families added 20, 242 until the three zone-title families added 20, and 262 until the two
 * return-past families added 8.
 *
 * Empty, and the one entry that was here before the sweep went in is worth recording as gone. The
 * back edge `C --> A` in `graph TD` was written up as a permitted exception -- its corridor was
 * reserved outside either box, so the port was hard against the end of its face and the step was
 * said to belong to the corridor rather than to the fan. `straightenDetours` straightens it too,
 * and `routeIsClear` agrees the straight run is clear of every box, zone and stroke. The exception
 * was a description of what the router happened to do, not a rule it had to obey.
 */
export const STEPPED_PAIRS = [];

export const ALIGNED_PAIRS = 270;

// --- what eight visual reviews left ----------------------------------------------------------
//
// Separately from the records above, which are properties of the generated space, this renderer
// was compared against Pele -- the other engine in this app, drawing the same sources under the
// `.pele` theme -- by eight reader-facing reviews of the same eighteen drawings. The per-source
// verdict, "which would a reader rather have", moved PELE 9 : OURS 3 : TIE 4, then 5:5:6, 3:5:8,
// 2:5:9, 1:6:9, 1:7:10 and finally PELE 0 : OURS 7 : TIE 11 across all eighteen, counting the two
// a reader had actually sent in as broken. Pele wins none of them.
//
// The one drawing the seventh review still gave to Pele was the dense DAG, for its 15 hops rather
// than for a defect. It has since stopped marking its crossings (`crossingsAreCommon` in
// flowpeek-flow.js), which also took away the one face-pressed hop once recorded here, and the
// eighth review scored that drawing a tie and every other one ours or a tie. That review named one
// concrete defect, an unmarked crossing beside a marked one, which `8fa2b2b` closed by charging a
// label plate that blocks the only room a crossing's bump could have.
//
// The items below are recorded rather than open: they are written beside the corpus so the next
// person finds them from the tests rather than from `git log`, and none is a reason to change the
// renderer again without a reader asking. A ninth review of THESE eighteen has nothing left to
// decide; new sources from real readers are the better next step.
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
