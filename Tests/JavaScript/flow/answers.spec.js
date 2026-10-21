// Two answers of one decision, each with a plate a reader can attach to the right line.
//
// The second held-out set's b20 sent "불가" up and "가능" down out of one diamond and drew both plates
// BESIDE their lines in the gap between the two -- each plate facing the other answer's line -- so
// the reader could swap them. Nothing measured it: every margin `placeEdgeLabel` scores was positive,
// because each plate stood 8px from its own line and further from its sibling's. The property this
// file holds is the reader's, read off the drawing: a plate BESIDE its line never has, as the next
// stroke across it on the side away from that line, a stroke of another edge leaving the same node.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SWEEP } from './corpus.js';
import { measureFace, measureText } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

// What the app ships, as differential.mjs renders it: the face `measureFace` was read from and the
// 20px outer margin of MacMermaidTheme.swift. Under the flat budget of `measureText` the plates come
// out narrower and other seats open, which hides the defect on these sources rather than fixing it.
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

/** The straight legs of a route, read off its path data; the corner curves are left out. */
function legs(d) {
  const out = [];
  let at = null;
  for (const [, cmd, args] of d.matchAll(/([MLQA])([^MLQA]*)/g)) {
    const n = args.trim().split(/[\s,]+/).map(Number);
    const to = { x: n[n.length - 2], y: n[n.length - 1] };
    if (cmd === 'L' && at && (at.x === to.x || at.y === to.y)) out.push([at, to]);
    at = to;
  }
  return out;
}

