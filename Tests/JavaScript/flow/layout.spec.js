// FlowPeek's own layout, tested on its own terms.
//
// Nothing here is vendored and nothing here is mermaid's: these are the properties the renderer
// exists to have, and mermaid has none of them. The 4px grid and the rank structure are asserted
// rather than inspected because they are supposed to be true by construction -- a failure here
// means an arithmetic path escaped grid units, not that a number needs rounding.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureText, countingMeasurer } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

// What MacMermaidTheme.swift ships, reduced to the keys the projection reads.
const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  themeVariables: { fontSize: '12px' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32,
    rankSpacing: 40,
    padding: 16,
    diagramPadding: 24,
    curve: 'rounded',
    flowchartCurve: 'step',
    wrappingWidth: 160,
  },
};

function draw(source, options = {}) {
  const db = new flow.FlowDB();
  db.clear();
  flow.parse(source, db);
  return flow.layout(db, {
    measureText: options.measureText || measureText,
    theme: options.theme === undefined ? EDITORIAL : options.theme,
    direction: options.direction,
  });
}

/** Every number the layout hands the next phase, flattened, with a label for the failure message. */
function coordinates(out) {
  const found = [];
  found.push(['width', out.width], ['height', out.height], ['padding', out.padding]);
  for (const n of out.nodes) {
    for (const key of ['x', 'y', 'width', 'height', 'cx', 'cy', 'labelWidth', 'labelHeight', 'lineHeight']) {
      found.push([`node ${n.id}.${key}`, n[key]]);
    }
  }
  for (const c of out.clusters) {
    for (const key of ['x', 'y', 'width', 'height', 'labelX', 'labelY', 'labelWidth', 'labelHeight']) {
      found.push([`cluster ${c.id}.${key}`, c[key]]);
    }
  }
  for (const e of out.edges) {
    found.push([`edge ${e.id}.start.x`, e.start.x], [`edge ${e.id}.start.y`, e.start.y]);
    found.push([`edge ${e.id}.end.x`, e.end.x], [`edge ${e.id}.end.y`, e.end.y]);
    found.push([`edge ${e.id}.labelWidth`, e.labelWidth], [`edge ${e.id}.labelHeight`, e.labelHeight]);
    if (e.channel) found.push([`edge ${e.id}.channel`, e.channel.value]);
    e.via.forEach((p, i) => found.push([`edge ${e.id}.via[${i}].x`, p.x], [`edge ${e.id}.via[${i}].y`, p.y]));
  }
  return found;
}

function offGrid(out) {
  return coordinates(out)
    .filter(([, value]) => !Number.isInteger(value) || value % 4 !== 0)
    .map(([name, value]) => `${name}=${value}`);
}

const byId = (out, id) => out.nodes.find((n) => n.id === id);
const clusterById = (out, id) => out.clusters.find((c) => c.id === id);

