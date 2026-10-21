#!/usr/bin/env node

// Differential geometry measurements for FlowPeek's two flowchart renderers.
//
// This deliberately reads the emitted SVG rather than either engine's internal model. The unit is
// therefore what a reader receives: masks, strokes, turns, and the final viewport. Run from any
// directory with `/opt/homebrew/bin/node Scripts/differential.mjs`.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
// The repository intentionally has no package `type`. Loading these two dependency-free ESM test
// helpers through data URLs avoids Node's typeless-package warning without changing package.json.
const importSource = async (path) => import(`data:text/javascript;base64,${Buffer.from(readFileSync(path, 'utf8')).toString('base64')}`);
const { SWEEP } = await importSource(join(root, 'Tests/JavaScript/flow/corpus.js'));
const { measureText } = await importSource(join(root, 'Tests/JavaScript/flow/measure.js'));
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));
const peleSource = readFileSync(join(root, 'Sources/FlowPeek/Resources/pele.global.js'), 'utf8');
// Pele's browser bundle declares `var pele` rather than exporting CommonJS. Evaluating the vendored
// file in an empty context gives it the same no-DOM environment FlowPeek's direct render call uses.
const pele = vm.runInNewContext(`${peleSource}\n;pele`, { console });

// Copied from Tests/JavaScript/flow/render.spec.js. This is the payload used by the editorial theme,
// including the deterministic host text measurer below.
const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  monoFontFamily: "'Geist', sans-serif",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }\n.node rect.basic:not([rx]) { rx: 6px; ry: 6px; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

// The light editorial palette mapped exactly as MacMermaidTheme.swift's `pele` factory maps it.
// These are paint-only CSS custom properties: `pele.render(source)` decides geometry before a host
// attaches the SVG and supplies the variables, so passing or splicing them cannot change any metric
// below. Keeping the map here documents that the comparison uses the same palette while correctly
// skipping a geometry-neutral mutation of Pele's markup.
const PELE_EDITORIAL = {
  '--pele-bg': '#F5F5F5', '--pele-fg': '#2D3142', '--pele-muted': '#4F5D75',
  '--pele-line': '#2D3142', '--pele-surface': '#E5E5E7', '--pele-surface-alt': '#D5D6D8',
  '--pele-border': '#7A8399', '--pele-accent': '#B24212', '--pele-critical': '#D72422',
  '--pele-radius': '6px',
  '--pele-font': "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif",
  '--pele-font-mono': "ui-monospace, 'SF Mono', Menlo, 'Apple SD Gothic Neo', monospace",
  '--pele-series-1': '#B24212', '--pele-series-2': '#2E5AA8', '--pele-series-3': '#3E7737',
  '--pele-series-4': '#8B507B', '--pele-series-5': '#846B0B', '--pele-series-6': '#6C5040',
  '--pele-series-7': '#765EB1', '--pele-series-8': '#336360',
};
void PELE_EDITORIAL;

const REPORTED = [
  ['reported/nego', [
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
  ].join('\n')],
  ['reported/reelect', [
    'flowchart TB',
    '    OPa["Original (Hauler1)<br/>derivedQuoteId: Nego-H3"]',
    '    subgraph reelect["QuoteStatusChangedEvent 수신 후 재선정"]',
    '        N3a["Nego-H3<br/>status: Quoted<br/>isRepresentative: true"]',
    '        N2a["Nego-H2<br/>status: Requested<br/>isRepresentative: false"]',
    '        N1a["Nego-H1<br/>status: Requested<br/>isRepresentative: false"]',
    '    end',
    '    OPa -. "derivedQuoteId 갱신" .-> N3a',
  ].join('\n')],
  ['reported/cand', [
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
  ].join('\n')],
];

const DRAWINGS = [
  ...SWEEP.map((drawing, index) => ({ ...drawing, name: `SWEEP ${String(index + 1).padStart(3, '0')} / ${drawing.name}` })),
  ...REPORTED.map(([name, source]) => ({ name, source })),
];
const NUMBER = /-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/i;

function attr(tag, name) {
  const match = new RegExp(`\\b${name}="([^"]*)"`).exec(tag);
  return match?.[1] ?? null;
}

function dimensions(svg) {
  const tag = /^<svg\b[^>]*>/.exec(svg)?.[0] ?? '';
  const width = Number(attr(tag, 'width'));
  const height = Number(attr(tag, 'height'));
  if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) return { width, height };
  const values = (attr(tag, 'viewBox')?.match(new RegExp(NUMBER.source, 'gi')) ?? []).map(Number);
  return values.length === 4 ? { width: values[2], height: values[3] } : null;
}

