// Labels that share one face's gap stand in columns, not end to end.
//
// The second held-out set's b04 sends five labelled links out of one face and takes two back, and
// drew the gap 830pt deep where Pele's is about 295: every plate in the corridor was given its own
// stretch of the gap, so the drawing came out 1.7 times as wide and, fitted to a window, every word
// in it that much smaller. Two plates on lines far enough apart across the gap can stand at the same
// place along it; `layoutLevel` now asks the gap for the plates of that many lines side by side
// rather than for all of them.
//
// The source here is a request/response exchange of the same shape, written for this file -- not
// b04, which is a measuring stick -- and the property is the reader's: the gap is shallower than the
// corridor's plates laid end to end.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureFace } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

// What the app ships, as differential.mjs renders it: the face `measureFace` was read from and the
// 20px outer margin of MacMermaidTheme.swift.
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

const exchange = (dir) => [
  `flowchart ${dir}`,
  '  C[Client] -->|ask the platform for a code| P[Platform]', '  P -->|code valid for five minutes| C',
  '  C -->|send the code| S[Server]', '  S -->|signed token| C', '  C -->|keep the token| K[Local store]',
  '  C -->|call with the token| S',
].join('\n');

function measured(source) {
  const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText: measureFace });
  expect(out.reason || 'ok').toBe('ok');
  expect(out.warnings).toEqual([]);
  const boxes = new Map();
  for (const m of out.svg.matchAll(/id="fp-0-flowchart-(\w+)-\d+" transform="translate\(([-\d.]+),([-\d.]+)\)"><rect class="basic label-container" x="([-\d.]+)" y="[-\d.]+" width="([\d.]+)"/g)) {
    boxes.set(m[1], { lo: +m[2] + +m[4], hi: +m[2] + +m[4] + +m[5] });
  }
  const widths = [...out.svg.matchAll(/<rect class="background" x="[-\d.]+" y="[-\d.]+" width="([\d.]+)"/g)].map((m) => +m[1]);
  return { boxes, widths };
}

describe('the plates of one face in one gap', () => {
  for (const dir of ['LR', 'RL']) {
    it(`stand side by side across the gap rather than end to end along it: ${dir}`, () => {
      const { boxes, widths } = measured(exchange(dir));
      const client = boxes.get('C');
      const far = ['P', 'S', 'K'].map((id) => boxes.get(id));
      const gap = dir === 'LR'
        ? Math.min(...far.map((b) => b.lo)) - client.hi
        : client.lo - Math.max(...far.map((b) => b.hi));
      // All six labels are on links into or out of the client's one face, so all six share its gap.
      expect(widths.length).toBe(6);
      const endToEnd = widths.reduce((a, b) => a + b, 0) + (widths.length - 1) * 16;
      expect(gap).toBeLessThan(endToEnd);
    });
  }
});