describe('[Layout] the 4px grid', () => {
  const sources = [
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
  ];

  for (const source of sources) {
    it(`puts every coordinate on the grid: ${JSON.stringify(source.split('\n')[0])} (${source.split('\n').length} lines)`, () => {
      expect(offGrid(draw(source))).toEqual([]);
    });
  }

  for (const source of sources) {
    it(`keeps every box off every other box: ${JSON.stringify(source.split('\n')[0])} (${source.split('\n').length} lines)`, () => {
      // Not a separate pass: a child occupies one slot in one rank of one level, and a subgraph's
      // whole interior occupies the slot its container took. Overlap is unrepresentable, so this
      // asserts the structure rather than a repair.
      const out = draw(source);
      const boxes = out.nodes.concat(out.clusters.map((c) => ({ ...c, cluster: true })));
      for (let i = 0; i < boxes.length; i += 1) {
        for (let j = i + 1; j < boxes.length; j += 1) {
          const a = boxes[i];
          const b = boxes[j];
          // A container is meant to contain; only two boxes at the same level may not overlap.
          if (a.cluster || b.cluster) continue;
          const hits = a.x < b.x + b.width && b.x < a.x + a.width
            && a.y < b.y + b.height && b.y < a.y + a.height;
          expect(`${a.id}/${b.id}:${hits}`).toBe(`${a.id}/${b.id}:false`);
        }
      }
    });
  }

  for (const source of sources) {
    it(`never runs two connectors along one lane: ${JSON.stringify(source.split('\n')[0])} (${source.split('\n').length} lines)`, () => {
      // SKILL.md §6 rule 3. Layout reserves a lane per edge that has to move sideways, but it reads
      // "sideways" off the two boxes' centres rather than off the fanned ports, so two edges joining
      // the same pair of columns can share one. This is what checks that when they do, the stretches
      // they actually occupy are disjoint -- which is the property the rule is about.
      const out = draw(source);
      const lanes = new Map();
      for (const e of out.edges) {
        if (!e.channel) continue;
        const key = `${e.channel.axis}:${e.channel.value}`;
        const span = e.channel.axis === 'y'
          ? [Math.min(e.start.x, e.end.x), Math.max(e.start.x, e.end.x)]
          : [Math.min(e.start.y, e.end.y), Math.max(e.start.y, e.end.y)];
        if (!lanes.has(key)) lanes.set(key, []);
        for (const other of lanes.get(key)) {
          const overlap = Math.min(span[1], other[1]) - Math.max(span[0], other[0]);
          expect(`${key} overlap ${overlap > 0}`).toBe(`${key} overlap false`);
        }
        lanes.get(key).push(span);
      }
    });
  }

  it('holds the grid when the measurer answers in fractions', () => {
    const jagged = (text, style) => {
      const m = measureText(text, style);
      return { width: m.width + 0.37, height: m.height + 0.91 };
    };
    expect(offGrid(draw(sources[0], { measureText: jagged }))).toEqual([]);
  });

  it('rounds a measured width up, so a box is never narrower than its text', () => {
    // 63.4px of text cannot fit in a 60px box; the only safe direction to round is outward.
    const wide = () => ({ width: 63.4, height: 14.4 });
    const out = draw('flowchart TD\n  A[x] --> B[y]', { measureText: wide });
    const a = byId(out, 'A');
    // padding 16 each side, and the label width is rounded up from 63.4 to 64.
    expect(a.labelWidth).toBe(64);
    expect(a.width).toBeGreaterThanOrEqual(64 + 32);
  });
});

describe('[Layout] ranks', () => {
  it('lays a chain out one rank at a time', () => {
    const out = draw('flowchart TD\n  A --> B --> C --> D');
    expect(out.nodes.map((n) => n.rank)).toEqual([0, 1, 2, 3]);
    const ys = out.nodes.map((n) => n.cy);
    for (let i = 1; i < ys.length; i += 1) expect(ys[i]).toBeGreaterThan(ys[i - 1]);
    // One node per rank, so every one of them shares a centre line.
    expect(new Set(out.nodes.map((n) => n.cx)).size).toBe(1);
  });

  it('gives a branch and its two arms three ranks, not four', () => {
    const out = draw('flowchart TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D');
    expect(byId(out, 'A').rank).toBe(0);
    expect(byId(out, 'B').rank).toBe(1);
    expect(byId(out, 'C').rank).toBe(1);
    expect(byId(out, 'D').rank).toBe(2);
    expect(byId(out, 'B').cy).toBe(byId(out, 'C').cy);
    expect(byId(out, 'B').cx).not.toBe(byId(out, 'C').cx);
  });

  it('honours the link length an author wrote', () => {
    // `----` is mermaid's own way of asking for more ranks; dropping it would make the author's
    // spacing silently mean nothing.
    const out = draw('flowchart TD\n  A ----> B');
    expect(byId(out, 'B').rank).toBe(3);
  });

  it('does not hang on a cycle', () => {
    const out = draw('flowchart TD\n  A --> B --> C --> A');
    expect(out.nodes.map((n) => n.rank)).toEqual([0, 1, 2]);
    expect(out.edges.length).toBe(3);
  });

  it('keeps the ranks apart by at least the theme rank spacing', () => {
    const out = draw('flowchart TD\n  A[one] --> B[two]');
    const a = byId(out, 'A');
    const b = byId(out, 'B');
    expect(b.y - (a.y + a.height)).toBeGreaterThanOrEqual(40);
  });
});