function tokenizePath(d) {
  return d.match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?/g) ?? [];
}

// Both engines emit orthogonal flow routes, with quadratic commands used to round a corner. Curves
// are sampled for length/intersection measurements, while their control point remains the logical
// corner for bend counting. SVG arcs are treated as their chord: FlowPeek uses them for crossover
// bridges, not routing turns, and neither adapter can recover the obscured straight run otherwise.
function pathGeometry(d) {
  const tokens = tokenizePath(d);
  const geometry = [];
  const skeleton = [];
  let i = 0;
  let command = null;
  let current = { x: 0, y: 0 };
  let start = current;
  const push = (array, point) => {
    const last = array[array.length - 1];
    if (!last || Math.abs(last.x - point.x) > 1e-7 || Math.abs(last.y - point.y) > 1e-7) array.push(point);
  };
  const point = (x, y, relative) => ({ x: relative ? current.x + x : x, y: relative ? current.y + y : y });
  while (i < tokens.length) {
    if (/^[a-zA-Z]$/.test(tokens[i])) command = tokens[i++];
    if (!command) break;
    const upper = command.toUpperCase();
    const relative = command !== upper;
    const arity = { M: 2, L: 2, H: 1, V: 1, Q: 4, C: 6, A: 7, Z: 0 }[upper];
    if (arity === undefined) break;
    if (upper === 'Z') {
      push(geometry, start); push(skeleton, start); current = start; command = null; continue;
    }
    if (i + arity > tokens.length || /^[a-zA-Z]$/.test(tokens[i])) { command = null; continue; }
    const n = tokens.slice(i, i + arity).map(Number); i += arity;
    if (upper === 'M') {
      current = point(n[0], n[1], relative); start = current;
      push(geometry, current); push(skeleton, current);
      command = relative ? 'l' : 'L';
    } else if (upper === 'L') {
      current = point(n[0], n[1], relative); push(geometry, current); push(skeleton, current);
    } else if (upper === 'H') {
      current = { x: relative ? current.x + n[0] : n[0], y: current.y };
      push(geometry, current); push(skeleton, current);
    } else if (upper === 'V') {
      current = { x: current.x, y: relative ? current.y + n[0] : n[0] };
      push(geometry, current); push(skeleton, current);
    } else if (upper === 'Q') {
      const from = current;
      const control = point(n[0], n[1], relative);
      const end = point(n[2], n[3], relative);
      push(skeleton, control); push(skeleton, end);
      for (let step = 1; step <= 8; step += 1) {
        const t = step / 8;
        push(geometry, {
          x: (1 - t) ** 2 * from.x + 2 * (1 - t) * t * control.x + t ** 2 * end.x,
          y: (1 - t) ** 2 * from.y + 2 * (1 - t) * t * control.y + t ** 2 * end.y,
        });
      }
      current = end;
    } else if (upper === 'C') {
      const from = current;
      const c1 = point(n[0], n[1], relative);
      const c2 = point(n[2], n[3], relative);
      const end = point(n[4], n[5], relative);
      push(skeleton, c1); push(skeleton, c2); push(skeleton, end);
      for (let step = 1; step <= 12; step += 1) {
        const t = step / 12;
        push(geometry, {
          x: (1 - t) ** 3 * from.x + 3 * (1 - t) ** 2 * t * c1.x + 3 * (1 - t) * t ** 2 * c2.x + t ** 3 * end.x,
          y: (1 - t) ** 3 * from.y + 3 * (1 - t) ** 2 * t * c1.y + 3 * (1 - t) * t ** 2 * c2.y + t ** 3 * end.y,
        });
      }
      current = end;
    } else if (upper === 'A') {
      current = point(n[5], n[6], relative); push(geometry, current); push(skeleton, current);
    }
  }
  return { points: geometry, skeleton };
}

