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

// ---------------------------------------------------------------------------------------------
// The face the app actually paints, for instruments that must not inherit the budget's bias.
//
// `measureText` above is a budget, and it is a generous one: against what WebKit's SVG getBBox()
// answers for the editorial stack (-apple-system, i.e. SF Pro Text, with Apple SD Gothic Neo for
// Hangul) it measures the differential corpus's 146 label strings a median 19.8% wide, up to 81.6%
// ("first" at weight 400), and Hangul at 1em where the face draws 0.865em. That is harmless for a
// layout assertion and wrong for a comparison with another engine, which is what
// Scripts/differential.mjs needed `measureFace` for.
//
// The table is per-character advances read from WKWebView exactly as flowpeek-glue.js's
// makeMeasurer reads them: an SVG <text> styled with the same declaration, getBBox().width, on
// macOS 26. Each entry is a run of twenty copies between two bars, less the bars, divided by
// twenty, so kerning against the bars cancels. Summed per character, it reproduces the full-string
// getBBox width of all 146 corpus strings to within 0.03px: SF Pro Text does not kern at these
// sizes, and letter-spacing lands between characters, not after the last. It is size-specific
// because SF Pro Text tracks by size -- the space is 0.2218em at 12px and 0.2178em at 16px -- so
// there is a row for 12px (the editorial base) and for 14px and 16px (what Pele asks for edge and
// node labels). Any other size reads the nearest row, and a weight between two rows interpolates.
// Checked the same way against the 133 strings Pele measures at 14px and 16px: within 0.021px.
// Trailing whitespace is counted, as a canvas counts it and as Pele's word-wrapper expects;
// getBBox drops it, so a string ending in a space reads one space advance wider than getBBox.
//
// Rows are ASCII 32..126 then FACE_EXTRA, in 1/10000 em, three base-36 digits each.
const FACE_ADVANCES = {
  12: {
    400: '1pm25438l4q04q06f758s21i2lc2lc37n4q01sn3e31sn27o4qg3h04fx4mz4qp4kz4t849u4pc4t81sn1sn4q04q04q03tw'
      + '6tx4z84re5cv5br4ce45o5j35h81te3wj4ql44o6hu5h85q04k65q04py4nu4kw5ga4y877n4zc4t24ud2lc27o2lc4q0460'
      + '3vp3yr4do3yx4do4222g44cc4911o41nv3uj1nz6bb46047a4ch4cc2i23p02fm4603tx5mi3pq3ur3qd2lc1qy2lc4q06hu'
      + '1sn1sn4q02eu70f4vy2yo2yo4q0',
    500: '1oo29n3e34ta4ty6na5bu23l2qn2qn3bk4ty1vg3f81vg29z4v43kl4je4qk4up4os4wp4cd4u04wp1vg1vg4ty4ty4ty3y1'
      + '6v354j4uo5fb5dq4ef47n5kv5k71x942c4ve46j6ko5it5rv4nu5ru4ts4rc4mw5hj52m7bi5424xy4vp2qn29z2qn4ty4ah'
      + '3vp42u4hk42q4hh45t2ku4ga4d81rf1r83zi1rk6gx4ah4ay4gf4ga2n73th2kk4ah3y25te3v63zo3tn2qn1tl2qn4ty6ko'
      + '1vg1vg4ty2i773w55734y34y4ty',
    600: '1nq2e53jl4wj4xu6vc5eu25o2vy2vy3fh4xu1y93gd1y92c84zr3o64mv4u44yo4sk5044ev4yo5041y91y94xu4xu4xu424'
      + '6w759t4xy5hp5fo4gf49l5mm5n621548550848e6nh5ke5tp4ri5to4xl4uu4ov5is5707fc58q52u4x02vy2c82vy4xu4ex'
      + '3vp46w4lg46h4l949j2pk4k84hd1uq1uk44g1v56mi4ex4em4kd4k82sc3xx2pg4ex42660a40m44k3wy2vy1w82vy4xu6nh'
      + '1y91y94xu2lj77d5ef3b73b74xu',
    700: '1mt2io3p34zu51s73f5hw27r3193193je51s2133hi2132ej54f3rr4qd4xp52o4wd53k4hd53c53k21321351s51s51s469'
      + '6xc5f45175k45hn4ig4bk5of5q62514dz5524a96qb5lz5vk4v65vi51d4yd4qw5k15be7j75df57q4yb3192ej31951s4je'
      + '3vp4ay4pc4aa4p24da2ua4o74lj1y11xx49f1ys6s44je4ia4oc4o72xh42e2ue4je46a67646249g4083191yv31951s6qb'
      + '21321351s2ov7av5nn3hh3hh51s',
  },
  14: {
    400: '1os25u37u4rp4rp6ca59m22c2lb2lb3714rp1rh3ew1rh29e4s93iy4h04o74rp4ma4v94bp4qd4v91rh1rh4rp4rp4rp3vp'
      + '6uq5094rp5ed5cc4d746f5k25i11u73xc4qm45h6in5i15qz4k95qz4q84ol4l75h74z178f5044tv4v42lb29e2lb4rp465'
      + '3yp3z84dm3yy4dm4222g64c949j1p11os3um1oh6ax4654784cd4c92he3p22fh4653tx5mi3pv3uw3pq2lb1rr2lb4rp6in'
      + '1rh1rh4rp2fw73e4o72wu2wu4rp',
    500: '1o32ag3co4uv4vn6jw5cn23t2qu2qu3bk4vn1tw3g11tw2bk4wu3md4kg4rp4vp4q04yh4e14ux4yh1tw1tw4vn4vn4vn3zt'
      + '6vx55j4uz5gs5eb4f448b5ly5ku1xw4354vi4776lf5jg5sx4ny5sx4u14s44n45i953f7c954t4ys4wf2qu2bk2qu4vn4ap'
      + '3yp43f4hl4304hh4612kz4gc4dq1s91s13zh1s16gh4ap4b44gg4gb2mj3tn2kh4ap3y55tf3vd3zr3t72qu1u52qu4vn6lf'
      + '1tw1tw4vn2j376w4we32k32k4vn',
    600: '1ne2f13hi4y04zl6rh5fo25b2wc2wc3g24zl1wa3h51wa2dq51e3pq4nv4v74zo4tp51p4gd4zh51p1wa1wa4zl4zl4zl43x'
      + '6x45as4y85j75g94h14a65nt5nm21m48y50c48w6o75kt5uv4rm5ut4xt4vl4p05ja57t7g359h53n4xq2wc2dq2wc4zl4f8'
      + '3yp47l4lk4724lc4a02ps4kg4hw1vg1va44c1vj6m14f84f04ki4kc2rp3y72ph4f842b60c40v44m3wn2wc1wj2wc4zl6o7'
      + '1wa1wa4zl2m97ad54l38a38a4zl',
    700: '1mq2jn3md51553j6z25ip26t31v31v3kl53j1yo3ia1yo2fw55y3t44rb4yp53o4xf54y4ip54254y1yo1yo53j53j53j482'
      + '6yb5g251h5lm5i84iz4c25pp5qg25b4er5574am6r05m85wt4vb5wq51m4z44qw5kc5c77jy5e658j4z131v2fw31v53j4js'
      + '3yp4bs4pk4b44p84dy2um4oj4m31yo1yj4971z36rm4js4iw4ol4oe2wv42r2uh4js46h67946c49h40431v1yy31v53j6r0'
      + '1yo1yo53j2pg7du5ct3e03e053j',
  },
  16: {
    400: '1oi25l37k4rg4rg6c059c2222l22l236r4rg1r73em1r72944rz3ip4gq4nx4rg4m14uz4bg4q34uz1r71r74rg4rg4rg3vg'
      + '6ug4zz4rg5e35c24cx4655js5hr1tx3x24qd4576ie5hr5qp4jz5qp4py4oc4ky5gy4ys7854zv4tm4uu2l22942l24rg45w'
      + '3yf3yy4dc3yp4dc41t2fw4bz49a1os1oi3uc1o86an45w46z4c44bz2h43os2f845w3to5m83pm3um3ph2l21rh2l24rg6ie'
      + '1r71r74rg2fm7354nx2wl2wl4rg',
    500: '1nt2a63ce4ul4vd6jl5ce23k2qk2qk3ba4vd1tm3fr1tm2ba4wk3m34k64rf4vf4pq4y84ds4uo4y81tm1tm4vd4vd4vd3zk'
      + '6vo5594up5gj5e14ev4815lo5kk1xn42w4v846x6l65j65so4no5sn4tr4ru4mu5hz5367c054j4yi4w52qk2ba2qk4vd4af'
      + '3yf4354hc42r4h745s2kp4g34dg1rz1rr3z81rr6g74af4av4g74g12ma3td2k84af3xv5t53v33zi3sx2qk1tw2qk4vd6l6'
      + '1tm1tm4vd2it76m4w432b32b4vd',
    600: '1n52er3h84xq4zb6r75fe2512w32w33fs4zb1w03gv1w02dg5143ph4nl4ux4ze4tf51f4g34z851f1w01w04zb4zb4zb43n'
      + '6wu5ai4xy5ix5g04gs49w5nj5nd21c48o50248n6ny5kk5ul4rc5uk4xk4vc4oq5j157j7fu59853e4xg2w32dg2w34zb4ez'
      + '3yf47b4la46s4l249q2pj4k64hm1v61v04421va6ls4ez4eq4k94k22rf3xx2p74ez42160240l44c3we2w31wa2w34zb6ny'
      + '1w01w04zb2m07a354c3803804zb',
    700: '1mg2jd3m350v5396ys5ig26j31l31l3kb5391ye3i01ye2fm55p3sv4r14yf53e4x554o4if53s54o1ye1ye53953953947s'
      + '6y15fs5175ld5hy4ip4bs5pf5q62514ei54y4ad6qq5lz5wj4v15wh51c4yu4qn5k25bx7jo5dw5894ys31l2fm31l5394ji'
      + '3yf4bi4pa4au4oy4do2uc4o94lt1ye1y948x1yt6rc4ji4im4oc4o42wl42h2u74ji46866z4634973zu31l1yo31l5396qq'
      + '1ye1ye5392p77dl5cj3dq3dq539',
  },
};
const FACE_EXTRA = '—·’−²→…“”×';
const FACE_SIZES = [12, 14, 16];
const FACE_WEIGHTS = [400, 500, 600, 700];
// Every wide character the stack was asked for -- Hangul syllables (all 11,172), compatibility
// jamo, fullwidth forms, a CJK ideograph and kana -- falls to Apple SD Gothic Neo at 0.865em.
const FACE_WIDE = 0.865;
// SF Mono is monospaced at 0.6182em in every weight.
const FACE_MONO = 0.6182;
// A character the table does not carry. None in the corpus; the budget's Latin advance stands in.
const FACE_UNKNOWN = 0.6;
// getBBox's line box: 14.140625px at 12px.
const FACE_LINE = 14.140625 / 12;