describe('[Layout] direction', () => {
  const source = 'flowchart DIR\n  A[first] --> B[second] --> C[third] --> D[fourth]';

  it('turns the same chain on its side for LR', () => {
    const td = draw(source.replace('DIR', 'TD'));
    const lr = draw(source.replace('DIR', 'LR'));
    expect(td.height).toBeGreaterThan(td.width);
    expect(lr.width).toBeGreaterThan(lr.height);
    // Same boxes, different arrangement: the nodes are not rotated with the drawing.
    expect(lr.nodes.map((n) => n.width)).toEqual(td.nodes.map((n) => n.width));
    expect(lr.nodes.map((n) => n.height)).toEqual(td.nodes.map((n) => n.height));
  });

  it('runs rank 0 to the left in LR and to the right in RL', () => {
    const lr = draw(source.replace('DIR', 'LR'));
    const rl = draw(source.replace('DIR', 'RL'));
    expect(byId(lr, 'A').cx).toBeLessThan(byId(lr, 'D').cx);
    expect(byId(rl, 'A').cx).toBeGreaterThan(byId(rl, 'D').cx);
    expect(lr.width).toBe(rl.width);
    expect(lr.height).toBe(rl.height);
  });

  it('runs rank 0 to the bottom in BT', () => {
    const tb = draw(source.replace('DIR', 'TD'));
    const bt = draw(source.replace('DIR', 'BT'));
    expect(byId(bt, 'A').cy).toBeGreaterThan(byId(bt, 'D').cy);
    expect(bt.width).toBe(tb.width);
    expect(bt.height).toBe(tb.height);
  });

  it('defaults to top-down when the source names no direction', () => {
    const out = draw('graph\n  A --> B');
    expect(out.direction).toBe('TB');
    expect(byId(out, 'A').cy).toBeLessThan(byId(out, 'B').cy);
  });
});

describe('[Layout] subgraphs', () => {
  const nested = [
    'flowchart TD',
    '  subgraph outer["Outer tier"]',
    '    subgraph inner["Inner tier"]',
    '      A[alpha] --> B[beta]',
    '    end',
    '    B --> C[gamma]',
    '  end',
    '  C --> D[delta]',
  ].join('\n');

  function contains(box, inner) {
    return inner.x >= box.x
      && inner.y >= box.y
      && inner.x + inner.width <= box.x + box.width
      && inner.y + inner.height <= box.y + box.height;
  }

  it('sizes a container around everything inside it', () => {
    const out = draw(nested);
    const outer = clusterById(out, 'outer');
    const inner = clusterById(out, 'inner');
    expect(contains(inner, byId(out, 'A'))).toBe(true);
    expect(contains(inner, byId(out, 'B'))).toBe(true);
    expect(contains(outer, inner)).toBe(true);
    expect(contains(outer, byId(out, 'C'))).toBe(true);
    // D is outside the group, and the group's box says so.
    expect(contains(outer, byId(out, 'D'))).toBe(false);
  });

  it('records the nesting the parser saw, not one recovered from the boxes', () => {
    const out = draw(nested);
    expect(clusterById(out, 'inner').parent).toBe('outer');
    expect(clusterById(out, 'outer').parent).toBe(null);
    expect(clusterById(out, 'inner').depth).toBe(1);
    expect(byId(out, 'A').parent).toBe('inner');
    expect(byId(out, 'C').parent).toBe('outer');
    expect(byId(out, 'D').parent).toBe(null);
  });

  it('leaves a header band for the zone eyebrow', () => {
    const out = draw(nested);
    const inner = clusterById(out, 'inner');
    expect(inner.titleLines).toEqual(['Inner tier']);
    const first = Math.min(byId(out, 'A').y, byId(out, 'B').y);
    // dd-arch.md: at least 16px between the bottom of the eyebrow and the first enclosed node.
    expect(first - (inner.labelY + inner.labelHeight)).toBeGreaterThanOrEqual(16);
  });

  it('keeps a subgraph member out of an outer rank', () => {
    // Both A and B are in `inner`, so they rank against each other and never against C or D.
    const out = draw(nested);
    expect(byId(out, 'A').rank).toBe(0);
    expect(byId(out, 'B').rank).toBe(1);
    expect(byId(out, 'C').rank).toBe(1);
    expect(clusterById(out, 'inner').rank).toBe(0);
  });

  it('gives a subgraph its own direction when the source asks for one', () => {
    const out = draw([
      'flowchart TD',
      '  subgraph s1',
      '    direction LR',
      '    A --> B',
      '  end',
      '  s1 --> C',
    ].join('\n'));
    expect(clusterById(out, 's1').direction).toBe('LR');
    expect(byId(out, 'A').cy).toBe(byId(out, 'B').cy);
    expect(byId(out, 'A').cx).toBeLessThan(byId(out, 'B').cx);
  });

  it('sizes an empty subgraph without collapsing it', () => {
    const out = draw('flowchart TD\n  subgraph s1["Nothing yet"]\n  end\n  A --> B');
    const s1 = clusterById(out, 's1');
    expect(s1.width).toBeGreaterThan(0);
    expect(s1.height).toBeGreaterThan(0);
    expect(offGrid(out)).toEqual([]);
  });
});

