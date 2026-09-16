// FlowPeek's own flowchart renderer.
//
// So far this is the parser only: it reads Mermaid flowchart source into `FlowDB`. `layout` and
// `render` below are stubs, and until they are written the app still draws every flowchart with
// the vendored mermaid.
//
// What it is for is the half that is not written yet. mermaid's layout cannot be asked for the
// things diagram-design calls non-negotiable -- every coordinate on a 4px grid, every connector
// orthogonal with a rounded elbow -- and this session established that they cannot be bolted on
// afterwards either: snapping mermaid's output moves the boxes out from under the edges it has
// already routed. Owning the layout is the only way to have them by construction.
//
// The parser, though, is held to mermaid exactly. Every flowchart mermaid accepts, this accepts,
// and resolves to the same vertices, edges, classes and subgraphs. That is checked rather than
// claimed: mermaid's own parser specs are vendored under Tests/JavaScript/mermaid-compat,
// byte-for-byte as mermaid wrote them, and run against the `FlowDB` below -- 948 of them.
//
// Compatibility stops at meaning. Nothing here promises mermaid's pixels, because different pixels
// are the entire point.
//
// No imports, no build step, no DOM. It is injected as a classic script into the same content world
// as mermaid, and the only thing it needs from its host is a text-measuring callback. That is what
// lets the same file run under node against the vendored tests, and what would let it be ported to
// WASM later without moving the seam.
"use strict";