const faceRows = new Map();
function faceRow(size, weight) {
  const key = `${size}|${weight}`;
  let row = faceRows.get(key);
  if (!row) {
    const packed = FACE_ADVANCES[size][weight];
    row = new Map();
    const chars = [];
    for (let c = 32; c < 127; c += 1) chars.push(String.fromCharCode(c));
    chars.push(...FACE_EXTRA);
    chars.forEach((ch, i) => row.set(ch, parseInt(packed.substr(i * 3, 3), 36) / 10000));
    faceRows.set(key, row);
  }
  return row;
}

function faceAdvance(ch, size, weight) {
  const code = ch.codePointAt(0);
  if (inRanges(code, COMBINING)) return 0;
  if (inRanges(code, WIDE)) return FACE_WIDE;
  const row = FACE_SIZES.reduce((best, s) => (Math.abs(s - size) < Math.abs(best - size) ? s : best));
  const w = Math.min(700, Math.max(400, weight));
  const lo = FACE_WEIGHTS.filter((x) => x <= w).pop();
  const hi = FACE_WEIGHTS.find((x) => x >= w);
  const a = faceRow(row, lo).get(ch);
  if (a === undefined) return FACE_UNKNOWN;
  return lo === hi ? a : a + (faceRow(row, hi).get(ch) - a) * ((w - lo) / (hi - lo));
}