describe('[Layout] node size', () => {
  it('takes its width from the label', () => {
    const out = draw('flowchart TD\n  A[ok] --> B[a considerably longer label]');
    expect(byId(out, 'B').width).toBeGreaterThan(byId(out, 'A').width);
  });

  it('never lets a box be narrower than its own text', () => {
    const out = draw('flowchart TD\n  A[a considerably longer label] --> B[x]');
    const a = byId(out, 'A');
    expect(a.width).toBeGreaterThanOrEqual(a.labelWidth);
    expect(a.height).toBeGreaterThanOrEqual(a.labelHeight);
  });

  it('wraps at the theme wrapping width and grows downward', () => {
    const one = draw('flowchart TD\n  A[short] --> B[x]');
    const many = draw('flowchart TD\n  A[a label long enough that it has to be broken over several lines to fit] --> B[x]');
    expect(byId(many, 'A').lines.length).toBeGreaterThan(1);
    expect(byId(many, 'A').labelWidth).toBeLessThanOrEqual(160);
    expect(byId(many, 'A').height).toBeGreaterThan(byId(one, 'A').height);
  });

  it('honours a <br/> as a line break and nothing else as markup', () => {
    const out = draw('flowchart TD\n  A["first<br/>second"] --> B[x]');
    expect(byId(out, 'A').lines).toEqual(['first', 'second']);
  });

  it('breaks a run that has no spaces in it at all', () => {
    // Korean carries no break opportunities, so a greedy word wrap alone would leave one long line
    // and a node wider than the wrapping width.
    const out = draw('flowchart TD\n  A["문서를읽고판단하여결과를저장하는단계"] --> B[x]');
    expect(byId(out, 'A').lines.length).toBeGreaterThan(1);
    expect(byId(out, 'A').labelWidth).toBeLessThanOrEqual(160);
  });

  it('gives a wide character its full em', () => {
    const latin = draw('flowchart TD\n  A[abcd] --> B[x]');
    const hangul = draw('flowchart TD\n  A[가나다라] --> B[x]');
    expect(byId(hangul, 'A').labelWidth).toBeGreaterThan(byId(latin, 'A').labelWidth);
  });

  it('gives a diamond room its label actually fits in', () => {
    // A w*h rectangle is inscribed in a rhombus of diagonals W*H exactly when w/W + h/H = 1, so the
    // diamond has to be wider than the rectangle that holds the same words. It is not always
    // taller: a single line of type already leaves the minimum height with room over it.
    const rect = draw('flowchart TD\n  A[Is it ready] --> B[x]');
    const diamond = draw('flowchart TD\n  A{Is it ready} --> B[x]');
    expect(byId(diamond, 'A').width).toBeGreaterThan(byId(rect, 'A').width);
    expect(byId(diamond, 'A').height).toBeGreaterThanOrEqual(2 * byId(diamond, 'A').labelHeight);
  });

  it('makes a circle square', () => {
    const out = draw('flowchart TD\n  A((go)) --> B[x]');
    const a = byId(out, 'A');
    expect(a.width).toBe(a.height);
  });

  it('measures each wrapped line once and no more', () => {
    const counter = countingMeasurer();
    draw('flowchart TD\n  A[Start] --> B[Start]\n  B --> C[Start]', { measureText: counter });
    const starts = counter.calls.filter((t) => t === 'Start');
    expect(starts.length).toBe(1);
  });
});