function pathElement(tag) {
  const d = attr(tag, 'd');
  return d === null ? null : pathGeometry(d);
}

function labelLines(body) {
  const tspans = [...body.matchAll(/<tspan\b/g)].length;
  return tspans || [...body.matchAll(/<text\b/g)].length || 1;
}

/**
 * FlowPeek adapter. It can see the explicit edge data-id, absolute route path, translated backing
 * rect, and emitted line tspans. It cannot see CSS-resolved stroke widths or infer labels without a
 * backing rect, and it intentionally ignores marker paths and non-edge decorative strokes.
 */
function adaptFlowPeek(svg) {
  const edges = [];
  for (const match of svg.matchAll(/<path\b[^>]*class="[^"]*\bedge-thickness-[^"]*"[^>]*>/g)) {
    const geometry = pathElement(match[0]);
    const id = attr(match[0], 'data-id');
    if (geometry && id !== null) edges.push({ id, ...geometry });
  }
  const labels = [];
  const re = /<g class="label[^"]*" data-id="([^"]*)" transform="translate\(([-\d.]+)[ ,]([-\d.]+)\)">([\s\S]*?)<\/g>/g;
  for (const match of svg.matchAll(re)) {
    const rect = /<rect\b[^>]*class="background"[^>]*>/.exec(match[4])?.[0];
    if (!rect) continue;
    labels.push({
      id: match[1], x: Number(match[2]) + Number(attr(rect, 'x')),
      y: Number(match[3]) + Number(attr(rect, 'y')),
      width: Number(attr(rect, 'width')), height: Number(attr(rect, 'height')),
      lines: labelLines(match[4]),
    });
  }
  return { engine: 'ours', edges, labels, size: dimensions(svg),
    coverage: {
      rootVocabulary: /<svg\b[^>]*class="flowchart"/.test(svg),
      edgeVocabulary: svg.includes('class="edgePaths"'),
      // FlowPeek emits edgeLabels even when empty; this distinguishes a real zero from a miss.
      labelVocabulary: svg.includes('class="edgeLabels"'),
    } };
}

/**
 * Pele adapter. It can see each `pele-edge` wrapper/data-id, its first non-marker path, and direct
 * edge-label rect/tspans. It cannot recover a route split across unexpected extra path elements,
 * CSS-resolved widths, or strokes outside `pele-edge`; marker geometry is deliberately excluded.
 * Flowchart edge and label coordinates are already in the root frame, so no transform is guessed.
 */
function adaptPele(svg) {
  const edges = [];
  const edgeRe = /<g class="pele-edge(?:\s[^"]*)?" data-id="([^"]*)">([\s\S]*?)<\/g>/g;
  for (const match of svg.matchAll(edgeRe)) {
    const paths = [...match[2].matchAll(/<path\b[^>]*>/g)].map((item) => item[0]);
    const route = paths.find((tag) => !/class="[^"]*pele-marker/.test(tag));
    const geometry = route ? pathElement(route) : null;
    if (geometry) edges.push({ id: match[1], ...geometry });
  }
  const labels = [];
  const labelRe = /<g class="pele-edge-label(?:\s[^"]*)?" data-id="([^"]*)">([\s\S]*?)<\/g>/g;
  for (const match of svg.matchAll(labelRe)) {
    const rect = /<rect\b[^>]*>/.exec(match[2])?.[0];
    if (!rect) continue;
    labels.push({
      id: match[1], x: Number(attr(rect, 'x')), y: Number(attr(rect, 'y')),
      width: Number(attr(rect, 'width')), height: Number(attr(rect, 'height')),
      lines: labelLines(match[2]),
    });
  }
  return { engine: 'Pele', edges, labels, size: dimensions(svg),
    coverage: {
      rootVocabulary: /<svg\b[^>]*class="pele pele-flowchart"/.test(svg),
      edgeVocabulary: svg.includes('class="pele-edges"'),
      // Pele omits the entire label group for a legitimate zero, so root + edge vocabulary prove
      // adapter applicability; this flag is reported, not used to turn an absent group into error.
      labelVocabulary: svg.includes('class="pele-edge-labels"'),
    } };
}

function segments(points) {
  const result = [];
  for (let i = 1; i < points.length; i += 1) result.push([points[i - 1], points[i]]);
  return result;
}

function orientation(a, b, c) { return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); }