function trackingPX(letterSpacing, size) {
  const value = String(letterSpacing || 'normal').trim();
  if (value === 'normal') return 0;
  const n = parseFloat(value);
  if (!Number.isFinite(n)) return 0;
  return /em$/.test(value) ? n * size : n;
}

/**
 * The width WebKit's getBBox() gives the editorial stack, from the table above.
 * @param {string} text one line, never containing "\n"
 * @param {{fontFamily:string, fontSizePX:number, fontWeight:(string|number), letterSpacing:string}} style
 * @returns {{width:number, height:number}}
 */
export function measureFace(text, style) {
  const size = style.fontSizePX;
  const mono = /mono/i.test(String(style.fontFamily || ''));
  const weight = Number(style.fontWeight) || (/bold/i.test(String(style.fontWeight)) ? 700 : 400);
  let ems = 0;
  let glyphs = 0;
  for (const ch of String(text)) {
    const code = ch.codePointAt(0);
    if (inRanges(code, COMBINING)) continue;
    glyphs += 1;
    ems += mono && !inRanges(code, WIDE) ? FACE_MONO : faceAdvance(ch, size, weight);
  }
  return {
    width: ems * size + trackingPX(style.letterSpacing, size) * Math.max(0, glyphs - 1),
    height: size * FACE_LINE,
  };
}