/** Every BESIDE plate whose far side faces a stroke of a sibling edge, as `drawing: edge`. */
function platesFacingASibling(name, source) {
  const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measureFace });
  expect(out.reason || 'ok').toBe('ok');
  const svg = out.svg;
  const nodes = new Set([...svg.matchAll(/<g class="node[^"]*" id="fp-0-flowchart-(.*?)-\d+"/g)].map((m) => m[1]));
  const fromOf = (id) => {
    const body = id.replace(/^L_/, '').replace(/_\d+$/, '');
    for (let k = 1; k < body.length; k += 1) {
      if (body[k] === '_' && nodes.has(body.slice(0, k)) && nodes.has(body.slice(k + 1))) return body.slice(0, k);
    }
    return null;
  };
  const edges = [...svg.matchAll(/<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"/g)]
    .map((m) => ({ id: m[1], from: fromOf(m[1]), legs: legs(m[2]) }));
  const found = [];
  const plates = [];
  const facing = [];
  for (const m of svg.matchAll(/data-id="([^"]*)" transform="translate\(([-\d.]+),([-\d.]+)\)"><rect class="background" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"/g)) {
    const own = edges.find((e) => e.id === m[1]);
    if (!own) continue;
    const rect = { x: +m[2] + +m[4], y: +m[3] + +m[5], w: +m[6], h: +m[7] };
    const cx = rect.x + rect.w / 2, cy = rect.y + rect.h / 2;
    const through = (l) => (l[0].y === l[1].y
      ? l[0].y > rect.y && l[0].y < rect.y + rect.h && Math.max(l[0].x, l[1].x) > rect.x && Math.min(l[0].x, l[1].x) < rect.x + rect.w
      : l[0].x > rect.x && l[0].x < rect.x + rect.w && Math.max(l[0].y, l[1].y) > rect.y && Math.min(l[0].y, l[1].y) < rect.y + rect.h);
    own.on = own.legs.some(through);
    plates.push(own);
    if (own.on) continue; // ON its line: the line names it
    // The own leg the plate stands beside: the nearest one alongside it.
    let near = null, best = Infinity;
    for (const l of own.legs) {
      const h = l[0].y === l[1].y;
      const lo = h ? Math.min(l[0].x, l[1].x) : Math.min(l[0].y, l[1].y);
      const hi = h ? Math.max(l[0].x, l[1].x) : Math.max(l[0].y, l[1].y);
      if (hi <= (h ? rect.x : rect.y) || lo >= (h ? rect.x + rect.w : rect.y + rect.h)) continue;
      const dist = Math.abs(h ? l[0].y - cy : l[0].x - cx);
      if (dist < best) { best = dist; near = l; }
    }
    if (!near) continue;
    const h = near[0].y === near[1].y;
    const side = Math.sign(h ? cy - near[0].y : cx - near[0].x);
    const far = h ? (side > 0 ? rect.y + rect.h : rect.y) : (side > 0 ? rect.x + rect.w : rect.x);
    const lo = h ? rect.x : rect.y, hi = lo + (h ? rect.w : rect.h);
    let next = null, gap = Infinity;
    for (const e of edges) {
      if (e === own) continue;
      for (const l of e.legs) {
        if ((l[0].y === l[1].y) !== h) continue;
        const a = h ? Math.min(l[0].x, l[1].x) : Math.min(l[0].y, l[1].y);
        const b = h ? Math.max(l[0].x, l[1].x) : Math.max(l[0].y, l[1].y);
        if (b <= lo || a >= hi) continue;
        const dist = ((h ? l[0].y : l[0].x) - far) * side;
        if (dist >= 0 && dist < gap) { gap = dist; next = e; }
      }
    }
    if (next && next.from !== null && next.from === own.from) facing.push([own, next]);
  }
  // Whether or not the sibling's own plate is ON its line. b20 had both plates in the gap; with one
  // of them ON, the other still stands between two lines that leave one vertex, and is read as its
  // own only by elimination -- which the reader has to know to do.
  for (const [own, next] of facing) found.push(`${name}: ${own.id} faces ${next.id}`);
  return found;
}

/**
 * The plates the sweep still draws facing a sibling, as an EXACT set, each because every seat that
 * does not face one costs a real harm by the placer's own terms -- a stroke inside the gap or under
 * the plate, or another plate -- and `placeEdgeLabel` prices facing below those. Read off the placer:
 *
 *   * `long back edge LR`: "right" above its line under "left"'s, 9. ON is 30, with "retry"
 *     arriving 12px under it passing under the plate; below is 238, over that arrival's corner.
 *     "left" is ON its own line, so the gap holds one plate.
 *   * `four-way decision` TD and BT: "account" beside its last leg, facing "how-to"'s line, 9. ON
 *     on that leg stands against "bug"'s plate, placed first, and ON on its first leg has a lane
 *     under it (60); `reorderPairs` finds no trade that leaves "bug" as well seated.
 *   * `opposed answers beside a skip` LR and RL: both answers in the gap, which is b20's defect,
 *     and the one this list exists to keep in view. A third line arrives at each answer's target
 *     16px off the answer's own, so ON for either is 4px from that line and the far side is on it.
 *     It is the layout's to widen; see the note in `placeEdgeLabel`.
 *
 * Before `facesSibling` this list had one more: the skip family's "no problem" in LR, facing the
 * line of its sibling "mortgage over 70% of price" while a clean seat below its own line was free.
 */
const FACING_A_SIBLING = [
  'four-way decision TD: L_D_E_0 faces L_D_K_0',
  'long back edge LR: L_B_D_0 faces L_B_C_0',
  'opposed answers beside a skip LR: L_D_X_0 faces L_D_P_0',
  'opposed answers beside a skip LR: L_D_P_0 faces L_D_X_0',
  'four-way decision BT: L_D_E_0 faces L_D_K_0',
  'opposed answers beside a skip RL: L_D_X_0 faces L_D_P_0',
  'opposed answers beside a skip RL: L_D_P_0 faces L_D_X_0',
];

describe('a plate beside its line', () => {
  it('faces the line of another edge leaving the same node only where every other seat is a harm', () => {
    const found = SWEEP.flatMap(({ name, source }) => platesFacingASibling(name, source));
    expect(found).toEqual(FACING_A_SIBLING);
  });

  it('is never ON its line with another edge of its node running under it beside its own', () => {
    // The third held-out set's c12: two answers into one target, the second's line under the
    // first's plate from end to end. Under the flat budget, which is the ruler the family was
    // found on: the face measures this plate narrower than the gap it sits in.
    const under = [];
    const routesSeen = new Set();
    const pairs = SWEEP.filter(({ name }) => name.startsWith('two answers into one target'));
    for (const { name, source } of pairs) {
      const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText });
      expect(out.reason || 'ok').toBe('ok');
      if (/flowchart-link" data-id="L_/.test(out.svg)) routesSeen.add(name);
      const routes = new Map([...out.svg.matchAll(/<path[^>]*flowchart-link" data-id="(L_[^"]+)" d="([^"]+)"/g)].map((m) => [m[1], legs(m[2])]));
      for (const m of out.svg.matchAll(/<g class="label" data-id="([^"]+)" transform="translate\(([-\d.]+),([-\d.]+)\)"><rect class="background" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"/g)) {
        const [ox, oy, x, y, w, h] = m.slice(2).map(Number);
        const plate = { x0: ox + x, y0: oy + y, x1: ox + x + w, y1: oy + y + h };
        const sits = (routes.get(m[1]) || []).some(([a, b]) => (a.x === b.x
          ? a.x > plate.x0 && a.x < plate.x1 && Math.min(a.y, b.y) < plate.y0 && Math.max(a.y, b.y) > plate.y1
          : a.y > plate.y0 && a.y < plate.y1 && Math.min(a.x, b.x) < plate.x0 && Math.max(a.x, b.x) > plate.x1));
        if (!sits) continue;
        for (const [other, own] of routes) {
          if (other === m[1]) continue;
          const crosses = own.some(([a, b]) => (a.x === b.x
            ? a.x > plate.x0 && a.x < plate.x1 && Math.max(a.y, b.y) > plate.y0 && Math.min(a.y, b.y) < plate.y1
            : a.y > plate.y0 && a.y < plate.y1 && Math.max(a.x, b.x) > plate.x0 && Math.min(a.x, b.x) < plate.x1));
          if (crosses) under.push(`${name}: ${m[1]} over ${other}`);
        }
      }
    }
    expect(pairs).toHaveLength(4);
    expect([...routesSeen]).toEqual(pairs.map(({ name }) => name));
    expect(under).toEqual([]);
  });

  it('is checked on the decision families that put the two answers on opposite sides', () => {
    // So that the assertion above is not vacuous: these are the drawings it exists for.
    const opposed = SWEEP.filter(({ name }) => name.startsWith('opposed answers'));
    expect(opposed.length).toBe(8);
  });
});