function properCrossing([a, b], [c, d]) {
  const e = 1e-7;
  const abC = orientation(a, b, c), abD = orientation(a, b, d);
  const cdA = orientation(c, d, a), cdB = orientation(c, d, b);
  return abC * abD < -e && cdA * cdB < -e;
}

function pointToSegment(point, [a, b]) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const denominator = dx * dx + dy * dy;
  const t = denominator === 0 ? 0 : Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / denominator));
  return Math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy));
}

function inRect(point, rect) {
  return point.x >= rect.x && point.x <= rect.x + rect.width && point.y >= rect.y && point.y <= rect.y + rect.height;
}

function rectEdges(rect) {
  const a = { x: rect.x, y: rect.y }, b = { x: rect.x + rect.width, y: rect.y };
  const c = { x: rect.x + rect.width, y: rect.y + rect.height }, d = { x: rect.x, y: rect.y + rect.height };
  return [[a, b], [b, c], [c, d], [d, a]];
}

function segmentTouchesRect(segment, rect) {
  if (inRect(segment[0], rect) || inRect(segment[1], rect)) return true;
  return rectEdges(rect).some((edge) => properCrossing(segment, edge)
    || Math.abs(orientation(segment[0], segment[1], edge[0])) < 1e-7 && pointToSegment(edge[0], segment) < 1e-7
    || Math.abs(orientation(segment[0], segment[1], edge[1])) < 1e-7 && pointToSegment(edge[1], segment) < 1e-7);
}

function segmentToRect(segment, rect) {
  if (segmentTouchesRect(segment, rect)) return 0;
  const corners = rectEdges(rect).map(([point]) => point);
  const dx = (point) => Math.hypot(
    Math.max(rect.x - point.x, 0, point.x - rect.x - rect.width),
    Math.max(rect.y - point.y, 0, point.y - rect.y - rect.height),
  );
  return Math.min(dx(segment[0]), dx(segment[1]), ...corners.map((point) => pointToSegment(point, segment)));
}

function rectsOverlap(a, b) {
  return a.x < b.x + b.width && b.x < a.x + a.width
    && a.y < b.y + b.height && b.y < a.y + a.height;
}

function bendsOf(skeleton) {
  let bends = 0;
  for (let i = 2; i < skeleton.length; i += 1) {
    const a = skeleton[i - 2], b = skeleton[i - 1], c = skeleton[i];
    const ab = Math.hypot(b.x - a.x, b.y - a.y), bc = Math.hypot(c.x - b.x, c.y - b.y);
    if (ab > 1e-7 && bc > 1e-7 && Math.abs(orientation(a, b, c)) / (ab * bc) > 1e-4) bends += 1;
  }
  return bends;
}