(function () {
  var FLOW_VERSION = "1";

  // The config mermaid's flowDb reads out of `getConfig()`. Every one of the fifteen vendored spec
  // files opens with `setConfig({ securityLevel: 'strict' })` and none changes it afterwards, so a
  // fixed strict default reproduces the behaviour they assert; the app never runs this half with a
  // looser level either, because the WebView already sandboxes what a diagram may do.
  var CONFIG = { securityLevel: "strict", maxEdges: 500 };

  // mermaid's logger, reduced to the one call the flowchart model makes. It stays a named object,
  // and is exported below, because a warning nobody can reach is a warning that does not exist: the
  // one thing this ever says -- a style naming a node that was never declared -- is a typo report
  // for whoever wrote the diagram, and it has to arrive somewhere other than the page's console.
  // Replacing a method on the exported object is the whole of that contract.
  var log = {
    trace: function () {},
    debug: function () {},
    info: function () {},
    warn: function () {},
    error: function () {},
    fatal: function () {}
  };

  // ===========================================================================
  // Text handling.
  //
  // mermaid puts every label through DOMPurify before the database ever sees it. Under
  // `securityLevel: 'strict'` its `sanitizeText` is, in full,
  // `DOMPurify.sanitize(DOMPurify.sanitize(txt), { FORBID_TAGS: ['style'] })` -- `removeScript` out
  // of `sanitizeMore`, then a second pass that also forbids `style`. So a label is not a string
  // mermaid copied; it is a string a browser parsed as a whole HTML document, an allowlist filtered,
  // and the HTML serializer wrote back out of `body`.
  //
  // What used to stand here was a regex that kept anything shaped like a tag, which meant
  // `A[<script>a</script>]` and `A[<img src=x onerror=1>]` arrived in `vertex.text` intact. Labels
  // are destined for markup, so that was an injection into our own SVG that we were performing on
  // ourselves. There is no DOM here and no dependency to reach for, so the three stages are written
  // out below: a tokenizer, DOMPurify's own allowlists, and a serializer.
  //
  // Diffed against real mermaid 11.17.2 driven under jsdom: 2,264 sources built from 163 payloads
  // carried as node labels, quoted labels, edge labels, subgraph titles, tooltips, accTitle,
  // accDescr, front-matter titles and `@{ label: }` metadata, of which mermaid accepts 1,885 and
  // 1,814 agree -- 96% of what it was shown, not all of it, and the 71 that differ are enumerated
  // below. Feeding this filter its own output leaves the output unchanged across 60,550 inputs, so
  // a second pass of THIS filter is a no-op on everything measured. That is not the same claim as
  // mermaid's second `sanitize` having nothing left to do: what DOMPurify makes of this filter's
  // output has never been measured here, and only that would settle it.
  //
  // Reproduced: script, iframe, style and the rest of FORBID_CONTENTS removed along with their
  // contents; unknown elements unwrapped and their text kept; event handlers and every other
  // attribute outside ALLOWED_ATTR dropped; `javascript:` dropped from href and src, along with
  // every entity spelling of it a character reference can reach -- `java&Tab;script:`,
  // `javascript&colon;`, `&#106;avascript:`, `&Tab;javascript:` in leading position, and the two
  // combined as `&Tab;javascript&colon;`. The last two each escaped a version of this check that
  // the round before had read as complete, so `uriIsAllowed` below carries the readings it uses now
  // together with what each of them was measured against;
  // `<image>` renamed to `<img>`; void elements normalised, so `<br/>` and `<BR>` both become
  // `<br>`; unclosed elements closed; and an unterminated tag discarded along with everything it had
  // swallowed, which is why `A[a<b]` is `a` and not `a&lt;b`.
  //
  // The 71 that still differ are three shapes:
  //   - No character-reference decoding. A run already shaped like a reference is copied through
  //     instead, so mermaid stores `©` for `&copy;` where this stores `&copy;`, and `&amp;zz;` for
  //     an unknown `&zz;` where this stores `&zz;`. Both spellings render the same character
  //     wherever the label is put back into markup, which is the only place it goes. The one thing
  //     decoding really decides is a URL's scheme, and that is settled at the check itself.
  //   - No tree construction past the implied end tags below. `<p>a<p>b` comes out as mermaid's
  //     `<p>a</p><p>b</p>`, but the `<tbody>` the tree builder inserts into a bare `<table><tr>`
  //     does not appear, and neither does the adoption agency's untangling of `<b><p>x</b>y`.
  //   - `<noscript>` before anything has opened the body. jsdom parses with scripting disabled and
  //     hoists the children out, keeping `n` from `<noscript>n</noscript>`; WebKit, where the app
  //     actually runs mermaid, treats the content as raw text and drops it, which is what this
  //     does. The two reference engines disagree here, so only one of them can be matched.
  //
  // Three more the sweep did not reach but a direct probe against DOMPurify did, each costing a
  // table larger than the case looked worth: the SVG camelCase tag adjustment, so
  // `<svg><feGaussianBlur/></svg>` keeps a lowercase name; the HTML-element breakout from foreign
  // content, so `<svg><div>x</div></svg>` keeps the div inside the svg where mermaid lifts it out;
  // and DOMPurify's SANITIZE_DOM clobber check, which drops an `id` or `name` whose value collides
  // with a property of `document` or of a form element, so `<a id=body>` keeps its id here.
  //
  // The last two of those are open gaps rather than settled trade-offs. Foreign-content breakout
  // and DOM clobbering are the shapes real DOMPurify bypasses are built from, and nothing measured
  // here shows either to be reachable through this parser, or shows that it is not.
  //
  // What those six cover, and what they do not: they are the divergences two sweeps found -- the
  // 2,264-source diff against mermaid above, and a direct probe of DOMPurify for the three the diff
  // could not reach -- so they are what was looked for and seen, never a proof that the list closed.
  // Twice now a round has read its own list as closed and been wrong. The first time a seventh sat
  // outside it, `&Tab;javascript:` in an href. That was fixed, and the URL dimension was then swept
  // on its own terms -- 9,400 attribute values against real DOMPurify -- after which one shape
  // survived, a semicolon-less `&nbsp`, measured not to be a live scheme. An adversarial pass then
  // found an eighth that the sweep had not generated: `&Tab;javascript&colon;`, two references
  // doing two different jobs, which is what the per-reference reading at `uriIsAllowed` exists for.
  //
  // So read the six as a floor, and read the sweep counts as what was looked for rather than as what
  // is there. The dimensions other than URL have had no sweep of their own at all.
  // ===========================================================================

  function nameSet(names) {
    var out = Object.create(null);
    var list = names.split(" ");
    for (var i = 0; i < list.length; i += 1) if (list[i]) out[list[i]] = true;
    return out;
  }

  // DOMPurify's default ALLOWED_TAGS -- its html, svg, svgFilters and mathMl lists, lowercased the
  // way `addToSet` lowercases them -- less four names. `style` goes because mermaid's second pass
  // forbids it. `html`, `head` and `body` go because a fragment parsed into a body never builds
  // them: the start tag is dropped and the children carry on where they were, which is what
  // unwrapping already does.
  var ALLOWED_TAGS = nameSet(
    "a abbr acronym address altglyph altglyphdef altglyphitem animatecolor animatemotion " +
    "animatetransform area article aside audio b bdi bdo big blink blockquote br button " +
    "canvas caption center circle cite clippath code col colgroup content data datalist dd " +
    "decorator defs del desc details dfn dialog dir div dl dt element ellipse em enterkeyhint " +
    "exportparts feblend fecolormatrix fecomponenttransfer fecomposite feconvolvematrix " +
    "fediffuselighting fedisplacementmap fedistantlight fedropshadow feflood fefunca fefuncb " +
    "fefuncg fefuncr fegaussianblur feimage femerge femergenode femorphology feoffset " +
    "fepointlight fespecularlighting fespotlight fetile feturbulence fieldset figcaption " +
    "figure filter font footer form g glyph glyphref h1 h2 h3 h4 h5 h6 header hgroup hkern hr " +
    "i image img input inputmode ins kbd label legend li line lineargradient main map mark " +
    "marker marquee mask math menclose menu menuitem merror metadata meter mfenced mfrac " +
    "mglyph mi mlabeledtr mmultiscripts mn mo mover mpadded mpath mphantom mprescripts mroot " +
    "mrow ms mspace msqrt mstyle msub msubsup msup mtable mtd mtext mtr munder munderover nav " +
    "nobr ol optgroup option output p part path pattern picture polygon polyline pre progress " +
    "q radialgradient rect rp rt ruby s samp search section select shadow slot small source " +
    "spacer span stop strike strong sub summary sup svg switch symbol table tbody td template " +
    "text textarea textpath tfoot th thead time title tr track tref tspan tt u ul var video " +
    "view vkern wbr"
  );

  // DOMPurify's default ALLOWED_ATTR, same four lists. Nothing beginning `on` is in it, which is
  // the whole of why `<img src=x onerror=1>` loses its handler and keeps its source.
  var ALLOWED_ATTR = nameSet(
    "accent accent-height accentunder accept accumulate action additive align " +
    "alignment-baseline alt amplitude ascent attributename attributetype autocapitalize " +
    "autocomplete autopictureinpicture autoplay azimuth background basefrequency " +
    "baseline-shift begin bevelled bgcolor bias border by capture cellpadding cellspacing " +
    "checked cite class clear clip clip-path clip-rule clippathunits close color " +
    "color-interpolation color-interpolation-filters color-profile color-rendering cols " +
    "colspan columnalign columnlines columnspacing columnspan command commandfor controls " +
    "controlslist coords crossorigin cx cy d datetime decoding default denomalign depth " +
    "diffuseconstant dir direction disabled disablepictureinpicture disableremoteplayback " +
    "display displaystyle divisor dominant-baseline download draggable dur dx dy edgemode " +
    "elevation encoding enctype end enterkeyhint exponent exportparts face fence fill " +
    "fill-opacity fill-rule filter filterunits flood-color flood-opacity font-family " +
    "font-size font-size-adjust font-stretch font-style font-variant font-weight for frame fx " +
    "fy g1 g2 glyph-name glyphref gradienttransform gradientunits headers height hidden high " +
    "href hreflang id image-rendering in in2 inert inputmode integrity intercept ismap k k1 " +
    "k2 k3 k4 kernelmatrix kernelunitlength kerning keypoints keysplines keytimes kind label " +
    "lang largeop length lengthadjust letter-spacing lighting-color linethickness list " +
    "loading local loop low lquote lspace marker-end marker-mid marker-start markerheight " +
    "markerunits markerwidth mask mask-type maskcontentunits maskunits mathbackground " +
    "mathcolor mathsize mathvariant max maxlength maxsize media method min minlength minsize " +
    "mode movablelimits multiple muted name nonce noshade notation novalidate nowrap numalign " +
    "numoctaves offset opacity open operator optimum order orient orientation origin overflow " +
    "paint-order part path pathlength pattern patterncontentunits patterntransform " +
    "patternunits placeholder playsinline pointer-events points popover popovertarget " +
    "popovertargetaction poster preload preservealpha preserveaspectratio primitiveunits " +
    "pubdate r radiogroup radius readonly refx refy rel repeatcount repeatdur required " +
    "restart result rev reversed role rotate rowalign rowlines rows rowspacing rowspan rquote " +
    "rspace rx ry scale scope scriptlevel scriptminsize scriptsizemultiplier seed selected " +
    "selection separator separators shape shape-rendering size sizes slope slot span " +
    "specularconstant specularexponent spellcheck spreadmethod src srclang srcset start " +
    "startoffset stddeviation step stitchtiles stop-color stop-opacity stretchy stroke " +
    "stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit " +
    "stroke-opacity stroke-width style subscriptshift summary supscriptshift surfacescale " +
    "symmetric systemlanguage tabindex tablevalues targetx targety text-anchor " +
    "text-decoration text-orientation text-rendering textlength title transform " +
    "transform-origin translate type u1 u2 unicode usemap valign value values vector-effect " +
    "version vert-adv-y vert-origin-x vert-origin-y viewbox visibility voffset width " +
    "word-spacing wrap writing-mode x x1 x2 xchannelselector xlink:href xlink:title xml:id " +
    "xml:space xmlns xmlns:xlink y y1 y2 ychannelselector z zoomandpan"
  );

  // The elements DOMPurify deletes outright instead of unwrapping: its FORBID_CONTENTS, minus the
  // names that are also in ALLOWED_TAGS and therefore never removed in the first place, plus
  // `style` for mermaid's second pass. Without this list `<script>a</script>` would surrender its
  // tags and keep its `a`.
  var DROP_WITH_CONTENT = nameSet(
    "annotation-xml foreignobject iframe noembed noframes noscript plaintext script " +
    "selectedcontent style xmp"
  );

  var TRANSPARENT_TAGS = nameSet("html head body");

  var VOID_TAGS = nameSet(
    "area base basefont bgsound br col embed frame hr img input keygen link meta param source " +
    "track wbr"
  );

  // Elements whose content the tokenizer must not read as markup. `noscript` is deliberately absent:
  // it is raw text only where scripting is enabled, and DROP_WITH_CONTENT removes it whole under
  // either reading, so the only thing the distinction would change is how a nested `<noscript>` is
  // counted on the way out.
  var RAW_TEXT_TAGS = nameSet("script style iframe noembed noframes xmp textarea title");

  // The "generate implied end tags" cases a label can plausibly reach. The rest of tree
  // construction is not here; see the divergence note above.
  var IMPLIED_CLOSE = {
    li: nameSet("li"),
    dt: nameSet("dt dd"),
    dd: nameSet("dt dd"),
    option: nameSet("option"),
    optgroup: nameSet("option optgroup")
  };
  var CLOSES_P = nameSet(
    "address article aside blockquote center details dialog dir div dl fieldset figcaption " +
    "figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr listing main menu nav ol p " +
    "plaintext pre search section summary table ul xmp"
  );
  var OPEN_P = nameSet("p");
  // Where the search for an element to imply-close has to stop, standing in for the spec's several
  // flavours of scope.
  var SCOPE_BOUNDARY = nameSet("button caption marquee math object svg table td template th");

  // DOMPurify parses into a whole document with DOMParser and then serializes only `body`, so an
  // element the tree builder routes into `<head>` never reaches the output at all. Everything on
  // that list except these two is already dropped here by the allowlist or by DROP_WITH_CONTENT, so
  // only `title` and `template` need the distinction -- and they need it only until something opens
  // the body, after which the same tags are kept: `<title>t</title>b` sanitizes to `b` and
  // `b<title>t</title>` to `b<title>t</title>`.
  var HEAD_ROUTED = nameSet("template title");
  var HEAD_ELEMENTS = nameSet(
    "base basefont bgsound link meta noframes noscript script style template title"
  );

  // Table scaffolding is ignored outright by the "in body" insertion mode, which is why
  // `<colgroup><col></colgroup>` sanitizes to nothing while `<thead><tr><td>x` keeps its `x`. Inside
  // an open `<table>` the same tags are real, so the check is conditional.
  var TABLE_SCAFFOLD = nameSet("caption col colgroup frame tbody td tfoot th thead tr");

  // Names DOMPurify allows but only in their own namespace. An element with one of these names in
  // HTML content fails `_checkHtmlNamespace` -- `!ALL_MATHML_TAGS[tag] && (COMMON_SVG_AND_HTML_ELEMENTS[tag]
  // || !ALL_SVG_TAGS[tag])` -- and is force-removed with its subtree rather than unwrapped, so
  // `<path>p</path>` sanitizes to nothing where the unknown `<foo>bar</foo>` keeps its `bar`. The
  // list is the allowlist intersected with DOMPurify's SVG and MathML names, less its five
  // COMMON_SVG_AND_HTML_ELEMENTS and less `svg` and `math`, which are what open foreign content.
  var FOREIGN_ONLY_TAGS = nameSet(
    "altglyph altglyphdef altglyphitem animatecolor animatemotion animatetransform circle " +
    "clippath defs desc ellipse enterkeyhint exportparts feblend fecolormatrix " +
    "fecomponenttransfer fecomposite feconvolvematrix fediffuselighting fedisplacementmap " +
    "fedistantlight fedropshadow feflood fefunca fefuncb fefuncg fefuncr fegaussianblur " +
    "feimage femerge femergenode femorphology feoffset fepointlight fespecularlighting " +
    "fespotlight fetile feturbulence filter g glyph glyphref hkern image inputmode line " +
    "lineargradient marker mask menclose merror metadata mfenced mfrac mglyph mi mlabeledtr " +
    "mmultiscripts mn mo mover mpadded mpath mphantom mprescripts mroot mrow ms mspace " +
    "msqrt mstyle msub msubsup msup mtable mtd mtext mtr munder munderover part path " +
    "pattern polygon polyline radialgradient rect stop switch symbol text textpath tref " +
    "tspan view vkern"
  );

  var URI_SAFE_ATTR = nameSet(
    "alt class for id label name pattern placeholder role style summary title value xmlns"
  );
  var DATA_URI_TAGS = nameSet("audio image img source track video");
  var IS_ALLOWED_URI =
    /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;
  var ATTR_WHITESPACE = /[\u0000-\u0020\u00A0\u1680\u180E\u2000-\u2029\u205F\u3000]/g;
  var DATA_ATTR = /^data-[\-\w.\u00B7-\uFFFF]+$/;
  var ARIA_ATTR = /^aria-[\-\w]+$/;

  var CHAR_REF = /&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/g;
  var NUMERIC_REF = /&#(?:([0-9]+)|[xX]([0-9a-fA-F]+));/g;
  var SPACE = /[\t\n\f\r ]/;

  function isAlpha(c) {
    return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
  }

  // Reads one tag starting at the first character of its name. Returns null for the spec's
  // "eof-in-tag": the tokenizer emits nothing, so the tag and every character it had consumed are
  // simply gone, and that is the whole reason `A[a<b]` comes out as `a`.
  function readTag(src, p, isEnd) {
    var n = src.length;
    var name = "";
    while (p < n && !SPACE.test(src.charAt(p)) && src.charAt(p) !== "/" && src.charAt(p) !== ">") {
      name += src.charAt(p);
      p += 1;
    }
    var attrs = [];
    var seen = Object.create(null);
    var self = false;
    for (;;) {
      while (p < n && SPACE.test(src.charAt(p))) p += 1;
      if (p >= n) return null;
      var c = src.charAt(p);
      if (c === ">") { p += 1; break; }
      if (c === "/") {
        p += 1;
        if (p < n && src.charAt(p) === ">") { self = true; p += 1; break; }
        continue;
      }
      var aname = "";
      while (p < n && !SPACE.test(src.charAt(p)) &&
             src.charAt(p) !== "/" && src.charAt(p) !== ">" && src.charAt(p) !== "=") {
        aname += src.charAt(p);
        p += 1;
      }
      if (p >= n) return null;
      while (p < n && SPACE.test(src.charAt(p))) p += 1;
      if (p >= n) return null;
      var value = "";
      if (src.charAt(p) === "=") {
        p += 1;
        while (p < n && SPACE.test(src.charAt(p))) p += 1;
        if (p >= n) return null;
        var quote = src.charAt(p);
        if (quote === '"' || quote === "'") {
          p += 1;
          while (p < n && src.charAt(p) !== quote) { value += src.charAt(p); p += 1; }
          if (p >= n) return null;
          p += 1;
        } else {
          while (p < n && !SPACE.test(src.charAt(p)) && src.charAt(p) !== ">") {
            value += src.charAt(p);
            p += 1;
          }
          if (p >= n) return null;
        }
      }
      aname = aname.toLowerCase();
      // The DOM keeps the first of a repeated attribute, not the last.
      if (aname && !seen[aname]) { seen[aname] = true; attrs.push([aname, value]); }
    }
    return { end: p, name: name.toLowerCase(), attrs: attrs, self: self, kind: isEnd ? "end" : "start" };
  }

  // Skips a comment, a doctype, a processing instruction or a bogus comment. None of them survives:
  // DOMPurify's default ALLOWED_TAGS has no `#comment`, and a doctype inside a body fragment is
  // dropped by the tree builder, so all four cases are the same case here.
  function skipDeclaration(src, i) {
    var n = src.length;
    if (src.substr(i, 4) === "<!--") {
      // `-->` and `--!>` both end a comment, so whichever comes first does.
      var end = src.indexOf("-->", i + 4);
      var bang = src.indexOf("--!>", i + 4);
      if (end === -1 || (bang !== -1 && bang < end)) return bang === -1 ? n : bang + 4;
      return end + 3;
    }
    var gt = src.indexOf(">", i);
    return gt === -1 ? n : gt + 1;
  }

  function tokenize(src) {
    var toks = [];
    var text = "";
    var i = 0;
    var n = src.length;
    while (i < n) {
      if (src.charAt(i) !== "<") { text += src.charAt(i); i += 1; continue; }
      var after = src.charAt(i + 1);
      var isEnd = after === "/";
      var first = src.charAt(i + (isEnd ? 2 : 1));
      if (after === "!" || after === "?" || (isEnd && !isAlpha(first))) {
        i = skipDeclaration(src, i);
        continue;
      }
      if (!isAlpha(first)) { text += "<"; i += 1; continue; }
      var tag = readTag(src, i + (isEnd ? 2 : 1), isEnd);
      if (!tag) break;
      if (text) { toks.push({ kind: "text", value: text }); text = ""; }
      toks.push(tag);
      i = tag.end;
      if (tag.kind === "start" && !tag.self && RAW_TEXT_TAGS[tag.name]) {
        var close = new RegExp("</" + tag.name + "[\\t\\n\\f\\r />]", "i").exec(src.slice(i));
        var raw = close ? src.substr(i, close.index) : src.slice(i);
        if (raw) toks.push({ kind: "text", value: raw });
        i += raw.length;
      } else if (tag.kind === "start" && tag.name === "plaintext") {
        if (i < n) toks.push({ kind: "text", value: src.slice(i) });
        i = n;
      }
    }
    if (text) toks.push({ kind: "text", value: text });
    return toks;
  }

  // The HTML serializer's "escaping a string", which is what `innerHTML` runs on the way out. A run
  // already spelling a character reference is copied rather than re-escaped: decoding it and
  // re-encoding it is the identity for every reference this escaper itself produces, and for the
  // rest it costs the byte difference recorded in the divergence note.
  function escapeText(s, attribute) {
    var out = "";
    for (var i = 0; i < s.length; i += 1) {
      var c = s.charAt(i);
      if (c === "&") {
        CHAR_REF.lastIndex = i;
        var ref = CHAR_REF.exec(s);
        if (ref && ref.index === i) { out += ref[0]; i += ref[0].length - 1; continue; }
        out += "&amp;";
      } else if (c === "\u00a0") {
        out += "&nbsp;";
      } else if (attribute) {
        out += c === '"' ? "&quot;" : c;
      } else {
        out += c === "<" ? "&lt;" : c === ">" ? "&gt;" : c;
      }
    }
    return out;
  }

  // DOMPurify decides a URL attribute on the fully decoded value, and this does not decode. Numeric
  // references are cheap to resolve so they are; a named one is answered by reading the value once
  // per decoding that could change the verdict and refusing unless every reading is safe.
  //
  // Those decodings are a short list rather than a guess. IS_ALLOWED_URI looks at the leading run of
  // scheme characters `[a-z+.-]` and the colon that ends it, and nothing after, so a reference
  // matters only if it lands in that run and decodes to whitespace ATTR_WHITESPACE then deletes, to
  // a colon, or to more scheme characters. Walking the binary trie that parse5 and therefore jsdom
  // decode with -- `entities/src/generated/decode-data-html.ts`, 2,125 names plus the 106 that also
  // decode without their semicolon, matching the spec's 2,231 -- says which names those are: 54
  // decode to ATTR_WHITESPACE (`&Tab;` and `&NewLine;`, but also `&hellip;` and `&bull;`, because
  // DOMPurify's class runs U+2000 to U+2029), one to a colon (`&colon;`), and three to scheme
  // characters (`&period;`, `&plus;`, and `&fjlig;`, the sole name whose decoding contains ASCII
  // letters -- "fj"). Every other name decodes to a character that ends the run exactly where the
  // literal `&` ends it, so the literal reading already decides it. Hence REF_READINGS, and hence
  // no table of two thousand entity names here.
  //
  // What was here read the value only twice, literally and with a colon substituted, and that let a
  // leading reference through: `&Tab;javascript:alert(1)` reads as `&...` literally and
  // `:javascript:...` with the colon, and IS_ALLOWED_URI's `[^a-z]` branch blesses any value whose
  // first character is not a letter, so neither reading refused and the href survived to re-parse as
  // `protocol === 'javascript:'`. Mid-word the colon substitution happened to break the scheme, so
  // `java&Tab;script:` was refused all along and only the leading spelling leaked. The empty reading
  // is what closes it.
  //
  // Measured against real DOMPurify 3.4.14 under jsdom, 2,350 values carried on href, src, datetime
  // and cite for 9,400 pairs: 1,993 stricter, 8 looser. Stricter costs a dropped attribute --
  // `datetime="Jan&nbsp;1"` is the everyday one -- where looser would cost a live scheme, so the
  // asymmetry is the one to have.
  //
  // The 8 are one shape, `data&nbsp:text/html,x` and `file&nbsp:///etc/passwd`: a legacy reference
  // spelled without its semicolon, which HTML still decodes in an attribute when the next character
  // is neither `=` nor alphanumeric. CHAR_REF requires the semicolon and widening it would refuse
  // ordinary relative links carrying a query, `p?a&b` among them, which is the worse trade. Neither
  // is a live scheme, and that is checked rather than assumed: of the 106 semicolon-optional names
  // none decodes to a colon or to a character the WHATWG URL parser strips, `&nbsp` decodes to
  // U+00A0, which that parser keeps, and jsdom's URL reads both values back as `protocol: 'http:'`,
  // a relative path. DOMPurify is stricter than the URL parser requires here rather than safer.
  var REF_READINGS = ["", ":", ".", "fj"];

  function uriIsAllowed(value) {
    var decoded = value.replace(NUMERIC_REF, function (_, dec, hex) {
      var code = dec ? parseInt(dec, 10) : parseInt(hex, 16);
      return code >= 0 && code <= 0x10ffff ? String.fromCodePoint(code) : _;
    });
    if (!schemeIsAllowed(decoded)) return false;
    if (decoded.indexOf("&") === -1) return true;
    for (var i = 0; i < REF_READINGS.length; i += 1) {
      if (!schemeIsAllowed(decoded.replace(CHAR_REF, REF_READINGS[i]))) return false;
    }
    // Every reference read the same way is not enough, because the attack that got through gave two
    // references two different jobs: `&Tab;javascript&colon;alert(1)` needs the first to vanish and
    // the second to become a colon, and no single reading produces both at once -- read as nothing
    // there is no colon, read as a colon the value starts with one and IS_ALLOWED_URI's non-letter
    // branch waves it through. Measured after the previous round closed `&Tab;javascript:`: this
    // spelling kept its href on all five URL attributes and re-parsed to protocol "javascript:".
    //
    // So the references are also read the way that attack reads them -- one of them the colon, the
    // rest gone. That is one pass per reference rather than the four-to-the-N of every combination,
    // and it is the only combination that matters: a scheme is a run of letters then a colon, so the
    // references before the colon have to disappear for the run to be unbroken, and exactly one has
    // to supply the colon itself.
    var refs = decoded.match(CHAR_REF);
    if (!refs || refs.length < 2) return true;
    for (var colon = 0; colon < refs.length; colon += 1) {
      var seen = -1;
      var reading = decoded.replace(CHAR_REF, function () {
        seen += 1;
        return seen === colon ? ":" : "";
      });
      if (!schemeIsAllowed(reading)) return false;
    }
    return true;
  }

  function schemeIsAllowed(value) {
    return IS_ALLOWED_URI.test(value.replace(ATTR_WHITESPACE, ""));
  }

  function attrIsAllowed(tag, name, value) {
    // Declarative partial updates: `for` links an element to a patch target anywhere but on a
    // <label> or an <output>, and `patchsrc` fetches markup. DOMPurify refuses both unconditionally.
    if (name === "patchsrc" || (name === "for" && tag !== "label" && tag !== "output")) return false;
    if (DATA_ATTR.test(name) || ARIA_ATTR.test(name)) return true;
    if (!ALLOWED_ATTR[name]) return false;
    if (URI_SAFE_ATTR[name]) return true;
    if (uriIsAllowed(value)) return true;
    if ((name === "src" || name === "href" || name === "xlink:href") && tag !== "script" &&
        value.indexOf("data:") === 0 && DATA_URI_TAGS[tag]) {
      return true;
    }
    return !value;
  }

  function openTag(tag) {
    var out = "<" + tag.name;
    for (var i = 0; i < tag.attrs.length; i += 1) {
      var name = tag.attrs[i][0];
      var value = tag.attrs[i][1];
      if (attrIsAllowed(tag.name, name, value)) out += " " + name + '="' + escapeText(value, true) + '"';
    }
    return out + ">";
  }

  function popTo(open, out, index) {
    while (open.length > index) {
      var el = open.pop();
      if (el.kept) out.push("</" + el.name + ">");
    }
  }

  function impliedClose(open, out, targets) {
    for (var i = open.length - 1; i >= 0; i -= 1) {
      if (targets[open[i].name]) { popTo(open, out, i); return; }
      if (SCOPE_BOUNDARY[open[i].name]) return;
    }
  }

  function hasOpen(open, name) {
    for (var i = open.length - 1; i >= 0; i -= 1) if (open[i].name === name) return true;
    return false;
  }

  function inForeignContent(open, name) {
    if (name === "svg" || name === "math") return true;
    for (var i = open.length - 1; i >= 0; i -= 1) {
      if (open[i].name === "svg" || open[i].name === "math") return true;
    }
    return false;
  }

  function sanitizeText(txt) {
    // DOMPurify's own early exit -- `if (stringIndexOf(dirty, '<') === -1) return dirty` -- and the
    // reason `charTest('&')` and the commented-out `charTest('>', '&gt;')` in flow.spec.js:128-140
    // read the way they do. Without a `<` nothing is ever parsed, so nothing is ever re-escaped.
    if (!txt || txt.indexOf("<") === -1) return txt;
    var toks = tokenize(txt);
    var out = [];
    var open = [];
    var skipName = "";
    var skipDepth = 0;
    var inHead = true;
    for (var k = 0; k < toks.length; k += 1) {
      var tok = toks[k];
      if (skipDepth > 0) {
        if (tok.kind === "start" && tok.name === skipName && !tok.self) skipDepth += 1;
        else if (tok.kind === "end" && tok.name === skipName) skipDepth -= 1;
        continue;
      }
      if (tok.kind === "text") {
        // Leading whitespace is the one thing that does not open the body: the tree builder ignores
        // it before `<head>` and DOMPurify puts it back by hand afterwards.
        if (/\S/.test(tok.value)) inHead = false;
        out.push(escapeText(tok.value, false));
        continue;
      }
      var name = tok.name;
      if (TRANSPARENT_TAGS[name]) continue;
      if (tok.kind === "end") {
        if (VOID_TAGS[name]) continue;
        for (var j = open.length - 1; j >= 0; j -= 1) {
          if (open[j].name === name) { popTo(open, out, j); break; }
        }
        continue;
      }
      var headRouted = inHead && HEAD_ROUTED[name];
      if (!HEAD_ELEMENTS[name]) inHead = false;
      // The "in body" insertion mode renames `image` to `img` before inserting it, which is why
      // `<image src=x>` comes back as an `<img>` and never meets the namespace check below.
      if (name === "image" && !inForeignContent(open, name)) { name = "img"; tok.name = name; }
      if (TABLE_SCAFFOLD[name] && !hasOpen(open, "table")) continue;
      var allowed = ALLOWED_TAGS[name] && !headRouted &&
        !(FOREIGN_ONLY_TAGS[name] && !inForeignContent(open, name));
      if (!allowed && (DROP_WITH_CONTENT[name] || headRouted || FOREIGN_ONLY_TAGS[name])) {
        if (!tok.self && !VOID_TAGS[name]) { skipName = name; skipDepth = 1; }
        continue;
      }
      if (IMPLIED_CLOSE[name]) impliedClose(open, out, IMPLIED_CLOSE[name]);
      if (CLOSES_P[name]) impliedClose(open, out, OPEN_P);
      if (allowed) out.push(openTag(tok));
      // A solidus closes the element only in foreign content; in HTML it is ignored, which is how
      // `<foo/>bar` ends up with `bar` inside the element rather than after it.
      if (VOID_TAGS[name]) continue;
      if (tok.self && inForeignContent(open, name)) {
        if (allowed) out.push("</" + name + ">");
        continue;
      }
      open.push({ name: name, kept: Boolean(allowed) });
    }
    popTo(open, out, 0);
    return out.join("");
  }

  // ===========================================================================
  // `click ... href` targets.
  //
  // mermaid puts a link through @braintree/sanitize-url whenever the security level is anything
  // but loose (its own `formatUrl`, chunk-75Z2AOVW.mjs:142-152). What follows is a port of that
  // package's `sanitizeUrl` at 7.1.2 -- the copy node_modules/mermaid resolves and the copy the
  // mermaid.min.js beside this file has bundled, which is why there is one behaviour to match and
  // not two.
  //
  // What stood here was a single regex over the scheme, written on the reading that the scheme
  // check is the package's whole job. It is not, and the shortfall was not cosmetic. The package
  // decodes before it decides, so `&#106;avascript:alert(1)`, `javascript&colon;alert(1)` and
  // `%6a%61vascript:alert(1)` were stored verbatim where mermaid stores `about:blank` -- and the
  // first two are decoded straight back into a working `javascript:` href by the HTML parser the
  // moment such a link is written into an attribute. The old pattern also caught what mermaid
  // lets through: it allowed whitespace between the letters, so `j a v a s c r i p t:` was blanked
  // here while sanitize-url strips only C0, C1 and a few Unicode spaces and then matches the
  // literal word.
  // ===========================================================================

  var BLANK_URL = "about:blank";

  // sanitize-url's constants, verbatim from the package's constants.js. Their oddities are load
  // bearing and are the package's, not ours: `(^\w|;)?` in the entity pattern can never match its
  // first branch, so it only makes the trailing semicolon optional, and together with the greedy
  // `\w+` before it that is why `&#106avascript:alert(1)` collapses to `:alert(1)` -- digits and
  // letters are captured as one run whose char code is NaN. The scheme pattern is greedy too, so
  // `http://x.com:8080/a` yields the scheme `http://x.com:` and leaves by the `://` exit below
  // rather than being canonicalised.
  var URL_CTRL_CHARS = /[\u0000-\u001F\u007F-\u009F\u2000-\u200D\uFEFF]/gim;
  var URL_HTML_ENTITIES = /&#(\w+)(^\w|;)?/g;
  var URL_HTML_CTRL_ENTITY = /&(newline|tab);/gi;
  var URL_WS_ESCAPES = /(\\|%5[cC])((%(6[eE]|72|74))|[nrt])/g;
  var URL_SCHEME = /^.+(:|&colon;)/gim;
  var URL_INVALID_PROTOCOL = /^([^\w]*)(javascript|data|vbscript)/im;

  // A `%` that begins no escape makes decodeURIComponent throw. sanitize-url keeps the string as it
  // stands rather than rejecting it, which is how `http://x.com/%zz` survives to be parsed.
  function decodeUrlOnce(uri) {
    try { return decodeURIComponent(uri); } catch (e) { return uri; }
  }

  // sanitize-url hands http and https to the host's WHATWG URL parser and returns what that prints.
  // That one call is what puts the trailing slash on `http://x.com`, percent-encodes the space in
  // `/a b`, lowercases `HTTP://X.COM`, punycodes `münchen.de` and reads `http://1.1` as
  // `http://1.0.0.1/`. Writing a URL parser here was the alternative and it was rejected outright:
  // IDNA, the percent-encode sets, the IPv4 shorthand and path collapsing are each a table this
  // file has no business carrying, and a canonical form that is subtly wrong is worse than none.
  // mermaid and this both run where `URL` is a global -- WebKit in the app, node under the vendored
  // specs -- so this is not an approximation of mermaid's answer, it is the same call into the same
  // parser. `URL.canParse` is not used, because it is Safari 18 and newer and is defined as whether
  // the constructor throws; the catch below is that definition. The protocol and hostname
  // assignments are sanitize-url's own and are no-ops, the parser having lowercased both already.
  //
  // A host with no `URL` would be the one place this falls short, and there it leaves the link as
  // it found it rather than guessing at a canonical form. Nothing this file is built for is in that
  // position, and mermaid could not run there either.
  function canonicalHttpUrl(url) {
    if (typeof URL !== "function") return url;
    var parsed;
    try { parsed = new URL(url); } catch (e) { return BLANK_URL; }
    parsed.protocol = parsed.protocol.toLowerCase();
    parsed.hostname = parsed.hostname.toLowerCase();
    return parsed.toString();
  }

  function sanitizeUrl(url) {
    // Each pass strips one layer of encoding and the loop repeats while another layer is still
    // visible, so `%26%23106%3bavascript:alert(1)` arrives at `javascript:` and is blanked like the
    // plain spelling. It terminates because every pass either removes characters or replaces an
    // escape with the single character it stood for, so a string that still matches gets shorter.
    var decoded = decodeUrlOnce(url.trim());
    var pending;
    do {
      decoded = decoded
        .replace(URL_CTRL_CHARS, "")
        .replace(URL_HTML_ENTITIES, function (match, dec) { return String.fromCharCode(dec); })
        .replace(URL_HTML_CTRL_ENTITY, "")
        .replace(URL_CTRL_CHARS, "")
        .replace(URL_WS_ESCAPES, "")
        .trim();
      decoded = decodeUrlOnce(decoded);
      pending = decoded.match(URL_CTRL_CHARS) || decoded.match(URL_HTML_ENTITIES) ||
        decoded.match(URL_HTML_CTRL_ENTITY) || decoded.match(URL_WS_ESCAPES);
    } while (pending && pending.length > 0);
    if (!decoded) return BLANK_URL;
    // A path is never a scheme, so `./javascript:x` is left alone and never reaches the check.
    if (decoded.charAt(0) === "." || decoded.charAt(0) === "/") return decoded;
    var trimmed = decoded.trimStart();
    var schemeMatch = trimmed.match(URL_SCHEME);
    if (!schemeMatch) return decoded;
    var scheme = schemeMatch[0].toLowerCase().trim();
    if (URL_INVALID_PROTOCOL.test(scheme)) return BLANK_URL;
    var backSanitized = trimmed.replace(/\\/g, "/");
    if (scheme === "mailto:" || scheme.indexOf("://") !== -1) return backSanitized;
    if (scheme === "http:" || scheme === "https:") return canonicalHttpUrl(backSanitized);
    return backSanitized;
  }

  function formatUrl(linkStr) {
    var url = String(linkStr).trim();
    if (!url) return undefined;
    return CONFIG.securityLevel === "loose" ? url : sanitizeUrl(url);
  }

  // ===========================================================================
  // The `@{ ... }` metadata loader.
  //
  // mermaid hands the accumulated SHAPE_DATA run to js-yaml under JSON_SCHEMA, wrapping a run with
  // no newline in braces so it parses as a flow mapping (flowDb.reference.ts:141-150). js-yaml
  // cannot be pulled in here, so what follows is a port of the loader out of the copy mermaid
  // bundles (node_modules/mermaid/dist/chunks/mermaid.core/chunk-LNGE3PJU.mjs), cut to loading
  // under the JSON schema: the failsafe types plus null, bool, int and float, and nothing of the
  // dumper, the core/default schemas or !!binary and !!timestamp, which JSON_SCHEMA never resolves.
  //
  // It replaces a pair of hand-written splitters over `,` and `:`, and the YAML they missed was not
  // exotic. `@{shape:Rect}` is one key `shape:Rect` with a null value, because a plain scalar in
  // flow context runs on through a colon that is not followed by space or a flow indicator;
  // `@{ shape: rect # c }` ends at the comment; `@{ "shape": rect }` has a quoted key;
  // `@{ label: [a, b] }` is a flow sequence. The splitters read all four wrongly and turned the
  // first two into a throw -- a diagram mermaid draws that FlowPeek refuses, which is the one
  // failure the reader can neither see nor work around. Four more special cases would have been
  // wrong about `? a : b`, `&anchor`, `*alias` and duplicate keys the same way, so the loader goes
  // in whole instead.
  //
  // Error *text* is deliberately not ported: js-yaml decorates every message with a rendered
  // source snippet and a line/column mark, and nothing here reads either. Where mermaid raises a
  // YAMLException this raises a plain Error with the same wording minus that decoration.
  //
  // Differential-tested against the real thing rather than against the specs, which say almost
  // nothing about the YAML: 13,158 `@{...}` bodies driven through both this and mermaid 11.17.2's
  // own parser agreed on all but 23, and each of those 23 diverges in the SHAPE_DATA lexer or in
  // addVertex, identically before and after this file changed.
  var loadShapeData = (function () {
    var CONTEXT_FLOW_IN = 1;
    var CONTEXT_FLOW_OUT = 2;
    var CONTEXT_BLOCK_IN = 3;
    var CONTEXT_BLOCK_OUT = 4;
    var CHOMPING_CLIP = 1;
    var CHOMPING_STRIP = 2;
    var CHOMPING_KEEP = 3;

    var PATTERN_NON_PRINTABLE = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x84\x86-\x9F\uFFFE\uFFFF]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]/;
    var PATTERN_FLOW_INDICATORS = /[,\[\]{}]/;
    var PATTERN_TAG_HANDLE = /^(?:!|!!|![0-9A-Za-z-]+!)$/;
    var PATTERN_TAG_URI = /^(?:!|[^,\[\]{}])(?:%[0-9a-f]{2}|[0-9a-z\-#;/?:@&=+$,_.!~*'()\[\]])*$/i;

    var hasOwn = Object.prototype.hasOwnProperty;

    function isEol(c) { return c === 10 || c === 13; }
    function isWhiteSpace(c) { return c === 9 || c === 32; }
    function isWsOrEol(c) { return c === 9 || c === 32 || c === 10 || c === 13; }
    function isFlowIndicator(c) { return c === 44 || c === 91 || c === 93 || c === 123 || c === 125; }
    function fromDecimalCode(c) { return c >= 48 && c <= 57 ? c - 48 : -1; }

    function fromHexCode(c) {
      if (c >= 48 && c <= 57) return c - 48;
      var lc = c | 32;
      return lc >= 97 && lc <= 102 ? lc - 97 + 10 : -1;
    }

    // `\x`, `\u` and `\U` take 2, 4 and 8 hex digits; everything else is not a hex escape.
    function escapedHexLen(c) {
      if (c === 120) return 2;
      if (c === 117) return 4;
      if (c === 85) return 8;
      return 0;
    }

    var SIMPLE_ESCAPES = {
      48: "\0", 97: "\x07", 98: "\b", 116: "\t", 9: "\t", 110: "\n", 118: "\v", 102: "\f",
      114: "\r", 101: "\x1b", 32: " ", 34: '"', 47: "/", 92: "\\", 78: "\x85", 95: "\xa0",
      76: "\u2028", 80: "\u2029"
    };

    function repeat(s, n) {
      var out = "";
      for (var i = 0; i < n; i += 1) out += s;
      return out;
    }

    function codepoint(c) {
      if (c <= 0xffff) return String.fromCharCode(c);
      return String.fromCharCode(((c - 0x10000) >> 10) + 0xd800, ((c - 0x10000) & 0x3ff) + 0xdc00);
    }

    // ---- the JSON schema's types -------------------------------------------
    // These four are the whole of what JSON_SCHEMA resolves implicitly, and they are why
    // `yes`/`no`/`on`/`off` stay strings while `true`/`True`/`TRUE` convert, why `0X10` stays a
    // string where `0x10` becomes 16, and why `1_000` stays a string. They are transcribed from the
    // build mermaid ships, whose resolvers accept no underscore digit separators, rather than from
    // the YAML 1.1 spec, which does.
    function resolveNull(data) {
      if (data === null) return true;
      var max = data.length;
      return (max === 1 && data === "~") || (max === 4 && (data === "null" || data === "Null" || data === "NULL"));
    }

    function resolveBool(data) {
      if (data === null) return false;
      var max = data.length;
      return (max === 4 && (data === "true" || data === "True" || data === "TRUE")) ||
        (max === 5 && (data === "false" || data === "False" || data === "FALSE"));
    }

    function parseYamlInteger(data) {
      var value = data;
      var sign = 1;
      var ch = value[0];
      if (ch === "-" || ch === "+") {
        if (ch === "-") sign = -1;
        value = value.slice(1);
        ch = value[0];
      }
      if (value === "0") return 0;
      if (ch === "0") {
        if (value[1] === "b") return sign * parseInt(value.slice(2), 2);
        if (value[1] === "x") return sign * parseInt(value.slice(2), 16);
        if (value[1] === "o") return sign * parseInt(value.slice(2), 8);
      }
      return sign * parseInt(value, 10);
    }

    function resolveInt(data) {
      if (data === null) return false;
      var max = data.length;
      var index = 0;
      var hasDigits = false;
      if (!max) return false;
      var ch = data[index];
      if (ch === "-" || ch === "+") ch = data[++index];
      if (ch === "0") {
        if (index + 1 === max) return true;
        ch = data[++index];
        if (ch === "b" || ch === "x" || ch === "o") {
          var radix = ch === "b" ? 2 : ch === "x" ? 16 : 8;
          index += 1;
          for (; index < max; index += 1) {
            var digit = fromHexCode(data.charCodeAt(index));
            if (digit < 0 || digit >= radix) return false;
            hasDigits = true;
          }
          return hasDigits && isFinite(parseYamlInteger(data));
        }
      }
      for (; index < max; index += 1) {
        if (fromDecimalCode(data.charCodeAt(index)) < 0) return false;
        hasDigits = true;
      }
      return hasDigits && isFinite(parseYamlInteger(data));
    }

    var YAML_FLOAT = /^(?:[-+]?(?:[0-9]+)(?:\.[0-9]*)?(?:[eE][-+]?[0-9]+)?|\.[0-9]+(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$/;
    var YAML_FLOAT_SPECIAL = /^(?:[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$/;

    function resolveFloat(data) {
      if (data === null) return false;
      if (!YAML_FLOAT.test(data)) return false;
      return isFinite(parseFloat(data)) || YAML_FLOAT_SPECIAL.test(data);
    }

    function constructFloat(data) {
      var value = data.toLowerCase();
      var sign = value[0] === "-" ? -1 : 1;
      if ("+-".indexOf(value[0]) >= 0) value = value.slice(1);
      if (value === ".inf") return sign === 1 ? Infinity : -Infinity;
      if (value === ".nan") return NaN;
      return sign * parseFloat(value);
    }

    function always() { return true; }

    // Implicit resolution is tried in this order, so `0` reaches the int type before the float one.
    var IMPLICIT_TYPES = [
      { tag: "tag:yaml.org,2002:null", kind: "scalar", resolve: resolveNull, construct: function () { return null; } },
      { tag: "tag:yaml.org,2002:bool", kind: "scalar", resolve: resolveBool, construct: function (d) { return d === "true" || d === "True" || d === "TRUE"; } },
      { tag: "tag:yaml.org,2002:int", kind: "scalar", resolve: resolveInt, construct: parseYamlInteger },
      { tag: "tag:yaml.org,2002:float", kind: "scalar", resolve: resolveFloat, construct: constructFloat }
    ];

    var ALL_TYPES = [
      { tag: "tag:yaml.org,2002:str", kind: "scalar", resolve: always, construct: function (d) { return d !== null ? d : ""; } },
      { tag: "tag:yaml.org,2002:seq", kind: "sequence", resolve: always, construct: function (d) { return d !== null ? d : []; } },
      { tag: "tag:yaml.org,2002:map", kind: "mapping", resolve: always, construct: function (d) { return d !== null ? d : {}; } }
    ].concat(IMPLICIT_TYPES);

    var TYPE_MAP = { scalar: {}, sequence: {}, mapping: {}, fallback: {} };
    for (var ti = 0; ti < ALL_TYPES.length; ti += 1) {
      TYPE_MAP[ALL_TYPES[ti].kind][ALL_TYPES[ti].tag] = ALL_TYPES[ti];
      TYPE_MAP.fallback[ALL_TYPES[ti].tag] = ALL_TYPES[ti];
    }

    // ---- the loader ---------------------------------------------------------
    // js-yaml wraps every message in a YAMLException carrying a mark and a rendered source
    // snippet, and rewinds `position` before some throws so the caret lands on the offending
    // character. Nothing in FlowPeek renders a snippet, so only the offset is kept -- enough to
    // leave those rewinds meaning something, and enough for a caller that one day wants to point
    // at the character.
    function fail(st, message) {
      var error = new Error(message);
      error.yamlOffset = st.position;
      throw error;
    }

    function newState(input) {
      return {
        input: input,
        length: input.length,
        position: 0,
        line: 0,
        lineStart: 0,
        lineIndent: 0,
        depth: 0,
        firstTabInLine: -1,
        kind: null,
        result: null,
        tag: null,
        anchor: null,
        anchorMap: Object.create(null),
        tagMap: Object.create(null),
        documents: []
      };
    }

    function snapshot(st) {
      return {
        position: st.position, line: st.line, lineStart: st.lineStart, lineIndent: st.lineIndent,
        firstTabInLine: st.firstTabInLine, tag: st.tag, anchor: st.anchor, kind: st.kind, result: st.result
      };
    }

    function restore(st, snap) {
      st.position = snap.position;
      st.line = snap.line;
      st.lineStart = snap.lineStart;
      st.lineIndent = snap.lineIndent;
      st.firstTabInLine = snap.firstTabInLine;
      st.tag = snap.tag;
      st.anchor = snap.anchor;
      st.kind = snap.kind;
      st.result = snap.result;
    }

    function storeAnchor(st, name, value) {
      st.anchorMap[name] = value;
    }

    function captureSegment(st, start, end, checkJson) {
      if (start >= end) return;
      var slice = st.input.slice(start, end);
      if (checkJson) {
        for (var i = 0; i < slice.length; i += 1) {
          var c = slice.charCodeAt(i);
          if (!(c === 9 || (c >= 32 && c <= 1114111))) fail(st, "expected valid JSON character");
        }
      } else if (PATTERN_NON_PRINTABLE.test(slice)) {
        fail(st, "the stream contains non-printable characters");
      }
      st.result += slice;
    }

    function readLineBreak(st) {
      var ch = st.input.charCodeAt(st.position);
      if (ch === 10) {
        st.position += 1;
      } else if (ch === 13) {
        st.position += 1;
        if (st.input.charCodeAt(st.position) === 10) st.position += 1;
      } else {
        fail(st, "a line break is expected");
      }
      st.line += 1;
      st.lineStart = st.position;
      st.firstTabInLine = -1;
    }

    function skipSeparationSpace(st, allowComments, checkIndent) {
      var lineBreaks = 0;
      var ch = st.input.charCodeAt(st.position);
      while (ch !== 0) {
        while (isWhiteSpace(ch)) {
          if (ch === 9 && st.firstTabInLine === -1) st.firstTabInLine = st.position;
          ch = st.input.charCodeAt(++st.position);
        }
        if (allowComments && ch === 35) {
          do { ch = st.input.charCodeAt(++st.position); } while (ch !== 10 && ch !== 13 && ch !== 0);
        }
        if (!isEol(ch)) break;
        readLineBreak(st);
        ch = st.input.charCodeAt(st.position);
        lineBreaks += 1;
        st.lineIndent = 0;
        while (ch === 32) {
          st.lineIndent += 1;
          ch = st.input.charCodeAt(++st.position);
        }
      }
      // js-yaml only warns about deficient indentation here, and `load` installs no warning
      // handler, so `checkIndent` has nothing left to do and is not carried through.
      return lineBreaks;
    }

    function testDocumentSeparator(st) {
      var p = st.position;
      var ch = st.input.charCodeAt(p);
      if ((ch === 45 || ch === 46) && ch === st.input.charCodeAt(p + 1) && ch === st.input.charCodeAt(p + 2)) {
        ch = st.input.charCodeAt(p + 3);
        if (ch === 0 || isWsOrEol(ch)) return true;
      }
      return false;
    }

    function writeFoldedLines(st, count) {
      if (count === 1) st.result += " ";
      else if (count > 1) st.result += repeat("\n", count - 1);
    }

    function readPlainScalar(st, nodeIndent, withinFlowCollection) {
      var kind = st.kind;
      var result = st.result;
      var ch = st.input.charCodeAt(st.position);
      if (isWsOrEol(ch) || isFlowIndicator(ch) || ch === 35 || ch === 38 || ch === 42 || ch === 33 ||
        ch === 124 || ch === 62 || ch === 39 || ch === 34 || ch === 37 || ch === 64 || ch === 96) {
        return false;
      }
      if (ch === 63 || ch === 45) {
        var next = st.input.charCodeAt(st.position + 1);
        if (isWsOrEol(next) || (withinFlowCollection && isFlowIndicator(next))) return false;
      }
      st.kind = "scalar";
      st.result = "";
      var captureStart = st.position;
      var captureEnd = st.position;
      var pending = false;
      var line, lineStart, lineIndent;
      while (ch !== 0) {
        if (ch === 58) {
          // The colon only ends the scalar when a space or a flow indicator follows it. This is
          // what makes `@{shape:Rect}` one key with a null value rather than shape -> Rect.
          var following = st.input.charCodeAt(st.position + 1);
          if (isWsOrEol(following) || (withinFlowCollection && isFlowIndicator(following))) break;
        } else if (ch === 35) {
          if (isWsOrEol(st.input.charCodeAt(st.position - 1))) break;
        } else if ((st.position === st.lineStart && testDocumentSeparator(st)) ||
          (withinFlowCollection && isFlowIndicator(ch))) {
          break;
        } else if (isEol(ch)) {
          line = st.line;
          lineStart = st.lineStart;
          lineIndent = st.lineIndent;
          skipSeparationSpace(st, false, -1);
          if (st.lineIndent >= nodeIndent) {
            pending = true;
            ch = st.input.charCodeAt(st.position);
            continue;
          }
          st.position = captureEnd;
          st.line = line;
          st.lineStart = lineStart;
          st.lineIndent = lineIndent;
          break;
        }
        if (pending) {
          captureSegment(st, captureStart, captureEnd, false);
          writeFoldedLines(st, st.line - line);
          captureStart = captureEnd = st.position;
          pending = false;
        }
        if (!isWhiteSpace(ch)) captureEnd = st.position + 1;
        ch = st.input.charCodeAt(++st.position);
      }
      captureSegment(st, captureStart, captureEnd, false);
      if (st.result) return true;
      st.kind = kind;
      st.result = result;
      return false;
    }

    function readSingleQuotedScalar(st, nodeIndent) {
      var ch = st.input.charCodeAt(st.position);
      if (ch !== 39) return false;
      st.kind = "scalar";
      st.result = "";
      st.position += 1;
      var captureStart = st.position;
      var captureEnd = st.position;
      while ((ch = st.input.charCodeAt(st.position)) !== 0) {
        if (ch === 39) {
          captureSegment(st, captureStart, st.position, true);
          ch = st.input.charCodeAt(++st.position);
          if (ch !== 39) return true;
          captureStart = st.position;
          st.position += 1;
          captureEnd = st.position;
        } else if (isEol(ch)) {
          captureSegment(st, captureStart, captureEnd, true);
          writeFoldedLines(st, skipSeparationSpace(st, false, nodeIndent));
          captureStart = captureEnd = st.position;
        } else if (st.position === st.lineStart && testDocumentSeparator(st)) {
          fail(st, "unexpected end of the document within a single quoted scalar");
        } else {
          st.position += 1;
          if (!isWhiteSpace(ch)) captureEnd = st.position;
        }
      }
      fail(st, "unexpected end of the stream within a single quoted scalar");
    }

    function readDoubleQuotedScalar(st, nodeIndent) {
      var ch = st.input.charCodeAt(st.position);
      if (ch !== 34) return false;
      st.kind = "scalar";
      st.result = "";
      st.position += 1;
      var captureStart = st.position;
      var captureEnd = st.position;
      while ((ch = st.input.charCodeAt(st.position)) !== 0) {
        if (ch === 34) {
          captureSegment(st, captureStart, st.position, true);
          st.position += 1;
          return true;
        }
        if (ch === 92) {
          captureSegment(st, captureStart, st.position, true);
          ch = st.input.charCodeAt(++st.position);
          var hexLength = escapedHexLen(ch);
          if (isEol(ch)) {
            skipSeparationSpace(st, false, nodeIndent);
          } else if (ch < 256 && SIMPLE_ESCAPES[ch] !== undefined) {
            st.result += SIMPLE_ESCAPES[ch];
            st.position += 1;
          } else if (hexLength > 0) {
            var hexResult = 0;
            for (; hexLength > 0; hexLength -= 1) {
              var digit = fromHexCode(st.input.charCodeAt(++st.position));
              if (digit < 0) fail(st, "expected hexadecimal character");
              hexResult = (hexResult << 4) + digit;
            }
            st.result += codepoint(hexResult);
            st.position += 1;
          } else {
            fail(st, "unknown escape sequence");
          }
          captureStart = captureEnd = st.position;
        } else if (isEol(ch)) {
          captureSegment(st, captureStart, captureEnd, true);
          writeFoldedLines(st, skipSeparationSpace(st, false, nodeIndent));
          captureStart = captureEnd = st.position;
        } else if (st.position === st.lineStart && testDocumentSeparator(st)) {
          fail(st, "unexpected end of the document within a double quoted scalar");
        } else {
          st.position += 1;
          if (!isWhiteSpace(ch)) captureEnd = st.position;
        }
      }
      fail(st, "unexpected end of the stream within a double quoted scalar");
    }

    function readFlowCollection(st, nodeIndent) {
      var readNext = true;
      var tag = st.tag;
      var anchor = st.anchor;
      var terminator, isMapping, result;
      var ch = st.input.charCodeAt(st.position);
      if (ch === 91) {
        terminator = 93;
        isMapping = false;
        result = [];
      } else if (ch === 123) {
        terminator = 125;
        isMapping = true;
        result = {};
      } else {
        return false;
      }
      if (st.anchor !== null) storeAnchor(st, st.anchor, result);
      ch = st.input.charCodeAt(++st.position);
      while (ch !== 0) {
        skipSeparationSpace(st, true, nodeIndent);
        ch = st.input.charCodeAt(st.position);
        if (ch === terminator) {
          st.position += 1;
          st.tag = tag;
          st.anchor = anchor;
          st.kind = isMapping ? "mapping" : "sequence";
          st.result = result;
          return true;
        }
        if (!readNext) fail(st, "missed comma between flow collection entries");
        if (ch === 44) fail(st, "expected the node content, but found ','");
        var keyTag = null;
        var keyNode = null;
        var valueNode = null;
        var isPair = false;
        var isExplicitPair = false;
        if (ch === 63 && isWsOrEol(st.input.charCodeAt(st.position + 1))) {
          isPair = isExplicitPair = true;
          st.position += 1;
          skipSeparationSpace(st, true, nodeIndent);
        }
        var line = st.line;
        composeNode(st, nodeIndent, CONTEXT_FLOW_IN, false, true);
        keyTag = st.tag;
        keyNode = st.result;
        skipSeparationSpace(st, true, nodeIndent);
        ch = st.input.charCodeAt(st.position);
        if ((isExplicitPair || st.line === line) && ch === 58) {
          isPair = true;
          st.position += 1;
          skipSeparationSpace(st, true, nodeIndent);
          composeNode(st, nodeIndent, CONTEXT_FLOW_IN, false, true);
          valueNode = st.result;
        }
        if (isMapping) storeMappingPair(st, result, keyTag, keyNode, valueNode);
        else if (isPair) result.push(storeMappingPair(st, null, keyTag, keyNode, valueNode));
        else result.push(keyNode);
        skipSeparationSpace(st, true, nodeIndent);
        ch = st.input.charCodeAt(st.position);
        if (ch === 44) {
          readNext = true;
          ch = st.input.charCodeAt(++st.position);
        } else {
          readNext = false;
        }
      }
      fail(st, "unexpected end of the stream within a flow collection");
    }

    function readBlockScalar(st, nodeIndent) {
      var folding;
      var chomping = CHOMPING_CLIP;
      var didReadContent = false;
      var detectedIndent = false;
      var textIndent = nodeIndent;
      var emptyLines = 0;
      var atMoreIndented = false;
      var ch = st.input.charCodeAt(st.position);
      if (ch === 124) folding = false;
      else if (ch === 62) folding = true;
      else return false;
      st.kind = "scalar";
      st.result = "";
      while (ch !== 0) {
        ch = st.input.charCodeAt(++st.position);
        if (ch === 43 || ch === 45) {
          if (chomping !== CHOMPING_CLIP) fail(st, "repeat of a chomping mode identifier");
          chomping = ch === 43 ? CHOMPING_KEEP : CHOMPING_STRIP;
        } else {
          var width = fromDecimalCode(ch);
          if (width < 0) break;
          if (width === 0) fail(st, "bad explicit indentation width of a block scalar; it cannot be less than one");
          if (detectedIndent) fail(st, "repeat of an indentation width identifier");
          textIndent = nodeIndent + width - 1;
          detectedIndent = true;
        }
      }
      if (isWhiteSpace(ch)) {
        do { ch = st.input.charCodeAt(++st.position); } while (isWhiteSpace(ch));
        if (ch === 35) {
          do { ch = st.input.charCodeAt(++st.position); } while (!isEol(ch) && ch !== 0);
        }
      }
      while (ch !== 0) {
        readLineBreak(st);
        st.lineIndent = 0;
        ch = st.input.charCodeAt(st.position);
        while ((!detectedIndent || st.lineIndent < textIndent) && ch === 32) {
          st.lineIndent += 1;
          ch = st.input.charCodeAt(++st.position);
        }
        if (!detectedIndent && st.lineIndent > textIndent) textIndent = st.lineIndent;
        if (isEol(ch)) {
          emptyLines += 1;
          continue;
        }
        if (!detectedIndent && textIndent === 0) fail(st, "missing indentation for block scalar");
        if (st.lineIndent < textIndent) {
          if (chomping === CHOMPING_KEEP) st.result += repeat("\n", didReadContent ? 1 + emptyLines : emptyLines);
          else if (chomping === CHOMPING_CLIP && didReadContent) st.result += "\n";
          break;
        }
        if (!folding) {
          st.result += repeat("\n", didReadContent ? 1 + emptyLines : emptyLines);
        } else if (isWhiteSpace(ch)) {
          atMoreIndented = true;
          st.result += repeat("\n", didReadContent ? 1 + emptyLines : emptyLines);
        } else if (atMoreIndented) {
          atMoreIndented = false;
          st.result += repeat("\n", emptyLines + 1);
        } else if (emptyLines === 0) {
          if (didReadContent) st.result += " ";
        } else {
          st.result += repeat("\n", emptyLines);
        }
        didReadContent = true;
        detectedIndent = true;
        emptyLines = 0;
        var captureStart = st.position;
        while (!isEol(ch) && ch !== 0) ch = st.input.charCodeAt(++st.position);
        captureSegment(st, captureStart, st.position, false);
      }
      return true;
    }

    function readBlockSequence(st, nodeIndent) {
      var tag = st.tag;
      var anchor = st.anchor;
      var result = [];
      var detected = false;
      if (st.firstTabInLine !== -1) return false;
      if (st.anchor !== null) storeAnchor(st, st.anchor, result);
      var ch = st.input.charCodeAt(st.position);
      while (ch !== 0) {
        if (st.firstTabInLine !== -1) {
          st.position = st.firstTabInLine;
          fail(st, "tab characters must not be used in indentation");
        }
        if (ch !== 45) break;
        if (!isWsOrEol(st.input.charCodeAt(st.position + 1))) break;
        detected = true;
        st.position += 1;
        if (skipSeparationSpace(st, true, -1) && st.lineIndent <= nodeIndent) {
          result.push(null);
          ch = st.input.charCodeAt(st.position);
          continue;
        }
        var line = st.line;
        composeNode(st, nodeIndent, CONTEXT_BLOCK_IN, false, true);
        result.push(st.result);
        skipSeparationSpace(st, true, -1);
        ch = st.input.charCodeAt(st.position);
        if ((st.line === line || st.lineIndent > nodeIndent) && ch !== 0) fail(st, "bad indentation of a sequence entry");
        else if (st.lineIndent < nodeIndent) break;
      }
      if (!detected) return false;
      st.tag = tag;
      st.anchor = anchor;
      st.kind = "sequence";
      st.result = result;
      return true;
    }

    function readBlockMapping(st, nodeIndent, flowIndent) {
      var tag = st.tag;
      var anchor = st.anchor;
      var result = {};
      var keyTag = null;
      var keyNode = null;
      var valueNode = null;
      var atExplicitKey = false;
      var detected = false;
      var allowCompact = false;
      if (st.firstTabInLine !== -1) return false;
      if (st.anchor !== null) storeAnchor(st, st.anchor, result);
      var ch = st.input.charCodeAt(st.position);
      while (ch !== 0) {
        if (!atExplicitKey && st.firstTabInLine !== -1) {
          st.position = st.firstTabInLine;
          fail(st, "tab characters must not be used in indentation");
        }
        var following = st.input.charCodeAt(st.position + 1);
        var line = st.line;
        if ((ch === 63 || ch === 58) && isWsOrEol(following)) {
          if (ch === 63) {
            if (atExplicitKey) {
              storeMappingPair(st, result, keyTag, keyNode, null);
              keyTag = keyNode = valueNode = null;
            }
            detected = true;
            atExplicitKey = true;
            allowCompact = true;
          } else if (atExplicitKey) {
            atExplicitKey = false;
            allowCompact = true;
          } else {
            fail(st, "incomplete explicit mapping pair; a key node is missed; or followed by a non-tabulated empty line");
          }
          st.position += 1;
          ch = following;
        } else {
          if (!composeNode(st, flowIndent, CONTEXT_FLOW_OUT, false, true)) break;
          if (st.line !== line) {
            if (detected) fail(st, "can not read a block mapping entry; a multiline key may not be an implicit key");
            st.tag = tag;
            st.anchor = anchor;
            return true;
          }
          ch = st.input.charCodeAt(st.position);
          while (isWhiteSpace(ch)) ch = st.input.charCodeAt(++st.position);
          if (ch !== 58) {
            if (detected) fail(st, "can not read an implicit mapping pair; a colon is missed");
            st.tag = tag;
            st.anchor = anchor;
            return true;
          }
          ch = st.input.charCodeAt(++st.position);
          if (!isWsOrEol(ch)) fail(st, "a whitespace character is expected after the key-value separator within a block mapping");
          if (atExplicitKey) {
            storeMappingPair(st, result, keyTag, keyNode, null);
            keyTag = keyNode = valueNode = null;
          }
          detected = true;
          atExplicitKey = false;
          allowCompact = false;
          keyTag = st.tag;
          keyNode = st.result;
        }
        if (st.line === line || st.lineIndent > nodeIndent) {
          if (composeNode(st, nodeIndent, CONTEXT_BLOCK_OUT, true, allowCompact)) {
            if (atExplicitKey) keyNode = st.result;
            else valueNode = st.result;
          }
          if (!atExplicitKey) {
            storeMappingPair(st, result, keyTag, keyNode, valueNode);
            keyTag = keyNode = valueNode = null;
          }
          skipSeparationSpace(st, true, -1);
          ch = st.input.charCodeAt(st.position);
        }
        if ((st.line === line || st.lineIndent > nodeIndent) && ch !== 0) fail(st, "bad indentation of a mapping entry");
        else if (st.lineIndent < nodeIndent) break;
      }
      if (atExplicitKey) storeMappingPair(st, result, keyTag, keyNode, null);
      if (!detected) return false;
      st.tag = tag;
      st.anchor = anchor;
      st.kind = "mapping";
      st.result = result;
      return true;
    }

    // `!!merge` is not in the JSON schema, so the `<<` merge branch js-yaml has here cannot fire
    // and is left out; what remains is the key stringification and the duplicate-key rejection
    // that makes `@{ shape: rect, shape: rounded }` an error rather than a last-one-wins.
    function storeMappingPair(st, result, keyTag, keyNode, valueNode) {
      if (Array.isArray(keyNode)) {
        keyNode = keyNode.slice();
        for (var i = 0; i < keyNode.length; i += 1) {
          if (Array.isArray(keyNode[i])) fail(st, "nested arrays are not supported inside keys");
          if (typeof keyNode[i] === "object" && keyNode[i] !== null) keyNode[i] = "[object Object]";
        }
      }
      if (typeof keyNode === "object" && keyNode !== null && !Array.isArray(keyNode)) keyNode = "[object Object]";
      keyNode = String(keyNode);
      if (result === null) result = {};
      if (hasOwn.call(result, keyNode)) fail(st, "duplicated mapping key");
      if (keyNode === "__proto__") {
        Object.defineProperty(result, keyNode, { configurable: true, enumerable: true, writable: true, value: valueNode });
      } else {
        result[keyNode] = valueNode;
      }
      return result;
    }

    function readTagProperty(st) {
      var isVerbatim = false;
      var isNamed = false;
      var tagHandle;
      var tagName;
      var ch = st.input.charCodeAt(st.position);
      if (ch !== 33) return false;
      if (st.tag !== null) fail(st, "duplication of a tag property");
      ch = st.input.charCodeAt(++st.position);
      if (ch === 60) {
        isVerbatim = true;
        ch = st.input.charCodeAt(++st.position);
      } else if (ch === 33) {
        isNamed = true;
        tagHandle = "!!";
        ch = st.input.charCodeAt(++st.position);
      } else {
        tagHandle = "!";
      }
      var start = st.position;
      if (isVerbatim) {
        do { ch = st.input.charCodeAt(++st.position); } while (ch !== 0 && ch !== 62);
        if (st.position >= st.length) fail(st, "unexpected end of the stream within a verbatim tag");
        tagName = st.input.slice(start, st.position);
        st.position += 1;
      } else {
        while (ch !== 0 && !isWsOrEol(ch)) {
          if (ch === 33) {
            if (isNamed) fail(st, "tag suffix cannot contain exclamation marks");
            tagHandle = st.input.slice(start - 1, st.position + 1);
            if (!PATTERN_TAG_HANDLE.test(tagHandle)) fail(st, "named tag handle cannot contain such characters");
            isNamed = true;
            start = st.position + 1;
          }
          ch = st.input.charCodeAt(++st.position);
        }
        tagName = st.input.slice(start, st.position);
        if (PATTERN_FLOW_INDICATORS.test(tagName)) fail(st, "tag suffix cannot contain flow indicator characters");
      }
      if (tagName && !PATTERN_TAG_URI.test(tagName)) fail(st, "tag name cannot contain such characters: " + tagName);
      try {
        tagName = decodeURIComponent(tagName);
      } catch (err) {
        fail(st, "tag name is malformed: " + tagName);
      }
      if (isVerbatim) st.tag = tagName;
      else if (hasOwn.call(st.tagMap, tagHandle)) st.tag = st.tagMap[tagHandle] + tagName;
      else if (tagHandle === "!") st.tag = "!" + tagName;
      else if (tagHandle === "!!") st.tag = "tag:yaml.org,2002:" + tagName;
      else fail(st, 'undeclared tag handle "' + tagHandle + '"');
      return true;
    }

    function readAnchorProperty(st) {
      var ch = st.input.charCodeAt(st.position);
      if (ch !== 38) return false;
      if (st.anchor !== null) fail(st, "duplication of an anchor property");
      ch = st.input.charCodeAt(++st.position);
      var start = st.position;
      while (ch !== 0 && !isWsOrEol(ch) && !isFlowIndicator(ch)) ch = st.input.charCodeAt(++st.position);
      if (st.position === start) fail(st, "name of an anchor node must contain at least one character");
      st.anchor = st.input.slice(start, st.position);
      return true;
    }

    function readAlias(st) {
      var ch = st.input.charCodeAt(st.position);
      if (ch !== 42) return false;
      ch = st.input.charCodeAt(++st.position);
      var start = st.position;
      while (ch !== 0 && !isWsOrEol(ch) && !isFlowIndicator(ch)) ch = st.input.charCodeAt(++st.position);
      if (st.position === start) fail(st, "name of an alias node must contain at least one character");
      var alias = st.input.slice(start, st.position);
      if (!hasOwn.call(st.anchorMap, alias)) fail(st, 'unidentified alias "' + alias + '"');
      st.result = st.anchorMap[alias];
      skipSeparationSpace(st, true, -1);
      return true;
    }

    // A tag or anchor written on the line before a block mapping leaves the mapping unreadable by
    // the main path, which has already decided block collections are not allowed; js-yaml rewinds
    // to where the property started and tries again. The anchor map is copied rather than
    // journalled the way js-yaml journals it, because rolling the copy back has the same effect for
    // a speculative parse this shallow.
    function tryReadBlockMappingFromProperty(st, propertyStart, nodeIndent, flowIndent) {
      var fallback = snapshot(st);
      var anchors = Object.assign(Object.create(null), st.anchorMap);
      restore(st, propertyStart);
      st.tag = null;
      st.anchor = null;
      st.kind = null;
      st.result = null;
      if (readBlockMapping(st, nodeIndent, flowIndent) && st.kind === "mapping") return true;
      st.anchorMap = anchors;
      restore(st, fallback);
      return false;
    }

    function composeNode(st, parentIndent, nodeContext, allowToSeek, allowCompact) {
      var indentStatus = 1;
      var atNewLine = false;
      var hasContent = false;
      var propertyStart = null;
      var type;
      var ch;
      if (st.depth >= 100) fail(st, "nesting exceeded maxDepth (100)");
      st.depth += 1;
      st.tag = null;
      st.anchor = null;
      st.kind = null;
      st.result = null;
      var allowBlockStyles = nodeContext === CONTEXT_BLOCK_OUT || nodeContext === CONTEXT_BLOCK_IN;
      var allowBlockScalars = allowBlockStyles;
      var allowBlockCollections = allowBlockStyles;
      if (allowToSeek && skipSeparationSpace(st, true, -1)) {
        atNewLine = true;
        indentStatus = st.lineIndent > parentIndent ? 1 : st.lineIndent === parentIndent ? 0 : -1;
      }
      if (indentStatus === 1) {
        while (true) {
          ch = st.input.charCodeAt(st.position);
          var propertyState = snapshot(st);
          if (atNewLine && ((ch === 33 && st.tag !== null) || (ch === 38 && st.anchor !== null))) break;
          if (!readTagProperty(st) && !readAnchorProperty(st)) break;
          if (propertyStart === null) propertyStart = propertyState;
          if (skipSeparationSpace(st, true, -1)) {
            atNewLine = true;
            allowBlockCollections = allowBlockStyles;
            indentStatus = st.lineIndent > parentIndent ? 1 : st.lineIndent === parentIndent ? 0 : -1;
          } else {
            allowBlockCollections = false;
          }
        }
      }
      if (allowBlockCollections) allowBlockCollections = atNewLine || allowCompact;
      if (indentStatus === 1 || nodeContext === CONTEXT_BLOCK_OUT) {
        var flowIndent = (nodeContext === CONTEXT_FLOW_IN || nodeContext === CONTEXT_FLOW_OUT) ? parentIndent : parentIndent + 1;
        var blockIndent = st.position - st.lineStart;
        if (indentStatus === 1) {
          if ((allowBlockCollections && (readBlockSequence(st, blockIndent) || readBlockMapping(st, blockIndent, flowIndent))) ||
            readFlowCollection(st, flowIndent)) {
            hasContent = true;
          } else {
            ch = st.input.charCodeAt(st.position);
            if (propertyStart !== null && allowBlockStyles && !allowBlockCollections && ch !== 124 && ch !== 62 &&
              tryReadBlockMappingFromProperty(st, propertyStart, propertyStart.position - propertyStart.lineStart, flowIndent)) {
              hasContent = true;
            } else if ((allowBlockScalars && readBlockScalar(st, flowIndent)) ||
              readSingleQuotedScalar(st, flowIndent) || readDoubleQuotedScalar(st, flowIndent)) {
              hasContent = true;
            } else if (readAlias(st)) {
              hasContent = true;
              if (st.tag !== null || st.anchor !== null) fail(st, "alias node should not have any properties");
            } else if (readPlainScalar(st, flowIndent, nodeContext === CONTEXT_FLOW_IN)) {
              hasContent = true;
              if (st.tag === null) st.tag = "?";
            }
            if (st.anchor !== null) storeAnchor(st, st.anchor, st.result);
          }
        } else if (indentStatus === 0) {
          hasContent = allowBlockCollections && readBlockSequence(st, blockIndent);
        }
      }
      if (st.tag === null) {
        if (st.anchor !== null) storeAnchor(st, st.anchor, st.result);
      } else if (st.tag === "?") {
        if (st.result !== null && st.kind !== "scalar") {
          fail(st, 'unacceptable node kind for !<?> tag; it should be "scalar", not "' + st.kind + '"');
        }
        for (var i = 0; i < IMPLICIT_TYPES.length; i += 1) {
          type = IMPLICIT_TYPES[i];
          if (type.resolve(st.result)) {
            st.result = type.construct(st.result);
            st.tag = type.tag;
            if (st.anchor !== null) storeAnchor(st, st.anchor, st.result);
            break;
          }
        }
      } else if (st.tag !== "!") {
        type = TYPE_MAP[st.kind || "fallback"][st.tag];
        if (!type) fail(st, "unknown tag !<" + st.tag + ">");
        if (st.result !== null && type.kind !== st.kind) {
          fail(st, "unacceptable node kind for !<" + st.tag + '> tag; it should be "' + type.kind + '", not "' + st.kind + '"');
        }
        if (!type.resolve(st.result, st.tag)) fail(st, "cannot resolve a node with !<" + st.tag + "> explicit tag");
        st.result = type.construct(st.result, st.tag);
        if (st.anchor !== null) storeAnchor(st, st.anchor, st.result);
      }
      st.depth -= 1;
      return st.tag !== null || st.anchor !== null || hasContent;
    }

    function readDocument(st) {
      var hasDirectives = false;
      var ch;
      st.tagMap = Object.create(null);
      st.anchorMap = Object.create(null);
      while ((ch = st.input.charCodeAt(st.position)) !== 0) {
        skipSeparationSpace(st, true, -1);
        ch = st.input.charCodeAt(st.position);
        if (st.lineIndent > 0 || ch !== 37) break;
        hasDirectives = true;
        ch = st.input.charCodeAt(++st.position);
        var start = st.position;
        while (ch !== 0 && !isWsOrEol(ch)) ch = st.input.charCodeAt(++st.position);
        var name = st.input.slice(start, st.position);
        var args = [];
        if (name.length < 1) fail(st, "directive name must not be less than one character in length");
        while (ch !== 0) {
          while (isWhiteSpace(ch)) ch = st.input.charCodeAt(++st.position);
          if (ch === 35) {
            do { ch = st.input.charCodeAt(++st.position); } while (ch !== 0 && !isEol(ch));
            break;
          }
          if (isEol(ch)) break;
          start = st.position;
          while (ch !== 0 && !isWsOrEol(ch)) ch = st.input.charCodeAt(++st.position);
          args.push(st.input.slice(start, st.position));
        }
        if (ch !== 0) readLineBreak(st);
        // %YAML only picks a version and warns, and an unknown directive only warns, so %TAG is the
        // one whose effect survives: it rewrites the handles readTagProperty resolves against.
        if (name === "TAG") {
          if (args.length !== 2) fail(st, "TAG directive accepts exactly two arguments");
          if (!PATTERN_TAG_HANDLE.test(args[0])) fail(st, "ill-formed tag handle (first argument) of the TAG directive");
          if (hasOwn.call(st.tagMap, args[0])) fail(st, 'there is a previously declared suffix for "' + args[0] + '" tag handle');
          if (!PATTERN_TAG_URI.test(args[1])) fail(st, "ill-formed tag prefix (second argument) of the TAG directive");
          try {
            st.tagMap[args[0]] = decodeURIComponent(args[1]);
          } catch (err) {
            fail(st, "tag prefix is malformed: " + args[1]);
          }
        } else if (name === "YAML") {
          if (args.length !== 1) fail(st, "YAML directive accepts exactly one argument");
          var version = /^([0-9]+)\.([0-9]+)$/.exec(args[0]);
          if (version === null) fail(st, "ill-formed argument of the YAML directive");
          if (parseInt(version[1], 10) !== 1) fail(st, "unacceptable YAML version of the document");
        }
      }
      skipSeparationSpace(st, true, -1);
      if (st.lineIndent === 0 && st.input.charCodeAt(st.position) === 45 &&
        st.input.charCodeAt(st.position + 1) === 45 && st.input.charCodeAt(st.position + 2) === 45) {
        st.position += 3;
        skipSeparationSpace(st, true, -1);
      } else if (hasDirectives) {
        fail(st, "directives end mark is expected");
      }
      composeNode(st, st.lineIndent - 1, CONTEXT_BLOCK_OUT, false, true);
      skipSeparationSpace(st, true, -1);
      st.documents.push(st.result);
      if (st.position === st.lineStart && testDocumentSeparator(st)) {
        if (st.input.charCodeAt(st.position) === 46) {
          st.position += 3;
          skipSeparationSpace(st, true, -1);
        }
        return;
      }
      if (st.position < st.length - 1) fail(st, "end of the stream or a document separator is expected");
    }

    function load(input) {
      if (input.length !== 0) {
        var last = input.charCodeAt(input.length - 1);
        if (last !== 10 && last !== 13) input += "\n";
        if (input.charCodeAt(0) === 0xfeff) input = input.slice(1);
      }
      var st = newState(input);
      if (input.indexOf("\0") !== -1) fail(st, "null byte is not allowed in input");
      // The sentinel is what every `ch !== 0` loop above stops on, and `length` deliberately still
      // measures the input without it.
      st.input += "\0";
      while (st.input.charCodeAt(st.position) === 32) {
        st.lineIndent += 1;
        st.position += 1;
      }
      while (st.position < st.length - 1) readDocument(st);
      if (st.documents.length === 0) return undefined;
      if (st.documents.length > 1) throw new Error("expected a single document in the stream, but found more");
      return st.documents[0];
    }

    // The two wrappings are mermaid's, not ours: a run with no newline is braced so it reads as a
    // flow mapping, and the multi-line form gets the trailing newline a block document needs
    // (flowDb.reference.ts:141-150). Feeding the loader the same string mermaid feeds js-yaml is
    // what keeps `@{shape:Rect}` reading as one null-valued key here too, rather than needing a
    // rule of its own.
    return function loadShapeData(metadata) {
      return load(metadata.indexOf("\n") === -1 ? "{\n" + metadata + "\n}" : metadata + "\n");
    };
  })();

  // Every name mermaid's `isValidShape` accepts: the shortName, aliases and internalAliases of its
  // 53 shape definitions plus the 20 undocumented ones. Held as data rather than derived because
  // there is nothing to derive it from here, and because `@{ shape: rect_left_inv_arrow }` has to
  // reach the lowercase check rather than the unknown-shape one (flow-node-data.spec.js:207).
  var SHAPE_NAMES = ("anchor bang block_arrow bolt bow-rect bow-tie-rectangle brace brace-l brace-r braces browser " +
    "bucket card choice circ circle classBox cloud collapsedGroup collate com-link comment composite console " +
    "cross-circ crossed-circle curv-trap curved-trapezoid cyl cylinder das data-store database datastore db " +
    "dbl-circ decision defaultMindmapNode delay diam diamond directory disk display div-proc div-rect " +
    "divided-process divided-rectangle doc docs document documents double-circle doublecircle erBox event extract " +
    "f-circ filled-circle flag flip-tri flipped-triangle folder fork forkJoin fr-circ fr-rect framed-circle " +
    "framed-rectangle h-cyl half-rounded-rectangle hex hexagon horizontal-cylinder hourglass icon iconCircle " +
    "iconRounded iconSquare imageSquare in-out internal-storage inv-trapezoid inv_trapezoid join junction " +
    "kanbanItem labelRect lean-l lean-left lean-r lean-right lean_left lean_right lightning-bolt lin-cyl lin-doc " +
    "lin-proc lin-rect lined-cylinder lined-document lined-process lined-rectangle loop-limit manual manual-file " +
    "manual-input mindmapCircle notch-pent notch-rect notched-pentagon notched-rectangle note odd out-in " +
    "paper-tape person pill prepare priority proc process processes procs question rect rectWithTitle " +
    "rect_left_inv_arrow rectangle requirementBox rounded roundedRect shaded-process sl-rect sloped-rectangle " +
    "sm-circ small-circle squareRect st-doc st-rect stacked-document stacked-rectangle stadium start state " +
    "stateEnd stateStart stop stored-data subproc subprocess subroutine summary tag-doc tag-proc tag-rect " +
    "tagged-document tagged-process tagged-rectangle terminal text trap-b trap-t trapezoid trapezoid-bottom " +
    "trapezoid-top tri triangle win-pane window-pane").split(" ");

  var VALID_SHAPES = new Map();
  for (var si = 0; si < SHAPE_NAMES.length; si += 1) VALID_SHAPES.set(SHAPE_NAMES[si], true);

  // ===========================================================================
  // The data model.
  //
  // Deliberately mermaid's own shape rather than something of our own with an adapter in front:
  // the 268 vendored tests read this object directly, so making it the native model is what keeps
  // the two from drifting. Anything the renderer needs that mermaid does not have goes in a
  // separate structure, never as an extra field here.
  // ===========================================================================

  var MERMAID_DOM_ID_PREFIX = "flowchart-";

  function edgeId(from, to, counter, id) {
    return id ? id : "L_" + from + "_" + to + "_" + counter;
  }

  function FlowDB() {
    this.vertexCounter = 0;
    this.secCount = -1;
    this.posCrossRef = [];
    this.direction = undefined;

    // jison reaches every action through `yy.<name>`, so a spy installed on the instance has to be
    // what the parser finds. flow-interactions.spec.js:20 replaces `setClickEvent` on the db and
    // asserts the call, which only works because the parser looks the method up on the object each
    // time -- these bindings are mermaid's own way of guaranteeing that (flowDb.reference.ts:62-76).
    this.addVertex = this.addVertex.bind(this);
    this.firstGraph = this.firstGraph.bind(this);
    this.setDirection = this.setDirection.bind(this);
    this.addSubGraph = this.addSubGraph.bind(this);
    this.addLink = this.addLink.bind(this);
    this.setLink = this.setLink.bind(this);
    this.updateLink = this.updateLink.bind(this);
    this.addClass = this.addClass.bind(this);
    this.setClass = this.setClass.bind(this);
    this.destructLink = this.destructLink.bind(this);
    this.setClickEvent = this.setClickEvent.bind(this);
    this.setTooltip = this.setTooltip.bind(this);
    this.updateLinkInterpolate = this.updateLinkInterpolate.bind(this);
    this.setClickFun = this.setClickFun.bind(this);
    this.bindFunctions = this.bindFunctions.bind(this);

    // The lexer calls `yy.lex.firstGraph()` from inside the GRAPH rules
    // (flow.jison.reference:116-119), so the flag has to be reachable through a nested object and
    // not just as a method.
    this.lex = { firstGraph: this.firstGraph.bind(this) };

    this.clear();
    this.setGen("gen-2");
  }

  FlowDB.prototype.clear = function (ver) {
    this.vertices = new Map();
    this.classes = new Map();
    // A plain array, because `linkStyle default` hangs `defaultStyle` and `defaultInterpolate` off
    // it as expandos and flow-lines.spec.js:21 reads them straight off what getEdges() returns.
    this.edges = [];
    this.funs = [];
    this.diagramId = "";
    this.subGraphs = [];
    this.subGraphLookup = new Map();
    this.subCount = 0;
    this.tooltips = new Map();
    this.firstGraphFlag = true;
    this.version = ver === undefined ? "gen-2" : ver;
    this.config = CONFIG;
    this.accTitle = "";
    this.accDescription = "";
    this.diagramTitle = "";
  };

  FlowDB.prototype.setGen = function (ver) {
    this.version = ver || "gen-2";
  };

  FlowDB.prototype.sanitizeNodeLabelType = function (labelType) {
    // Anything unrecognised -- `undefined` included -- becomes markdown, which is what gives
    // `A@{ label: "x" }` a markdown label while `A["x"]` keeps 'string'
    // (flowDb.reference.ts:90-100).
    if (labelType === "markdown" || labelType === "string" || labelType === "text") return labelType;
    return "markdown";
  };

  FlowDB.prototype.setDiagramId = function (svgElementId) {
    this.diagramId = svgElementId;
  };

  FlowDB.prototype.lookUpDomId = function (id) {
    var values = Array.from(this.vertices.values());
    for (var i = 0; i < values.length; i += 1) {
      if (values[i].id === id) {
        return this.diagramId ? this.diagramId + "-" + values[i].domId : values[i].domId;
      }
    }
    return this.diagramId ? this.diagramId + "-" + id : id;
  };

  FlowDB.prototype.addVertex = function (id, textObj, type, style, classes, dir, props, metadata) {
    if (!id || id.trim().length === 0) return;
    if (props === undefined) props = {};

    var doc;
    if (metadata !== undefined) doc = loadShapeData(metadata);

    // The three lookups are ordered, and the order is the whole behaviour: `sub1@{ view: collapsed }`
    // has to reach the subgraph and `e1@{ curve: basis }` the edge, or both grow a phantom vertex
    // and the node counts in flow-node-data.spec.js:393 and flow-lines.spec.js:38 go wrong
    // (flowDb.reference.ts:152-177).
    var subGraph = this.subGraphLookup.get(id);
    if (subGraph && doc) {
      subGraph.metadata = Object.assign({}, subGraph.metadata, doc);
      return;
    }

    var edge = this.findEdgeById(id);
    if (edge) {
      if (doc) {
        if (doc.animate !== undefined) edge.animate = doc.animate;
        if (doc.animation !== undefined) edge.animation = doc.animation;
        if (doc.curve !== undefined) edge.interpolate = doc.curve;
      }
      return;
    }

    var vertex = this.vertices.get(id);
    if (vertex === undefined) {
      if (textObj === undefined && type === undefined && style !== undefined && style !== null) {
        log.warn(
          'Style applied to unknown node "' + id + '". This may indicate a typo. The node will be created automatically.'
        );
      }
      vertex = {
        id: id,
        labelType: "text",
        domId: MERMAID_DOM_ID_PREFIX + id + "-" + this.vertexCounter,
        styles: [],
        classes: []
      };
      this.vertices.set(id, vertex);
    }
    // Counted on every call, re-declarations included, so domIds match mermaid's.
    this.vertexCounter += 1;

    if (textObj !== undefined) {
      var txt = sanitizeText(textObj.text.trim());
      vertex.labelType = textObj.type;
      if (txt.startsWith('"') && txt.endsWith('"')) txt = txt.substring(1, txt.length - 1);
      vertex.text = txt;
    } else if (vertex.text === undefined) {
      // `=== undefined`, not falsy: `A(( ))` leaves an empty label that a style statement must not
      // overwrite with the id (flow-style.spec.js:88).
      vertex.text = id;
    }
    if (type !== undefined) vertex.type = type;
    if (style !== undefined && style !== null) {
      for (var s = 0; s < style.length; s += 1) vertex.styles.push(style[s]);
    }
    if (classes !== undefined && classes !== null) {
      for (var c = 0; c < classes.length; c += 1) vertex.classes.push(classes[c]);
    }
    if (dir !== undefined) vertex.dir = dir;
    if (vertex.props === undefined) vertex.props = props;
    else if (props !== undefined) Object.assign(vertex.props, props);

    if (doc === undefined) return;

    if (doc.shape) {
      // Lowercase first: `rect_left_inv_arrow` is a real internal shape, so a validity-first check
      // would hand it the wrong message (flow-node-data.spec.js:207-214).
      if (doc.shape !== doc.shape.toLowerCase() || doc.shape.indexOf("_") !== -1) {
        throw new Error("No such shape: " + doc.shape + ". Shape names should be lowercase.");
      } else if (!VALID_SHAPES.get(doc.shape)) {
        throw new Error("No such shape: " + doc.shape + ".");
      }
      vertex.type = doc.shape;
    }
    if (doc.label) {
      // Assigned raw. The YAML loader has already dropped the quotes and folded the multi-line
      // forms, so re-running the label pipeline would corrupt them.
      vertex.text = doc.label;
      vertex.labelType = this.sanitizeNodeLabelType(doc.labelType);
    }
    if (doc.icon) {
      vertex.icon = doc.icon;
      if (!(doc.label && doc.label.trim()) && vertex.text === id) vertex.text = "";
    }
    if (doc.form) vertex.form = doc.form;
    if (doc.pos) vertex.pos = doc.pos;
    if (doc.img) {
      vertex.img = doc.img;
      if (!(doc.label && doc.label.trim()) && vertex.text === id) vertex.text = "";
    }
    if (doc.constraint) vertex.constraint = doc.constraint;
    if (doc.w) vertex.assetWidth = Number(doc.w);
    if (doc.h) vertex.assetHeight = Number(doc.h);
  };

  FlowDB.prototype.findEdgeById = function (id) {
    for (var i = 0; i < this.edges.length; i += 1) {
      if (this.edges[i].id === id) return this.edges[i];
    }
    return undefined;
  };

  FlowDB.prototype.addSingleLink = function (_start, _end, type, id) {
    var edge = {
      start: _start,
      end: _end,
      type: undefined,
      text: "",
      labelType: "text",
      classes: [],
      isUserDefinedId: false,
      // Snapshotted here rather than resolved on read, which is why `linkStyle default interpolate`
      // only reaches edges declared after it (flow-lines.spec.js:56-70).
      interpolate: this.edges.defaultInterpolate
    };
    var linkTextObj = type.text;
    if (linkTextObj !== undefined) {
      edge.text = sanitizeText(linkTextObj.text.trim());
      if (edge.text.startsWith('"') && edge.text.endsWith('"')) {
        edge.text = edge.text.substring(1, edge.text.length - 1);
      }
      edge.labelType = this.sanitizeNodeLabelType(linkTextObj.type);
    }
    if (type !== undefined) {
      edge.type = type.type;
      edge.stroke = type.stroke;
      edge.length = type.length > 10 ? 10 : type.length;
    }

    if (id && !this.findEdgeById(id)) {
      edge.id = id;
      edge.isUserDefinedId = true;
    } else {
      var existing = 0;
      for (var i = 0; i < this.edges.length; i += 1) {
        if (this.edges[i].start === edge.start && this.edges[i].end === edge.end) existing += 1;
      }
      // Index 1 is skipped by design: the second edge of a pair is `L_A_B_2`.
      edge.id = edgeId(edge.start, edge.end, existing === 0 ? 0 : existing + 1);
    }

    if (this.edges.length < (this.config.maxEdges === undefined ? 500 : this.config.maxEdges)) {
      this.edges.push(edge);
    } else {
      throw new Error(
        "Edge limit exceeded. " + this.edges.length + " edges found, but the limit is " + this.config.maxEdges + ".\n\n" +
        "Initialize mermaid with maxEdges set to a higher number to allow more edges.\n" +
        "You cannot set this config via configuration inside the diagram as it is a secure config.\n" +
        "You have to call mermaid.initialize."
      );
    }
  };

  FlowDB.prototype.addLink = function (_start, _end, linkData) {
    var id;
    if (linkData !== null && typeof linkData === "object" && typeof linkData.id === "string") {
      id = linkData.id.replace("@", "");
    }
    // Start-major, end-minor, and the user id goes to exactly one pair -- last start crossed with
    // first end -- so `A & B e1@--> C & D` puts `e1` on the third edge
    // (flowDb.reference.ts:360-371, flow-node-data.spec.js:352).
    for (var i = 0; i < _start.length; i += 1) {
      for (var j = 0; j < _end.length; j += 1) {
        var isLastStart = _start[i] === _start[_start.length - 1];
        var isFirstEnd = _end[j] === _end[0];
        this.addSingleLink(_start[i], _end[j], linkData, isLastStart && isFirstEnd ? id : undefined);
      }
    }
  };

  FlowDB.prototype.updateLinkInterpolate = function (positions, interpolate) {
    for (var i = 0; i < positions.length; i += 1) {
      if (positions[i] === "default") this.edges.defaultInterpolate = interpolate;
      else this.edges[positions[i]].interpolate = interpolate;
    }
  };

  FlowDB.prototype.updateLink = function (positions, style) {
    for (var i = 0; i < positions.length; i += 1) {
      var pos = positions[i];
      if (typeof pos === "number" && pos >= this.edges.length) {
        throw new Error(
          "The index " + pos + " for linkStyle is out of bounds. Valid indices for linkStyle are between 0 and " +
          (this.edges.length - 1) + ". (Help: Ensure that the index is within the range of existing edges.)"
        );
      }
      if (pos === "default") {
        this.edges.defaultStyle = style;
      } else {
        this.edges[pos].style = style;
        var have = this.edges[pos].style;
        var hasFill = false;
        for (var s = 0; s < have.length; s += 1) if (have[s] && have[s].startsWith("fill")) hasFill = true;
        if (have.length > 0 && !hasFill) have.push("fill:none");
      }
    }
  };

  FlowDB.prototype.addClass = function (ids, _style) {
    // The §§§ round trip protects an escaped `\,` from the comma-to-semicolon swap that lets a
    // single classDef carry several declarations (flowDb.reference.ts:416-421).
    var style = _style
      .join()
      .replace(/\\,/g, "§§§")
      .replace(/,/g, ";")
      .replace(/§§§/g, ",")
      .split(";");
    var parts = ids.split(",");
    for (var i = 0; i < parts.length; i += 1) {
      var id = parts[i];
      var classNode = this.classes.get(id);
      if (classNode === undefined) {
        classNode = { id: id, styles: [], textStyles: [] };
        this.classes.set(id, classNode);
      }
      for (var s = 0; s < style.length; s += 1) {
        // Not trimmed: `background:  #bbb` keeps both spaces (flow-style.spec.js:144).
        if (/color/.exec(style[s])) classNode.textStyles.push(style[s].replace("fill", "bgFill"));
        classNode.styles.push(style[s]);
      }
    }
  };

  FlowDB.prototype.setDirection = function (dir) {
    // Substring tests, in this order, because the DIR token still carries the `\s*` its lexer rule
    // matched -- `graph >` arrives as `' >'` (flow.jison.reference:135).
    this.direction = dir.trim();
    if (/.*</.exec(this.direction)) this.direction = "RL";
    if (/.*\^/.exec(this.direction)) this.direction = "BT";
    if (/.*>/.exec(this.direction)) this.direction = "LR";
    if (/.*v/.exec(this.direction)) this.direction = "TB";
    if (this.direction === "TD") this.direction = "TB";
  };

  FlowDB.prototype.setClass = function (ids, className) {
    var parts = ids.split(",");
    for (var i = 0; i < parts.length; i += 1) {
      // All three lookups run: an id can name a vertex, an edge and a subgraph at once.
      var vertex = this.vertices.get(parts[i]);
      if (vertex) vertex.classes.push(className);
      var edge = this.findEdgeById(parts[i]);
      if (edge) edge.classes.push(className);
      var subGraph = this.subGraphLookup.get(parts[i]);
      if (subGraph) subGraph.classes.push(className);
    }
  };

  FlowDB.prototype.setTooltip = function (ids, tooltip) {
    if (tooltip === undefined) return;
    tooltip = sanitizeText(tooltip);
    var parts = ids.split(",");
    for (var i = 0; i < parts.length; i += 1) {
      this.tooltips.set(this.version === "gen-1" ? this.lookUpDomId(parts[i]) : parts[i], tooltip);
    }
  };

  FlowDB.prototype.setClickFun = function (id, functionName, functionArgs) {
    if (CONFIG.securityLevel !== "loose") return;
    if (functionName === undefined) return;
    var argList = [];
    if (typeof functionArgs === "string") {
      argList = functionArgs.split(/,(?=(?:(?:[^"]*"){2})*[^"]*$)/);
      for (var i = 0; i < argList.length; i += 1) {
        var item = argList[i].trim();
        if (item.startsWith('"') && item.endsWith('"')) item = item.substr(1, item.length - 2);
        argList[i] = item;
      }
    }
    if (argList.length === 0) argList.push(id);
    var vertex = this.vertices.get(id);
    if (vertex) {
      // mermaid queues a DOM listener here. Nothing in the parse path may touch a DOM -- that is
      // what lets this model run under node -- so the flag is all this records, and attaching the
      // handler is left to whoever owns the rendered element.
      vertex.haveCallback = true;
      vertex.callbackArgs = argList;
    }
  };

  FlowDB.prototype.setLink = function (ids, linkStr, target) {
    var parts = ids.split(",");
    for (var i = 0; i < parts.length; i += 1) {
      var vertex = this.vertices.get(parts[i]);
      if (vertex !== undefined) {
        vertex.link = formatUrl(linkStr);
        vertex.linkTarget = target;
      }
    }
    this.setClass(ids, "clickable");
  };

  FlowDB.prototype.getTooltip = function (id) {
    return this.tooltips.get(id);
  };

  FlowDB.prototype.setClickEvent = function (ids, functionName, functionArgs) {
    var parts = ids.split(",");
    for (var i = 0; i < parts.length; i += 1) this.setClickFun(parts[i], functionName, functionArgs);
    this.setClass(ids, "clickable");
  };

  // The one entry point in the model that expects a DOM, and the only reason `funs` exists: a host
  // that renders the diagram queues its post-render work here and calls this once.
  FlowDB.prototype.bindFunctions = function (element) {
    for (var i = 0; i < this.funs.length; i += 1) this.funs[i](element);
  };

  FlowDB.prototype.getDirection = function () {
    return this.direction === undefined ? undefined : this.direction.trim();
  };
  FlowDB.prototype.getVertices = function () { return this.vertices; };
  FlowDB.prototype.getEdges = function () { return this.edges; };
  FlowDB.prototype.getClasses = function () { return this.classes; };
  FlowDB.prototype.getSubGraphs = function () { return this.subGraphs; };

  FlowDB.prototype.defaultStyle = function () {
    return "fill:#ffa;stroke: #f66; stroke-width: 3px; stroke-dasharray: 5, 5;fill:#ffa;stroke: #666;";
  };

  FlowDB.prototype.firstGraph = function () {
    // A one-shot mutator, not a predicate: only the first graph keyword opens the `dir` state, so a
    // later `graph` inside a label cannot swallow the next token as a direction.
    if (this.firstGraphFlag) {
      this.firstGraphFlag = false;
      return true;
    }
    return false;
  };

  FlowDB.prototype.addSubGraph = function (_id, list, _title) {
    var id = _id && _id.text !== undefined ? _id.text.trim() : undefined;
    var title = _title && _title.text !== undefined ? _title.text : undefined;
    // Object identity, not value equality. The id-less production hands the same object twice
    // (flow.jison.reference:382-383), which is the only thing separating `subgraph Some Title` from
    // `subgraph some-id[Some Title]`.
    if (_id === _title && _title && /\s/.exec(_title.text)) id = undefined;

    var flat = [];
    for (var f = 0; f < list.length; f += 1) {
      if (Array.isArray(list[f])) flat = flat.concat(list[f]);
      else flat.push(list[f]);
    }

    var dir;
    var seen = new Map();
    var nodeList = [];
    for (var i = 0; i < flat.length; i += 1) {
      var item = flat[i];
      if (item && item.stmt === "dir") {
        // Last one wins (flow-direction.spec.js:47-62).
        dir = item.value;
        continue;
      }
      if (typeof item !== "string" || item.trim() === "") continue;
      if (seen.get(item)) continue;
      seen.set(item, true);
      nodeList.push(item);
    }

    if (this.version === "gen-1") {
      for (var g = 0; g < nodeList.length; g += 1) nodeList[g] = this.lookUpDomId(nodeList[g]);
    }

    if (id === undefined) id = "subGraph" + this.subCount;
    title = sanitizeText(title || "");
    this.subCount = this.subCount + 1;

    var subGraph = {
      id: id,
      nodes: nodeList,
      title: title.trim(),
      classes: [],
      dir: dir,
      labelType: this.sanitizeNodeLabelType(_title ? _title.type : undefined)
    };

    // Run against the subgraphs registered so far, before this one is pushed, so a node belongs to
    // the first subgraph that claimed it -- the innermost, since it closed first.
    subGraph.nodes = this.makeUniq(subGraph, this.subGraphs).nodes;
    this.subGraphs.push(subGraph);
    this.subGraphLookup.set(id, subGraph);
    return id;
  };

  FlowDB.prototype.exists = function (allSgs, _id) {
    for (var i = 0; i < allSgs.length; i += 1) {
      if (allSgs[i].nodes.indexOf(_id) !== -1) return true;
    }
    return false;
  };

  FlowDB.prototype.makeUniq = function (sg, allSubgraphs) {
    var res = [];
    for (var i = 0; i < sg.nodes.length; i += 1) {
      if (!this.exists(allSubgraphs, sg.nodes[i])) res.push(sg.nodes[i]);
    }
    return { nodes: res };
  };

  FlowDB.prototype.getPosForId = function (id) {
    for (var i = 0; i < this.subGraphs.length; i += 1) {
      if (this.subGraphs[i].id === id) return i;
    }
    return -1;
  };

  FlowDB.prototype.indexNodes2 = function (id, pos) {
    var nodes = this.subGraphs[pos].nodes;
    this.secCount = this.secCount + 1;
    if (this.secCount > 2000) return { result: false, count: 0 };
    this.posCrossRef[this.secCount] = pos;
    if (this.subGraphs[pos].id === id) return { result: true, count: 0 };

    var count = 0;
    var posCount = 1;
    while (count < nodes.length) {
      var childPos = this.getPosForId(nodes[count]);
      if (childPos >= 0) {
        var res = this.indexNodes2(id, childPos);
        if (res.result) return { result: true, count: posCount + res.count };
        posCount = posCount + res.count;
      }
      count = count + 1;
    }
    return { result: false, count: posCount };
  };

  FlowDB.prototype.getDepthFirstPos = function (pos) { return this.posCrossRef[pos]; };

  FlowDB.prototype.indexNodes = function () {
    this.secCount = -1;
    if (this.subGraphs.length > 0) this.indexNodes2("none", this.subGraphs.length - 1);
  };

  FlowDB.prototype.setAccTitle = function (txt) { this.accTitle = sanitizeText(txt).replace(/^\s+/g, ""); };
  FlowDB.prototype.getAccTitle = function () { return this.accTitle; };
  FlowDB.prototype.setAccDescription = function (txt) {
    // The per-line strip is what flattens the indentation of an `accDescr { ... }` block
    // (flow.spec.js:206).
    this.accDescription = sanitizeText(txt).replace(/\n\s+/g, "\n");
  };
  FlowDB.prototype.getAccDescription = function () { return this.accDescription; };
  FlowDB.prototype.setDiagramTitle = function (txt) { this.diagramTitle = sanitizeText(txt); };
  FlowDB.prototype.getDiagramTitle = function () { return this.diagramTitle; };
  FlowDB.prototype.defaultConfig = function () { return { padding: 8, useMaxWidth: true }; };

  // ---------------------------------------------------------------------------
  // Link shapes.
  // ---------------------------------------------------------------------------

  FlowDB.prototype.countChar = function (char, str) {
    var count = 0;
    for (var i = 0; i < str.length; i += 1) if (str.charAt(i) === char) count += 1;
    return count;
  };

  FlowDB.prototype.destructStartLink = function (_str) {
    var str = _str.trim();
    var type = "arrow_open";
    var head = str.charAt(0);
    if (head === "<") { type = "arrow_point"; str = str.slice(1); }
    else if (head === "x") { type = "arrow_cross"; str = str.slice(1); }
    else if (head === "o") { type = "arrow_circle"; str = str.slice(1); }

    var stroke = "normal";
    if (str.indexOf("=") !== -1) stroke = "thick";
    if (str.indexOf(".") !== -1) stroke = "dotted";
    return { type: type, stroke: stroke };
  };

  FlowDB.prototype.destructEndLink = function (_str) {
    var str = _str.trim();
    var line = str.slice(0, -1);
    var type = "arrow_open";

    var tail = str.slice(-1);
    if (tail === "x") {
      type = "arrow_cross";
      if (str.startsWith("x")) { type = "double_" + type; line = line.slice(1); }
    } else if (tail === ">") {
      type = "arrow_point";
      if (str.startsWith("<")) { type = "double_" + type; line = line.slice(1); }
    } else if (tail === "o") {
      type = "arrow_circle";
      if (str.startsWith("o")) { type = "double_" + type; line = line.slice(1); }
    }

    var stroke = "normal";
    var length = line.length - 1;
    if (line.startsWith("=")) stroke = "thick";
    if (line.startsWith("~")) stroke = "invisible";
    // A dotted link measures its dots, not its characters: `-...->` is length 3, not 4.
    var dots = this.countChar(".", line);
    if (dots) { stroke = "dotted"; length = dots; }

    return { type: type, stroke: stroke, length: length };
  };

  FlowDB.prototype.destructLink = function (_str, _startStr) {
    var info = this.destructEndLink(_str);
    if (!_startStr) return info;

    var startInfo = this.destructStartLink(_startStr);
    // A mismatched pair is reported, not thrown: `x-- text -->` becomes an INVALID edge with no
    // length at all (flowDb.reference.ts:921-932).
    if (startInfo.stroke !== info.stroke) return { type: "INVALID", stroke: "INVALID" };
    if (startInfo.type === "arrow_open") {
      startInfo.type = info.type;
    } else {
      if (startInfo.type !== info.type) return { type: "INVALID", stroke: "INVALID" };
      startInfo.type = "double_" + startInfo.type;
    }
    if (startInfo.type === "double_arrow") startInfo.type = "double_arrow_point";
    startInfo.length = info.length;
    return startInfo;
  };

  // ---------------------------------------------------------------------------
  // The layout-facing projection of the model.
  // ---------------------------------------------------------------------------

  FlowDB.prototype.getTypeFromVertex = function (vertex) {
    if (vertex.img) return "imageSquare";
    if (vertex.icon) {
      if (vertex.form === "circle") return "iconCircle";
      if (vertex.form === "square") return "iconSquare";
      if (vertex.form === "rounded") return "iconRounded";
      return "icon";
    }
    // Only three of the sixteen names the grammar writes are remapped; the rest pass through, which
    // is why `A{...}` reports `diamond` and not mermaid's modern `diam` short name.
    if (vertex.type === "square" || vertex.type === undefined) return "squareRect";
    if (vertex.type === "round") return "roundedRect";
    if (vertex.type === "ellipse") return "ellipse";
    return vertex.type;
  };

  FlowDB.prototype.getCompiledStyles = function (classDefs) {
    var compiled = [];
    for (var i = 0; i < classDefs.length; i += 1) {
      var cssClass = this.classes.get(classDefs[i]);
      if (!cssClass) continue;
      if (cssClass.styles) compiled = compiled.concat(cssClass.styles);
      if (cssClass.textStyles) compiled = compiled.concat(cssClass.textStyles);
    }
    return compiled.map(function (s) { return s.trim(); });
  };

  FlowDB.prototype.destructEdgeType = function (type) {
    var arrowTypeStart = "none";
    var arrowTypeEnd = "arrow_point";
    if (type === "arrow_point" || type === "arrow_circle" || type === "arrow_cross") {
      arrowTypeEnd = type;
    } else if (type === "double_arrow_point" || type === "double_arrow_circle" || type === "double_arrow_cross") {
      arrowTypeStart = type.replace("double_", "");
      arrowTypeEnd = arrowTypeStart;
    }
    return { arrowTypeStart: arrowTypeStart, arrowTypeEnd: arrowTypeEnd };
  };

  FlowDB.prototype.addNodeFromVertex = function (vertex, nodes, parentDB, subGraphDB, config, look) {
    var existing;
    for (var i = 0; i < nodes.length; i += 1) if (nodes[i].id === vertex.id) existing = nodes[i];
    if (existing) {
      // An id that names both a vertex and a subgraph lands here: the container node is already in
      // the list, so only its styling is folded in.
      existing.cssStyles = vertex.styles;
      existing.cssCompiledStyles = this.getCompiledStyles(vertex.classes);
      existing.cssClasses = vertex.classes.join(" ");
      return;
    }
    var isGroup = subGraphDB.get(vertex.id) === true;
    var node = {
      id: vertex.id,
      label: vertex.text,
      labelType: vertex.labelType,
      labelStyle: "",
      parentId: parentDB.get(vertex.id),
      padding: 8,
      cssStyles: vertex.styles,
      cssCompiledStyles: this.getCompiledStyles(["default", "node"].concat(vertex.classes)),
      cssClasses: "default " + vertex.classes.join(" "),
      dir: vertex.dir,
      domId: vertex.domId,
      look: look,
      link: vertex.link,
      linkTarget: vertex.linkTarget,
      tooltip: this.getTooltip(vertex.id),
      icon: vertex.icon,
      pos: vertex.pos,
      img: vertex.img,
      assetWidth: vertex.assetWidth,
      assetHeight: vertex.assetHeight,
      constraint: vertex.constraint,
      isGroup: isGroup,
      shape: isGroup ? "rect" : this.getTypeFromVertex(vertex)
    };
    nodes.push(node);
  };

  FlowDB.prototype.getData = function () {
    var self = this;
    var config = this.config;
    var nodes = [];
    var edges = [];
    var subGraphs = this.getSubGraphs();
    var parentDB = new Map();
    var subGraphDB = new Map();
    var i;
    var j;

    // A subgraph carrying `@{ view: collapsed }` is drawn as one compact node; its descendants are
    // hidden and every edge that crossed the boundary is redirected onto it. The containment map is
    // built first so the outermost collapsed ancestor can be found regardless of declaration order.
    var subGraphParent = new Map();
    for (i = 0; i < subGraphs.length; i += 1) {
      for (j = 0; j < subGraphs[i].nodes.length; j += 1) {
        if (this.subGraphLookup.has(subGraphs[i].nodes[j])) {
          subGraphParent.set(subGraphs[i].nodes[j], subGraphs[i].id);
        }
      }
    }
    var isCollapsed = function (sgId) {
      var sg = self.subGraphLookup.get(sgId);
      return !!(sg && sg.metadata && sg.metadata.view === "collapsed");
    };
    var outermostCollapsed = function (sgId) {
      var result;
      var seen = new Map();
      var current = sgId;
      while (current !== undefined && !seen.has(current)) {
        seen.set(current, true);
        if (isCollapsed(current)) result = current;
        current = subGraphParent.get(current);
      }
      return result;
    };

    var hiddenIds = new Map();
    var collapsedAncestor = new Map();
    for (i = 0; i < subGraphs.length; i += 1) {
      var ancestor = outermostCollapsed(subGraphs[i].id);
      if (ancestor === undefined) continue;
      if (subGraphs[i].id !== ancestor) {
        hiddenIds.set(subGraphs[i].id, true);
        collapsedAncestor.set(subGraphs[i].id, ancestor);
      }
      for (j = 0; j < subGraphs[i].nodes.length; j += 1) {
        if (subGraphs[i].nodes[j] === ancestor) continue;
        hiddenIds.set(subGraphs[i].nodes[j], true);
        collapsedAncestor.set(subGraphs[i].nodes[j], ancestor);
      }
    }

    for (i = subGraphs.length - 1; i >= 0; i -= 1) {
      if (hiddenIds.has(subGraphs[i].id)) continue;
      if (subGraphs[i].nodes.length > 0) subGraphDB.set(subGraphs[i].id, true);
      for (j = 0; j < subGraphs[i].nodes.length; j += 1) parentDB.set(subGraphs[i].nodes[j], subGraphs[i].id);
    }

    // Subgraphs first and in reverse declaration order, then the vertices in Map insertion order.
    // Every positional `nodes[n]` assertion in flow-node-data.spec.js reads that sequence.
    for (i = subGraphs.length - 1; i >= 0; i -= 1) {
      var sg = subGraphs[i];
      if (hiddenIds.has(sg.id)) continue;
      var collapsed = !!(sg.metadata && sg.metadata.view === "collapsed");
      nodes.push({
        id: sg.id,
        label: sg.title,
        labelStyle: "",
        labelType: sg.labelType,
        parentId: parentDB.get(sg.id),
        padding: 8,
        cssCompiledStyles: this.getCompiledStyles(sg.classes),
        cssClasses: sg.classes.join(" "),
        shape: collapsed ? "collapsedGroup" : "rect",
        dir: sg.dir,
        isGroup: !collapsed,
        look: config.look
      });
    }

    this.getVertices().forEach(function (vertex) {
      if (hiddenIds.has(vertex.id)) return;
      self.addNodeFromVertex(vertex, nodes, parentDB, subGraphDB, config, config.look || "classic");
    });

    var raw = this.getEdges();
    for (i = 0; i < raw.length; i += 1) {
      var rawEdge = raw[i];
      var arrows = this.destructEdgeType(rawEdge.type);
      var styles = (raw.defaultStyle || []).slice();

      var start = collapsedAncestor.has(rawEdge.start) ? collapsedAncestor.get(rawEdge.start) : rawEdge.start;
      var end = collapsedAncestor.has(rawEdge.end) ? collapsedAncestor.get(rawEdge.end) : rawEdge.end;
      // Dropped only when the collapse itself made the two ends meet; a genuine self-loop survives.
      if (start === end && (collapsedAncestor.has(rawEdge.start) || collapsedAncestor.has(rawEdge.end))) continue;

      if (rawEdge.style) styles = styles.concat(rawEdge.style);
      var invisible = rawEdge.stroke === "invisible" || rawEdge.type === "arrow_open";
      edges.push({
        id: edgeId(start, end, i, rawEdge.id),
        isUserDefinedId: rawEdge.isUserDefinedId,
        start: start,
        end: end,
        type: rawEdge.type === undefined ? "normal" : rawEdge.type,
        label: rawEdge.text,
        labelType: rawEdge.labelType,
        labelpos: "c",
        thickness: rawEdge.stroke,
        minlen: rawEdge.length,
        classes: rawEdge.stroke === "invisible" ? "" : "edge-thickness-normal edge-pattern-solid flowchart-link",
        arrowTypeStart: invisible ? "none" : arrows.arrowTypeStart,
        arrowTypeEnd: invisible ? "none" : arrows.arrowTypeEnd,
        arrowheadStyle: "fill: #333",
        cssCompiledStyles: this.getCompiledStyles(rawEdge.classes),
        labelStyle: styles,
        style: styles,
        pattern: rawEdge.stroke,
        look: config.look,
        animate: rawEdge.animate,
        animation: rawEdge.animation,
        curve: rawEdge.interpolate || raw.defaultInterpolate || config.curve
      });
    }

    return { nodes: nodes, edges: edges, other: {}, config: config };
  };

  // The UNICODE_TEXT character class, copied verbatim from flow.jison.reference:211-271, where it
  // is written as an alternation of single-character classes. Substituting a broad \p{L} would be
  // wrong twice over: the published ranges deliberately omit some code points, and because the rule
  // sits after NODE_STRING it only ever fires on characters NODE_STRING rejected -- one at a time,
  // re-welded by the idString and text concatenations.
  var UNICODE_RANGES =
    "\u00AA\u00B5\u00BA\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE" +
    "\u0370-\u0374\u0376\u0377\u037A-\u037D\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5" +
    "\u03F7-\u0481\u048A-\u0527\u0531-\u0556\u0559\u0561-\u0587\u05D0-\u05EA\u05F0-\u05F2" +
    "\u0620-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u06FC\u06FF\u0710" +
    "\u0712-\u072F\u074D-\u07A5\u07B1\u07CA-\u07EA\u07F4\u07F5\u07FA\u0800-\u0815\u081A\u0824\u0828" +
    "\u0840-\u0858\u08A0\u08A2-\u08AC\u0904-\u0939\u093D\u0950\u0958-\u0961\u0971-\u0977\u0979-\u097F" +
    "\u0985-\u098C\u098F\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BD\u09CE\u09DC\u09DD" +
    "\u09DF-\u09E1\u09F0\u09F1\u0A05-\u0A0A\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32\u0A33\u0A35" +
    "\u0A36\u0A38\u0A39\u0A59-\u0A5C\u0A5E\u0A72-\u0A74\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8" +
    "\u0AAA-\u0AB0\u0AB2\u0AB3\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0\u0AE1\u0B05-\u0B0C\u0B0F\u0B10" +
    "\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3D\u0B5C\u0B5D\u0B5F-\u0B61\u0B71\u0B83" +
    "\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA" +
    "\u0BAE-\u0BB9\u0BD0\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C33\u0C35-\u0C39\u0C3D\u0C58" +
    "\u0C59\u0C60\u0C61\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBD\u0CDE" +
    "\u0CE0\u0CE1\u0CF1\u0CF2\u0D05-\u0D0C\u0D0E-\u0D10\u0D12-\u0D3A\u0D3D\u0D4E\u0D60\u0D61" +
    "\u0D7A-\u0D7F\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0E01-\u0E30\u0E32\u0E33" +
    "\u0E40-\u0E46\u0E81\u0E82\u0E84\u0E87\u0E88\u0E8A\u0E8D\u0E94-\u0E97\u0E99-\u0E9F\u0EA1-\u0EA3" +
    "\u0EA5\u0EA7\u0EAA\u0EAB\u0EAD-\u0EB0\u0EB2\u0EB3\u0EBD\u0EC0-\u0EC4\u0EC6\u0EDC-\u0EDF\u0F00" +
    "\u0F40-\u0F47\u0F49-\u0F6C\u0F88-\u0F8C\u1000-\u102A\u103F\u1050-\u1055\u105A-\u105D\u1061\u1065" +
    "\u1066\u106E-\u1070\u1075-\u1081\u108E\u10A0-\u10C5\u10C7\u10CD\u10D0-\u10FA\u10FC-\u1248" +
    "\u124A-\u124D\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288\u128A-\u128D\u1290-\u12B0" +
    "\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5\u12C8-\u12D6\u12D8-\u1310\u1312-\u1315" +
    "\u1318-\u135A\u1380-\u138F\u13A0-\u13F4\u1401-\u166C\u166F-\u167F\u1681-\u169A\u16A0-\u16EA" +
    "\u1700-\u170C\u170E-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176C\u176E-\u1770\u1780-\u17B3" +
    "\u17D7\u17DC\u1820-\u1877\u1880-\u18A8\u18AA\u18B0-\u18F5\u1900-\u191C\u1950-\u196D\u1970-\u1974" +
    "\u1980-\u19AB\u19C1-\u19C7\u1A00-\u1A16\u1A20-\u1A54\u1AA7\u1B05-\u1B33\u1B45-\u1B4B" +
    "\u1B83-\u1BA0\u1BAE\u1BAF\u1BBA-\u1BE5\u1C00-\u1C23\u1C4D-\u1C4F\u1C5A-\u1C7D\u1CE9-\u1CEC" +
    "\u1CEE-\u1CF1\u1CF5\u1CF6\u1D00-\u1DBF\u1E00-\u1F15\u1F18-\u1F1D\u1F20-\u1F45\u1F48-\u1F4D" +
    "\u1F50-\u1F57\u1F59\u1F5B\u1F5D\u1F5F-\u1F7D\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4" +
    "\u1FC6-\u1FCC\u1FD0-\u1FD3\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u2071\u207F" +
    "\u2090-\u209C\u2102\u2107\u210A-\u2113\u2115\u2119-\u211D\u2124\u2126\u2128\u212A-\u212D" +
    "\u212F-\u2139\u213C-\u213F\u2145-\u2149\u214E\u2183\u2184\u2C00-\u2C2E\u2C30-\u2C5E\u2C60-\u2CE4" +
    "\u2CEB-\u2CEE\u2CF2\u2CF3\u2D00-\u2D25\u2D27\u2D2D\u2D30-\u2D67\u2D6F\u2D80-\u2D96\u2DA0-\u2DA6" +
    "\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE\u2DD0-\u2DD6\u2DD8-\u2DDE" +
    "\u2E2F\u3005\u3006\u3031-\u3035\u303B\u303C\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF" +
    "\u3105-\u312D\u3131-\u318E\u31A0-\u31BA\u31F0-\u31FF\u3400-\u4DB5\u4E00-\u9FCC\uA000-\uA48C" +
    "\uA4D0-\uA4FD\uA500-\uA60C\uA610-\uA61F\uA62A\uA62B\uA640-\uA66E\uA67F-\uA697\uA6A0-\uA6E5" +
    "\uA717-\uA71F\uA722-\uA788\uA78B-\uA78E\uA790-\uA793\uA7A0-\uA7AA\uA7F8-\uA801\uA803-\uA805" +
    "\uA807-\uA80A\uA80C-\uA822\uA840-\uA873\uA882-\uA8B3\uA8F2-\uA8F7\uA8FB\uA90A-\uA925" +
    "\uA930-\uA946\uA960-\uA97C\uA984-\uA9B2\uA9CF\uAA00-\uAA28\uAA40-\uAA42\uAA44-\uAA4B" +
    "\uAA60-\uAA76\uAA7A\uAA80-\uAAAF\uAAB1\uAAB5\uAAB6\uAAB9-\uAABD\uAAC0\uAAC2\uAADB-\uAADD" +
    "\uAAE0-\uAAEA\uAAF2-\uAAF4\uAB01-\uAB06\uAB09-\uAB0E\uAB11-\uAB16\uAB20-\uAB26\uAB28-\uAB2E" +
    "\uABC0-\uABE2\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uF900-\uFA6D\uFA70-\uFAD9\uFB00-\uFB06" +
    "\uFB13-\uFB17\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C\uFB3E\uFB40\uFB41\uFB43\uFB44" +
    "\uFB46-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC" +
    "\uFF21-\uFF3A\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7\uFFDA-\uFFDC";

  // ===========================================================================
  // The tokenizer.
  //
  // jison-lex declares no `%options flex` anywhere in flow.jison.reference, so its scan loop breaks
  // out on the FIRST rule that matches at the current position rather than the longest one --
  // `if (tempMatch && (!match || tempMatch[0].length > match[0].length)) { ... else if
  // (!this.options.flex) { break; } }`. Declaration order from line 31 to line 290 is therefore
  // semantics rather than housekeeping, and the table below is in that order with every rule's line
  // cited. The case that settles it is `graph TD;style.node;`, which flow-singlenode.spec.js:328
  // requires to throw: under longest match `style.node` is one NODE_STRING and the diagram parses.
  //
  // All twenty start conditions are declared `%x` (lines 9-28), so an unprefixed rule is live only
  // in INITIAL and a `<*>` rule is live everywhere. That exclusivity is the entire mechanism by
  // which a node label may contain `end`, `graph` or `subgraph`; it is not an optimisation.
  //
  // `begin` and `pushState` are the same push in jison-lex, and `popState` refuses to pop the last
  // element -- which is what lets the LINK rule at line 156 pop unconditionally even when the arrow
  // was a plain `A-->B` read in INITIAL.
  // ===========================================================================

  var RULES = [];
  var INITIAL_ONLY = null;
  var ANY_STATE = "*";

  // Every pattern here goes through jison-lex's keyword-boundary rewrite before it becomes a
  // regex, because the generated lexer mermaid actually runs has been through it: dumping
  // `diagram.parser.parser.lexer.rules` from mermaid 11.17.2 shows `/^(?:graph\b)/`,
  // `/^(?:class\b)/`, `/^(?:_self\b)/` and twenty more boundaries that appear nowhere in
  // flow.jison.reference. Without them `graphQL` lexes as GRAPH followed by NODE_STRING `QL`, and
  // nothing downstream can glue the two back together -- idStringToken (flow.jison.reference:597)
  // admits NODE_STRING and DEFAULT but no other keyword, so mermaid's own grammar would reject its
  // own lexer's output. The boundary is what stops the keyword rule from ever firing there.
  //
  // Doing it in R rather than by hand-editing the twenty-three affected patterns keeps the table a
  // transcription of the .jison source, and means a rule copied across later cannot quietly miss it.
  function R(states, source, action) {
    RULES.push({
      states: states,
      re: new RegExp(easyKeywordBoundary(typeof source === "string" ? source : source.source), "y"),
      act: action
    });
  }

  // jison appends the boundary to any rule whose pattern ends in a word character, and the escape
  // list is the exception that matters: rule `(\r?\n)*\s*\n` and rule `\s` both end in a letter
  // that belongs to a backslash escape, and mermaid's generated table leaves both unbounded. An
  // odd-backslash-count test would cover those two as well, but it would also decline to bound a
  // pattern ending in `\d` or `\w`, which jison does bound; matching jison's literal escape list
  // keeps the two in step for patterns this grammar does not happen to contain yet. Verified by
  // applying this to all 121 rule sources below and comparing the resulting \b set against the
  // live mermaid rule table: identical, rule index for rule index.
  function easyKeywordBoundary(source) {
    if (!/[0-9A-Za-z_]$/.test(source)) return source;
    if (/\\(?:r|f|n|t|v|s|b|c[A-Z]|x[0-9A-F]{2}|u[a-fA-F0-9]{4}|[0-7]{1,3})$/.test(source)) return source;
    return source + "\\b";
  }

  function tok(name) {
    return function () { return name; };
  }

  function pushText(state, name) {
    return function (lx) { lx.begin(state); return name; };
  }

  function popText(name) {
    return function (lx) { lx.popState(); return name; };
  }

  function graphKeyword(lx) {
    if (lx.yy.lex.firstGraph()) lx.begin("dir");
    return "GRAPH";
  }

  function dirToken(lx) {
    lx.popState();
    return "DIR";
  }

  function linkToken(lx) {
    lx.popState();
    return "LINK";
  }

  function startLink(state) {
    return function (lx) { lx.begin(state); return "START_LINK"; };
  }

  R(INITIAL_ONLY, /accTitle\s*:\s*/, function (lx) { lx.begin("acc_title"); return "acc_title"; });
  // `(?!\n|;|#)*` in the grammar is a zero-width assertion under a star, so it always matches empty
  // and the rule is `[^\n]*` in effect.
  R(["acc_title"], /[^\n]*/, function (lx) { lx.popState(); return "acc_title_value"; });
  R(INITIAL_ONLY, /accDescr\s*:\s*/, function (lx) { lx.begin("acc_descr"); return "acc_descr"; });
  R(["acc_descr"], /[^\n]*/, function (lx) { lx.popState(); return "acc_descr_value"; });
  R(INITIAL_ONLY, /accDescr\s*\{\s*/, function (lx) { lx.begin("acc_descr_multiline"); });
  R(["acc_descr_multiline"], /[}]/, function (lx) { lx.popState(); });
  R(["acc_descr_multiline"], /[^}]*/, tok("acc_descr_multiline_value"));

  // `@{` blanks its own text and the closing `}` emits nothing at all, so what the grammar
  // concatenates is exactly the YAML between them -- quotes included, because both quote rules
  // re-emit the character they matched (flow.jison.reference:41-64).
  R(INITIAL_ONLY, /@\{/, function (lx) { lx.begin("shapeData"); lx.yytext = ""; return "SHAPE_DATA"; });
  R(["shapeData"], /["]/, function (lx) { lx.begin("shapeDataStr"); return "SHAPE_DATA"; });
  R(["shapeDataStr"], /["]/, function (lx) { lx.popState(); return "SHAPE_DATA"; });
  R(["shapeDataStr"], /[^"]+/, function (lx) {
    // Per quoted span, not over the assembled string: folding newlines later would also mangle the
    // ones separating YAML keys (flow-node-data.spec.js:252).
    lx.yytext = lx.yytext.replace(/\n\s*/g, "<br/>");
    return "SHAPE_DATA";
  });
  // The caret is an ordinary member of this class, not a negation -- keep the set byte-identical.
  R(["shapeData"], /[^}^"]+/, tok("SHAPE_DATA"));
  R(["shapeData"], /\}/, function (lx) { lx.popState(); });

  R(INITIAL_ONLY, /call[\s]+/, function (lx) { lx.begin("callbackname"); });
  R(["callbackname"], /\([\s]*\)/, function (lx) { lx.popState(); });
  R(["callbackname"], /\(/, function (lx) { lx.popState(); lx.begin("callbackargs"); });
  R(["callbackname"], /[^(]*/, tok("CALLBACKNAME"));
  R(["callbackargs"], /\)/, function (lx) { lx.popState(); });
  // Declared above the `<*>` quote rules, which is why `call cb("a", b)` keeps its quotes and
  // arrives as one raw CALLBACKARGS string (flow-interactions.spec.js:70).
  R(["callbackargs"], /[^)]*/, tok("CALLBACKARGS"));

  R(["md_string"], /[^`"]+/, tok("MD_STR"));
  R(["md_string"], /[`]["]/, function (lx) { lx.popState(); });
  R(ANY_STATE, /["][`]/, function (lx) { lx.begin("md_string"); });
  R(["string"], /[^"]+/, tok("STR"));
  R(["string"], /["]/, function (lx) { lx.popState(); });
  R(ANY_STATE, /["]/, function (lx) { lx.begin("string"); });

  // R gives each of these a trailing `\b`, so a keyword only wins when the character after it is not
  // a word character. `classifier`, `styles` and `interpolateZ` therefore fall through to NODE_STRING
  // below, which is greedy across `-`, `.`, `_` and `/` and takes them whole. `graph.node` still
  // splits, because `.` is not a word character and the boundary holds there --
  // flow-singlenode.spec.js:328 requires that split.
  R(INITIAL_ONLY, /style/, tok("STYLE"));
  R(INITIAL_ONLY, /default/, tok("DEFAULT"));
  R(INITIAL_ONLY, /linkStyle/, tok("LINKSTYLE"));
  R(INITIAL_ONLY, /interpolate/, tok("INTERPOLATE"));
  // Before `class`, or first-match reads `classDef` as CLASS followed by an id `Def`.
  R(INITIAL_ONLY, /classDef/, tok("CLASSDEF"));
  R(INITIAL_ONLY, /class/, tok("CLASS"));
  // `href`, `click` and `call` demand trailing whitespace, which is why `href.node` is a legal id
  // while `style.node` is not (flow-singlenode.spec.js:335).
  R(INITIAL_ONLY, /href[\s]/, tok("HREF"));
  R(INITIAL_ONLY, /click[\s]+/, function (lx) { lx.begin("click"); });
  R(["click"], /[\s\n]/, function (lx) { lx.popState(); });
  R(["click"], /[^\s\n]*/, tok("CLICK"));

  R(INITIAL_ONLY, /flowchart-elk/, graphKeyword);
  R(INITIAL_ONLY, /swimlane-beta/, graphKeyword);
  R(INITIAL_ONLY, /graph/, graphKeyword);
  R(INITIAL_ONLY, /flowchart/, graphKeyword);
  R(INITIAL_ONLY, /subgraph/, tok("subgraph"));
  // `end` is the one keyword whose boundary is written in the grammar rather than added by R, and
  // the trailing `\s*` swallows the newline after it -- which is why the subgraph production has no
  // separator of its own.
  R(INITIAL_ONLY, /end\b\s*/, tok("end"));
  R(INITIAL_ONLY, /_self/, tok("LINK_TARGET"));
  R(INITIAL_ONLY, /_blank/, tok("LINK_TARGET"));
  R(INITIAL_ONLY, /_parent/, tok("LINK_TARGET"));
  R(INITIAL_ONLY, /_top/, tok("LINK_TARGET"));

  R(["dir"], /(\r?\n)*\s*\n/, function (lx) { lx.popState(); return "NODIR"; });
  // The `\s*` is kept in the token text on purpose: setDirection does the trimming and the glyph
  // translation itself.
  R(["dir"], /\s*LR/, dirToken);
  R(["dir"], /\s*RL/, dirToken);
  R(["dir"], /\s*TB/, dirToken);
  R(["dir"], /\s*BT/, dirToken);
  R(["dir"], /\s*TD/, dirToken);
  R(["dir"], /\s*BR/, dirToken);
  R(["dir"], /\s*</, dirToken);
  R(["dir"], /\s*>/, dirToken);
  R(["dir"], /\s*\^/, dirToken);
  R(["dir"], /\s*v/, dirToken);

  // `direction` is not a keyword: the leading `.*` swallows the whole line from here to its end,
  // indentation included, which is how an indented `direction TB` inside a subgraph parses without
  // producing a single SPACE token.
  R(INITIAL_ONLY, /.*direction\s+TB[^\n]*/, tok("direction_tb"));
  R(INITIAL_ONLY, /.*direction\s+BT[^\n]*/, tok("direction_bt"));
  R(INITIAL_ONLY, /.*direction\s+RL[^\n]*/, tok("direction_rl"));
  R(INITIAL_ONLY, /.*direction\s+LR[^\n]*/, tok("direction_lr"));
  R(INITIAL_ONLY, /.*direction\s+TD[^\n]*/, tok("direction_td"));

  // The negative lookahead is the only thing separating an edge id from node shape data: `A e1@-->B`
  // is a LINK_ID, `D@{ shape: rounded }` is not (flow-edges.spec.js:120-129).
  R(INITIAL_ONLY, /[^\s"]+@(?=[^{"])/, tok("LINK_ID"));
  R(INITIAL_ONLY, /[0-9]+/, tok("NUM"));
  R(INITIAL_ONLY, /#/, tok("BRKT"));
  // Before COLON, or `:::` is three COLONs and `:::exClass` stops being a class separator.
  R(INITIAL_ONLY, /:::/, tok("STYLE_SEPARATOR"));
  R(INITIAL_ONLY, /:/, tok("COLON"));
  R(INITIAL_ONLY, /&/, tok("AMP"));
  R(INITIAL_ONLY, /;/, tok("SEMI"));
  R(INITIAL_ONLY, /,/, tok("COMMA"));
  R(INITIAL_ONLY, /\*/, tok("MULT"));

  // Each complete arrow is declared BEFORE its two-character stub, so `A-->B` is one LINK while
  // `A-- t -->B` fails the LINK pattern -- `[-xo>]` cannot match a space -- and only then falls to
  // START_LINK. The `[xo<]?` prefix is part of the arrow, not a node id: ` x--x ` is one token.
  R(["INITIAL", "edgeText"], /\s*[xo<]?--+[-xo>]\s*/, linkToken);
  R(INITIAL_ONLY, /\s*[xo<]?--\s*/, startLink("edgeText"));
  // Edge text is scanned one character at a time, the opposite policy from node text. Because this
  // rule is declared above every `<*>` bracket rule, `[`, `(`, `{` and `|` survive literally inside
  // an edge label; only `"` escapes, its rule being higher still.
  R(["edgeText"], /[^-]|-(?!-)/, tok("EDGE_TEXT"));

  R(["INITIAL", "thickEdgeText"], /\s*[xo<]?==+[=xo>]\s*/, linkToken);
  R(INITIAL_ONLY, /\s*[xo<]?==\s*/, startLink("thickEdgeText"));
  R(["thickEdgeText"], /[^=]|=(?!=)/, tok("EDGE_TEXT"));

  R(["INITIAL", "dottedEdgeText"], /\s*[xo<]?-?\.+-[xo>]?\s*/, linkToken);
  R(INITIAL_ONLY, /\s*[xo<]?-\.\s*/, startLink("dottedEdgeText"));
  R(["dottedEdgeText"], /[^.]|\.(?!-)/, tok("EDGE_TEXT"));

  // An invisible link is the one edge that may appear inside a text state without ending it: it
  // carries no label of its own, so there is nothing for a pop to return from.
  R(ANY_STATE, /\s*~~[~]+\s*/, tok("LINK"));

  R(["ellipseText"], /[-\/)][)]/, popText("-)"));
  // `(` is excluded here, so `X(- My Text (` cannot be closed and reaches EOF as a parse error
  // rather than looping (flow-text.spec.js:538).
  R(["ellipseText"], /[^()\[\]{}]|-!\)+/, tok("TEXT"));
  R(ANY_STATE, /\(-/, pushText("ellipseText", "(-"));

  // Openers are `<*>` while closers are `<text>`-only, and both groups run longest-first. That an
  // opener is live inside an already-open text is what makes `A((x))` a circle: the second `(`
  // pushes a SECOND text state and the two `)` pop them in turn.
  R(["text"], /\]\)/, popText("STADIUMEND"));
  R(ANY_STATE, /\(\[/, pushText("text", "STADIUMSTART"));
  R(["text"], /\]\]/, popText("SUBROUTINEEND"));
  R(ANY_STATE, /\[\[/, pushText("text", "SUBROUTINESTART"));
  // The one `[`-family opener that does NOT enter text: the props body is read in INITIAL and only
  // the `|` before the label pushes text (flow-text.spec.js:361).
  R(INITIAL_ONLY, /\[\|/, tok("VERTEX_WITH_PROPS_START"));
  R(INITIAL_ONLY, />/, pushText("text", "TAGEND"));
  R(["text"], /\)\]/, popText("CYLINDEREND"));
  R(ANY_STATE, /\[\(/, pushText("text", "CYLINDERSTART"));
  R(["text"], /\)\)\)/, popText("DOUBLECIRCLEEND"));
  R(ANY_STATE, /\(\(\(/, pushText("text", "DOUBLECIRCLESTART"));
  // `[\\(?=\])]` is a character class holding `\ ( ? = ]`, not a lookahead, so `)]` and `?]` close a
  // trapezoid too. Kept byte-identical rather than tidied.
  R(["trapText"], /[\\(?=\])][\]]/, popText("TRAPEND"));
  R(["trapText"], /\/(?=\])\]/, popText("INVTRAPEND"));
  R(["trapText"], /\/(?!\])|\\(?!\])|[^\\\[\](){}\/]+/, tok("TEXT"));
  R(ANY_STATE, /\[\//, pushText("trapText", "TRAPSTART"));
  R(ANY_STATE, /\[\\/, pushText("trapText", "INVTRAPSTART"));

  R(INITIAL_ONLY, /</, tok("TAGSTART"));
  // Unreachable: line 183 already claimed `>` for the odd-shape opener.
  R(INITIAL_ONLY, />/, tok("TAGEND"));
  R(INITIAL_ONLY, /\^/, tok("UP"));
  // A quoted pattern in a jison-lex file is escaped literally, so SEP matches a backslash followed
  // by a pipe -- not a bare `|`, which would shadow PIPE and break every `|label|` edge. It appears
  // in no production; it is here only to keep the table's order honest.
  R(INITIAL_ONLY, /\\\|/, tok("SEP"));
  // `v` is its own token, so `vnode` is DOWN plus NODE_STRING re-welded by idString.
  R(INITIAL_ONLY, /v/, tok("DOWN"));
  R(INITIAL_ONLY, /\*/, tok("MULT"));
  R(INITIAL_ONLY, /#/, tok("BRKT"));
  R(INITIAL_ONLY, /&/, tok("AMP"));
  R(INITIAL_ONLY, /(?:[A-Za-z0-9!"#$%&'*+.`?\\_\/]|-(?=[^>\-.])|=(?!=))+/, tok("NODE_STRING"));
  R(INITIAL_ONLY, /-/, tok("MINUS"));
  R(INITIAL_ONLY, new RegExp("[" + UNICODE_RANGES + "]"), tok("UNICODE_TEXT"));

  R(["text"], /\|/, popText("PIPE"));
  R(ANY_STATE, /\|/, pushText("text", "PIPE"));
  R(["text"], /\)/, popText("PE"));
  R(ANY_STATE, /\(/, pushText("text", "PS"));
  R(["text"], /\]/, popText("SQE"));
  R(ANY_STATE, /\[/, pushText("text", "SQS"));
  R(["text"], /\}/, popText("DIAMOND_STOP"));
  R(ANY_STATE, /\{/, pushText("text", "DIAMOND_START"));
  // Declared last of the `<text>` rules, and chunked rather than per-character: every bracket, pipe
  // and quote is excluded and falls through to a closer or an opener above. That is why
  // `A[This is a () in text]` must throw -- the `(` is not label text (flow-text.spec.js:581).
  R(["text"], /[^\[\](){}|"]+/, tok("TEXT"));

  // Unreachable: line 87 always claims a quote first. QUOTE appears in no production.
  R(INITIAL_ONLY, /"/, tok("QUOTE"));
  // A run of blank lines collapses into ONE token, while `\s` emits one SPACE per character.
  R(INITIAL_ONLY, /(\r?\n)+/, tok("NEWLINE"));
  R(INITIAL_ONLY, /\s/, tok("SPACE"));

  function ruleActive(rule, state) {
    if (rule.states === ANY_STATE) return true;
    if (rule.states === INITIAL_ONLY) return state === "INITIAL";
    return rule.states.indexOf(state) !== -1;
  }

  function Lexer(input, yy) {
    this.input = input;
    this.yy = yy;
    this.pos = 0;
    this.yytext = "";
    this.stack = ["INITIAL"];
    this.done = false;
  }

  Lexer.prototype.begin = function (condition) { this.stack.push(condition); };
  Lexer.prototype.popState = function () { if (this.stack.length > 1) this.stack.pop(); };

  Lexer.prototype.next = function () {
    for (;;) {
      // `<<EOF>>` is declared INITIAL-only, but jison-lex answers EOF from any state once the input
      // runs out. Reporting a lexical error instead would turn the unterminated-ellipse case into
      // the wrong kind of failure -- flow-text.spec.js:538 wants a parse error, not a hang.
      //
      // Exhausting the input is not the same moment as answering EOF, and the gap between them is
      // load-bearing. jison-lex sets `done` as soon as `_input` is empty but still runs the rules
      // that one time, so a start condition whose rule can match the empty string emits one last
      // empty token before EOF; only the call after that answers EOF. Six of the rules below can
      // match empty -- `<acc_title>[^\n]*`, `<acc_descr>[^\n]*`, `<acc_descr_multiline>[^}]*`,
      // `<callbackname>[^(]*`, `<callbackargs>[^)]*` and `<click>[^\s\n]*` -- and returning EOF the
      // moment the input ran out lost that token in every one of them. It mattered in both
      // directions: `accTitle:` with nothing after it parses in mermaid, on the empty
      // `acc_title_value`, and threw here, which is the failure this parser is not allowed to have;
      // and an unterminated `accDescr {` block ends in mermaid with an empty
      // `acc_descr_multiline_value` overwriting what the block had collected, which is why mermaid
      // reports no description for it while this reported the block's text.
      //
      // Run over every prefix of every source in the differential corpus, 15,039 of them, against
      // real mermaid: 10 rejections that mermaid accepts became agreement, 89 disagreements became
      // agreement, and 77 sources this used to accept and mermaid refuses now fail here too. One
      // prefix moved the other way, `click A call ` with the trailing space: the empty CALLBACKNAME
      // satisfies `CLICK CALLBACKNAME` here while mermaid still refuses it. That is a source this
      // accepts and mermaid does not, which costs nothing -- the rule runs the other way.
      if (this.done) return { type: "EOF", value: "", pos: this.pos };
      if (this.pos >= this.input.length) this.done = true;

      var state = this.stack[this.stack.length - 1];
      var matched = null;
      for (var i = 0; i < RULES.length; i += 1) {
        var rule = RULES[i];
        if (!ruleActive(rule, state)) continue;
        rule.re.lastIndex = this.pos;
        var m = rule.re.exec(this.input);
        if (m) { matched = { rule: rule, text: m[0] }; break; }
      }
      if (!matched) {
        if (this.done) return { type: "EOF", value: "", pos: this.pos };
        throw new Error("Lexical error on line " + lineOf(this.input, this.pos) + ": Unrecognized text.");
      }

      var start = this.pos;
      var depth = this.stack.length;
      this.yytext = matched.text;
      this.pos += matched.text.length;
      var name = matched.rule.act(this);
      // jison would spin here; a rule that neither consumes input nor changes condition can only be
      // reached by input mermaid also cannot lex, so failing loudly is the honest answer. Past the
      // end of the input it cannot spin -- `done` ends the loop on the next turn -- and that empty
      // match is the one jison emits, so the guard has to let it through.
      if (!this.done && matched.text.length === 0 && this.stack.length === depth) {
        throw new Error("Lexical error on line " + lineOf(this.input, start) + ": Unrecognized text.");
      }
      if (name !== undefined) return { type: name, value: this.yytext, pos: start };
    }
  };

  function lineOf(input, pos) {
    var line = 1;
    for (var i = 0; i < pos && i < input.length; i += 1) if (input.charAt(i) === "\n") line += 1;
    return line;
  }

  // ===========================================================================
  // The parser.
  //
  // Recursive descent over the token stream rather than an LALR table, because the grammar's only
  // real recursion is the left-recursive concatenations (`idString`, `text`, `vertexStatement`),
  // which are loops, and because the actions matter more than the derivation: every `yy.*` call has
  // to reach the db with the grammar's exact ARITY. flow-interactions.spec.js:26 spies on the
  // instance and asserts `toHaveBeenCalledWith('A','callback')`, so a padded trailing `undefined`
  // fails even though the effect is identical.
  //
  // The tokenizer needs no feedback from here -- its start conditions are driven entirely by the
  // characters it has seen -- but it is still pulled one token at a time, because jison's is too.
  // `node[hello ) world]` is the case that forces it: the `)` pops the text state and the parser
  // dies on PE, which flow-text.spec.js:605 asserts, while the `]` further along the line has no
  // rule at all in INITIAL. Scanning the source up front turns that into a lexical error instead.
  // ===========================================================================

  function set(names) {
    var m = new Map();
    for (var i = 0; i < names.length; i += 1) m.set(names[i], true);
    return m;
  }

  // The five token lists at flow.jison.reference:597-605. They differ in ways that matter:
  // alphaNumToken carries DIR but not DEFAULT, idStringToken carries DEFAULT and MINUS but not DIR.
  var ID_TOKENS = set(["NUM", "NODE_STRING", "DOWN", "MINUS", "DEFAULT", "COMMA", "COLON", "AMP", "BRKT", "MULT", "UNICODE_TEXT"]);
  var ALPHANUM_TOKENS = set(["NUM", "UNICODE_TEXT", "NODE_STRING", "DIR", "DOWN", "MINUS", "COMMA", "COLON", "AMP", "BRKT", "MULT"]);
  var TEXT_TOKENS = set(["TEXT", "TAGSTART", "TAGEND", "UNICODE_TEXT"]);
  var EDGE_TOKENS = set(["EDGE_TEXT", "UNICODE_TEXT"]);
  // `keywords` exists in the grammar solely to be inlined here, which is what lets a subgraph title
  // contain `end` mid-line even though a bare `end` closes the block.
  var NOTAG_TOKENS = set(["NUM", "NODE_STRING", "SPACE", "MINUS", "AMP", "UNICODE_TEXT", "COLON", "MULT", "BRKT",
    "START_LINK", "STYLE", "LINKSTYLE", "CLASSDEF", "CLASS", "CLICK", "GRAPH", "DIR", "subgraph", "end", "DOWN", "UP"]);
  // UNIT and PCT are declared in the grammar but no lexer rule produces them.
  var STYLE_TOKENS = set(["NUM", "NODE_STRING", "COLON", "SPACE", "BRKT", "STYLE"]);

  var DIRECTION_STMT = {
    direction_tb: "TB",
    direction_bt: "BT",
    direction_rl: "RL",
    direction_lr: "LR",
    direction_td: "TD"
  };

  function Parser(source, db) {
    this.lexer = new Lexer(source, db);
    this.source = source;
    this.db = db;
    this.toks = [];
    this.i = 0;
  }

  Parser.prototype.lookahead = function (k) {
    while (this.toks.length <= this.i + k) {
      var last = this.toks[this.toks.length - 1];
      if (last && last.type === "EOF") return last;
      this.toks.push(this.lexer.next());
    }
    return this.toks[this.i + k];
  };

  Parser.prototype.peek = function () { return this.lookahead(0); };
  Parser.prototype.advance = function () { this.i += 1; };

  Parser.prototype.at = function (type) { return this.peek().type === type; };

  Parser.prototype.skipSpaces = function () {
    while (this.at("SPACE")) this.advance();
  };

  // The type of the first token that is not a SPACE, used where the grammar needs one token of
  // lookahead past a spaceList.
  Parser.prototype.afterSpaces = function () {
    var k = 0;
    while (this.lookahead(k).type === "SPACE") k += 1;
    return this.lookahead(k).type;
  };

  // jison's own message shape, because the specs assert on substrings of it: `got 'PS'`,
  // `got 'STR'`, `got 'PE'` and `Expecting 'SQE'` (flow-text.spec.js:580-608). The expected list is
  // written closer-first for the same reason -- the assertion is a substring match, so a shape's
  // own terminator has to lead.
  Parser.prototype.fail = function (t, expected) {
    var line = lineOf(this.source, t.pos);
    var lines = this.source.split("\n");
    var text = lines[line - 1] === undefined ? "" : lines[line - 1];
    var quoted = expected.map(function (e) { return "'" + e + "'"; }).join(", ");
    throw new Error(
      "Parse error on line " + line + ":\n" + text + "\n" +
      new Array(Math.max(1, t.pos - this.source.lastIndexOf("\n", t.pos - 1))).join("-") + "^\n" +
      "Expecting " + quoted + ", got '" + t.type + "'"
    );
  };

  Parser.prototype.expect = function (type, alsoExpected) {
    var t = this.peek();
    if (t.type !== type) this.fail(t, alsoExpected ? [type].concat(alsoExpected) : [type]);
    this.advance();
    return t;
  };

  // ---------------------------------------------------------------------------

  Parser.prototype.parseStart = function () {
    this.graphConfig();
    this.document(false);
  };

  Parser.prototype.graphConfig = function () {
    while (this.at("SPACE") || this.at("NEWLINE")) this.advance();
    this.expect("GRAPH");
    if (this.at("NODIR")) {
      // The NODIR token already consumed the newline, so this form takes no separator of its own.
      this.advance();
      this.db.setDirection("TB");
      return;
    }
    var dir = this.expect("DIR", ["NODIR"]);
    this.db.setDirection(dir.value);
    this.skipSpaces();
    if (this.at("SEMI") || this.at("NEWLINE")) { this.advance(); return; }
    this.fail(this.peek(), ["NEWLINE", "SEMI"]);
  };

  Parser.prototype.separator = function () {
    // EOF is a legal statement terminator, so an unterminated last line parses.
    if (this.at("NEWLINE") || this.at("SEMI")) { this.advance(); return; }
    if (this.at("EOF")) return;
    this.fail(this.peek(), ["NEWLINE", "SEMI", "EOF"]);
  };

  Parser.prototype.document = function (inSubgraph) {
    var items = [];
    for (;;) {
      var t = this.peek();
      if (t.type === "EOF") {
        if (inSubgraph) this.fail(t, ["end"]);
        return items;
      }
      if (inSubgraph && t.type === "end") return items;
      if (t.type === "SEMI" || t.type === "NEWLINE" || t.type === "SPACE") {
        // Bare separator lines contribute their raw text and are filtered later, inside
        // addSubGraph's uniq -- not here, because that filter is also where the `dir` marker is
        // extracted (flow.jison.reference:307-325).
        items.push(t.value);
        this.advance();
        continue;
      }
      var value = this.statement();
      if (!Array.isArray(value) || value.length > 0) items.push(value);
    }
  };

  Parser.prototype.statement = function () {
    var t = this.peek();
    switch (t.type) {
      case "STYLE":
        this.styleStatement();
        this.separator();
        return [];
      case "LINKSTYLE":
        this.linkStyleStatement();
        this.separator();
        return [];
      case "CLASSDEF":
        this.classDefStatement();
        this.separator();
        return [];
      case "CLASS":
        this.classStatement();
        this.separator();
        return [];
      case "CLICK":
        this.clickStatement();
        this.separator();
        return [];
      case "subgraph":
        return this.subgraphStatement();
      case "acc_title":
        this.advance();
        var title = this.expect("acc_title_value").value.trim();
        this.db.setAccTitle(title);
        return title;
      case "acc_descr":
        this.advance();
        var descr = this.expect("acc_descr_value").value.trim();
        this.db.setAccDescription(descr);
        return descr;
      case "acc_descr_multiline_value":
        this.advance();
        var multi = t.value.trim();
        this.db.setAccDescription(multi);
        return multi;
      default:
        break;
    }
    if (DIRECTION_STMT[t.type]) {
      // Not setDirection: this sets the enclosing SUBGRAPH's dir, and the value is NOT normalised --
      // `direction TD` stores 'TD' where `graph TD` stores 'TB' (subgraph.spec.js:325). The marker
      // reaches addSubGraph through the statement list.
      this.advance();
      return { stmt: "dir", value: DIRECTION_STMT[t.type] };
    }
    var nodes = this.vertexStatement();
    this.separator();
    return nodes;
  };

  // ---------------------------------------------------------------------------
  // Vertices and links.
  // ---------------------------------------------------------------------------

  Parser.prototype.vertexStatement = function () {
    var nodes = this.nodeGroup();
    var accumulated = nodes.slice();
    var stmt = nodes;
    for (;;) {
      // A LINK or START_LINK carries its own leading whitespace, but LINK_ID does not, so `A e1@-->B`
      // arrives as a node, a spaceList and then the link -- which the grammar reaches through
      // `vertexStatement: node spaceList` (flow.jison.reference:409).
      var t = this.at("SPACE") ? this.afterSpaces() : this.peek().type;
      if (t !== "LINK" && t !== "START_LINK" && t !== "LINK_ID") break;
      this.skipSpaces();
      var link = this.link();
      var next = this.nodeGroup();
      this.db.addLink(stmt, next, link);
      // Prepended, not appended: a chained statement reports its nodes tail-to-head, which is what
      // makes `a1-->a2-->a3` inside a subgraph come back as ['a3','a2','a1'] (subgraph.spec.js:33).
      accumulated = next.concat(accumulated);
      stmt = next;
    }
    this.skipSpaces();
    return accumulated;
  };

  Parser.prototype.nodeGroup = function () {
    var list = [this.styledVertex()];
    for (;;) {
      if (this.at("SHAPE_DATA")) {
        var data = this.shapeData();
        // Targets the last id read so far. mermaid reaches the same vertices by a different
        // route -- flow.jison.reference:420-421 reduces the whole `node & node` group before
        // running the action, so it attaches the metadata after the later ids exist -- and the
        // only thing that falls out of the difference is the order ids are counted in, which
        // shows up as a different `domId` suffix on the second node of a group. Nothing the
        // renderer reads depends on it, and no spec covers it.
        this.db.addVertex(list[list.length - 1], undefined, undefined, undefined, undefined, undefined, undefined, data);
      }
      // `&` grouping needs a spaceList on both sides, so `A&B` is one id rather than two nodes.
      if (!(this.at("SPACE") && this.afterSpaces() === "AMP")) break;
      this.skipSpaces();
      this.advance();
      this.skipSpaces();
      list.push(this.styledVertex());
    }
    return list;
  };

  Parser.prototype.shapeData = function () {
    var out = "";
    while (this.at("SHAPE_DATA")) {
      out += this.peek().value;
      this.advance();
    }
    return out;
  };

  Parser.prototype.styledVertex = function () {
    var id = this.vertex();
    if (this.at("STYLE_SEPARATOR")) {
      this.advance();
      this.db.setClass(id, this.idString());
    }
    return id;
  };

  Parser.prototype.vertex = function () {
    var id = this.idString();
    var db = this.db;
    var txt;
    switch (this.peek().type) {
      case "SQS":
        this.advance();
        txt = this.text("SQE");
        this.expect("SQE");
        db.addVertex(id, txt, "square");
        break;
      case "DOUBLECIRCLESTART":
        this.advance();
        txt = this.text("DOUBLECIRCLEEND");
        this.expect("DOUBLECIRCLEEND");
        db.addVertex(id, txt, "doublecircle");
        break;
      case "PS":
        this.advance();
        if (this.at("PS")) {
          this.advance();
          txt = this.text("PE");
          this.expect("PE");
          this.expect("PE");
          db.addVertex(id, txt, "circle");
        } else {
          txt = this.text("PE");
          this.expect("PE");
          db.addVertex(id, txt, "round");
        }
        break;
      case "(-":
        this.advance();
        txt = this.text("-)");
        this.expect("-)");
        db.addVertex(id, txt, "ellipse");
        break;
      case "STADIUMSTART":
        this.advance();
        txt = this.text("STADIUMEND");
        this.expect("STADIUMEND");
        db.addVertex(id, txt, "stadium");
        break;
      case "SUBROUTINESTART":
        this.advance();
        txt = this.text("SUBROUTINEEND");
        this.expect("SUBROUTINEEND");
        db.addVertex(id, txt, "subroutine");
        break;
      case "VERTEX_WITH_PROPS_START":
        this.advance();
        var field = this.expect("NODE_STRING").value;
        this.expect("COLON");
        var value = this.expect("NODE_STRING").value;
        this.expect("PIPE");
        txt = this.text("SQE");
        this.expect("SQE");
        var props = {};
        props[field] = value;
        db.addVertex(id, txt, "rect", undefined, undefined, undefined, props);
        break;
      case "CYLINDERSTART":
        this.advance();
        txt = this.text("CYLINDEREND");
        this.expect("CYLINDEREND");
        db.addVertex(id, txt, "cylinder");
        break;
      case "DIAMOND_START":
        this.advance();
        if (this.at("DIAMOND_START")) {
          this.advance();
          txt = this.text("DIAMOND_STOP");
          this.expect("DIAMOND_STOP");
          this.expect("DIAMOND_STOP");
          db.addVertex(id, txt, "hexagon");
        } else {
          txt = this.text("DIAMOND_STOP");
          this.expect("DIAMOND_STOP");
          db.addVertex(id, txt, "diamond");
        }
        break;
      case "TAGEND":
        this.advance();
        txt = this.text("SQE");
        this.expect("SQE");
        db.addVertex(id, txt, "odd");
        break;
      case "TRAPSTART":
        // Which of the two closers arrives decides between trapezoid and lean_right; neither the
        // opener nor the closer settles the shape alone.
        this.advance();
        txt = this.text("TRAPEND");
        if (this.at("INVTRAPEND")) {
          this.advance();
          db.addVertex(id, txt, "lean_right");
        } else {
          this.expect("TRAPEND");
          db.addVertex(id, txt, "trapezoid");
        }
        break;
      case "INVTRAPSTART":
        this.advance();
        txt = this.text("TRAPEND");
        if (this.at("INVTRAPEND")) {
          this.advance();
          db.addVertex(id, txt, "inv_trapezoid");
        } else {
          this.expect("TRAPEND");
          db.addVertex(id, txt, "lean_left");
        }
        break;
      default:
        // One argument, deliberately. addVertex distinguishes an absent textObj and type from an
        // explicit undefined nowhere, but the style-warning branch reads `style !== undefined`, so
        // the bare form must not pad (flowDb.reference.ts:183).
        db.addVertex(id);
    }
    return id;
  };

  Parser.prototype.link = function () {
    var id;
    if (this.at("LINK_ID")) {
      id = this.peek().value;
      this.advance();
    }
    var t = this.peek();
    if (t.type === "START_LINK") {
      this.advance();
      var body = this.edgeText();
      var end = this.peek();
      if (end.type !== "LINK") this.fail(end, ["LINK"]);
      this.advance();
      var paired = this.db.destructLink(end.value, t.value);
      var withText = { type: paired.type, stroke: paired.stroke, length: paired.length, text: body };
      if (id !== undefined) withText.id = id;
      return withText;
    }
    if (t.type === "LINK") {
      this.advance();
      // One argument: `linkStatement: LINK` never validates a start marker, so the whole
      // double-ended branch of destructLink is skipped for a plain arrow.
      var info = this.db.destructLink(t.value);
      var link = { type: info.type, stroke: info.stroke, length: info.length };
      if (id !== undefined) link.id = id;
      if (this.at("PIPE")) {
        this.advance();
        link.text = this.text("PIPE");
        this.expect("PIPE");
        this.skipSpaces();
      }
      return link;
    }
    this.fail(t, ["LINK", "START_LINK"]);
  };

  // STR and MD_STR are whole-label alternatives: they can be followed by plain tokens but never
  // preceded by them, which is why `A(this node has "string" and text)` is a parse error while
  // `"test string()" ` trailing a space is not (flow-text.spec.js:162, :586).
  Parser.prototype.labelled = function (tokens, stringType, closer) {
    var t = this.peek();
    var type;
    var buf;
    if (t.type === "STR") { type = stringType; buf = t.value; this.advance(); }
    else if (t.type === "MD_STR") { type = "markdown"; buf = t.value; this.advance(); }
    else if (tokens.get(t.type)) { type = "text"; buf = t.value; this.advance(); }
    else this.fail(t, [closer]);
    while (tokens.get(this.peek().type)) {
      buf += this.peek().value;
      this.advance();
    }
    return { text: buf, type: type };
  };

  Parser.prototype.text = function (closer) { return this.labelled(TEXT_TOKENS, "string", closer); };
  Parser.prototype.edgeText = function () { return this.labelled(EDGE_TOKENS, "string", "LINK"); };
  // The one text context that reports a double-quoted label as 'text' rather than 'string', which is
  // how `subgraph "One"` ends up with labelType 'text' (flow-md-string.spec.js:57).
  Parser.prototype.textNoTags = function () { return this.labelled(NOTAG_TOKENS, "text", "SQS"); };

  Parser.prototype.idString = function () {
    var t = this.peek();
    if (!ID_TOKENS.get(t.type)) this.fail(t, ["NODE_STRING"]);
    var buf = "";
    while (ID_TOKENS.get(this.peek().type)) {
      buf += this.peek().value;
      this.advance();
    }
    return buf;
  };

  Parser.prototype.alphaNum = function () {
    var t = this.peek();
    if (!ALPHANUM_TOKENS.get(t.type)) this.fail(t, ["NODE_STRING"]);
    var buf = "";
    while (ALPHANUM_TOKENS.get(this.peek().type)) {
      buf += this.peek().value;
      this.advance();
    }
    return buf;
  };

  // ---------------------------------------------------------------------------
  // Subgraphs.
  // ---------------------------------------------------------------------------

  Parser.prototype.subgraphStatement = function () {
    this.advance();
    var idObj;
    var titleObj;
    if (this.at("SPACE")) {
      this.advance();
      idObj = this.textNoTags();
      if (this.at("SQS")) {
        this.advance();
        titleObj = this.text("SQE");
        this.expect("SQE");
      } else {
        // The SAME object in both positions, never a copy: addSubGraph decides whether the title
        // doubles as the id by reference identity (flow.jison.reference:382).
        titleObj = idObj;
      }
    }
    this.separator();
    var doc = this.document(true);
    // No separator after `end`: its lexer rule already swallowed the newline.
    this.expect("end");
    // The resolved id is the statement's value, so an enclosing subgraph sees the nested one as a
    // member of its own node list.
    return this.db.addSubGraph(idObj, doc, titleObj);
  };

  // ---------------------------------------------------------------------------
  // Styles, classes and interactivity.
  // ---------------------------------------------------------------------------

  Parser.prototype.style = function () {
    var t = this.peek();
    if (!STYLE_TOKENS.get(t.type)) this.fail(t, ["NODE_STRING"]);
    var buf = "";
    // SPACE is a style component, so `border:1px solid red` stays one entry and its interior spaces
    // survive verbatim (flow-style.spec.js:144).
    while (STYLE_TOKENS.get(this.peek().type)) {
      buf += this.peek().value;
      this.advance();
    }
    return buf;
  };

  Parser.prototype.stylesOpt = function () {
    var list = [this.style()];
    while (this.at("COMMA")) {
      this.advance();
      list.push(this.style());
    }
    return list;
  };

  Parser.prototype.styleStatement = function () {
    this.advance();
    this.expect("SPACE");
    var id = this.idString();
    this.expect("SPACE");
    // Four arguments. The missing textObj and type are what make addVertex log the unknown-node
    // warning before creating the vertex for backward compatibility.
    this.db.addVertex(id, undefined, undefined, this.stylesOpt());
  };

  Parser.prototype.classDefStatement = function () {
    this.advance();
    this.expect("SPACE");
    var ids = this.idString();
    this.expect("SPACE");
    // `ids` stays a comma-separated string; addClass splits it itself.
    this.db.addClass(ids, this.stylesOpt());
  };

  Parser.prototype.classStatement = function () {
    this.advance();
    this.expect("SPACE");
    var ids = this.idString();
    this.expect("SPACE");
    this.db.setClass(ids, this.idString());
  };

  Parser.prototype.numList = function () {
    var list = [this.expect("NUM").value];
    while (this.at("COMMA")) {
      this.advance();
      list.push(this.expect("NUM").value);
    }
    return list;
  };

  Parser.prototype.linkStyleStatement = function () {
    this.advance();
    this.expect("SPACE");
    var positions;
    if (this.at("DEFAULT")) {
      // An array of one, not the bare string: updateLink iterates positions and branches on
      // `pos === 'default'`.
      positions = [this.peek().value];
      this.advance();
    } else {
      positions = this.numList();
    }
    this.expect("SPACE");
    if (this.at("INTERPOLATE")) {
      this.advance();
      this.expect("SPACE");
      this.db.updateLinkInterpolate(positions, this.alphaNum());
      if (this.at("SPACE") && STYLE_TOKENS.get(this.afterSpaces())) {
        this.advance();
        this.db.updateLink(positions, this.stylesOpt());
      }
      return;
    }
    this.db.updateLink(positions, this.stylesOpt());
  };

  // The thirteen clickStatement productions, folded into the three shapes they actually take. What
  // the specs pin here is arity: two arguments where the grammar writes two, three where it writes
  // three, and setLink before setTooltip when both fire.
  Parser.prototype.clickStatement = function () {
    var db = this.db;
    var id = this.peek().value;
    this.advance();
    var t = this.peek();

    if (t.type === "CALLBACKNAME") {
      this.advance();
      if (this.at("CALLBACKARGS")) {
        var args = this.peek().value;
        this.advance();
        db.setClickEvent(id, t.value, args);
      } else {
        // `call cb()` emits no CALLBACKARGS at all, so this is the two-argument form.
        db.setClickEvent(id, t.value);
      }
      this.clickTooltip(id);
      return;
    }

    if (t.type === "HREF" || t.type === "STR") {
      if (t.type === "HREF") this.advance();
      var link = this.expect("STR").value;
      var tooltip;
      var target;
      if (this.at("SPACE") && this.afterSpaces() === "STR") {
        this.skipSpaces();
        tooltip = this.peek().value;
        this.advance();
      }
      if (this.at("SPACE") && this.afterSpaces() === "LINK_TARGET") {
        this.skipSpaces();
        target = this.peek().value;
        this.advance();
      }
      if (target === undefined) db.setLink(id, link);
      else db.setLink(id, link, target);
      if (tooltip !== undefined) db.setTooltip(id, tooltip);
      return;
    }

    // `click A callback` reaches setClickEvent through alphaNum, not CALLBACKNAME -- that token only
    // exists after the word `call`.
    db.setClickEvent(id, this.alphaNum());
    this.clickTooltip(id);
  };

  Parser.prototype.clickTooltip = function (id) {
    if (!(this.at("SPACE") && this.afterSpaces() === "STR")) return;
    this.skipSpaces();
    this.db.setTooltip(id, this.peek().value);
    this.advance();
  };

  // ===========================================================================
  // Parsing.
  // ===========================================================================

  function parse(source, db) {
    var text = String(source);
    // Every action is dispatched on the db the caller handed us, never on a captured reference: a
    // spy installed on the instance has to be what the parser finds.
    var parser = new Parser(text, db);
    parser.parseStart();
    return true;
  }

  // ===========================================================================
  // Layout. Not written yet -- see the head of the file.
  // ===========================================================================

  function layout(db, options) {
    throw new Error("not implemented");
  }

  // ===========================================================================
  // The app entry. Never throws; declines with {ok:false, reason} so the glue can fall back to
  // mermaid without a try/catch deciding what a failure means. Every source declines today.
  // ===========================================================================

  function render(input) {
    return { ok: false, reason: "not-implemented" };
  }

  var API = {
    version: FLOW_VERSION,
    FlowDB: FlowDB,
    log: log,
    parse: parse,
    layout: layout,
    render: render
  };

  if (typeof module === "object" && module && module.exports) module.exports = API;
  if (typeof window !== "undefined") window.__flowpeekFlow = API;
})();