describe('[Layout] edges', () => {
  it('reports the ranks and ports each edge has to join', () => {
    const out = draw('flowchart TD\n  A[one] --> B[two]');
    const [edge] = out.edges;
    expect(edge.fromRank).toBe(0);
    expect(edge.toRank).toBe(1);
    expect(edge.start.side).toBe('bottom');
    expect(edge.end.side).toBe('top');
    const a = byId(out, 'A');
    const b = byId(out, 'B');
    expect(edge.start.y).toBe(a.y + a.height);
    expect(edge.end.y).toBe(b.y);
  });

  it('turns the ports round in BT, so an arrow still arrives from the rank behind it', () => {
    const out = draw('flowchart BT\n  A[one] --> B[two]');
    const [edge] = out.edges;
    expect(edge.start.side).toBe('top');
    expect(edge.end.side).toBe('bottom');
  });

  it('uses the side faces in LR', () => {
    const out = draw('flowchart LR\n  A[one] --> B[two]');
    const [edge] = out.edges;
    expect(edge.start.side).toBe('right');
    expect(edge.end.side).toBe('left');
  });

  it('gives every connector on a face its own attach point', () => {
    // SKILL.md §6 rule 4: no two connectors may share a single point on a box.
    const out = draw('flowchart TD\n  A --> B\n  A --> C\n  A --> D');
    const fromA = out.edges.filter((e) => e.from === 'A');
    expect(fromA.length).toBe(3);
    const points = fromA.map((e) => `${e.start.x},${e.start.y}`);
    expect(new Set(points).size).toBe(3);
    const xs = fromA.map((e) => e.start.x).sort((p, q) => p - q);
    expect(xs[1] - xs[0]).toBeGreaterThanOrEqual(8);
    expect(xs[2] - xs[1]).toBeGreaterThanOrEqual(8);
  });

  it('centres the one connector on a face', () => {
    const out = draw('flowchart TD\n  A[one] --> B[two]');
    const a = byId(out, 'A');
    expect(out.edges[0].start.x).toBe(a.cx);
  });

  it('reserves a lane between the ranks for an edge that has to move sideways', () => {
    const out = draw('flowchart TD\n  A --> B\n  A --> C');
    for (const edge of out.edges) {
      expect(edge.channel).not.toBe(null);
      expect(edge.channel.axis).toBe('y');
      const a = byId(out, 'A');
      const target = byId(out, edge.to);
      expect(edge.channel.value).toBeGreaterThan(a.y + a.height);
      expect(edge.channel.value).toBeLessThan(target.y);
    }
    // Two edges moving sideways in one gap get lanes of their own, 12px apart at least.
    const lanes = out.edges.map((e) => e.channel.value);
    expect(new Set(lanes).size).toBe(2);
    expect(Math.abs(lanes[0] - lanes[1])).toBeGreaterThanOrEqual(12);
  });

  it('reserves a corridor through every rank a long edge passes', () => {
    const out = draw('flowchart TD\n  A --> B --> C --> D\n  A --> D');
    const long = out.edges.find((e) => e.from === 'A' && e.to === 'D');
    expect(long.via.length).toBe(2);
    for (const point of long.via) {
      // The corridor is clear of every node in the rank it crosses.
      for (const node of out.nodes) {
        const inside = point.x > node.x && point.x < node.x + node.width
          && point.y > node.y && point.y < node.y + node.height;
        expect(inside).toBe(false);
      }
    }
  });

  it('hands a back edge its corridor and its lane from the end it leaves', () => {
    const out = draw('flowchart TD\n  A --> B --> C --> D\n  D --> A');
    const back = out.edges.find((e) => e.from === 'D' && e.to === 'A');
    expect(back.fromRank).toBe(3);
    expect(back.toRank).toBe(0);
    expect(back.start.side).toBe('top');
    expect(back.end.side).toBe('bottom');
    // Travel order, so the first corridor point is the one nearest D.
    expect(back.via.length).toBe(2);
    expect(back.via[0].y).toBeGreaterThan(back.via[1].y);
    // The lane is in the gap D has to get clear of, not the one it eventually arrives in.
    expect(back.channel.value).toBeLessThan(byId(out, 'D').y);
    expect(back.channel.value).toBeGreaterThan(byId(out, 'C').y + byId(out, 'C').height);
  });

  it('carries the pattern and weight the source asked for', () => {
    const out = draw('flowchart TD\n  A -.-> B\n  B ==> C\n  C --> D');
    expect(out.edges[0].pattern).toBe('dotted');
    expect(out.edges[0].thickness).toBe('normal');
    expect(out.edges[1].pattern).toBe('solid');
    expect(out.edges[1].thickness).toBe('thick');
    expect(out.edges[2].pattern).toBe('solid');
  });

  it('sizes an edge label and reserves the gap for it', () => {
    const bare = draw('flowchart TD\n  A --> B');
    const tall = draw('flowchart TD\n  A -->|a label long enough that it has to wrap onto more than one line| B');
    const labelled = tall.edges[0];
    expect(labelled.labelLines.length).toBeGreaterThan(1);
    expect(labelled.labelWidth).toBeGreaterThan(0);
    const gapBare = byId(bare, 'B').y - (byId(bare, 'A').y + byId(bare, 'A').height);
    const gapTall = byId(tall, 'B').y - (byId(tall, 'A').y + byId(tall, 'A').height);
    expect(gapTall).toBeGreaterThan(gapBare);
    expect(gapTall).toBeGreaterThanOrEqual(labelled.labelHeight);
  });

  it('gives a self-loop two distinct ports on one face', () => {
    const out = draw('flowchart TD\n  A --> B\n  B --> B');
    const loop = out.edges.find((e) => e.from === 'B' && e.to === 'B');
    expect(loop.selfLoop).toBe(true);
    expect(loop.start.side).toBe('right');
    expect(loop.end.side).toBe('right');
    expect(loop.start.y).not.toBe(loop.end.y);
  });
});