function measure(model) {
  if (!model.coverage.rootVocabulary || !model.coverage.edgeVocabulary || !model.size) {
    return { available: false, reason: 'adapter root/edge vocabulary or viewport not found' };
  }
  let maskMask = 0;
  for (let i = 0; i < model.labels.length; i += 1) {
    for (let j = i + 1; j < model.labels.length; j += 1) if (rectsOverlap(model.labels[i], model.labels[j])) maskMask += 1;
  }
  let maskForeignStroke = 0;
  const foreignDistances = [];
  for (const label of model.labels) {
    const foreign = model.edges.filter((edge) => edge.id !== label.id).flatMap((edge) => segments(edge.points));
    if (foreign.length === 0) continue;
    const distance = Math.min(...foreign.map((segment) => segmentToRect(segment, label)));
    foreignDistances.push(distance);
    if (distance === 0) maskForeignStroke += 1;
  }
  let crossings = 0;
  for (let i = 0; i < model.edges.length; i += 1) {
    for (let j = i + 1; j < model.edges.length; j += 1) {
      for (const a of segments(model.edges[i].points)) {
        for (const b of segments(model.edges[j].points)) if (properCrossing(a, b)) crossings += 1;
      }
    }
  }
  const bends = model.edges.reduce((sum, edge) => sum + bendsOf(edge.skeleton), 0);
  const strokeLength = model.edges.reduce((sum, edge) => sum + segments(edge.points)
    .reduce((length, [a, b]) => length + Math.hypot(b.x - a.x, b.y - a.y), 0), 0);
  return {
    available: true,
    edgeCount: model.edges.length,
    labelCount: model.labels.length,
    maskMask,
    maskForeignStroke,
    crossings,
    bends,
    bendsPerEdge: model.edges.length ? bends / model.edges.length : null,
    strokeLength,
    area: model.size.width * model.size.height,
    wrappedLabels: model.labels.filter((label) => label.lines >= 2).length,
    labelLines: model.labels.reduce((sum, label) => sum + label.lines, 0),
    foreignDistances,
    nearestForeignMean: foreignDistances.length ? foreignDistances.reduce((a, b) => a + b, 0) / foreignDistances.length : null,
    nearestForeignMin: foreignDistances.length ? Math.min(...foreignDistances) : null,
  };
}

function renderOurs(source, index) {
  const output = flow.render({
    source, renderID: `diff-${index}`, diagramType: 'flowchart-v2', theme: EDITORIAL, measureText,
  });
  if (output.reason) throw new Error(output.reason);
  return output.svg;
}

function fmt(value, digits = 2) {
  if (value === null || value === undefined || !Number.isFinite(value)) return 'unavailable';
  return Number(value.toFixed(digits)).toLocaleString('en-US', { maximumFractionDigits: digits });
}

function delta(ours, theirs, digits = 2) {
  if (ours === null || theirs === null || ours === undefined || theirs === undefined) return 'unavailable';
  const value = theirs - ours;
  return `${value > 0 ? '+' : ''}${fmt(value, digits)}`;
}

const results = [];
for (let index = 0; index < DRAWINGS.length; index += 1) {
  const drawing = DRAWINGS[index];
  try {
    const ours = measure(adaptFlowPeek(renderOurs(drawing.source, index)));
    const theirs = measure(adaptPele(pele.render(drawing.source).svg));
    results.push({ ...drawing, ours, theirs, error: null });
  } catch (error) {
    results.push({ ...drawing, ours: null, theirs: null, error: error instanceof Error ? error.message : String(error) });
  }
}

const successful = results.filter((result) => result.ours?.available && result.theirs?.available);
const failed = results.filter((result) => !result.ours?.available || !result.theirs?.available);
const sum = (side, key) => successful.reduce((total, result) => total + result[side][key], 0);
const pooledDistances = (side) => successful.flatMap((result) => result[side].foreignDistances);
const average = (values) => values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
const minimum = (values) => values.length ? Math.min(...values) : null;

