// The shapes, read back out of the markup the emitter actually wrote.
//
// Every geometric claim in ports.spec.js and rule 5 in render.spec.js is about where a line is
// relative to a shape's OUTLINE, and the outline is a string of path data until something turns it
// back into points. A second implementation of the fifteen shapes would answer those questions with
// the model that was wrong in the first place -- a port on the bounding box agrees with a model of
// a rhombus and disagrees with the drawing -- so nothing here knows what a diamond is. It reads
// `points`, `d`, `r` and `x/y/width/height` off the element and samples what they describe.
//
// Arcs are sampled, not solved: 0.25 degrees a step, which puts the sampled chord within 1e-4 px of
// a 400px radius, four orders of magnitude under the tolerances anything here asserts.

const NUMBER = /-?\d+(?:\.\d+)?/g;
const ARC_STEP = (0.25 * Math.PI) / 180;

/** One elliptical arc, endpoint parameterisation, sampled from `from` to (x,y). SVG 2 §B.2.4. */
function sampleArc(from, rx, ry, rotation, largeArc, sweep, x, y) {
  const out = [];
  const phi = (rotation * Math.PI) / 180;
  const cos = Math.cos(phi);
  const sin = Math.sin(phi);
  const dx = (from.x - x) / 2;
  const dy = (from.y - y) / 2;
  const x1 = cos * dx + sin * dy;
  const y1 = -sin * dx + cos * dy;
  let RX = Math.abs(rx);
  let RY = Math.abs(ry);
  if (RX === 0 || RY === 0) return [{ x, y }];
  // The radius correction: a radius too small to reach both ends is scaled up until it does. This
  // is not a corner case here -- a stadium's cap is written with radius min(W,H) and drawn with
  // radius H -- which is why it is implemented rather than assumed away.
  const lambda = (x1 * x1) / (RX * RX) + (y1 * y1) / (RY * RY);
  if (lambda > 1) {
    const s = Math.sqrt(lambda);
    RX *= s;
    RY *= s;
  }
  const num = RX * RX * RY * RY - RX * RX * y1 * y1 - RY * RY * x1 * x1;
  const den = RX * RX * y1 * y1 + RY * RY * x1 * x1;
  const factor = (largeArc !== sweep ? 1 : -1) * Math.sqrt(Math.max(0, num / den));
  const cx1 = (factor * RX * y1) / RY;
  const cy1 = (-factor * RY * x1) / RX;
  const cx = cos * cx1 - sin * cy1 + (from.x + x) / 2;
  const cy = sin * cx1 + cos * cy1 + (from.y + y) / 2;
  const theta = Math.atan2((y1 - cy1) / RY, (x1 - cx1) / RX);
  let delta = Math.atan2((-y1 - cy1) / RY, (-x1 - cx1) / RX) - theta;
  if (sweep && delta < 0) delta += 2 * Math.PI;
  if (!sweep && delta > 0) delta -= 2 * Math.PI;
  const steps = Math.max(2, Math.ceil(Math.abs(delta) / ARC_STEP));
  for (let i = 1; i <= steps; i += 1) {
    const t = theta + (delta * i) / steps;
    const px = cos * RX * Math.cos(t) - sin * RY * Math.sin(t) + cx;
    const py = sin * RX * Math.cos(t) + cos * RY * Math.sin(t) + cy;
    out.push({ x: px, y: py });
  }
  return out;
}

/**
 * The first subpath of a `d`, as points. The first is the whole outline for both shapes that write
 * a second one: a cylinder's is the rim line across its lid and a subroutine's are the two bars
 * inside its rect, and neither is anything an edge can arrive at.
 */
