// The rulers in measure.js, held to what they were read from.
//
// `measureFace` exists because Scripts/differential.mjs compared the two engines with different
// rulers: ours on the flat style-guide budget, Pele on its own Helvetica table. The budget measured
// "negotiate(adjustRate, original)" at 223.2px where WebKit paints it in 155.05px, and wrapped six
// labels the app draws on one line. The widths below are WKWebView getBBox() readings on macOS 26
// for the editorial stack, taken the way flowpeek-glue.js's makeMeasurer takes them; the table is
// allowed 0.05px against each.
//
// `measureText` is pinned too, because every layout spec in this directory is written against it
// and none of them should move when the face table does.

import { measureFace, measureText } from './measure.js';

const SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Apple SD Gothic Neo', sans-serif";
const style = (fontWeight, letterSpacing = 'normal', fontSizePX = 12) => ({ fontFamily: SANS, fontSizePX, fontWeight, letterSpacing });

describe('[Measure] measureFace reads what WebKit paints', () => {
  it.each([
    ['negotiate(adjustRate, original)', style(400), 155.046875],
    ['derivedQuoteId (representative)', style(400), 165.375],
    ['discardedQuoteId: Candidate-H2.id', style(600), 194.8125],
    ['derivedQuoteId 갱신', style(400), 103.765625],
    ['Is it ready?', style(600), 58.90625],
    ['CDN', style(600), 25.65625],
  ])('%s', (text, s, webkit) => {
    expect(Math.abs(measureFace(text, s).width - webkit)).toBeLessThan(0.05);
  });

  it('draws Hangul at 0.865em, not the budget\'s 1em', () => {
    expect(measureFace('없음', style(400)).width).toBeCloseTo(2 * 0.865 * 12, 3);
  });

  it('puts letter-spacing between characters, not after the last', () => {
    const plain = measureFace('abc', style(600)).width;
    expect(measureFace('abc', style(600, '0.06em')).width - plain).toBeCloseTo(2 * 0.06 * 12, 6);
  });

  it('reads the row for the size it is asked, because SF Pro Text tracks by size', () => {
    // A space is 0.2218em at 12px and 0.2178em at 16px in getBBox.
    expect(measureFace(' ', style(400, 'normal', 12)).width / 12).toBeCloseTo(0.2218, 4);
    expect(measureFace(' ', style(400, 'normal', 16)).width / 16).toBeCloseTo(0.2178, 4);
  });
});

describe('[Measure] measureText is still the budget', () => {
  it('charges 0.6em a Latin character and 1em a wide one', () => {
    expect(measureText('negotiate(adjustRate, original)', style(400)).width).toBeCloseTo(223.2, 6);
    expect(measureText('없음', style(400)).width).toBeCloseTo(24, 6);
  });
});