const aggregate = {
  ours: {
    maskMask: sum('ours', 'maskMask'), maskForeignStroke: sum('ours', 'maskForeignStroke'),
    crossings: sum('ours', 'crossings'), bends: sum('ours', 'bends'), strokeLength: sum('ours', 'strokeLength'),
    area: sum('ours', 'area'), wrappedLabels: sum('ours', 'wrappedLabels'), labelLines: sum('ours', 'labelLines'),
    nearestForeignMean: average(pooledDistances('ours')), nearestForeignMin: minimum(pooledDistances('ours')),
  },
  theirs: {
    maskMask: sum('theirs', 'maskMask'), maskForeignStroke: sum('theirs', 'maskForeignStroke'),
    crossings: sum('theirs', 'crossings'), bends: sum('theirs', 'bends'), strokeLength: sum('theirs', 'strokeLength'),
    area: sum('theirs', 'area'), wrappedLabels: sum('theirs', 'wrappedLabels'), labelLines: sum('theirs', 'labelLines'),
    nearestForeignMean: average(pooledDistances('theirs')), nearestForeignMin: minimum(pooledDistances('theirs')),
  },
};
aggregate.ours.bendsPerEdge = aggregate.ours.bends / sum('ours', 'edgeCount');
aggregate.theirs.bendsPerEdge = aggregate.theirs.bends / sum('theirs', 'edgeCount');

const metrics = [
  ['Mask-vs-mask overlaps', 'maskMask', 'lower', 0],
  ['Mask-vs-foreign-stroke overlaps', 'maskForeignStroke', 'lower', 0],
  ['Stroke crossings', 'crossings', 'lower', 0],
  ['Total bends', 'bends', 'lower', 0],
  ['Mean bends per edge', 'bendsPerEdge', 'lower', 3],
  ['Total stroke length (px)', 'strokeLength', 'lower', 2],
  ['Total drawing area (px²)', 'area', 'lower', 0],
  ['Labels wrapped to 2+ lines', 'wrappedLabels', 'lower', 0],
  ['All edge-label lines', 'labelLines', 'lower', 0],
  ['Mean nearest foreign-stroke distance (px)', 'nearestForeignMean', 'higher', 2],
  ['Minimum nearest foreign-stroke distance (px)', 'nearestForeignMin', 'higher', 2],
];

const candidates = [];
for (const result of successful) {
  for (const [label, key, better] of metrics) {
    const ours = result.ours[key], theirs = result.theirs[key];
    if (ours === null || theirs === null || ours === undefined || theirs === undefined) continue;
    const gain = better === 'lower' ? ours - theirs : theirs - ours;
    if (gain <= 1e-7) continue;
    // Ranking across unlike units uses symmetric percent improvement; the report still prints the
    // raw measured values and delta. A +1 denominator keeps a one-count win finite at a zero bound.
    const score = gain / (Math.max(Math.abs(ours), Math.abs(theirs)) + 1);
    candidates.push({ drawing: result.name, metric: label, key, ours, theirs, gain, score, better });
  }
}
candidates.sort((a, b) => b.score - a.score || b.gain - a.gain || a.drawing.localeCompare(b.drawing));
const ranked = candidates.slice(0, 30);

function cause(item) {
  if (item.key === 'maskMask') return 'Pele separates edge-label plates that overlap in our output.';
  if (item.key === 'maskForeignStroke') return 'Pele keeps more edge-label plates off unrelated connectors.';
  if (item.key === 'crossings') return 'Pele routes this graph with fewer connector intersections.';
  if (item.key === 'bends' || item.key === 'bendsPerEdge') return 'Pele reaches the endpoints with fewer direction changes.';
  if (item.key === 'strokeLength') return 'Pele uses a shorter connector network.';
  if (item.key === 'area') return 'Pele packs the same source into a smaller viewport.';
  if (item.key === 'wrappedLabels') return 'Pele keeps more edge labels on one line.';
  if (item.key === 'labelLines') return 'Pele emits fewer edge-label text lines overall.';
  return 'Pele leaves edge-label plates farther from their nearest unrelated connector.';
}