export function samplePath(d) {
  const commands = d.match(/[MLAZz][^MLAZz]*/g) || [];
  const points = [];
  let cursor = { x: 0, y: 0 };
  for (const command of commands) {
    const head = command[0];
    if (head === 'Z' || head === 'z') break;
    if (head === 'M' && points.length > 0) break;
    const n = (command.slice(1).match(NUMBER) || []).map(Number);
    if (head === 'M' || head === 'L') {
      cursor = { x: n[0], y: n[1] };
      points.push(cursor);
    } else {
      for (const p of sampleArc(cursor, n[0], n[1], n[2], n[3], n[4], n[5], n[6])) points.push(p);
      cursor = { x: n[5], y: n[6] };
    }
  }
  return points;
}

function sampleCircle(cx, cy, r) {
  const points = [];
  const steps = Math.max(8, Math.ceil((2 * Math.PI) / ARC_STEP));
  for (let i = 0; i < steps; i += 1) {
    const t = (2 * Math.PI * i) / steps;
    points.push({ x: cx + r * Math.cos(t), y: cy + r * Math.sin(t) });
  }
  return points;
}

function sampleRect(x, y, w, h, r) {
  if (!(r > 0)) return [{ x, y }, { x: x + w, y }, { x: x + w, y: y + h }, { x, y: y + h }];
  const radius = Math.min(r, w / 2, h / 2);
  const points = [];
  const corners = [
    [x + w - radius, y + radius, -Math.PI / 2],
    [x + w - radius, y + h - radius, 0],
    [x + radius, y + h - radius, Math.PI / 2],
    [x + radius, y + radius, Math.PI],
  ];
  for (const [ccx, ccy, from] of corners) {
    const steps = Math.max(2, Math.ceil(Math.PI / 2 / ARC_STEP));
    for (let i = 0; i <= steps; i += 1) {
      const t = from + (Math.PI / 2) * (i / steps);
      points.push({ x: ccx + radius * Math.cos(t), y: ccy + radius * Math.sin(t) });
    }
  }
  return points;
}

/** Every `g.node` in the markup: its translate, its bounding box, and its outline as points. */
export function nodeOutlines(svg) {
  const found = [];
  // Stops at the label group, or at the first close if the node has no label to draw.
  const re = /<g class="node([^"]*)" id="([^"]*)" transform="translate\((-?\d+),(-?\d+)\)">(.*?)(?:<g class="label"|<\/g>)/g;
  let m;
  while ((m = re.exec(svg)) !== null) {
    const classes = m[1].trim().split(/\s+/).filter(Boolean);
    const cx = Number(m[3]);
    const cy = Number(m[4]);
    const body = m[5];
    const shape = /<(polygon|rect|circle|path)\b[^>]*>/.exec(body);
    if (!shape) continue;
    const tag = shape[1];
    const attributes = shape[0];
    let local;
    if (tag === 'polygon') {
      const n = (/points="([^"]*)"/.exec(attributes)[1].match(NUMBER) || []).map(Number);
      local = [];
      for (let i = 0; i + 1 < n.length; i += 2) local.push({ x: n[i], y: n[i + 1] });
    } else if (tag === 'circle') {
      local = sampleCircle(0, 0, Number(/\br="(-?\d+)"/.exec(attributes)[1]));
    } else if (tag === 'rect') {
      const rx = /\brx="(-?\d+)"/.exec(attributes);
      local = sampleRect(
        Number(/\bx="(-?\d+)"/.exec(attributes)[1]),
        Number(/\by="(-?\d+)"/.exec(attributes)[1]),
        Number(/\bwidth="(\d+)"/.exec(attributes)[1]),
        Number(/\bheight="(\d+)"/.exec(attributes)[1]),
        rx ? Number(rx[1]) : 0,
      );
    } else {
      local = samplePath(/\bd="([^"]*)"/.exec(attributes)[1]);
    }
    const points = local.map((p) => ({ x: cx + p.x, y: cy + p.y }));
    const xs = points.map((p) => p.x);
    const ys = points.map((p) => p.y);
    found.push({
      id: m[2],
      classes,
      cx,
      cy,
      points,
      box: {
        x: Math.min(...xs), y: Math.min(...ys),
        width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys),
      },
    });
  }
  return found;
}

