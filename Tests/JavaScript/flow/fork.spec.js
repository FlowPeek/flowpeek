// The branches of one decision read as a pair.
//
// The defect a reader reported, looking at the Korean decision drawing rather than at the code: the
// two branches off `재고가 충분한가?` did not mirror each other, and the reader's own reading was
// that they should, "with no influence from the text". Two things were wrong and they had nothing
// to do with each other:
//
//   * THE TURN HEIGHT. `layoutLevel` handed every segment that had to move sideways a lane of its
//     own, from a running counter, so a fork's two arms were always on two lanes 12px apart and
//     always turned at two different heights. The asymmetry followed the order the edges were
//     DECLARED in: swap the two `C -->` lines and the high turn goes with whichever is written
//     first. Measured over the corpus's 66 fork pairs, 11 turned at the same height.
//   * THE STEP. `desirePorts` answers for one edge at a time, so each branch aimed at its own
//     target's landing run and was clamped by its own target's width. `결제 진행` is an 88px box the
//     branch reaches straight down; `입고 대기 알림` is 120px and its landing run starts 44px to the
//     right, so that branch was clamped and stepped. One branch a bare vertical, one an S. The
//     reader's hypothesis, and it holds: on `C{Check} --> L[Go]` / `C --> R[A considerably longer
//     label here]` the left branch stepped 44px and the right was straight, and with the two labels
//     exchanged the left was straight and the right stepped 40px. 30 of 66 pairs were mirrored.
//
// WHAT A FORK IS, as both passes read it: the edges leaving ONE node by ONE face in ONE rank
// direction, each reaching its target directly. `chooseSides` gives every ranked edge the face its
// direction names, so "one node and one direction" is one face. An edge with a corridor to travel
// is not an arm -- its first station is the corridor, several ranks long, not a branch beside the
// others. A node with five children is a fan, not a fork, and the same rule covers it: arm k and
// arm n-1-k are a mirror pair, the middle of an odd fan is the axis, and the pairs ladder outwards
// so the arm that crosses furthest turns nearest the node it left.
//
// WHAT IT COST. Mirroring bends legs that used to be straight -- that is the trade, and the
// measurement is that it is a small one. Over 328 sources and 675 connectors: single-segment
// straight connectors 454 -> 453, corners 532 -> 533, bridge hops 16 -> 14, drawing area -3.58%,
// reduced-radius (4px) fillets 84 -> 74. Every arrival still has arrival.spec.js's 16px straight
// run, which is what the second half of this file checks.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SEVEN_WAY_DECISION } from './corpus.js';
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

function theme(overrides) {
  if (!overrides) return EDITORIAL;
  return { ...EDITORIAL, arrangement: { ...EDITORIAL.arrangement, ...overrides } };
}

function laid(source, overrides) {
  const db = new flow.FlowDB();
  db.clear();
  flow.parse(source, db);
  return flow.layout(db, { measureText, theme: flow.buildFlowTheme(theme(overrides)) });
}

function drawn(source, overrides) {
  const out = flow.render({
    source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: theme(overrides), measureText,
  });
  expect(out.reason || 'ok').toBe('ok');
  return out;
}

/** Which axis a face of `side` runs along, and so which coordinate a step along it moves. */
const ALONG = { top: 'x', bottom: 'x', left: 'y', right: 'y' };

/**
 * One fork, measured off the drawing rather than off the code that made it.
 *
 * Every number is relative to the SOURCE NODE'S CENTRE along the face, because that is the line the
 * branches are supposed to mirror about. `port` is where the arm leaves, `land` where it arrives,
 * `step` the sideways distance between them, and `turn` the lane it crosses on -- null when it is
 * straight and never turns at all. Arms come back ordered across the rank, so `arms[k]` and
 * `arms[n - 1 - k]` are the pair that has to mirror.
 */
