// A deterministic stand-in for the text measurement the app injects from the DOM.
//
// The renderer takes its only pixel measurements through a callback (RENDERER-SPEC.md §3) precisely
// so that a host without a DOM can hand it a fixed metric and get the same drawing every time. This
// is that metric, and it is the style guide's own width budget rather than an invention: every
// Unicode wide or full-width character costs 1em, every other character costs its face's Latin
// advance, and nonspacing marks cost nothing (style-guide.md, "Width budget").
//
// It is not a font. It exists so the layout assertions below are about the layout.

const SANS_ADVANCE = 0.6;
const MONO_ADVANCE = 0.62;

// East Asian Wide and Fullwidth, coarse but sufficient: Hangul, the CJK blocks, Kana, and the
// fullwidth forms. Measuring these at the Latin advance is the trap the style guide names.
const WIDE = [
  [0x1100, 0x115f], [0x2e80, 0x303e], [0x3041, 0x33ff], [0x3400, 0x4dbf],
  [0x4e00, 0x9fff], [0xa000, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff],
  [0xfe30, 0xfe6f], [0xff00, 0xff60], [0xffe0, 0xffe6],
];

const COMBINING = [
  [0x0300, 0x036f], [0x0483, 0x0489], [0x0591, 0x05bd], [0x0610, 0x061a],
  [0x064b, 0x065f], [0x0e31, 0x0e31], [0x0e34, 0x0e3a], [0x0e47, 0x0e4e],
  [0x1ab0, 0x1aff], [0x1dc0, 0x1dff], [0x20d0, 0x20f0], [0x3099, 0x309a],
  [0xfe00, 0xfe0f], [0xfe20, 0xfe2f],
];

function inRanges(code, ranges) {
  for (const [lo, hi] of ranges) if (code >= lo && code <= hi) return true;
  return false;
}

/**
 * @param {string} text one line, never containing "\n"
 * @param {{fontFamily:string, fontSizePX:number, fontWeight:(string|number), letterSpacing:string}} style
 * @returns {{width:number, height:number}}
 */
export function measureText(text, style) {
  const size = style.fontSizePX;
  const mono = /mono/i.test(String(style.fontFamily || ''));
  const latin = mono ? MONO_ADVANCE : SANS_ADVANCE;
  let ems = 0;
  for (const ch of String(text)) {
    const code = ch.codePointAt(0);
    if (inRanges(code, COMBINING)) continue;
    ems += inRanges(code, WIDE) ? 1 : latin;
  }
  return {
    width: ems * size,
    // The line box, never zero: the adapter owes a height for empty text even where WebKit's
    // getBBox answers 0x0, which is the compensation the glue already patches in.
    height: size * 1.2,
  };
}

/** Counts calls, so a test can assert the renderer measures a line once rather than per paragraph. */
export function countingMeasurer() {
  const calls = [];
  const fn = (text, style) => {
    calls.push(text);
    return measureText(text, style);
  };
  fn.calls = calls;
  return fn;
}