const lines = [];
lines.push('# FlowPeek vs Pele differential measurement');
lines.push('');
lines.push(`Measured ${successful.length} of ${DRAWINGS.length} drawings (${SWEEP.length} SWEEP + ${REPORTED.length} reader-reported).`);
lines.push('Pele’s editorial CSS variables are paint-only and were therefore documented in the harness but not injected into geometry.');
lines.push('');
lines.push('## Aggregate metric table');
lines.push('');
lines.push('| Metric | Ours | Pele | Delta (Pele − ours) | Better |');
lines.push('|---|---:|---:|---:|:---:|');
for (const [label, key, better, digits] of metrics) {
  lines.push(`| ${label} | ${fmt(aggregate.ours[key], digits)} | ${fmt(aggregate.theirs[key], digits)} | ${delta(aggregate.ours[key], aggregate.theirs[key], digits)} | ${better} |`);
}
lines.push('');
lines.push('Distances are measured from the edge-label backing rectangle to the nearest stroke with a different data-id; drawings without both a label and a foreign stroke are unavailable for that distance rather than counted as zero. Crossings exclude shared endpoints. Rounded quadratic corners are sampled for physical length/intersections and counted once at their logical control-point turn.');
lines.push('');
lines.push('## Adapter coverage');
lines.push('');
lines.push('| Engine | Edges seen | Edge labels seen | Drawings with foreign-distance samples |');
lines.push('|---|---:|---:|---:|');
for (const [side, label] of [['ours', 'Ours'], ['theirs', 'Pele']]) {
  lines.push(`| ${label} | ${sum(side, 'edgeCount')} | ${sum(side, 'labelCount')} | ${successful.filter((r) => r[side].foreignDistances.length > 0).length} |`);
}
lines.push('');
lines.push('## Ranked Pele wins');
lines.push('');
lines.push('Ranked by symmetric proportional improvement so counts, pixels, and square pixels can share one list; raw values remain the authoritative measurements.');
lines.push('');
lines.push('| Rank | Drawing | Metric | Ours | Pele | Raw improvement | Reading |');
lines.push('|---:|---|---|---:|---:|---:|---|');
ranked.forEach((item, index) => {
  lines.push(`| ${index + 1} | ${item.drawing.replaceAll('|', '\\|')} | ${item.metric} | ${fmt(item.ours)} | ${fmt(item.theirs)} | ${fmt(item.gain)} | ${cause(item)} |`);
});
lines.push('');
lines.push('## Worst gaps by metric');
lines.push('');
for (const [label, key] of metrics) {
  const worst = candidates.filter((item) => item.key === key).slice(0, 8);
  lines.push(`### ${label}`);
  lines.push('');
  if (worst.length === 0) lines.push('No drawing where Pele is better on this metric.');
  else {
    lines.push('| Drawing | Ours | Pele | Improvement |');
    lines.push('|---|---:|---:|---:|');
    for (const item of worst) lines.push(`| ${item.drawing.replaceAll('|', '\\|')} | ${fmt(item.ours)} | ${fmt(item.theirs)} | ${fmt(item.gain)} |`);
  }
  lines.push('');
}
if (failed.length) {
  lines.push('## Unavailable drawings');
  lines.push('');
  for (const item of failed) lines.push(`- ${item.name}: ${item.error ?? item.ours?.reason ?? item.theirs?.reason ?? 'unavailable'}`);
  lines.push('');
}

const report = `${lines.join('\n')}\n`;
const reportPath = '/private/tmp/claude-501/-Users-tim-Projects-personal-flowpeek/4189cc37-2f53-4348-9f23-270e9bf01d86/scratchpad/diff-report.md';
mkdirSync(dirname(reportPath), { recursive: true });
writeFileSync(reportPath, report);
process.stdout.write(report);