function forkOf(out, from) {
  const src = out.nodes.find((n) => n.id === from);
  const arms = out.edges.filter((e) => e.from === from && e.start && e.end);
  const axis = ALONG[arms[0].start.side];
  const centre = axis === 'x' ? src.x + src.width / 2 : src.y + src.height / 2;
  const target = (e) => out.nodes.find((n) => n.id === e.to);
  return arms
    .map((e) => ({
      to: e.to,
      port: e.start[axis] - centre,
      land: e.end[axis] - centre,
      step: e.end[axis] - e.start[axis],
      // A connector that never leaves its own line has no turn to compare; `channel` is still set,
      // because the layout reserved the lane before the router found it did not need it.
      turn: e.start[axis] === e.end[axis] ? null : e.channel.value,
      at: axis === 'x'
        ? target(e).x + target(e).width / 2
        : target(e).y + target(e).height / 2,
    }))
    .sort((p, q) => (p.at - q.at) || (p.land - q.land));
}

/** Arm k against arm n-1-k, as the one string a failure has to print to be readable. */
function pairsOf(fork) {
  const out = [];
  for (let k = 0; k + 1 < fork.length - k; k += 1) {
    const lo = fork[k];
    const hi = fork[fork.length - 1 - k];
    out.push({
      name: `${lo.to}/${hi.to}`,
      land: `${lo.land}/${hi.land}`,
      mirroredLand: `${lo.land}/${-lo.land}`,
      port: `${lo.port}/${hi.port}`,
      mirroredPort: `${lo.port}/${-lo.port}`,
      turn: `${lo.turn}/${hi.turn}`,
      sameTurn: `${lo.turn}/${lo.turn}`,
    });
  }
  return out;
}

/** Every pair of a fork mirrors: the same step out, and the same turn height. */
function expectMirror(out, from, why) {
  const fork = forkOf(out, from);
  expect(fork.length).toBeGreaterThan(1);
  for (const pair of pairsOf(fork)) {
    expect(`${why} ${pair.name} lands ${pair.land}`).toBe(`${why} ${pair.name} lands ${pair.mirroredLand}`);
    expect(`${why} ${pair.name} leaves ${pair.port}`).toBe(`${why} ${pair.name} leaves ${pair.mirroredPort}`);
    expect(`${why} ${pair.name} turns ${pair.turn}`).toBe(`${why} ${pair.name} turns ${pair.sameTurn}`);
  }
  return fork;
}

/** The reported drawing, with the two branch targets' labels under the caller's control. */
const DECISION = (left, right, swapped) => [
  'flowchart TD',
  '  A([주문 접수]) --> B[재고 확인]',
  '  B --> C{재고가 충분한가?}',
  ...(swapped
    ? [`  C -->|부족함| E[${right}]`, `  C -->|충분함| D[${left}]`]
    : [`  C -->|충분함| D[${left}]`, `  C -->|부족함| E[${right}]`]),
  '  D --> F([배송 시작])',
  '  E --> B',
].join('\n');

/** A decision with nothing else attached, so only the branch labels can move anything. */
const BRANCH = (dir, left, right, leftEdge = 'yes', rightEdge = 'no') =>
  `flowchart ${dir}\n  S[Start] --> C{Check}\n  C -->|${leftEdge}| L[${left}]\n  C -->|${rightEdge}| R[${right}]\n`;

/** Widths that bracket what a label can do to a box: 32px of text up to a wrapped two-liner. */
const LABELS = ['AA', 'Go', '결제 진행', '입고 대기 알림', 'A considerably longer label here'];