describe('[Layout] the ladder', () => {
  it('names a rung for every node from the graph shape', () => {
    const out = draw('flowchart TD\n  A[in] --> B[work] --> C[(store)]\n  B --> D[out]');
    expect(byId(out, 'A').rung).toBe('entry');
    expect(byId(out, 'C').rung).toBe('store');
    expect(byId(out, 'D').rung).toBe('terminal');
    expect(out.counts.rungs.entry).toBe(1);
    expect(out.counts.rungs.store).toBe(1);
  });

  it('marks a node reached only by a dotted link as optional', () => {
    const out = draw('flowchart TD\n  A --> B\n  B -.-> C\n  C -.-> D');
    expect(byId(out, 'C').rung).toBe('optional');
  });

  it('abstains from an accent unless one node is genuinely the busiest', () => {
    const chain = draw('flowchart TD\n  A --> B --> C --> D --> E');
    expect(chain.counts.rungs.focal).toBe(0);

    const hub = draw([
      'flowchart TD',
      '  A --> H',
      '  B --> H',
      '  C --> H',
      '  H --> D',
      '  H --> E',
    ].join('\n'));
    expect(hub.counts.rungs.focal).toBe(1);
    expect(byId(hub, 'H').rung).toBe('focal');
  });

  it('says nothing at all about a diagram with no edges', () => {
    const out = draw('flowchart TD\n  A\n  B');
    expect(out.nodes.every((n) => n.rung === null)).toBe(true);
    expect(out.counts.rungs.backend).toBe(0);
  });

  it('never names a node in what it reports', () => {
    const out = draw('flowchart TD\n  subgraph secret["a private scope"]\n    Payroll --> Ledger\n  end\n  Ledger --> Audit');
    const json = JSON.stringify(out.counts);
    expect(json).not.toContain('Payroll');
    expect(json).not.toContain('secret');
    expect(out.counts).toEqual({
      nodes: 3,
      edges: 2,
      zones: 1,
      rungs: expect.any(Object),
    });
  });
});