function edges(points) {
  const out = [];
  for (let i = 0; i < points.length; i += 1) out.push([points[i], points[(i + 1) % points.length]]);
  return out;
}

function distanceToSegment(p, a, b) {
  const vx = b.x - a.x;
  const vy = b.y - a.y;
  const len = vx * vx + vy * vy;
  let t = len === 0 ? 0 : ((p.x - a.x) * vx + (p.y - a.y) * vy) / len;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy));
}

/** How far the point is from the outline itself, inside or out. */
export function distanceToOutline(p, points) {
  let best = Infinity;
  for (const [a, b] of edges(points)) best = Math.min(best, distanceToSegment(p, a, b));
  return best;
}

/** Ray casting, on the closed outline. */
export function insideOutline(p, points) {
  let inside = false;
  for (const [a, b] of edges(points)) {
    if ((a.y > p.y) !== (b.y > p.y)) {
      const x = a.x + ((p.y - a.y) / (b.y - a.y)) * (b.x - a.x);
      if (x > p.x) inside = !inside;
    }
  }
  return inside;
}

/**
 * How far along `dir` from `from` the outline is -- the first crossing, which is the depth of the
 * shape under a point on its bounding box. Measured off the sampled outline rather than computed
 * from a shape name, which is the whole point of this file.
 */
export function rayDepth(from, dir, points) {
  let best = Infinity;
  for (const [a, b] of edges(points)) {
    // Both rays are axis-parallel: every port normal is one of the four.
    if (dir.x === 0) {
      if ((a.x > from.x) === (b.x > from.x) && a.x !== from.x && b.x !== from.x) continue;
      if (a.x === b.x) continue;
      const t = (from.x - a.x) / (b.x - a.x);
      if (t < 0 || t > 1) continue;
      const y = a.y + t * (b.y - a.y);
      const along = (y - from.y) * dir.y;
      if (along >= -1e-9) best = Math.min(best, along);
    } else {
      if ((a.y > from.y) === (b.y > from.y) && a.y !== from.y && b.y !== from.y) continue;
      if (a.y === b.y) continue;
      const t = (from.y - a.y) / (b.y - a.y);
      if (t < 0 || t > 1) continue;
      const x = a.x + t * (b.x - a.x);
      const along = (x - from.x) * dir.x;
      if (along >= -1e-9) best = Math.min(best, along);
    }
  }
  return best;
}

/**
 * Whether the segment passes through the shape, `margin` px in from the outline. Clipped against
 * the outline's own half-planes, so the answer is exact for a convex shape -- which all fifteen are
 * except `odd`, whose left notch this treats as filled. Stricter there, never looser.
 */
export function segmentEntersShape([p, q], points, margin) {
  let cx = 0;
  let cy = 0;
  for (const point of points) { cx += point.x; cy += point.y; }
  cx /= points.length;
  cy /= points.length;
  let t0 = 0;
  let t1 = 1;
  for (const [a, b] of edges(points)) {
    let nx = -(b.y - a.y);
    let ny = b.x - a.x;
    const len = Math.hypot(nx, ny);
    if (len === 0) continue;
    nx /= len;
    ny /= len;
    if (nx * (cx - a.x) + ny * (cy - a.y) < 0) { nx = -nx; ny = -ny; }
    // Keep the stretch of [p,q] with (n . (x - a)) >= margin.
    const dp = nx * (p.x - a.x) + ny * (p.y - a.y) - margin;
    const dq = nx * (q.x - a.x) + ny * (q.y - a.y) - margin;
    if (dp >= 0 && dq >= 0) continue;
    if (dp < 0 && dq < 0) return false;
    const t = dp / (dp - dq);
    if (dp < 0) t0 = Math.max(t0, t);
    else t1 = Math.min(t1, t);
    if (t0 >= t1) return false;
  }
  return t0 < t1;
}