describe('[Fork] the branches of one decision', () => {
  it('mirrors the reported drawing about the decision node', () => {
    // `flowpeek-flow.js` before this: the 충분함 branch dropped straight down from a port 8px left
    // of the apex while the 부족함 branch stepped 44px right and turned 12px lower. Now both step
    // 44px and both turn at the same height.
    //
    // That height is 272. It was 304 while the gap under the decision reserved room for 충분함 and
    // 부족함 between the rhombus and the lane, which left the two arms running side by side down to
    // it; a decision's lane now sits at the source face's reserve and the labels ride the arms'
    // own drops, so the pair turns where it leaves. The mirror is the property under test and it is
    // untouched -- what moved is where the mirrored pair sits, not that it is one.
    const out = laid(DECISION('결제 진행', '입고 대기 알림'));
    const fork = expectMirror(out, 'C', 'reported');
    expect(fork.map((a) => a.step)).toEqual([-44, 44]);
    expect(fork.map((a) => a.turn)).toEqual([272, 272]);

    // And as drawn, not just as placed: the two paths are reflections of each other in the line
    // through the apex. A reflection has to be read off the emitted `d` because that is the only
    // place the corner radii appear, and a mirror with one 4px fillet and one 8px is not a mirror.
    const paths = new Map(
      [...drawn(DECISION('결제 진행', '입고 대기 알림')).svg
        .matchAll(/data-id="(L_C_[DE]_0)" d="([^"]*)"/g)].map((m) => [m[1], m[2]]),
    );
    const apex = 132;
    const reflect = (d) => d.replace(/(-?\d+),(-?\d+)/g, (_, x, y) => `${2 * apex - Number(x)},${y}`);
    // Both paths run top to bottom, so a reflection is the x coordinates flipped and nothing else:
    // every `x,y` pair in the two -- a `Q`'s control point as well as its end -- maps onto its
    // opposite number in order. Neither carries a bridge arc, whose flags would not survive this.
    expect(reflect(paths.get('L_C_D_0'))).toBe(paths.get('L_C_E_0'));
  });

  for (const swapped of [false, true]) {
    it(`mirrors the reported drawing whatever the branch targets are called${swapped ? ', declared either way round' : ''}`, () => {
      // The reader's own hypothesis, turned into an assertion. Swapping the labels swaps the box
      // widths; making one much longer than the other wraps it to two lines and changes its height
      // as well. Neither may show in the shape of the connectors.
      for (const [left, right] of [
        ['결제 진행', '입고 대기 알림'],
        ['입고 대기 알림', '결제 진행'],
        ['결제 진행', '입고 대기 알림 그리고 훨씬 더 긴 문장'],
        ['결제 진행 그리고 훨씬 더 긴 문장', '입고 대기 알림'],
      ]) {
        expectMirror(laid(DECISION(left, right, swapped)), 'C', `${left}|${right}`);
      }
    });
  }

  it('mirrors a decision at every label width, in every direction', () => {
    // 100 drawings: four directions by five left labels by five right ones. Before this change none
    // of the 100 mirrored -- not even `Go`/`Go`, where the two boxes are the same size and only the
    // lane counter was left to separate them.
    for (const dir of ['TD', 'LR', 'BT', 'RL']) {
      for (const left of LABELS) {
        for (const right of LABELS) {
          expectMirror(laid(BRANCH(dir, left, right)), 'C', `${dir} ${left}|${right}`);
        }
      }
    }
  });

  it('mirrors a decision whatever its EDGE labels are', () => {
    // An edge label lives in the gap and sizes it, so a long one on one arm and a short one on the
    // other is the other way text could reach the connectors.
    const long = 'a very long edge label indeed';
    for (const [l, r] of [['yes', 'no'], [long, 'no'], ['yes', long], [long, long]]) {
      expectMirror(laid(BRANCH('TD', 'Left', 'Right', l, r)), 'C', `edge ${l}|${r}`);
    }
  });

  it('mirrors a fan pairwise and ladders it outwards', () => {
    // Five children is a fan, not a fork, and the same rule has to leave it readable: the outermost
    // pair shares the lane nearest the hub, the next pair the one after it, and the middle arm is
    // the axis and stays straight. The other order is what the counter was drawing -- an inner arm's
    // cross-line ran under an outer arm's and the router had to bridge it.
    for (const dir of ['TD', 'LR']) {
      for (let wide = 0; wide < 5; wide += 1) {
        const label = (i) => (i === wide ? 'A much wider label here' : `n${i}`);
        const source = `flowchart ${dir}\n  H{Hub} --> A[${label(0)}]\n  H --> B[${label(1)}]\n`
          + `  H --> C[${label(2)}]\n  H --> D[${label(3)}]\n  H --> E[${label(4)}]\n`;
        const fork = expectMirror(laid(source), 'H', `${dir} wide=${wide}`);
        expect(fork.length).toBe(5);
        expect(fork[2].step).toBe(0);
        expect(fork[2].turn).toBe(null);
        // Outermost nearest the hub. The lane coordinate grows away from the hub in TD and LR.
        expect(Math.abs(fork[0].land)).toBeGreaterThan(Math.abs(fork[1].land));
        expect(fork[1].turn - fork[0].turn).toBe(12);
      }
    }
  });

  it('follows the drawing and not the order the edges were declared in', () => {
    // The measurement that separated the two defects in the first place: with the counter, lane 0
    // went to whichever branch was written first and the turn height followed it. Swapping the two
    // `C -->` lines has to leave every coordinate of the fork where it was.
    const straight = forkOf(laid(DECISION('결제 진행', '입고 대기 알림', false)), 'C');
    const swapped = forkOf(laid(DECISION('결제 진행', '입고 대기 알림', true)), 'C');
    expect(swapped).toEqual(straight);
  });

  it('gives a shared lane to arms that cannot run into each other, and separate lanes to arms that can', () => {
    // Sharing is the whole mechanism of the equal turn height, so what it must not do is put two
    // connectors along one stretch of one lane -- SKILL.md §6 rule 3. A fork's two arms meet only at
    // their own source's centre, and their ports are 16px apart there, so the stretches they occupy
    // are disjoint with room to spare.
    for (const source of [
      DECISION('결제 진행', '입고 대기 알림'),
      BRANCH('TD', 'Left', 'A considerably longer label here'),
      BRANCH('LR', 'Left', 'A considerably longer label here'),
      'flowchart TD\n  H{Hub} --> A\n  H --> B\n  H --> C\n  H --> D\n  H --> E\n',
      'flowchart TD\n  N0 --> Z\n  N1 --> Z\n  N2 --> Z\n  N3 --> Z\n  N4 --> Z\n',
    ]) {
      const out = laid(source);
      const lanes = new Map();
      for (const e of out.edges) {
        if (!e.channel) continue;
        const axis = e.channel.axis === 'y' ? 'x' : 'y';
        if (e.start[axis] === e.end[axis]) continue;
        const span = [Math.min(e.start[axis], e.end[axis]), Math.max(e.start[axis], e.end[axis])];
        const key = `${e.channel.axis}:${e.channel.value}`;
        for (const other of lanes.get(key) || []) {
          const overlap = Math.min(span[1], other[1]) - Math.max(span[0], other[0]);
          expect(`${source.split('\n')[1]} ${key} overlap ${overlap > 0}`)
            .toBe(`${source.split('\n')[1]} ${key} overlap false`);
        }
        lanes.set(key, [...(lanes.get(key) || []), span]);
      }
      // And the check is not vacuous: every one of these has a lane carrying two cross-lines, which
      // is what it costs to give a fork's two arms one turn height.
      expect([...lanes.values()].some((held) => held.length > 1)).toBe(true);
    }
  });

  it('holds the arrival run, the grid and the elbows it was given', () => {
    // Mirroring moves the arrival ports, which is exactly the kind of change that could take back
    // arrival.spec.js's 16px of straight under an 8px arrowhead, put a coordinate off the 4px grid,
    // or leave a corner the radius cannot round. Checked here on the fork sources specifically.
    for (const dir of ['TD', 'LR', 'BT', 'RL']) {
      for (const source of [
        DECISION('결제 진행', '입고 대기 알림'),
        BRANCH(dir, 'AA', 'A considerably longer label here'),
        BRANCH(dir, 'A considerably longer label here', 'AA'),
        `flowchart ${dir}\n  H{Hub} --> A\n  H --> B\n  H --> C\n  H --> D\n  H --> E\n`,
      ]) {
        const svg = drawn(source).svg;
        for (const m of svg.matchAll(/<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"([^>]*)\/>/g)) {
          const [, id, d, rest] = m;
          const off = [];
          for (const cmd of d.match(/[MLQA][^MLQA]*/g) || []) {
            const v = (cmd.slice(1).match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
            // A bridge arc's radii and its three flags are not points; only its endpoint is.
            for (const c of cmd[0] === 'A' ? v.slice(5) : v) if (c % 4 !== 0) off.push(c);
          }
          expect(`${id} off grid: ${off.join()}`).toBe(`${id} off grid: `);
          if (!/marker-end=/.test(rest)) continue;
          const cmds = d.match(/[MLQAZz][^MLQAZz]*/g) || [];
          const last = cmds[cmds.length - 1];
          const prev = cmds[cmds.length - 2];
          expect(last[0]).toBe('L');
          const n = (last.slice(1).match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
          const p = (prev.slice(1).match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
          const from = prev[0] === 'Q' ? { x: p[2], y: p[3] }
            : prev[0] === 'A' ? { x: p[5], y: p[6] } : { x: p[0], y: p[1] };
          const run = Math.abs(n[0] - from.x) + Math.abs(n[1] - from.y);
          expect(`${dir} ${id} run ${run >= 16}`).toBe(`${dir} ${id} run true`);
          // The fillet into the head is the FULL 8px. `cornerRadius` gives half the shorter of the
          // two legs it joins, capped at 8 and snapped to the grid, so a 4px fillet before a head
          // means the cross-line feeding it was under 16px long. Before this change the `no` branch
          // of an LR decision had exactly that -- `Q260,100 260,104 ... Q260,112 264,112`, a 12px
          // cross-line with a 4px fillet at each end of it -- because only one of the two branches
          // was allowed to step and it was allowed only as far as its own box reached. Mirrored,
          // that cross-line is 20px and both fillets are 8.
          if (prev[0] === 'Q') {
            const radius = Math.abs(p[2] - p[0]) + Math.abs(p[3] - p[1]);
            expect(`${dir} ${id} radius ${radius}`).toBe(`${dir} ${id} radius 8`);
          }
        }
      }
    }
  });
});

describe('[Fork] a decision branches where it is left', () => {
  // The second visual review, weakness 9: a decision's two answers left the rhombus 16px apart and
  // ran side by side before either turned -- 44px of straight under each diamond of 01 and 09
  // (52 under 09's 결제 성공?) and 104px off 04's right vertex, read as one doubled line at the place
  // a reader most needs to see a branch. Pele's diverge at the vertex. Measured here is the shared
  // stretch: the shorter of the two arms' straight first legs, from the outline to where its first
  // corner begins. A leg has to clear its stub floor before it can round a corner, so the stretch
  // cannot be zero; it is 12px under 01's diamonds and 09's first, 20 under 결제 성공? and 28 off
  // 04. The lane is at the same 16px reserve in all of them; what differs is how far inside the
  // band a port 8px off the vertex sits, which is the slope of the rhombus's face.
  const SOURCES = {
    '01 decision': 'flowchart TD\n    start([Start]) --> input[/Read order/]\n    input --> valid{Valid?}\n    valid -->|Yes| stock{In stock?}\n    valid -->|No| reject[Reject order]\n    stock -->|Yes| ship[Ship]\n    stock -->|No| backorder[Backorder]\n    backorder --> notify[Notify customer]\n    ship --> done([End])\n    reject --> done\n    notify --> done',
    '04 long wrap': 'flowchart LR\n    a[The customer submits a refund request through the self-service portal with the original receipt attached] --> b{Is the purchase within the thirty day return window and the item unopened?}\n    b -->|Yes, within policy| c[Automatically approve the refund and issue store credit or the original payment method]\n    b -->|No, outside the policy window| d[Escalate to a human support agent who reviews the case history and decides]\n    d --> e[Send the customer a personalised email explaining the decision and any next steps]\n    c --> e',
    '09 korean': 'flowchart TD\n    시작([주문 접수]) --> 확인{재고가 충분한가?}\n    확인 -->|예| 결제[결제 진행]\n    확인 -->|아니오| 대기[입고 대기 목록에 추가]\n    결제 --> 성공{결제 성공?}\n    성공 -->|예| 배송[배송 준비 및 출고]\n    성공 -->|아니오| 취소[주문 취소 및 고객 안내]\n    대기 --> 알림[고객에게 예상 입고일 문자 발송]\n    배송 --> 완료([처리 완료])\n    취소 --> 완료\n    알림 --> 완료',
  };
  const corners = (d) => {
    const pts = [];
    for (const c of d.match(/[MLQA][^MLQA]*/g)) {
      const n = c.slice(1).match(/-?\d+(?:\.\d+)?/g).map(Number);
      if (c[0] === 'Q') pts.push({ x: n[0], y: n[1] });
      else if (c[0] === 'A') pts.push({ x: n[5], y: n[6] });
      else pts.push({ x: n[0], y: n[1] });
    }
    return pts;
  };
  const firstLeg = (d) => {
    const [a, b] = corners(d);
    return Math.abs(b.x - a.x) + Math.abs(b.y - a.y);
  };

  it('turns both answers of every decision within 28px of leaving it', () => {
    for (const [label, source] of Object.entries(SOURCES)) {
      const svg = drawn(source).svg;
      const decisions = [...source.matchAll(/([^\s[{(>|-]+)\{[^}]*\}/gu)].map((m) => m[1]);
      expect(decisions.length, label).toBeGreaterThan(0);
      for (const node of decisions) {
        const legs = [...svg.matchAll(/data-id="L_([^"]*)_\d+" d="([^"]*)"/g)]
          .filter((m) => m[1].startsWith(`${node}_`))
          .map((m) => firstLeg(m[2]));
        expect(legs.length, `${label} ${node}`).toBe(2);
        expect(Math.min(...legs), `${label} ${node} shared stretch`).toBeLessThanOrEqual(28);
      }
    }
  });
});

describe('[Fork] the answers of a many-way decision', () => {
  // The third held-out set's c10: 재질이 무엇인가요? sends seven labelled answers down a ladder of
  // four lanes, and each plate took the middle of its own lane, so the answers stood at five
  // heights and a reader hunted down the ladder for each one. Pele writes all seven in one row.
  // The property, read off the drawing: every plate of the decision's answers is ON its own line
  // and they all stand at one place along the rank axis.
  it('writes every answer of a seven-way decision in one row, each on its own line', () => {
    for (const { name, source } of SEVEN_WAY_DECISION) {
      const svg = drawn(source).svg;
      const vertical = / (TD|BT)$/.test(name);
      const paths = new Map([...svg.matchAll(/data-id="(L_Q_[^"]*)" d="([^"]*)"/g)].map((m) => [m[1], m[2]]));
      const places = new Set();
      const off = [];
      let plates = 0;
      for (const m of svg.matchAll(/data-id="(L_Q_[^"]*)" transform="translate\(([-\d.]+),([-\d.]+)\)"><rect class="background" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"/g)) {
        const rect = { x: +m[2] + +m[4], y: +m[3] + +m[5], w: +m[6], h: +m[7] };
        places.add(vertical ? rect.y + rect.h / 2 : rect.x + rect.w / 2);
        plates += 1;
        // The straight legs: each `L` from wherever the command before it ended, corners left out.
        const legs = [];
        let at = null;
        for (const [, cmd, args] of paths.get(m[1]).matchAll(/([MLQA])([^MLQA]*)/g)) {
          const n = args.trim().split(/[\s,]+/).map(Number);
          const to = { x: n[n.length - 2], y: n[n.length - 1] };
          if (cmd === 'L' && at) legs.push([at, to]);
          at = to;
        }
        // ON: a leg of the rank axis runs through the plate from one end to the other.
        const on = legs.some(([a, b]) => (vertical
          ? a.x === b.x && a.x > rect.x && a.x < rect.x + rect.w
            && Math.min(a.y, b.y) < rect.y && Math.max(a.y, b.y) > rect.y + rect.h
          : a.y === b.y && a.y > rect.y && a.y < rect.y + rect.h
            && Math.min(a.x, b.x) < rect.x && Math.max(a.x, b.x) > rect.x + rect.w));
        if (!on) off.push(m[1]);
      }
      expect(plates, name).toBe(7);
      expect(`${name} rows ${[...places].sort((a, b) => a - b).join(',')}`).toBe(`${name} rows ${[...places][0]}`);
      expect(`${name} off their lines: ${off.join(' ')}`).toBe(`${name} off their lines: `);
    }
  });
});