describe('[Layout] determinism', () => {
  const source = [
    'flowchart TD',
    '  subgraph zone["A zone"]',
    '    A[Start] --> B{Ready?}',
    '  end',
    '  B -->|yes| C[(Store)]',
    '  B -->|no| A',
    '  C --> D((Done))',
  ].join('\n');

  it('draws the same source the same way twice', () => {
    expect(draw(source)).toEqual(draw(source));
  });

  it('does not depend on anything that survives a render', () => {
    const first = draw(source);
    draw('flowchart LR\n  X --> Y --> Z');
    draw('flowchart BT\n  P --> Q');
    expect(draw(source)).toEqual(first);
  });

  it('is unchanged by two hosts whose metrics land in the same grid step', () => {
    // What quantizing on entry buys, stated exactly: 36.1px and 36.9px are both 10 units, so two
    // font engines that disagree by a fraction draw the same diagram. It does not buy agreement
    // across a step boundary -- 36.0 and 36.4 are 9 units and 10 -- and claiming it would be a
    // promise the arithmetic does not make.
    const fixed = (width) => () => ({ width, height: 14.4 });
    expect(draw(source, { measureText: fixed(61.2) })).toEqual(draw(source, { measureText: fixed(63.9) }));
    expect(draw(source, { measureText: fixed(60) })).not.toEqual(draw(source, { measureText: fixed(63.9) }));
  });
});

describe('[Layout] contract', () => {
  it('refuses to guess a width when there is no measurer', () => {
    const db = new flow.FlowDB();
    db.clear();
    flow.parse('flowchart TD\n  A --> B', db);
    expect(() => flow.layout(db, {})).toThrow(/measureText/);
  });

  it('gives an empty diagram a positive size', () => {
    const out = draw('flowchart TD\n');
    expect(out.width).toBeGreaterThan(0);
    expect(out.height).toBeGreaterThan(0);
    expect(out.nodes).toEqual([]);
  });

  it('falls back to the shipped arrangement when the theme says nothing', () => {
    const out = draw('flowchart TD\n  A --> B', { theme: {} });
    expect(out.padding).toBe(24);
    expect(offGrid(out)).toEqual([]);
  });

  it('rounds an off-grid arrangement up, once, at projection time', () => {
    const theme = flow.buildFlowTheme({ arrangement: { nodeSpacing: 33, rankSpacing: 41, padding: 17, diagramPadding: 25 } });
    expect(theme.arrangement.nodeSpacing).toBe(36);
    expect(theme.arrangement.rankSpacing).toBe(44);
    expect(theme.arrangement.padding).toBe(20);
    expect(theme.arrangement.diagramPadding).toBe(28);
  });

  it('holds the 12px type floor a Hangul label depends on', () => {
    expect(flow.buildFlowTheme({ themeVariables: { fontSize: '8px' } }).fontSizePX).toBe(12);
    expect(flow.buildFlowTheme({ themeVariables: { fontSize: '15px' } }).fontSizePX).toBe(15);
  });

  it('keeps the whole drawing inside the diagram padding', () => {
    const out = draw('flowchart TD\n  A[one] --> B[two]\n  A --> C[three]');
    for (const node of out.nodes) {
      expect(node.x).toBeGreaterThanOrEqual(24);
      expect(node.y).toBeGreaterThanOrEqual(24);
      expect(node.x + node.width).toBeLessThanOrEqual(out.width - 24);
      expect(node.y + node.height).toBeLessThanOrEqual(out.height - 24);
    }
  });
});
