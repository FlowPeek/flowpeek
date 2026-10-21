// FlowPeek's own flowchart renderer.
//
// All three phases are here. `parse` reads Mermaid flowchart source into `FlowDB`; `layout` turns
// that into geometry -- a box for every vertex, a container for every subgraph, and the ranks and
// ports every edge has to join; `render` routes those ports orthogonally and writes the SVG. The
// app still draws every flowchart with the vendored mermaid, because nothing in the glue calls
// `render` yet; that seam is RENDERER-SPEC.md §2 and it is one `if` in flowpeek-glue.js.
//
// What it is for is the part mermaid cannot be asked for. diagram-design calls two things
// non-negotiable -- every coordinate on a 4px grid, every connector orthogonal with a rounded elbow
// -- and this session established that neither can be bolted on afterwards: snapping mermaid's
// output moves the boxes out from under the edges it has already routed. So the grid is counted in
// rather than corrected. Layout arithmetic happens in integer units of 4px and nothing else, which
// is why there is no snapping pass below and no rounding rule to get wrong.
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
  // The grid.
  //
  // It is counted in rather than checked. Every number from here down is an integer in grid units
  // of 4 CSS px; `up` is the only door a measured pixel enters by and `px` the only door out, so a
  // coordinate of 37 is not a thing this file can produce. That is why there is no snapToGrid()
  // anywhere below -- a snap is a repair, and a repair means something was allowed to break first.
  // The prototype that snapped mermaid's output is what settled this: it put every rect corner on
  // the grid and broke the edges that had already been routed to the old corners.
  // ===========================================================================

  var GRID = 4;

  function up(pixels) {
    return Math.ceil(pixels / GRID);
  }

  function px(units) {
    return units * GRID;
  }

  // A node is positioned by its centre -- `transform="translate(cx,cy)"`, mermaid's convention and
  // the one the theme's selectors assume -- so its width and height have to be even numbers of
  // units or the centre lands on a half-unit and every corner comes off the grid by 2px.
  function even(units) {
    return (units % 2) === 0 ? units : units + 1;
  }

  function gridUp(value, fallback) {
    var n = Number(value);
    if (!isFinite(n) || n <= 0) n = fallback;
    return Math.ceil(n / GRID) * GRID;
  }

  function nonEmptyString(v) {
    return (typeof v === "string" && v.length > 0) ? v : "";
  }

  // ===========================================================================
  // The theme projection.
  //
  // MacMermaidTheme.swift stays the single source of truth; this reads a named allowlist out of the
  // payload already on the wire and invents nothing (RENDERER-SPEC.md §4). Layout needs three of
  // the fields -- the type, the type size and the arrangement -- and carries the rest for the
  // phases that paint.
  // ===========================================================================

  function buildFlowTheme(payload) {
    var p = payload || {};
    var vars = (p.themeVariables && typeof p.themeVariables === "object") ? p.themeVariables : {};
    var css = typeof p.themeCSS === "string" ? p.themeCSS : "";
    var arr = (p.arrangement && typeof p.arrangement === "object") ? p.arrangement : {};

    // The 12px floor is the style guide's and it is about Hangul, not taste: below it the syllable
    // blocks fill in and a Korean label becomes a smudge (style-guide.md, "Floor of 12px"). The
    // shipped theme asks for 12px, so this only ever catches a host that asks for less.
    var size = parseFloat(vars.fontSize);
    if (!(size >= 12)) size = 12;

    return {
      dark: p.dark === true,
      fontFamily: nonEmptyString(p.fontFamily) || nonEmptyString(vars.fontFamily) || "sans-serif",
      // The face the theme's stylesheet paints edge labels in, which the payload names separately
      // because it need not be the node face (MacMermaidTheme.monoFontFamily -- the name is
      // historical; the editorial theme now sends its sans). A payload without it falls back to the
      // node face, and an edge label is then measured in a face that may not be the painted one.
      monoFontFamily: nonEmptyString(p.monoFontFamily) || nonEmptyString(p.fontFamily) || "monospace",
      fontSizePX: size,
      variables: vars,
      css: css,
      ladder: css.indexOf(".fp-ladder") !== -1,
      arrangement: {
        // All five shipped values are already exact multiples of 4 (MacMermaidTheme.swift:412-428).
        // Rounding up here is for a host that hands over something else, and it happens once, at
        // projection time, so the layout never sees a length it has to think about.
        nodeSpacing: gridUp(arr.nodeSpacing, 32),
        rankSpacing: gridUp(arr.rankSpacing, 40),
        padding: gridUp(arr.padding, 16),
        diagramPadding: gridUp(arr.diagramPadding, 24),
        curve: nonEmptyString(arr.curve) || "rounded",
        flowchartCurve: nonEmptyString(arr.flowchartCurve) || "step",
        wrappingWidth: gridUp(arr.wrappingWidth, 160)
      },
      labelContrast: p.labelContrast || null
    };
  }

  // ===========================================================================
  // Text.
  //
  // The module never touches the DOM, so every width in it comes from the injected callback
  // (RENDERER-SPEC.md §3). There is deliberately no internal fallback metric: a guessed advance
  // would draw a different diagram on every host and the difference would be invisible until
  // something clipped.
  // ===========================================================================

  // Recognised before escaping and turned into a line break, which is the one piece of markup a
  // label is allowed to carry. Everything else in a label is character data.
  var BREAK_TAG = /<br\s*\/?\s*>/gi;

  // Nonspacing and enclosing marks, so a grapheme is not cut away from the letter it sits on when
  // a run has to be broken by character. Ranges rather than \p{M}: the file is loaded as a classic
  // script into a WKContentWorld and unicode property escapes are not worth the compatibility bet.
  var COMBINING = /[\u0300-\u036F\u0483-\u0489\u0591-\u05BD\u0610-\u061A\u064B-\u065F\u0E31\u0E34-\u0E3A\u0E47-\u0E4E\u1AB0-\u1AFF\u1DC0-\u1DFF\u20D0-\u20F0\u3099\u309A\uFE00-\uFE0F\uFE20-\uFE2F]/;

  // Surrogate-aware, mark-aware, and emphatically not Intl.Segmenter: the drawing has to be the
  // same bytes on every host, and a segmenter's answer follows the host's ICU version
  // (RENDERER-SPEC.md §5.6).
  function graphemes(s) {
    var out = [];
    var i = 0;
    while (i < s.length) {
      var piece;
      var c = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        var d = s.charCodeAt(i + 1);
        piece = (d >= 0xDC00 && d <= 0xDFFF) ? s.slice(i, i + 2) : s.charAt(i);
      } else {
        piece = s.charAt(i);
      }
      i += piece.length;
      if (out.length > 0 && COMBINING.test(piece)) out[out.length - 1] += piece;
      else out.push(piece);
    }
    return out;
  }

  function makeMetrics(measureText, theme) {
    if (typeof measureText !== "function") {
      throw new TypeError("layout needs a measureText callback; see RENDERER-SPEC.md §3");
    }
    // Allocated per call, never at module scope: the pooled web view keeps one JS context across
    // renders, so anything that survives a render and reaches the output is a determinism bug
    // waiting for a second diagram (RENDERER-SPEC.md §5.1).
    var cache = Object.create(null);

    function measure(text, style) {
      var key = style.fontSizePX + "|" + style.fontWeight + "|" + style.letterSpacing + "|" + text;
      var hit = cache[key];
      if (hit !== undefined) return hit;
      var m = measureText(text, style) || {};
      var w = Number(m.width);
      var h = Number(m.height);
      var out = {
        w: (isFinite(w) && w > 0) ? w : 0,
        // A floor, not a substitute. The adapter owes a line box for empty text -- WebKit answers
        // 0x0 where Blink answers the em, which is the whole reason the glue patches getBBox -- and
        // a zero here would give a label no height at all rather than an obviously wrong one.
        h: (isFinite(h) && h > 0) ? h : style.fontSizePX
      };
      cache[key] = out;
      return out;
    }

    // The three registers the editorial stylesheet actually paints, and they are read off that
    // stylesheet rather than off the style guide. The guide puts arrow labels at 8px tracked mono;
    // the theme's `.edgeLabel` rule sets the face (carried as `monoFontFamily`, whatever it is) and
    // the weight, sets no tracking, and leaves the size alone, so the painted size is the base size
    // and the tracking is normal. Measuring the guide's 8px, or the 0.04em it used to track by,
    // would size every backing rect for type nobody will see.
    return {
      measure: measure,
      node: {
        fontFamily: theme.fontFamily,
        fontSizePX: theme.fontSizePX,
        fontWeight: 600,
        letterSpacing: "normal"
      },
      edge: {
        fontFamily: theme.monoFontFamily,
        fontSizePX: theme.fontSizePX,
        fontWeight: 400,
        letterSpacing: "normal"
      },
      cluster: {
        fontFamily: theme.fontFamily,
        fontSizePX: theme.fontSizePX,
        fontWeight: 600,
        letterSpacing: "0.06em"
      }
    };
  }

  // The longest prefix of `text` that fits, as graphemes. Returns null when the whole thing fits or
  // when there is nothing to cut, so the caller's loop always makes progress.
  function breakToWidth(text, measure, style, maxPX) {
    var parts = graphemes(text);
    if (parts.length <= 1) return null;
    var head = parts[0];
    var i = 1;
    for (; i < parts.length; i += 1) {
      if (measure(head + parts[i], style).w > maxPX) break;
      head += parts[i];
    }
    if (i >= parts.length) return null;
    return { head: head, tail: parts.slice(i).join("") };
  }

  // `keepWordsWhole` asks for the grapheme fallback to stay off while the line still has a space to
  // break at. The zone title is the one caller that asks: a cluster is sized by what is inside it
  // and can be widened, so a title that does not fit is a reason to give it more room, not a reason
  // to cut a word in half. reelect.mmd is the source that settled it -- its title came out as
  // "QuoteStatusChangedEven" / "t 수신 후 재선정" inside a zone 608px wide. A node label cannot be
  // given room the same way -- it is pinned to the wrapping width -- so it keeps the fallback.
  //
  // The fallback is kept even for a title when the line offers nothing else: a CJK title carries no
  // spaces at all, and one line 900px long is worse for the reader than a cut one.
  function wrapOneLine(line, measure, style, maxPX, keepWordsWhole) {
    var text = line.replace(/\s+/g, " ").replace(/^ /, "").replace(/ $/, "");
    if (text === "") return [""];
    if (measure(text, style).w <= maxPX) return [text];

    var words = text.split(" ");
    var mayCut = !keepWordsWhole || words.length === 1;
    var out = [];
    var cur = "";
    for (var i = 0; i < words.length; i += 1) {
      var candidate = (cur === "") ? words[i] : cur + " " + words[i];
      if (cur !== "" && measure(candidate, style).w > maxPX) {
        out.push(cur);
        cur = words[i];
      } else {
        cur = candidate;
      }
      // A run with no break opportunity in it -- a URL, a path, or any CJK sentence, which carries
      // no spaces at all -- would otherwise stay one line however long and blow the node out past
      // the wrapping width. Breaking it by grapheme is the only option that is still deterministic.
      while (mayCut) {
        if (measure(cur, style).w <= maxPX) break;
        var cut = breakToWidth(cur, measure, style, maxPX);
        if (!cut) break;
        out.push(cut.head);
        cur = cut.tail;
      }
    }
    if (cur !== "") out.push(cur);
    return out.length ? out : [""];
  }

  // A label's lines and its box, in grid units. `up` runs here and nowhere else downstream: two
  // hosts whose font metrics differ by less than 4px produce the same drawing, and a box is never
  // narrower than the text in it because the rounding is always outward (RENDERER-SPEC.md §7.1).
  // The five references DOMPurify's serializer can produce, which is the whole of what the parser
  // hands over: `escapeText` writes `&amp; &lt; &gt; &quot; &nbsp;` and copies any other reference
  // through from the source verbatim. Unknown names are left alone on purpose -- a table of 2,231
  // entity names to display `&hellip;` correctly is not worth carrying, and leaving it literal is
  // the failure the reader can see and fix rather than one that silently changes their words.
  var NAMED_REFS = new Map([["amp", "&"], ["lt", "<"], ["gt", ">"], ["quot", "\""], ["apos", "'"], ["nbsp", "\u00a0"]]);
  var ANY_REF = /&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/g;

  // The parser's output is HTML-escaped text, because mermaid's sanitizer is an HTML serializer:
  // `A["a & b"]` arrives as `a &amp; b`. Measuring and drawing that verbatim would show the reader
  // five characters where they wrote one, so it is decoded back to characters here -- once, and
  // before anything is measured, so the box is sized for what will be painted. Safety is not what
  // the encoding was doing at this point: `esc` re-escapes every one of these at emit time, so
  // `&lt;script&gt;` decodes to text and is written back out as `&lt;script&gt;`.
  function decodeRefs(text) {
    return String(text).replace(ANY_REF, function (whole, body) {
      if (body.charAt(0) === "#") {
        var hex = (body.charAt(1) === "x" || body.charAt(1) === "X");
        var code = hex ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
        // Control characters stay spelled out. A decoded `&#10;` would put a newline inside a
        // <tspan>, which is a line the layout never measured and never reserved room for.
        if (!isFinite(code) || code < 0x20 || code > 0x10FFFF) return whole;
        if (code >= 0xD800 && code <= 0xDFFF) return whole;
        return String.fromCodePoint(code);
      }
      var named = NAMED_REFS.get(body);
      return named === undefined ? whole : named;
    });
  }

  function shapeLabel(text, metrics, style, maxPX, keepWordsWhole) {
    // Split before decoding, never after. `<br/>` is a line break because the sanitizer kept it as
    // markup; `&lt;br/&gt;` is four visible characters because the author escaped it, and decoding
    // first would turn the second into the first.
    var hard = String(text === undefined || text === null ? "" : text).split(BREAK_TAG);
    var lines = [];
    for (var i = 0; i < hard.length; i += 1) {
      var wrapped = wrapOneLine(decodeRefs(hard[i]), metrics.measure, style, maxPX, keepWordsWhole);
      for (var j = 0; j < wrapped.length; j += 1) lines.push(wrapped[j]);
    }
    var widest = 0;
    var tallest = 0;
    for (var k = 0; k < lines.length; k += 1) {
      var m = metrics.measure(lines[k], style);
      if (m.w > widest) widest = m.w;
      if (m.h > tallest) tallest = m.h;
    }
    var lineHeight = up(tallest);
    return {
      lines: lines,
      w: up(widest),
      h: lineHeight * lines.length,
      lineHeight: lineHeight
    };
  }

  // ===========================================================================
  // Shapes.
  //
  // Only the geometry, and only as much of it as sizing needs. The grammar writes sixteen shape
  // names and `@{ shape: … }` can write any of the ~180 in the catalogue; this maps the ones whose
  // outline changes how much room a label needs and lets everything else be a rectangle, which is
  // the honest default -- a box that is slightly too big is a drawing, a box that is too small is
  // clipped text.
  // ===========================================================================

  var SHAPE_GEOMETRY = (function () {
    var m = new Map();
    function put(geometry, names) {
      var list = names.split(" ");
      for (var i = 0; i < list.length; i += 1) m.set(list[i], geometry);
    }
    put("round", "round roundedRect rounded rect-rounded");
    put("stadium", "stadium pill terminal");
    put("circle", "circle circ small-circle sm-circ");
    put("doublecircle", "doublecircle double-circle dbl-circ framed-circle fr-circ");
    put("ellipse", "ellipse");
    put("diamond", "diamond diam decision question");
    put("hexagon", "hexagon hex prepare");
    // The one shape that decides a rung, so the alias set matters: a cylinder is the author saying
    // "datastore" and `fp-store` is what the theme paints it with.
    put("cylinder", "cylinder cyl db database datastore data-store das disk lin-cyl lined-cylinder");
    put("subroutine", "subroutine subprocess subproc framed-rectangle fr-rect");
    put("lean-r", "lean_right lean-r lean-right in-out");
    put("lean-l", "lean_left lean-l lean-left out-in");
    put("trap-t", "trapezoid trap-b priority");
    put("trap-b", "inv_trapezoid inv-trapezoid trap-t manual");
    put("odd", "odd rect_left_inv_arrow");
    return m;
  })();

  function geometryOf(shape) {
    var g = SHAPE_GEOMETRY.get(String(shape));
    return g === undefined ? "rect" : g;
  }

  // The smallest width on the style guide's own node ramp (80, 96, 112, …) and a height that keeps
  // a one-line label on the 4px grid with room above and below. A measured box almost never lands
  // on a ramp value; the floor is what stops a two-character node from becoming a chip.
  var MIN_W = 20;
  var MIN_H = 8;
  var MIN_ROUND = 12;

  function shapeBox(geometry, label, pad) {
    var w = label.w + 2 * pad;
    var h = label.h + 2 * pad;
    var d;
    switch (geometry) {
      case "diamond":
        // A w×h rectangle is inscribed in a rhombus of diagonals W×H exactly when w/W + h/H = 1,
        // so W = 2w, H = 2h is the tightest rhombus that holds the label -- with the text touching
        // all four edges at their midpoints. The padding is added once on top of that, which is the
        // clearance. Adding it before doubling would pay for it twice and give a 320px "Yes?".
        w = 2 * label.w + pad;
        h = 2 * label.h + pad;
        break;
      case "circle":
      case "doublecircle":
        // The circumscribed circle of the label box; padding is a radial margin so it counts twice.
        d = Math.ceil(Math.sqrt(label.w * label.w + label.h * label.h)) + 2 * pad;
        if (geometry === "doublecircle") d += 2;
        d = even(Math.max(d, MIN_ROUND));
        return { w: d, h: d };
      case "ellipse":
        // An ellipse circumscribing a w×h rectangle has axes w√2 and h√2.
        w = Math.ceil(label.w * 1.4143) + pad;
        h = Math.ceil(label.h * 1.4143) + pad;
        break;
      case "hexagon":
      case "lean-r":
      case "lean-l":
      case "trap-t":
      case "trap-b":
        // The slanted ends take half the height of usable width off each side.
        w += h;
        break;
      case "subroutine":
        w += 4;
        break;
      case "stadium":
        w += 2;
        // A pill is at least as wide as it is tall, and this is the line that makes that true
        // rather than a hope. shapeMarkup writes the cap as an arc of radius min(W,H) between two
        // ends 2H apart, and SVG scales a radius too small to reach both ends up until it does: a
        // box taller than it is wide is drawn with caps of radius H, which reach H-W past the box
        // on each side. Measured on a five-line label: an 80x112 box drawn 112 wide, so the port on
        // its side face -- and the arrowhead on it -- sat 16px inside the fill that is painted over
        // them. Widening the box is the only fix the path shape allows; capping the radius would
        // draw a cap that does not reach its own ends.
        if (h > w) w = h;
        break;
      case "odd":
        w += 2;
        break;
      case "cylinder":
        h += 4;
        break;
      default:
        break;
    }
    return { w: even(Math.max(w, MIN_W)), h: even(Math.max(h, MIN_H)) };
  }

  // ===========================================================================
  // The model the layout works on.
  //
  // Built from the parse tree, never from a rendered document. That is the whole advantage of
  // owning both halves: subgraph membership, shape and edge pattern are facts here, where the glue
  // has to recover membership by comparing cluster rects against node transforms because mermaid
  // does not put the nesting in the DOM.
  // ===========================================================================

  function normaliseDirection(dir, fallback) {
    var d = String(dir === undefined || dir === null ? "" : dir).trim().toUpperCase();
    if (d === "TD") d = "TB";
    if (d === "TB" || d === "BT" || d === "LR" || d === "RL") return d;
    return fallback;
  }

  function ancestry(id, parentOf) {
    var chain = [];
    var cur = id;
    // A subgraph cannot contain its own ancestor -- the parser closes the inner one first -- so the
    // bound is not load-bearing; it is here so a malformed model fails as a bad drawing rather than
    // as a hang.
    for (var guard = 0; guard < 256 && cur !== undefined && cur !== null; guard += 1) {
      chain.push(cur);
      cur = parentOf.get(cur);
    }
    chain.push("");
    return chain;
  }

  function buildModel(db, rootDirection) {
    var vertices = db.getVertices();
    var subGraphs = db.getSubGraphs();
    var rawEdges = db.getEdges();

    var clusterById = new Map();
    var i;
    for (i = 0; i < subGraphs.length; i += 1) clusterById.set(subGraphs[i].id, subGraphs[i]);

    // `makeUniq` already guarantees a node is claimed by exactly one subgraph -- the innermost,
    // because it closed first -- and a nested subgraph's id reaches its parent's member list as the
    // value of the `subgraph` statement. So one pass in declaration order is the whole tree.
    var parentOf = new Map();
    for (i = 0; i < subGraphs.length; i += 1) {
      var members = subGraphs[i].nodes;
      for (var m = 0; m < members.length; m += 1) {
        if (!parentOf.has(members[m])) parentOf.set(members[m], subGraphs[i].id);
      }
    }

    var nodes = [];
    var nodeById = new Map();
    vertices.forEach(function (vertex, id) {
      // An id that names both a vertex and a subgraph is the container, not a leaf -- the same call
      // `addNodeFromVertex` makes when it sets `isGroup`.
      if (clusterById.has(id)) return;
      var node = {
        id: id,
        index: nodes.length,
        kind: "node",
        vertex: vertex,
        shape: db.getTypeFromVertex(vertex),
        parent: parentOf.has(id) ? parentOf.get(id) : null,
        inDeg: 0,
        outDeg: 0,
        edges: 0,
        incoming: [],
        rung: null
      };
      nodes.push(node);
      nodeById.set(id, node);
    });

    var clusters = [];
    var clusterNodeById = new Map();
    for (i = 0; i < subGraphs.length; i += 1) {
      var sg = subGraphs[i];
      var cluster = {
        id: sg.id,
        index: i,
        kind: "cluster",
        title: sg.title,
        sub: sg,
        parent: parentOf.has(sg.id) ? parentOf.get(sg.id) : null,
        children: [],
        depth: 0
      };
      clusters.push(cluster);
      clusterNodeById.set(sg.id, cluster);
    }

    function childFor(id) {
      if (clusterNodeById.has(id)) return clusterNodeById.get(id);
      if (nodeById.has(id)) return nodeById.get(id);
      return null;
    }

    for (i = 0; i < clusters.length; i += 1) {
      var list = clusters[i].sub.nodes;
      for (var c = 0; c < list.length; c += 1) {
        var child = childFor(list[c]);
        // `acc_title` and friends also land in a subgraph's statement list as bare strings; only
        // something that resolved to a vertex or to another subgraph is a member.
        if (child) clusters[i].children.push(child);
      }
    }

    // Top-level order comes from the vertices, in declaration order: the first leaf of a group puts
    // the whole group in that place. An alternative -- clusters first, then loose nodes -- reads as
    // two diagrams stacked, because the reading order stops matching the source.
    var rootChildren = [];
    var seen = new Map();
    function topOf(child) {
      var cur = child;
      for (var guard = 0; guard < 256 && cur.parent; guard += 1) {
        var next = clusterNodeById.get(cur.parent);
        if (!next) break;
        cur = next;
      }
      return cur;
    }
    for (i = 0; i < nodes.length; i += 1) {
      var top = topOf(nodes[i]);
      if (seen.get(top.id)) continue;
      seen.set(top.id, true);
      rootChildren.push(top);
    }
    for (i = 0; i < clusters.length; i += 1) {
      // An empty subgraph has no leaf to introduce it.
      if (clusters[i].parent === null && !seen.get(clusters[i].id)) {
        seen.set(clusters[i].id, true);
        rootChildren.push(clusters[i]);
      }
    }

    for (i = 0; i < clusters.length; i += 1) {
      var depth = 0;
      var walk = clusters[i].parent;
      for (var guard2 = 0; guard2 < 256 && walk; guard2 += 1) {
        depth += 1;
        var parentCluster = clusterNodeById.get(walk);
        walk = parentCluster ? parentCluster.parent : null;
      }
      clusters[i].depth = depth;
    }

    // Levels, keyed by cluster id with "" for the root. Each is laid out on its own, which is what
    // keeps a subgraph's members together: they are never candidates for a rank outside it.
    var levels = new Map();
    function level(id, dir, children) {
      var lv = { id: id, dir: dir, children: children, edges: [] };
      levels.set(id, lv);
      return lv;
    }
    level("", rootDirection, rootChildren);
    for (i = 0; i < clusters.length; i += 1) {
      var parentDir = rootDirection;
      if (clusters[i].parent && levels.has(clusters[i].parent)) parentDir = levels.get(clusters[i].parent).dir;
      // `direction LR` inside a subgraph is the author changing the axis for that box only, and the
      // parser keeps it unnormalised ('TD' where the top-level statement stores 'TB').
      level(clusters[i].id, normaliseDirection(clusters[i].sub.dir, parentDir), clusters[i].children);
    }
    // A nested subgraph declared before its parent takes the parent's direction, so the inherited
    // value is settled in declaration order and then corrected once the parents are all known.
    for (i = clusters.length - 1; i >= 0; i -= 1) {
      var lv2 = levels.get(clusters[i].id);
      if (clusters[i].sub.dir !== undefined && clusters[i].sub.dir !== null) continue;
      var inherit = clusters[i].parent && levels.has(clusters[i].parent)
        ? levels.get(clusters[i].parent).dir
        : rootDirection;
      lv2.dir = inherit;
    }

    var edges = [];
    var warnings = [];
    for (i = 0; i < rawEdges.length; i += 1) {
      var raw = rawEdges[i];
      var fromChild = childFor(raw.start);
      var toChild = childFor(raw.end);
      if (!fromChild || !toChild) {
        if (warnings.indexOf("edge-endpoint-missing") === -1) warnings.push("edge-endpoint-missing");
        continue;
      }
      // An open link (`---`, `-.-`, `===`, any length, labelled or not) has no head at either end.
      // `destructEdgeType` cannot say so -- it is mermaid's, and defaults the end to `arrow_point`
      // -- and mermaid itself corrects it one step later, in `getData` (`arrowTypeEnd: invisible ?
      // "none"` above, where `invisible` includes `arrow_open`). This projection called the helper
      // without that step, so every open link was drawn as an arrow: 6 of 6 in the held-out review,
      // and 12 of the 39 drawn forms in the link-form table in render.spec.js. Fixing the helper
      // instead was rejected: it is kept line for line with flowDb.reference.ts, whose vendored
      // specs read it through `getData`, and mermaid's own default is what `getData` corrects.
      var arrows = raw.type === "arrow_open"
        ? { arrowTypeStart: "none", arrowTypeEnd: "none" }
        : db.destructEdgeType(raw.type);
      var edge = {
        id: raw.id,
        index: edges.length,
        from: fromChild.id,
        to: toChild.id,
        fromChild: fromChild,
        toChild: toChild,
        raw: raw,
        // `---` is one rank, `----` two, `-----` three: mermaid reads the link's own length as a
        // minimum span and so does this, or the author's spacing silently stops meaning anything.
        minLen: Math.max(1, Math.min(10, Number(raw.length) || 1)),
        pattern: raw.stroke === "dotted" ? "dotted" : (raw.stroke === "invisible" ? "invisible" : "solid"),
        thickness: raw.stroke === "thick" ? "thick" : "normal",
        arrowStart: arrows.arrowTypeStart,
        arrowEnd: arrows.arrowTypeEnd,
        kind: null
      };
      edges.push(edge);

      var fromNode = nodeById.get(raw.start);
      var toNode = nodeById.get(raw.end);
      // Degree is counted over leaves only. An edge that names a subgraph attaches to the container
      // and says nothing about any one node inside it, so letting it raise a member's degree would
      // hand `fp-entry` to whichever node happened to be listed first.
      if (fromNode) { fromNode.outDeg += 1; fromNode.edges += 1; }
      if (toNode) { toNode.inDeg += 1; toNode.edges += 1; }
      if (toNode) toNode.incoming.push(edge);
      edge.countsForRung = !!(fromNode && toNode);

      // Which level draws it: the lowest subgraph containing both ends. An edge wholly inside a
      // subgraph is that subgraph's business; one that leaves it is the parent's, and connects the
      // container to whatever is outside.
      if (raw.start === raw.end) {
        edge.level = fromChild.parent === null ? "" : fromChild.parent;
        edge.a = fromChild;
        edge.b = fromChild;
        edge.selfLoop = true;
      } else {
        var fa = ancestry(fromChild.id, parentOf);
        var fb = ancestry(toChild.id, parentOf);
        var ai = fa.length - 1;
        var bi = fb.length - 1;
        while (ai > 0 && bi > 0 && fa[ai - 1] === fb[bi - 1]) { ai -= 1; bi -= 1; }
        edge.selfLoop = false;
        if (ai === 0 || bi === 0) {
          // `s1 --> A` where A is inside s1: one end is the other's ancestor, so there is no pair of
          // level-mates to rank against each other. It keeps its two boxes and gets its ports from
          // the geometry; ranking it would mean ranking a container against its own contents, which
          // has no answer rather than a hard one.
          edge.boundary = true;
          edge.level = (ai === 0) ? fromChild.id : toChild.id;
          edge.a = fromChild;
          edge.b = toChild;
        } else {
          edge.level = fa[ai];
          edge.a = childFor(fa[ai - 1]);
          edge.b = childFor(fb[bi - 1]);
        }
      }
      var target = levels.get(edge.level);
      if (target && !edge.boundary && edge.a && edge.b) target.edges.push(edge);
    }

    return {
      nodes: nodes,
      nodeById: nodeById,
      clusters: clusters,
      clusterById: clusterNodeById,
      parentOf: parentOf,
      levels: levels,
      edges: edges,
      warnings: warnings
    };
  }

  // ===========================================================================
  // One level of the layered layout.
  //
  // Ranks, then an order within each rank that reduces crossings, then coordinates. Deliberately
  // the textbook shape and deliberately O(n²) in the ordering and the positioning passes:
  // diagram-design budgets nine nodes and twelve edges per diagram (SKILL.md §7), so the whole
  // level fits in a cache line and a pass that can be read beats one that has to be trusted.
  //
  // Everything here counts on two axes named for their job rather than for the page: R runs across
  // the ranks and O runs along them. Which of x and y each becomes is one switch at the end, which
  // is what lets TD, BT, LR and RL share every line above it -- and, crucially, keeps a node's
  // width the width of its label in all four, where transposing the finished drawing would rotate
  // the boxes with it.
  // ===========================================================================

  // §7.2: an edge leaves and arrives perpendicular to the boundary by a fixed stub, so the
  // arrowhead meets the node square-on rather than grazing it.
  var STUB = 2;
  // SKILL.md §6 rule 3: two connectors that run parallel must stay ≥12px apart along their whole
  // length or the reader cannot trace either one.
  var LANE_GAP = 3;
  // What an ARRIVING edge needs between the face it lands on and the last place it may turn, where
  // STUB is what a LEAVING one needs. The two ends are not symmetric because only one of them
  // carries an arrowhead: the head is 8px long with its reference at the tip (`markerWidth 8`,
  // `refX 8`, in `markerMarkup`), so it eats the last 8px of the path, and a corner one stub from the
  // face leaves 8 - cornerRadius = 4px of line under it. Six units is 24px, and cornerRadius caps
  // at two units, so the leg spends 8px on the fillet, shows 8px of shaft, and gives the last 8px
  // to the head.
  //
  // Rendered at 1x and at 2x through DiagramExporter and looked at side by side: the two-subgraph
  // drawing's `worker --> web` arrival at five settings of this. At 4px of straight -- what shipped
  // for that edge -- the head and the elbow arc are one shape and the head reads as a barb hanging
  // off the horizontal run rather than as the end of a line. At 12px the arc still lets go inside
  // the head's own length. At 16px, this value, the head reads as head-plus-stem,
  // the same as the straight `web --> router` arrival beside it. At 20 and 24px nothing further is
  // legible and the corpus costs a further 2.4% and 4.7% of drawing area.
  var ARRIVE = 6;
  // SKILL.md §6 rule 2 asks for 6-10px between a label's mask and the stroke it annotates, and
  // `LABEL_GAP_PX` below is the 8 that satisfies it. It is stated here, in grid units, because the
  // LAYOUT is now the first thing that needs it: a label that has to sit 8px off its own stroke has
  // to be given 8px to sit in, and only the layout can hand out room.
  var LABEL_GAP = 2;
  // How long a marker is along its route, in grid units: `markerMarkup` draws every one 8 wide. The
  // placer charges an ON plate within LABEL_GAP of where the head begins, so a gap sized for plates
  // ON their lines has to hold this too.
  var HEAD = 2;

  // How far apart one face's ends have to stand for each labelled one to have a seat: its plate ON
  // its own line, in the same column as its neighbours' plates, with rule 2's gap between plates.
  // That is the plate's extent across the run plus LABEL_GAP -- 32px under a one-line 24px plate --
  // and 0 where a face needs nothing of the kind.
  //
  // Measured from the runs up, not tuned to a drawing: before this, a face of two or three labelled
  // ends stood at MIN_PITCH (12px) and one of four at BUSY_PITCH (24px), and neither holds a 24px
  // plate in a column. The second held-out set's b04 ran three links between one pair of nodes 24,
  // 20 and 12px apart, and its plates could only stagger along the gap -- the width -- or float off
  // their lines. `c5fe0f4` lined the plates up and could not seat them; the room has to exist
  // before the placer looks. Over the three review sets plates with a labelled run closer than
  // plate + 8 went 115 to 80 and over the 320-drawing sweep 65 to 38; b04 went 1696x296 to
  // 1416x320.
  //
  // Only where a plate is shorter across its run than along it, which is a horizontal level's
  // one-line labels. In TD a plate is across a vertical run by its WIDTH, and a column of them
  // would push a face apart by whole label widths where stacking them along the gap costs a
  // plate's height each. Rejected, by `c5fe0f4`'s measurement: 48px on every labelled face of four
  // ends (b04 1416x368), and the busy pitch for three links to one neighbour (b04 1544x324 and a
  // label-crowded warning) -- the first pays twice the height this does, the second does not seat.
  //
  // An edge labelled on its corridor carries no plate at this face, so it is not counted.
  function seatPitch(edges, runsAlongX) {
    var labelled = 0, across = 0, along = 0;
    for (var s = 0; s < edges.length; s += 1) {
      var sb = edges[s].labelBox;
      if (!sb || (runsAlongX && edges[s].chain && edges[s].chain.length > 2)) continue;
      labelled += 1;
      across = Math.max(across, runsAlongX ? sb.h : sb.w);
      along = Math.max(along, runsAlongX ? sb.w : sb.h);
    }
    if (labelled < 2 || across >= along) return 0;
    return across + LABEL_GAP;
  }

  // What one end's plate takes across the run, or 0 where the end has none at this face.
  function plateAcross(edge, runsAlongX) {
    var sb = edge.labelBox;
    if (!sb || (runsAlongX && edge.chain && edge.chain.length > 2)) return 0;
    return runsAlongX ? sb.h : sb.w;
  }

  // The seat paid gap by gap, `edges` in the order they stand on the face, or null where
  // `seatPitch` asks nothing: a gap beside a plate is that plate's own seat, the taller of the two
  // where both have one, and a gap between two bare ends keeps the face's. Paid face by face, the
  // tallest plate set every gap: c17's Slack, seven one-line plates and one two-line one, stood
  // 352px tall at 48px a gap where the one-line pairs need 32.
  //
  // Measured and refused, the bare gaps any narrower. At 12px c14's Draft went 208 to 168 and its
  // "request changes" off its line: a face that short ends above In review's port, and the router
  // swaps that end with "delete (admins only)" and hops it. A plate beside a bare end at half its
  // extent plus LABEL_GAP took c05's 同行评审 144 to 136, and b14's PLC gateway 112 to 104 with its
  // line to the first robot laid along two boxes' tops and six hops.
  function seatGaps(edges, runsAlongX) {
    var seat = seatPitch(edges, runsAlongX);
    if (seat === 0) return null;
    var gaps = [];
    for (var k = 0; k + 1 < edges.length; k += 1) {
      var wider = Math.max(plateAcross(edges[k], runsAlongX), plateAcross(edges[k + 1], runsAlongX));
      gaps.push(wider === 0 ? seat : wider + LABEL_GAP);
    }
    return gaps;
  }

  // The longest run `seatGaps` can ask of these ends in any order, for `layoutLevel`, which sizes a
  // face before anything has ordered it. A gap beside a plate is at most the taller plate's seat,
  // and each plate stands beside at most two gaps, so the plates' seats, each counted twice, the
  // largest first, bound the gaps beside plates; the rest are bare.
  function seatSpan(edges, runsAlongX) {
    var seat = seatPitch(edges, runsAlongX);
    var N = edges.length;
    if (seat === 0) return 0;
    var charges = [];
    for (var k = 0; k < N; k += 1) {
      var h = plateAcross(edges[k], runsAlongX);
      if (h > 0) charges.push(h + LABEL_GAP, h + LABEL_GAP);
    }
    charges.sort(function (a, b) { return b - a; });
    var beside = Math.min(N - 1, charges.length);
    var span = (N - 1 - beside) * seat;
    for (k = 0; k < beside; k += 1) span += charges[k];
    return span;
  }

  function layoutLevel(level, env) {
    var vertical = (level.dir === "TB" || level.dir === "BT");
    var children = level.children;
    var n = children.length;
    var i, j;

    var items = [];
    for (i = 0; i < n; i += 1) {
      var child = children[i];
      child.slot = i;
      items.push({
        ref: child,
        dummy: false,
        oSize: vertical ? child.w : child.h,
        rSize: vertical ? child.h : child.w,
        rank: 0
      });
    }

    var proper = [];
    var adj = [];
    for (i = 0; i < n; i += 1) adj.push([]);
    for (i = 0; i < level.edges.length; i += 1) {
      var e = level.edges[i];
      e.selfLoopInLevel = e.selfLoop || e.a === e.b;
      if (e.selfLoopInLevel) continue;
      proper.push(e);
      adj[e.a.slot].push({ to: e.b.slot, edge: e });
    }

    // Cycles are broken by marking the back edges of a depth-first walk in source order. The walk is
    // an explicit stack rather than recursion because the spec's node limit is 5000 (RENDERER-SPEC.md §8.1) and a chain
    // that long would be a stack overflow reported as a render failure.
    var state = [];
    for (i = 0; i < n; i += 1) state.push(0);
    for (i = 0; i < n; i += 1) {
      if (state[i] !== 0) continue;
      state[i] = 1;
      var stack = [{ at: i, next: 0 }];
      while (stack.length > 0) {
        var top = stack[stack.length - 1];
        if (top.next >= adj[top.at].length) { state[top.at] = 2; stack.pop(); continue; }
        var link = adj[top.at][top.next];
        top.next += 1;
        if (state[link.to] === 1) { link.edge.reversed = true; continue; }
        if (state[link.to] === 2) continue;
        state[link.to] = 1;
        stack.push({ at: link.to, next: 0 });
      }
    }

    // Longest path over the acyclic orientation: a node sits one rank (or `minLen` ranks, for a
    // `----` link) below the lowest thing that reaches it.
    var rank = [];
    var indeg = [];
    var succ = [];
    for (i = 0; i < n; i += 1) { rank.push(0); indeg.push(0); succ.push([]); }
    for (i = 0; i < proper.length; i += 1) {
      var pe = proper[i];
      var from = pe.reversed ? pe.b.slot : pe.a.slot;
      var to = pe.reversed ? pe.a.slot : pe.b.slot;
      succ[from].push({ to: to, len: pe.minLen });
      indeg[to] += 1;
    }
    var queue = [];
    for (i = 0; i < n; i += 1) if (indeg[i] === 0) queue.push(i);
    var head = 0;
    while (head < queue.length) {
      var at = queue[head];
      head += 1;
      for (j = 0; j < succ[at].length; j += 1) {
        var s = succ[at][j];
        if (rank[at] + s.len > rank[s.to]) rank[s.to] = rank[at] + s.len;
        indeg[s.to] -= 1;
        if (indeg[s.to] === 0) queue.push(s.to);
      }
    }
    for (i = 0; i < n; i += 1) items[i].rank = rank[i];

    // A busy face's room, now that ranks say which face each end lands on.
    //
    // The pass in `layout` sized every node for max(in, out) at rule 4's 12px, before ranks existed,
    // and said so: a cycle that brings ends back onto the face its out-edges leave from is left at
    // whatever pitch remains. That is the face the held-out review ranked first. h04's Advertising
    // was sized for five ends and carried six on its right face -- four back edges in, two edges out
    // -- at 12px along a 256px straight run, three of the six labelled; h20's Closed took seven ends
    // at 12px on a stadium sized for exactly that. A plate on a line in such a bundle is 24px tall,
    // so at a 12px pitch it covers the line either side, and BESIDE there is no gap to stand in.
    // `slopesOf` gave a busy VERTEX two pitches per port by spreading over slopes it already had; a
    // flat face has nothing spare -- `17c84b4` measured these faces full at the pitch -- so the face
    // grows until its landing run holds BUSY_PITCH between neighbours.
    //
    // Chosen over a trunk, which merges the ends before the face into one stroke and one head. It
    // keeps 12px but changes what the drawing says -- a junction no source wrote -- and it moves the
    // labels' problem rather than solving it: every label still has to sit on a branch, and the
    // branches meet where the bundle was. What growing costs, measured: h04's drawing went from
    // 2392x388 to 2316x392 (Advertising 72px to 136px tall), h20's and h19's kept their size (Closed
    // 96px to 200px wide), and the 204-drawing sweep did not change, because none of its faces with
    // four or more ends carries a label.
    //
    // Across a horizontal level, only a face that some end ARRIVES at. Both faces the review named
    // are arrivals -- Advertising's four back edges, Closed's seven -- and there the heads are what
    // stand 12px apart. A face every end leaves from carries no head, and in LR its lines part where
    // they turn up or down toward their targets, so each plate stands on a vertical run of its own;
    // growing the face bought nothing but height. The third held-out set's c11 drew its IVR menu,
    // seven ends all leaving, as a 160px pillar against Pele's 48 -- 96px without the growth, the
    // label "성공" back on its line, and nothing else in the 60 held-out drawings changed by a byte.
    // Not in TD, where the same growth widens a box -- which reads as a box, not a pillar -- and
    // without it `keyed menu`'s plates ride horizontal turns 12px apart and warn label-crowded.
    {
      var ends = [];
      for (i = 0; i < n; i += 1) ends.push({ lo: 0, hi: 0, loL: false, hiL: false, loA: false, hiA: false, loE: [], hiE: [] });
      for (i = 0; i < proper.length; i += 1) {
        var be = proper[i];
        var rA = rank[be.a.slot], rB = rank[be.b.slot];
        if (rA === rB) continue;
        var labelled = !!be.labelBox;
        var low = rA < rB ? be.a.slot : be.b.slot;
        var high = rA < rB ? be.b.slot : be.a.slot;
        ends[low].hi += 1; if (labelled) ends[low].hiL = true;
        ends[high].lo += 1; if (labelled) ends[high].loL = true;
        if (be.b.slot === low) ends[low].hiA = true; else ends[high].loA = true;
        // Not `chain`, which does not exist yet: a horizontal edge spanning ranks is labelled on its
        // corridor, so it is no plate at this face.
        var seatable = { labelBox: (!vertical && Math.abs(rA - rB) > 1) ? null : be.labelBox };
        ends[low].hiE.push(seatable);
        ends[high].loE.push(seatable);
      }
      for (i = 0; i < n; i += 1) {
        var bc = children[i];
        if (bc.kind !== "node") continue;
        var bg = geometryOf(bc.shape);
        var sides = FORWARD_SIDES[level.dir] || FORWARD_SIDES.TB;
        var want = [
          [ends[i].hi, ends[i].hiL && (vertical || ends[i].hiA), sides[0], ends[i].hiE],
          [ends[i].lo, ends[i].loL && (vertical || ends[i].loA), sides[1], ends[i].loE]
        ];
        for (var wi = 0; wi < 2; wi += 1) {
          var bn = want[wi][0];
          var bp = (bn >= BUSY_N && want[wi][1]) ? BUSY_PITCH * (bn - 1) : 0;
          // And a face with two or more labelled ends grows until each has a seat (`seatGaps`): the
          // pitches `facePitches` will ask of it are only usable if the run holds them.
          bp = Math.max(bp, seatSpan(want[wi][3], !vertical));
          if (bp === 0) continue;
          // Grown against the landing run rather than the box, because the run is what `placeFace`
          // spends: a stadium loses its two caps, and Closed sized as 8 x 24px of box still put its
          // seven ports 12-16px apart. A face whose run is one point is a vertex, `slopesOf`'s to
          // answer for. Bounded, and two units a step to keep the box even.
          for (var tries = 0; tries < 64; tries += 1) {
            var tb = { x: 0, y: 0, w: bc.w, h: bc.h };
            var tr = landingRun(bg, tb, want[wi][2], portSpan(bg, tb, want[wi][2]));
            if (tr.hi === tr.lo) break;
            if (tr.hi - tr.lo >= bp) break;
            if (bg === "circle" || bg === "doublecircle") { bc.w += 2; bc.h = bc.w; }
            else if (vertical) bc.w += 2;
            else bc.h += 2;
          }
        }
        items[i].oSize = vertical ? bc.w : bc.h;
        items[i].rSize = vertical ? bc.h : bc.w;
      }
    }

    var maxRank = 0;
    for (i = 0; i < n; i += 1) if (rank[i] > maxRank) maxRank = rank[i];

    // An edge spanning more than one rank gets a chain of dummies, one per rank it passes through.
    // Without them the intervening rank has no idea the edge is there and packs a node into the
    // corridor, which is SKILL.md §6 rule 5 -- a connector passing behind a box that is neither of
    // its endpoints -- produced by the layout rather than by the router.
    for (i = 0; i < proper.length; i += 1) {
      var pe2 = proper[i];
      var ra = rank[pe2.a.slot];
      var rb = rank[pe2.b.slot];
      var lo = Math.min(ra, rb);
      var hi = Math.max(ra, rb);
      var lowSlot = (ra <= rb) ? pe2.a.slot : pe2.b.slot;
      var highSlot = (ra <= rb) ? pe2.b.slot : pe2.a.slot;
      pe2.lowRank = lo;
      pe2.highRank = hi;
      pe2.chain = [lowSlot];
      for (var r = lo + 1; r < hi; r += 1) {
        pe2.chain.push(items.length);
        // Two units wide, so the corridor has a centre that is still a whole unit; zero deep, so it
        // cannot make the rank band it passes through any taller than its real nodes need.
        items.push({ ref: null, dummy: true, oSize: 2, rSize: 0, rank: r, edge: pe2 });
      }
      pe2.chain.push(highSlot);
    }

    var m = items.length;
    var segments = [];
    for (i = 0; i < proper.length; i += 1) {
      var chain = proper[i].chain;
      for (j = 0; j + 1 < chain.length; j += 1) {
        segments.push({ u: chain[j], v: chain[j + 1], edge: proper[i], gap: items[chain[j]].rank });
      }
    }

    var nbrUp = [];
    var nbrDown = [];
    for (i = 0; i < m; i += 1) { nbrUp.push([]); nbrDown.push([]); }
    for (i = 0; i < segments.length; i += 1) {
      nbrDown[segments[i].u].push(segments[i].v);
      nbrUp[segments[i].v].push(segments[i].u);
    }

    // --- order within each rank -------------------------------------------
    var layers = [];
    for (i = 0; i <= maxRank; i += 1) layers.push([]);
    var placed = [];
    for (i = 0; i < m; i += 1) placed.push(false);
    // Seeded breadth-first from rank 0 in source order so a chain starts out already untangled and
    // the sweeps have something sane to improve, rather than the declaration order of a list that
    // has dummies appended to the end of it.
    var bfs = [];
    for (i = 0; i < m; i += 1) if (items[i].rank === 0) bfs.push(i);
    head = 0;
    while (head < bfs.length) {
      var node = bfs[head];
      head += 1;
      if (placed[node]) continue;
      placed[node] = true;
      layers[items[node].rank].push(node);
      for (j = 0; j < nbrDown[node].length; j += 1) if (!placed[nbrDown[node][j]]) bfs.push(nbrDown[node][j]);
      for (j = 0; j < nbrUp[node].length; j += 1) if (!placed[nbrUp[node][j]]) bfs.push(nbrUp[node][j]);
    }
    for (i = 0; i < m; i += 1) {
      if (placed[i]) continue;
      placed[i] = true;
      layers[items[i].rank].push(i);
    }

    // --- the ends outside the level ---------------------------------------
    // A zone is laid out on its own, before anything outside it is placed, so an edge that leaves
    // it is not in this level at all: it belongs to the level holding both ends, which sees only
    // the zone's box. Left at that, the order inside a zone is whatever its own edges say, and a
    // zone with none says nothing -- 02's Data zone has no edge inside it, so Postgres, Redis and S3
    // stood in declaration order and Auth -> Redis crossed both edges into Postgres.
    //
    // `level.outside` names, for each edge whose far end is on the rank side the level reads from,
    // which child the edge reaches and where its far end stands, as an ordinal along this level's
    // O axis (see `outsideOf`). Each becomes a node of a fixed rank in front of rank 0, with one
    // ordering-only dummy per rank between it and its child, the same chain a long edge inside the
    // level gets. So the sweeps, `transpose` and the count below see those edges as edges, and an
    // outside end that two edges share is one node, which crosses neither. None of it survives the
    // ordering: the ids are past `m`, the rank is index 0 of the ordering's layers, and both are
    // dropped before a coordinate is given out. With no outside ends the extra rank is empty and
    // every step below does what it did without it.
    //
    // Rejected: keeping every one of those dummies as a real item, so that the zone reserves each
    // edge a corridor the way it does a long edge. On 02 it took iOS -> API Gateway off CDN and drew
    // no crossing, but the corridors for iOS and Android sat below CDN, both edges climbed to the
    // gateway's left tip at the last turn allowed before it, and the two shared 8px of one vertical
    // -- there is room between CDN's clearance and that turn for one climb, not two. Letting every
    // corridor pull its child as well bent `subgraph s[Tier] W --> R end / K --> R` (straight.spec.js)
    // and made 14's two thick edges into the queue cross twice (braid.spec.js). What survives of the
    // idea is narrower, and is `coLayers` below: one corridor per child, and only where it is the
    // child's median.
    var M = m;
    var farAt = new Map();
    var ordUp = [];
    var ordDown = [];
    for (i = 0; i < m; i += 1) { ordUp.push(nbrUp[i].slice()); ordDown.push(nbrDown[i].slice()); }
    var ordSegs = [];
    for (i = 0; i < segments.length; i += 1) {
      ordSegs.push({ u: segments[i].u, v: segments[i].v, gap: segments[i].gap + 1 });
    }
    layers.unshift([]);
    var outside = level.outside || [];
    var slotOf = new Map();
    for (i = 0; i < n; i += 1) slotOf.set(children[i].id, i);
    var farNode = new Map();
    for (i = 0; i < outside.length; i += 1) {
      var far = outside[i];
      if (!slotOf.has(far.child)) continue;
      var reach = slotOf.get(far.child);
      if (!farNode.has(far.at)) {
        farNode.set(far.at, M);
        farAt.set(M, far.at);
        ordUp.push([]); ordDown.push([]);
        layers[0].push(M);
        M += 1;
      }
      var tail = farNode.get(far.at);
      for (var ol = 1; ol <= items[reach].rank + 1; ol += 1) {
        var hop = reach;
        if (ol <= items[reach].rank) {
          hop = M;
          ordUp.push([]); ordDown.push([]);
          layers[ol].push(M);
          M += 1;
        }
        ordDown[tail].push(hop);
        ordUp[hop].push(tail);
        ordSegs.push({ u: tail, v: hop, gap: ol - 1 });
        tail = hop;
      }
    }
    // Far ends in O order: the fixed rank is never reordered, so this is the order it keeps.
    layers[0].sort(function (p, q) { return farAt.get(p) - farAt.get(q); });

    function positionsOf(ls) {
      var pos = [];
      for (var a = 0; a < M; a += 1) pos.push(0);
      for (var b = 0; b < ls.length; b += 1) for (var c = 0; c < ls[b].length; c += 1) pos[ls[b][c]] = c;
      return pos;
    }

    function crossings(ls) {
      var pos = positionsOf(ls);
      var total = 0;
      for (var g = 0; g + 1 < ls.length; g += 1) {
        var here = [];
        for (var a = 0; a < ordSegs.length; a += 1) {
          if (ordSegs[a].gap !== g) continue;
          here.push([pos[ordSegs[a].u], pos[ordSegs[a].v]]);
        }
        for (var b = 0; b < here.length; b += 1) {
          for (var c = b + 1; c < here.length; c += 1) {
            if ((here[b][0] - here[c][0]) * (here[b][1] - here[c][1]) < 0) total += 1;
          }
        }
      }
      return total;
    }

    function copyLayers(ls) {
      var out = [];
      for (var a = 0; a < ls.length; a += 1) out.push(ls[a].slice());
      return out;
    }

    function sweep(ls, down) {
      var pos = positionsOf(ls);
      // Index 0 is the fixed rank of outside ends: read from, never sorted.
      var from = down ? 1 : ls.length - 2;
      var stop = down ? ls.length : 0;
      var step = down ? 1 : -1;
      for (var r2 = from; r2 !== stop; r2 += step) {
        var layer = ls[r2];
        var keyed = [];
        for (var a = 0; a < layer.length; a += 1) {
          var id = layer[a];
          var fixed = down ? ordUp[id] : ordDown[id];
          var sum = 0;
          for (var b = 0; b < fixed.length; b += 1) sum += pos[fixed[b]];
          // A node with nothing in the fixed rank keeps where it is; moving it would be noise, and
          // noise in a sort is how a stable layout stops being stable.
          keyed.push({ id: id, key: fixed.length ? sum / fixed.length : a, at: a });
        }
        keyed.sort(function (p, q) {
          if (p.key !== q.key) return p.key - q.key;
          return p.at - q.at;
        });
        for (var c = 0; c < keyed.length; c += 1) { layer[c] = keyed[c].id; pos[keyed[c].id] = c; }
      }
    }

    // Crossings between u and v, with u before v, against both of the ranks beside theirs -- the
    // only crossings that swapping two neighbours can change, so it is the whole of the question
    // and costs deg(u)·deg(v) instead of a recount of the level.
    function pairCost(pos, u, v) {
      var total = 0;
      for (var side = 0; side < 2; side += 1) {
        var nu = side ? ordDown[u] : ordUp[u];
        var nv = side ? ordDown[v] : ordUp[v];
        for (var a = 0; a < nu.length; a += 1) {
          for (var b = 0; b < nv.length; b += 1) if (pos[nu[a]] > pos[nv[b]]) total += 1;
        }
      }
      return total;
    }

    // Swap neighbours while a swap strictly lowers the crossings, until a pass swaps nothing.
    // Strictly, so a tie keeps the order the sweep gave it and two equal pairs cannot trade places
    // forever; each swap lowers a non-negative count, so the loop ends without a guard.
    function transpose(ls) {
      var pos = positionsOf(ls);
      var improved = true;
      while (improved) {
        improved = false;
        for (var r2 = 1; r2 < ls.length; r2 += 1) {
          var layer = ls[r2];
          for (var k = 0; k + 1 < layer.length; k += 1) {
            var u = layer[k];
            var v = layer[k + 1];
            if (pairCost(pos, v, u) < pairCost(pos, u, v)) {
              layer[k] = v; layer[k + 1] = u;
              pos[v] = k; pos[u] = k + 1;
              improved = true;
            }
          }
        }
      }
    }

    // Eight barycentre sweeps from the breadth-first seed, each followed by `transpose`, the
    // adjacent-swap pass dot runs after its median one -- and then the same again from a few
    // shuffled seeds, keeping whichever order crosses least.
    //
    // Both halves are measured, against a search that runs median and barycentre sweeps with
    // `transpose` from 60 random starts. Over the 16 review sources the sweeps alone left 21
    // crossings where that search finds 12: 17 against 12 on `hard-dense`, and 2 against 0 on the
    // state machine and on the back-edge chain. 24 sweeps instead of 8 left all 21. Adding
    // `transpose` took `hard-dense` to 15 and nothing else: each of the three is a local minimum
    // that no single swap leaves, because what has to move is a whole chain of dummies from one
    // side of the drawing to the other. Median sweeps, both sweep directions first, and moving
    // each node to its best slot in the rank (sifting) were each tried on top and left 18 or 19.
    // Shuffled restarts are what reach it: one, two and three of them leave 16, 14 and 13, four
    // reach 12, and eight -- the number here -- are four of margin. Seeds reversed rank by rank
    // reached 0 on the two small ones and only 15 on `hard-dense`, which is why they are shuffled.
    //
    // The shuffle is the Park-Miller sequence from a fixed seed, exact in a double, so the drawing
    // is the same every time. Only a strictly lower count replaces the breadth-first answer, and
    // nothing runs once it is zero, so a drawing the sweeps already untangle is drawn exactly as
    // before: over the 172-drawing sweep the count stays at 4, which the 60-start search cannot
    // lower either.
    // Restarts stop at 256 segments, where the recount each sweep pays is 32k pairs; past that a
    // level keeps the one breadth-first run, which is everything it had before.
    var seeded = copyLayers(layers);
    var best = copyLayers(layers);
    var bestCross = crossings(layers);
    var seed = 1;
    var RESTARTS = ordSegs.length <= 256 ? 8 : 0;
    for (var start = 0; start <= RESTARTS && bestCross > 0; start += 1) {
      if (start > 0) {
        layers = copyLayers(seeded);
        for (i = 1; i < layers.length; i += 1) {
          for (j = layers[i].length - 1; j > 0; j -= 1) {
            seed = (seed * 48271) % 2147483647;
            var pick = seed % (j + 1);
            var held = layers[i][j]; layers[i][j] = layers[i][pick]; layers[i][pick] = held;
          }
        }
      }
      for (i = 0; i < 8 && bestCross > 0; i += 1) {
        sweep(layers, (i % 2) === 0);
        transpose(layers);
        var cross = crossings(layers);
        if (cross < bestCross) { bestCross = cross; best = copyLayers(layers); }
      }
    }
    layers = [];
    for (i = 1; i < best.length; i += 1) {
      layers.push(best[i].filter(function (id) { return id < m; }));
    }
    // --- the one outside corridor a member sits on ------------------------
    // With the dummies above dropped, the coordinates below line a member up with its neighbours
    // INSIDE the zone and nothing else. On 02 that put API Gateway level with CDN, its one inside
    // neighbour, so CDN stood where iOS -> API Gateway has to pass; the edge climbed over CDN and took
    // a bridge over Web -> CDN and another over CDN -> Gateway. Pele draws that side with none.
    //
    // So a member whose median neighbour in the rank before it is an OUTSIDE end keeps that one
    // corridor for its coordinates: a ghost item in each rank the edge passes, two units wide like a
    // long edge's dummy, which the coordinate passes pin to the member's centre (`pinned` below)
    // and pack the real items around. API Gateway's neighbours, in order, are CDN, iOS and Android;
    // iOS is the median, so the gateway sits on iOS's line and CDN steps aside by one node gap.
    // Android's corridor is not kept: two corridors into one face are the 8px-shared climb the
    // rejection above describes, and it is the median alone that a straight run is owed.
    //
    // The median, not the mean, and an even count with an inside neighbour in the middle pair goes
    // to the inside one -- which is what keeps `W --> R / K --> R` straight, the case the rejected
    // pull bent. Two edges to one far end are one neighbour: 14's Worker West A has Router West
    // inside and the replicate pair outside, and counting the pair twice made it the median, moved
    // East Region 4px and put the two failover lines one lane apart for most of their length.
    var bestPos = positionsOf(best);
    var kept = new Set();
    var anchoredTo = new Map();
    for (i = 2; i < best.length; i += 1) {
      for (j = 0; j < best[i].length; j += 1) {
        var child2 = best[i][j];
        if (child2 >= m) continue;
        var ups2 = ordUp[child2];
        if (!ups2.some(function (u) { return u >= m; })) continue;
        var seenFar = new Set();
        ups2 = ups2.filter(function (u) {
          if (u < m) return true;
          var top2 = u;
          while (!farAt.has(top2)) top2 = ordUp[top2][0];
          if (seenFar.has(top2)) return false;
          seenFar.add(top2);
          return true;
        });
        ups2.sort(function (p2, q2) { return bestPos[p2] - bestPos[q2]; });
        var h3 = ups2.length >> 1;
        var pick2 = -1;
        if (ups2.length % 2) pick2 = ups2[h3];
        else if ((ups2[h3 - 1] >= m) !== (ups2[h3] >= m)) pick2 = ups2[h3 - 1] >= m ? ups2[h3] : ups2[h3 - 1];
        if (pick2 < m) continue;
        anchoredTo.set(child2, pick2);
        for (var walk = pick2; walk >= m && !farAt.has(walk); walk = ordUp[walk][0]) kept.add(walk);
      }
    }
    var ghostOf = new Map();
    var coLayers = [];
    for (i = 1; i < best.length; i += 1) {
      var row = [];
      for (j = 0; j < best[i].length; j += 1) {
        var id2 = best[i][j];
        if (id2 < m) { row.push(id2); continue; }
        if (!kept.has(id2)) continue;
        ghostOf.set(id2, items.length);
        row.push(items.length);
        items.push({ ref: null, dummy: true, ghost: true, oSize: 2, rSize: 0, rank: i - 1 });
        nbrUp.push([]); nbrDown.push([]);
      }
      coLayers.push(row);
    }
    // A ghost has no neighbour before it (its far end is not in this level) and one after it, the
    // next ghost or the member, which is all the upward pass needs to pin it.
    ghostOf.forEach(function (gi, id) {
      var nx = ordDown[id][0];
      nbrDown[gi].push(nx < m ? nx : ghostOf.get(nx));
    });
    anchoredTo.forEach(function (g, child) { items[child].anchor = ghostOf.get(g); });

    for (i = 0; i < layers.length; i += 1) {
      for (j = 0; j < layers[i].length; j += 1) items[layers[i][j]].order = j;
    }

    // --- the room a label needs across the rank ---------------------------
    // An edge label does not sit ON its stroke, it sits BESIDE it (SKILL.md §6 rule 2, so the
    // connector stays traceable under its own annotation). In a TB level that stroke runs along the
    // rank axis, so the room its label needs runs ACROSS the rank -- the one axis nothing below
    // reserves. `gapLabel` reserves the other one, and reserving only that is what drew
    // `A -->|publishes an event| B` as a 128px-wide drawing with a 144px label hanging off the side
    // of it: measured over 79 sources, 41 of 88 labels came within rule 2's own 8px of a node, 22
    // within it of another label, and 8 were outside the viewBox altogether.
    //
    // The demand is stated centre to centre rather than as extra node spacing because the stroke
    // leaves from the middle of a face, not from its edge: a wide box and a narrow one leaving the
    // same gap between them leave the label different amounts of room, and the label is beside the
    // STROKE. `assignPorts` fans several connectors across a face afterwards, so this is the
    // corridor the run is in the middle of rather than the exact O it ends up at.
    //
    // BOTH ends claim it, not just the source. Which leg of a one-gap route the label lands beside
    // is `placeEdgeLabel`'s choice of the longest segment, and the two ends disagree about which
    // that is: a fork's arms share their source point and diverge at their targets, a fan-in does
    // the reverse. The two are close to a wash and this is the dearer of them: measured over 79
    // sources, claiming at the source alone costs 13.1% of drawing area against 13.8% and leaves
    // one more label inside rule 2's 8px of a stroke, 6 against 5. It is chosen for being the
    // statement that does not depend on which end of an edge the author happened to write first.
    //
    // Room on the OTHER side too, but only where a face carries two labelled runs into the same
    // gap. Reserving one side is enough for one label and cannot be enough for two: both of them
    // want the side the placer tries first, the second takes what is left, and on
    // `P -- "derivedQuoteId (representative)" --> Q / P -. "originalQuoteId" .-> Q` what was left
    // was a 136px mask lying across a 12px lane pitch with both strokes under it. The placer finds
    // the answer on its own once the room exists -- given an unbounded ownership weight it put that
    // mask at x=-84, 8px clear of its own line and 20px from the sibling, which is off a 232px
    // canvas by 84px. This is that 84px, asked for at layout time.
    //
    // Only the SECOND widest of a face's labels is claimed back here, not all of them: the widest
    // still goes on the first side, and a third label in one corridor is stacked along the run
    // rather than given a third side, which is what `placeEdgeLabel` does with the height it has.
    // Reserving both sides of EVERY run was measured and rejected at 18.5% of drawing area against
    // 13.8%; this is the same reserve spent only where one side is provably not enough. Measured
    // over the corpus it costs 3.6% of total area -- 7.95 Mpx to 8.24 -- and buys three masks their
    // ownership, one of them on a drawing the reader sent, where it was 40px nearer a connector
    // that was not its own. It also takes the last two masks out of rule 2's gap of a node and the
    // last two out of rule 2's gap of another mask.
    var labelRoom = [];
    var labelRoomBack = [];
    var perFace = [];
    for (i = 0; i < m; i += 1) { labelRoom.push(0); labelRoomBack.push(0); perFace.push(new Map()); }
    var claim = function (item, gap, extent) {
      var byGap = perFace[item];
      if (!byGap.has(gap)) byGap.set(gap, []);
      byGap.get(gap).push(extent);
    };
    for (i = 0; i < segments.length; i += 1) {
      var lseg = segments[i];
      if (lseg.gap >= maxRank) continue;
      var lbox = lseg.edge.labelBox;
      if (!lbox) continue;
      // The label's extent along O, which is its width in a TB or BT level and its height in an LR
      // or RL one -- the same switch `gapLabel` makes for the other axis, and for the same reason:
      // a box is not rotated when the drawing is.
      var oExtent = vertical ? lbox.w : lbox.h;
      claim(lseg.u, lseg.gap, oExtent);
      claim(lseg.v, lseg.gap, oExtent);
    }
    for (i = 0; i < m; i += 1) {
      perFace[i].forEach(function (extents, gap) {
        extents.sort(function (a, b) { return b - a; });
        if (extents[0] > labelRoom[this.i]) labelRoom[this.i] = extents[0];
        if (extents.length > 1 && extents[1] > labelRoomBack[this.i]) labelRoomBack[this.i] = extents[1];
      }, { i: i });
    }
    // Room for the labels on connectors that LEAVE the zone, which the claims above cannot see: those
    // runs are drawn by an outer level, so a zone's members were spaced as if they carried none. On
    // cand.mmd that is C2 and C3, each joined to its Nego by a labelled pair one 12px pitch apart --
    // a pair whose left label has to stand left of both lanes, because ON covers the sibling and
    // right of the left lane IS the sibling. The two columns were 256px apart centre to centre, and
    // in the app, at WebKit's widths, "negotiate(adjustRate, original)" went ON its line and erased
    // the dotted run beside it while "derivedQuoteId (representative)" lay across two strokes of the
    // O -> N1 bundle: 2 plates on foreign strokes, nearest 0px.
    //
    // A member is owed the widest such label plus one MIN_PITCH per leaving label: the sibling lanes
    // that stand between its column and the plate, and one more for LABEL_MARGIN_PX, which is the
    // same 3 units. Without that last one the plate fits but 8px from its own line and 8px from the
    // next, the placer prices that tie above ON, and the drawing kept 1 plate on a stroke.
    //
    // Only where a member has two or more: one leaving label has a free side, and claiming for it
    // was measured -- on `X -- "crosses the wall" --> I1` it moved I1 off X's line and put a
    // crossing under "returns",
    // whose middle then stood nearer X -> I2 than its own run. And only BETWEEN neighbours, not at
    // the level's outer edge: applied to the edge as well it widened single-column zones too, and
    // render.spec.js came back with 4 failures, one a new crossing on 12 crowded subgraphs.
    //
    // Measured: in the app cand.mmd goes from 608 to 696px wide (Pele draws it at 894), plates on
    // foreign strokes 2 to 0, nearest foreign stroke 0 to 20px, and C3's column now stands 24px off
    // N3's, which costs one doubled step: bends 8 to 12. differential.mjs, whose stand-in measurer
    // wraps those labels and so never saw the collision, moves only cand's area, 561,408 to 567,936
    // px². The 16 review sources are byte-identical, under the stand-in and under CoreText widths.
    var leavingRoom = [];
    for (i = 0; i < m; i += 1) {
      leavingRoom.push(0);
      if (!level.leaving || items[i].dummy) continue;
      var leaving = level.leaving.get(items[i].ref.id);
      if (!leaving || leaving.length < 2) continue;
      for (j = 0; j < leaving.length; j += 1) {
        leavingRoom[i] = Math.max(leavingRoom[i], (vertical ? leaving[j].w : leaving[j].h) + MIN_PITCH * leaving.length);
      }
    }
    // Which way the placer looks first, in this level's own O frame. `placeEdgeLabel` offers the
    // right of a vertical run and the top of a horizontal one before the other side, and `localOf`
    // maps O to +x in TB and BT and to +y in LR and RL with no flip anywhere -- so a vertical level
    // reserves at +O and a horizontal one at -O. Reserving BOTH sides of every run was measured and
    // rejected on the number -- 18.5% of drawing area against 13.8%, for a corridor the placer only
    // reaches when the first one is taken, and it took one label off a stroke to do it.
    var labelAfter = vertical;
    // Ghosts carry no label, so they claim the plain gap and nothing more.
    for (i = m; i < items.length; i += 1) { labelRoom.push(0); labelRoomBack.push(0); leavingRoom.push(0); }
    // The minimum distance between two neighbours' centres: what they need to not touch, or what the
    // label between them needs, whichever is larger. `a` is the earlier of the two along the rank.
    // One label between two neighbours needs a gap from its stroke and a gap from the neighbour, so
    // `room + 2 * LABEL_GAP`. Two -- one hanging back off the later neighbour, one hanging forward
    // off the earlier -- need a third gap between the two masks.
    //
    // Plus LABEL_MARGIN_PX where the label stands between two labelled COLUMNS: `a` and `b` each
    // carry a labelled run across the same gap, to two different nodes that are themselves
    // neighbours on the far rank. Those two runs are parallel for the whole gap, so a plate beside
    // the first has the second exactly one gap off its far edge and no slide along the run gets it
    // clear. In the app's widths nego.mmd's C2 -> N2 and C3 -> N3 stand 192px apart with a 176px
    // plate, 8 + 176 + 8: an ownership margin of 0, which the placer prices above ON, so those
    // two went ON while the other four went BESIDE and the picture carried both conventions. With
    // the margin the same two take a clean BESIDE and nego is uniform, 6 of 6, 24px wider.
    // `leavingRoom` already holds this pitch -- it is its "one more" -- so it is added only where
    // the in-level claim is the one that decided.
    //
    // Rejected: the margin on every forward claim. It made nego uniform too, and moved six of the
    // review's eighteen drawings to do it: cand.mmd went 696 -> 720px wide with 3 of its 9 labels
    // ON, because there the room was `leavingRoom`'s and the pitch was paid twice; 03, 07, 13 and
    // 16 moved; and the three-way labelled fan and its fan-in, TD and BT, came out with 4 masks
    // tied 8px from their own line and 8px from a sibling's. A fan's long runs are its lanes, not
    // its columns, so the extra room only rearranged which of its plates sat on a lane. Rejected
    // too: the same rule counting ghost corridors as columns, which still moved 03 (848 -> 888px)
    // and 07 (284 -> 288px) for no label of theirs.
    var facingColumns = function (a, b) {
      if (items[a].dummy || items[b].dummy) return false;
      for (var p = 0; p < segments.length; p += 1) {
        var sa = segments[p];
        if ((sa.u !== a && sa.v !== a) || !sa.edge.labelBox) continue;
        var pa = sa.u === a ? sa.v : sa.u;
        if (items[pa].dummy) continue;
        for (var q = 0; q < segments.length; q += 1) {
          var sb = segments[q];
          if ((sb.u !== b && sb.v !== b) || sb.gap !== sa.gap || !sb.edge.labelBox) continue;
          var pb = sb.u === b ? sb.v : sb.u;
          if (pa !== pb && !items[pb].dummy && items[pa].order + 1 === items[pb].order) return true;
        }
      }
      return false;
    };
    var centreSep = function (a, b) {
      var plain = (items[a].oSize + items[b].oSize) / 2 + env.spaceU;
      var own = labelAfter ? labelRoom[a] : labelRoomBack[a];
      var forward = Math.max(own, leavingRoom[a]);
      var backward = labelAfter ? labelRoomBack[b] : labelRoom[b];
      var need = 0;
      if (forward > 0) need += forward + LABEL_GAP;
      if (own > leavingRoom[a] && facingColumns(a, b)) need += MIN_PITCH;
      if (backward > 0) need += backward + LABEL_GAP;
      if (need > 0) need += LABEL_GAP;
      return Math.max(plain, need);
    };

    // --- coordinates along the rank (the O axis) --------------------------
    var oPos = [];
    for (i = 0; i < items.length; i += 1) oPos.push(0);
    for (i = 0; i < coLayers.length; i += 1) {
      var cursor = 0;
      for (j = 0; j < coLayers[i].length; j += 1) {
        var it = items[coLayers[i][j]];
        if (j > 0) {
          var prevIdx = coLayers[i][j - 1];
          cursor = oPos[prevIdx] + items[prevIdx].oSize / 2
            + centreSep(prevIdx, coLayers[i][j]) - it.oSize / 2;
        }
        oPos[coLayers[i][j]] = cursor;
      }
    }

    function centreOf(idx) {
      return oPos[idx] + items[idx].oSize / 2;
    }

    var segUp = [];
    var segDown = [];
    for (i = 0; i < m; i += 1) { segUp.push([]); segDown.push([]); }
    for (i = 0; i < segments.length; i += 1) {
      segDown[segments[i].u].push(segments[i]);
      segUp[segments[i].v].push(segments[i]);
    }
    // Where along this level's O axis an edge goes into a zone, measured from the zone's middle.
    // A zone is aligned by its middle, which is right while its members are centred in it and wrong
    // once a kept corridor has stepped one aside: on 02 the Edge zone's middle is 12px above API
    // Gateway, so iOS, level with the middle, jogged 12px down into the gateway and Gateway -> Order
    // Service jogged back up. Only a zone whose own layout pinned a corridor (`offCentre`) answers
    // with anything but 0, so every other level is aligned exactly as before. Applying it to every
    // zone was measured: it straightened 02 and 12's Storage -> Serving runs, but on cand it moved
    // Original onto Nego-H1's column and stacked three labels on its parallel lines, and on 14 it
    // doubled the failover pair.
    function attachO(seg, idx) {
      var zone = items[idx].ref;
      if (!zone || zone.kind !== "cluster" || !zone.offCentre) return 0;
      var e3 = seg.edge;
      var end3 = null;
      var ends3 = [e3.fromChild, e3.toChild];
      for (var k3 = 0; k3 < 2 && !end3; k3 += 1) {
        var cur3 = ends3[k3];
        var o3 = 0;
        for (var g3 = 0; g3 < 256 && cur3 && cur3 !== zone; g3 += 1) {
          o3 += vertical ? cur3.lx + (cur3 === ends3[k3] ? cur3.w / 2 : 0) : cur3.ly + (cur3 === ends3[k3] ? cur3.h / 2 : 0);
          var up3 = cur3.parent ? env.clusters.get(cur3.parent) : null;
          if (up3) o3 += vertical ? up3.contentDX : up3.contentDY;
          cur3 = up3;
        }
        if (cur3 === zone) end3 = o3;
      }
      if (end3 === null) return 0;
      return Math.round(end3 - (vertical ? zone.w : zone.h) / 2);
    }

    // Four alternating passes of: ask each node where its neighbours in the rank above (or below)
    // would like it, then walk the rank left to right honouring the minimum gap, then slide the
    // whole rank by the average of what everyone gave up. The straightforward alternative -- pack
    // each rank and centre it -- draws a fan as a block of boxes with the parent over the middle of
    // the block rather than over its own children, which is what the eye follows.
    for (var pass = 0; pass < 4; pass += 1) {
      var downward = (pass % 2) === 0;
      var order = [];
      for (i = 0; i < coLayers.length; i += 1) order.push(downward ? i : coLayers.length - 1 - i);
      for (var oi = 0; oi < order.length; oi += 1) {
        var lr = order[oi];
        var layer2 = coLayers[lr];
        if (!layer2.length) continue;
        var want = [];
        var pinned = [];
        for (i = 0; i < layer2.length; i += 1) {
          var idx = layer2[i];
          pinned.push(false);
          var fixed2 = downward ? nbrUp[idx] : nbrDown[idx];
          if (downward && items[idx].anchor !== undefined) {
            want.push(Math.round(centreOf(items[idx].anchor) - items[idx].oSize / 2));
            continue;
          }
          if (!fixed2.length) { want.push(oPos[idx]); continue; }
          if (items[idx].ghost) {
            want.push(Math.round(centreOf(fixed2[0]) - items[idx].oSize / 2));
            pinned[i] = true;
            continue;
          }

          // Against an off-centre zone, the median of where each edge would have this item stand: an
          // edge per entry, so the three edges into API Gateway outvote CDN's one, and Edge lines
          // up with Clients at iOS.
          var segs2 = downward ? segUp[idx] : segDown[idx];
          var offs = [];
          var through = false;
          for (j = 0; j < segs2.length; j += 1) {
            var far2 = downward ? segs2[j].u : segs2[j].v;
            var d2 = attachO(segs2[j], far2) - attachO(segs2[j], idx);
            if (d2 !== 0) through = true;
            offs.push(centreOf(far2) + d2);
          }
          if (through) {
            offs.sort(function (p2, q2) { return p2 - q2; });
            var h2 = offs.length >> 1;
            var mid2 = (offs.length % 2) ? offs[h2] : (offs[h2 - 1] + offs[h2]) / 2;
            want.push(Math.round(mid2 - items[idx].oSize / 2));
            continue;
          }
          var acc = 0;
          for (j = 0; j < fixed2.length; j += 1) acc += centreOf(fixed2[j]);
          want.push(Math.round(acc / fixed2.length - items[idx].oSize / 2));
        }
        // A pinned ghost stays where its member wants it; the real items before it are packed back
        // from it rather than pushing it forward, and nothing drifts the rank off it afterwards.
        var stepOf = function (k) {
          return items[layer2[k - 1]].oSize / 2 + centreSep(layer2[k - 1], layer2[k]) - items[layer2[k]].oSize / 2;
        };
        var ceil = [];
        var anyPin = false;
        for (i = layer2.length - 1; i >= 0; i -= 1) {
          var c2 = Infinity;
          if (i + 1 < layer2.length) {
            c2 = ceil[i + 1] - stepOf(i + 1);
            if (pinned[i + 1]) c2 = Math.min(c2, want[i + 1] - stepOf(i + 1));
          }
          ceil[i] = c2;
          if (pinned[i]) anyPin = true;
        }
        var put = [];
        for (i = 0; i < layer2.length; i += 1) {
          var lowest = (i === 0) ? -Infinity : put[i - 1] + stepOf(i);
          var aim = pinned[i] ? want[i] : Math.min(want[i], ceil[i]);
          put.push(Math.max(aim, lowest));
        }
        var drift = 0;
        var drifting = 0;
        for (i = 0; i < layer2.length; i += 1) {
          if (items[layer2[i]].ghost) continue;
          drift += want[i] - put[i];
          drifting += 1;
        }
        drift = (drifting && !anyPin) ? Math.round(drift / drifting) : 0;
        if (anyPin) level.offCentre = true;
        for (i = 0; i < layer2.length; i += 1) oPos[layer2[i]] = put[i] + drift;
      }
    }

    // --- one lane for a long edge -----------------------------------------
    // The passes above settle a dummy at the mean of its two neighbours, which for a chain of them
    // is a straight line from one end of the edge to the other -- and an orthogonal router draws
    // that line as a staircase, a jog in every gap the edge passes. The held-out review counted 21
    // links with 6 or more bends over its twenty unseen sources, reset -> boot at 12 and
    // breaker -> fastfail at 10, stepping five times down one side of the page where Pele draws a
    // single run. So an edge that spans three ranks or more is given ONE corridor: every dummy on
    // it is moved to the same O, the median of where the passes left them, clamped to the range
    // every rank's neighbours allow. What is left is a jog off the source onto the corridor, one
    // run, and a jog off it into the target.
    //
    // Only the dummies move, and only between their neighbours in the rank, so the order the
    // crossing count settled and every real box stay exactly where they were. Where the ranks do
    // not leave one O common to all of them the chain is left as it was rather than split into
    // partial runs: a split keeps a jog in the middle, which is the staircase again with fewer
    // steps. Rejected: running the corridor outside the whole level, Pele's outer lane. It needs
    // the dummy to be first or last in every rank it passes, which a back edge into the middle of
    // a fan is not, and moving it there reorders the ranks the crossing count settled.
    //
    // In rounds, until one moves nothing. A chain that is blocked can be freed by one settled after
    // it: on h13 the retry edge budget -> send cannot straighten past the dummy of the half-open
    // return beside it until that return has moved onto its own corridor. A chain once straight is
    // not visited again -- every neighbour that moves afterwards keeps its separation from it -- so
    // each round straightens at least one more chain or ends the loop, and the cap is only a guard.
    var straightened = new Set();
    for (var round1 = 0; round1 <= proper.length; round1 += 1) {
      var moved1 = false;
      for (i = 0; i < proper.length; i += 1) {
        var lchain = proper[i].chain;
        if (lchain.length < 4 || straightened.has(i)) continue;
        var lane1 = [];
        var lo1 = -Infinity;
        var hi1 = Infinity;
        for (j = 1; j + 1 < lchain.length; j += 1) {
          var d1 = lchain[j];
          var row1 = coLayers[items[d1].rank];
          var at1 = row1.indexOf(d1);
          if (at1 < 0) { lo1 = Infinity; break; }
          if (at1 > 0) lo1 = Math.max(lo1, centreOf(row1[at1 - 1]) + centreSep(row1[at1 - 1], d1));
          if (at1 + 1 < row1.length) hi1 = Math.min(hi1, centreOf(row1[at1 + 1]) - centreSep(d1, row1[at1 + 1]));
          lane1.push(centreOf(d1));
        }
        if (lo1 > hi1) continue;
        lane1.sort(function (p1, q1) { return p1 - q1; });
        var aim1 = Math.round(Math.min(hi1, Math.max(lo1, lane1[(lane1.length - 1) >> 1])));
        if (aim1 < lo1 || aim1 > hi1) continue;
        for (j = 1; j + 1 < lchain.length; j += 1) oPos[lchain[j]] = aim1 - items[lchain[j]].oSize / 2;
        straightened.add(i);
        moved1 = true;
      }
      if (!moved1) break;
    }

    // The label of the LAST run along a rank has no neighbour to take its room from, so the level
    // itself has to be that wide -- otherwise the corridor `centreSep` reserved for every other
    // label runs off the end of the viewBox for this one. `labelled chain TD` is the whole story in
    // one source: one column, two labels, and before this a 128px drawing with both of them outside
    // it. The bound is the label's own far edge, not a centre-to-centre distance, because there is
    // nothing on the far side of it to be clear of.
    var minO = 0;
    var first = true;
    for (i = 0; i < m; i += 1) {
      var low = oPos[i];
      var lowRoom = labelAfter ? labelRoomBack[i] : labelRoom[i];
      if (lowRoom > 0) {
        low = Math.min(low, oPos[i] + items[i].oSize / 2 - LABEL_GAP - lowRoom);
      }
      if (first || low < minO) { minO = low; first = false; }
    }
    for (i = 0; i < m; i += 1) oPos[i] -= minO;

    var totalO = 0;
    for (i = 0; i < m; i += 1) {
      var end = oPos[i] + items[i].oSize;
      var highRoom = labelAfter ? labelRoom[i] : labelRoomBack[i];
      if (highRoom > 0) {
        end = Math.max(end, oPos[i] + items[i].oSize / 2 + LABEL_GAP + highRoom);
      }
      if (end > totalO) totalO = end;
    }

    // --- the inter-rank gaps ----------------------------------------------
    // Sized last, because only now is it known how many edges have to move sideways between two
    // ranks, and which of them can travel side by side. A lane is 12px from the next, which is
    // SKILL.md §6 rule 3 held by the layout rather than left to the router to discover it cannot
    // hold it. On top of the lanes the gap reserves each of its two faces -- 2*STUB to turn away
    // from one, ARRIVE to arrive at one -- which at the default 40px rank spacing tile it exactly:
    // 16 + 24.
    //
    // "Has to move sideways" is read off the two boxes' centres, not off the two ports, because the
    // ports are fanned globally afterwards and a face can carry edges from more than one level. So
    // two edges joining the same pair of columns share the band centre and the router jogs them the
    // few px their fanned ports differ by. What that leaves unguaranteed is checked rather than
    // assumed: "never runs two connectors along one lane" in layout.spec.js asserts that edges
    // sharing a lane occupy disjoint stretches of it.
    var gapLanes = [];
    var gapLabel = [];
    // The labelled corridors' stacks, in columns and end to end; see the column note below.
    var gapStack = [];
    var seatedAt = [];
    var seatRooms = [];
    var gapWhole = [];
    // How much of the gap each of its two faces has to be left alone for. A gap is not symmetric:
    // the face an edge LEAVES needs a stub plus room to round the corner off it, and the face an
    // edge ARRIVES at needs that plus the arrowhead and a shaft behind it. Which face is which is a
    // property of the edges in the gap, not of the gap, so it is read off them -- an all-forward
    // gap only ever has arrivals on its far face, and reserving ARRIVE on both instead cost 6.47%
    // of drawing area over the 300-source corpus against 2.24% for this.
    var gapLoNeed = [];
    var gapHiNeed = [];
    var gapStraight = [];
    var stacked = [];
    // An edge that crosses more than one gap of a horizontal level is labelled on its corridor, and
    // claims no room in any gap for it. In LR and RL that corridor is the long horizontal run past
    // the intermediate ranks, and its cross-lines are short vertical jogs; the placer takes the
    // longest run first, so the label goes on the corridor and never beside a jog. Charging it as
    // if it did reserved the label's WIDTH, beside every jog and in every gap the edge passed: the
    // review's 07 -- a seven-node LR chain with five labelled back edges -- came out 2016px wide,
    // about twice Pele's, with gaps of 112-352px between boxes 80px wide. Without the charge it is
    // 984px, its gaps 40-108px, and every label is still on its own line.
    //
    // Rejected: keeping the gap claim but charging it once, in whichever gap the edge's label
    // fits best, which is 1036px on 07 for room the placer does not use either. Also rejected: the
    // same rule in TB and BT. There the cross-line IS the long run along a rank and the labels go
    // on it: the review's 03 went from 704px to 516px tall, and one of its labels was then pushed
    // between two parallel connectors with no zero-penalty position left.
    var onCorridor = function (edge) { return !vertical && edge.chain.length > 2; };
    // A node whose faces along the rank axis are single points, so `clusterAt` rather than the
    // fan decides where its ports go: a rhombus on every face, a hexagon on the two it points with.
    var vertexFork = function (idx) {
      var ref = items[idx].ref;
      if (!ref || ref.kind !== "node") return false;
      var g = geometryOf(ref.shape);
      return g === "diamond" || (g === "hexagon" && !vertical);
    };
    for (i = 0; i < maxRank; i += 1) {
      gapLanes.push(0); gapLabel.push(0); gapStack.push(0); seatedAt.push({}); gapWhole.push(0); gapStraight.push(0); stacked.push(new Map());
      gapLoNeed.push(2 * STUB); gapHiNeed.push(2 * STUB);
    }
    for (i = 0; i < segments.length; i += 1) {
      var seg = segments[i];
      if (seg.gap >= maxRank) continue;
      // The target's rank, which is the high end for a forward edge and the low end for a back one.
      // Only the segment adjacent to it can be the one that arrives, and there is exactly one.
      var segEdge = seg.edge;
      var segBack = rank[segEdge.a.slot] > rank[segEdge.b.slot];
      var segTargetRank = segBack ? segEdge.lowRank : segEdge.highRank;
      if (segTargetRank === seg.gap && ARRIVE > gapLoNeed[seg.gap]) gapLoNeed[seg.gap] = ARRIVE;
      if (segTargetRank === seg.gap + 1 && ARRIVE > gapHiNeed[seg.gap]) gapHiNeed[seg.gap] = ARRIVE;
      // The stretch of the gap this segment crosses, so the assignment below can ask whether two of
      // them would actually share any of a lane rather than counting them.
      var cu = centreOf(seg.u);
      var cv = centreOf(seg.v);
      seg.lo = Math.min(cu, cv);
      seg.hi = Math.max(cu, cv);
      seg.lane = -1;
      // Which node this segment LEAVES, when it leaves one at all: the low end of a forward edge,
      // the high end of a back one, and only where this is the segment next to that node. That node
      // plus that direction IS the fork -- "the edges leaving one node on one face, the same way" --
      // because `chooseSides` hands every ranked edge the face its direction names, so one node and
      // one direction can only be one face.
      //
      // An edge with a corridor to travel is not an arm of it, which is the same line `mirrorForks`
      // draws and for the same reason: its cross-line is a step onto a corridor several ranks long,
      // not a branch beside the others, and pairing it with one would ladder a mirror that the port
      // pass is never going to draw.
      seg.forkAt = (!segBack && seg.gap === segEdge.lowRank) ? seg.u
        : ((segBack && seg.gap + 1 === segEdge.highRank) ? seg.v : -1);
      // On a vertex the exception does not hold. A diamond places its own ports along its slopes
      // (`slopesOf`) whatever `mirrorForks` would ask, so an answer that steps onto a corridor
      // is one more branch beside the others, and outside the ladder it took the gap's next free
      // lane: on h13 the 5xx answer, the outermost, turned BELOW the 429 answer inside it and
      // crossed its drop with a hop.
      if (seg.forkAt >= 0 && segEdge.chain.length > 2 && !vertexFork(seg.forkAt)) seg.forkAt = -1;
      seg.forkBack = segBack;
      seg.forkOff = (seg.forkAt < 0) ? 0
        : ((seg.forkAt === seg.u ? cv : cu) - centreOf(seg.forkAt));
      // The same information at the other end: several direct edges arriving at one node are a
      // fan-in. It cannot reuse the fork's lane order. For a forward fork the outer pair turns
      // nearest the low/source face; for a forward fan-in that is exactly the order that crosses,
      // because an outer arm's cross-line cuts the inner arm before the latter has turned. The
      // fan-in must therefore ladder towards its high/target face, inner pair first. Sorting all
      // segments nearest-first was rejected: it has no notion of a shared face and can reorder an
      // unrelated edge ahead of a fork; pairing only the arms that share this target preserves the
      // first-fit order everywhere else.
      seg.mergeAt = (segEdge.chain.length > 2) ? -1
        : ((!segBack && seg.gap + 1 === segEdge.highRank) ? seg.v
          : ((segBack && seg.gap === segEdge.lowRank) ? seg.u : -1));
      seg.mergeBack = segBack;
      seg.mergeOff = (seg.mergeAt < 0) ? 0
        : ((seg.mergeAt === seg.u ? cv : cu) - centreOf(seg.mergeAt));
      var lbl = onCorridor(segEdge) ? null : seg.edge.labelBox;
      if (lbl) {
        var along = vertical ? lbl.h : lbl.w;
        if (along > gapLabel[seg.gap]) gapLabel[seg.gap] = along;
        // A run with no cross-line is labelled beside the run itself, anywhere along it. It is
        // tracked apart from the rest because a gap that holds both kinds has to hold them at two
        // different heights -- see the far-face reserve below.
        if (seg.lo === seg.hi) {
          if (along > gapStraight[seg.gap]) gapStraight[seg.gap] = along;
        }
        // Labels that will be fighting over one corridor, so that the gap can be made deep enough
        // to STACK them rather than wide enough to stand them side by side. Two runs share a
        // corridor when they cross the gap at one O -- cand.mmd, five labelled connectors between
        // one node and one zone, every one of them straight, five labels in a 56px band -- or when
        // they leave the same item, which is the case a shared O misses: nego.mmd's `OP` sends a
        // labelled arm and a labelled dotted link into the same gap, `centreSep` reserved ONE
        // corridor beside it because it takes the widest label and not the sum, and the two masks
        // landed on top of each other.
        //
        // Stacking is what the room costs least in, and it is the only one of the two that works.
        // Giving each label a corridor of its own across the rank instead -- `labelRoom` summing
        // rather than taking the widest -- costs 25.4% of drawing area over the 79 sources against
        // 13.8% for this AND still leaves 4 labels overlapping another, because a rank holding one
        // item has no corridor to widen and cand.mmd's five connectors run between one node and one
        // zone. `assignPorts` does fan the shared ports apart afterwards -- 28px in cand.mmd, across
        // a 168px face -- which is no help against labels 128 to 168px wide.
        //
        // The key is exact, not an overlap test: a fan-in's arms all pass over their target's
        // centre and are still side by side by the time they are labelled, and grouping by overlap
        // stacked every one of those for nothing.
        var corridor = (seg.lo === seg.hi) ? ("o" + seg.lo) : ("u" + seg.u);
        var stack = stacked[seg.gap];
        var sharing = stack.get(corridor);
        if (!sharing) { sharing = []; stack.set(corridor, sharing); }
        sharing.push({ along: along, across: vertical ? lbl.w : lbl.h });
      }
    }

    for (i = 0; i < maxRank; i += 1) {
      stacked[i].forEach(function (plates, key) {
        // How deep the stack has to be, in COLUMNS. A corridor's runs leave one face side by side,
        // one port pitch apart, so two plates whose lines are k pitches apart can stand at the same
        // place along the gap once k pitches hold a plate's extent across the gap and the rule 2 gap
        // either side of it. Then only that many plates need room of their own along it, and the
        // widest of them is the worst case, whichever lines the placer puts them on.
        //
        // End to end, which is what was here, holds the same plates and is right where k reaches the
        // corridor's size. It is in a TB level: across is a plate's WIDTH and a column there is a
        // whole fan. In an LR one across is a plate's 24px height and the stack ran along the WIDTHS,
        // and b04 in the second held-out set came out 1968px wide against Pele's 1201 -- six plates
        // of one face strung along one gap.
        //
        // The pitch is BUSY_PITCH where the face is one `layout` grew for it -- a node, not a zone
        // or a vertex, with BUSY_N or more labelled ends -- and MIN_PITCH otherwise.
        var n = plates.length;
        var at = key.charAt(0) === "u" ? Number(key.slice(1)) : -1;
        var grown = n >= BUSY_N && at >= 0 && items[at].ref && items[at].ref.kind === "node" && !vertexFork(at);
        var pitch = grown ? BUSY_PITCH : MIN_PITCH;
        var across = 0;
        for (var d = 0; d < n; d += 1) if (plates[d].across > across) across = plates[d].across;
        var columns = Math.min(n, Math.ceil((across + 2 * LABEL_GAP) / pitch));
        // A node face `seatPitch` spaced holds its plates in ONE column, each ON its own line, so
        // the gap needs the widest plate along it and no more. The formula above asks for rule 2's
        // gap on both sides of a plate BESIDE a line and would charge it two.
        var seatedFace = n >= 2 && at >= 0 && items[at].ref && items[at].ref.kind === "node" && !vertexFork(at)
          && plates.every(function (p) { return p.across < p.along; });
        if (seatedFace) columns = 1;
        var alongs = plates.map(function (p) { return p.along; }).sort(function (a, b) { return b - a; });
        var depth = (columns - 1) * 2 * LABEL_GAP;
        for (d = 0; d < columns; d += 1) depth += alongs[d];
        if (seatedFace) seatedAt[i][key] = true;
        if (depth > gapStack[i]) gapStack[i] = depth;
        var whole = (n - 1) * 2 * LABEL_GAP;
        for (d = 0; d < n; d += 1) whole += alongs[d];
        if (whole > gapWhole[i]) gapWhole[i] = whole;
      });
    }

    // --- which lane each segment travels ----------------------------------
    // A running counter used to hand every segment in a gap a lane of its own, in the order the
    // edges were declared. That is what made a decision fork's two branches turn at two different
    // heights -- the reader who reported it could see the asymmetry follow the source's line order
    // and nothing in the drawing -- and on a five-way fan it also laddered the right-hand arms
    // inner-first, which put an inner arm's cross-line across an outer arm and cost a bridge hop.
    //
    // So a fork's arms are laddered as MIRROR PAIRS. Sort the arms of one fork by where along the
    // rank they are going, pair the outermost with the outermost inwards, and give each pair one
    // lane: arm k and arm n-1-k turn at the same height by construction, whatever their targets are
    // called. The pairs ladder outwards-first, the outermost taking the lane nearest the node they
    // leave, because the other order is the one that crosses -- an inner arm's cross-line would have
    // to pass under an outer arm's, and that is the hop the fan was drawing.
    //
    // Everything else first-fits alongside them. Two segments may share a lane when the stretches
    // they cross are disjoint, which is the property "never runs two connectors along one lane" in
    // layout.spec.js has always asserted and which the counter, handing out a lane apiece, could
    // only ever meet by never sharing. Touching at one point counts as disjoint: a fork's two arms
    // meet at their own source's centre and nowhere else, and their ports there are 16px apart.
    // Measured over the 312 drawings the corpus lays out: 2 pairs shared a lane before this and 83
    // do now, and the pairs that overlap along the one they share are the same 2 in both -- a
    // pre-existing case in the nested-subgraph source, untouched, not one of the 81 new ones.
    var laneHeld = [];
    for (i = 0; i < maxRank; i += 1) laneHeld.push([]);
    var laneFits = function (g, L, list) {
      var held = laneHeld[g][L];
      if (!held) return true;
      for (var q = 0; q < list.length; q += 1) {
        for (var w = 0; w < held.length; w += 1) {
          if (Math.min(list[q].hi, held[w][1]) - Math.max(list[q].lo, held[w][0]) > 0) return false;
        }
      }
      return true;
    };
    var takeLane = function (g, list, from) {
      var L = from;
      while (!laneFits(g, L, list)) L += 1;
      while (laneHeld[g].length <= L) laneHeld[g].push([]);
      for (var q = 0; q < list.length; q += 1) {
        list[q].lane = L;
        laneHeld[g][L].push([list[q].lo, list[q].hi]);
      }
      if (L + 1 > gapLanes[g]) gapLanes[g] = L + 1;
      return L;
    };

    var forks = new Map();
    for (i = 0; i < segments.length; i += 1) {
      var fs = segments[i];
      if (fs.gap >= maxRank || fs.forkAt < 0) continue;
      var fkey = fs.gap + "|" + fs.forkAt + "|" + (fs.forkBack ? "b" : "f");
      if (!forks.has(fkey)) forks.set(fkey, []);
      forks.get(fkey).push(fs);
    }
    var merges = new Map();
    for (i = 0; i < segments.length; i += 1) {
      var ms = segments[i];
      if (ms.gap >= maxRank || ms.mergeAt < 0) continue;
      var mkey = ms.gap + "|" + ms.mergeAt + "|" + (ms.mergeBack ? "b" : "f");
      if (!merges.has(mkey)) merges.set(mkey, []);
      merges.get(mkey).push(ms);
    }
    // A lane is claimed by a UNIT: one mirror pair of a fork, or one segment on its own. Units go in
    // the order their edges were DECLARED, which is the order the counter used, so a gap that holds
    // no fork comes out of this exactly as it went in. Two orders that read as more principled were
    // built and measured, and each cost a bridge hop somewhere:
    //   * furthest-travelling unit first. Inside a fork that IS the rule -- an arm that crosses
    //     further has to turn sooner or the shorter one's cross-line runs through it -- but a fan-IN
    //     shares its point at the other end of the gap and wants the opposite. `fan-in-TD` and
    //     `fan-in-LR` went from 1 hop to 2 each, 17 over the corpus against 14.
    //   * forks claiming their lanes before anything else in the gap. That pushes a two-rank edge
    //     out past an arm travelling less far than it does: `B --> C / E --> C / B --> E / B --> A /
    //     B --> D` in render.spec.js went from 1 hop to 3.
    // Declaration order costs neither and still saves two: 16 hops over the corpus before, 14 after.
    var units = [];
    forks.forEach(function (arms) {
      if (arms.length < 2) return;
      arms.sort(function (p, q) { return (p.forkOff - q.forkOff) || (p.edge.index - q.edge.index); });
      for (var a2 = 0; a2 < arms.length; a2 += 1) arms[a2].inFork = true;
      var tiers = [];
      for (var k = 0; k < arms.length; k += 1) {
        var t = Math.min(k, arms.length - 1 - k);
        if (!tiers[t]) tiers[t] = [];
        tiers[t].push(arms[k]);
      }
      // One index for the whole fork, so that its pairs sort together and in ladder order. A pair's
      // own edges will not do: tier order is position order and an edge index is declaration order,
      // and the two need not agree -- a fork whose inner pair was written first would sort ahead of
      // its own outer pair and take the lower lane. Nothing in the corpus does that, and every
      // measurement is identical with this line and without it; it is what lets the ladder below be
      // stated as a rule rather than held by the order the source happened to be written in.
      var forkIndex = arms[0].edge.index;
      for (var a3 = 1; a3 < arms.length; a3 += 1) forkIndex = Math.min(forkIndex, arms[a3].edge.index);
      var fork = { tiers: [], back: arms[0].forkBack };
      for (var t2 = 0; t2 < tiers.length; t2 += 1) {
        var tier = tiers[t2];
        if (!tier) continue;
        // The axis of an odd fan: one arm, going nowhere along the rank. It is drawn straight, so
        // there is no cross-line to reserve a lane for. A tier of two keeps its lane even when one
        // of the pair is a point, because `mirrorForks` gives that arm a step to match its partner.
        if (tier.length === 1 && tier[0].lo === tier[0].hi) continue;
        fork.tiers.push({ segs: tier, index: forkIndex, fork: fork });
      }
      // Lane 0 is the one nearest the gap's LOW face, which is the face a forward fork leaves by and
      // the face a back fork arrives at, so a back fork ladders the other way round -- its innermost
      // pair takes the lowest lane, which puts its outermost arm nearest the node it is leaving.
      // Ranking turns most declared back edges into forward ones, and no source in the 328-source
      // corpus produces a back fork of two arms at all: 7 segments there qualify as one arm of one
      // and no two of them ever share a node. So this line is the rule carried through rather than a
      // case measured, and `forkBack` is in the key above for the reachable half of the same point --
      // a node with one back arm and two forward ones is not a fork of three.
      if (fork.back) fork.tiers.reverse();
      for (var t4 = 0; t4 < fork.tiers.length; t4 += 1) {
        fork.tiers[t4].step = t4;
        units.push(fork.tiers[t4]);
      }
    });
    merges.forEach(function (arms) {
      // A segment cannot be scheduled twice. A source fork owns the lane shape when both ends fan;
      // the merge then orders only the arms left over, if it still has a pair to order.
      arms = arms.filter(function (arm) { return !arm.inFork; });
      if (arms.length < 2) return;
      arms.sort(function (p, q) { return (p.mergeOff - q.mergeOff) || (p.edge.index - q.edge.index); });
      for (var a4 = 0; a4 < arms.length; a4 += 1) arms[a4].inMerge = true;
      var tiers = [];
      for (var k2 = 0; k2 < arms.length; k2 += 1) {
        var t5 = Math.min(k2, arms.length - 1 - k2);
        if (!tiers[t5]) tiers[t5] = [];
        tiers[t5].push(arms[k2]);
      }
      var mergeIndex = arms[0].edge.index;
      for (var a5 = 1; a5 < arms.length; a5 += 1) mergeIndex = Math.min(mergeIndex, arms[a5].edge.index);
      var merge = { tiers: [], back: arms[0].mergeBack };
      for (var t6 = 0; t6 < tiers.length; t6 += 1) {
        var mergeTier = tiers[t6];
        if (!mergeTier) continue;
        if (mergeTier.length === 1 && mergeTier[0].lo === mergeTier[0].hi) continue;
        merge.tiers.push({ segs: mergeTier, index: mergeIndex, merge: merge });
      }
      // Lane zero is nearest the low face. A forward merge arrives at the high face, so its outer
      // pair goes last; a back merge arrives at the low face and keeps the outer pair first.
      if (!merge.back) merge.tiers.reverse();
      for (var t7 = 0; t7 < merge.tiers.length; t7 += 1) {
        merge.tiers[t7].step = t7;
        units.push(merge.tiers[t7]);
      }
    });
    for (i = 0; i < segments.length; i += 1) {
      var rest = segments[i];
      if (rest.gap >= maxRank || rest.lo === rest.hi) continue;
      if (rest.inFork || rest.inMerge) continue;
      units.push({ segs: [rest], index: rest.edge.index, fork: null, merge: null, step: 0 });
    }
    units.sort(function (p, q) { return (p.index - q.index) || (p.step - q.step); });
    for (i = 0; i < units.length; i += 1) {
      var unit = units[i];
      var family = unit.fork || unit.merge;
      var floorL = family ? (family.floor || 0) : 0;
      var got = takeLane(unit.segs[0].gap, unit.segs, floorL);
      // A fork or merge's pairs ladder one lane apart at least, whatever else claims the gap first.
      if (family) family.floor = got + 1;
    }

    // --- a decision's answers branch where they leave it --------------------
    // A rhombus hands its arms ports clustered at its vertex, 16px apart, and the gap then put the
    // lane they turn on wherever the gap's slack and labels left it: in the middle of the band, and
    // below the room reserved for the answers' labels on the source side. So the two answers left
    // the diamond as a pair and ran 52px side by side in 01, 09 and 13, and 112px in 04, before
    // either turned -- read by both reviews as one doubled line, at the one place in a flowchart
    // where a reader most needs to see a branch. Pele's diverge at the vertex.
    //
    // So a forward fork off a diamond that holds the gap's first lane has that lane at the source
    // face's own reserve, and the room its labels would claim on that face is claimed on the far
    // face instead -- a label then rides the arm's own drop to its target, which is apart from the
    // other arm's, rather than the shared stretch where both strokes still run together. Only a
    // diamond: a rectangle spreads its arms over its whole face, and moving every fork's lane
    // re-shapes drawings no reader complained of.
    //
    // And only where the drops stand far enough apart for each label to ride its own: half of each
    // plate and a label gap between them. In 13 the HMAC diamond's two drops land 72px apart and its
    // `no, the signature does not match...` plate is 224px wide, and with the lane hugged that plate
    // sat across BOTH drops -- the label placer's zero-harm count over the review sources fell from
    // 43/44 to 41/44. Such a fork keeps its labels on the source side and its lane where it was.
    //
    // Where a drop lands is the port pass's answer, later, so it is estimated here the way that pass
    // answers it: `mirrorForks` steps both arms out from the fork's axis by one amount, the least
    // that every target's landing can take -- a rectangle's face from two units inside its near
    // corner, a rhombus only at its vertex. Taking the targets' centres instead put 13's drops 60
    // units apart, past both plates, where they were drawn 18 apart; this puts them 18 apart, and
    // 01's at 42 and 12 where they are drawn at 42 and 12.
    var hugGap = [];
    var hugArms = new Map();
    for (i = 0; i < maxRank; i += 1) hugGap.push(false);
    for (i = 0; i < segments.length; i += 1) {
      var hs = segments[i];
      // Every arm, the straight one too: `H{Hub}`'s middle route drops straight between the other
      // two, and its plate stands between theirs.
      if (hs.gap >= maxRank || hs.forkAt < 0 || hs.forkBack) continue;
      var hRef = items[hs.forkAt].ref;
      if (!hRef || hRef.kind !== "node" || geometryOf(hRef.shape) !== "diamond") continue;
      var hKey = hs.gap + "|" + hs.forkAt;
      if (!hugArms.has(hKey)) hugArms.set(hKey, []);
      hugArms.get(hKey).push(hs);
    }
    hugArms.forEach(function (arms) {
      if (!arms.some(function (a) { return a.lane === 0 && a.lo !== a.hi; })) return;
      var axis = centreOf(arms[0].forkAt);
      var farOf = function (a) { return a.forkAt === a.u ? a.v : a.u; };
      var reachOf = function (a) {
        var t = farOf(a), lo = oPos[t], hi = oPos[t] + items[t].oSize;
        var ref = items[t].ref;
        if (ref && ref.kind === "node" && geometryOf(ref.shape) !== "rect") {
          var c = Math.abs(centreOf(t) - axis);
          return { lo: c, hi: c };
        }
        if (lo <= axis && axis <= hi) return { lo: 0, hi: Math.max(hi - axis, axis - lo) - 2 };
        return lo > axis ? { lo: lo - axis + 2, hi: hi - axis - 2 } : { lo: axis - hi + 2, hi: axis - lo - 2 };
      };
      var common = { lo: 0, hi: Infinity };
      for (var h1 = 0; h1 < arms.length; h1 += 1) {
        if (arms[h1].lo === arms[h1].hi) continue;
        var rr = reachOf(arms[h1]);
        common = { lo: Math.max(common.lo, rr.lo), hi: Math.min(common.hi, rr.hi) };
      }
      var dropOf = function (a) {
        if (a.lo === a.hi) return axis;
        var step = common.lo <= common.hi ? common.lo : reachOf(a).lo;
        return centreOf(farOf(a)) < axis ? axis - step : axis + step;
      };
      var halfOf = function (a) {
        var box = onCorridor(a.edge) ? null : a.edge.labelBox;
        return box ? (vertical ? box.w : box.h) / 2 : 0;
      };
      arms.sort(function (p, q) { return dropOf(p) - dropOf(q); });
      for (var h2 = 0; h2 + 1 < arms.length; h2 += 1) {
        if (dropOf(arms[h2 + 1]) - dropOf(arms[h2]) < halfOf(arms[h2]) + halfOf(arms[h2 + 1]) + LABEL_GAP) return;
      }
      hugGap[arms[0].gap] = true;
    });

    // --- how far apart the lanes sit -------------------------------------
    // A cross-line's label sits beside the cross-line, so the space between two lanes is where one
    // of them has to go. At the flat LANE_GAP that space is 12px and a one-line label is 24px, which
    // is why `H -->|route one| A / |route two| B / |route three| C` drew its three labels on top of
    // one another: the layout had counted the lanes and not what is written along them.
    //
    // Per lane rather than one pitch for the whole gap, so that a gap with four lanes of which one
    // is labelled does not pay the label's pitch three times. No source in the 79 reaches that
    // shape -- one pitch for the gap measures the same drawing, to the pixel, on every one of them
    // -- so this is the rule carried through rather than a case measured.
    //
    // WHICH side of its lane a label takes is the side `placeEdgeLabel` offers first, carried
    // through the same one switch the rest of this function uses: it prefers above a horizontal run
    // and the right of a vertical one, and `localOf` flips R for BT and RL. So the label sits on the
    // low side of its lane in TB and RL and on the high side in BT and LR, and the room goes there.
    // Which side of a lane its label is charged to. BT was added to the set, and the honest note
    // is that the set it was added to could not be derived from anything: {TB, RL} is not "rank
    // increases with the coordinate" ({TB, LR}), nor the source's side of the gap, nor the target's,
    // and nothing else in the file explains it.
    //
    // So it was settled by measurement over the 172-source sweep, which is the one ground available.
    // `labelled fork BT` was the only drawing in it that came out with a `label-crowded` warning
    // and the only one with a label mask inside the 8px, and the reason is here rather than in the
    // placer: the drawing is the exact vertical mirror of `labelled fork TD`, which is clean, EXCEPT
    // that `B -->|no| D` turns 24px after leaving B where TD turns it at 44px -- a shorter run, and
    // the two labels on B's face then have nowhere clean to sit. Counting warnings across the sweep:
    // {TB, RL} gives 1, {TB, LR} gives 1, dropping the condition entirely gives 2, and both
    // {TB, BT, RL} and a flat `true` give 0. Total drawing area is 11.030M px^2 in all five, to the
    // last digit, so the choice costs nothing in size.
    //
    // A flat `true` scored the same as this and would delete the condition. It is not taken because
    // equal on two metrics is not the same as equal: the variable also decides which side of a lane
    // a label sits on, and that is a thing to look at rather than to count. Adding the one direction
    // that measurably misbehaves moves 2 drawings of 169 -- this one and `ladder BT` -- where the
    // flat rule would also move the LR family on no evidence.
    var laneLabelLo = (level.dir === "TB" || level.dir === "BT" || level.dir === "RL");
    var laneNeed = [];
    for (i = 0; i < maxRank; i += 1) laneNeed.push([]);
    for (i = 0; i < segments.length; i += 1) {
      var ns = segments[i];
      // Only a segment with a cross-line has a lane to be labelled beside. A straight run took no
      // lane at all (`takeLane` is never called for lo === hi) and its label is `centreSep`'s
      // business, across the rank rather than along it.
      if (ns.gap >= maxRank || ns.lane < 0 || ns.lo === ns.hi) continue;
      var nbox = onCorridor(ns.edge) ? null : ns.edge.labelBox;
      if (!nbox) continue;
      var nExtent = vertical ? nbox.h : nbox.w;
      var here = laneNeed[ns.gap];
      while (here.length <= ns.lane) here.push(0);
      if (nExtent > here[ns.lane]) here[ns.lane] = nExtent;
    }
    var laneRoom = function (g, L) {
      var need = laneNeed[g][L] || 0;
      return need > 0 ? need + 2 * LABEL_GAP : 0;
    };
    // Where each lane of a gap sits, measured from the first one. Lane L's label sits between lane
    // L and its neighbour on the label side, so that neighbour is the one that has to move over.
    //
    // And a bump's room where the first lane passes under a box whose stubs turn at the second.
    // That lane crosses the box's own stubs a lane above where they turn, and a hop needs HOP_R of
    // straight stroke on each side of the crossing: on the stub, the bump reaches HOP_R down from
    // the crossing and the stub's own corner, two units of radius, starts that far above the next
    // lane, so the two lanes have to stand 2 * HOP_R apart where LANE_GAP sets them 12px. In 11
    // C -> E ran under D across D -> G's and D -> H's stubs with its lane 4px above D -> H's corner,
    // the router drew it 12px off D's face instead, and both bumps there came out with their crests
    // 4px from the border -- what the reviews called face-pressed. With the pitch, C -> E
    // keeps its lane 20px below D and both crests stand 12px clear: two of the drawing's three
    // pressed hops, for 8px of height. `8b0420d` measured that no slide inside the old gap could.
    //
    // "Passes under" is the box's CENTRE inside the lane's span. Its whole face overlapping the span
    // was tried first and moved eight sweep drawings -- every fan-in and both-ways crossing, in four
    // directions -- each 4px larger with no hop in it before or after: a merge ladders its outer arm
    // deepest, so the first lane's span only grazes its neighbours' faces and crosses nothing. And
    // only stubs that turn at the SECOND lane: one that turns deeper already runs two pitches, 24px,
    // straight below the first, and charging those too gave K3,3 in render.spec.js a crossing it
    // did not have, 11 hops to 12, with no pressed hop in it to cure.
    //
    // Left: K's one pressed hop. K -> N drops straight, so nothing here claims room under K, and
    // I -> M runs 12px off K's face. A deeper floor as well was swept, 5 and 6 units against
    // pitches of 4, 5 and 6: K cleared at two of the six settings and not at their neighbours, each
    // one adding a hop and 16 to 24px more height, which is a lucky setting rather than a rule.
    var crossesStubs = [];
    for (i = 0; i < maxRank; i += 1) crossesStubs.push(false);
    for (i = 0; i < segments.length; i += 1) {
      var fs = segments[i];
      if (fs.gap >= maxRank || fs.lane !== 0 || fs.lo === fs.hi) continue;
      for (j = 0; j < segments.length; j += 1) {
        var ft = segments[j];
        if (ft.gap !== fs.gap || ft.lane !== 1) continue;
        var fx = ft.u;
        if (fx === fs.u || fx === fs.v || items[fx].dummy) continue;
        if (centreOf(fx) > fs.lo && centreOf(fx) < fs.hi) crossesStubs[fs.gap] = true;
      }
    }
    var laneOff = [];
    for (i = 0; i < maxRank; i += 1) {
      var offs = [0];
      for (j = 1; j < gapLanes[i]; j += 1) {
        var pitch = Math.max(LANE_GAP, laneRoom(i, laneLabelLo ? j : j - 1));
        if (j === 1 && crossesStubs[i]) pitch = Math.max(pitch, 2 * HOP_R / GRID);
        offs.push(offs[j - 1] + pitch);
      }
      laneOff.push(offs);
      // The outermost lane's label has no next lane to take its room from; the gap's own face is
      // what it is clear of, so the face reserve grows instead. ARRIVE and 2*STUB stay the floor --
      // this is a label's demand on top of an arrowhead's, not instead of it.
      var edgeLane = laneLabelLo ? 0 : gapLanes[i] - 1;
      var edgeRoom = gapLanes[i] > 0 ? laneRoom(i, edgeLane) : 0;
      if (laneLabelLo && !hugGap[i]) {
        if (edgeRoom > gapLoNeed[i]) gapLoNeed[i] = edgeRoom;
      } else if (edgeRoom > gapHiNeed[i]) {
        gapHiNeed[i] = edgeRoom;
      }
      // A gap holding both kinds of label holds them on opposite faces. A cross-line's label is
      // pinned beside its lane; a straight run's can slide the length of the run, so it is the one
      // that moves, and it moves to the face the lanes' labels do not use. Without this, the middle
      // arm of `H -->|route one| A / |route two| B / |route three| C` -- the one arm that IS
      // straight -- put its label at the same height as the outer arms' and over the top of one of
      // them. Only when both kinds are present: a gap of straight runs alone has the whole band,
      // and charging it a second face regardless costs 16px of every such gap -- `labelled chain
      // TD` goes 272px tall to 304 across its two -- for a further 1.3% of drawing area over the 79
      // sources and not one clash removed.
      if (edgeRoom > 0 && gapStraight[i] > 0) {
        var bothRoom = gapStraight[i] + 2 * LABEL_GAP;
        // A hugged gap is the exception: its lanes sit at the low face by construction, so the
        // straight run's free stretch is the far one, whatever `laneLabelLo` says. Charged to the
        // low face instead, in LR, it pushed a three-way decision's outer answers 56px out along
        // the middle one before they turned, and the middle label had nowhere clean to sit.
        if (laneLabelLo || hugGap[i]) {
          if (bothRoom > gapHiNeed[i]) gapHiNeed[i] = bothRoom;
        } else if (bothRoom > gapLoNeed[i]) {
          gapLoNeed[i] = bothRoom;
        }
      }
    }

    var rankSize = [];
    for (i = 0; i <= maxRank; i += 1) rankSize.push(0);
    for (i = 0; i < m; i += 1) if (items[i].rSize > rankSize[items[i].rank]) rankSize[items[i].rank] = items[i].rSize;
    for (i = 0; i <= maxRank; i += 1) rankSize[i] = even(rankSize[i]);

    var gapSize = [];
    for (i = 0; i < maxRank; i += 1) {
      var lanes = gapLanes[i];
      var needed = gapLoNeed[i] + (lanes > 0 ? laneOff[i][lanes - 1] : 0) + gapHiNeed[i];
      // An edge label lives in the gap, so the gap has to hold it. The router decides which side of
      // the stroke it goes on; reserving the room is the only part layout can settle.
      //
      // A stack in columns stands on the straight stretch of its lines, so the lanes where lines
      // step across the gap are added to it: a plate over a step has a corner under it. Never more
      // than the plates end to end, which always fitted. Measured over the three reviewed sets and
      // the 300-drawing sweep it moves 5 drawings, every one narrower -- b04 1968 -> 1696px, h04
      // 2316 -> 2240, b16 1584 -> 1528, `labelled returns to one face` LR 752 -> 696 and RL 752 ->
      // 736 -- with no label leaving its line and no new warning.
      //
      // Rejected: the columns without the lanes. b04 came to 1416px, but under the style-guide
      // ruler it warned label-crowded, as did two request/response exchanges written to test this
      // (stack.spec.js's, and one with five links): their lines step in the middle of the gap and
      // the plate between two columns stood on a step. Also rejected: the lanes added without the
      // cap, which made b11 1544 -> 1648px and h04 wider too; and columns at MIN_PITCH everywhere,
      // safe but b04 only 1968 -> 1784.
      var jogs = lanes > 0 ? laneOff[i][lanes - 1] : 0;
      var labelled = Math.max(gapLabel[i], gapStack[i] > 0 ? Math.min(gapWhole[i], gapStack[i] + jogs) : 0) + 2 * STUB;
      // A seated face's plates stand ON the straight its lines run after they step across the gap,
      // between the lane and the far face -- the face is the gap's low end, `seg.u` -- and that
      // straight is shorter than the gap by more than the two stubs `labelled` above adds: it
      // starts after the step's elbow (`cornerRadius`, 2 units at most) and has to end LABEL_GAP
      // short of the head, because the placer charges an ON plate nearer than that 10 and a BESIDE
      // one only 8. The held-out set's b02 showed it at 14a73f8: ESTABLISHED's two exits ran 128px
      // straight into their heads, "rcv FIN / send ACK" is 120, and it sat 8px under its line. So
      // each such line's straight is measured from its own lane, and the gap grows where one is short;
      // and where centring the lanes in the slack would hand the straight only half of it, the lanes
      // stand at the low reserve instead (`seatRooms`).
      //
      // Only a line that steps onto a lane and ends in its own head at the far face: one arriving at
      // the seated face has no head out there, a straight run has the whole gap, and a line whose
      // lane stands far out has a seat on the straight before it -- `labelled fan with a return`
      // RL grew 40px for that, with every plate on its line before and after.
      //
      // Rejected: the seat from the gap's outermost lane, as a far reserve. A plate stands on its own
      // line, not the outermost one, and the reserve bound wherever lanes spread: plates off their
      // run over the three sets and the sweep 99 -> 95 under the face ruler, but b11 1432 -> 1576px
      // wide with no plate moved, and b04 1416 -> 1456. Also rejected: centring the column over each
      // lane's longest straight run instead of the gap, as the sixth review proposed. Every run here
      // ends in a head, so the column's x is not what is short; the straight's length is.
      var band0 = Math.max(env.rankU, needed, labelled);
      var centred0 = hugGap[i] ? 0 : Math.floor((band0 - gapLoNeed[i] - jogs - gapHiNeed[i]) / 2);
      var seatRoom = 0;
      for (j = 0; j < segments.length; j += 1) {
        var ss = segments[j];
        if (ss.gap !== i || ss.lane < 0 || ss.lo === ss.hi || !seatedAt[i]["u" + ss.u]) continue;
        if (onCorridor(ss.edge) || !ss.edge.labelBox) continue;
        if (rank[ss.edge.a.slot] > rank[ss.edge.b.slot] || i + 1 !== ss.edge.highRank) continue;
        var plate = vertical ? ss.edge.labelBox.h : ss.edge.labelBox.w;
        var lane = gapLoNeed[i] + centred0 + laneOff[i][ss.lane];
        // Either straight holding the plate is a seat: before the lane, between the stub and the
        // elbow, where no head asks for room, or after it.
        if (lane - STUB - 2 >= plate) continue;
        if (band0 - lane - 2 >= plate + LABEL_GAP + HEAD) continue;
        var straight = gapLoNeed[i] + laneOff[i][ss.lane] + 2 + plate + LABEL_GAP + HEAD;
        if (straight > seatRoom) seatRoom = straight;
      }
      seatRooms.push(seatRoom);
      gapSize.push(Math.max(band0, seatRoom));
    }

    var rankStart = [];
    var at2 = 0;
    for (i = 0; i <= maxRank; i += 1) {
      rankStart.push(at2);
      at2 += rankSize[i] + (i < maxRank ? gapSize[i] : 0);
    }
    var totalR = at2;

    // Inside the two reserves, not across the whole band. Centring across the band put the lane the
    // gap was sized for in a place the router could not take it: a cross-line is clamped between
    // the two stubs the route leaves its ports on, so a lane closer to the arrival face than ARRIVE
    // is outside the range `connect` may choose from, and every edge whose lane fell outside it
    // dropped to the same fallback midpoint. This and the inclusive bound in `crossCandidates` go
    // together and neither works alone: with either one missing, 7 further pairs of connectors came
    // within 12px of each other over the corpus -- SKILL.md §6 rule 3 -- and with both, none.
    // `gapSize` is a max over `needed`, which is `lo + used + hi`, so the slack cannot go negative.
    var laneAt = [];
    for (i = 0; i < maxRank; i += 1) {
      var bandStart = rankStart[i] + rankSize[i];
      var band = gapSize[i];
      var used = gapLanes[i] > 0 ? laneOff[i][gapLanes[i] - 1] : 0;
      var slack = band - gapLoNeed[i] - used - gapHiNeed[i];
      var centred = hugGap[i] || seatRooms[i] > 0 ? 0 : Math.floor(slack / 2);
      laneAt.push(bandStart + gapLoNeed[i] + centred);
    }

    // --- one switch, four directions --------------------------------------
    var localOf = function (rPos, oPosn, rSize) {
      if (level.dir === "TB") return { x: oPosn, y: rPos };
      if (level.dir === "BT") return { x: oPosn, y: totalR - rPos - rSize };
      if (level.dir === "LR") return { x: rPos, y: oPosn };
      return { x: totalR - rPos - rSize, y: oPosn };
    };
    var laneCoord = function (r) {
      return (level.dir === "BT" || level.dir === "RL") ? totalR - r : r;
    };

    for (i = 0; i < m; i += 1) {
      var item = items[i];
      // Centred in its rank band: both the band and the box are an even number of units, so the
      // half is an integer and the corner stays on the grid.
      var rPos = rankStart[item.rank] + ((rankSize[item.rank] - item.rSize) >> 1);
      var local = localOf(rPos, oPos[i], item.rSize);
      item.lx = local.x;
      item.ly = local.y;
      if (item.ref) {
        item.ref.lx = local.x;
        item.ref.ly = local.y;
        item.ref.rank = item.rank;
        item.ref.order = item.order;
      }
    }

    for (i = 0; i < segments.length; i += 1) {
      var sg2 = segments[i];
      if (sg2.gap >= maxRank) continue;
      sg2.laneR = (sg2.lane >= 0) ? laneAt[sg2.gap] + laneOff[sg2.gap][sg2.lane] : laneAt[sg2.gap];
      sg2.laneLocal = laneCoord(sg2.laneR);
      sg2.laneAxis = vertical ? "y" : "x";
    }

    for (i = 0; i < proper.length; i += 1) {
      var pe3 = proper[i];
      pe3.via = [];
      for (j = 1; j + 1 < pe3.chain.length; j += 1) {
        var dummy = items[pe3.chain[j]];
        pe3.via.push({
          lx: dummy.lx + (vertical ? 1 : 0),
          ly: dummy.ly + (vertical ? 0 : 1)
        });
      }
      // The chain was built from the low rank up; the router walks from the source, which for a
      // back edge is the high end. Handing over the corridor in travel order means the router never
      // has to work out which way round it is.
      var backwards = rank[pe3.a.slot] > rank[pe3.b.slot];
      if (backwards) pe3.via.reverse();

      // The lane it may travel along, in this level's own frame: the one in the gap it leaves its
      // source by, which is the gap below the source for a forward edge and above it for a back
      // edge. Taking the lowest-numbered gap instead would hand a back edge the lane next to its
      // target, which is the end it arrives at rather than the end it has to get clear of.
      var startGap = backwards ? rank[pe3.a.slot] - 1 : rank[pe3.a.slot];
      var startSeg = null;
      for (j = 0; j < segments.length; j += 1) {
        if (segments[j].edge === pe3 && segments[j].gap === startGap) { startSeg = segments[j]; break; }
      }
      pe3.laneLocal = startSeg ? startSeg.laneLocal : null;
      // And the lane in the gap it ARRIVES through, which the router takes only where the edge lands
      // on a vertex; see `joinStations`.
      var endGap = backwards ? rank[pe3.b.slot] : rank[pe3.b.slot] - 1;
      var endSeg = null;
      for (j = 0; j < segments.length; j += 1) {
        if (segments[j].edge === pe3 && segments[j].gap === endGap) { endSeg = segments[j]; break; }
      }
      pe3.endLaneLocal = (endSeg && endSeg !== startSeg && endSeg.lane >= 0) ? endSeg.laneLocal : null;
      pe3.laneAxis = startSeg ? startSeg.laneAxis : null;
    }

    level.contentW = vertical ? totalO : totalR;
    level.contentH = vertical ? totalR : totalO;
    level.maxRank = maxRank;
  }

  // ===========================================================================
  // The ladder.
  //
  // RENDERER-SPEC.md §4.3, and the same semantics as the glue's `tagStructure` -- with the inputs it
  // would rather have had. A rung is a class name, never a colour: the theme's stylesheet owns every
  // fill and stroke, so one palette change in MacMermaidTheme.swift reaches both renderers and
  // neither of them has a second copy to drift from.
  // ===========================================================================

  function tagLadder(model) {
    var counts = { backend: 0, store: 0, entry: 0, terminal: 0, cross: 0 };
    var nodes = model.nodes;
    var edges = [];
    var i;
    for (i = 0; i < model.edges.length; i += 1) if (model.edges[i].countsForRung) edges.push(model.edges[i]);
    // The same two abstentions the glue makes. One node, or none of them joined up, is not a
    // structure -- it is a fragment, and putting an `fp-entry` on the only box in it says nothing.
    if (nodes.length < 2 || edges.length === 0) return counts;

    for (i = 0; i < nodes.length; i += 1) {
      var n = nodes[i];
      var rung = (geometryOf(n.shape) === "cylinder") ? "store"
        : (n.inDeg === 0 && n.outDeg > 0) ? "entry"
        : (n.outDeg === 0 && n.inDeg > 0) ? "terminal"
        : "backend";
      // No `optional` rung. A node every one of whose edges was `-.->` used to become `fp-optional`,
      // drawn with a dashed border, on the reading that the author had called it conditional. The
      // author had said that of the LINK. The held-out review found the border on six nodes in three
      // of twenty unseen sources and read it as a claim each time: Prometheus in a deployment
      // topology is not optional, its one edge is dotted; a saga's compensating steps are
      // conditional, not optional. None of the twenty wrote a `classDef` or `style` that asked for
      // it. The precedent is the zone-crossing dash below, which yields to an authored `-.->` rather
      // than putting a second meaning on dashed lines, and the accent this sweep stopped inventing.
      // Keeping the rung and dropping only its dash was rejected: its fill (ink @ 0.02) is 1.036:1
      // from terminal's in light and 1.061:1 in dark, so without the dash no reader could see it.
      n.rung = rung;
      counts[rung] += 1;
    }

    // No focal node and no accent edge. This sweep used to promote the node of strictly highest
    // degree (four or more, among four or more nodes) to `fp-focal` -- coral outline, coral wash --
    // and the incoming edge whose source had the highest out-degree to `fp-accent`. Measured before
    // it was removed: 8 of the corpus's 172 sweep drawings and 6 of the 16 sources of the
    // reader-facing review fired, and the review named five of those six, plus both accent edges, as
    // colour that "signals meaning that isn't in the source". None of the 188 sources wrote a
    // `style`, `classDef`, `linkStyle`, `class` or `:::`, so there was never an author choice to
    // yield to: every coral node on those pages was arithmetic.
    //
    // Narrowing it was tried on paper first, by the winning margin, and the numbers rule it out.
    // Where the margin is thin the pick is an artefact -- the lineage drawing's "Revenue by user"
    // won 4 to 3, the state machine's "Connecting" 6 to 4, and its "user retries" edge was chosen
    // only because Failed has out-degree 2 against 1 for each other source. Where the margin is wide
    // (every fan-in and fan-out hub: 4 to 1 up to 11 to 1) the hub is already the one box every line
    // reaches, so the coral says nothing the geometry does not, and the reader still decoded it as
    // "this is the critical path". It also cost meaning the author had given: on the fan-in source
    // the hub is a `[( )]` cylinder, and promoting it took its `fp-store` rung away. No threshold
    // keeps a firing that is both right and informative.
    //
    // The theme's one-accent restraint is kept rather than spent: an author who wants emphasis
    // already has it -- `style`/`classDef` arrive inline and outrank the theme, and `==>` is the
    // weight the stylesheet carries -- which is the same deference the zone-crossing dash makes
    // below. The author's meaning outranks the renderer's, and here the renderer had none to add.

    // A path that leaves one zone and enters another. Membership is read off the parse tree here,
    // where the glue has to infer it from overlapping rects, so "innermost" is simply the parent.
    // Both ends have to be in a zone: an edge to a node in no subgraph has not crossed a boundary,
    // and counting it as one made every edge in a half-grouped diagram "crossing".
    //
    // ...unless the reader has already spent the dash. The class is drawn `stroke: link` plus
    // `stroke-dasharray: 6,3`, and the dash is load-bearing rather than decorative: link against
    // muted is 1.003:1 in greyscale in the light palette (1.668:1 in dark), so hue alone carries
    // nothing for a reader who cannot separate those two hues. But a source that writes `-.->`
    // has ALREADY given dashes a meaning, and then one picture holds two kinds of dashed line --
    // one the author marked optional, one this function decided crosses a boundary -- with nothing
    // to tell them apart. Measured on `WB --> EA` beside `WA -.-> EB` across two subgraphs: the
    // solid edge came out `fp-cross`, which the stylesheet dashes, next to the authored dotted
    // edge, and a reader cannot recover which is which.
    //
    // So the renderer yields the whole category for that drawing. The alternative considered first
    // was dropping the dash and keeping the hue, which the 1.003:1 above rules out; a second dash
    // pattern was considered and rejected because two dash patterns are still two kinds of dashed
    // line. Yielding is also what the loop below already does edge by edge -- a dotted edge is
    // skipped rather than restyled -- so this is that deference applied to the whole picture
    // instead of one edge. The cost is that a diagram mixing `-.->` with zone crossings loses a
    // category it would otherwise have had, which is the right way round: the author's meaning
    // outranks the renderer's.
    var authoredDash = false;
    for (i = 0; i < model.edges.length; i += 1) {
      if (model.edges[i].pattern === "dotted") { authoredDash = true; break; }
    }
    if (model.clusters.length > 0 && !authoredDash) {
      var crossing = [];
      for (i = 0; i < model.edges.length; i += 1) {
        var e = model.edges[i];
        if (e.pattern === "dotted" || e.pattern === "invisible") continue;
        var a = model.nodeById.get(e.from);
        var b = model.nodeById.get(e.to);
        if (!a || !b) continue;
        if (a.parent && b.parent && a.parent !== b.parent) crossing.push(e);
      }
      // Capped so it stays a category rather than becoming the default stroke.
      if (crossing.length > 0 && crossing.length <= 6 && crossing.length * 3 <= model.edges.length) {
        for (i = 0; i < crossing.length; i += 1) { crossing[i].kind = "cross"; counts.cross += 1; }
      }
    }

    return counts;
  }

  // ===========================================================================
  // Ports.
  //
  // dd-arch.md's port-selection rule: leave and arrive perpendicular to the boundary, on the faces
  // the rank axis points at. Entering a node from the side on a mainly-vertical path reads as the
  // arrow puncturing the node face rather than arriving from above.
  //
  // Then SKILL.md §6 rule 4, which is the part a layered layout has to do and a router cannot: when
  // several connectors share a face they each get their own attach point, spread at L*k/(N+1). Two
  // arrows landing on one point is a hard fail there, and it is a fail the router could not repair
  // without moving a box.
  // ===========================================================================

  var FORWARD_SIDES = {
    TB: ["bottom", "top"],
    BT: ["top", "bottom"],
    LR: ["right", "left"],
    RL: ["left", "right"]
  };

  function centreX(box) { return box.x + box.w / 2; }
  function centreY(box) { return box.y + box.h / 2; }

  function chooseSides(edge, dir) {
    var vertical = (dir === "TB" || dir === "BT");
    var a = edge.fromChild;
    var b = edge.toChild;
    if (edge.selfLoop) return vertical ? ["right", "right"] : ["bottom", "bottom"];

    var ranked = !edge.boundary
      && edge.a && edge.b
      && edge.a.rank !== undefined && edge.b.rank !== undefined
      && edge.a.rank !== edge.b.rank;
    if (ranked) {
      var pair = FORWARD_SIDES[dir];
      return (edge.b.rank > edge.a.rank) ? [pair[0], pair[1]] : [pair[1], pair[0]];
    }

    // Same rank, or an edge between a container and something inside it: there is no rank to read,
    // so the geometry decides. Along the order axis first, because that is the short way round.
    var da = vertical ? centreX(b) - centreX(a) : centreY(b) - centreY(a);
    if (da > 0) return vertical ? ["right", "left"] : ["bottom", "top"];
    if (da < 0) return vertical ? ["left", "right"] : ["top", "bottom"];
    var dr = vertical ? centreY(b) - centreY(a) : centreX(b) - centreX(a);
    if (dr > 0) return vertical ? ["bottom", "top"] : ["right", "left"];
    if (dr < 0) return vertical ? ["top", "bottom"] : ["left", "right"];
    return vertical ? ["right", "right"] : ["bottom", "bottom"];
  }

  function faceLength(box, side) {
    return (side === "top" || side === "bottom") ? box.w : box.h;
  }

  function portPoint(box, side, offset, inset) {
    if (side === "top") return { x: box.x + offset, y: box.y + inset };
    if (side === "bottom") return { x: box.x + offset, y: box.y + box.h - inset };
    if (side === "left") return { x: box.x + inset, y: box.y + offset };
    return { x: box.x + box.w - inset, y: box.y + offset };
  }

  // ---------------------------------------------------------------------------
  // Where the outline actually is.
  //
  // A face of the bounding box is the outline for the rectangle, and for the subroutine that is a
  // rectangle with two bars drawn inside it. For the other thirteen it is not: a rhombus meets its
  // bottom face at the single point of its apex, a stadium only between its two end radii, a
  // cylinder's lid only where it crests. A port left on the face hangs in mid-air beside the shape
  // it is attached to, which is exactly what a rendered decision diagram showed -- both branches
  // leaving the rhombus started below the outline with daylight under them.
  //
  // The port therefore sinks INWARD ALONG THE FACE NORMAL until it reaches the outline. Along the
  // normal and not along the face, because the first segment of every route leaves on that normal
  // (routeEdge's stub): sliding the port sideways to where the outline happens to touch the box
  // would keep the arithmetic exact and make the connector diagonal, which SKILL.md §6 rule 1 calls
  // an automatic fail. Sinking moves the point the route starts from and changes nothing about the
  // direction it starts in.
  //
  // The depths below mirror shapeMarkup's own path data -- the same K, the same radii, the same
  // vertices -- because those two are the only description of these outlines the file has. They are
  // not trusted to agree: Tests/JavaScript/flow/ports.spec.js parses the `d` and `points` the
  // emitter writes and measures every port against that, which is the check a second model of the
  // same shape cannot give itself.
  // ---------------------------------------------------------------------------

  // shapeMarkup writes these three in px; everything here counts in grid units.
  var ROUND_R = 2;    // `rx="8"` on a (round) rect.
  var CYL_LID = 2;    // `K = Math.min(8, H)`, the cylinder's lid depth.
  var ODD_NOTCH = 2;  // `K = Math.min(8, W)`, how far the odd shape's left notch bites in.

  // How far under `side` the outline runs, in grid units, at `t` along that face from its centre --
  // signed towards +x on the top and bottom faces and towards +y on the left and right ones, which
  // is the frame shapeMarkup draws in. W and H are half the box, as they are there.
  function outlineDepth(geometry, W, H, side, t) {
    var vertical = (side === "top" || side === "bottom");
    // Half the face's own length, and half the box's depth under it.
    var A = vertical ? W : H;
    var B = vertical ? H : W;
    var a = Math.abs(t);
    var K, flat, R;
    switch (geometry) {
      case "round":
        R = Math.min(ROUND_R, A, B);
        flat = A - R;
        return a <= flat ? 0 : R - Math.sqrt(Math.max(0, R * R - (a - flat) * (a - flat)));
      case "stadium":
        // The cap is written with radius min(W,H) between two ends 2H apart, and SVG scales a
        // radius too small to reach both ends up until it does -- so the arc that gets drawn has
        // radius H whichever way round the box is, centred on the cap's straight edge.
        K = Math.min(W, H);
        if (vertical) {
          flat = W - K;
          return a <= flat ? 0 : H - Math.sqrt(Math.max(0, H * H - (a - flat) * (a - flat)));
        }
        // Negative when the scaled-up cap bulges past the box, which is a tall stadium's drawing
        // rather than this function's: the face is already inside the shape, so it does not sink.
        return Math.max(0, K - Math.sqrt(Math.max(0, H * H - a * a)));
      case "circle":
      case "doublecircle":
      case "ellipse":
        // One formula for all three: shapeBox makes a circle's box square and doublecircle's outer
        // ring is the one an edge can touch.
        return B - B * Math.sqrt(Math.max(0, 1 - (a / A) * (a / A)));
      case "diamond":
        return B * a / A;
      case "hexagon":
        K = Math.min(W, H);
        if (vertical) { flat = W - K; return a <= flat ? 0 : H * (a - flat) / K; }
        return K * a / H;
      case "cylinder":
        K = Math.min(CYL_LID, H);
        if (vertical) return K - K * Math.sqrt(Math.max(0, 1 - (a / W) * (a / W)));
        flat = H - K;
        return a <= flat ? 0 : W - W * Math.sqrt(Math.max(0, 1 - ((a - flat) / K) * ((a - flat) / K)));
      case "lean-r":
        K = Math.min(W, H);
        if (side === "top") return t >= K - W ? 0 : 2 * H * ((K - W) - t) / K;
        if (side === "bottom") return t <= W - K ? 0 : 2 * H * (t - (W - K)) / K;
        if (side === "left") return K * (H - t) / (2 * H);
        return K * (t + H) / (2 * H);
      case "lean-l":
        K = Math.min(W, H);
        if (side === "top") return t <= W - K ? 0 : 2 * H * (t - (W - K)) / K;
        if (side === "bottom") return t >= K - W ? 0 : 2 * H * ((K - W) - t) / K;
        if (side === "left") return K * (t + H) / (2 * H);
        return K * (H - t) / (2 * H);
      case "trap-t":
        K = Math.min(W, H);
        if (side === "bottom") return 0;
        if (side === "top") { flat = W - K; return a <= flat ? 0 : 2 * H * (a - flat) / K; }
        return K * (H - t) / (2 * H);
      case "trap-b":
        K = Math.min(W, H);
        if (side === "top") return 0;
        if (side === "bottom") { flat = W - K; return a <= flat ? 0 : 2 * H * (a - flat) / K; }
        return K * (t + H) / (2 * H);
      case "odd":
        K = Math.min(ODD_NOTCH, W);
        return side === "left" ? K * (H - a) / H : 0;
      default:
        // rect, and subroutine: its two inner bars are decoration inside a plain rectangle.
        return 0;
    }
  }

  // Grid units are integers (see "The grid"), and an outline crosses a grid point only where its
  // slope is rational in the right way -- the 88x48px rhombus in the render corpus meets one at
  // its four apexes and nowhere else, so its bottom face has exactly one grid point on the outline
  // and rule 4 wants three. So the depth has to be rounded, and there is only one safe direction:
  // a port a fraction PROUD of the outline draws the gap this whole section exists to close, while
  // a port a fraction inside it is covered, because nodes are painted after every edge (emit's
  // painters order, asserted in render.spec.js). Hence up to the next whole unit, not the nearest.
  //
  // Measured off the emitted paths, every geometry on every face, three connectors to a face: 312
  // of 360 ports land exactly on the outline -- 308 until `slopesOf` moved a vertex's three off the
  // point and onto its slopes -- none lands outside it, and the deepest any sank past it is
  // 3.63px, under one grid step, which is what ceil() can cost. ports.spec.js holds those three
  // numbers.
  var DEPTH_EPS = 1e-9;

  function portInset(geometry, box, side, t) {
    if (geometry === "rect") return 0;
    var d = outlineDepth(geometry, box.w / 2, box.h / 2, side, t);
    if (!(d > 0)) return 0;
    return Math.ceil(d - DEPTH_EPS);
  }

  // The stretch of a face whose ports can reach the outline without sinking past the shape's own
  // middle. It is the whole face for eleven of the fifteen; the four it trims are the two
  // parallelograms and the two trapezoids, whose slanted ends run the full height of the box, so
  // the outer corner of such a face is two half-depths down. A port that sank that far would be on
  // the far half of the outline and its stub would leave through a face it was never attached to,
  // so those offsets are not offered and the fan spreads over what is left -- on an 88x48 box that
  // is 12px off one or both ends of the slanted faces, and nothing anywhere else.
  function portSpan(geometry, box, side) {
    var L = faceLength(box, side);
    if (geometry === "rect") return { lo: 0, hi: L };
    var B = ((side === "top" || side === "bottom") ? box.h : box.w) / 2;
    var half = L / 2;
    var lo = 0;
    var hi = L;
    var o;
    // Outward from the middle, which every geometry above touches at depth 0, so the run this
    // finds is the contiguous one the fan has to stay inside.
    for (o = half; o >= 0; o -= 1) {
      if (portInset(geometry, box, side, o - half) > B) { lo = o + 1; break; }
    }
    for (o = half; o <= L; o += 1) {
      if (portInset(geometry, box, side, o - half) > B) { hi = o - 1; break; }
    }
    return { lo: lo, hi: hi };
  }

  // ---------------------------------------------------------------------------
  // Where along a face a connector SHOULD land.
  //
  // `portSpan` answers where a port may go without sinking past the shape's own middle. That is not
  // the same question, and a rendered decision flowchart is the difference: every port on the
  // rhombus was on its outline and none of them was where a reader would draw one. The arrow in
  // landed a third of the way down the upper-right slope and both branches left from the lower
  // slopes, and a vertical arrow meeting a slanted edge reads as a mistake whatever the arithmetic
  // says.
  //
  // So a face has a LANDING RUN: the stretch of it whose outline both lies ON the face and faces the
  // direction a connector arrives from. Read off `outlineDepth`, the same description of the shape
  // the sink uses, it sorts the fifteen geometries into three kinds of face:
  //
  //   * A FLAT RUN -- a rectangle's face, the middle of a hexagon's or a trapezoid's, the straight
  //     between a stadium's two caps. The run is that stretch less the corners at each end, where
  //     the outline turns away from the face. Ports fan across it and keep every alignment the
  //     previous round won.
  //   * A VERTEX -- a rhombus's apex, a hexagon's or a stadium's or a circle's extreme point, a
  //     cylinder's crest. The outline touches the face at one point and falls away on both sides, so
  //     that point is the whole run: the first connector lands ON it and further ones spread around
  //     it at the minimum pitch, which is rule 4's answer to two edges wanting one point. mermaid
  //     attaches a decision node at its apex and so does diagram-design; this is that, derived from
  //     the shape rather than special-cased for it.
  //   * NEITHER -- the skewed side of a parallelogram or a trapezoid, whose extreme point is a
  //     CORNER and therefore disqualified for the same reason the rectangle's corners are, and the
  //     notch of `>odd]`, whose middle is its deepest point rather than its nearest. There is no
  //     vertex to attach to, so the fan keeps to the middle of what `portSpan` allows, which is
  //     where those ports already were.
  //
  // Rejected for the vertex, where rule 4 forbids two edges the one point it offers: sending the
  // second edge to another face. On the Korean decision source the rhombus is drawn at x 24..240
  // with its two branches feeding boxes at 56..144 and 176..296, so a branch put on the LEFT vertex
  // would leave at x=24 -- 76px the wrong side of the box it feeds -- and have to come back under
  // the shape it started from. The fork the pitch gives instead leaves both branches within 8px of
  // the apex, which is how a decision node is drawn everywhere anyone draws one. Also rejected:
  // widening the box, which changes a rhombus's slope and never gives it a flat face to land on.
  // ---------------------------------------------------------------------------

  // The theme rounds a bare rect to 6px in CSS -- `.node rect.basic:not([rx])`, MacMermaidTheme.swift
  // -- and `shapeMarkup` writes no rx for it, so `outlineDepth` cannot see that corner and calls the
  // face flat right up to it. Rounded up to the grid: a port 8px in from the corner is on the
  // straight part of the painted border with 2px to spare, where one ON the corner was left about
  // 2.5px outside the paint with nothing behind its arrowhead.
  var RECT_CSS_R = 2;
  // One more step in from wherever the outline turns. The turn itself is a tangent point: the
  // painted line there runs PARALLEL to the arriving arrow, which is what made two arrows into a
  // stadium's left cap read as grazing the pill rather than entering it.
  var TURN_BACKOFF = 1;
  // How far the outline may fall away under a face, per grid step along it, and still count as
  // facing the connector: half a step, which is 26.6° off head-on.
  var FACING_SLOPE = 0.5;

  function clampInto(value, lo, hi) {
    return Math.min(hi, Math.max(lo, value));
  }

  function landingRun(geometry, box, side, span) {
    var L = faceLength(box, side);
    // Whole, because `layout` rounds every box to an even number of grid units on both axes.
    var mid = L / 2;
    var W = box.w / 2;
    var H = box.h / 2;
    var on = function (o) { return !(outlineDepth(geometry, W, H, side, o - mid) > DEPTH_EPS); };
    // Where the painted outline stops running along the face, at whichever end. For every geometry
    // but the plain rectangle `outlineDepth` puts that point exactly, and it is a TANGENT point --
    // the paint there is parallel to the arriving arrow -- so the run gives up one more step, which
    // also keeps the 6px-wide arrowhead a pixel clear of a sharp corner. A rect's turn is the
    // theme's 6px CSS radius, which rounds to 8px of trim on its own and lands 2px inside the
    // straight part of the border; a second step there would cost alignment for nothing.
    var back = (geometry === "rect") ? RECT_CSS_R : TURN_BACKOFF;
    var lo = mid;
    var hi = mid;
    var run;
    if (on(mid)) {
      while (lo - 1 >= 0 && on(lo - 1)) lo -= 1;
      while (hi + 1 <= L && on(hi + 1)) hi += 1;
    }
    if (on(mid) && hi > lo) {
      run = { lo: lo + back, hi: hi - back };
      // A face too short to give both corners their clearance keeps its middle rather than nothing.
      if (run.lo > run.hi) run = { lo: (lo + hi) / 2, hi: (lo + hi) / 2 };
    } else if (on(mid)) {
      // The outline touches the face at one point and falls away on both sides. Whether a connector
      // may use anything but that point is the difference between a corner and a curve, and the
      // depth says which: an outline that leaves a vertex along a straight line has a constant
      // second difference of zero, while a curve's rises.
      //
      // A vertex gets nothing else. Its slope is the same all the way along -- a rhombus is 28.6°
      // at 88x48 and 12.5° at the 216x48 the Korean decision node is drawn at -- so no angle test
      // separates a good landing from a bad one there: what the eye reads is the POINT, and the
      // arrow that read as a mistake was 36px along the slope from it on the wide one and 28px on
      // the 192x48 one in `A[Start] --> B{Is it ready?}`.
      //
      // A curve has no such point, only the stretch that still faces the arrow. It is taken at a
      // depth slope of half a grid step per step -- about 26° off head-on at the far end -- which on
      // a circle or a stadium's cap works out at half the radius either side of the crest, and on a
      // cylinder's much shallower lid at nearly the whole face. It is what keeps a port off the
      // TANGENT POINTS, where the painted outline runs parallel to the arrow: two arrows into a
      // stadium's left cap landed on exactly those and read as grazing the pill.
      var depthAt = function (o) { return outlineDepth(geometry, W, H, side, o - mid); };
      var d1 = depthAt(mid + 1);
      var d2 = depthAt(mid + 2);
      if (mid + 2 > L || Math.abs(d2 - 2 * d1) <= DEPTH_EPS) {
        run = { lo: mid, hi: mid };
      } else {
        // The slope AT the offset being considered, as the central difference across it -- not the
        // step that arrives there. A cylinder's lid is shallow for eight of its ten steps and then
        // turns into the rim: the arriving step still reads 0.4 at the offset whose own slope is
        // already 0.65, and a port there lands on the rim rather than on the lid.
        var slopeAt = function (o) {
          var a = Math.max(0, o - 1);
          var b = Math.min(L, o + 1);
          return b > a ? (depthAt(b) - depthAt(a)) / (b - a) : 0;
        };
        var reach = 0;
        while (mid + reach + 1 <= L && slopeAt(mid + reach + 1) <= FACING_SLOPE) reach += 1;
        run = { lo: mid - reach, hi: mid + reach };
      }
    } else {
      run = { lo: span.lo + TURN_BACKOFF, hi: span.hi - TURN_BACKOFF };
      if (run.lo > run.hi) run = { lo: mid, hi: mid };
    }
    run.lo = Math.round(clampInto(run.lo, span.lo, span.hi));
    run.hi = Math.round(clampInto(run.hi, span.lo, span.hi));
    if (run.hi < run.lo) run.hi = run.lo;
    // The box's own middle whenever the run reaches it, which is what keeps a lone connector between
    // two boxes on one centre line straight -- including on the four skewed geometries, whose run is
    // not centred under the node (straight.spec.js's parallelogram).
    run.anchor = clampInto(mid, run.lo, run.hi);
    // The same clearance measured off the FACE's own ends, for the placements that cannot stay
    // inside the run at all -- a fan too big for it, or a cluster straddling a vertex. Without it
    // four connectors on a 48px face took the 16px pitch, filled the face exactly and put their
    // outer two on the corners.
    run.innerLo = Math.min(span.lo + back, run.anchor);
    run.innerHi = Math.max(span.hi - back, run.anchor);
    return run;
  }

  // Every port on one point, at the minimum pitch, in the order the group is already in.
  //
  // Even counts take a 16px pitch rather than 12 so the block stays symmetric about the vertex AND
  // on the 4px grid -- 12px symmetric is ±6px, which is neither. Odd counts put their middle member
  // exactly on the vertex. Measured over 418 sources: 290 ports on a rhombus, 106 of them the only
  // connector on their face and 120 of them exactly on the vertex -- the other 14 being the middle
  // member of a fan of three or five.
  function clusterAt(anchor, N, run, span) {
    if (N >= 3 && run.lo === run.hi) return slopesOf(anchor, N, span);
    // The wider pitch is a nicety and the first thing given up: four connectors on a 48px face took
    // 16px each, filled the face exactly, and landed their outer two ON the corners -- which is the
    // defect the landing run exists to stop.
    var pitch = (N % 2 === 1) ? MIN_PITCH : MIN_PITCH + 1;
    if (pitch * (N - 1) > run.innerHi - run.innerLo) pitch = MIN_PITCH;
    var width = pitch * (N - 1);
    if (width > span.hi - span.lo) return spreadOf(span, N);
    // Rounded, because an even count at the odd pitch has a half-unit centre and every offset here
    // is whole; the half-unit is spent on one side of the vertex rather than smeared over both.
    var start = Math.round(anchor - width / 2);
    start = (width <= run.innerHi - run.innerLo)
      ? clampInto(start, run.innerLo, run.innerHi - width)
      : clampInto(start, span.lo, span.hi - width);
    var out = [];
    for (var k = 0; k < N; k += 1) out.push(start + pitch * k);
    return out;
  }

  // Three or more connectors on a vertex: both slopes, not the point.
  //
  // The cluster above is right for TWO -- a decision's yes and no leave the apex 16px apart and
  // diverge at once, which is what `60fae7a` built and what every one of the eighteen tuned sources
  // needed, since none of them had a diamond with a third exit. The held-out review's did: three
  // answers off 승인 응답 코드's tip at a 12px pitch and four off h13's Response ran down together
  // until each turned, and a reader could not tell which of the labels below belonged to which
  // line. Pele leaves such a diamond from points along its two lower edges. This is that, the
  // cluster's own rule carried on: the middle member of an odd count stays ON the vertex, and the
  // rest stand out along the slopes, evenly, at the step that divides the face into N + 1 -- so no
  // port is nearer the side corners than the step, and each is at least two pitches from the next.
  // Measured on the held-out sources: 승인 응답 코드's three exits went from 12px apart to 36, h13's
  // Response's four from 16 to 24, h20's Category's four from 16 to 24, h09's deploy decision's
  // three from 12 to 52.
  //
  // Rejected: the third exit on a side vertex.
  // The rejection beside `landingRun` still holds -- a branch off the side vertex leaves from the
  // far side of the box it feeds and has to come back under the shape it started from. Also
  // rejected: spreading two exits the same way. A pair already diverges at the apex, the tuned
  // sources were read with them that way, and the lane `60fae7a` hugs is sized for that pair.
  function slopesOf(anchor, N, span) {
    var step = Math.floor((span.hi - span.lo) / (N + 1));
    // A face too short to carry the spread at twice the pitch keeps the cluster's behaviour.
    if (step < 2 * MIN_PITCH) return spreadOf(span, N);
    var start = anchor - Math.round(step * (N - 1) / 2);
    start = clampInto(start, span.lo + step, span.hi - step - step * (N - 1));
    var out = [];
    for (var k = 0; k < N; k += 1) out.push(start + step * k);
    return out;
  }

  function assignPorts(model) {
    var attachments = [];
    var i;
    for (i = 0; i < model.edges.length; i += 1) {
      var edge = model.edges[i];
      var level = model.levels.get(edge.level);
      var dir = level ? level.dir : "TB";
      var sides = chooseSides(edge, dir);
      edge.startSide = sides[0];
      edge.endSide = sides[1];
      edge.startAtt = { edge: edge, end: 0, box: edge.fromChild, side: edge.startSide, other: edge.toChild };
      edge.endAtt = { edge: edge, end: 1, box: edge.toChild, side: edge.endSide, other: edge.fromChild };
      attachments.push(edge.startAtt, edge.endAtt);
    }

    var groups = new Map();
    for (i = 0; i < attachments.length; i += 1) {
      var att = attachments[i];
      var key = att.box.kind + " " + att.box.id + " " + att.side;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(att);
    }

    // Every face exists before any desire is read, because a desire is read off the OTHER end's
    // face and a face that did not exist yet could only be guessed at.
    var faces = [];
    groups.forEach(function (group) {
      var box = group[0].box;
      var side = group[0].side;
      var alongX = (side === "top" || side === "bottom");
      var geometry = (box.kind === "node") ? geometryOf(box.shape) : "rect";
      // The face, kept whole after the placement has run on it, because one more pass needs to know
      // what else is attached here before it may move anything: `alignUnitJog`.
      var span = portSpan(geometry, box, side);
      var face = {
        box: box,
        side: side,
        geometry: geometry,
        span: span,
        run: landingRun(geometry, box, side, span),
        // Which coordinate an offset along this face moves, and what offset 0 is in the drawing's
        // own frame -- `portPoint` adds the offset to box.x on the horizontal faces and to box.y on
        // the vertical ones.
        alongX: alongX,
        base: alongX ? box.x : box.y,
        group: group,
        desires: [],
        offsets: []
      };
      // A face the shape has already answered for: its run is one point, or it is too short to hold
      // this many ports at the pitch. Nothing attached to it can move along it, so it is placed
      // before any desire is read and the free ends aim at the result.
      face.fixed = face.run.hi === face.run.lo
        || face.run.hi - face.run.lo < MIN_PITCH * (group.length - 1);
      for (var g = 0; g < group.length; g += 1) {
        group[g].face = face;
        group[g].desire = clampToRun(face, faceCentre(face));
      }
      faces.push(face);
    });

    // Fixed faces first, in the order the far ends stand along this face -- the fan's own order,
    // since a fixed face has no desires to sort by and two ports crossing before they have left the
    // box is the thing the order exists to prevent.
    //
    // "Where the far end stands" is `headingOf`, the same key the free faces break ties by, and not
    // the far box's centre, which is what this sorted by until the held-out review's h03: an answer
    // sent back up a corridor leaves the vertex towards that corridor, wherever its far box is.
    // 재시도's 예 went back to 결제 요청 생성, left of the tip, down a corridor on the far right, so
    // by box centre it took the tip's left port and crossed the arrow coming in from 결제 실패 처리
    // on its way right. `long back edge` TD and BT drew the same knot under Check.
    for (i = 0; i < faces.length; i += 1) {
      var fx = faces[i];
      if (!fx.fixed) continue;
      fx.group.sort(function (p, q) {
        var pk = headingOf(fx, p, model);
        var qk = headingOf(fx, q, model);
        if (pk !== qk) return pk - qk;
        if (p.edge.index !== q.edge.index) return p.edge.index - q.edge.index;
        return p.end - q.end;
      });
      recordSlots(fx);
      fx.offsets = clusterAt(fx.run.anchor, fx.group.length, fx.run, fx.span);
      settleFace(fx, fx.group);
    }

    for (i = 0; i < model.edges.length; i += 1) desirePorts(model.edges[i], model);

    mirrorForks(faces, model);

    for (i = 0; i < faces.length; i += 1) {
      var f = faces[i];
      if (f.fixed) continue;
      // Ordered by what each attachment wants, so the attach points come off the face in the order
      // the arrows fan out and none of them has to cross its neighbour before it has left the box.
      // The old key was the other end's centre along this axis, which is the same order whenever the
      // desire IS that centre -- but not when it is a corridor or a clamped meeting point, and
      // `placeFace` reads an order it cannot reorder. On B's bottom face in `A --> B / B -.-> C /
      // C --> D / A --> D / B --> D / C --> A`, that key put a desire of 17 units in the slot before
      // a desire of 4, and the two ports that wanted to be 13 apart were pulled to 9 and 12.
      // A self-loop puts both of its ends in one group, which is also what stops them landing on the
      // same point.
      //
      // Ties go to where each end is headed next, which for an edge handed a corridor is that
      // corridor rather than its far box: two ends leaning to the same end of a run tie, and once
      // they did, on A's bottom face in the dense review source the edge to M -- whose corridor runs
      // outside everything on the right while M itself stands left of D -- was slotted inside
      // A --> D by M's centre and crossed it on the way out.
      var byDesire = function (p, q) {
        if (p.desire !== q.desire) return p.desire - q.desire;
        var pk = headingOf(f, p, model);
        var qk = headingOf(f, q, model);
        if (pk !== qk) return pk - qk;
        if (p.edge.index !== q.edge.index) return p.edge.index - q.edge.index;
        return p.end - q.end;
      };
      f.group.sort(byDesire);
      if (isInverted(f, model) || unalignsAny(f)) {
        // An end whose desire something else has since set -- `mirrorForks` -- keeps that one.
        for (var g3 = 0; g3 < f.group.length; g3 += 1) {
          var leaning = f.group[g3];
          if (leaning.lean && leaning.desire === leaning.lean.from) leaning.desire = leaning.lean.desire;
        }
        f.group.sort(byDesire);
      }
      for (var g2 = 0; g2 < f.group.length; g2 += 1) f.desires.push(f.group[g2].desire);
      recordSlots(f);
      f.offsets = placeFace(f);
      settleFace(f, f.group);
    }

    for (i = 0; i < model.edges.length; i += 1) alignUnitJog(model.edges[i], model);
  }

  // Where an end goes after it leaves its face, along that face: the corridor it was handed, or the
  // far box when it reaches that directly.
  //
  // Directly, the far PORT where the far face runs along the same axis: where that end has asked to
  // land, which `mirrorForks` has already settled by the time any face is sorted. The far box's
  // centre cannot tell two edges between the same two boxes apart, so on one face they tied and
  // fell to declaration order while the far face, where their desires differ, put them the other
  // way round -- and they crossed between the two. The held-out review's h04 did that at Advertising
  // and Pairing: Advertising's fork mirrored "central connects"'s landing one unit below where
  // "passkey wrong x3" leaves Pairing at the two boxes' meeting point, and on Advertising's face the
  // two tied at that meeting point. Only for a face on the same axis: a far face across this one
  // stands at one coordinate whatever the desire, and its box's centre is as good an answer there.
  //
  // A far box behind a zone that holds neither end is not where the route heads first: the route
  // goes round that zone (no connector enters a foreign zone), and round the side nearer this face.
  // In 08, once App Server 2 stood left of App Server 1, its edges to Primary and to S3 Bucket tied
  // -- both far boxes are centred on one x -- and the edge index put S3's port on the right, so
  // its route left round the left of the Database Tier from the right-hand port and shared 8px
  // with the edge to Primary under the box. Heading for the zone's near side is what it does.
  //
  // A NODE standing in the gap across the far box's line is passed the same way, and for the same
  // reason. In the review's mesh source Worker West A's right face carries Router West's edge in and
  // the two `replicate` edges to and from Worker East A; all three tie on the face's middle, and by
  // far centres Router West (31 units) sorts ahead of Worker East A (33), so the router edge took
  // the top port. But Router West stands between the face and Worker East A, across that line, and
  // both replicate routes go over it -- so both crossed the router edge beside the face (two bumps
  // within 30px of three line ends), and the one leaving stepped past the one arriving onto a lane
  // 4px from it for 522px, which read as one doubled line. Heading for Router West's near side
  // slots the replicate ends above the router edge: no bump at the face, and the pair 12px apart,
  // a port pitch. Over differential.mjs's drawings it also took the three crossings left in
  // `nested subgraphs` LR and RL and the 8-line LR specimen to 0 -- Z's two ports there were the
  // inverted pair the elbow-slide comment names -- and bends 576 -> 570.
  function headingOf(face, att, model) {
    var via = att.edge.via || [];
    var level = model.levels.get(att.edge.level);
    if (via.length > 0 && level) return viaAlong(face, level, att.end === 0 ? via[0] : via[via.length - 1]);
    var farAtt = att.end === 0 ? att.edge.endAtt : att.edge.startAtt;
    var far = face.alongX ? centreX(att.other) : centreY(att.other);
    if (farAtt && farAtt.face && farAtt.face.alongX === face.alongX && farAtt.face !== face) far = farAtt.face.base + farAtt.desire;
    var box = face.box;
    var other = att.other;
    var mine = ancestry(att.edge.from, model.parentOf).concat(ancestry(att.edge.to, model.parentOf));
    var lo = face.alongX ? Math.min(box.y + box.h, other.y + other.h) : Math.min(box.x + box.w, other.x + other.w);
    var hi = face.alongX ? Math.max(box.y, other.y) : Math.max(box.x, other.x);
    var nearest = null;
    for (var z = 0; z < model.clusters.length; z += 1) {
      var zone = model.clusters[z];
      if (mine.indexOf(zone.id) >= 0) continue;
      var zLo = face.alongX ? zone.y : zone.x;
      var zHi = face.alongX ? zone.y + zone.h : zone.x + zone.w;
      var aLo = face.alongX ? zone.x : zone.y;
      var aHi = face.alongX ? zone.x + zone.w : zone.y + zone.h;
      if (zLo < lo || zHi > hi || far <= aLo || far >= aHi) continue;
      if (nearest === null || Math.abs(zLo - lo) < Math.abs(nearest.lo - lo)) nearest = { lo: zLo, aLo: aLo, aHi: aHi };
    }
    for (var n = 0; n < model.nodes.length; n += 1) {
      var node = model.nodes[n];
      if (node === box || node === other) continue;
      var nLo = face.alongX ? node.y : node.x;
      var nHi = face.alongX ? node.y + node.h : node.x + node.w;
      var bLo = face.alongX ? node.x : node.y;
      var bHi = face.alongX ? node.x + node.w : node.y + node.h;
      if (nLo < lo || nHi > hi || far <= bLo || far >= bHi) continue;
      if (nearest === null || Math.abs(nLo - lo) < Math.abs(nearest.lo - lo)) nearest = { lo: nLo, aLo: bLo, aHi: bHi };
    }
    if (nearest === null) return far;
    var centre = face.base + faceCentre(face);
    return (centre - nearest.aLo <= nearest.aHi - centre) ? nearest.aLo : nearest.aHi;
  }

  // Which slot of its face each end of each edge holds, so the two passes after placement --
  // `settleFace` and `alignUnitJog` -- can find the port again.
  function recordSlots(face) {
    for (var g = 0; g < face.group.length; g += 1) {
      if (face.group[g].end === 0) {
        face.group[g].edge.startFace = face;
        face.group[g].edge.startSlot = g;
      } else {
        face.group[g].edge.endFace = face;
        face.group[g].edge.endSlot = g;
      }
    }
  }

  // The offset that puts a port under the middle of its own box. Always inside the span: every
  // geometry's outline touches the middle of every face at depth 0, and `portSpan` grows outward
  // from exactly there. A whole unit, because `layout` rounds every box to an even number of grid
  // units on both axes (`even`).
  function faceCentre(face) {
    return (face.alongX ? centreX(face.box) : centreY(face.box)) - face.base;
  }

  // Every desire is clamped to the LANDING RUN rather than to the span the shape allows: a desire
  // outside the run is one the placement may not grant, and clamping it where it will actually be
  // granted keeps the PAVA blocks honest about what they are allowed to reach.
  function clampToRun(face, offset) {
    return Math.min(face.run.hi, Math.max(face.run.lo, offset));
  }

  // Where each end of an edge would go if nothing else were attached to its face: the offset that
  // lines the port up with the next place the route has to reach.
  //
  // The default set above is the box's own middle, and that alone is half the defect this replaced.
  // `Trapezoid --> Parallelogram` in the shapes corpus is two boxes on one centre line with one
  // connector between them, and it still bent 8px: a parallelogram's top face is outline only
  // between its two skewed ends, `portSpan` trims what is left, and the fan centred itself on that
  // TRIMMED run rather than on the box. The port came out two units right of the box's own middle
  // with nothing else on the face to blame.
  function desirePorts(edge, model) {
    var s = edge.startAtt;
    var e = edge.endAtt;
    if (!s || !e || !s.face || !e.face) return;
    if (edge.selfLoop) {
      // Both ends are on one face, so neither can line up with the other, and how far apart they
      // sit is how wide the loop is drawn. The spread the face would give a lone pair is what set
      // that before, so it is what they ask for now.
      var feet = spreadOf(s.face.span, 2);
      s.desire = feet[0];
      e.desire = feet[1];
      return;
    }
    var level = model.levels.get(edge.level);
    var via = edge.via || [];
    if (via.length > 0 && level) {
      // A multi-rank edge is handed a corridor to travel down, and the corridor -- not the far port
      // -- is the first station its stub has to meet. Lining up with it closes the jog at BOTH ends,
      // because the same corridor is also the last station before the far port.
      s.desire = clampToRun(s.face, viaAlong(s.face, level, via[0]) - s.face.base);
      e.desire = clampToRun(e.face, viaAlong(e.face, level, via[via.length - 1]) - e.face.base);
      s.aligned = true;
      e.aligned = true;
      return;
    }
    // One end the shape has already placed. The free end aims at THAT, which is the only reading
    // that can still come out straight -- a fixed port cannot move towards anything, and letting it
    // try is what put the arrow a third of the way down the rhombus's slope.
    if (s.face.fixed !== e.face.fixed && s.face.alongX === e.face.alongX) {
      var fixedPoint = s.face.fixed ? edge.startPoint : edge.endPoint;
      var free = s.face.fixed ? e : s;
      if (fixedPoint) {
        free.desire = clampToRun(free.face, (free.face.alongX ? fixedPoint.x : fixedPoint.y) - free.face.base);
        free.aligned = true;
      }
      return;
    }
    if (s.face.fixed || e.face.fixed) return;
    // Nothing between them: the two ports are each other's next station, so "in line" is one
    // coordinate that both of them take. Halfway between the two box centres is the choice that
    // does not favour one box over the other, and where only one of them can reach that, the
    // nearest coordinate both landing runs hold is taken instead.
    //
    // Clamping into the overlap was rejected while the runs were the whole face: where two boxes
    // barely overlap, the answer a clamp finds is their touching corners, and a connector leaving
    // the very corner of a box reads worse than the jog it replaces. A landing run ends 4-8px short
    // of every corner, so the overlap of two of them cannot BE a corner any more -- and the clamp
    // pays for itself. Measured over 418 sources and 2694 connectors: 978 single-segment
    // connectors with it, 897 with the strict "both faces reach the midpoint" test it replaced.
    if (s.face.alongX === e.face.alongX) {
      var lo = Math.max(s.face.run.lo + s.face.base, e.face.run.lo + e.face.base);
      var hi = Math.min(s.face.run.hi + s.face.base, e.face.run.hi + e.face.base);
      if (lo <= hi) {
        var meet = Math.min(hi, Math.max(lo,
          Math.round((faceCentre(s.face) + s.face.base + faceCentre(e.face) + e.face.base) / 2)));
        s.desire = meet - s.face.base;
        e.desire = meet - e.face.base;
        s.aligned = true;
        e.aligned = true;
      } else {
        s.lean = leanOf(s, e);
        e.lean = leanOf(e, s);
      }
    }
  }

  // An end that cannot line up with its far end still knows which way the far end lies, and on a
  // face it shares that is the one thing its slot must agree with. Left at the face's middle, it
  // asks for the same offset as every other end that cannot go straight, while an end that CAN go
  // straight asks for its own meeting point -- and the face is sorted by desire, so the straight
  // end is slotted by where it is straight and the rest around the middle, and the two orders can
  // disagree. That was the whole of three reader-reported crossings: Notifications took the
  // Central Event Bus's leftmost port and crossed the four arms from further left, License Check
  // took Release Pipeline's rightmost and crossed five, and App Server 1's edge up to NAT Gateway
  // left to the LEFT of the edge arriving from Load Balancer with NAT Gateway on the right.
  //
  // So such an end may instead ask for the end of its landing run nearest the far box: the order it
  // sorts into is then the order the far ends stand in, and `placeFace` still owns the spacing.
  // Sorting the face by the far ends and leaving the desires alone was rejected: it gives the right
  // order, but `placeFace` then pulls the straight arms off their meeting points towards the middle
  // the others still ask for -- on the fan-in both Notifications and Analytics bend, where with this
  // only Notifications has to, because four arms must sit to its left on a run too short to hold
  // them and keep it straight.
  //
  // Only recorded here, and taken only on a face where the middle does harm: one whose order it
  // inverts (`isInverted`), or one where it would push an aligned neighbour off its line
  // (`unalignsAny`).
  function leanOf(att, far) {
    if (att.face.fixed) return undefined;
    var at = att.face.alongX ? centreX(far.box) : centreY(far.box);
    return { desire: clampToRun(att.face, at - att.face.base), from: att.desire };
  }

  // Whether placing the face as sorted would take an end that lines up with its far end off the
  // offset it lines up at. The middle a non-aligned end asks for is where an aligned neighbour is
  // likeliest to want to be: in the harness's `rank skip LR`, B --> C asked for B's middle and
  // pushed B --> D off the meeting point that would have drawn it as one straight line.
  function unalignsAny(face) {
    var desires = face.group.map(function (att) { return att.desire; });
    var probe = { run: face.run, span: face.span, group: face.group, desires: desires };
    var offsets = placeFace(probe);
    for (var g = 0; g < face.group.length; g += 1) {
      if (face.group[g].aligned && offsets[g] !== face.group[g].desire) return true;
    }
    return false;
  }

  // Whether sorting a face by desire puts an end ahead of one headed further along it. Leaning
  // every end that could lean was tried first and rejected twice. It spends offsets no ordering
  // needs: on the ellipse in ports.spec.js's matrix, three arms whose desires already sorted in
  // their far ends' order were pushed to the two ends of the run, where the rounded inset left 4 of
  // 360 ports outside the drawn outline. And on the reader-reported `cand` drawing, Nego-H1's three
  // edges to and from Original leaned at BOTH ends, the three Zs between them shrank into one narrow
  // corridor, and two label plates landed on foreign strokes where there had been none -- a face
  // whose ends all lead to one box cannot be out of order, and this test leaves it alone.
  function isInverted(face, model) {
    var seen = -Infinity;
    for (var g = 0; g < face.group.length; g += 1) {
      var at = headingOf(face, face.group[g], model);
      if (at < seen) return true;
      seen = Math.max(seen, at);
    }
    return false;
  }

  function viaAlong(face, level, v) {
    return face.alongX ? (level.originX + v.lx) : (level.originY + v.ly);
  }

  var FACING_SIDE = { top: "bottom", bottom: "top", left: "right", right: "left" };

  // A fork's branches have to read as a pair.
  //
  // `desirePorts` answers for one edge at a time, so each branch of a decision aims at its OWN
  // target and nothing compares the two. On the Korean decision source that is the whole defect the
  // reader reported: `결제 진행` is an 88px box and the branch reaches it straight down, `입고 대기
  // 알림` is a 120px box whose landing run starts 44px to the right, so that branch is clamped and
  // steps. One branch a bare vertical, one an S. Exchanging two branch labels exchanges which is
  // which -- on `C{Check} --> L[Go]` / `C --> R[A considerably longer label here]` the left stepped
  // 44px and the right was straight, and the other way round the left was straight and the right
  // stepped 40 -- which is the reader's own test and why "no influence from the text" is the
  // requirement and not a nicety.
  //
  // So the branches are settled together. The arms of one fork -- the edges LEAVING one face, in the
  // rank direction that face names, each reaching its target directly -- are sorted across the rank
  // and paired outermost-with-outermost, and each pair is given one distance either side of the
  // face's own centre: the LARGER of what the two asked for, clamped into the stretch both landing
  // runs can hold. Larger rather than smaller because the arm that has to step furthest is the one
  // with no choice -- its target's run does not reach any closer -- and matching it costs the other
  // arm only a longer cross-line. Where no distance suits both -- two targets on the same side of
  // the apex, or a near one too small to reach out as far as a far one has to -- the pair is left as
  // `desirePorts` had it rather than pushed somewhere neither box wants it. 23 of the corpus's 66
  // pairs are that; the drawing is lopsided there because the BOXES are, and nothing a connector can
  // do about it would be an improvement. The odd arm of an odd fan is the axis of symmetry and
  // goes to the centre.
  //
  // Only a preference is written. `placeFace` still owns the face and still holds rule 4's 12px, so
  // a target face carrying other connectors gives the fork what it can and no more.
  //
  // An arm travelling a corridor is not one of these: its first station is the corridor the layout
  // reserved, several ranks long, and aiming it at a mirror point instead would bend it at both ends
  // to buy symmetry with a branch that is not beside it anyway.
  //
  // But such a corridor still LANDS on the faces the arms land on, and the mirror point must not be
  // on its far side. A corridor comes down its lane and onto the face at that lane; an arm comes
  // across the last gap from the apex. Where the apex stands on one side of the corridor's lane, the
  // arm can reach a port on the other side only by crossing the corridor in that gap, and the two
  // were decided apart: the corridor's port by `desirePorts`, the arm's by this pass, which read
  // nothing but the two targets' runs. So an arm's reach on its target face stops a port's pitch
  // short of every corridor landing there, on the apex's side. The third held-out set showed it
  // three times. b12's store forks to RevenueChart and OrderDrawer, the two outermost of four
  // targets, and the mirror sent both to the outer ends of their runs -- past MainPanel's corridors
  // down to each, so each arm hopped one. b09's CS201 forks to CS320 and CS350, and CS350's arm was
  // sent to the bottom of its face, below CS110's corridor arriving from below. And the sweep's
  // `opposed answers beside a skip` drew it without a hop: Guarantee?'s "granted" was mirrored to
  // the far corner of Pay the holding deposit, past the corridor from Request proof of paid taxes,
  // and that corridor's last jog ran 12px along the dashed arm's run -- one line read as joining
  // the other.
  //
  // Where the stopped reach leaves no distance that suits both arms, the pair is left as
  // `desirePorts` had it, which is the rule above for boxes that cannot be mirrored, and the face's
  // sort then orders the arm by where it heads (`isInverted`, `leanOf`). Rejected: keeping the
  // mirror and moving the corridor's port instead. The corridor's port is under its lane, so it
  // lands straight; moving it off its lane bends a line several ranks long to keep a symmetry the
  // reader cannot see from the corridor's end of the drawing. A face too short to hold the arm
  // beside the lane still moves the corridor -- `placeFace` keeps the pitch -- and that is the one
  // cost measured: CS110's corridor in b09 now steps 12px before CS350, a bend where it had a hop.
  function mirrorForks(faces, model) {
    for (var i = 0; i < faces.length; i += 1) {
      var f = faces[i];
      var arms = [];
      for (var g = 0; g < f.group.length; g += 1) {
        var att = f.group[g];
        // `end === 0` is the end the edge leaves by, whichever way round the ranks are: a back
        // edge's start attachment is on its source's far face, and that face is still a fork face.
        if (att.end !== 0 || att.edge.selfLoop) continue;
        if ((att.edge.via || []).length) continue;
        var far = att.edge.endAtt;
        if (!far || !far.face) continue;
        if (far.face.alongX !== f.alongX || far.side !== FACING_SIDE[f.side]) continue;
        arms.push(far);
      }
      if (arms.length < 2) continue;
      // Sorted by where the TARGETS stand across the rank, not by what they asked for: two arms
      // clamped to the same end of their runs ask for the same thing and would pair with themselves.
      arms.sort(function (p, q) {
        var pk = f.alongX ? centreX(p.box) : centreY(p.box);
        var qk = f.alongX ? centreX(q.box) : centreY(q.box);
        return (pk - qk) || (p.edge.index - q.edge.index);
      });
      var centre = Math.round(f.base + faceCentre(f));
      // Where an arm may land, in the drawing's own frame. A shape that answers for its own port --
      // a circle, a cylinder's crest, a rhombus's apex -- has a run of one point, and that point is
      // already placed and read back rather than asked for: the arm cannot move, so it is the one
      // that sets the distance and its partner is the one that matches.
      var reachOf = function (a) {
        if (a.face.fixed) {
          var pt = a.edge.endPoint;
          if (pt) {
            var at = f.alongX ? pt.x : pt.y;
            return { lo: at, hi: at };
          }
        }
        var reach = { lo: a.face.base + a.face.run.lo, hi: a.face.base + a.face.run.hi };
        for (var c = 0; c < a.face.group.length; c += 1) {
          var other = a.face.group[c];
          var via = other.edge.via || [];
          var level = model.levels.get(other.edge.level);
          if (other === a || via.length === 0 || !level) continue;
          var lane = viaAlong(a.face, level, other.end === 0 ? via[0] : via[via.length - 1]);
          var lands = a.face.base + other.desire;
          if (lane < centre) reach.lo = Math.max(reach.lo, lands + MIN_PITCH);
          else if (lane > centre) reach.hi = Math.min(reach.hi, lands - MIN_PITCH);
        }
        return reach;
      };
      for (var k = 0; k + 1 < arms.length - k; k += 1) {
        var lo = arms[k];
        var hi = arms[arms.length - 1 - k];
        var loAt = reachOf(lo);
        var hiAt = reachOf(hi);
        var least = Math.max(centre - loAt.hi, hiAt.lo - centre, 0);
        var most = Math.min(centre - loAt.lo, hiAt.hi - centre);
        if (least > most) continue;
        var want = Math.max(
          Math.abs(lo.face.base + lo.desire - centre),
          Math.abs(hi.face.base + hi.desire - centre)
        );
        var step = Math.min(most, Math.max(least, want));
        if (!lo.face.fixed) lo.desire = centre - step - lo.face.base;
        if (!hi.face.fixed) hi.desire = centre + step - hi.face.base;
      }
      if (arms.length % 2 === 1) {
        var mid = arms[(arms.length - 1) / 2];
        if (!mid.face.fixed) mid.desire = clampToRun(mid.face, centre - mid.face.base);
      }
    }
  }

  // SKILL.md §6 rule 4's "spread the attach points evenly along the edge", `L * k / (N + 1)` and all.
  // It was the whole of port placement until a corpus was measured against it: of the 23 connectors
  // whose two boxes shared a centre line with nothing between them, 7 still bent, because an even
  // spread moves a port that had no reason to move (straight.spec.js counts them). It survives in
  // the two places `placeFace` has no better answer for -- the two feet of a self-loop, and a face
  // too short to hold rule 4's 12px at all.
  function spreadOf(span, N) {
    var L = span.hi - span.lo;
    var step = Math.max(1, Math.floor(L / (N + 1)));
    var start = span.lo + Math.round((L - step * (N - 1)) / 2);
    var out = [];
    for (var g = 0; g < N; g += 1) out.push(Math.min(span.hi, Math.max(span.lo, start + step * g)));
    return out;
  }

  // Any value between a block's two central members costs the same total displacement; the midpoint
  // of that interval is the one that does not favour either side. Whole, because the interval's two
  // ends are: the desires are whole grid units and so is the pitch subtracted from them.
  function middleOf(values) {
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    var n = sorted.length;
    return Math.round((sorted[(n - 1) >> 1] + sorted[n >> 1]) / 2);
  }

  // Put every attachment where it wants to be, and move only what rule 4's 12px forces to move.
  //
  // Substituting p[k] = offset[k] - MIN_PITCH * k turns "the offsets rise by at least the pitch"
  // into "p does not decrease", which is isotonic regression under absolute error. PAVA solves that
  // exactly: walk left to right, and wherever the new value sits below its neighbour merge the two
  // into one block and give the block a median of its members. What comes out is the placement with
  // the least total movement away from the desires -- not an approximation of it and not an
  // iteration towards it -- and the medians are whole units because the inputs are. Clamping each
  // block into the span afterwards is what the same theorem says to do about the ends of the face.
  //
  // Rejected: sweeping the face and nudging any pair closer than the pitch apart until nothing
  // moves. It lands on a different answer depending on which end it sweeps from, and where several
  // ports want one offset it displaces ports that did not have to move at all.
  function placeFace(face) {
    // The landing run, not the span: `assignPorts` has already sent every face too short to hold
    // its fan to `clusterAt`, so what arrives here has room for one, and spending the run's slack
    // rather than the shape's is what keeps a port off the corner it was allowed to sit on.
    var span = face.run;
    var N = face.group.length;
    var gaps = facePitches(face);
    var at = [0];
    for (var c = 0; c < gaps.length; c += 1) at.push(at[c] + gaps[c]);
    // No placement holds the pitch on a face this short, and the even spread is what the file has
    // always done here. `layout` widens a node until 3(N + 1) units fit, but it sizes for
    // max(in, out) -- so the face that overflows is the one a CYCLE loads from both sides, which is
    // the case its own comment says it declines to size for. Measured: 0 of 836 random and
    // shape-sweep sources reach this, and 14 of 21 sources built out of `Z --> M / M --> Z` pairs do,
    // every one of them a plain rectangle rather than a geometry `portSpan` trimmed.
    if (span.hi - span.lo < MIN_PITCH * (N - 1)) return spreadOf(face.span, N);
    var blocks = [];
    var k;
    for (k = 0; k < N; k += 1) {
      var p = face.desires[k] - at[k];
      blocks.push({ vals: [p], value: p, n: 1 });
      while (blocks.length > 1 && blocks[blocks.length - 2].value > blocks[blocks.length - 1].value) {
        var b = blocks.pop();
        var a = blocks[blocks.length - 1];
        a.vals = a.vals.concat(b.vals);
        a.n += b.n;
        a.value = middleOf(a.vals);
      }
    }
    var top = span.hi - at[N - 1];
    var out = [];
    for (k = 0; k < blocks.length; k += 1) {
      var v = Math.min(top, Math.max(span.lo, blocks[k].value));
      for (var j = 0; j < blocks[k].n; j += 1) out.push(v + at[out.length]);
    }
    return out;
  }

  // Writes a face's offsets back onto the edges attached to it. Separate from the fan because the
  // pass after it moves an offset and then has to re-derive the point: the inset depends on where
  // along the face the port ended up (`portInset`), so a moved port that kept its old inset would
  // hang off the outline the previous round put it on.
  function settleFace(face, group) {
    var centre = faceLength(face.box, face.side) / 2;
    for (var g = 0; g < group.length; g += 1) {
      var offset = face.offsets[g];
      var inset = portInset(face.geometry, face.box, face.side, offset - centre);
      var point = portPoint(face.box, face.side, offset, inset);
      if (group[g].end === 0) {
        group[g].edge.startPoint = point;
        group[g].edge.startInset = inset;
        group[g].edge.startPitch = endPitch(face, g);
      } else {
        group[g].edge.endPoint = point;
        group[g].edge.endInset = inset;
        group[g].edge.endPitch = endPitch(face, g);
      }
    }
    face.group = group;
  }

  // SKILL.md §6 rule 4's "at least 12px between adjacent attach points", in grid units.
  var MIN_PITCH = 3;
  // A face carrying BUSY_N or more ends, any of them labelled, is held at BUSY_PITCH: twice rule 4's
  // minimum, which is what `slopesOf` already gives a vertex, and the 24px a label plate is tall --
  // the least that lets a plate sit ON one line of the bundle without covering its neighbour.
  //
  // Four, not three. Swept at three: 12 of the 204 sweep drawings changed and gained 12 bends
  // between them -- `open links`, `long back edge past a fork` and `long forward edge`, in all four
  // directions -- and in the three looked at (TD) the three lines already parted within one gap of
  // the face, so the spread only added a jog. At four and five the sweep is byte-identical and the
  // held-out faces the review named -- h04's Advertising (6), h20's Closed (7) and Tier 1 (4 and 4)
  // -- are all held. Unlabelled faces keep 12px: a fan-in with nothing written on it has nothing a
  // reader must match to a line, and h01's, h08's and h11's four- to six-end faces stay as they were.
  var BUSY_N = 4;
  var BUSY_PITCH = 2 * MIN_PITCH;
  function facePitch(face) {
    var N = face.group.length;
    if (N < 2 || face.run.hi === face.run.lo) return MIN_PITCH;
    var lab = false;
    var edges = [];
    for (var g = 0; g < N; g += 1) {
      if (face.group[g].edge.labelBox) lab = true;
      edges.push(face.group[g].edge);
    }
    // All or nothing. A face `layoutLevel` did not grow -- its ends cross a zone's border -- may be
    // too short for the seat pitch, and part of it seats no plate: on the two-zone L1..R3 drawing in
    // render.spec.js a 16px spread re-routed "back two" off its line and left its middle nearer two
    // other links than its own. Such a face keeps the pitch it had.
    var seat = seatPitch(edges, !face.alongX);
    if (seat > 0 && seat * (N - 1) <= face.run.hi - face.run.lo) return seat;
    var want = (N >= BUSY_N && lab) ? BUSY_PITCH : MIN_PITCH;
    if (want === MIN_PITCH) return MIN_PITCH;
    // As much of the busy pitch as the run allows: a face the pass in `layoutLevel` did not grow --
    // an end arriving from another level, which that pass does not count -- keeps what fits.
    return Math.max(MIN_PITCH, Math.min(want, Math.floor((face.run.hi - face.run.lo) / (N - 1))));
  }

  // The pitch between each pair of neighbours on a face, in the order `group` stands: `seatGaps`'
  // where the run holds them, and `facePitch`'s uniform answer everywhere else.
  function facePitches(face) {
    var N = face.group.length;
    var gaps = null;
    if (N >= 2 && face.run.hi !== face.run.lo) {
      var edges = [];
      for (var g = 0; g < N; g += 1) edges.push(face.group[g].edge);
      gaps = seatGaps(edges, !face.alongX);
      var total = 0;
      for (g = 0; gaps && g < gaps.length; g += 1) total += gaps[g];
      if (gaps && total > face.run.hi - face.run.lo) gaps = null;
    }
    if (gaps) return gaps;
    var pitch = facePitch(face);
    gaps = [];
    for (var k = 0; k + 1 < N; k += 1) gaps.push(pitch);
    return gaps;
  }

  // How close another port on the face may stand to slot `g`'s: the wider of its two gaps.
  function endPitch(face, g) {
    var gaps = facePitches(face);
    if (gaps.length === 0) return facePitch(face);
    return Math.max(g > 0 ? gaps[g - 1] : 0, g < gaps.length ? gaps[g] : 0);
  }

  // A route's first turn is where the stub off a port meets the next station -- the first waypoint
  // the layout reserved, or the far port when there is none. When those two differ by exactly one
  // grid unit along the face, the router has to draw a 4px sidestep, and 4px is the one run length
  // `cornerRadius` cannot round on the grid: two quarter arcs want 8px of it, and no smaller radius
  // puts its endpoints on multiples of 4. Both of its corners come out square, which SKILL.md §6
  // rule 1 calls an automatic fail.
  //
  // So the unit is closed here instead, by sliding the port one step along its own face. That
  // removes the sidestep rather than rounding it, and it is the only end of the problem that can be
  // moved: the two coordinates the router is handed are not negotiable once it has them.
  //
  // A port only moves if it can do so without taking any neighbour on the same face closer than
  // rule 4's 12px, which is why `settleFace` kept the face: a lone connector is always free and a
  // crowded face is never disturbed. The source end is tried first, so that when neither end has a
  // waypoint the one move settles both.
  //
  // Measured over 102 sources: 5 ports slid and 2 more asked to and were refused by the guard, and
  // no sidestep survives in any of them. The guard earns its place -- one of the five moved on a
  // face already carrying three connectors -- and render.spec.js asserts the resulting 12px
  // directly rather than trusting the check.
  function alignUnitJog(edge, model) {
    if (edge.selfLoop || !edge.startPoint || !edge.endPoint) return;
    var level = model.levels.get(edge.level);
    if (!level) return;
    var via = edge.via || [];
    function waypoint(k) {
      return { x: level.originX + via[k].lx, y: level.originY + via[k].ly };
    }
    var ends = [
      { face: edge.startFace, slot: edge.startSlot, side: edge.startSide },
      { face: edge.endFace, slot: edge.endSlot, side: edge.endSide }
    ];
    // Closing the sidestep is tried at BOTH ends before either is widened. Widening first would
    // settle for a step the other end could have removed outright: with no waypoints the two ports
    // are each other's station, so a source that gave up and moved 8px away left the destination
    // reading a delta of three units and nothing left to do about it -- 31 connectors in the corpus
    // that are straight when the passes are in this order.
    for (var pass = 0; pass < 2; pass += 1) {
      for (var e = 0; e < 2; e += 1) {
        var end = ends[e];
        // A fixed face is the shape's answer, not a preference: sliding a port off a rhombus's
        // apex to save a sidestep would put back the defect the apex is there to fix.
        if (!end.face || end.face.fixed) continue;
        // Read fresh each time round: with no waypoints the two stations ARE the two ports, so
        // closing the unit at the source also closes it at the destination, and a stale copy of the
        // far port would have the second end slide a face that is already aligned.
        var here = (e === 0) ? edge.startPoint : edge.endPoint;
        var next = via.length
          ? waypoint(e === 0 ? 0 : via.length - 1)
          : (e === 0 ? edge.endPoint : edge.startPoint);
        // A stub leaves on the face normal, so it is the OTHER axis that has to meet the next
        // station, and that axis is the one the face runs along.
        var key = (end.side === "top" || end.side === "bottom") ? "x" : "y";
        var delta = next[key] - here[key];
        // One unit is a 4px sidestep, which `cornerRadius` can only draw square. Two is an 8px
        // one, which it draws as a pair of touching 4px arcs with no straight run between them --
        // legal by rule 1 and still a wobble in the line rather than two corners. Both are cheaper
        // to remove than to round, and the guard inside `slideAlongFace` refuses the move on a face
        // that cannot spare it.
        if (delta !== 1 && delta !== -1 && delta !== 2 && delta !== -2) continue;
        // Closing it is the first choice and the best one. When the face cannot give the port
        // that step -- `A --> D` in the five-node corpus source, whose neighbour on the face was
        // already at the end of the run, 12px away -- WIDENING is the other way out: a sidestep of
        // three units rounds to two 4px arcs with a 4px straight between them, and one of two units
        // to two arcs that touch. Both are legal under rule 1 where a square corner is not, so the
        // order is close, then widen to three, then widen to two.
        var tries = pass === 0
          ? [delta]
          : ((delta === 1 || delta === -1) ? [-2 * delta, -delta] : [-delta / 2]);
        for (var t = 0; t < tries.length; t += 1) {
          if (!slideAlongFace(end.face, end.slot, tries[t])) continue;
          settleFace(end.face, end.face.group);
          break;
        }
      }
    }
  }

  function slideAlongFace(face, slot, delta) {
    var want = face.offsets[slot] + delta;
    if (want < face.run.lo || want > face.run.hi) return false;
    for (var i = 0; i < face.offsets.length; i += 1) {
      if (i === slot) continue;
      if (Math.abs(face.offsets[i] - want) < Math.max(endPitch(face, i), endPitch(face, slot))) return false;
    }
    face.offsets[slot] = want;
    return true;
  }

  // ===========================================================================
  // Layout.
  //
  // Takes a parsed FlowDB and a text measurer and returns the drawing's geometry -- every box,
  // every container, the ranks and ports each edge has to join, and the overall size. Every number
  // it returns is CSS px and an integer multiple of 4, because every number it computed was an
  // integer number of grid units.
  //
  // It does not route and it does not emit. Those are the next two phases, and the seam is here on
  // purpose: routing that is handed ports, lanes and corridors cannot invent a diagonal, and
  // emission that is handed integers cannot invent a fractional coordinate.
  //
  // Throws only for a broken contract -- no measurer. A source it cannot draw is `render`'s
  // business to decline, and a decline is a route rather than a failure.
  // ===========================================================================

  // How wide an EDGE label may grow before it takes a second line. Not `wrappingWidth`: that is the
  // budget of a label inside a box, which cannot get wider and so has to get taller. An edge label
  // stands in a gap beside its line, and there height is the expensive axis -- a taller plate is
  // what reaches the neighbouring strokes. At the node's 160 the editorial theme wrapped 41 of the
  // 44 labels on label-analysis.md's eight crowded sources, where Pele wraps 3.
  //
  // Swept at 160, 192, 208, 216, 224, 232, 240, 248, 256, 288, 320, 384, 448, 512 and no cap, over
  // those eight sources and Scripts/differential.mjs's 175 drawings. On the eight, labels at two
  // or more lines went 41, 29, 20, 10, 9, 4, 3, 3, 3, 2 and 0 from 320 on; placements that found a
  // zero-penalty spot went 27, 27, 32, 32, 32 of 44, then 28 from 232 on; and the mean distance
  // from a plate to the nearest stroke it does not own went 30.06, 26.73, 27.30, 29.87, 33.59,
  // then 28.67 at 232 and between 27.36 and 27.90 past it. Of the 175, only the two reader-sent
  // drawings carry a label long enough to notice, and 224 is the last setting before one of them
  // pays for it: at 232 cand.mmd's "negotiate(adjustRate, original)" comes off two lines onto one
  // 248px plate, the drawing goes from 1 plate over a foreign stroke to 3, and the corpus's
  // zero-penalty count drops from 36 of 40 to 35. So 224 is where the wraps stop paying for
  // themselves -- the clean-placement count and the clearance both peak there -- and the next step
  // is the first one that is bought with a drawing a reader sent.
  //
  // What 224 costs, measured: the eight crowded sources grow from 2,469,056 to 2,822,784 px²,
  // because the plates trade height for width (summed heights 3104 to 2788, widths 6900 to 8708);
  // over the 175 the area moves from 12,306,336 to 12,299,168. Ownership does not suffer: the
  // crowded plates clear by at least 12px 44 of 44 times against 43 at 160, and none is lost at
  // any setting swept. One crowded plate -- every-edge-labelled diamond BT -- lands on a foreign
  // stroke it cleared at 160. Rejected: going smaller to win that back. It is on that stroke at
  // every setting from 192 to 232, and 208, the cheapest of them at 2,591,040 px², still wraps 20
  // of 44 and stands the plates nearer foreign strokes than 160 did.
  //
  // Everything above was measured against the MONO face, ui-monospace tracked 0.04em, which is what
  // the editorial theme painted edge labels in then. A budget in pixels is a budget in that face's
  // advances, so when the theme moved edge labels to its sans (MacMermaidTheme.swift, `sans`) the
  // 224 knee stopped being a measurement of anything. Re-derived against the sans with real advances
  // -- CoreText widths of SF Pro 12 / SF Mono 12, Hangul falling back to Apple SD Gothic Neo -- over
  // differential.mjs's 175 drawings plus the 16 sources of the editorial-vs-Pele visual review:
  // mono at 224 put 3 plates on foreign strokes and 8 labels on two or more lines; sans at 224 puts
  // 3 and 1, and the third plate is new -- review 13's "no, the signature does not match and the
  // request may be forged" comes off four mono lines onto two 210px sans lines centred between the
  // diamond's two exits, masking both. Sans at 208 puts 2 and 1, with that label clear of both exits
  // by 24px. 192 measured the same as 208 on all three; 208 is taken because the wider of two equal
  // budgets is the one that keeps more labels on one line. 160 wraps 8 again.
  //
  // Not widened to clear the 6 labels differential.mjs reports at two lines on cand and nego. Those
  // wraps belong to its stand-in measurer, which charges 0.6em a character and so puts the 31
  // characters of "negotiate(adjustRate, original)" at 223.2px; WebKit sets it in a 176px plate, on
  // one line, at this budget. Re-swept against today's renderer under the stand-in, 224 and every
  // setting past it does unwrap all 6 -- and puts 2 plates on foreign strokes in cand, nearest 0px,
  // which is the drawing the app was already showing. That was room, not budget; see `leavingRoom`.
  var EDGE_WRAP_PX = 208;

  // The labels on a zone member's connectors that leave the zone, keyed by the member: the child of
  // the zone the inside end descends from. Those connectors are drawn by a level further out, so the
  // room pass inside the zone never sees them, and the zone is sized as if its members carried no
  // labels at all. See `leavingRoom` in `layoutLevel` for what is done with them.
  function leavingLabels(model, zoneId) {
    var byChild = new Map();
    for (var i = 0; i < model.edges.length; i += 1) {
      var e = model.edges[i];
      if (e.selfLoop || e.boundary || !e.labelBox) continue;
      var ends = [e.fromChild, e.toChild];
      var inside = [];
      for (var k = 0; k < 2; k += 1) {
        var chain = ancestry(ends[k].id, model.parentOf);
        var at = chain.indexOf(zoneId);
        inside.push(at > 0 ? chain[at - 1] : null);
      }
      if ((inside[0] === null) === (inside[1] === null)) continue;
      var member = inside[0] !== null ? inside[0] : inside[1];
      if (!byChild.has(member)) byChild.set(member, []);
      byChild.get(member).push(e.labelBox);
    }
    return byChild;
  }

  // Where the far end of each edge that enters a zone stands, per zone, from a drawing whose boxes
  // are all placed. Only an edge from the side the zone's own ranks are read from is counted -- the
  // rank side in front of rank 0, which is above a TB zone, left of an LR one, below a BT one and
  // right of an RL one -- and only when its far end is wholly on that side of the zone's box. Both
  // limits keep the answer settled: what is upstream of a zone is laid out from what is upstream of
  // it, so each pass of `layout` settles one more zone in the chain and none of them can chase a
  // zone that is chasing it back. Taking both sides was measured, and is that chase: Services sorts
  // by Data's order of the previous pass while Data sorts by Services', so 02 and 08 were still
  // changing after four passes and stopped on the order they began with -- Postgres, Redis, S3 --
  // and 12 drew its Ingestion column upside down. Upstream only, 02, 12 and 14 settle in one
  // extra pass and 08 in two.
  //
  // `at` is the far end's rank among the zone's far ends along its O axis, so the key compares
  // orders and not pixels: a pass that only moves boxes, without reordering any, hands the next
  // pass the same key, which is what ends the loop.
  function outsideOf(model) {
    var byZone = new Map();
    function contains(zoneId, child) {
      return ancestry(child.id, model.parentOf).indexOf(zoneId) > 0;
    }
    function record(zoneId, childId, farEnd) {
      var zone = model.clusterById.get(zoneId);
      var dir = model.levels.get(zoneId).dir;
      var fx = farEnd.x + farEnd.w / 2;
      var fy = farEnd.y + farEnd.h / 2;
      var upstream = (dir === "TB") ? fy < zone.y
        : (dir === "BT") ? fy > zone.y + zone.h
          : (dir === "LR") ? fx < zone.x
            : fx > zone.x + zone.w;
      if (!upstream) return;
      if (!byZone.has(zoneId)) byZone.set(zoneId, []);
      byZone.get(zoneId).push({ child: childId, at: (dir === "TB" || dir === "BT") ? fx : fy });
    }
    for (var i = 0; i < model.edges.length; i += 1) {
      var e = model.edges[i];
      if (e.selfLoop || e.boundary) continue;
      for (var end = 0; end < 2; end += 1) {
        var farEnd = end ? e.fromChild : e.toChild;
        var child = end ? e.toChild : e.fromChild;
        for (var guard = 0; guard < 256 && child.parent; guard += 1) {
          if (contains(child.parent, farEnd)) break;
          record(child.parent, child.id, farEnd);
          child = model.clusterById.get(child.parent);
          if (!child) break;
        }
      }
    }
    var key = [];
    byZone.forEach(function (list, zoneId) {
      var values = list.map(function (o) { return o.at; }).sort(function (a, b) { return a - b; });
      var ranks = [];
      for (var k = 0; k < values.length; k += 1) if (k === 0 || values[k] !== values[k - 1]) ranks.push(values[k]);
      for (var k2 = 0; k2 < list.length; k2 += 1) list[k2].at = ranks.indexOf(list[k2].at);
      key.push(zoneId + "\u0000" + list.map(function (o) { return o.child + "@" + o.at; }).join(","));
    });
    key.sort();
    return { hints: byZone, key: key.join("\u0001") };
  }

  // The layout, run again while what it says about each zone's outside ends keeps changing. A
  // drawing with no edge into a zone from upstream says nothing the first time, and is the first
  // run exactly. Four is the bound on how deep a chain of zones is settled; one that has not
  // converged by then draws the last answer, which is still a placed drawing.
  function layout(db, options) {
    var probe = {};
    var drawing = layoutOnce(db, options, null, probe);
    var used = "";
    for (var pass = 0; pass < 4 && probe.key !== used; pass += 1) {
      used = probe.key;
      var hints = probe.hints;
      probe = {};
      drawing = layoutOnce(db, options, hints, probe);
    }
    return drawing;
  }

  function layoutOnce(db, options, outside, probe) {
    var opts = options || {};
    // Accepts either the projection or the raw payload it is projected from, so a caller that
    // already built the theme does not pay for it twice and a test can pass nothing at all.
    var theme = (opts.theme && typeof opts.theme.fontSizePX === "number")
      ? opts.theme
      : buildFlowTheme(opts.theme || {});
    var metrics = makeMetrics(opts.measureText, theme);
    var arrangement = theme.arrangement;
    var env = {
      clusters: null,
      spaceU: arrangement.nodeSpacing / GRID,
      rankU: arrangement.rankSpacing / GRID
    };
    var padU = arrangement.padding / GRID;
    var marginU = arrangement.diagramPadding / GRID;
    var wrapPX = arrangement.wrappingWidth;

    var rootDir = normaliseDirection(opts.direction || db.getDirection(), "TB");
    var model = buildModel(db, rootDir);
    env.clusters = model.clusterById;
    var warnings = model.warnings;
    var i;

    // How many connectors one face of each node has to hold, before anything has been sized.
    //
    // `assignPorts` divides a face of L units between N connectors at a pitch of floor(L/(N+1)), so
    // SKILL.md §6 rule 4's 12px needs a face of at least 3(N+1) units. The label is what sizes a
    // node, and on a default 80x48 box that runs out at six. Measured on a fan-in, before this:
    // 12px of pitch at five, 8px at six, 4px at ten, and at twenty-two the offsets stop being
    // distinct at all -- twenty-one whole grid steps is every position an 80px face has, and
    // sharing one is the clause of rule 4 with no room in it ("no two connectors may share a single
    // point on a box"). The arrowhead is 6px across the face, so 4px of pitch overlaps two heads
    // well before the ports collide.
    //
    // WHICH face an edge takes is not known here -- that needs ranks, and ranks need sizes -- but
    // the AXIS is: `chooseSides` sends every ranked edge to the pair of faces the level's direction
    // names, so a TB level loads a node's width and an LR level its height. In-edges land on one of
    // that pair and out-edges on the other, which makes max(in, out) the count one face has to
    // hold. A cycle can put both on one face; that case is left at the pitch it had before rather
    // than sized for a worst case that no acyclic drawing ever reaches.
    var faceLoad = new Map();
    function loadOf(id) {
      if (!faceLoad.has(id)) faceLoad.set(id, { in: 0, out: 0 });
      return faceLoad.get(id);
    }
    for (i = 0; i < model.edges.length; i += 1) {
      var le = model.edges[i];
      // A self-loop puts both of its ends on ONE face of the order axis, not the rank axis
      // (`chooseSides`), so it is no reason to widen a box along the rank axis.
      if (le.selfLoop) continue;
      loadOf(le.from).out += 1;
      loadOf(le.to).in += 1;
    }

    for (i = 0; i < model.nodes.length; i += 1) {
      var node = model.nodes[i];
      node.label = shapeLabel(node.vertex.text, metrics, metrics.node, wrapPX);
      var geometry = geometryOf(node.shape);
      var box = shapeBox(geometry, node.label, padU);
      node.w = box.w;
      node.h = box.h;
      var load = faceLoad.get(node.id);
      if (load) {
        var need = even(MIN_PITCH * (Math.max(load.in, load.out) + 1));
        var level = model.levels.get(node.parent === null ? "" : node.parent);
        var vertical = ((level ? level.dir : rootDir) === "TB") || ((level ? level.dir : rootDir) === "BT");
        // A circle is drawn at radius W whatever its height says (`shapeMarkup`), so growing one
        // axis of one and not the other would draw a shape that leaves its own box. The two round
        // families stay square; every other geometry takes the growth on the loaded axis alone.
        if (geometry === "circle" || geometry === "doublecircle") {
          if (need > node.w || need > node.h) { node.w = even(Math.max(node.w, need)); node.h = node.w; }
        } else if (vertical) {
          node.w = even(Math.max(node.w, need));
        } else {
          node.h = even(Math.max(node.h, need));
        }
      }
    }

    for (i = 0; i < model.edges.length; i += 1) {
      var edge = model.edges[i];
      var text = edge.raw.text;
      if (typeof text === "string" && text.length > 0) {
        // Never narrower than a host's node budget: a theme that lets a box grow to 300px has said
        // nothing to make the label beside it wrap sooner than the label inside it.
        var shaped = shapeLabel(text, metrics, metrics.edge, Math.max(wrapPX, EDGE_WRAP_PX));
        edge.label = shaped;
        // The backing rect is 8px wider than the text on each side rather than 4. Half of that is
        // SKILL.md §6 rule 2 wanting the mask clear of the stroke; the other half is slack against
        // a host whose payload does not name the edge face, which measures the node face instead.
        edge.labelBox = { w: even(shaped.w + 4), h: even(shaped.h + 2) };
      } else {
        edge.label = null;
        edge.labelBox = null;
      }
    }

    // Innermost first, which is the order the parser closed them in: a container cannot be sized
    // until the level inside it has been laid out, and `subGraphs` is already in exactly that order
    // because `addSubGraph` runs on `end`.
    for (i = 0; i < model.clusters.length; i += 1) {
      var cluster = model.clusters[i];
      var inner = model.levels.get(cluster.id);
      inner.outside = (outside && outside.get(cluster.id)) || null;
      inner.leaving = leavingLabels(model, cluster.id);
      layoutLevel(inner, env);
      var title = String(cluster.title || "");
      var header = 0;
      if (title.length > 0) {
        // The title is wrapped at the room the zone actually has, not at the node wrapping width.
        // The two are unrelated numbers: `wrappingWidth` is how wide one label may grow before a
        // box has to get taller, and a box cannot get wider; a zone has no such cap, because it is
        // sized by what is inside it and `inner` has already been laid out one line above. Wrapping
        // a title at 160px inside a zone whose band is 576px is what put reelect.mmd's title on
        // two lines with 416px of that band left empty. The floor keeps a zone around one 80px node
        // from stacking a three-word title into three lines -- below the wrapping width the zone
        // grows instead, which is the cheaper of the two.
        var titleMaxPX = Math.max(px(inner.contentW), wrapPX);
        cluster.label = shapeLabel(title, metrics, metrics.cluster, titleMaxPX, true);
        // dd-arch.md: the eyebrow sits 4px inside the top of the zone and there is at least 16px
        // between its baseline box and the first enclosed node. The 2 units here plus the padding
        // below buy 20px, which is the near side of that.
        header = even(cluster.label.h + 2);
        // A zone the drawing found a route crossing its title along the band (see `titleRoom` in
        // `renderOrDecline`) takes a lane under the title: deep enough that a first-row node's
        // arrival station, ARRIVE above its face, sits a gap below the title's box rather than in
        // it, so the turn into the zone is made under the words instead of through them.
        var laneHeader = Math.max(header, even(cluster.label.h + 1 + LABEL_GAP + ARRIVE - padU));
        cluster.laneU = laneHeader - header;
        var room = opts.titleRoom && opts.titleRoom[cluster.id];
        if (room && room.lane) header = laneHeader;
      } else {
        cluster.label = null;
      }
      cluster.header = header;
      // A title wider than the contents widens the zone rather than hanging off its right edge --
      // which is what it did before, because the width was the contents' alone. `keepWordsWhole`
      // above makes that case reachable on purpose: a token with no break in it now overflows the
      // wrapping width, and this is where the room for it comes from. The contents keep the middle
      // of the widened zone; leaving them against the left padding put a short row of nodes under
      // one end of a long title and read as a misalignment rather than as a wide title.
      var bandU = cluster.label ? Math.max(inner.contentW, cluster.label.w) : inner.contentW;
      // And one crossed straight through by a line it cannot slide clear of is widened by what the
      // drawing measured it needs; the contents stay centred, so the line moves half of it.
      var roomW = opts.titleRoom && opts.titleRoom[cluster.id];
      if (cluster.label && roomW && roomW.wide > 0) bandU = even(bandU + Math.ceil(roomW.wide / GRID));
      cluster.contentDX = padU + Math.floor((bandU - inner.contentW) / 2);
      cluster.contentDY = padU + header;
      cluster.offCentre = !!inner.offCentre;
      cluster.w = even(bandU + 2 * padU);
      cluster.h = even(inner.contentH + 2 * padU + header);
    }

    var root = model.levels.get("");
    layoutLevel(root, env);

    function place(levelId, ox, oy) {
      var level = model.levels.get(levelId);
      if (!level) return;
      level.originX = ox;
      level.originY = oy;
      for (var c = 0; c < level.children.length; c += 1) {
        var child = level.children[c];
        child.x = ox + child.lx;
        child.y = oy + child.ly;
        if (child.kind === "cluster") place(child.id, child.x + child.contentDX, child.y + child.contentDY);
      }
    }
    // Grid units added to one side of the margin, for a plate the first pass placed outside the
    // content box. See `renderOrDecline`.
    var grow = opts.grow || { left: 0, top: 0, right: 0, bottom: 0 };
    place("", marginU + grow.left, marginU + grow.top);

    var told = outsideOf(model);
    probe.hints = told.hints;
    probe.key = told.key;

    assignPorts(model);
    var counts = tagLadder(model);

    var widthU = root.contentW + 2 * marginU + grow.left + grow.right;
    var heightU = root.contentH + 2 * marginU + grow.top + grow.bottom;
    // A drawing with nothing in it still has to have a positive size: Swift turns a zero width into
    // `.renderProducedNoSVG` (MermaidRenderer.swift:502-522), which would report an engine failure
    // for a source whose only sin is being empty.
    if (widthU <= 0) widthU = 2 * marginU;
    if (heightU <= 0) heightU = 2 * marginU;

    var outNodes = [];
    for (i = 0; i < model.nodes.length; i += 1) {
      var n2 = model.nodes[i];
      outNodes.push({
        id: n2.id,
        index: n2.index,
        domId: n2.vertex.domId,
        shape: n2.shape,
        geometry: geometryOf(n2.shape),
        label: n2.vertex.text,
        labelType: n2.vertex.labelType,
        lines: n2.label.lines,
        lineHeight: px(n2.label.lineHeight),
        labelWidth: px(n2.label.w),
        labelHeight: px(n2.label.h),
        x: px(n2.x),
        y: px(n2.y),
        width: px(n2.w),
        height: px(n2.h),
        cx: px(n2.x) + px(n2.w) / 2,
        cy: px(n2.y) + px(n2.h) / 2,
        rung: n2.rung,
        styles: n2.vertex.styles || [],
        classes: n2.vertex.classes || [],
        parent: n2.parent,
        rank: n2.rank === undefined ? 0 : n2.rank,
        order: n2.order === undefined ? 0 : n2.order
      });
    }

    var outClusters = [];
    for (i = 0; i < model.clusters.length; i += 1) {
      var c2 = model.clusters[i];
      var childIds = [];
      for (var ci = 0; ci < c2.children.length; ci += 1) childIds.push(c2.children[ci].id);
      outClusters.push({
        id: c2.id,
        index: c2.index,
        title: c2.title,
        titleLines: c2.label ? c2.label.lines : [],
        x: px(c2.x),
        y: px(c2.y),
        width: px(c2.w),
        height: px(c2.h),
        // The eyebrow's own box, inside the header band the container reserved for it.
        labelX: px(c2.x + padU),
        labelY: px(c2.y + 1),
        labelWidth: c2.label ? px(c2.label.w) : 0,
        labelHeight: c2.label ? px(c2.label.h) : 0,
        lineHeight: c2.label ? px(c2.label.lineHeight) : 0,
        // How much deeper the header is with a lane under the title (`titleRoom`).
        laneDepth: c2.label ? px(c2.laneU || 0) : 0,
        parent: c2.parent,
        depth: c2.depth,
        direction: model.levels.get(c2.id).dir,
        children: childIds,
        rank: c2.rank === undefined ? 0 : c2.rank,
        order: c2.order === undefined ? 0 : c2.order
      });
    }

    var outEdges = [];
    for (i = 0; i < model.edges.length; i += 1) {
      var e2 = model.edges[i];
      var level2 = model.levels.get(e2.level);
      var via = [];
      if (e2.via && level2) {
        for (var vi = 0; vi < e2.via.length; vi += 1) {
          via.push({
            x: px(level2.originX + e2.via[vi].lx),
            y: px(level2.originY + e2.via[vi].ly)
          });
        }
      }
      var channel = null;
      if (e2.laneAxis && level2) {
        var base = (e2.laneAxis === "y") ? level2.originY : level2.originX;
        channel = { axis: e2.laneAxis, value: px(base + e2.laneLocal) };
      }
      // Only onto a face the shape fixed, a vertex: see `joinStations` for why, and for the wider rule
      // that was measured and rejected.
      var endChannel = null;
      if (e2.laneAxis && level2 && e2.endLaneLocal !== null && e2.endLaneLocal !== undefined && e2.endFace && e2.endFace.fixed) {
        endChannel = { axis: e2.laneAxis, value: px(((e2.laneAxis === "y") ? level2.originY : level2.originX) + e2.endLaneLocal) };
      }
      outEdges.push({
        id: e2.id,
        index: e2.index,
        from: e2.from,
        to: e2.to,
        level: e2.level,
        direction: level2 ? level2.dir : rootDir,
        fromRank: (e2.a && e2.a.rank !== undefined) ? e2.a.rank : null,
        toRank: (e2.b && e2.b.rank !== undefined) ? e2.b.rank : null,
        minLength: e2.minLen,
        reversed: e2.reversed === true,
        selfLoop: e2.selfLoop === true,
        // `inset` is how far the port sank from the bounding box's face to reach the shape's own
        // outline. The router needs it: its stub is measured from the face, not from the port.
        start: { x: px(e2.startPoint.x), y: px(e2.startPoint.y), side: e2.startSide, inset: px(e2.startInset), pitch: px(e2.startPitch || MIN_PITCH) },
        end: { x: px(e2.endPoint.x), y: px(e2.endPoint.y), side: e2.endSide, inset: px(e2.endInset), pitch: px(e2.endPitch || MIN_PITCH) },
        channel: channel,
        endChannel: endChannel,
        via: via,
        label: e2.raw.text,
        labelType: e2.raw.labelType,
        labelLines: e2.label ? e2.label.lines : [],
        labelWidth: e2.labelBox ? px(e2.labelBox.w) : 0,
        labelHeight: e2.labelBox ? px(e2.labelBox.h) : 0,
        lineHeight: e2.label ? px(e2.label.lineHeight) : 0,
        pattern: e2.pattern,
        thickness: e2.thickness,
        arrowStart: e2.arrowStart,
        arrowEnd: e2.arrowEnd,
        kind: e2.kind,
        styles: e2.raw.style || [],
        interpolate: e2.raw.interpolate
      });
    }

    return {
      version: FLOW_VERSION,
      grid: GRID,
      direction: rootDir,
      width: px(widthU),
      height: px(heightU),
      padding: arrangement.diagramPadding,
      nodes: outNodes,
      clusters: outClusters,
      edges: outEdges,
      // Counts, and nothing but counts. The geometry above carries ids and label text because the
      // emitter has to draw them; this is the part `render` is allowed to hand back to the host, so
      // no node id, edge id or label may appear in it (RENDERER-SPEC.md §4.3).
      counts: {
        nodes: model.nodes.length,
        edges: model.edges.length,
        zones: model.clusters.length,
        rungs: counts
      },
      warnings: warnings
    };
  }

  // ===========================================================================
  // Routing.
  //
  // The layout has already settled everything a router could only get wrong by moving a box: which
  // face each end attaches to and where along it, which lane in which gap the edge may travel, and
  // a reserved corridor through every rank it crosses. What is left is joining those points with
  // segments that are each parallel to an axis -- and that is the only thing the code below can
  // express. Every point it appends changes one coordinate, so a diagonal is not something it is
  // careful not to emit; it is something it cannot say. SKILL.md §6 rule 1 calls a diagonal an
  // automatic fail, and unrepresentable is the only form of "never" worth writing down.
  //
  // Two of the six rules survive the layout and are settled here, both by search rather than by
  // hope. Rule 5 -- a connector may not pass behind a box that is not its endpoint. Rule 3 -- two
  // connectors may not run along one another. Every cross-line the router is free to choose is
  // picked from candidates taken off the obstacles' own edges, ordered by distance from the lane
  // the layout reserved, and the first that clears every box and every stroke already drawn wins.
  // When nothing clears, the edge is dashed and its label moves to the visible end, which is the
  // exception rule 5 spells out rather than a silent failure.
  // ===========================================================================

  var STUB_PX = px(STUB);
  // The arrival's counterpart to STUB_PX, and deliberately not the same number. STUB was chosen for
  // LEAVING a port, where the line is bare; arriving, the last 8px of it are under the arrowhead
  // (`refX 8` at the tip, in `markerMarkup`), so a route that turns one stub from the face has
  // 8 - cornerRadius = 4px of line showing and reads as a bulge rather than as an arrow. See
  // ARRIVE, in the layout, for the five settings that were rendered and looked at to land on 24.
  var ARRIVE_PX = px(ARRIVE);
  // SKILL.md §6 rule 2 asks for 6-10px between a label's mask and the stroke it annotates. 8 is the
  // middle of that and the only value in it that is also a grid step, so the mask's own corners
  // stay on the grid without a second rounding rule. Written as the layout's own LABEL_GAP rather
  // than as an 8 of its own: the layout reserves the room and the placer spends it, and two
  // spellings of one number is how those two stop agreeing.
  var LABEL_GAP_PX = px(LABEL_GAP);
  // How much of an ON label's tail an arrowhead takes (HEAD, in the layout's units).
  var HEAD_PX = px(HEAD);
  // How much nearer a label's plate has to be to its own connector than to the nearest connector
  // that is not, before "which line is this naming?" stops needing an answer.
  //
  // One and a half times rule 2's own gap, because the gap is the unit the question is asked in:
  // a mask BESIDE its line stands 8px off it, so a rival 12px further away is at 20px, and the one
  // the mask is attached to is the near one by half again. Swept over the 47-source corpus at 8,
  // 12, 16, 24 and 32: the corpus floor is 4px at every one of them, and what moves is the three
  // drawings the reader sent -- 8px at a target of 8, 12px at 12 and at 16, and back to 4px at 24
  // and 32, where the target stops being reachable and the taper flattens into the verdict this
  // pass exists to get rid of. 12 is the smallest setting that reaches the best margin any
  // position on those three drawings' connectors offers.
  var LABEL_MARGIN_PX = px(3);
  // A self-loop's bulge, and its return leg -- one number, because a loop is symmetric about the
  // face it leaves and lands on. It was half the 32px node spacing, so the loop sat inside the gap
  // the layout already left beside the node rather than reaching the next column; what that missed
  // is that 16px is also exactly a corner radius plus a head, and all 9 self-loops in the corpus
  // came back in with no shaft at all. ARRIVE_PX is three quarters of that gap rather than half,
  // so the loop still ends inside it. Measured over the corpus the loops' closest approach to a box
  // they are not attached to is unchanged at 56px, and rendered at 24px a loop still reads as a
  // loop -- at 28 and 32 it stops being a return and becomes a rectangle stuck on the side.
  var LOOP_PX = ARRIVE_PX;
  // A cap on how far the cross-line search will look, not a budget it spends. Measured over 39
  // sources up to 200 nodes and 228 edges, the accepted candidate's index never exceeded 2 and the
  // mean was 0.03 -- the lane the layout reserved is almost always clear, which is what it was
  // reserved for. The cap is here because the candidate list is O(nodes) -- it reached 403 on the
  // 200-node source -- and without it an adversarial drawing would make routing quadratic in the
  // node count for candidates nothing ever reaches.
  var MAX_CANDIDATES = 96;

  function snap4(value) {
    return GRID * Math.round(value / GRID);
  }

  function sign(n) {
    return n > 0 ? 1 : (n < 0 ? -1 : 0);
  }

  function outwardOf(side) {
    if (side === "top") return { x: 0, y: -1 };
    if (side === "bottom") return { x: 0, y: 1 };
    if (side === "left") return { x: -1, y: 0 };
    return { x: 1, y: 0 };
  }

  // Duplicate points and collinear runs are dropped rather than prevented: a route is assembled
  // from independent legs and a leg that needs no lateral move produces the same point twice. This
  // is the de-duplication d3's `step` output needs too, and it is exact here because there are no
  // fractions to compare.
  function mergeRoute(points) {
    var out = [];
    var i;
    for (i = 0; i < points.length; i += 1) {
      var p = points[i];
      var last = out.length > 0 ? out[out.length - 1] : null;
      if (last && last.x === p.x && last.y === p.y) continue;
      out.push({ x: p.x, y: p.y });
    }
    i = 1;
    while (i + 1 < out.length) {
      var a = out[i - 1], b = out[i], c = out[i + 1];
      if ((a.x === b.x && b.x === c.x) || (a.y === b.y && b.y === c.y)) out.splice(i, 1);
      else i += 1;
    }
    return out;
  }

  // Strict on every side, which is what lets a port sit exactly on its own box's boundary without
  // reporting that the edge starts inside the node.
  function hitsBox(p, q, box) {
    return Math.max(p.x, q.x) > box.x
      && Math.min(p.x, q.x) < box.x + box.width
      && Math.max(p.y, q.y) > box.y
      && Math.min(p.y, q.y) < box.y + box.height;
  }

  // Only a shared stretch counts. Two connectors crossing at a point is a crossing -- dd-arch.md's
  // bridge primitive, not a violation -- while two sharing a run is rule 3's "cannot tell them
  // apart at a glance".
  function runsAlong(p, q, r, s) {
    if (p.x === q.x && r.x === s.x && p.x === r.x) {
      return Math.min(Math.max(p.y, q.y), Math.max(r.y, s.y)) - Math.max(Math.min(p.y, q.y), Math.min(r.y, s.y)) > 0;
    }
    if (p.y === q.y && r.y === s.y && p.y === r.y) {
      return Math.min(Math.max(p.x, q.x), Math.max(r.x, s.x)) - Math.max(Math.min(p.x, q.x), Math.min(r.x, s.x)) > 0;
    }
    return false;
  }

  // How close a leg may run to the SIDE of a box it is only passing. `hitsBox` is strict on every
  // side, so a leg exactly on a box's outline counts as clear of it -- and in a two-subgraph drawing
  // two legs took that literally: they ran down x=100 and x=196 while the API Server box spanned
  // exactly 100..196, 152px of connector drawn along a border, over its rounded corners, with no way
  // to tell the line from a doubled outline. SKILL.md §6 rule 3 wants 12px between two lines a
  // reader has to trace apart; a line and a box border are two lines.
  //
  // Passing THROUGH is still `hitsBox`'s business and still a flat no. This is only about how near
  // a leg may run alongside, and it is measured on the axis the leg runs across.
  var PASS_CLEAR = 3;
  var PASS_CLEAR_PX = px(PASS_CLEAR);
  // A zone's border is a 0.8px hairline painted before everything else, and the space it leaves
  // between its own edge and the boxes inside it is 16px -- two stubs. Holding 12px there is not
  // possible for a connector leaving one of those boxes, so a zone asks for the stub instead: far
  // enough that the line and the hairline are two lines, near enough to be achievable. Measured on
  // the two-subgraph drawing, where the 12px rule alone had nothing to offer and the search fell
  // all the way back to a leg drawn along the API Server's outline.
  var ZONE_CLEAR_PX = STUB_PX;

  // Measured against the two BORDERS the leg runs beside rather than against the box as a whole, so
  // that a leg deep inside a container -- which is where a connector into a subgraph has to be --
  // is not confused with one drawn along its outline.
  function passesTooClose(p, q, box, clear) {
    if (p.x === q.x) {
      if (Math.min(p.y, q.y) >= box.y + box.height || Math.max(p.y, q.y) <= box.y) return false;
      return Math.abs(p.x - box.x) < clear || Math.abs(p.x - (box.x + box.width)) < clear;
    }
    if (p.y === q.y) {
      if (Math.min(p.x, q.x) >= box.x + box.width || Math.max(p.x, q.x) <= box.x) return false;
      return Math.abs(p.y - box.y) < clear || Math.abs(p.y - (box.y + box.height)) < clear;
    }
    return false;
  }

  // The zones a connector has no business inside: every zone that contains neither of its ends.
  // A zone is a painted panel that says "these go together", so a stroke across its interior reads
  // as one more member. Its own ancestors are excluded because reaching a node in a nested zone
  // means crossing every zone around it, which is the one passage a reader expects.
  //
  // Kept per edge on the context: `legIsClear` asks for it once per candidate leg, and the answer
  // depends only on the edge.
  function foreignZones(edge, ctx) {
    if (!edge || !ctx.rails || ctx.rails.length === 0) return [];
    var cached = ctx.foreign.get(edge);
    if (cached) return cached;
    var own = new Map();
    var ends = [edge.from, edge.to];
    for (var e = 0; e < ends.length; e += 1) {
      // A subgraph cannot contain its own ancestor, so the walk ends; the bound is the same guard
      // `ancestry` keeps against a malformed model.
      var cur = ends[e];
      for (var guard = 0; guard < 256 && cur !== undefined && cur !== null; guard += 1) {
        own.set(cur, true);
        cur = ctx.parentOf.get(cur);
      }
    }
    var out = [];
    for (var i = 0; i < ctx.rails.length; i += 1) {
      if (!own.has(ctx.rails[i].id)) out.push(ctx.rails[i]);
    }
    ctx.foreign.set(edge, out);
    return out;
  }

  // How many legs of a route cross the inside of a foreign zone. The post-routing passes compare
  // this before and after, so that a shortcut cannot buy a straight line by cutting back through a
  // zone the router had just gone round.
  function foreignPassages(points, ctx, edge) {
    var zones = foreignZones(edge, ctx);
    var n = 0;
    for (var i = 0; i + 1 < points.length; i += 1) {
      for (var z = 0; z < zones.length; z += 1) {
        if (hitsBox(points[i], points[i + 1], zones[z])) n += 1;
      }
    }
    return n;
  }

  // `strict` counts down the demands rather than switching them: 4 wants everything 3 does and also
  // keeps out of the interior of every zone the edge does not belong to; 3 wants daylight from
  // every border this edge is not attached to -- 12px from a node's, a stub from a zone's hairline
  // -- AND no shared run with a stroke already drawn; 2 drops the daylight; 1 keeps only "not
  // behind a box"; 0 accepts whatever the first candidate was.
  //
  // The zone interior is a pass of its own on top rather than a clause folded into 3, because it
  // is a preference with a fallback: where no route goes round, the edge has to come out of 3
  // exactly as it did before, not be pushed down to 2 and lose its daylight from every border to
  // keep a rule it cannot keep anyway. Folding it into 2 as well was the other shape considered and
  // is worse the same way -- an unavoidable zone would then cost the stroke rule and raise
  // `edge-crowded` on a drawing whose only fault is a zone in the way.
  //
  // Before this, the zone rule was `passesTooClose` alone, which is about running ALONG a border,
  // so a leg deep inside a foreign zone was clear by every test it was given. That is how
  // `app2 --> s3` came to run the full height of the Database Tier in the nested review source and
  // `dlq --> p1` (replay) to climb through Processing in the crowded one.
  // A leg on the line of a port whose node is inside `zone`, running from that port's station. Such
  // a leg is where the layout put the port, under the zone's own title or not, and no choice of
  // lane moves it; the title pass excuses it so that the rest of the route can still be asked to
  // keep off the title, and the layout is asked for the room (`roomAt`). A port in another zone
  // is not excused: its line crosses this title only because the route chose to turn onto it here.
  function onPortLine(p, q, ctx, zone) {
    var a = ctx.portLines;
    if (!a) return false;
    for (var i = 0; i < a.length; i += 1) {
      var s = a[i];
      if (!insideZone(s.node, zone.id, ctx)) continue;
      if (s.x === null ? (p.y === s.y && q.y === s.y) : (p.x === s.x && q.x === s.x)) {
        if ((p.x === s.at.x && p.y === s.at.y) || (q.x === s.at.x && q.y === s.at.y)) return true;
      }
    }
    return false;
  }

  function legIsClear(p, q, ctx, strict, edge) {
    var i;
    var box;
    for (i = 0; i < ctx.boxes.length; i += 1) {
      if (hitsBox(p, q, ctx.boxes[i])) return false;
    }
    // The title pass (`routeEdge`): no leg through a zone title or the gap round it.
    if (strict >= 5 && ctx.titleRooms) {
      for (i = 0; i < ctx.titleRooms.length; i += 1) {
        var room = ctx.titleRooms[i];
        if (segmentCrossesRect(p, q, room) && !onPortLine(p, q, ctx, room.zone)) return false;
      }
    }
    if (strict >= 4) {
      var zones = foreignZones(edge, ctx);
      for (i = 0; i < zones.length; i += 1) {
        if (hitsBox(p, q, zones[i])) return false;
      }
    }
    if (strict >= 3) {
      for (i = 0; i < ctx.boxes.length; i += 1) {
        box = ctx.boxes[i];
        // Its own two boxes are exempt: every route leaves one of them by a stub of 8px and has to
        // be allowed to turn there, and a line beside the box it is attached to is traceable
        // BECAUSE it is attached -- the eye follows it out of the node it starts in.
        if (edge && (box.id === edge.from || box.id === edge.to)) continue;
        if (passesTooClose(p, q, box, PASS_CLEAR_PX)) return false;
      }
      // Zone borders are not obstacles -- a connector into a subgraph crosses one by definition --
      // but they are painted lines, and a leg drawn along one is as unreadable as a leg drawn along
      // a node's edge. In the two-subgraph drawing the same two legs that ran down the API Server's
      // sides also ran down the Backend zone's, which is how this came to be tested separately.
      for (i = 0; i < ctx.rails.length; i += 1) {
        box = ctx.rails[i];
        if (edge && (box.id === edge.from || box.id === edge.to)) continue;
        if (passesTooClose(p, q, box, ZONE_CLEAR_PX)) return false;
      }
    }
    if (strict < 2) return true;
    for (i = 0; i < ctx.drawn.length; i += 1) {
      if (runsAlong(p, q, ctx.drawn[i][0], ctx.drawn[i][1])) return false;
    }
    return true;
  }

  // A sidestep of one grid unit has no radius it can be drawn with, so it is drawn square.
  // `cornerRadius` returns zero for a 4px leg -- the two corners share that leg, so each could have
  // at most 2px, which is off the grid -- and `pathOf` then takes its `r <= 0` branch at both ends.
  //
  // `alignUnitJog` removes these in the LAYOUT by sliding a port, and that is the better place
  // because it is the cheapest and it happens before anything depends on the geometry. What reaches
  // here is the remainder: the jogs whose face was too full to give the step up. Instrumented on
  // `rank skip LR`, `alignUnitJog` sees the delta and reports failure on both of its passes --
  // `slideAlongFace` refuses to close the step, to widen it to three units, and to widen it to two
  // -- because the destination already carries three ports at the minimum pitch. Over the 172-source
  // sweep that left 4 square corners, in `rank skip LR` and its RL mirror.
  //
  // The lever still available is the RUN rather than the port. A jog sits between two straight runs;
  // moving whichever of them does not end on a port onto the other's line removes the jog outright,
  // and usually merges the two runs into one straight line. Where the drawing has no room for that,
  // widening the jog to two units is the other legal shape -- a pair of 4px arcs that touch, which
  // the emitter's own note already allows under rule 1.
  //
  // Both candidates go through `routeIsClear` at full strictness against every stroke already
  // drawn, so this cannot buy a straight line by laying one connector along another. A jog that
  // neither move can fix is left alone and still draws square; the record in Tests/JavaScript/flow/
  // corpus.js is what says whether any remain.
  function withoutKinks(points) {
    var out = [points[0]];
    for (var i = 1; i < points.length; i += 1) {
      var p = points[i];
      var last = out[out.length - 1];
      if (p.x === last.x && p.y === last.y) continue;
      if (out.length >= 2) {
        var prev = out[out.length - 2];
        if ((prev.x === last.x && last.x === p.x) || (prev.y === last.y && last.y === p.y)) {
          out[out.length - 1] = p;
          continue;
        }
      }
      out.push(p);
    }
    return out;
  }

  // Every leg with a turn at both ends has to be long enough for two 4px arcs, which is 8px. A
  // candidate that fixes one jog by making another is not an improvement.
  function legsAreDrawable(points) {
    for (var i = 1; i + 2 < points.length; i += 1) {
      var run = Math.abs(points[i + 1].x - points[i].x) + Math.abs(points[i + 1].y - points[i].y);
      if (run < 2 * GRID) return false;
    }
    return true;
  }

  // A detour the drawing no longer needs.
  //
  // A route is built from the ports outwards through whatever lane its rank gap assigned it, and
  // the lane is chosen before the rest of the drawing exists. By the time every box is placed the
  // reason for a particular excursion may be gone, and nothing went back to look. `D --> B` in
  // `two back edges LR` is the shape of it: both ports sit at y=96 and the stroke runs
  // 400,96 -> 376,96 -> 376,108 -> 288,108 -> 288,96 -> 232,96, dropping into the back-edge lane
  // and climbing straight back out of it, 12px down and 12px up to cover ground it could have
  // crossed in one line. A reader sees a connector that wanders.
  //
  // So: any two stations that share a coordinate are offered the straight run between them, longest
  // span first, and the first one that is clear wins. `routeIsClear` at full strictness is the
  // whole of the judgement -- boxes, zones, and running along another stroke -- which is also why
  // this is safe to do blind: a shortcut that would lie along a connector already drawn is refused
  // by the same rule that stopped the router taking it in the first place.
  //
  // Longest first is the point, not an optimisation. Collapsing the innermost wobble of a detour
  // leaves the detour, and the pass would then have to be run to a fixed point to find what one
  // look could have seen.
  function straightenDetours(points, ctx, edge) {
    var current = points;
    var moved = true;
    while (moved) {
      moved = false;
      for (var span = current.length - 1; span >= 2 && !moved; span -= 1) {
        for (var a = 0; a + span < current.length && !moved; a += 1) {
          var b = a + span;
          var p = current[a], q = current[b];
          if (p.x !== q.x && p.y !== q.y) continue;
          var candidate = current.slice(0, a + 1).concat(current.slice(b));
          candidate = withoutKinks(candidate);
          if (candidate.length < 2) continue;
          if (candidate.length >= current.length) continue;
          if (!legsAreDrawable(candidate)) continue;
          if (!routeIsClear(candidate, ctx, 2, edge)) continue;
          if (foreignPassages(candidate, ctx, edge) > foreignPassages(current, ctx, edge)) continue;
          current = candidate;
          moved = true;
        }
      }
    }
    return current;
  }

  function closeUnitJogs(points, ctx, edge) {
    var current = points;
    // Closing is tried on every jog before any is widened, for the same reason `alignUnitJog`
    // orders its own two passes that way: a widened jog is a wobble that a later close would have
    // removed outright, and once widened it no longer looks like a jog to find.
    for (var pass = 0; pass < 2; pass += 1) {
      var moved = true;
      while (moved) {
        moved = false;
        for (var i = 1; i + 2 < current.length; i += 1) {
          var b = current[i], c = current[i + 1];
          if (Math.abs(b.x - c.x) + Math.abs(b.y - c.y) !== GRID) continue;
          var axis = (b.x === c.x) ? "y" : "x";
          var step = c[axis] - b[axis];
          // A run that ends on a port cannot move: the port is the face's answer and sliding it is
          // what `alignUnitJog` already tried.
          var sides = [];
          if (i - 1 > 0) sides.push(-1);
          if (i + 2 < current.length - 1) sides.push(1);
          for (var s = 0; s < sides.length && !moved; s += 1) {
            var side = sides[s];
            var want = pass === 0
              ? (side < 0 ? c[axis] : b[axis])
              : (side < 0 ? b[axis] - step : c[axis] + step);
            var first = side < 0 ? i - 1 : i + 1;
            var candidate = [];
            for (var k = 0; k < current.length; k += 1) {
              if (k === first || k === first + 1) {
                var shifted = { x: current[k].x, y: current[k].y };
                shifted[axis] = want;
                candidate.push(shifted);
              } else {
                candidate.push(current[k]);
              }
            }
            candidate = withoutKinks(candidate);
            if (candidate.length < 2) continue;
            if (!legsAreDrawable(candidate)) continue;
            if (!routeIsClear(candidate, ctx, 2, edge)) continue;
            if (foreignPassages(candidate, ctx, edge) > foreignPassages(current, ctx, edge)) continue;
            current = candidate;
            moved = true;
          }
          if (moved) break;
        }
      }
    }
    return current;
  }

  // Two connectors that cross each other twice.
  //
  // Each route is chosen alone, against the strokes drawn before it, and nothing in that choice
  // counts crossings: the first clear cross-line nearest the reserved lane wins. So two edges whose
  // cross-runs share a stretch of one rank gap can come out in the order where each one's leg cuts
  // the other's run -- a crossing, a stretch side by side, and a crossing back. That is the braid
  // the review could not trace through ("rows of bumps"), and between the two of them it is never
  // needed: swap the two runs' coordinates and the same two shapes cross each other zero times.
  // Whether the swap is TAKEN depends on the rest of the drawing -- below. Measured over the 16 review sources
  // before this pass, 15 pairs of connectors crossed twice -- 11 of them in the dense 14-node DAG,
  // where they were 22 of its 43 crossings -- and none in the 172-source sweep.
  //
  // Reordering the gap's LANES in the layout was the first lever tried, since lanes are handed out
  // in declaration order with no notion of crossings: every permutation of each gap's lanes,
  // scored by crossings at the box centres, the best one kept. It predicted 43 in-gap crossings
  // falling to 28 over the review sources and drew 90 crossings where there had been 90. The
  // prediction is made at the centres, before ports are fanned and before the router departs from
  // a lane it cannot take, so it was optimising a drawing that is never made. This works on the
  // finished points instead.
  //
  // A swap only moves two interior runs along their own normal, so it adds no bend, leaves both
  // ports and both stubs where they were (a stub may lengthen, never drop below its floor), and is
  // kept only when the two routes together cross strictly fewer strokes than before, are still
  // clear at the same strictness `straightenDetours` asks for, and enter no foreign zone they did
  // not already. Self-loops are not offered: the loop is the detour.
  //
  // The rule it keeps is about any two links, and was narrower than that: no two links cross more
  // than once, and two links between ONE pair of nodes never cross at all -- a two-way pair is the
  // pair a reader most wants to read as a matched there-and-back. The third held-out set showed how
  // far short the pass fell. Over the review sources and two held-out sets 9 pairs crossed twice, one
  // of them a two-way pair crossing itself twice (b11, Esc and Resume); every one was offered and
  // refused, for the first two reasons below, and the third shape was never offered at all:
  //  - A swap could only move interior runs. b11's pair stood in swapped order on BOTH faces, and
  //    the one interior swap took its two crossings away and put two back on other routes (4 before,
  //    4 after). What undoes it is trading which route takes which port, so where two routes end on
  //    one flat face of one box their end runs are offered too: the face keeps the same ports at the
  //    same pitch, only their owners trade. Moving the crossing onto two other routes is then worth
  //    taking when it removes a knot and adds none -- kept when no count rises and one falls, among
  //    all crossings, knots, and crossings between routes that share a node.
  //  - The clearance test refused every swap whose route ended on a circle or a cylinder: it asked
  //    `routeIsClear` of the whole route, and a port sunk into a round outline starts inside its own
  //    box's rectangle. That was wrong, not strict -- `stubsAndBodyClear` already excuses that box on
  //    that leg -- so the stubs are now asked only to keep off other strokes. Both of b12's pairs,
  //    under ThemeContext and under the store, were refused this way.
  //  - A two-way pair crossing once was never offered: the pass started at two crossings.
  // Over those 56 drawings that leaves 3 pairs crossing more than once and no two-way pair crossing
  // itself. What is left is three routes in one gap, where every trade of two moves the second
  // crossing onto a third route or lays a run along one -- 11-hard-dense's A -> M against L's two
  // exits, and b09's two exits from CS360 -- and a gap with too few lanes: a hub fanning to three,
  // with a two-way pair to a node past the middle child, trades its pair's crossing for one with the
  // hub's last child, because that child's jog cannot drop below the pair's turn and keep its
  // arrival. Both need a run moved to a lane nobody holds, which is a slide, not a trade.
  //
  // Rejected: a second pass beside this one for two-way pairs. The moves and every check on them
  // are this pass's, and b11's pair crossed twice, so it was this pass's to undo already.
  function crossesAt(p, q, r, s) {
    if (p.y === q.y && r.x === s.x) {
      return r.x > Math.min(p.x, q.x) && r.x < Math.max(p.x, q.x) && p.y > Math.min(r.y, s.y) && p.y < Math.max(r.y, s.y);
    }
    if (p.x === q.x && r.y === s.y) return crossesAt(r, s, p, q);
    return false;
  }

  function crossingsBetween(a, b) {
    var n = 0;
    for (var i = 0; i + 1 < a.length; i += 1) {
      for (var j = 0; j + 1 < b.length; j += 1) {
        if (crossesAt(a[i], a[i + 1], b[j], b[j + 1])) n += 1;
      }
    }
    return n;
  }

  // Between every two routes the corridors pass orders -- no self-loop, no transit leg -- the
  // crossings, and the stretches drawn on one line (`runsAlong`) or beside one (`besideCount`).
  function tangleOfRoutes(routed) {
    var live = routed.filter(function (r) { return r && !r.edge.selfLoop && !r.transit; });
    var out = { crossed: 0, doubled: 0 };
    for (var a = 0; a < live.length; a += 1) {
      var p = live[a].points;
      for (var b = a + 1; b < live.length; b += 1) {
        var q = live[b].points;
        out.crossed += crossingsBetween(p, q);
        out.doubled += besideCount(p, [live[b]]);
        for (var i = 0; i + 1 < p.length; i += 1) {
          for (var j = 0; j + 1 < q.length; j += 1) if (runsAlong(p[i], p[i + 1], q[j], q[j + 1])) out.doubled += 1;
        }
      }
    }
    return out;
  }

  // The route with run k (points k and k+1) moved onto `value` across its own axis, or null when
  // that would turn a leg round, shorten a stub below its floor, or leave a leg too short to round.
  function shiftRun(points, k, value, edge) {
    var axis = (points[k].y === points[k + 1].y) ? "y" : "x";
    var out = points.map(function (p) { return { x: p.x, y: p.y }; });
    out[k][axis] = value;
    out[k + 1][axis] = value;
    for (var i = 0; i + 1 < out.length; i += 1) {
      var was = sign(points[i + 1].x - points[i].x) + 2 * sign(points[i + 1].y - points[i].y);
      var now = sign(out[i + 1].x - out[i].x) + 2 * sign(out[i + 1].y - out[i].y);
      if (was !== now) return null;
    }
    var last = out.length - 1;
    var first = Math.abs(out[1].x - out[0].x) + Math.abs(out[1].y - out[0].y);
    var arrive = Math.abs(out[last].x - out[last - 1].x) + Math.abs(out[last].y - out[last - 1].y);
    if (first < STUB_PX + edge.start.inset) return null;
    if (arrive < ARRIVE_PX + edge.end.inset) return null;
    if (!legsAreDrawable(out)) return null;
    return out;
  }

  // Whether two routes join the same two nodes, either way round: a two-way pair, or two links
  // written between one pair. Self-loops never reach here.
  function sameEnds(a, b) {
    return (a.from === b.from && a.to === b.to) || (a.from === b.to && a.to === b.from);
  }

  function shareNode(a, b) {
    return a.from === b.from || a.from === b.to || a.to === b.from || a.to === b.to;
  }

  // What the pass counts as a knot: every crossing between two routes past their first, and every
  // crossing at all between two that join the same two nodes. A single crossing between unrelated
  // routes is the drawing's business; a second is the braid, and a two-way pair crossing itself is
  // the one pair a reader most wants to see as a matched there-and-back.
  function knotsOf(n, a, b) {
    return sameEnds(a, b) ? n : Math.max(0, n - 1);
  }

  // The runs of two routes that can trade places across their shared normal: every pair of parallel
  // interior runs, and the two END runs where both routes have an end on one flat face of one box.
  // Trading two end runs trades the two ports, which leaves the face holding the same ports at the
  // same pitch and corner clearance the layout gave it -- only which route takes which changes.
  // Only on a rectangle with both ports unsunk, as `portSlides` asks: on an outline the port would
  // have to be re-sunk at its new offset.
  function exchanges(P, Q, ctx) {
    var out = [];
    var np = P.points.length, nq = Q.points.length;
    for (var j = 1; j + 2 < np; j += 1) {
      for (var k = 1; k + 2 < nq; k += 1) out.push([j, k]);
    }
    if (np < 3 || nq < 3) return out;
    function flatEnd(r, end) {
      var id = end === 0 ? r.edge.from : r.edge.to;
      var tip = end === 0 ? r.edge.start : r.edge.end;
      var box = ctx.boxById.get(id);
      return box && box.geometry === "rect" && tip.inset === 0 ? { id: id, side: tip.side } : null;
    }
    var ends = [0, 1];
    for (var a = 0; a < 2; a += 1) {
      for (var b = 0; b < 2; b += 1) {
        var fp = flatEnd(P, ends[a]), fq = flatEnd(Q, ends[b]);
        if (!fp || !fq || fp.id !== fq.id || fp.side !== fq.side) continue;
        out.push([ends[a] === 0 ? 0 : np - 2, ends[b] === 0 ? 0 : nq - 2]);
      }
    }
    return out;
  }

  // The two routes with each exchange in `moves` applied, or null where `shiftRun` refuses one.
  function exchanged(P, Q, moves) {
    var p = P.points, q = Q.points;
    for (var m = 0; m < moves.length; m += 1) {
      var j = moves[m][0], k = moves[m][1];
      var pH = p[j].y === p[j + 1].y;
      if (pH !== (q[k].y === q[k + 1].y)) return null;
      var pc = pH ? p[j].y : p[j].x;
      var qc = pH ? q[k].y : q[k].x;
      if (pc === qc) return null;
      var p2 = shiftRun(p, j, qc, P.edge);
      var q2 = shiftRun(q, k, pc, Q.edge);
      if (!p2 || !q2) return null;
      p = p2;
      q = q2;
    }
    return [p, q];
  }

  function uncrossPairs(routed, ctx) {
    var live = [];
    for (var i = 0; i < routed.length; i += 1) {
      if (routed[i] && !routed[i].edge.selfLoop) live.push(routed[i]);
    }
    // Crossings and knots between `points` (standing for `self`) and every route but the two moved.
    function againstOthers(points, self, skipA, skipB) {
      var n = 0, knots = 0, kin = 0;
      for (var o = 0; o < live.length; o += 1) {
        if (live[o] === skipA || live[o] === skipB) continue;
        var c = crossingsBetween(points, live[o].points);
        n += c;
        knots += knotsOf(c, self.edge, live[o].edge);
        if (shareNode(self.edge, live[o].edge)) kin += c;
      }
      return { n: n, knots: knots, kin: kin };
    }
    function tally(p, q, P, Q) {
      var mutual = crossingsBetween(p, q);
      var a = againstOthers(p, P, P, Q), b = againstOthers(q, Q, P, Q);
      var kin = (shareNode(P.edge, Q.edge) ? mutual : 0) + a.kin + b.kin;
      return { n: mutual + a.n + b.n, knots: knotsOf(mutual, P.edge, Q.edge) + a.knots + b.knots, kin: kin };
    }
    // The legs between the two stubs against boxes and strokes at `straightenDetours`' strictness,
    // and the stubs against strokes alone. A stub is excused its own box by `stubsAndBodyClear`, and
    // has to be here too: a port sunk into a round outline starts inside its own box's rectangle,
    // so the whole route asked of `routeIsClear` was refused for every swap whose end sat on a
    // circle or a cylinder -- held-out b12's two knots, under ThemeContext and under the store,
    // were both refused so, by both routes, with nothing near either of them.
    function clearWith(points, edge, skipA, skipB, partner) {
      var drawn = [];
      for (var o = 0; o < live.length; o += 1) {
        if (live[o] === skipA || live[o] === skipB) continue;
        for (var s = 0; s + 1 < live[o].points.length; s += 1) drawn.push([live[o].points[s], live[o].points[s + 1]]);
      }
      for (var t = 0; t + 1 < partner.length; t += 1) drawn.push([partner[t], partner[t + 1]]);
      var last = points.length - 1;
      var stubs = [[points[0], points[1]], [points[last - 1], points[last]]];
      for (var e = 0; e < 2; e += 1) {
        for (var d = 0; d < drawn.length; d += 1) {
          if (runsAlong(stubs[e][0], stubs[e][1], drawn[d][0], drawn[d][1])) return false;
        }
      }
      var saved = ctx.drawn;
      ctx.drawn = drawn;
      var ok = points.length < 4 || routeIsClear(points.slice(1, last), ctx, 2, edge);
      ctx.drawn = saved;
      return ok;
    }
    // Bounded, because each accepted exchange strictly lowers a finite sum and a few rounds is all
    // any measured source uses; the bound is there so a pathological source costs time linearly.
    for (var round = 0; round < 4; round += 1) {
      var moved = false;
      for (var a = 0; a < live.length; a += 1) {
        for (var b = a + 1; b < live.length; b += 1) {
          var P = live[a], Q = live[b];
          if (P.transit || Q.transit) continue;
          var mutual = crossingsBetween(P.points, Q.points);
          if (knotsOf(mutual, P.edge, Q.edge) === 0 && !(mutual > 0 && shareNode(P.edge, Q.edge))) continue;
          var before = tally(P.points, Q.points, P, Q);
          var single = exchanges(P, Q, ctx);
          // One exchange, then two at once: a two-way pair whose ports stand swapped on BOTH faces
          // crosses itself once per face, and trading either pair of ports alone can cost a crossing
          // elsewhere that trading both does not.
          var offers = single.map(function (x) { return [x]; });
          for (var u = 0; u < single.length; u += 1) {
            for (var v = u + 1; v < single.length; v += 1) {
              if (single[u][0] !== single[v][0] && single[u][1] !== single[v][1]) offers.push([single[u], single[v]]);
            }
          }
          var taken = false;
          for (var f = 0; f < offers.length; f += 1) {
            var next = exchanged(P, Q, offers[f]);
            if (!next || !keeps(next, P, Q, before)) continue;
            P.points = next[0];
            Q.points = next[1];
            moved = taken = true;
            break;
          }
          if (taken || !sameEnds(P.edge, Q.edge)) continue;
          var slid = slideApart(P, Q, offers, mutual, before);
          if (!slid) continue;
          P.points = slid[0];
          Q.points = slid[1];
          easeAround(P, Q);
          moved = true;
        }
      }
      if (!moved) break;
    }
    // A trade is kept when no count rises and one falls, when both routes stay clear of every box
    // and stroke, and when neither enters a foreign zone it did not already.
    function keeps(next, P, Q, before) {
      var after = tally(next[0], next[1], P, Q);
      if (after.n > before.n || after.knots > before.knots || after.kin > before.kin) return false;
      if (after.n === before.n && after.knots === before.knots && after.kin === before.kin) return false;
      if (!stubsAndBodyClear(next[0], ctx, P.edge) || !stubsAndBodyClear(next[1], ctx, Q.edge)) return false;
      if (!clearWith(next[0], P.edge, P, Q, next[1]) || !clearWith(next[1], Q.edge, P, Q, next[0])) return false;
      if (foreignPassages(next[0], ctx, P.edge) > foreignPassages(P.points, ctx, P.edge)) return false;
      if (foreignPassages(next[1], ctx, Q.edge) > foreignPassages(Q.points, ctx, Q.edge)) return false;
      return true;
    }
    // A third route the slide left within PASS_CLEAR_PX of the pair's runs, offered a slide of one of
    // its own runs, a grid step at a time up to SLIDE_STEPS each way: kept, cheapest first, when it
    // lays fewer runs near a parallel stroke (`nearRuns`), no more beside one, crosses no more, and
    // passes a trade's clearances.
    //
    // `slideApart` holds the PAIR to no more near runs than it had, and that is a count: in b11 it
    // traded Esc's and Resume's ports at Paused and stood Resume's riser at x 596, past Esc's, which
    // took Esc's two near runs against Quit to title -- the two risers on x 580 meeting end to end,
    // and Esc's run ending where Quit's began -- down to one, Resume's run on y 160 under Quit's on
    // y 156, 4px apart for 16px. No slide of the pair parts them: Resume's riser has to stand past
    // Esc's at x 580 to nest, and Quit's run starts at x 580. Quit's jog moved to x 608, 12px past
    // Resume's riser, does.
    // Rejected: asking `slideApart` for no near run at all. No slide qualifies in b11, Esc and
    // Resume cross each other again and the drawing has 4 crossings where it has 3.
    function easeAround(P, Q) {
      for (var t = 0; t < live.length; t += 1) {
        var R = live[t];
        if (R === P || R === Q || R.transit || nearRuns(R.points, [P, Q]) === 0) continue;
        var rest = live.filter(function (o) { return o !== R; });
        var was = R.points;
        var near0 = nearRuns(was, rest), beside0 = besideCount(was, rest), seated0 = inSeats(was, rest);
        var crossed0 = againstOthers(was, R, R, null).n;
        var best = null;
        for (var k = 1; k + 2 < was.length; k += 1) {
          var axis = was[k].y === was[k + 1].y ? "y" : "x";
          for (var d = 1; d <= 2 * SLIDE_STEPS; d += 1) {
            var cost = Math.ceil(d / 2);
            if (best && best.cost < cost) break;
            var next = shiftRun(was, k, was[k][axis] + (d % 2 ? -1 : 1) * cost * GRID, R.edge);
            if (!next) continue;
            var near = nearRuns(next, rest);
            if (near >= near0 || (best && best.near <= near)) continue;
            if (besideCount(next, rest) > beside0 || againstOthers(next, R, R, null).n > crossed0) continue;
            if (inSeats(next, rest) > seated0) continue;
            if (!stubsAndBodyClear(next, ctx, R.edge) || !clearWith(next, R.edge, R, null, [])) continue;
            if (foreignPassages(next, ctx, R.edge) > foreignPassages(was, ctx, R.edge)) continue;
            best = { next: next, near: near, cost: cost };
          }
        }
        if (best) R.points = best.next;
      }
    }
    // Runs of `points` laid along a labelled route's parallel run, overlapping it, closer across it
    // than its plate's extent across plus LABEL_GAP: the room the label pass, which runs after this
    // one, will want for that plate. Asked of `easeAround` because a run eased off the pair can be
    // eased into that room: in 30,000 random graphs with a two-way pair it was, three times, and each
    // drawing then warned label-crowded where it had not. With this two do not and the
    // third still does; over the same graphs warnings go from 34 to 35 where they went to 37.
    function inSeats(points, others) {
      var n = 0;
      for (var o = 0; o < others.length; o += 1) {
        var edge = others[o].edge, q = others[o].points;
        if (!(edge.labelWidth > 0) || !(edge.labelHeight > 0)) continue;
        for (var i = 0; i + 1 < points.length; i += 1) {
          var a = points[i], b = points[i + 1];
          var h = a.y === b.y;
          var seat = (h ? edge.labelHeight : edge.labelWidth) + LABEL_GAP_PX;
          for (var j = 0; j + 1 < q.length; j += 1) {
            var c = q[j], d = q[j + 1];
            if (h !== (c.y === d.y)) continue;
            var gap = h ? Math.abs(a.y - c.y) : Math.abs(a.x - c.x);
            var lo = h ? Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) : Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y));
            var hi = h ? Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) : Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y));
            if (gap < seat && hi > lo) n += 1;
          }
        }
      }
      return n;
    }
    // A two-way pair every trade left crossing: each trade again, or none, with one run of either
    // route slid to a lane nobody holds, nearest first.
    //
    // 14a73f8 spread a face's labelled ends 32px apart, and two pairs a09c1af had untwisted crossed
    // again in the third held-out set -- not because the pass ran before the spread (ports are laid
    // out before any route exists, and this pass runs on the finished routes), but because every
    // trade it offered was refused. In b11 trading Esc's and Resume's ports at Playing put Resume's
    // last run on y 276, which Boss defeated's run into Stage clear holds over 80px: at a 32px pitch
    // the two boxes' ports now stand on one level. In b14 the pair runs over the top between two
    // faces where each route's arrival needs an outer riser, so whichever way the ports stand, one
    // route's top run passes the other's riser. Each untwists once a riser stands past the run it
    // was blocked by: Resume's beyond Boss defeated's, MES -> PLC's beyond PLC -> MES's.
    //
    // Same terms as a trade, plus no run laid nearer a parallel stroke than SKILL.md §6 rule 3's 12px,
    // across or along, that was not already (`nearRuns`), and the pair must cross less. `besideCount`
    // alone was the first cut and let b11's Resume take x 496, 4px past Boss defeated's riser at 492:
    // the two risers met end to end at y 276, and the export read as one vertical line with Resume
    // branching off it -- a join, which is worse than the twist it removed.
    //
    // Only for a two-way pair, the one this pass promises never crosses: offered to every knot, it
    // would move lanes in drawings no reader flagged, and the goldens record them.
    //
    // Rejected: re-spacing the faces back below the plates' height where a trade needs it. That is
    // 14a73f8 taken back on exactly the faces that carry the most labels.
    function slideApart(P, Q, offers, mutual, before) {
      var others = live.filter(function (o) { return o !== P && o !== Q; });
      function near(pair) {
        return nearRuns(pair[0], others.concat([{ points: pair[1] }])) + nearRuns(pair[1], others);
      }
      var extent = { x: { lo: Infinity, hi: -Infinity }, y: { lo: Infinity, hi: -Infinity } };
      ctx.boxes.forEach(function (b) {
        extent.x.lo = Math.min(extent.x.lo, b.x); extent.x.hi = Math.max(extent.x.hi, b.x + b.width);
        extent.y.lo = Math.min(extent.y.lo, b.y); extent.y.hi = Math.max(extent.y.hi, b.y + b.height);
      });
      live.forEach(function (r) {
        r.points.forEach(function (q) {
          extent.x.lo = Math.min(extent.x.lo, q.x); extent.x.hi = Math.max(extent.x.hi, q.x);
          extent.y.lo = Math.min(extent.y.lo, q.y); extent.y.hi = Math.max(extent.y.hi, q.y);
        });
      });
      var bases = [[]].concat(offers).map(function (o) {
        return o.length ? exchanged(P, Q, o) : [P.points, Q.points];
      }).filter(Boolean);
      var untwisted = slideOne(bases, near([P.points, Q.points]), function (next) {
        return crossingsBetween(next[0], next[1]) < mutual;
      });
      if (!untwisted) return null;
      // Then once more, only to part the pair: in b14 the router had laid the two top runs 4px apart
      // over 928px, and the crossing `roomForBridges` lifted one of them clear for is the one just
      // removed -- the pair untwisted read as one doubled line, both plates pushed off it. Parted by
      // 12px it still had no seat: a 24px plate centred on either run covered the other, and both
      // floated off. So a labelled pair's runs are parted by the seat `seatPitch` gives a face's
      // labelled ends, the plate's extent across the run plus LABEL_GAP.
      var crossed = crossingsBetween(untwisted.next[0], untwisted.next[1]);
      var cramp = crampOf(untwisted.next);
      var parted = cramp > 0 && slideOne([untwisted.next], untwisted.near, function (next) {
        return crossingsBetween(next[0], next[1]) <= crossed && crampOf(next) < cramp;
      });
      return (parted || untwisted).next;
      // Parallel runs of the pair, overlapping along their axis, closer across it than a seat.
      function crampOf(pair) {
        var n = 0;
        for (var i = 0; i + 1 < pair[0].length; i += 1) {
          var a = pair[0][i], b = pair[0][i + 1];
          var h = a.y === b.y;
          var need = Math.max(PASS_CLEAR_PX, seatOf(P.edge, h), seatOf(Q.edge, h));
          for (var j = 0; j + 1 < pair[1].length; j += 1) {
            var c = pair[1][j], d = pair[1][j + 1];
            if (h !== (c.y === d.y)) continue;
            var gap = h ? Math.abs(a.y - c.y) : Math.abs(a.x - c.x);
            var lo = h ? Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) : Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y));
            var hi = h ? Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) : Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y));
            if (gap < need && hi > lo) n += 1;
          }
        }
        return n;
      }
      // What a plate on a run of this edge needs across it, where it is shorter across than along.
      function seatOf(edge, horizontal) {
        if (!(edge.labelWidth > 0) || !(edge.labelHeight > 0)) return 0;
        var across = horizontal ? edge.labelHeight : edge.labelWidth;
        var along = horizontal ? edge.labelWidth : edge.labelHeight;
        return across < along ? across + LABEL_GAP_PX : 0;
      }
      // Every one-run slide of either route in `bases`, a lane at a time between the runs either side
      // of it (which `shiftRun` would refuse to pass anyway), that `wanted` accepts, lays no more
      // than `allowed` runs near a parallel stroke, and is kept on a trade's terms: the fewest such
      // runs, then the shortest slide.
      function slideOne(bases, allowed, wanted) {
        var best = null;
        for (var f = 0; f < bases.length; f += 1) {
          for (var side = 0; side < 2; side += 1) {
            var pts = bases[f][side];
            var edge = side === 0 ? P.edge : Q.edge;
            for (var k = 1; k + 2 < pts.length; k += 1) {
              var axis = pts[k].y === pts[k + 1].y ? "y" : "x";
              var at = pts[k][axis];
              var lo = Math.min(pts[k - 1][axis], pts[k + 2][axis]);
              var hi = Math.max(pts[k - 1][axis], pts[k + 2][axis]);
              // A run outside both its neighbours -- the top of a U -- can only move further out: as
              // far as the drawing already reaches, or as far as `roomForBridges` slides a run, a rank
              // gap's worth. b14's pair is the outermost thing in its drawing, and at 14a73f8 that
              // pass lifted MES -> PLC's top from y 56 to 32, 20px past that edge, to bump the twist.
              var from = lo + 2 * GRID, to = hi - 2 * GRID;
              if (at < lo) { from = Math.min(extent[axis].lo, at - SLIDE_STEPS * GRID); to = lo - 2 * GRID; }
              else if (at > hi) { from = hi + 2 * GRID; to = Math.max(extent[axis].hi, at + SLIDE_STEPS * GRID); }
              for (var v = from; v <= to; v += 2 * GRID) {
                if (v === at) continue;
                var moved = shiftRun(pts, k, v, edge);
                if (!moved) continue;
                var next = side === 0 ? [moved, bases[f][1]] : [bases[f][0], moved];
                if (!wanted(next)) continue;
                var cost = Math.abs(v - at);
                var close = near(next);
                if (close > allowed) continue;
                if (best && (best.near < close || (best.near === close && best.cost <= cost))) continue;
                if (!keeps(next, P, Q, before)) continue;
                best = { next: next, cost: cost, near: close };
              }
            }
          }
        }
        return best;
      }
    }
  }

  // The order of the lanes into one face.
  //
  // Ports are ordered by where each end lands (`assignPorts`), so the ends on a face stand in the
  // order their routes arrive from. The LANES those routes take in the gap before the face were
  // never ordered: each route takes the cross-line `connect` finds first for it alone, so two
  // routes that come in from the same side can turn onto the face in the wrong order and cross
  // twice inside the corridor -- once where the outer one's run passes the inner one's last leg,
  // once where its own last leg passes the inner one's run. Nested, they cross nowhere. The
  // held-out review named it: h20's Closed, where Finance approval's and Notify customer's routes
  // into the bottom face took two hops.
  //
  // So for every face, the routes arriving from one side are given the lanes they already hold,
  // reassigned in the order their ports stand: the route whose port it reaches first, travelling
  // along the face, takes the lane nearest the face, the next the next, and so on outward. The
  // same for the routes leaving a face, mirrored. It moves no port and adds no bend -- `shiftRun`
  // slides each run along its normal and refuses anything that turns a leg round -- and a new
  // order is kept only when it leaves strictly fewer crossings in the drawing and every moved
  // route passes the checks `uncrossPairs` asks of a swap.
  //
  // `uncrossPairs` already swaps the runs of two routes that cross twice, and it is not enough here:
  // swapping Finance's and Notify's runs in h20 takes their two crossings away and puts two back,
  // Finance's leg past the Suggest KB route's run and onto its last leg, so the swap is refused
  // (2 before, 2 after). The three have to take each other's lanes at once, and the face's order
  // says which way round. Its leftovers: where two of a face's routes hold one lane between them,
  // end to end, the lanes they hold are too few to nest them, and the order is not attempted --
  // a labelled variant of braid.spec.js's three-arm fan keeps 2 hops so, in all four directions.
  function orderCorridors(routed, ctx, free) {
    var freedParts = 0;
    var live = [];
    for (var i = 0; i < routed.length; i += 1) {
      if (routed[i] && !routed[i].edge.selfLoop && !routed[i].transit) live.push(routed[i]);
    }
    var groups = new Map();
    function enter(r, arriving) {
      var pts = r.points;
      var n = pts.length;
      if (n < 4) return;
      // The leg on the port, the run across the face before it, and the leg before that.
      var port = arriving ? pts[n - 1] : pts[0];
      var near = arriving ? pts[n - 2] : pts[1];
      var turn = arriving ? pts[n - 3] : pts[2];
      var faceAlongX = near.y !== port.y || near.x === port.x;
      if (faceAlongX ? turn.y !== near.y : turn.x !== near.x) return;
      var axis = faceAlongX ? "x" : "y";
      var normal = faceAlongX ? "y" : "x";
      var travel = arriving ? sign(near[axis] - turn[axis]) : sign(turn[axis] - near[axis]);
      if (travel === 0) return;
      var key = (arriving ? "in|" + r.edge.to : "out|" + r.edge.from) + "|" + axis + "|" + sign(port[normal] - near[normal]) + "|" + travel;
      var g = groups.get(key);
      if (!g) groups.set(key, (g = []));
      g.push({
        r: r, k: arriving ? n - 3 : 1, at: port[axis], level: near[normal], face: port[normal], travel: travel, arriving: arriving,
        lo: Math.min(turn[axis], port[axis]), hi: Math.max(turn[axis], port[axis])
      });
    }
    for (i = 0; i < live.length; i += 1) { enter(live[i], true); enter(live[i], false); }
    function crossingsOfAll() {
      var n = 0;
      for (var a = 0; a < live.length; a += 1) {
        for (var b = a + 1; b < live.length; b += 1) n += crossingsBetween(live[a].points, live[b].points);
      }
      return n;
    }
    // Only routes whose runs share some of the face's length can be in each other's way, so a face's
    // routes are reordered in runs of overlapping spans: in h20 a short jog onto Closed from
    // Account manager, clear of the three routes the knot is made of, would otherwise be handed
    // a lane 40px further from the face, and four routes on three lanes were refused as a group.
    var parts = [];
    groups.forEach(function (g) {
      g.sort(function (p, q) { return (p.lo - q.lo) || (p.hi - q.hi); });
      var part = [];
      var reach = -Infinity;
      for (var e = 0; e < g.length; e += 1) {
        if (part.length && g[e].lo >= reach) { parts.push(part); part = []; }
        part.push(g[e]);
        reach = part.length === 1 ? g[e].hi : Math.max(reach, g[e].hi);
      }
      if (part.length) parts.push(part);
    });
    parts.forEach(function (g) {
      if (g.length < 2) return;
      // Nearest the face first: arriving, the port the route reaches first along its travel;
      // leaving, the port the others' runs would have to pass.
      var order = g.slice().sort(function (p, q) {
        var pk = p.arriving ? p.travel * p.at : -p.travel * p.at;
        var qk = q.arriving ? q.travel * q.at : -q.travel * q.at;
        return (pk - qk) || (p.r.edge.index - q.r.edge.index);
      });
      var levels = g.map(function (e) { return e.level; }).sort(function (a, b) {
        return Math.abs(a - g[0].face) - Math.abs(b - g[0].face);
      });
      var moved = [];
      for (var m = 0; m < order.length; m += 1) {
        var e = order[m];
        if (e.level === levels[m]) continue;
        var next = shiftRun(e.r.points, e.k, levels[m], e.r.edge);
        if (!next) return;
        moved.push({ e: e, points: next, was: e.r.points, rank: m });
      }
      if (moved.length === 0) return;
      var before = crossingsOfAll();
      for (m = 0; m < moved.length; m += 1) moved[m].e.r.points = moved[m].points;
      var face = g[0].face;
      function out(v) { return Math.abs(v - face); }
      // The lane a route was handed is refused, and the lanes the part holds are not the only ones
      // in the gap. In b09 STAT200 -> CS450 was handed the lane CS350 -> CS450 held, and on it the
      // climb to CS450 ran along CS360 -> CS460's climb to CS460, a route of another face that holds
      // the same line further down the corridor; in h12q rowner -> pread, nested onto projects:read,
      // ran along rowner -> pdeploy the same way. Those were the only two refusals of this kind over
      // SWEEP and the three review sets, and each left its face's routes crossing where nested they
      // need not. So the route is offered the free lanes beside it, a grid step at a time and
      // nearest first, as far as `roomForBridges` slides a run -- but only between its neighbours
      // in the order, so the nest still holds -- and of those that pass every check the handed lane
      // failed it keeps the one laid beside fewest other strokes, never more than where it was.
      // b09 then draws 10 crossings where it drew 13, and h12q 3 where it drew 5; no other drawing
      // in those sets moves.
      // Rejected: keeping the handed lane and ignoring the shared run. That draws STAT200's climb
      // on CS360 -> CS460's line, and b09 still ends with 14 crossings, not fewer. Rejected too:
      // the first free lane that passes. For STAT200 that is 4px from CS360 -> CS460's climb, the
      // part then lays more beside other strokes than it did and is refused, and b09 stays at 13;
      // over the 163 random DAGs counted below it leaves 4 with fewer crossings where this leaves 55.
      function freeLane(mv, leave) {
        var lane = levels[mv.rank];
        var away = sign(lane - face) || 1;
        var inner = mv.rank > 0 ? out(levelOf(order[mv.rank - 1])) : 0;
        var outer = mv.rank + 1 < order.length ? out(levels[mv.rank + 1]) : Infinity;
        var rest = others(mv.e.r);
        var best = null;
        var least = besideCount(mv.was, rest);
        for (var d = 1; d <= 2 * SLIDE_STEPS; d += 1) {
          var v = lane + away * (d % 2 ? 1 : -1) * Math.ceil(d / 2) * GRID;
          if (out(v) <= inner || out(v) >= outer) continue;
          var alt = shiftRun(mv.was, mv.e.k, v, mv.e.r.edge);
          if (!alt) continue;
          var beside = besideCount(alt, rest);
          if (best && beside >= least) continue;
          if (beside > least) continue;
          mv.e.r.points = alt;
          if (fits(mv.e.r, mv.was, leave)) { best = alt; least = beside; }
        }
        mv.e.r.points = best || mv.points;
        if (best) mv.points = best;
        return best !== null;
      }
      var ok = true;
      var freed = false;
      for (m = 0; ok && m < moved.length; m += 1) {
        if (fits(moved[m].e.r, moved[m].was, false)) continue;
        freed = true;
        ok = free && freeLane(moved[m], true);
      }
      // A part that needed a free lane is a nest the pass used to refuse, and it is held to one
      // check more, over every route it moves: the leg a route leaves its node by keeps the run an
      // 8px fillet needs on both sides, where it had that run. A lane the part held can lie that
      // close to another route's source face -- it was some other route's lane -- and `shiftRun`
      // only keeps the stub's floor. In `nesting past a third route`, once B --> E had its free lane,
      // D --> E took the lane B --> E gave up 12px off D and turned on a 4px fillet in every
      // direction, the shape arrival.spec.js measures on every source; with this it takes a free
      // lane 16px off D.
      // Rejected: the same check on every part. It also refuses nests the pass has always made --
      // r-cand and h20 move, neither with a crossing fewer -- which is a change to drawings nobody
      // reported, and not this one's to make.
      for (m = 0; ok && freed && m < moved.length; m += 1) {
        if (!fits(moved[m].e.r, moved[m].was, true)) ok = freeLane(moved[m], true);
      }
      if (ok && freed) ok = besideOfAll(moved, true) <= besideOfAll(moved, false);
      if (ok) ok = crossingsOfAll() < before;
      if (!ok) for (m = 0; m < moved.length; m += 1) moved[m].e.r.points = moved[m].was;
      else if (freed) freedParts += 1;
    });
    return freedParts;
    function others(r) {
      return live.filter(function (o) { return o !== r; });
    }
    // Stretches of the drawing laid beside another stroke (`besideCount`), with the part's moves
    // applied or with each moved route back where it was.
    function besideOfAll(moved, applied) {
      var m;
      if (!applied) for (m = 0; m < moved.length; m += 1) moved[m].e.r.points = moved[m].was;
      var n = 0;
      for (var a = 0; a < live.length; a += 1) n += besideCount(live[a].points, live.slice(a + 1));
      if (!applied) for (m = 0; m < moved.length; m += 1) moved[m].e.r.points = moved[m].points;
      return n;
    }
    function levelOf(e) {
      var p = e.r.points;
      return p[e.k].y === p[e.k + 1].y ? p[e.k].y : p[e.k].x;
    }
    // What `uncrossPairs` asks of a swap, of one moved route, and with `leave` the leg it leaves
    // its node by kept at 16px where it was at least that.
    function fits(r, was, leave) {
      if (leave) {
        var now = Math.abs(r.points[1].x - r.points[0].x) + Math.abs(r.points[1].y - r.points[0].y);
        var then = Math.abs(was[1].x - was[0].x) + Math.abs(was[1].y - was[0].y);
        if (now < Math.min(then, 2 * STUB_PX)) return false;
      }
      if (!stubsAndBodyClear(r.points, ctx, r.edge)) return false;
      if (foreignPassages(r.points, ctx, r.edge) > foreignPassages(was, ctx, r.edge)) return false;
      var drawn = [];
      for (var o = 0; o < live.length; o += 1) {
        if (live[o] === r) continue;
        for (var s = 0; s + 1 < live[o].points.length; s += 1) drawn.push([live[o].points[s], live[o].points[s + 1]]);
      }
      var saved = ctx.drawn;
      ctx.drawn = drawn;
      // The legs between the two stubs: a port that has sunk into a rounded outline starts inside
      // its own box's rectangle, which `stubsAndBodyClear` above already excuses and this would not.
      var clear = routeIsClear(r.points.slice(1, r.points.length - 1), ctx, 2, r.edge);
      ctx.drawn = saved;
      return clear;
    }
  }

  // A crossing drawn where neither connector can carry a bump.
  //
  // `bridgeCrossings` bridges a crossing only on a straight stretch with a bump's width and a grid
  // step of air each side, and that is right: a bump run into a corner arc reads as a wobble. But
  // the crossings it then leaves plain are not rare accidents at the edge of that rule -- they are
  // the ones the router put next to an elbow, and the review read them as joins. In 07 the
  // `changes requested` connector turns down at x=576 and `rollback` crosses it 8px below the turn,
  // 4px from the end of its own straight; in 08 `App Server 1 --> NAT` turns right exactly where
  // `LB --> App Server 2` passes, 4px above that one's next corner. Both crossings are forced -- the
  // two connectors enter a channel in one order and leave it in the other -- so no lane order
  // removes them; what can change is WHERE they happen. Over SWEEP and the 16 review sources, 17
  // crossings were drawn with no bump: 9 at a corner, 8 on stretches shorter than a bump needs.
  //
  // So before labels are placed, a crossing that no bump could sit on offers each of its two runs a
  // slide along its own normal, nearest first, a grid step at a time and at most a rank gap's worth.
  // The slide is the same move `uncrossPairs` makes -- `shiftRun`, so no bend is added and no stub
  // drops below its floor; a port moves only along a flat face, below -- and is kept only when the
  // moved route has strictly fewer crossings that cannot be bridged, no more crossings in all, no
  // stretch laid along or beside another stroke that it did not have, the same daylight from every
  // box, and no new foreign zone. Labels come after, so a label lands on the run where it now is
  // rather than being left beside where it was. Over the same sources this leaves 8 plain: four
  // copies of `crossing` (TD, LR, BT, RL), where 52px between the two ranks' ports leaves the
  // crossed run 4px of straight between two elbows whichever way it slides; three of `nested
  // subgraphs`, where Z's two ports stand in the inverted order and the crossing sits inside
  // `Y --> Z`'s arrival leg -- removed only by swapping them, which is port order, not a slide, and
  // which `headingOf` now does (X stands across Z's line to Y, so the end to X heads round it);
  // and one in the dense review source, two elbows 4px apart.
  //
  // Relaxing the bump's own guard was the alternative, and the evidence is against it: the 07
  // crossing has 4px of straight on its horizontal and none on its vertical, so a bump there would
  // have to start inside an arc -- the wobble the guard exists to refuse. Marking these crossings
  // some other way (a gap in the lower stroke) would draw two conventions for one event, which is
  // the complaint itself.
  var SLIDE_STEPS = 8;

  // A crossing hard against a box. The fifth visual review read two in 11 as "face-pressed hop
  // clusters": under L, A -> M ran 16px below L's face across L's two leaving stubs, one bump on
  // A -> M and the other on L -> M's stub, both crests 8px from the face; under D, C -> E did the
  // same 12px below D, crests 4px off. Every one of them was bridged -- `placeHop` asks a grid step
  // of air -- so `roomForBridges` never looked at them. The cure is the one it already applies to a
  // crossing on an elbow: move the CROSSING, not the bump. A crossing is `pressed` when no bump
  // fits with three grid steps of air from every box, a bump's radius and one step more, so the
  // crest stands further from the face than the bump is tall. Squeezing the bump instead was
  // tried by an earlier pass and either stranded it or moved L's port 4px without changing the
  // picture, because the run it sits on IS the lane nearest the face.
  //
  // One run alone cannot do it at either face -- the crossed stub is a port's first leg, which
  // only a port slide moves -- so a pressed crossing is offered a slide of ONE run of each of its
  // two connectors together, cheapest first, kept on the same terms as a single slide plus: no more
  // crossings drawn plain, strictly fewer pressed, and neither connector gaining a tight leg, a
  // stroke beside it or a foreign zone. Under L it slides L -> N's port 4px left and A -> M 4px
  // down, and both bumps then ride A -> M, 16px apart and 12px clear of L. Under D nothing
  // qualifies: D -> G must keep a 24px arrival into G, so its elbow can sink no lower than 208,
  // D -> H's elbow has to stay a lane above that, and with C -> E low enough to clear D the
  // crossing sits on D -> H's corner arc and is drawn with no bump at all. Only a deeper gap holds
  // it, and that is the layout, not this pass. K's one pressed hop, on K -> N's stub where I -> M
  // passes 12px below K, is offered the same and no pair qualifies either.
  var FACE_AIR = 3 * GRID;

  function bumpRoom(points, k, at, ctx, clear, air) {
    var run = bumpRun(points, k, straightRuns(points));
    var horizontal = points[k].y === points[k + 1].y;
    var centre = horizontal ? at.x : at.y;
    if (centre - clear < run.lo || centre + clear > run.hi) return false;
    var g = air || GRID;
    var near = horizontal
      ? { x: at.x - HOP_R - g, y: at.y - HOP_R - g, width: 2 * HOP_R + 2 * g, height: HOP_R + 2 * g }
      : { x: at.x - HOP_R - g, y: at.y - HOP_R - g, width: HOP_R + 2 * g, height: 2 * HOP_R + 2 * g };
    for (var i = 0; i < ctx.boxes.length; i += 1) {
      if (rectsOverlap(near, ctx.boxes[i])) return false;
    }
    return true;
  }

  // The run a bump jumps over has to be straight where the bump stands, a bump's height each side:
  // `bridgeCrossings` asks only that the crossing be inside it, and a bump beside the other
  // connector's elbow has that elbow's arc running into its crest.
  function straightThrough(points, k, at, clear) {
    var run = straightRuns(points)[k];
    var centre = points[k].y === points[k + 1].y ? at.x : at.y;
    return centre - clear >= run.lo && centre + clear <= run.hi;
  }

  function crossingTally(points, others, ctx) {
    // `stranded`: no bump fits at all; `cramped`: none fits with ROOMY_CLEAR, a superset.
    // `pressed`: one fits, but none with FACE_AIR from every box; `plain`: what
    // `bridgeCrossings` will draw with no bump, which is not `stranded` -- that pass asks no
    // straight run of the crossed connector, and refuses a crossing on a corner arc outright.
    var tally = { all: 0, stranded: 0, cramped: 0, pressed: 0, plain: 0 };
    var ownRuns = straightRuns(points);
    for (var o = 0; o < others.length; o += 1) {
      var q = others[o].points;
      for (var i = 0; i + 1 < points.length; i += 1) {
        for (var j = 0; j + 1 < q.length; j += 1) {
          if (!crossesAt(points[i], points[i + 1], q[j], q[j + 1])) continue;
          tally.all += 1;
          var at = points[i].y === points[i + 1].y
            ? { x: q[j].x, y: points[i].y } : { x: points[i].x, y: q[j].y };
          var overQ = bumpRoom(points, i, at, ctx, HOP_CLEAR) && straightThrough(q, j, at, HOP_R);
          var overP = bumpRoom(q, j, at, ctx, HOP_CLEAR) && straightThrough(points, i, at, HOP_R);
          if (!overQ && !overP) tally.stranded += 1;
          var roomyQ = bumpRoom(points, i, at, ctx, ROOMY_CLEAR) && straightThrough(q, j, at, HOP_R + GRID);
          var roomyP = bumpRoom(q, j, at, ctx, ROOMY_CLEAR) && straightThrough(points, i, at, HOP_R + GRID);
          if (!roomyQ && !roomyP) tally.cramped += 1;
          var airQ = bumpRoom(points, i, at, ctx, HOP_CLEAR, FACE_AIR) && straightThrough(q, j, at, HOP_R);
          var airP = bumpRoom(q, j, at, ctx, HOP_CLEAR, FACE_AIR) && straightThrough(points, i, at, HOP_R);
          if ((overQ || overP) && !airQ && !airP) tally.pressed += 1;
          var hz = points[i].y === points[i + 1].y;
          var qRun = straightRuns(q)[j];
          var inOwn = (hz ? at.x : at.y) > ownRuns[i].lo && (hz ? at.x : at.y) < ownRuns[i].hi;
          var inQ = (hz ? at.y : at.x) > qRun.lo && (hz ? at.y : at.x) < qRun.hi;
          if (!inOwn || !inQ || (!bumpRoom(points, i, at, ctx, HOP_CLEAR) && !bumpRoom(q, j, at, ctx, HOP_CLEAR))) tally.plain += 1;
        }
      }
    }
    return tally;
  }

  // Parallel stretches of two different connectors closer than two grid steps: a pair that close
  // reads as one doubled line. `runsAlong` refuses the same line; this refuses the next lane over.
  function besideCount(points, others) {
    var n = 0;
    for (var o = 0; o < others.length; o += 1) {
      var q = others[o].points;
      for (var i = 0; i + 1 < points.length; i += 1) {
        var a = points[i], b = points[i + 1];
        var aH = a.y === b.y;
        for (var j = 0; j + 1 < q.length; j += 1) {
          var c = q[j], d = q[j + 1];
          if (aH !== (c.y === d.y)) continue;
          var gap = aH ? Math.abs(a.y - c.y) : Math.abs(a.x - c.x);
          if (gap === 0 || gap >= 2 * GRID) continue;
          var lo = aH ? Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) : Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y));
          var hi = aH ? Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) : Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y));
          if (hi > lo) n += 1;
        }
      }
    }
    return n;
  }

  // Parallel runs of two connectors within PASS_CLEAR_PX of each other across their axis whose spans
  // overlap or end within PASS_CLEAR_PX of each other along it -- `besideCount`'s doubled line, plus
  // two runs that meet end to end, which read as one line that branches.
  function nearRuns(points, others) {
    var n = 0;
    for (var o = 0; o < others.length; o += 1) {
      var q = others[o].points;
      for (var i = 0; i + 1 < points.length; i += 1) {
        var a = points[i], b = points[i + 1];
        var aH = a.y === b.y;
        for (var j = 0; j + 1 < q.length; j += 1) {
          var c = q[j], d = q[j + 1];
          if (aH !== (c.y === d.y)) continue;
          var gap = aH ? Math.abs(a.y - c.y) : Math.abs(a.x - c.x);
          if (gap >= PASS_CLEAR_PX) continue;
          var lo = aH ? Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) : Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y));
          var hi = aH ? Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) : Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y));
          if (hi - lo > -PASS_CLEAR_PX) n += 1;
        }
      }
    }
    return n;
  }

  function roomForBridges(routed, ctx) {
    var live = [];
    for (var i = 0; i < routed.length; i += 1) {
      if (routed[i] && !routed[i].edge.selfLoop) live.push(routed[i]);
    }
    function othersOf(r) {
      return live.filter(function (o) { return o !== r; });
    }
    function tightLegs(points, edge, others) {
      var drawn = [];
      for (var o = 0; o < others.length; o += 1) {
        for (var s = 0; s + 1 < others[o].points.length; s += 1) drawn.push([others[o].points[s], others[o].points[s + 1]]);
      }
      var saved = ctx.drawn;
      ctx.drawn = drawn;
      var n = 0;
      for (var t = 0; t + 1 < points.length; t += 1) {
        if (!legIsClear(points[t], points[t + 1], ctx, 3, edge)) n += 1;
      }
      var blocked = !routeIsClear(points, ctx, 2, edge);
      ctx.drawn = saved;
      return blocked ? Infinity : n;
    }
    // Every slide of one interior run, and of two neighbouring runs together, cheapest first. A pair
    // is needed where the crossing sits between two elbows of the same connector: in 07 `rollback`
    // turns at x=588 and again at y=116, 12px right of and 8px below `changes requested`'s elbow,
    // so moving either run alone only carries the crossing from one of its corners to the other.
    function slides(r) {
      var points = r.points;
      var out = [];
      var k, d, e;
      var lo = portSlides(r, 0) ? 0 : 1;
      var hi = portSlides(r, points.length - 1) ? points.length - 2 : points.length - 3;
      for (k = lo; k <= hi; k += 1) {
        for (d = 1; d <= SLIDE_STEPS; d += 1) {
          out.push({ cost: d, moves: [[k, -d]] }, { cost: d, moves: [[k, d]] });
        }
      }
      for (k = lo; k + 1 <= hi; k += 1) {
        for (d = -SLIDE_STEPS; d <= SLIDE_STEPS; d += 1) {
          for (e = -SLIDE_STEPS; e <= SLIDE_STEPS; e += 1) {
            if (d === 0 || e === 0) continue;
            out.push({ cost: Math.abs(d) + Math.abs(e), moves: [[k, d], [k + 1, e]] });
          }
        }
      }
      // Stable, so equal costs keep the order above: singles before pairs, earlier runs first.
      return out.sort(function (a, b) { return a.cost - b.cost; });
    }
    // A run that ends on a port moves the port with it, which is allowed only along a flat face:
    // the ends of 08's crossing are four ports on four different boxes, App Server 1's top and the
    // Load Balancer's bottom 8px apart and App Server 2's top and NAT's bottom 4px apart, so the
    // crossing sits on an elbow at whichever pair it is moved to, and no interior run reaches it.
    // Only on a rectangle -- an outline elsewhere would need the port re-sunk to it -- and only
    // where the face keeps the same corner clearance and port pitch the layout gave it.
    function portSlides(r, end) {
      var box = ctx.boxById.get(end === 0 ? r.edge.from : r.edge.to);
      var inset = end === 0 ? r.edge.start.inset : r.edge.end.inset;
      return !!box && box.geometry === "rect" && inset === 0;
    }
    function portsHold(r, moved, others) {
      var ends = [0, moved.length - 1];
      for (var e = 0; e < 2; e += 1) {
        var at = moved[ends[e]], was = r.points[ends[e]];
        if (at.x === was.x && at.y === was.y) continue;
        var box = ctx.boxById.get(e === 0 ? r.edge.from : r.edge.to);
        var alongX = at.y === was.y;
        var lo = alongX ? box.x : box.y;
        var hi = lo + (alongX ? box.width : box.height);
        var c = alongX ? at.x : at.y;
        if (c < lo + 2 * GRID || c > hi - 2 * GRID) return false;
        for (var o = 0; o < others.length; o += 1) {
          var q = others[o].points;
          var tips = [q[0], q[q.length - 1]];
          for (var t = 0; t < 2; t += 1) {
            var onFace = alongX ? tips[t].y === at.y : tips[t].x === at.x;
            if (onFace && Math.abs((alongX ? tips[t].x : tips[t].y) - c) < (e === 0 ? r.edge.start.pitch : r.edge.end.pitch)) return false;
          }
        }
      }
      return true;
    }
    function trySlide(r, others, before) {
      var tight = tightLegs(r.points, r.edge, others);
      var beside = besideCount(r.points, others);
      var passes = foreignPassages(r.points, ctx, r.edge);
      var options = slides(r);
      for (var phase = 0; phase < 2; phase += 1) {
        for (var o = 0; o < options.length; o += 1) {
          var moved = r.points;
          for (var m = 0; m < options[o].moves.length && moved; m += 1) {
            var k = options[o].moves[m][0];
            var axis = moved[k].y === moved[k + 1].y ? "y" : "x";
            moved = shiftRun(moved, k, r.points[k][axis] + options[o].moves[m][1] * GRID, r.edge);
          }
          if (!moved || !portsHold(r, moved, others)) continue;
          var after = crossingTally(moved, others, ctx);
          if (after.stranded >= before.stranded || after.all > before.all) continue;
          if (phase === 0 && after.cramped >= before.cramped) continue;
          if (!stubsAndBodyClear(moved, ctx, r.edge)) continue;
          if (tightLegs(moved, r.edge, others) > tight) continue;
          if (besideCount(moved, others) > beside) continue;
          if (foreignPassages(moved, ctx, r.edge) > passes) continue;
          r.points = moved;
          return true;
        }
      }
      return false;
    }
    function movable(r) {
      return { lo: portSlides(r, 0) ? 0 : 1, hi: portSlides(r, r.points.length - 1) ? r.points.length - 2 : r.points.length - 3 };
    }
    function sum(a, b) {
      var out = {};
      for (var key in a) out[key] = a[key] + b[key];
      return out;
    }
    function swapIn(list, from, to) {
      return list.map(function (o) { return o === from ? to : o; });
    }
    // See FACE_AIR. One run of P and one of its pressed partner Q, each next to a crossing between
    // them, every pair of non-zero steps up to SLIDE_STEPS, cheapest total first.
    function tryPairSlide(P, othersP) {
      for (var qi = 0; qi < othersP.length; qi += 1) {
        var Q = othersP[qi];
        if (Q.transit || crossingTally(P.points, [Q], ctx).pressed === 0) continue;
        var othersQ = othersOf(Q);
        var before = sum(crossingTally(P.points, othersP, ctx), crossingTally(Q.points, othersQ, ctx));
        var near = function (r, other) {
          var at = [];
          var span = movable(r);
          for (var i = 0; i + 1 < r.points.length; i += 1) {
            for (var j = 0; j + 1 < other.points.length; j += 1) {
              if (!crossesAt(r.points[i], r.points[i + 1], other.points[j], other.points[j + 1])) continue;
              for (var k = i - 1; k <= i + 1; k += 1) if (k >= span.lo && k <= span.hi && at.indexOf(k) < 0) at.push(k);
            }
          }
          return at;
        };
        var pRuns = near(P, Q), qRuns = near(Q, P);
        var options = [];
        for (var a = 0; a < pRuns.length; a += 1) {
          for (var b = 0; b < qRuns.length; b += 1) {
            for (var d = -SLIDE_STEPS; d <= SLIDE_STEPS; d += 1) {
              for (var e = -SLIDE_STEPS; e <= SLIDE_STEPS; e += 1) {
                if (d === 0 || e === 0) continue;
                options.push({ cost: Math.abs(d) + Math.abs(e), p: [pRuns[a], d], q: [qRuns[b], e] });
              }
            }
          }
        }
        options.sort(function (x, y) { return x.cost - y.cost; });
        var sideP = { tight: tightLegs(P.points, P.edge, othersP), beside: besideCount(P.points, othersP), passes: foreignPassages(P.points, ctx, P.edge) };
        var sideQ = { tight: tightLegs(Q.points, Q.edge, othersQ), beside: besideCount(Q.points, othersQ), passes: foreignPassages(Q.points, ctx, Q.edge) };
        for (var o = 0; o < options.length; o += 1) {
          var opt = options[o];
          var axisP = P.points[opt.p[0]].y === P.points[opt.p[0] + 1].y ? "y" : "x";
          var axisQ = Q.points[opt.q[0]].y === Q.points[opt.q[0] + 1].y ? "y" : "x";
          var P2 = shiftRun(P.points, opt.p[0], P.points[opt.p[0]][axisP] + opt.p[1] * GRID, P.edge);
          if (!P2) continue;
          var Q2 = shiftRun(Q.points, opt.q[0], Q.points[opt.q[0]][axisQ] + opt.q[1] * GRID, Q.edge);
          if (!Q2) continue;
          var movedP = { points: P2, edge: P.edge }, movedQ = { points: Q2, edge: Q.edge };
          var othersP2 = swapIn(othersP, Q, movedQ), othersQ2 = swapIn(othersQ, P, movedP);
          if (!portsHold(P, P2, othersP2) || !portsHold(Q, Q2, othersQ2)) continue;
          var after = sum(crossingTally(P2, othersP2, ctx), crossingTally(Q2, othersQ2, ctx));
          if (after.all > before.all || after.stranded > before.stranded || after.plain > before.plain) continue;
          if (after.pressed >= before.pressed || after.cramped > before.cramped) continue;
          if (!stubsAndBodyClear(P2, ctx, P.edge) || !stubsAndBodyClear(Q2, ctx, Q.edge)) continue;
          if (tightLegs(P2, P.edge, othersP2) > sideP.tight || tightLegs(Q2, Q.edge, othersQ2) > sideQ.tight) continue;
          if (besideCount(P2, othersP2) > sideP.beside || besideCount(Q2, othersQ2) > sideQ.beside) continue;
          if (foreignPassages(P2, ctx, P.edge) > sideP.passes || foreignPassages(Q2, ctx, Q.edge) > sideQ.passes) continue;
          P.points = P2;
          Q.points = Q2;
          return true;
        }
      }
      return false;
    }

    // Bounded for the same reason as `uncrossPairs`: each accepted slide strictly lowers a finite
    // count.
    for (var round = 0; round < 4; round += 1) {
      var progressed = false;
      for (var a = 0; a < live.length; a += 1) {
        var P = live[a];
        if (P.transit) continue;
        var others = othersOf(P);
        var before = crossingTally(P.points, others, ctx);
        if (before.stranded > 0 && trySlide(P, others, before)) progressed = true;
        else if (before.pressed > 0 && tryPairSlide(P, others)) progressed = true;
      }
      if (!progressed) break;
    }
  }

  function routeIsClear(points, ctx, strict, edge) {
    for (var i = 0; i + 1 < points.length; i += 1) {
      if (!legIsClear(points[i], points[i + 1], ctx, strict, edge)) return false;
    }
    return true;
  }

  // The cross-line's coordinate is the router's only degree of freedom, so the candidates are drawn
  // from where a clear line can actually be -- one stub outside each obstacle's near and far edge --
  // rather than from a fixed sweep. Scanning every 4px would find the same answers and test two
  // orders of magnitude more of them; taking them off the obstacles means the list is O(nodes) and
  // already contains the gaps the layout left.
  function crossCandidates(axis, p, q, preferred, ctx) {
    var key = (axis === "y") ? "y" : "x";
    var lo = Math.min(p[key], q[key]);
    var hi = Math.max(p[key], q[key]);
    // Inclusive, because a cross-line exactly on one of the two stations is a legal route -- it is
    // the single-bend L both endpoint coordinates are offered for below. Excluding the ends threw
    // the lane away in the one case it is now most needed: the gap reserves ARRIVE at the arrival
    // face, so the lane nearest that face lands exactly on the arrival station, and rejecting it
    // sent those edges to the midpoint instead. It and the reserve-respecting `laneAt` go together
    // and neither works alone: with either one missing, 7 further pairs of connectors came within
    // 12px of each other over the corpus, and with both, none.
    var anchor = (preferred !== null && (ctx.anyAnchor || (preferred >= lo && preferred <= hi))) ? preferred : snap4((lo + hi) / 2);
    var seen = new Map();
    var list = [];
    function add(value) {
      if (value === null || !isFinite(value)) return;
      var c = snap4(value);
      if (seen.has(c)) return;
      seen.set(c, true);
      list.push(c);
    }
    add(anchor);
    add(preferred);
    // The two endpoint coordinates, which turn the three-segment cross into a single-bend L. They
    // are candidates like any other rather than a special case: dd-arch.md's L-path is the cross
    // whose line happens to pass through one of its ends.
    add(p[key]);
    add(q[key]);
    // Both the nodes and the zone borders: a line clear of every box can still be drawn along a
    // subgraph's outline, and the candidate that clears THAT has to be in the list to be found.
    var obstacles = ctx.boxes.concat(ctx.rails || []);
    for (var i = 0; i < obstacles.length; i += 1) {
      var b = obstacles[i];
      // At the clearance, not at a stub: a line offered 8px from one box is 8px from it, and the
      // first pass would only reject it. Both are still offered -- the stub distance is where a
      // route that has given the clearance up wants to be -- but the clear one comes first.
      if (axis === "y") {
        add(b.y - PASS_CLEAR_PX); add(b.y + b.height + PASS_CLEAR_PX);
        add(b.y - STUB_PX); add(b.y + b.height + STUB_PX);
      } else {
        add(b.x - PASS_CLEAR_PX); add(b.x + b.width + PASS_CLEAR_PX);
        add(b.x - STUB_PX); add(b.x + b.width + STUB_PX);
      }
    }
    // On the title pass, the two lines that just clear each title: a lane stepping off a title
    // belongs at its edge, and no box or zone border is there to offer it.
    if (ctx.anyAnchor) {
      for (i = 0; i < ctx.titleRooms.length; i += 1) {
        var t = ctx.titleRooms[i];
        if (axis === "y") { add(t.y); add(t.y + t.height); } else { add(t.x); add(t.x + t.width); }
      }
    }
    list.sort(function (a, b2) {
      var da = Math.abs(a - anchor);
      var db = Math.abs(b2 - anchor);
      if (da !== db) return da - db;
      return a - b2;
    });
    return list.length > MAX_CANDIDATES ? list.slice(0, MAX_CANDIDATES) : list;
  }

  // Joins two points with at most two bends, on a line perpendicular to `axis`. `strict` decides
  // how much the leg has to clear; `null` means nothing did, which only ever happens on the two
  // demanding passes because the relaxed one accepts its first candidate.
  function connect(p, q, axis, preferred, ctx, strict, edge) {
    var candidates = crossCandidates(axis, p, q, preferred, ctx);
    for (var i = 0; i < candidates.length; i += 1) {
      var c = candidates[i];
      var m1 = (axis === "y") ? { x: p.x, y: c } : { x: c, y: p.y };
      var m2 = (axis === "y") ? { x: q.x, y: c } : { x: c, y: q.y };
      var pts = mergeRoute([p, m1, m2, q]);
      if (strict === 0) return pts.slice(1, pts.length - 1);
      if (routeIsClear(pts, ctx, strict, edge)) return pts.slice(1, pts.length - 1);
    }
    return null;
  }

  function joinStations(stations, travel, edge, ctx, strict, plan) {
    var pts = [stations[0]];
    var other = (travel === "y") ? "x" : "y";
    for (var i = 0; i + 1 < stations.length; i += 1) {
      // Only the first leg gets the reserved lane: it is the lane in the gap the edge has to leave
      // its SOURCE by, which is the one place two edges out of one rank would otherwise stack.
      //
      // And the last leg, where it lands on a vertex (`endChannel`). A vertex hands out its ports
      // along its slopes, one step apart (`slopesOf`), so a corridor arriving there comes in beside
      // the vertex's own answers -- and once the answers took the order their corridors run in,
      // `long back edge`'s retry landed on Check's right slope 20px from the "right" answer, turned
      // 36px above Right's face instead of at the lane the layout reserved 56px above it, and left
      // the answer's plate 4px of room: a crowded label and a mask inside rule 2's gap, TD and BT.
      // The layout had already sized that gap for the plate; the router was not using the plan.
      // Rejected: the last leg's lane for every corridor. It moved 42 of the 212 sweep drawings for
      // no change in bends or crossings outside these two, and in the bridge-weight fixture it
      // slid A1 --> B2's jog onto the stretch its bump needed.
      var pref = (i === 0 && edge.channel && edge.channel.axis === travel) ? edge.channel.value : null;
      if (i > 0 && i + 2 === stations.length && edge.endChannel && edge.endChannel.axis === travel) pref = edge.endChannel.value;
      var was = plan && plan.length > i ? plan[i] : null;
      if (was && was.axis === travel) pref = was.value;
      var used = travel;
      var mid = connect(stations[i], stations[i + 1], travel, pref, ctx, strict, edge);
      if (mid === null) {
        used = other;
        mid = connect(stations[i], stations[i + 1], other, was && was.axis === other ? was.value : null, ctx, strict, edge);
      }
      if (mid === null) return null;
      if (plan && !was) plan.push({ axis: used, value: mid.length ? mid[0][used] : null });
      pts = pts.concat(mid);
      pts.push(stations[i + 1]);
    }
    return pts;
  }

  // Four passes, giving up the cheapest rule first. The first demands everything: daylight between
  // the leg and every border it runs beside (rule 3), no shared run with a stroke already drawn
  // (rule 3 again) and nothing behind a box (rule 5). The second drops the daylight, because a line
  // 8px from a border is still two lines while a line sharing a run with another is one. The third
  // drops the stroke rule for the same reason a line vanishing behind a box is worse than two lines
  // side by side. Only when even that has no answer does the edge become rule 5's declared
  // exception -- dashed, with its label at the visible end -- rather than a connector that silently
  // disappears under something it has nothing to do with.
  //
  // Measured over 418 sources and 2694 connectors, including four four-node cycles with a label on
  // every edge: every one of them routed on the FIRST pass. The `warnings` array is how a drawing
  // that does not says so.

  // Rule 5 over the finished route, with one box excused on one leg at each end: the box the port
  // is attached to. A port that has sunk to its shape's outline starts inside the bounding box --
  // only the rectangle and the subroutine never sink -- so the leg carrying it necessarily crosses
  // that rect, through canvas the node does not paint. The exemption is that box on that leg and nothing else, so an edge that
  // genuinely runs back over its own source, or over any other node, still takes the exception.
  // A two-point route is one leg carrying both ports, which is why each end is tested separately
  // rather than by index.
  function stubsAndBodyClear(points, ctx, edge) {
    var last = points.length - 1;
    var from = ctx.boxById.get(edge.from);
    var to = ctx.boxById.get(edge.to);
    for (var i = 0; i + 1 < points.length; i += 1) {
      for (var b = 0; b < ctx.boxes.length; b += 1) {
        var box = ctx.boxes[b];
        if (i === 0 && box === from) continue;
        if (i + 1 === last && box === to) continue;
        if (hitsBox(points[i], points[i + 1], box)) return false;
      }
    }
    return true;
  }

  // Whether the title pass's route only stepped off a title, rather than went another way: it
  // leaves its first station and reaches its last turning the same way along each face as the
  // ordinary route -- the side the layout ordered that face's ports for (`assignPorts`) -- and where
  // the ordinary route crossed a title, it stays inside that title's zone. Either alone was not
  // enough. In `return across subgraphs` the back edge, kept off Backend's title, went round the
  // right of Worker instead of the left and crossed Handler's arrival on Worker's face; and in the
  // crowded two-zone drawing of render.spec.js it left Zone one for a lane 8px outside its wall,
  // 104px from where it was, with its label astride Zone two's.
  function steppedAside(route, plain, travel, ctx) {
    var along = travel === "y" ? "x" : "y";
    if (firstTurn(route, along, 1) !== firstTurn(plain, along, 1)) return false;
    if (firstTurn(route, along, -1) !== firstTurn(plain, along, -1)) return false;
    for (var i = 0; i + 1 < plain.length; i += 1) {
      for (var t = 0; t < ctx.titleRooms.length; t += 1) {
        if (!segmentCrossesRect(plain[i], plain[i + 1], ctx.titleRooms[t])) continue;
        var z = ctx.titleRooms[t].zone;
        var vertical = plain[i].x === plain[i + 1].x;
        for (var j = 0; j + 1 < route.length; j += 1) {
          if ((route[j].x === route[j + 1].x) !== vertical) continue;
          var at = vertical ? route[j].x : route[j].y;
          var lo = vertical ? z.x : z.y;
          var hi = lo + (vertical ? z.width : z.height);
          var inside = at > lo && at < hi;
          var spans = vertical
            ? Math.max(route[j].y, route[j + 1].y) > z.y && Math.min(route[j].y, route[j + 1].y) < z.y + z.height
            : Math.max(route[j].x, route[j + 1].x) > z.x && Math.min(route[j].x, route[j + 1].x) < z.x + z.width;
          if (spans && !inside) return false;
        }
      }
    }
    return true;
  }

  // The sign of the first move along `axis` from the start (dir 1) or the end (dir -1) of a route.
  function firstTurn(points, axis, dir) {
    var n = points.length;
    for (var k = 0; k + 1 < n; k += 1) {
      var a = dir > 0 ? points[k] : points[n - 1 - k];
      var b = dir > 0 ? points[k + 1] : points[n - 2 - k];
      var d = sign(b[axis] - a[axis]);
      if (d !== 0) return d;
    }
    return 0;
  }

  function routeEdge(edge, ctx) {
    var S = { x: edge.start.x, y: edge.start.y };
    var E = { x: edge.end.x, y: edge.end.y };
    var dS = outwardOf(edge.start.side);
    var dE = outwardOf(edge.end.side);
    // Measured from the face rather than from the port, and the inset is what puts it back there.
    // A port on a rhombus or a cylinder has sunk to the shape's outline, which is inside the
    // bounding box; a stub of STUB_PX from the port would leave the route's first corner inside
    // that box, and the router would then be searching for a cross-line from a point behind a node.
    var outS = STUB_PX + edge.start.inset;
    // And the arrival station is a whole ARRIVE_PX out, which is the floor on the final leg rather
    // than a preference: `connect` clamps its cross-line between the two stations, so no route can
    // put its last corner nearer the target face than this. The 12 four-px arrivals in the corpus
    // were all this line reading STUB_PX -- the departure constant, borrowed for the end that has
    // an arrowhead on it.
    var outE = ARRIVE_PX + edge.end.inset;

    if (edge.selfLoop) {
      return {
        points: mergeRoute([
          S,
          { x: S.x + dS.x * (LOOP_PX + edge.start.inset), y: S.y + dS.y * (LOOP_PX + edge.start.inset) },
          { x: E.x + dE.x * (LOOP_PX + edge.end.inset), y: E.y + dE.y * (LOOP_PX + edge.end.inset) },
          E
        ]),
        transit: false,
        crowded: false
      };
    }

    var A = { x: S.x + dS.x * outS, y: S.y + dS.y * outS };
    var B = { x: E.x + dE.x * outE, y: E.y + dE.y * outE };
    ctx.portLines = [
      { x: dS.x === 0 ? A.x : null, y: dS.x === 0 ? null : A.y, at: A, node: edge.from },
      { x: dE.x === 0 ? B.x : null, y: dE.x === 0 ? null : B.y, at: B, node: edge.to }
    ];
    var stations = [A];
    for (var i = 0; i < edge.via.length; i += 1) stations.push({ x: edge.via[i].x, y: edge.via[i].y });
    stations.push(B);
    var travel = (dS.x === 0) ? "y" : "x";

    // A pass above the four that keeps every leg off the zone titles, taken only where it moves a
    // lane and nothing else (`steppedAside`). A lane laid down a zone's side lies under its sibling's
    // title as often as not -- in h14 the route from checkout-api down to Aurora writer ran under
    // "AZ us-east-1b" and the title slid 36px along its band to let it through -- and the router
    // had no reason to prefer the lane 36px over, left of the title, which crosses nothing. It is
    // tried after the ordinary route, from that route's own lanes (`plan`), so the answer is the
    // nearest lane that clears, not wherever the midpoint search happens to land first.
    //
    // Measured and rejected: the titles as part of the third pass's rule, taken by whatever route
    // satisfies it. It clears the same titles, and sends the back edge of `return across subgraphs`
    // TD and of the nine-line two-zone specimen round the other side of its source, across the
    // arrival on that face: 2 stroke crossings in a sweep that has none.
    var plan = [];
    var body = joinStations(stations, travel, edge, ctx, 4, plan);
    ctx.anyAnchor = true;
    var titled = body === null ? null : joinStations(stations, travel, edge, ctx, 5, plan);
    ctx.anyAnchor = false;
    if (titled !== null && steppedAside(titled, body, travel, ctx)) body = titled;
    var crowded = false;
    var transit = false;
    if (body === null) body = joinStations(stations, travel, edge, ctx, 3);
    if (body === null) body = joinStations(stations, travel, edge, ctx, 2);
    if (body === null) { body = joinStations(stations, travel, edge, ctx, 1); crowded = true; }
    if (body === null) { body = joinStations(stations, travel, edge, ctx, 0); crowded = false; transit = true; }

    var points = mergeRoute([S].concat(body).concat([E]));
    // The stubs are not negotiable -- a port is where the layout put it -- so they are checked
    // after the fact rather than searched over. A stub that is blocked is the same fact as a body
    // that is blocked, and takes the same exception.
    if (!transit && !stubsAndBodyClear(points, ctx, edge)) transit = true;
    return { points: points, transit: transit, crowded: crowded };
  }

  // RENDERER-SPEC.md §7.2, in grid units so the arithmetic cannot produce a fraction: at most two
  // units, and at most HALF of either neighbouring run. Half is the exact condition, not a margin:
  // two corners sharing one leg take r each, so r <= leg/2 on both of them is what stops them
  // eating it.
  //
  // It asked for a third until a two-subgraph drawing was rendered and looked at. A third is
  // stricter than the geometry needs and it floors to ZERO at two grid units -- and two grid units
  // is STUB_PX, the run every route leaves its port on, so a corner one stub away from a box came
  // out square while its neighbours in the same drawing were rounded. SKILL.md §6 rule 1 makes the
  // rounded right angle mandatory, which makes that a hard fail rather than a tight corner.
  // Measured over 92 sources before the change: 40 of 368 corners were square, 30 of them on a run
  // of exactly 8px, which this turns into r=4.
  //
  // What half costs: an 8px run between two corners has no straight stretch left between the arcs
  // and reads as a rounded step rather than as two right angles. That is the trade rule 1 settles
  // in one direction -- a square corner is an automatic fail and a tight step is not.
  //
  // A run of ONE grid unit still returns 0, and no on-grid radius exists for it: two arcs need 8px
  // of a 4px run. Those runs are why `alignUnitJog` exists in the layout -- it is cheaper to not
  // produce a 4px sidestep than to try to round one.
  //
  // The cap of two units is the other half of ARRIVE's arithmetic, so the two move together: this
  // takes up to 8px off the front of the final leg and the 8px head takes the back, which is why
  // the leg has to be 24 for 8px of shaft to survive in the middle. Raise the cap and ARRIVE has
  // to follow it.
  function cornerRadius(inLen, outLen) {
    return GRID * Math.min(2, Math.floor((inLen / GRID) / 2), Math.floor((outLen / GRID) / 2));
  }

  // ---------------------------------------------------------------------------
  // Bridges.
  //
  // SKILL.md §6 rule 3 sends two connectors that cross to dd-arch.md's bridge/hop primitive: an
  // 8px semicircular bump on ONE of them at the crossing point, never on both, drawn on the less
  // important of the two. `a 8,8 0 0,1 16,0` is the source's own formula; this writes it absolute,
  // like every other command here.
  //
  // What decides "less important" is what the source actually said about the two edges, in
  // dd-arch.md's own order: a dashed path is bridged under a solid one ("it is by definition the
  // less important connection"), then a normal weight under a thick one, and a tie goes to the
  // edge declared later so that the first one written stays whole. Nothing here reads a label or
  // guesses at meaning.
  //
  // A bump is only drawn where it can be read as one. It needs 16px of straight run on each side of
  // the crossing -- its own 8px, plus the 8px a neighbouring corner's arc may already have taken
  // out of that run -- and it may not land under a node or a label mask, both of which are painted
  // after the strokes and would swallow it. When the less important edge cannot take it, the other
  // one is offered the same test; when neither can, the crossing is left plain, which is what rule
  // 3 gets instead of a bump drawn somewhere it does not belong.
  //
  // Measured over 99 sources: 41 places where two strokes cross, 29 of them bridged, 0 bridged
  // twice. The 12 left plain all cross within a bump's width of an elbow -- this router's crossings
  // cluster there, because that is where a fan's legs converge -- and a bump that ran into a corner
  // arc would read as a wobble rather than as a bridge.
  // ---------------------------------------------------------------------------

  var HOP_R = 8;
  // A bump needs its own 8px each side of the crossing plus one grid step of straight, measured
  // against the run that is actually DRAWN -- from where the previous corner's arc lets go to where
  // the next one takes hold, not from corner to corner. The difference is up to 8px at each end and
  // it decides real crossings: this router's crossings cluster near elbows, and measuring
  // corner-to-corner against a worst-case 8px radius bridged 14 of them where the drawn run
  // bridges 19, over the same 93 sources.
  // The grid step is there because a bump that ends on the pixel an arc begins reads as one
  // continuous wobble rather than as a bridge -- seen on `Y --> Z` in the nested-subgraph source.
  var HOP_CLEAR = HOP_R + GRID;
  // What a slide aims for first: a bump with two grid steps of straight before it and the run it
  // jumps a grid step clear of its elbow either side, rather than the bare minimum. At the bare
  // minimum 07's `changes requested` came out as elbow, 4px of line, bump -- one S-shaped wobble --
  // where 8px later the same rule draws a corner and then, plainly, a bridge.
  var ROOMY_CLEAR = HOP_CLEAR + GRID;

  // Higher is more important. Bridge the lower of the two.
  function hopWeight(edge) {
    return (edge.pattern === "dotted" ? 0 : 2) + (edge.thickness === "thick" ? 1 : 0);
  }

  // The stretch of each segment that is drawn straight: the corner-to-corner run less whatever
  // `pathOf` will round off each end. Computed here from the same `cornerRadius` rather than
  // guessed at, because the two have to agree about where the arcs are.
  function straightRuns(points) {
    var radii = [];
    var runs = [];
    var i;
    for (i = 0; i < points.length; i += 1) {
      if (i === 0 || i + 1 >= points.length) { radii.push(0); continue; }
      radii.push(cornerRadius(
        Math.abs(points[i].x - points[i - 1].x) + Math.abs(points[i].y - points[i - 1].y),
        Math.abs(points[i + 1].x - points[i].x) + Math.abs(points[i + 1].y - points[i].y)
      ));
    }
    for (i = 0; i + 1 < points.length; i += 1) {
      var horizontal = points[i].y === points[i + 1].y;
      var a = horizontal ? points[i].x : points[i].y;
      var b = horizontal ? points[i + 1].x : points[i + 1].y;
      var u = sign(b - a);
      var lo = a + u * radii[i];
      var hi = b - u * radii[i + 1];
      runs.push({ lo: Math.min(lo, hi), hi: Math.max(lo, hi) });
    }
    return runs;
  }

  // The run a bump may use on the leg a route arrives on stops short of the tip by the approach
  // run, less what HOP_CLEAR already keeps: a bump there has to leave the head its 16px of shaft
  // (`ARRIVE`), or the head hangs off the bump the way it hung off an elbow arc. No sweep source
  // put a bump there; `roomForBridges` did, sliding a route under `nested subgraphs LR` at a rank
  // spacing of 64 until `Y --> Z`'s last leg had a bump 4px from its tip.
  function bumpRun(points, k, runs) {
    var run = runs[k];
    if (k + 2 !== points.length) return run;
    var tip = points[k + 1], from = points[k];
    var back = ARRIVE_PX - HOP_CLEAR;
    var forward = (tip.x !== from.x) ? tip.x > from.x : tip.y > from.y;
    return forward ? { lo: run.lo, hi: run.hi - back } : { lo: run.lo + back, hi: run.hi };
  }

  function hopFits(run, centre, existing) {
    if (centre - HOP_CLEAR < run.lo || centre + HOP_CLEAR > run.hi) return false;
    for (var i = 0; i < existing.length; i += 1) {
      if (Math.abs(existing[i].at - centre) < 2 * HOP_R) return false;
    }
    return true;
  }

  // The bump a crossing at x,y would get on `seg`, or null where the run has no room for it.
  // `side` is +1 only for a crossing on a corner's tangent (`crossingsOf`); otherwise -1.
  function hopAt(seg, x, y, existing, side) {
    var flip = side === 1;
    if (seg.horizontal) {
      if (!hopFits(seg.room, x, existing)) return null;
      // The bump goes to -y on a horizontal run and to -x on a vertical one, whichever way the run
      // travels, so a drawing reads its bridges as one gesture. In SVG's y-down frame sweep 1 is
      // the increasing-angle direction, which lifts a left-to-right arc upwards and drops a
      // right-to-left one; the sign of the run is what keeps the bump on the same side of both.
      return {
        at: x, box: { x: x - HOP_R, y: flip ? y : y - HOP_R, width: 2 * HOP_R, height: HOP_R },
        from: { x: x - seg.u * HOP_R, y: y }, to: { x: x + seg.u * HOP_R, y: y },
        sweep: (seg.u > 0) !== flip ? 1 : 0
      };
    }
    if (!hopFits(seg.room, y, existing)) return null;
    return {
      at: y, box: { x: flip ? x : x - HOP_R, y: y - HOP_R, width: HOP_R, height: 2 * HOP_R },
      from: { x: x, y: y - seg.u * HOP_R }, to: { x: x, y: y + seg.u * HOP_R },
      sweep: (seg.u > 0) !== flip ? 0 : 1
    };
  }

  // A grid step of air around the bump, not just no overlap. A crest that stops on a node's
  // border is read as part of the border; the nodes are painted after the strokes, so it would be
  // a bump with its top shaved off.
  function hopAir(hop) {
    return {
      x: hop.box.x - GRID, y: hop.box.y - GRID,
      width: hop.box.width + 2 * GRID, height: hop.box.height + 2 * GRID
    };
  }

  function clearOfBoxes(rect, ctx) {
    for (var i = 0; i < ctx.boxes.length; i += 1) {
      if (rectsOverlap(rect, ctx.boxes[i])) return false;
    }
    return true;
  }

  function placeHop(seg, x, y, ctx, side) {
    var existing = seg.owner.hops[seg.index] || [];
    var hop = hopAt(seg, x, y, existing, side);
    if (!hop) return false;
    var near = hopAir(hop);
    if (!clearOfBoxes(near, ctx)) return false;
    for (var i = 0; i < ctx.labelRects.length; i += 1) {
      if (rectsOverlap(near, ctx.labelRects[i])) return false;
    }
    existing.push(hop);
    existing.sort(function (a, b) { return a.at - b.at; });
    seg.owner.hops[seg.index] = existing;
    return true;
  }

  // Every place two connectors cross on their drawn straight runs, each with the two runs.
  function crossingsOf(routed) {
    var segs = [];
    var i;
    for (i = 0; i < routed.length; i += 1) {
      var r = routed[i];
      if (!r) continue;
      var runs = straightRuns(r.points);
      for (var s = 0; s + 1 < r.points.length; s += 1) {
        var p = r.points[s], q = r.points[s + 1];
        // The STRAIGHT stretch, not the corner-to-corner segment. Two routes whose segments meet
        // inside one of them's corner arc do not cross as drawn -- one of them has already turned
        // away -- and a bump there bridges nothing. Found by a test that read the crossings off the
        // emitted `d` while the pass was still reading them off the route's corners.
        var horizontal = p.y === q.y;
        var u = sign(horizontal ? q.x - p.x : q.y - p.y);
        if (runs[s].hi - runs[s].lo <= 0) continue;
        segs.push({
          owner: r, order: i, index: s, horizontal: horizontal, u: u, run: runs[s], room: bumpRun(r.points, s, runs),
          fixed: horizontal ? p.y : p.x
        });
      }
    }
    var found = [];
    for (var a = 0; a < segs.length; a += 1) {
      for (var b = a + 1; b < segs.length; b += 1) {
        var A = segs[a], B = segs[b];
        if (A.owner === B.owner) continue;
        if (A.horizontal === B.horizontal) continue;
        var H = A.horizontal ? A : B;
        var V = A.horizontal ? B : A;
        var x = V.fixed, y = H.fixed;
        // Strictly interior on both, which is what makes it a crossing rather than a T: a route
        // that ends on another one's line shares a point with it and has nothing to hop over.
        var inH = x > H.run.lo && x < H.run.hi, inV = y > V.run.lo && y < V.run.hi;
        if (inH && inV) { found.push({ H: H, V: V, x: x, y: y }); continue; }
        // Or exactly where one of them lets go of a corner's arc, inside the other's run.
        var tH = !inH && inV && tangentSide(H, x), tV = inH && !inV && tangentSide(V, y);
        if (tV) found.push({ H: H, V: V, x: x, y: y, only: H, side: tV });
        else if (tH) found.push({ H: H, V: V, x: x, y: y, only: V, side: tH });
      }
    }
    return found;
  }

  // A crossing on a corner's tangent. In the third held-out set's b14, 測定データ ran into PLC
  // along y 188, exactly where the camera's route to 自動梱包機 finished turning down off y 180:
  // the drawn straight of that route starts ON the other line, so the strict test above saw a T, no
  // bump was drawn, and the arc landing on the line read as a branch -- as if 測定データ also fed
  // 自動梱包機. It is a crossing: the route arrives from one side of the line and leaves on the
  // other. `roomForBridges` already counts it stranded and offers slides; there, none was legal --
  // the camera's port stood at its face's last allowed place and PLC's left face held six ports at
  // one pitch -- and the crossing did not move.
  //
  // So it takes a bump on the run it lies inside, on the side the turning route RUNS STRAIGHT from
  // the crossing, which needs that straight to last the bump's height. On the other side is the
  // arc, and a bump there would cut through it: the arc and the bump both span the 8px between the
  // two lanes. Where the straight side is -y (or -x) this is the usual bump; where it is not, the
  // bump is the usual one mirrored, which is the only exception to one side per drawing and the
  // price of having a mark at all.
  //
  // Rejected: a smaller radius on that corner, so that the turning route shows a stub of straight
  // above the line. With any radius the crossing stays within a bump's height of the corner, so
  // neither route could carry a bump; the crossing would be plain and 4px from an elbow, which is
  // the shape `roomForBridges` was written because readers took for a join.
  //
  // Returns +1 or -1, the direction `seg`'s straight run leaves the point `at` along its own axis,
  // when `at` is where a corner's arc hands over to that run and the run lasts a bump's height;
  // else 0.
  function tangentSide(seg, at) {
    var a = seg.horizontal ? seg.owner.points[seg.index].x : seg.owner.points[seg.index].y;
    var b = seg.horizontal ? seg.owner.points[seg.index + 1].x : seg.owner.points[seg.index + 1].y;
    if (seg.run.hi - seg.run.lo < HOP_R) return 0;
    if (at === seg.run.lo && seg.run.lo !== Math.min(a, b)) return 1;
    if (at === seg.run.hi && seg.run.hi !== Math.max(a, b)) return -1;
    return 0;
  }

  function bridgeCrossings(routed, ctx) {
    var i;
    for (i = 0; i < routed.length; i += 1) {
      if (!routed[i]) continue;
      routed[i].hops = [];
      for (var s = 0; s + 1 < routed[i].points.length; s += 1) routed[i].hops.push(null);
    }
    var found = crossingsOf(routed);
    if (crossingsAreCommon(found.length, routed)) return;
    for (i = 0; i < found.length; i += 1) {
      var c = found[i];
      if (c.only) { placeHop(c.only, c.x, c.y, ctx, c.side); continue; }
      var wH = hopWeight(c.H.owner.edge), wV = hopWeight(c.V.owner.edge);
      var first = (wH !== wV) ? (wH < wV ? c.H : c.V) : (c.H.order > c.V.order ? c.H : c.V);
      var second = (first === c.H) ? c.V : c.H;
      if (!placeHop(first, c.x, c.y, ctx)) placeHop(second, c.x, c.y, ctx);
    }
  }

  // Where each crossing's bump could stand, for the label placer to keep its plates off.
  //
  // The labels are placed before `bridgeCrossings` runs and `placeHop` refuses a bump with a
  // mask inside its air, so a plate can strand a crossing that had all the room it needed. The
  // eighth reader-facing review found exactly one such crossing: in 14 (the RL mesh), as the app
  // paints it, `w4 -.-> e2`'s "failover" plate sits ON its own run with its end at x=700, 8px from
  // where the thick `e3 ==> q` drops across at 708,168 -- clean by every term `labelPenalty` scores,
  // since the drop stands on the edge of the plate's gap rather than in it -- and a bump there
  // needs 12 on either connector. So it was drawn plain while the same drop's other crossing, 44pt lower, was bridged,
  // and an unmarked crossing beside a marked one reads as a join. Over SWEEP and the 18 review
  // sources, in the drawings that mark crossings at all, it was the only one of 4 left plain.
  //
  // Each entry is the air of every bump the crossing could have, ignoring labels and the other
  // crossings' bumps: a plate that overlaps ALL of one entry leaves that crossing no bump. A
  // plate that blocks one side only is not charged, because `bridgeCrossings` takes the other.
  // A drawing whose crossings are common draws no bumps (`crossingsAreCommon`), so it has none
  // to keep clear, and its labels are placed exactly as before.
  //
  // Rejected: moving the crossing, as `roomForBridges` does off an elbow or a face. It slides
  // before the labels exist, and nothing about the routes was short of room: `placeHop` refused
  // this crossing's bump on both connectors for the plate alone, after both had passed the
  // straight-run and box tests. With the plate charged here it takes the same place on the far
  // side of the drop that the lower "failover" already had, and both bumps ride the drop. Also rejected: letting the bump run up to the
  // plate. The grid step of air is the one `placeHop` keeps from a box for the reason given
  // there, and a crest touching a plate reads as the plate's border just as it does a node's.
  function bumpRooms(routed, ctx) {
    var found = crossingsOf(routed);
    if (crossingsAreCommon(found.length, routed)) return [];
    var rooms = [];
    for (var i = 0; i < found.length; i += 1) {
      var c = found[i];
      var airs = [];
      for (var k = 0; k < 2; k += 1) {
        var seg = k === 0 ? c.H : c.V;
        if (c.only && seg !== c.only) continue;
        var hop = hopAt(seg, c.x, c.y, [], c.side);
        if (!hop) continue;
        var air = hopAir(hop);
        if (clearOfBoxes(air, ctx)) airs.push(air);
      }
      if (airs.length > 0) rooms.push(airs);
    }
    return rooms;
  }

  // A bump is a signal -- "these two pass, they do not meet" -- and a signal is read against the
  // lines that do not carry one. Every reader-facing review that praised the hop praised it with
  // the same rider, "where crossings are rare", and read the dense review source, 15 bumps on 11 of
  // its 28 connectors, as "a circuit board" with "rows of bumps"; that source was the last one a
  // reader still gave to Pele, which marks none of its crossings there.
  //
  // So a drawing whose crossings outnumber half its connectors marks none, and every crossing in
  // it is the plain right angle: two straight strokes through one point, each running on past it.
  // That is already how this renderer draws a crossing no bump fits, it is how the dense source
  // drew 2 of its 17 crossings before this rule, and on an orthogonal grid it cannot be read as a
  // join -- a join here is a T or an elbow, never four arms. The slides in `roomForBridges` still
  // run, and still keep these crossings off elbows and faces, which is what lets the cross read.
  //
  // The density is crossings per connector because that is what the reader's complaint counted:
  // how many of the lines carry a mark. Over SWEEP, the 18 review sources and render.spec.js's
  // crossing sources, bumps were drawn in four drawings, and the ratio parts them with a wide
  // margin: 12 (1 crossing on 16 connectors), 14 (3 on 14), the dense source (17 on 28) and K3,3
  // (11 on 9). Any cut-off from 0.22 to 0.6 sorts them the same way; a half is the plain-words
  // reading of "rare". A single crossing is never suppressed while there are two connectors.
  //
  // Rejected: dropping only the bumps that crowd one another -- a run with two, a row along one
  // lane. In the dense source that leaves bumps on some crossings and not on others, and "one
  // crossing marked, its neighbour not" is the reviews' weakness 10, still open in 14.
  // One convention per drawing is the rule both regimes keep. A count per drawing was rejected
  // too: it would strip a large sparse drawing of bumps a small dense one keeps.
  function crossingsAreCommon(crossings, routed) {
    var connectors = 0;
    for (var i = 0; i < routed.length; i += 1) if (routed[i]) connectors += 1;
    return 2 * crossings > connectors;
  }

  // Absolute M, L, Q and A, integers only. Not cosmetic: EditorialElbowTests.straightRuns parses
  // the first three and steps over anything else without moving its cursor, which is safe for an A
  // only because a bridge begins and ends on the run it interrupts -- the run measured across it is
  // the same axis-aligned run. An H, V or C would make that assertion pass without examining
  // anything, which is worse than failing.
  //
  // `lineTo` drops a zero-length L rather than writing one. Two corners 8px apart each take a 4px
  // radius, so the arcs meet and the run between them is gone; `cornerRadius` allows exactly that,
  // and the alternative -- a repeated point in the `d` -- is markup that says nothing.
  function pathOf(points, hops) {
    var at = { x: points[0].x, y: points[0].y };
    var d = "M" + at.x + "," + at.y;
    function lineTo(x, y) {
      if (x === at.x && y === at.y) return;
      d += " L" + x + "," + y;
      at.x = x;
      at.y = y;
    }
    for (var i = 1; i < points.length; i += 1) {
      var c = points[i];
      var p = points[i - 1];
      var bumps = hops ? hops[i - 1] : null;
      if (bumps) {
        // In travel order along this run, which is not the order they were found in.
        var ahead = (c.x !== p.x) ? (c.x > p.x) : (c.y > p.y);
        for (var k = 0; k < bumps.length; k += 1) {
          var hop = bumps[ahead ? k : bumps.length - 1 - k];
          lineTo(hop.from.x, hop.from.y);
          d += " A" + HOP_R + "," + HOP_R + " 0 0 " + hop.sweep + " " + hop.to.x + "," + hop.to.y;
          at.x = hop.to.x;
          at.y = hop.to.y;
        }
      }
      if (i + 1 >= points.length) { lineTo(c.x, c.y); continue; }
      var n = points[i + 1];
      var r = cornerRadius(
        Math.abs(c.x - p.x) + Math.abs(c.y - p.y),
        Math.abs(n.x - c.x) + Math.abs(n.y - c.y)
      );
      if (r <= 0) { lineTo(c.x, c.y); continue; }
      var ux = sign(c.x - p.x), uy = sign(c.y - p.y);
      var vx = sign(n.x - c.x), vy = sign(n.y - c.y);
      lineTo(c.x - ux * r, c.y - uy * r);
      d += " Q" + c.x + "," + c.y + " " + (c.x + vx * r) + "," + (c.y + vy * r);
      at.x = c.x + vx * r;
      at.y = c.y + vy * r;
    }
    return d;
  }

  function rectsOverlap(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width
      && a.y < b.y + b.height && b.y < a.y + a.height;
  }

  // Overlapping, or sharing a stretch of edge. A corner-to-corner touch counts too; it is a point,
  // and the plates either side of it still read as one shape.
  function rectsMeet(a, b) {
    return a.x <= b.x + b.width && b.x <= a.x + a.width
      && a.y <= b.y + b.height && b.y <= a.y + a.height;
  }

  // How far a mask's PLATE is from a stroke: positive outside it, negative under it.
  //
  // The plate and not the plate's centre, and the change is the whole of the reader's complaint.
  // Measured on cand.mmd, "negotiate(adjustRate, original)" -- a 176x40 plate naming the solid
  // O -> N1 edge -- stood 8px from its own line by the plate and 8px from the dotted N2 -> O edge
  // by the plate, while by the CENTRE its own line was 96px away and the dotted one 104px: nearest,
  // and the reader still read the sentence off the wrong line. A centre 8px nearer decides nothing
  // when the plate is a hundred pixels wide; what the eye uses is which stroke the plate touches.
  //
  // Both arguments are axis-aligned -- routes are orthogonal and plates are rectangles -- so
  // outside the plate this is the gap between two intervals per axis, hypotenuse when the segment
  // misses on both.
  //
  // Under the plate the same question is asked as a NEGATIVE distance, because zero is not an
  // answer and a third of the corpus lands there. A mask centred on its own run has its own stroke
  // at 0; so does every foreign stroke that happens to cross it, and clamped at zero 25 masks tied
  // at exactly that -- the placer was being asked which of two buried lines the plate was on and
  // the measurement had nothing to say. What a reader uses there is what a plate over a stroke actually
  // looks like: the stroke goes under one edge and comes out of the opposite one, the longer the
  // covered stretch the plainer it is, and the nearer the middle the plainer again. So the depth is
  // the covered length plus how far the stroke runs from the nearest parallel edge, and the two
  // terms are summed because each alone gets a case wrong -- covered length alone ties two parallel
  // runs 12px apart (both covered end to end), and the distance-from-the-edge alone calls a 40px
  // vertical crossing of a 136x40 plate a deeper claim than the 136px horizontal the plate is
  // sitting on.
  function rectSegDist(rect, p, q) {
    var loX = Math.min(p.x, q.x), hiX = Math.max(p.x, q.x);
    var loY = Math.min(p.y, q.y), hiY = Math.max(p.y, q.y);
    var gx = Math.max(0, Math.max(rect.x - hiX, loX - (rect.x + rect.width)));
    var gy = Math.max(0, Math.max(rect.y - hiY, loY - (rect.y + rect.height)));
    if (gx > 0 || gy > 0) return Math.sqrt(gx * gx + gy * gy);
    var covered, depth;
    if (p.y === q.y) {
      covered = Math.min(hiX, rect.x + rect.width) - Math.max(loX, rect.x);
      depth = Math.min(p.y - rect.y, rect.y + rect.height - p.y);
    } else if (p.x === q.x) {
      covered = Math.min(hiY, rect.y + rect.height) - Math.max(loY, rect.y);
      depth = Math.min(p.x - rect.x, rect.x + rect.width - p.x);
    } else {
      // Routes are orthogonal, so this is the rounding of a corner arrived at as its two tangent
      // legs elsewhere; treat it as a touch and let the legs either side carry the claim.
      return 0;
    }
    return -(Math.max(0, covered) + Math.max(0, depth));
  }

  // The nearest stroke to a plate that is NOT part of the route the label annotates. Own segments
  // are excluded by the identity of their endpoint objects, not by comparing coordinates: `emit`
  // fills `ctx.drawn` from the very `points` array this route was routed into, and two different
  // edges running the same lane do share coordinates.
  function nearestRival(rect, own, ctx) {
    var best = Infinity;
    for (var i = 0; i < ctx.drawn.length; i += 1) {
      var seg = ctx.drawn[i];
      var mine = false;
      for (var j = 0; j < own.length; j += 1) {
        if (own[j][0] === seg[0] && own[j][1] === seg[1]) { mine = true; break; }
      }
      if (mine) continue;
      var d = rectSegDist(rect, seg[0], seg[1]);
      if (d < best) best = d;
    }
    return best;
  }

  // How far a point is from a segment, for the tie-break below the plate measurement.
  function pointSegDist(x, y, p, q) {
    var dx = q.x - p.x, dy = q.y - p.y;
    var len = dx * dx + dy * dy;
    var t = len === 0 ? 0 : ((x - p.x) * dx + (y - p.y) * dy) / len;
    if (t < 0) t = 0; else if (t > 1) t = 1;
    var ex = x - (p.x + t * dx), ey = y - (p.y + t * dy);
    return Math.sqrt(ex * ex + ey * ey);
  }

  // The same two questions asked of the mask's middle rather than of its plate, as one number:
  // positive when the route it annotates is the nearer. See `placeEdgeLabel` for what it is worth
  // and why a second measurement earns its place at all.
  function centreMargin(cx, cy, own, ctx) {
    var mine = Infinity, rival = Infinity, i;
    for (i = 0; i < own.length; i += 1) {
      var d = pointSegDist(cx, cy, own[i][0], own[i][1]);
      if (d < mine) mine = d;
    }
    for (i = 0; i < ctx.drawn.length; i += 1) {
      var seg = ctx.drawn[i];
      var isMine = false;
      for (var j = 0; j < own.length; j += 1) {
        if (own[j][0] === seg[0] && own[j][1] === seg[1]) { isMine = true; break; }
      }
      if (isMine) continue;
      var r = pointSegDist(cx, cy, seg[0], seg[1]);
      if (r < rival) rival = r;
    }
    return rival - mine;
  }

  // Does a stroke that is not the label's own run under the plate ALONG the run the plate sits on?
  // `rectSegDist` cannot say so: it scores a buried stroke by covered length plus depth, and a
  // sibling 12px over from the plate's own line, covered end to end, comes out only 12 shallower
  // than the plate's own -- a margin the taper in `placeEdgeLabel` calls owned. A reader sees two
  // lines enter the plate on the same axis and leave it on the same axis, and nothing to say which
  // of the two the words name. A crossing under a plate is the other case and is not this one: it
  // enters across the plate's own line and leaves across it, which the comment on `rival < 0`
  // weighs.
  //
  // Inside the plate, or lying ON its edge from one end of the plate to the other. The plate is
  // opaque and painted over the strokes, so a stroke on its edge loses half its width for the whole
  // length and reads as the plate's border: the line looks broken where the words are, and the
  // plate stands between two lines on one axis exactly as above. The held-out review's h04 drew
  // "DFU request" ON its line with "CRC error"'s line 12px below -- one pitch, half the plate's 24px
  // -- on its bottom edge for all 88px, and this test, strictly inside, let it pass. The review
  // read the miss as a direction test, but nothing here asks direction; the boundary was the bug.
  //
  // Rejected: any stroke meeting the edge for any length. Run over 576 drawings that put a labelled
  // two-way pair beside a third exit on one face, it moved 4 whose third exit clipped 4px of a
  // plate's corner before turning away -- a stroke a reader still sees leave -- and took "close"
  // off its line to stand between two others. End to end on the edge moved 8 of the 576, took 2
  // plates off a stroke they erased, moved h04 alone of the held-out twenty, and left all
  // 212 sweep drawings byte-identical. A partial meeting stays with the gap terms.
  function parallelUnder(rect, seg, own, ctx) {
    for (var i = 0; i < ctx.drawn.length; i += 1) {
      var d = ctx.drawn[i];
      if ((d[0].y === d[1].y) !== seg.horizontal) continue;
      if (d[0].x !== d[1].x && d[0].y !== d[1].y) continue;
      var mine = false;
      for (var j = 0; j < own.length; j += 1) {
        if (own[j][0] === d[0] && own[j][1] === d[1]) { mine = true; break; }
      }
      if (mine) continue;
      var across = seg.horizontal ? d[0].y : d[0].x;
      var aLo = seg.horizontal ? rect.y : rect.x;
      var aHi = aLo + (seg.horizontal ? rect.height : rect.width);
      var lo = seg.horizontal ? Math.min(d[0].x, d[1].x) : Math.min(d[0].y, d[1].y);
      var hi = seg.horizontal ? Math.max(d[0].x, d[1].x) : Math.max(d[0].y, d[1].y);
      var bLo = seg.horizontal ? rect.x : rect.y;
      var bHi = bLo + (seg.horizontal ? rect.width : rect.height);
      if (across > aLo && across < aHi && hi > bLo && lo < bHi) return true;
      if ((across === aLo || across === aHi) && lo <= bLo && hi >= bHi) return true;
    }
    return false;
  }

  // Is the next stroke past a BESIDE plate -- across the plate, on the side away from its own run,
  // anywhere along the plate's length -- a sibling's: another edge leaving the node this one leaves?
  //
  // Then the plate stands in the gap between two lines that leave one vertex, and those are the two
  // lines a reader is most likely to confuse: they start together, and what is written on them is the
  // same kind of word -- "yes" and "no", "불가" and "가능". The second held-out set's b20 drew both of
  // a decision's answers that way, each plate facing the other's line, and its reviewer could swap
  // them; every margin the placer scores was positive, because each plate was 8px from its own line
  // and 40px from its sibling's. A plate that faces some unrelated line is not this case: that line
  // does not start where its own does, and the margin term already prices it by distance.
  //
  // Across the plate's whole length, not only from its middle: tested from the middle, b20's "불가"
  // slid 4px along its run until the ray missed the end of "가능"'s line, and stood where it was.
  function facesSibling(rect, seg, side, own, edge, ctx) {
    var best = Infinity, owner = null;
    var lo = seg.horizontal ? rect.x : rect.y;
    var hi = lo + (seg.horizontal ? rect.width : rect.height);
    var far = seg.horizontal ? (side > 0 ? rect.y + rect.height : rect.y) : (side > 0 ? rect.x + rect.width : rect.x);
    for (var i = 0; i < ctx.drawn.length; i += 1) {
      var d = ctx.drawn[i];
      if (!d.edge || d.edge === edge) continue;
      var across, dLo, dHi;
      if (seg.horizontal) {
        if (d[0].y !== d[1].y) continue;
        across = d[0].y; dLo = Math.min(d[0].x, d[1].x); dHi = Math.max(d[0].x, d[1].x);
      } else {
        if (d[0].x !== d[1].x) continue;
        across = d[0].x; dLo = Math.min(d[0].y, d[1].y); dHi = Math.max(d[0].y, d[1].y);
      }
      if (dHi <= lo || dLo >= hi) continue;
      var dist = (across - far) * side;
      if (dist >= 0 && dist < best) { best = dist; owner = d.edge; }
    }
    return owner !== null && owner.from === edge.from;
  }


  // How near the plate comes to the route it annotates. BESIDE this is the rule 2 gap; ON it is
  // the negative depth above, because the stroke runs under the plate. Taken over the whole route
  // rather than the one segment the placement was built around: a corner leg of the SAME edge
  // passing closer only makes the label's owner plainer, and pricing that as a failure sent the
  // placer looking for positions further from its own connector.
  function nearestOwn(rect, own) {
    var best = Infinity;
    for (var i = 0; i < own.length; i += 1) {
      var d = rectSegDist(rect, own[i][0], own[i][1]);
      if (d < best) best = d;
    }
    return best;
  }

  // How badly a mask lands where it is proposed. Zero is what a placement in open canvas scores;
  // the weights only order the failures, and they order them by how much the reader loses. A mask
  // outside the viewBox is clipped and the word is gone; a mask inside a node is covered by the
  // node's fill, because nodes are painted last (SKILL.md §6 rule 6); a mask over another mask
  // makes two words one; a mask straddling a zone wall cuts the outline of the box it stands in;
  // a mask whose owner cannot be told attaches its sentence to the wrong line; a mask over a
  // stroke hides a connector. In that order, and the ambiguity term is scored in `placeEdgeLabel`
  // rather than here because it is the only one of them that depends on where the mask's OWN
  // route runs.
  //
  // `sitting` is the one segment the mask is deliberately covering when it is placed ON its own
  // connector, and it is the only segment of the route exempted -- the legs around the corner from
  // it are hidden by accident, not by design, and still count.
  function labelPenalty(rect, own, ctx, sitting) {
    var penalty = 0;
    var i;
    if (rect.x < 0 || rect.y < 0 || rect.x + rect.width > ctx.width || rect.y + rect.height > ctx.height) {
      penalty += 1000;
    }
    // Every clearance here is measured at LABEL_GAP_PX, not at strict overlap. A mask whose corner
    // meets a node's corner has no pixel inside the box and reads as a collision anyway -- which is
    // exactly what reelect.mmd drew: the mask ended at x=244 and the node began at x=244, and the
    // reader reported the label as running into the box. Scoring true overlap alone also left the
    // search indifferent between a flush position and one 8px clear of the same face, so it kept
    // whichever it reached first. The measurement is the whole argument: over 79 sources NO label
    // was strictly inside a node and 41 of 88 were within this margin of one.
    var near = {
      x: rect.x - LABEL_GAP_PX, y: rect.y - LABEL_GAP_PX,
      width: rect.width + 2 * LABEL_GAP_PX, height: rect.height + 2 * LABEL_GAP_PX
    };
    // Two weights per obstacle, because the near margin and a real intersection are not the same
    // failure. A mask 4px from a node reads as touching it; a mask whose pixels are inside one is
    // painted over and gone. A mask 4px from another mask is tight; a mask ON another mask makes
    // both words unreadable, which is why it outranks standing too near a node -- on `P -- "..." -->
    // Q / P -. "..." .-> Q` the placer had only bad candidates and took a 50 that buried one label
    // under the other in preference to a 100 that merely stood close to a box.
    for (i = 0; i < ctx.boxes.length; i += 1) {
      if (rectsOverlap(rect, ctx.boxes[i])) penalty += 400;
      else if (rectsOverlap(near, ctx.boxes[i])) penalty += 100;
    }
    // A mask that MEETS another along an edge is charged as one on it, not as one near it. Both
    // plates are the same fill, so with no white between them they print as one strip and the two
    // labels read as one: the fifth held-out review found h04's "supervision timeout" and "DFU
    // request" exactly so, 0px apart, and `rectsOverlap` -- strict, as it has to be for strokes and
    // boxes -- scored that meeting 50, the same as a plate 7px off.
    for (i = 0; i < ctx.labelRects.length; i += 1) {
      if (rectsMeet(rect, ctx.labelRects[i])) penalty += 200;
      else if (rectsOverlap(near, ctx.labelRects[i])) penalty += 50;
    }
    // A mask that leaves a crossing no bump (see `bumpRooms`). 10, a foreign stroke within the
    // gap, because that is what it is at one remove: the crossing stroke stands just outside the
    // gap, and what the mask stands in is the bump that stroke's crossing would have drawn.
    for (i = 0; i < ctx.bumpRooms.length; i += 1) {
      var blocks = true;
      for (var b = 0; b < ctx.bumpRooms[i].length; b += 1) {
        if (!rectsOverlap(rect, ctx.bumpRooms[i][b])) { blocks = false; break; }
      }
      if (blocks) penalty += 10;
    }
    // A zone's rect is painted before the labels, so a mask INSIDE one covers nothing (rule 6 says
    // so in as many words) and a mask outside one is not its business. A mask that overlaps the
    // rect without being inside it is the third case: it is sitting on the wall, and it erases the
    // stretch of outline it covers. Measured on 216 labels over 79 sources, 5 did exactly that.
    for (i = 0; i < ctx.rails.length; i += 1) {
      var rail = ctx.rails[i];
      if (!rectsOverlap(near, rail)) continue;
      var inside = near.x >= rail.x && near.y >= rail.y
        && near.x + near.width <= rail.x + rail.width
        && near.y + near.height <= rail.y + rail.height;
      // Level with a mask over another mask, and for the same reason: both erase something
      // outright rather than making it harder to read. It was 20, which put it under the ambiguity
      // term added below, and the corpus came back with 4 masks astride a zone border. Ordering it
      // above costs nothing measurable -- 0 of the 162 masks lose ownership margin by it -- so
      // this is not the trade it looks like; two properties that can both be held are both held.
      if (!inside) penalty += 200;
    }
    // Foreign strokes only. `ctx.drawn` holds every route, this one included, and the label's own
    // legs are charged by the loop below, which is the one that knows which leg the mask is SITTING
    // on. Counted here as well, every leg was charged twice and the sitting one -- exempt below --
    // was charged anyway: every ON candidate in the review's source 03 came out at 10 with its
    // nearest foreign stroke 24-60px away, so ON cost 26 against the 16 the tie-break in
    // `placeEdgeLabel` was swept to mean, and every ON placement was reported as crowded. Same
    // identity test as `nearestRival`: two edges sharing a lane share coordinates, not objects.
    for (i = 0; i < ctx.drawn.length; i += 1) {
      var mine = false;
      for (var j = 0; j < own.length; j += 1) {
        if (own[j][0] === ctx.drawn[i][0] && own[j][1] === ctx.drawn[i][1]) { mine = true; break; }
      }
      if (mine) continue;
      if (segmentCrossesRect(ctx.drawn[i][0], ctx.drawn[i][1], near)) penalty += 10;
    }
    // Its own route counts too: the perpendicular offset clears only the segment the label
    // annotates, and a mask wider than that segment reaches the leg around the corner from it.
    for (i = 0; i < own.length; i += 1) {
      if (sitting && own[i][0] === sitting[0] && own[i][1] === sitting[1]) continue;
      if (segmentCrossesRect(own[i][0], own[i][1], near)) penalty += 10;
    }
    return penalty;
  }

  // Where an edge label goes, and which of the two ways of attaching it to its line is used.
  //
  // SKILL.md §6 rule 2 puts the mask BESIDE the stroke with a 6-10px gap so the connector stays
  // traceable under its own annotation. Two cases have taken that default apart. The labels the
  // reported sources carry are thirty characters where the guide asks for fourteen:
  // `negotiate(adjustRate, original)` is a 152px mask, so BESIDE a vertical run its centre stands
  // 84px off its own line, and in nego.mmd a different stroke was 8px away. And a short label
  // beside its line is still 8px of white away from it: the review of sixteen drawings beside
  // Pele found labels a reader could not attach in a drawing where every margin this function
  // scores was safe. See the tie-break at the bottom.
  //
  // So the mask sits ON the run, centred on the stroke, wherever that is clean -- the way mermaid
  // and Pele place every label. Ownership is then not a judgement: the line enters one edge of the
  // mask and leaves the opposite edge on the same axis, and it is the stroke the plate covers most
  // of, which is what `rectSegDist` measures under a plate. BESIDE is what is left where ON would
  // harm something: a run too short for the plate, another stroke under it or within its gap, a
  // node, a mask, a zone wall.
  //
  // Rejected: ON at any price, which is what mermaid does. The ordering below never takes ON over a
  // clean BESIDE once ON costs it anything, because the price of ON in a crowded drawing is another
  // connector under the plate or inside its gap.
  //
  // What is scored is a MARGIN, not a verdict. Measured over the 47-source corpus before it, by the
  // metric below: 29 of 147 masks stood no nearer their own connector than some other, the worst of
  // them 64px nearer a line it does not name, and one of the 29 was on a drawing the reader sent.
  // After it: 0, with 143 of the 147 clear by 12px. render.spec.js still asserts both, unchanged,
  // and both still hold.
  //
  // ON is offered only where the run is longer than the mask plus a visible tail of stroke at each
  // end. A mask longer than the segment it sits on swallows the whole connector, and then rule 2's
  // harm is real: there is nothing left to trace.
  //
  // `besideOnly` withholds ON, for the drawing-wide pass at the label loop; see there.
  function placeEdgeLabel(edge, points, ctx, preferEarly, besideOnly, column) {
    if (!(edge.labelWidth > 0) || !(edge.labelHeight > 0)) return null;
    var halfW = half4(edge.labelWidth);
    var halfH = half4(edge.labelHeight);
    var segs = [];
    var own = [];
    for (var i = 0; i + 1 < points.length; i += 1) {
      var p = points[i], q = points[i + 1];
      var pair = [p, q];
      own.push(pair);
      segs.push({
        pair: pair, p: p, q: q, at: i,
        len: Math.abs(q.x - p.x) + Math.abs(q.y - p.y),
        horizontal: p.y === q.y
      });
    }
    segs.sort(function (a, b) {
      // A transit edge's label belongs at the visible end, which rule 5 spells out: the reader has
      // to be able to read it without following the stroke behind whatever it disappears under.
      if (preferEarly && a.at !== b.at) return a.at - b.at;
      if (a.len !== b.len) return b.len - a.len;
      return a.at - b.at;
    });

    var best = null;
    for (i = 0; i < segs.length; i += 1) {
      var seg = segs[i];
      var lo = seg.horizontal ? Math.min(seg.p.x, seg.q.x) : Math.min(seg.p.y, seg.q.y);
      var hi = seg.horizontal ? Math.max(seg.p.x, seg.q.x) : Math.max(seg.p.y, seg.q.y);
      // Half the mask's extent ALONG the run, which is what decides whether the run can carry it.
      var alongHalf = seg.horizontal ? halfW : halfH;
      var onFits = (hi - lo) >= 2 * (alongHalf + LABEL_GAP_PX);
      // Where along this run a marker is drawn, if it carries one: the route's first point for a
      // start head, its last for an end head. See the head term below.
      var tips = [];
      if (seg.at === 0 && ARROW_MARKERS[edge.arrowStart]) tips.push(seg.horizontal ? seg.p.x : seg.p.y);
      if (seg.at === points.length - 2 && ARROW_MARKERS[edge.arrowEnd]) tips.push(seg.horizontal ? seg.q.x : seg.q.y);
      for (var m = 0; m < 3; m += 1) {
        var onLine = (m === 2);
        if (onLine && (!onFits || besideOnly)) continue;
        // `column`: ON a run of that axis at that one place along it, or nowhere (`alignColumns`).
        if (column && (!onLine || seg.horizontal !== column.horizontal)) continue;
        // Above a horizontal run and to the right of a vertical one, which is where the style guide
        // puts an arrow label; the other side is the second try, not a different rule. On the line
        // there is no side.
        var side = onLine ? 0 : (seg.horizontal ? (m === 0 ? -1 : 1) : (m === 0 ? 1 : -1));
        // ON keeps a tail of stroke showing past each end of the mask; BESIDE may use the whole run.
        var aLo = onLine ? lo + alongHalf + LABEL_GAP_PX : lo;
        var aHi = onLine ? hi - alongHalf - LABEL_GAP_PX : hi;
        var mid = snap4((lo + hi) / 2);
        if (mid < aLo) mid = aLo;
        if (mid > aHi) mid = aHi;
        // Every grid step along the run, nearest the midpoint first. Three positions were enough
        // while a fan's legs were long; a rhombus's two branches leave its apex 16px apart and turn
        // within 24px of it, and on `B -->|yes| C / B -->|no| D` every one of the six positions the
        // quarter rule offered was inside 8px of one of the route's own corners. Stepping the run
        // costs a handful of candidates on a diagram this file already budgets nine nodes for.
        var alongs = [mid];
        for (var step = GRID; mid - step >= aLo || mid + step <= aHi; step += GRID) {
          if (mid - step >= aLo) alongs.push(mid - step);
          if (mid + step <= aHi) alongs.push(mid + step);
        }
        if (column) alongs = column.at >= aLo && column.at <= aHi ? [column.at] : [];
        for (var a = 0; a < alongs.length; a += 1) {
          var cx, cy;
          if (seg.horizontal) {
            cx = alongs[a];
            cy = seg.p.y + side * (halfH + LABEL_GAP_PX);
          } else {
            cx = seg.p.x + side * (halfW + LABEL_GAP_PX);
            cy = alongs[a];
          }
          var rect = { x: cx - halfW, y: cy - halfH, width: edge.labelWidth, height: edge.labelHeight };
          // The canvas is as wide as the layout made it, and the layout made it wide enough for a
          // mask BESIDE a run, not for one centred on it: on two parallel labelled chains the room
          // pass reserves 192px between the columns, and a 176px mask centred on the left column
          // starts 24px off the left edge. Rather than lose the placement to the viewBox, slide it
          // back on -- the stroke still runs through the mask, which is the whole of what makes the
          // label the line's own. The slide is capped at a quarter of the mask, so the stroke stays
          // inside its middle half and it never reads as standing beside the line again.
          var slid = 0;
          if (onLine) {
            var cap = GRID * Math.floor((seg.horizontal ? halfH : halfW) / (2 * GRID));
            if (seg.horizontal) {
              if (rect.y < 0) slid = Math.min(-rect.y, cap);
              else if (rect.y + rect.height > ctx.height) slid = -Math.min(rect.y + rect.height - ctx.height, cap);
              cy += slid;
              rect.y += slid;
            } else {
              if (rect.x < 0) slid = Math.min(-rect.x, cap);
              else if (rect.x + rect.width > ctx.width) slid = -Math.min(rect.x + rect.width - ctx.width, cap);
              cx += slid;
              rect.x += slid;
            }
          }
          var penalty = labelPenalty(rect, own, ctx, onLine ? seg.pair : null);
          // Ambiguity, scored as a margin rather than as a verdict: how much nearer the plate is to
          // its own stroke than to the nearest stroke that is not its own.
          //
          // A verdict was what was here before -- a flat 40 for "some rival is at least as near",
          // a 6 for "a rival is within a gap of as near" -- and the corpus says what a verdict
          // costs. Of 147 masks that have a rival at all, it left 29 at a margin of zero or less,
          // 20 of them exact ties, and gave the placer no reason to prefer any one of the 29 over
          // any other: every candidate along the whole connector scored the same 40, so it took
          // whichever it reached first. Graded, the same measurement leaves 0 of the 147 at zero
          // or less and 143 of them at a clear 12px or better, and it is the same arithmetic.
          //
          // The taper ends at LABEL_MARGIN_PX. Below that the reader is being asked to judge two
          // distances that differ by less than the gap rule 2 already leaves, which is the judgement
          // the report says is not available: the plate is 8px off its own line and 8px off a
          // different one and there is no third fact to break it.
          var ownDist = nearestOwn(rect, own);
          var rival = nearestRival(rect, own, ctx);
          var margin = rival - ownDist;
          if (margin < LABEL_MARGIN_PX) {
            // 180 at the floor, which is where the reader put it: worse than a mask standing too
            // near a node (100) and not as bad as two masks printed over each other (200). The
            // taper is therefore 7.5 points a pixel, which has to be read against the two
            // tie-breaks below -- at 90 it was 3.75 and the pair of them outbid eight pixels of
            // margin on cand.mmd's "discardedQuoteId", which came out 8px from its own line and
            // 12px from a different one when a position 8 and 20 existed. Swept at 90, 120, 150,
            // 180 and 240: 180 is where all three of the reader's drawings reach the best margin
            // any position on their connectors offers, which is 12px, checked by running this
            // term at 100000 and reading off the floor. Past it the extra weight buys nothing and
            // starts pushing masks onto zone borders.
            //
            // Measured at the chosen setting, the trade this ranking permits is not taken: no
            // mask in the corpus ends within rule 2's gap of a node or of another mask. Before
            // this pass two did each, so the ranking costs nothing and the room reserve in the
            // layout takes those four back.
            var shortfall = Math.min(LABEL_MARGIN_PX - margin, 2 * LABEL_MARGIN_PX);
            penalty += Math.round((180 * shortfall) / (2 * LABEL_MARGIN_PX));
          }
          // And the same question of the mask's MIDDLE, at 5 -- half the cheapest real harm this
          // function charges for, so it can only order candidates the rest of the score calls equal
          // and can never overturn one of them. It earns the line because the two readings disagree
          // in a way that is not noise: with it at 0, three masks came out attached by their plates
          // and with a foreign stroke nearer their MIDDLES than their own, which is a mask whose
          // text leans on somebody else's line while its plate leans on its own. cand.mmd's
          // "derivedQuoteId (representative)" was one of them. At 5 all three are clean, and 5, 9,
          // 15 and 25 give the same drawing, so this is the cheapest setting that works rather than
          // a tuned one.
          if (centreMargin(cx, cy, own, ctx) <= 0) penalty += 5;
          // A foreign stroke UNDER the plate, charged apart from one merely within the gap. The stroke
          // term in `labelPenalty` gives both the same 10, and under the plate the ownership margin
          // stays positive -- the plate covers its own run more deeply than a line crossing it -- so
          // nothing else in the score could tell a plate that erases a connector from one that
          // stands 4px off it. With ON the default it mattered at once: on a labelled crossing mesh
          // "crossing alpha one to two" took an ON with another edge's leg running under it (10)
          // over a BESIDE that only stood near two (20), and over 128 labels the plates erasing a
          // foreign stroke went from 9 to 12.
          //
          // 10, so a stroke under the plate costs twice one beside it. Swept at 0, 5, 10, 20, 26,
          // 28, 40, 50, 60, 75 and 90: 12 erasures at 0 and 5, 9 from 10 to 50, 6 at 90 -- and from
          // 60 on the ownership tests in render.spec.js fail, because the taper above charges 90
          // for a margin of zero and a label tied between two lines starts to win over an ON that
          // covers a crossing. A label whose line cannot be told is the worse of the two: a crossing
          // under a plate still comes out of the far edge. 10 is the bottom of the flat stretch.
          if (rival < 0) penalty += 10;
          // An ON plate with a foreign stroke running under it beside its own, along the same axis
          // (`parallelUnder`). The held-out review found one, and `17c84b4` put it there: h03's
          // "승인 내역 없음" sat ON its line with its sibling exit, 12px over on the same face, running
          // the plate's whole height, because that ON cost 20 and the BESIDE above its own elbow
          // cost 58 once the term below charged it 40 for a third line 8px off. It is the same
          // failure as that BESIDE -- a plate between strokes a reader cannot rank -- so it pays the
          // same 40, and the two are then ordered by the harm each does besides.
          //
          // Swept at 0, 20, 40, 60, 100 and 180 over 750 drawings that put two labelled exits on
          // one rect face beside a third line (three directions, five label lengths for each of
          // three labels, both rulers): plates with a foreign stroke parallel under them 76, 60,
          // 52, 52, 48, 44. 20 leaves h03 as it was; 40 is the first that clears it, and it stays
          // there, under the 50 of a mask near a mask and the 100 of a mask near a node, because
          // either of those is worse than a plate a reader has to puzzle over. Of the 52 left, the
          // two read off by candidate had nothing better on their route -- every other plate went
          // into a node or over a different stroke -- so the rest are the layout's to part, not the
          // placer's. The 204-drawing sweep is byte-identical at every weight: none of its plates
          // had this.
          if (onLine && parallelUnder(rect, seg, own, ctx)) penalty += 40;
          // An ON plate inside a marker's length plus rule 2's gap of the tip it points at. The head
          // then sits flush on the plate with no shaft and reads as a barb on the label rather than
          // as the end of a line: without this term 7 of 91 ON plates did, against Pele's nearest
          // at 19px. Priced, not forbidden, and at 10, a stroke within the gap. Forbidden -- the
          // tail at that end lengthened by HEAD_PX -- it took 7 labels off their lines and moved
          // `H{Hub} -->|route two| B` up onto its two siblings' lanes, which is worse than the
          // flush head it avoided. Priced, 3 of 87 ON plates stand that close, as 3 of 18 did before.
          if (onLine) {
            for (var k = 0; k < tips.length; k += 1) {
              var along = seg.horizontal ? cx : cy;
              if (Math.abs(along - tips[k]) - alongHalf < LABEL_GAP_PX + HEAD_PX) penalty += 10;
            }
          }
          // What the reader actually loses here, before the ordering between the two ways of
          // attaching a label is applied. `crowded` is read as a warning slug, and which of the two
          // ways a clean label takes is a choice this function makes on a clear canvas, not a
          // compromise it was forced into.
          var harm = penalty;
          // The tie-break, and it now runs the other way: ON is the default and BESIDE pays.
          //
          // It was ON that paid, 16, so that rule 2's gap was the default and the line was taken
          // only where beside could not be owned. Two things were wrong with it. The price was not
          // 16: `labelPenalty` charged every ON for the run it was sitting on, through `ctx.drawn`,
          // so every ON scored at least 26, and the sweep that settled on 16 -- at 16, 30, 45, 60,
          // 90, 120 and 180 -- was really run 10 higher at every point. And ownership by margin was
          // the wrong measure of what the reader loses. The review of sixteen drawings beside Pele
          // ranked "edge labels float off their lines" first of ten weaknesses, and named labels
          // with every margin the score called safe: in its source 03 "timeout" stood 8px off its
          // own line with the nearest other one 64px from the plate, and in 04 "Yes, within
          // policy" stood the same 8 and 64. A plate beside its line is 8px of white away from
          // it, and with more than one line in view that reads as open space. Over
          // 128 labels -- the sweep, the three reported drawings, eight crowded stress sources and
          // the review's sixteen -- 110 touched no stroke at all; Pele, which sits every label on
          // its line, has 0.
          //
          // Rejected: keeping BESIDE wherever it is unambiguous, which is what the 16 meant to do.
          // Scored as "no foreign stroke within D of the plate", and measured with the rest of this
          // score as it stood, D has to pass 64 to move the review's labels at all -- at 48, 87 of
          // 128 still touch nothing -- and at 100 it still leaves 49 that way, "connect" in source
          // 03 among them, beside its line while the ten around it sit on theirs.
          //
          // 8 because it has to sit between two terms above: over the 5 the centre tie-break
          // charges, and under the 10 a stroke within the gap does, so that ON is taken only while
          // it is clean and any real harm on it hands the label back to a clean BESIDE. Swept at 1,
          // 4, 9, 10, 12 and 16: 86 of 128 on their lines at 1 and 4, 87 from 8 to 10, and from 12
          // on an ON with a stroke inside its gap beats a clean BESIDE -- plates erasing a foreign
          // stroke rise from 9 to 12 and render.spec.js's gap and parallel-run tests fail.
          //
          // Measured at this setting over the same 128: on their own lines 18 -> 87, touching no
          // stroke 110 -> 41, and ambiguous -- a foreign stroke under the plate, or one less than
          // twice as far from the label's middle as its own -- 60 -> 45. What is left is mostly the
          // layout's: a rhombus's two exits leave 16px apart, so a plate on either first leg covers
          // the other, and five edges between one pair share a corridor no placement can separate.
          if (!onLine) penalty += 8;
          // BESIDE with another line inside twice rule 2's gap of the plate: the plate then stands
          // between two strokes at distances a reader cannot rank, which the held-out review named
          // as the cost of a bundle -- "a reader cannot tell which label belongs to which line".
          // The taper above prices the margin, but a margin of a few px is cheap next to a stroke in
          // ON's gap, so such a plate was still the pick: 2 labels on the held-out sources stood
          // BESIDE with a foreign stroke under 16px off the plate. This leaves 1, h02's
          // refresh -> tokens, whose ON costs more than any BESIDE it has.
          //
          // 40, under the 50 a mask near another mask costs, and not the "never" a weight of 180
          // would mean: at 180 it put two of the three "settled" plates of render.spec.js's
          // labelled fan-in within 8px of each other, and two words run together is the worse failure.
          if (!onLine && rival < 2 * LABEL_GAP_PX) { penalty += 40; harm += 40; }
          // A BESIDE plate facing a sibling's line (`facesSibling`). 1, the smallest step the score
          // has: it orders two clean BESIDE seats and never outbids a real harm. At 10, as a harm,
          // it took b20's two answers off the gap and also put plates ON their lines with another
          // stroke inside the gap -- a clean seat facing a sibling cost 18 against 10: render.spec.js's
          // mask-distance check failed on `four-way decision` TD and BT, and those two and `long
          // back edge LR` warned label-crowded. A plate 4px off a different line is the worse of the
          // two, so the facing seat stays the cheaper.
          //
          // The other half is in `placeOne`: the drawing-wide BESIDE pass does not keep a seat that
          // faces a sibling. That pass is what put b20's "가능" there -- three of its four labels were
          // BESIDE, so it was offered BESIDE too, and its clean ON was given up for the gap.
          //
          // Measured over the three reviewed sets and the 292-drawing sweep: decision pairs whose
          // two plates share the gap 1 -> 0 (b20), with 5 drawings moving, none of them in the sweep.
          // What it cannot part is a pair whose every seat outside the gap is a real harm: the
          // sweep's `opposed answers beside a skip` sends a third line into each answer's target
          // 16px off it, so ON is 4px from a stroke and the far side is on it. That is two lines
          // arriving one pitch apart, and the layout's to widen.
          var faces = !onLine && facesSibling(rect, seg, side, own, edge, ctx);
          if (faces) penalty += 1;
          if (best === null || penalty < best.penalty) {
            best = { x: cx, y: cy, rect: rect, penalty: penalty, onLine: onLine, crowded: harm > 0, faces: faces, horizontal: seg.horizontal };
            if (penalty === 0) return best;
          }
        }
      }
    }
    return best;
  }

  // Where the zone title may sit, and where it ends up.
  //
  // A title is the one label in the drawing with no second choice of segment to sit on: it names
  // the box it is inside and belongs at the top of it. A route has no choice either -- its ports and
  // its lanes were settled by the layout, and a connector INTO a zone has to cross the zone's top
  // edge, which is the band the title lives in. Something has to give, and in reelect.mmd that band
  // is 576px wide and the title 260 of them: the title has room to step aside along it and the
  // route has none, so the title is what moves.
  //
  // Rejected: an opaque plate under the title, painted over the strokes the way a node is. It makes
  // the title legible whatever crosses it, and it hides 260px of a connector to do it -- the whole
  // point of §6 rule 2's gap is that a line stays traceable under its own annotation, and a title is
  // not even the annotation of the line it would be covering.
  // Also rejected: centring the title, which is what mermaid does and which happens to clear both
  // reported drawings. It clears them by luck -- the stroke is off-centre in both -- and it gives up
  // the editorial eyebrow's flush-left position on every zone, including the ones nothing crosses.
  //
  // The gap is LABEL_GAP_PX, the same 8px rule 2 asks between a mask and a stroke: a connector 2px
  // from a letter reads as touching it.
  function titleNear(x, cl) {
    return {
      x: x - LABEL_GAP_PX,
      y: cl.labelY - LABEL_GAP_PX,
      width: cl.labelWidth + 2 * LABEL_GAP_PX,
      height: cl.labelHeight + 2 * LABEL_GAP_PX
    };
  }

  function titleIsClear(x, cl, ctx) {
    var near = titleNear(x, cl);
    for (var i = 0; i < ctx.drawn.length; i += 1) {
      if (segmentCrossesRect(ctx.drawn[i][0], ctx.drawn[i][1], near)) return false;
    }
    return true;
  }

  // The eyebrow's home is the left of the band -- the position the layout reserved and the one
  // dd-arch.md asks for -- so the search starts there and steps right one grid unit at a time,
  // which makes the answer the least displacement that clears. `last` keeps the far end inside the
  // zone's own padding: a title that ran past it would be chrome hanging off the box it names.
  function slideTitle(cl, rect, ctx) {
    if (!(cl.labelWidth > 0)) return;
    if (titleIsClear(cl.labelX, cl, ctx)) return;
    var pad = cl.labelX - cl.x;
    var last = cl.x + cl.width - pad - cl.labelWidth;
    for (var x = cl.labelX + GRID; x <= last; x += GRID) {
      if (!titleIsClear(x, cl, ctx)) continue;
      cl.labelX = x;
      rect.x = x;
      return;
    }
    // Nothing in the band clears it. The title stays at the eyebrow's home rather than at whichever
    // arbitrary position the search stopped on -- one crossed title in its proper place is easier to
    // read than one crossed title halfway along a band.
  }

  // What a title at `x` would need from the layout to stand clear of every stroke: a lane under it
  // for a stroke along its band, or the band widened for one across it, by twice the shortfall,
  // because the contents stay centred in the band and so move half of what it gains. Null when
  // nothing crosses. Measured on the gap `titleIsClear` asks, not the bare box: a line in the gap is
  // one `slideTitle` could not clear, and judged on the box alone it was let stand 0px from the
  // words -- h07's "DWD 明细层", whose last glyph the review found 1.3pt from `d1 --> s1`'s ink.
  function roomAt(x, cl, ctx, routed) {
    var near = titleNear(x, cl);
    var room = null;
    for (var r = 0; r < routed.length; r += 1) {
      if (!routed[r]) continue;
      var pts = routed[r].points;
      var last = pts.length - 1;
      var edge = routed[r].edge;
      for (var i = 0; i < last; i += 1) {
        var p = pts[i], q = pts[i + 1];
        if (!segmentCrossesRect(p, q, near)) continue;
        room = room || { lane: false, wide: 0, helps: true };
        // Whether the room moves this line off the title. A lane deepens the header, so it carries
        // the zone's own first row, and with it a route's turn onto one of their ports, down out of
        // the title's band; a wider band carries the zone's contents across, and with them a port's
        // own line. A lane through the band on its way somewhere else, or a turn onto a port in
        // another zone, stays where it is either way -- the right-to-left drawing of `drop past a
        // sibling`, whose route into the lower zone runs level with that zone's first row across
        // the foot of the upper zone's title.
        var onto = (i + 2 === last && insideZone(edge.to, cl.id, ctx)) || (i === 1 && insideZone(edge.from, cl.id, ctx));
        var port = (i === 0 && insideZone(edge.from, cl.id, ctx)) || (i + 1 === last && insideZone(edge.to, cl.id, ctx));
        if (p.y === q.y) {
          room.lane = true;
          if (!onto && !port) room.helps = false;
        } else {
          room.wide = Math.max(room.wide, 2 * (x + cl.labelWidth + LABEL_GAP_PX - p.x));
          if (!port) room.helps = false;
        }
      }
    }
    return room;
  }

  function insideZone(id, zoneId, ctx) {
    for (var cur = id, guard = 0; guard < 256 && cur !== undefined && cur !== null; guard += 1) {
      if (cur === zoneId) return true;
      cur = ctx.parentOf.get(cur);
    }
    return false;
  }

  function segmentCrossesRect(p, q, rect) {
    return Math.max(p.x, q.x) > rect.x
      && Math.min(p.x, q.x) < rect.x + rect.width
      && Math.max(p.y, q.y) > rect.y
      && Math.min(p.y, q.y) < rect.y + rect.height;
  }

  // Half a length, kept on the grid. Every box this is asked about is an even number of grid units
  // wide, so the answer is exact; it is written as a rounding only so that a host whose arrangement
  // produced an odd one loses 2px of centring rather than the grid.
  function half4(value) {
    return GRID * Math.round(value / (2 * GRID));
  }

  // ===========================================================================
  // Emission.
  //
  // This is where the module stops reasoning about a drawing and starts producing markup, so it is
  // also where the threat model changes. Everything above operates on strings the parser already
  // put through mermaid's sanitizer; below, those strings are being written into a document. `esc`
  // is applied to every one of them without exception -- label text, node ids, class tokens derived
  // from ids, and every attribute value -- and it replaces `& < > " '` with character references.
  // Nothing else is honoured: `A["<b>bold</b>"]` draws the angle brackets. The single exception is
  // `<br/>`, and it is not honoured as markup either -- shapeLabel recognised it as a line break
  // before any of this ran, so what reaches here is already separate lines.
  //
  // The rest of RENDERER-SPEC.md §6 is structural and holds because there is no code here that
  // could break it: no element outside the fixed set below is ever written, no attribute name is
  // ever computed, and the only url() this emits names a marker id it generated itself.
  // ===========================================================================

  function esc(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // The one place a source's own bytes reach a style attribute, so the value is validated against a
  // grammar rather than escaped: escaping would keep `expression(...)` intact and merely spell it
  // safely. A declaration that does not match is dropped whole and the node keeps its rung.
  var STYLE_SHAPE_PROPS = "fill stroke stroke-width stroke-dasharray".split(" ");
  var STYLE_OUTLINE_PROPS = "stroke stroke-width stroke-dasharray".split(" ");
  // `fill` is deliberately absent. A `linkStyle` carrying one would fill the area an open path
  // encloses -- mermaid's flowchart edges are `fill: none` for exactly that reason -- and inline
  // beats the stylesheet, so honouring it would paint a solid wedge under an elbow.
  var STYLE_EDGE_PROPS = "stroke stroke-width stroke-dasharray".split(" ");
  var STYLE_TEXT_PROPS = "color".split(" ");
  var STYLE_VALUE = /^(?:#[0-9a-fA-F]{3,8}|rgba?\([0-9.,%\s]+\)|[a-zA-Z]+|[0-9]+(?:\.[0-9]+)?(?:px|em|rem|%)?|[0-9]+(?:\.[0-9]+)?(?:\s*,\s*[0-9]+(?:\.[0-9]+)?)+)$/;
  var STYLE_FORBIDDEN = /[;{}<>]|url\s*\(|expression\s*\(|\/\*/i;

  function splitDeclaration(text) {
    var raw = String(text === undefined || text === null ? "" : text);
    var at = raw.indexOf(":");
    if (at < 0) return null;
    var prop = raw.slice(0, at).trim().toLowerCase();
    var value = raw.slice(at + 1).trim();
    if (value.slice(-11).toLowerCase() === "!important") value = value.slice(0, -11).trim();
    if (!prop.length || !value.length) return null;
    if (STYLE_FORBIDDEN.test(prop) || STYLE_FORBIDDEN.test(value)) return null;
    if (!STYLE_VALUE.test(value)) return null;
    return { prop: prop, value: value };
  }

  function styleAttribute(declarations, allowed, rename) {
    var kept = [];
    for (var i = 0; i < declarations.length; i += 1) {
      var d = splitDeclaration(declarations[i]);
      if (!d) continue;
      if (allowed.indexOf(d.prop) === -1) continue;
      // `!important` is not decoration here: mermaid writes author styles that way and the live
      // label-contrast pass reads `style="fill:…"` off the shape to learn that a person chose it
      // (flowpeek-glue.js:260-265). A class would make it blind, which is why RENDERER-SPEC.md §4.2
      // puts author colour inline.
      kept.push((rename && rename[d.prop] ? rename[d.prop] : d.prop) + ":" + d.value + " !important");
    }
    return kept.length ? ' style="' + esc(kept.join(";")) + '"' : "";
  }

  function authorDeclarations(db, node) {
    var decls = (node.styles || []).slice();
    var names = ["default", "node"].concat(node.classes || []);
    return decls.concat(db.getCompiledStyles(names));
  }

  // Scoping the theme's stylesheet to this diagram's own root, the way mermaid does, so two
  // previews in one page cannot style each other. Comments go first because a `{` inside one would
  // otherwise be read as the start of a block; at-rules that carry nested rules are recursed into,
  // and anything else beginning with `@` is dropped -- `@import` is the hazard the glue's
  // STYLE_HAZARDS names, and none of the app's own CSS uses one.
  function prefixCSS(css, scope) {
    var text = String(css || "").replace(/\/\*[\s\S]*?\*\//g, "");
    var out = [];
    var i = 0;
    while (i < text.length) {
      var open = text.indexOf("{", i);
      if (open < 0) break;
      var selector = text.slice(i, open).trim();
      var depth = 1;
      var j = open + 1;
      while (j < text.length && depth > 0) {
        if (text.charAt(j) === "{") depth += 1;
        else if (text.charAt(j) === "}") depth -= 1;
        j += 1;
      }
      var body = text.slice(open + 1, j - 1);
      i = j;
      if (!selector.length) continue;
      if (selector.charAt(0) === "@") {
        if (/^@(media|supports|layer)\b/i.test(selector)) {
          out.push(selector + "{" + prefixCSS(body, scope) + "}");
        }
        continue;
      }
      var parts = selector.split(",");
      var scoped = [];
      for (var p = 0; p < parts.length; p += 1) {
        var one = parts[p].trim();
        if (one.length) scoped.push(scope + " " + one);
      }
      if (scoped.length) out.push(scoped.join(",") + "{" + body.trim() + "}");
    }
    return out.join("\n");
  }

  // A font stack is the one theme value that is not a colour, so it needs its own grammar: a family
  // name, a quote, a comma and the separators between them. Nothing else, because this string is
  // interpolated straight into a declaration and a `;` or a `}` in it would close the rule and open
  // whatever came next. The payload is app-authored today; "app-authored" is a fact about the
  // caller rather than a property of the input, and this is the only place it is relied on.
  var FONT_STACK = /^[A-Za-z0-9 '",.\-]+$/;

  function safeFamily(name) {
    var raw = String(name === undefined || name === null ? "" : name).trim();
    return FONT_STACK.test(raw) ? raw : "sans-serif";
  }

  // The named allowlist of RENDERER-SPEC.md §4.1 and nothing else. Each value goes through the same
  // grammar an author's declaration does: these arrive on the wire from the app, but "app-authored"
  // is a fact about today's caller rather than a property of the input.
  function themeColour(variables, names, fallback) {
    for (var i = 0; i < names.length; i += 1) {
      var raw = variables[names[i]];
      if (typeof raw !== "string" || !raw.length) continue;
      if (STYLE_FORBIDDEN.test(raw) || !STYLE_VALUE.test(raw.trim())) continue;
      return raw.trim();
    }
    return fallback;
  }

  // The generated half of the stylesheet: structure and the seven roles §4.1 names, and not one
  // colour this file chose. Every rung, every accent and every dash that carries meaning is left to
  // the theme's own CSS, which is appended after this and wins on specificity -- one palette, in
  // MacMermaidTheme.swift, reaching both renderers.
  function baseStylesheet(scope, theme, fontFamily) {
    var v = theme.variables;
    var nodeBorder = themeColour(v, ["nodeBorder"], "#333333");
    var nodeFill = themeColour(v, ["mainBkg"], "#ECECFF");
    var nodeText = themeColour(v, ["nodeTextColor", "primaryTextColor"], "#333333");
    var lineColor = themeColour(v, ["lineColor"], "#333333");
    var labelBkg = themeColour(v, ["edgeLabelBackground"], "#FFFFFF");
    var clusterFill = themeColour(v, ["clusterBkg"], "none");
    var clusterBorder = themeColour(v, ["clusterBorder"], "#333333");
    var size = theme.fontSizePX;
    var s = scope + " ";
    return [
      s + "text{font-family:" + fontFamily + ";font-size:" + size + "px}",
      s + ".node rect,"
        + s + ".node circle,"
        + s + ".node ellipse,"
        + s + ".node polygon,"
        + s + ".node path{fill:" + nodeFill + ";stroke:" + nodeBorder + ";stroke-width:1px}",
      s + ".node .label text,"
        + s + ".nodeLabel{fill:" + nodeText + ";font-weight:600}",
      s + ".cluster rect{fill:" + clusterFill + ";stroke:" + clusterBorder + ";stroke-width:0.8px}",
      s + ".flowchart-link{fill:none;stroke:" + lineColor + ";stroke-width:1px}",
      // Mermaid ships this rule in its own stylesheet; this renderer emits no mermaid stylesheet,
      // so the pattern class it writes has to mean something here or `-.->` would draw solid.
      s + ".flowchart-link.edge-pattern-dotted{stroke-dasharray:3,3}",
      // SKILL.md §6 rule 5's declared exception: an edge with no clear orthogonal route is dashed
      // to say "transit, not interaction". A stroke pattern, not a colour -- the palette stays in
      // MacMermaidTheme.swift.
      s + ".flowchart-link.fp-transit{stroke-dasharray:4,3}",
      s + ".edgeLabel rect.background{fill:" + labelBkg + ";stroke:none}",
      s + ".edgeLabel text{fill:" + nodeText + "}",
      s + "marker path,"
        + s + "marker circle{fill:" + lineColor + ";stroke:" + lineColor + "}",
      // An open cross has no interior; filling it would paint the triangle between its arms.
      s + "marker path.cross{fill:none;stroke-width:1.4}"
    ].join("\n");
  }

  // ---------------------------------------------------------------------------
  // Elements.
  //
  // One function per element type, assembling by concatenation, which is what fixes the attribute
  // order: it is the order these lines are written in and there is no object whose key order could
  // drift (RENDERER-SPEC.md §5.8).
  // ---------------------------------------------------------------------------

  function tspans(lines, lineHeight, x, anchorY) {
    var out = [];
    for (var i = 0; i < lines.length; i += 1) {
      out.push('<tspan x="' + x + '" y="' + (anchorY + i * lineHeight) + '">' + esc(lines[i]) + "</tspan>");
    }
    return out.join("");
  }

  // Where a line's baseline sits inside its line box. There is no font metric on this side of the
  // measurement callback -- it answers a box, not an ascent -- so three quarters of the line box is
  // the approximation, rounded to the grid like everything else. It is off by a pixel or two on an
  // unusual face, and it is off in the direction that keeps the text inside the box it was measured
  // into.
  function baselineIn(lineHeight) {
    return GRID * Math.round((lineHeight * 0.75) / GRID);
  }

  function polygon(points, styleAttr) {
    var parts = [];
    for (var i = 0; i < points.length; i += 1) parts.push(points[i][0] + "," + points[i][1]);
    return '<polygon class="label-container" points="' + parts.join(" ") + '"' + styleAttr + "/>";
  }

  // The fifteen sizing families shapeBox knows, drawn centred on the origin because a node is
  // positioned by `translate(cx,cy)` -- mermaid's convention, and the one the theme's selectors
  // assume. The class on each element is chosen to be one the editorial stylesheet's rung
  // selectors already name: `rect.basic`, `circle.basic`, `polygon.label-container`,
  // `path.basic.label-container`, `g.label-container circle`, and the two-path `g.outer-path`
  // whose children are painted separately (MacMermaidTheme.swift, rungCSS). An ellipse is drawn as
  // a path for that reason alone -- `ellipse` appears in no rung selector, so an <ellipse> element
  // would be the one shape the ladder could not colour.
  //
  // An author's declarations go on the element that paints, never on a <g> around it. A group's
  // style reaches its children only by inheritance, and inheritance loses to ANY rule that names
  // the child: `g.outer-path path:nth-child(1)` and `g.label-container circle` both do, so a
  // `classDef` written on the group was honoured on thirteen geometries and painted over on the
  // stadium and the double circle -- the held-out review's b01 and b18, whose green and red
  // terminals came out in the rung's grey. mermaid 11.17.2 writes the style onto each child for
  // the same reason (both of its stadium's paths and both of its double circle's circles carry it).
  function shapeMarkup(geometry, w, h, declarations) {
    var styleAttr = styleAttribute(declarations, STYLE_SHAPE_PROPS, null);
    var W = half4(w), H = half4(h);
    var K;
    switch (geometry) {
      case "round":
        // The radius value is arbitrary; its PRESENCE is not. `.node rect.basic:not([rx])` is what
        // separates `[rect]` from `(round)` in the theme (MacMermaidTheme.swift:323-325), so this
        // attribute is a shape cue rather than a decoration. 8 rather than the 5 mermaid writes:
        // 5 is not a grid step and every other number in this file is.
        return '<rect class="basic label-container" x="' + (-W) + '" y="' + (-H) + '" width="' + w
          + '" height="' + h + '" rx="8" ry="8"' + styleAttr + "/>";
      case "stadium":
        K = Math.min(W, H);
        var pill = "M" + (-W + K) + "," + (-H)
          + " L" + (W - K) + "," + (-H)
          + " A" + K + "," + K + " 0 0 1 " + (W - K) + "," + H
          + " L" + (-W + K) + "," + H
          + " A" + K + "," + K + " 0 0 1 " + (-W + K) + "," + (-H) + " Z";
        // Two paths, fill then outline, inside a <g class="outer-path">: the theme paints
        // `:nth-child(1)` and `:nth-child(2)` differently because one element carrying both would
        // stroke the fill and double-paint the edge.
        //
        // The author's declarations are split the same way rather than written whole onto both,
        // which is what mermaid does: the value grammar admits `rgba()`, and a translucent fill
        // laid on both paths composites twice and comes out darker than the colour asked for.
        return '<g class="basic label-container outer-path">'
          + '<path d="' + pill + '"' + styleAttribute(declarations, ["fill"], null) + "/>"
          + '<path d="' + pill + '"' + styleAttribute(declarations, STYLE_OUTLINE_PROPS, null) + "/></g>";
      case "circle":
        return '<circle class="basic label-container" cx="0" cy="0" r="' + W + '"' + styleAttr + "/>";
      case "doublecircle":
        // Both rings take the whole style, because the theme paints both whole: they are two
        // filled-and-stroked circles, not a fill and an outline.
        return '<g class="basic label-container">'
          + '<circle cx="0" cy="0" r="' + W + '"' + styleAttr + "/>"
          + '<circle cx="0" cy="0" r="' + Math.max(GRID, W - 4) + '"' + styleAttr + "/></g>";
      case "ellipse":
        return '<path class="basic label-container" d="M' + (-W) + ",0 A" + W + "," + H + " 0 1 0 " + W
          + ",0 A" + W + "," + H + " 0 1 0 " + (-W) + ',0 Z"' + styleAttr + "/>";
      case "diamond":
        return polygon([[0, -H], [W, 0], [0, H], [-W, 0]], styleAttr);
      case "hexagon":
        K = Math.min(W, H);
        return polygon([[-W + K, -H], [W - K, -H], [W, 0], [W - K, H], [-W + K, H], [-W, 0]], styleAttr);
      case "cylinder":
        // A bare <path class="…outer-path">, and the tagName is load-bearing: a cylinder and a
        // stadium carry the same classes, and `path` versus `g` is the whole discriminator the
        // glue's own store rule reads (flowpeek-glue.js:697-700).
        //
        // All three sweep flags are 1, 1, 0 and each was the other way round until a cylinder was
        // rendered and looked at. A sweep of 0 from the left end to the right one is the negative
        // angle direction, which in SVG's y-down frame arcs DOWNWARDS -- so both of the body's arcs
        // bowed into the box: the lid sagged 16px into the label at its crest and the base rose the
        // same, and an 80x64 cylinder came back 48px tall with a concave floor. shapeBox is the
        // witness that this was never the intent: it adds 4 units to a cylinder's height, which is
        // exactly the two K=8px lids, and a lid only takes room if it bulges OUT. The rim keeps the
        // opposite flag to the lid it sits under, which is what makes it the near edge of that lid
        // instead of a second outline drawn over the top of the first.
        //
        // And the rim is drawn right to left, against the body's direction, so that the crescent it
        // closes winds the same way the body does. Drawn the other way it winds against it, the
        // nonzero fill rule cancels the two, and the lid comes back with a hole across it -- which
        // is what the first cut of this rendered: a white sliver under the top arc.
        K = Math.min(8, H);
        return '<path class="basic label-container outer-path" d="M' + (-W) + "," + (-H + K)
          + " A" + W + "," + K + " 0 0 1 " + W + "," + (-H + K)
          + " L" + W + "," + (H - K)
          + " A" + W + "," + K + " 0 0 1 " + (-W) + "," + (H - K) + " Z"
          + " M" + W + "," + (-H + K) + " A" + W + "," + K + " 0 0 1 " + (-W) + "," + (-H + K) + '"'
          + styleAttr + "/>";
      case "subroutine":
        return '<path class="basic label-container" d="M' + (-W) + "," + (-H) + " L" + W + "," + (-H)
          + " L" + W + "," + H + " L" + (-W) + "," + H + " Z"
          + " M" + (-W + 8) + "," + (-H) + " L" + (-W + 8) + "," + H
          + " M" + (W - 8) + "," + (-H) + " L" + (W - 8) + "," + H + '"' + styleAttr + "/>";
      case "lean-r":
        K = Math.min(W, H);
        return polygon([[-W + K, -H], [W, -H], [W - K, H], [-W, H]], styleAttr);
      case "lean-l":
        K = Math.min(W, H);
        return polygon([[-W, -H], [W - K, -H], [W, H], [-W + K, H]], styleAttr);
      case "trap-t":
        K = Math.min(W, H);
        return polygon([[-W + K, -H], [W - K, -H], [W, H], [-W, H]], styleAttr);
      case "trap-b":
        K = Math.min(W, H);
        return polygon([[-W, -H], [W, -H], [W - K, H], [-W + K, H]], styleAttr);
      case "odd":
        K = Math.min(8, W);
        return polygon([[-W, -H], [W, -H], [W, H], [-W, H], [-W + K, 0]], styleAttr);
      default:
        // No rx at all. The theme rounds a bare rect to 6px through `:not([rx])`, and writing the
        // attribute here would opt this shape out of that rule and flatten the one cue mermaid's
        // rect family has.
        return '<rect class="basic label-container" x="' + (-W) + '" y="' + (-H) + '" width="' + w
          + '" height="' + h + '"' + styleAttr + "/>";
    }
  }

  // RENDERER-SPEC.md §7.3, emitted at the final geometry rather than reshaped afterwards.
  // EditorialArrowheadTests finds this by the `-pointEnd` id suffix and asserts every number in it
  // plus the literal path.
  var MARKER_SHAPES = {
    pointEnd: '<path d="M 0 0 L 8 3 L 0 6 z"/>',
    pointStart: '<path d="M 8 0 L 0 3 L 8 6 z"/>',
    circleEnd: '<circle cx="4" cy="4" r="3"/>',
    circleStart: '<circle cx="4" cy="4" r="3"/>',
    crossEnd: '<path class="cross" d="M 1 1 L 7 7 M 7 1 L 1 7"/>',
    crossStart: '<path class="cross" d="M 1 1 L 7 7 M 7 1 L 1 7"/>'
  };

  function markerMarkup(id, name, className) {
    // A triangle is 8x6 and reads at its point; a ring and a cross need a square box to stay round
    // and symmetric.
    //
    // Two attributes here were wrong in the first cut and both showed in the drawing.
    //
    // `markerUnits` is userSpaceOnUse, not the default strokeWidth. Left to scale with the stroke,
    // one arrowhead is 8x1.2 = 9.6px on an ordinary edge and 8x2 = 16px on the accent one, so the
    // accent head came out two thirds larger than its neighbours for no reason anybody could read,
    // and five edges fanned onto one 112px face at the 12px port pitch rule 4 asks for had their
    // heads touching. The source specifies one arrowhead and gives it in absolute units;
    // userSpaceOnUse is what makes 8x6 mean 8x6.
    //
    // And refX is the tip, not the centre. The router ends an edge exactly on the node's boundary,
    // so a reference point in the middle of the box buries the front half of the head under the
    // node, which is painted after it -- rendered and looked at, every arrow in all five sample
    // diagrams was a flat-ended trapezoid rather than a triangle. mermaid gets away with a centred
    // refX because it clips its edges short of the boundary; ours do not, so the tip is what has to
    // land on the endpoint. The skill's own marker sits one unit proud at refX 7; 8 puts the point
    // on the border instead of through it, which is what the boxes here are drawn to.
    var w = 8;
    var h = (name.indexOf("point") === 0) ? 6 : 8;
    // A ring and a cross are terminators that sit ON the endpoint rather than pointing at it, so
    // they keep the centre they are symmetric about. A start head is the same triangle drawn the
    // other way round -- its point is at x=0, which is where its reference has to be.
    var refX = w / 2;
    if (name === "pointEnd") refX = w;
    else if (name === "pointStart") refX = 0;
    return '<marker id="' + esc(id) + '" class="' + className + '" viewBox="0 0 ' + w + " " + h
      + '" markerWidth="' + w + '" markerHeight="' + h + '" refX="' + refX + '" refY="' + (h / 2)
      + '" orient="auto" markerUnits="userSpaceOnUse">' + MARKER_SHAPES[name] + "</marker>";
  }

  var ARROW_MARKERS = {
    arrow_point: "point",
    arrow_circle: "circle",
    arrow_cross: "cross"
  };

  // ---------------------------------------------------------------------------
  // The document.
  //
  // Painters order is a contract, not a preference (RENDERER-SPEC.md §8.5). `paperUnder` in the
  // live label pass walks ancestors and scans EARLIER siblings for the fill beneath a label, so
  // clusters first means a zone rect never covers what it contains, edges before nodes puts every
  // stroke behind the boxes it joins -- dd-arch.md's "draw arrows before boxes" -- and nodes last
  // means a node's own fill is what the contrast pass finds under its own label.
  // ---------------------------------------------------------------------------

  var MAX_NODES = 5000;
  var MAX_EDGES = 2000;
  var RENDER_ID = /^[A-Za-z][A-Za-z0-9_-]*$/;
  // The same marker the glue gates its editorial passes on (flowpeek-glue.js:455). Without it the
  // active theme has no `.fp-` rules, so every rung this file tags would be invisible and the
  // drawing would be worse than mermaid's rather than different from it.
  var LADDER_MARKER = ".fp-ladder";
  var CLOSE_STYLE = /<\s*\/\s*style/i;
  var STYLE_HAZARDS = /@import|url\s*\(\s*['"]?(?!#)|expression\s*\(|<\s*\/?\s*script/i;

  function noteWarning(list, slug) {
    if (list.indexOf(slug) === -1) list.push(slug);
  }

  function emit(db, drawing, theme, renderID) {
    var warnings = drawing.warnings.slice();
    var scope = "#" + renderID;
    var fontFamily = safeFamily(theme.fontFamily);
    var i;

    var boxById = new Map();
    var parentOf = new Map();
    for (i = 0; i < drawing.nodes.length; i += 1) {
      boxById.set(drawing.nodes[i].id, drawing.nodes[i]);
      parentOf.set(drawing.nodes[i].id, drawing.nodes[i].parent);
    }
    for (i = 0; i < drawing.clusters.length; i += 1) parentOf.set(drawing.clusters[i].id, drawing.clusters[i].parent);

    var ctx = {
      boxes: drawing.nodes,
      // Borders a stroke has to stay clear of without being kept out of what they enclose.
      rails: drawing.clusters,
      // Every node's and zone's containing zone, so a route can tell the zones it belongs in from
      // the ones it is only passing (`foreignZones`).
      parentOf: parentOf,
      foreign: new Map(),
      // The same objects, by the id an edge names its ends with, so the route check can tell the
      // box a port is attached to from the ones it has to stay off. An end that names a subgraph
      // finds nothing here, which is correct: a zone rect is not among the boxes either.
      boxById: boxById,
      drawn: [],
      labelRects: [],
      titleRooms: [],
      bumpRooms: [],
      width: drawing.width,
      height: drawing.height
    };
    // The zone eyebrows are in the label set before any edge label is placed, so an edge label
    // cannot land on a subgraph's title. They are not obstacles for the strokes: a connector
    // entering a zone has to cross the zone, and the zone rect is painted first, so it is behind
    // everything either way. The rect object is kept rather than copied, because `slideTitle` moves
    // it after routing and the edge labels have to see where the title actually ended up.
    var titles = [];
    for (i = 0; i < drawing.clusters.length; i += 1) {
      var cl = drawing.clusters[i];
      if (cl.labelWidth > 0) {
        var titleRect = { x: cl.labelX, y: cl.labelY, width: cl.labelWidth, height: cl.labelHeight };
        ctx.labelRects.push(titleRect);
        titles.push({ cluster: cl, rect: titleRect });
        var near = titleNear(cl.labelX, cl);
        near.zone = cl;
        ctx.titleRooms.push(near);
      }
    }

    // --- routing, in source order so the output is a function of the source alone ---
    //
    // Every edge is routed before any label is placed, and the two passes are in that order rather
    // than interleaved because the dependency only runs one way. A label can move; a route, once
    // its ports and lanes are fixed, cannot. Interleaving made routing dodge the masks of edges
    // that happened to come earlier in the source, which cost real lane separation to buy a label
    // position the second pass can find for itself with the whole drawing in front of it.
    var routed = [];
    var markers = new Map();
    for (i = 0; i < drawing.edges.length; i += 1) {
      var edge = drawing.edges[i];
      // `~~~` asks for the layout constraint without the line. Emitting a path with no stroke would
      // put an invisible element in the way of every geometric assertion downstream for no gain.
      if (edge.pattern === "invisible") { routed.push(null); continue; }
      var route = routeEdge(edge, ctx);
      if (route.transit) noteWarning(warnings, "edge-transit");
      else if (route.crowded) noteWarning(warnings, "edge-crowded");
      // Before the strokes are recorded, so that what the next edge routes around is what this one
      // actually draws, and before `bridgeCrossings`, which reads the finished points.
      // Shortcuts first: a detour removed outright takes its jogs with it, and what is left for
      // `closeUnitJogs` is the jogs that are actually load-bearing.
      // Not a self-loop. Its two ports are on one box and often share a coordinate, so the
      // straight run between them is both clear and wrong: the loop IS the detour, and
      // `alignUnitJog` refuses to touch one for the same reason. Caught by the self-loop test,
      // which asks for two distinct ports and three right angles and got a line.
      if (!edge.selfLoop) {
        route.points = straightenDetours(route.points, ctx, edge);
        route.points = closeUnitJogs(route.points, ctx, edge);
      }
      for (var s = 0; s + 1 < route.points.length; s += 1) {
        ctx.drawn.push([route.points[s], route.points[s + 1]]);
      }
      routed.push({ edge: edge, points: route.points, transit: route.transit, label: null });

      var head = ARROW_MARKERS[edge.arrowEnd];
      var tail = ARROW_MARKERS[edge.arrowStart];
      if (head) markers.set(head + "End", true);
      if (tail) markers.set(tail + "Start", true);
      if (edge.kind && head === "point") markers.set("fp-" + edge.kind, true);
    }

    // After every route exists, because a braid is a fact about two finished routes. `ctx.drawn`
    // is rebuilt from the result: the label pass tells a route's own legs from a rival's by the
    // identity of the point objects, so it has to hold the arrays the routes now carry.
    //
    // `orderCorridors` runs on both sides of `uncrossPairs`. Before it, so that the trades are
    // judged against lanes already nested: a trade is kept when it lowers crossings from where the
    // routes stand, and where two routes into one face stood in the wrong lanes that was a knot the
    // next pass would have untied for nothing. The third held-out set's b11 showed it. Quit to
    // title and Credits -> Title crossed twice in the gap before Title; trading their ports took
    // that to one and was kept, and the corridors pass, which nests them with no crossing at all
    // from the ports they had, then found the ports inverted and could do nothing. After it, as
    // before, because a swap or a trade can leave a face's lanes out of order again.
    //
    // Rejected: refusing a port trade that leaves its two routes crossing. It brings back the
    // braids the trades were added for -- pairs crossing twice over SWEEP, the review sources and
    // both held-out sets went from 3 to 6 -- because it also refuses trades like b11's Esc / Boss
    // defeated, which leaves that pair crossing once where it crossed twice.
    //
    // The corridors pass may give a refused nest a free lane (`orderCorridors`), and it keeps one
    // when the nest leaves fewer crossings where the routes then stand -- but the passes after it
    // start from what it kept, and a nest they would have done better without is not undone. Over
    // 3,000 distinct random DAGs of six to twelve nodes, 163 had a nest refused this way, and
    // taking the free lane wherever it helped on the spot left 7 of them with more crossings at the
    // end than without it, one going from 3 to 8: uncrossPairs and roomForBridges had untied the
    // refused drawing, and could not untie the nested one. So where a free lane was taken, the
    // four passes are run again from the same routes with free lanes refused, and the free lanes
    // are kept only if they end with strictly fewer crossings and no more stretches on or beside
    // another route's line. The second half is not idle: in one of the 163, `roomForBridges`,
    // starting from a free lane, slid N2 -> N4's run onto N3 -> N6's line. With both, none of the
    // 163 draws more crossings than at bbfbea3, 55 draw fewer, and their drawn crossings go from
    // 646 to 587. It costs those drawings a second run of the four passes and no other drawing
    // anything; on a tie the drawing is the one it was.
    var untangledFrom = routed.map(function (r) { return r ? r.points : null; });
    if (untangle(true) > 0) {
      var withFree = routed.map(function (r) { return r ? r.points : null; });
      var tangledFree = tangleOfRoutes(routed);
      for (i = 0; i < routed.length; i += 1) if (routed[i]) routed[i].points = untangledFrom[i];
      untangle(false);
      var tangled = tangleOfRoutes(routed);
      if (tangledFree.crossed < tangled.crossed && tangledFree.doubled <= tangled.doubled) {
        for (i = 0; i < routed.length; i += 1) if (routed[i]) routed[i].points = withFree[i];
      }
    }
    function untangle(free) {
      var n = orderCorridors(routed, ctx, free);
      uncrossPairs(routed, ctx);
      n += orderCorridors(routed, ctx, free);
      roomForBridges(routed, ctx);
      return n;
    }
    ctx.drawn = [];
    for (i = 0; i < routed.length; i += 1) {
      if (!routed[i]) continue;
      for (var ds = 0; ds + 1 < routed[i].points.length; ds += 1) {
        // Which edge drew it, for `facesSibling`: the label pass asks whose line a plate faces.
        var drawnPair = [routed[i].points[ds], routed[i].points[ds + 1]];
        drawnPair.edge = routed[i].edge;
        ctx.drawn.push(drawnPair);
      }
    }

    // Between the two passes on purpose: every stroke is drawn by now, which is what the title has
    // to dodge, and no edge label is placed yet, which is what has to dodge the title.
    for (i = 0; i < titles.length; i += 1) {
      var home = titles[i].cluster.labelX;
      slideTitle(titles[i].cluster, titles[i].rect, ctx);
      titles[i].room = roomAt(home, titles[i].cluster, ctx, routed);
      // A title slid further than its own inset, where the band could have moved less. A title
      // carried along its band stops reading as the zone's name and reads as a label floating in
      // it: the sixth held-out review measured h14's "AZ us-east-1b" inset 52 where its siblings
      // sit at 16, and h07's "ODS 原始数据层" stood at 80. The room moves the contents instead --
      // down by a lane's depth under the title, across by half what the band is widened, since
      // they stay centred in it -- and it is taken when that is the smaller move. Where a line runs
      // through a long title near its start the slide is: reelect.mmd's 260px title in a 568px
      // zone, crossed 76px in, would need the drawing 352px wider to stay home.
      var slid = titles[i].cluster.labelX - home;
      var r = titles[i].room;
      var moves = r ? Math.max(r.lane ? titles[i].cluster.laneDepth : 0, r.lane ? 0 : r.wide / 2) : 0;
      if (slid > home - titles[i].cluster.x && r && r.helps && moves < slid) {
        titles[i].cluster.labelX = home;
        titles[i].rect.x = home;
      }
    }
    // Which titles a stroke still crosses once every title has slid as far as it should, and what
    // room would clear it -- the layout's to give, on a second pass (`titleRoom`). A crossing ALONG
    // the band asks for a lane under the title; one ACROSS it asks for the band to widen until the
    // title, at home, ends a gap short of the line. Where both happen it is one route's turn into a
    // first-row node, whose last leg drops across the title's foot, and the lane alone removes
    // both, so the width is not asked for.
    var struck = {};
    for (i = 0; i < titles.length; i += 1) {
      var tc = titles[i].cluster;
      // A struck title is at its home: `slideTitle` leaves it there when nothing clears, and the
      // loop above puts it back there when the band should move instead.
      if (titleIsClear(tc.labelX, tc, ctx)) continue;
      struck[tc.id] = { lane: titles[i].room.lane, wide: titles[i].room.wide };
    }
    for (var sz in struck) {
      if (Object.prototype.hasOwnProperty.call(struck, sz) && struck[sz].lane) struck[sz].wide = 0;
    }

    // In source order, each label seeing the masks placed before it and not the ones after --
    // greedy, which is the shape that usually means the last label gets the leavings.
    //
    // It does not mean that here, and the reason is structural rather than lucky. Ownership is the
    // property this pass exists to get right, and the ownership term compares the plate against
    // STROKES: every route is drawn before any label is placed, so what it measures is the same for
    // the first mask and the last. Only the collision terms see the other masks, and over the
    // 53-source corpus they never bind hard enough to matter -- re-offering every label the
    // finished drawing with its own mask lifted out, and moving it on any improvement at all,
    // moved no mask at all and changed not one byte of the 53 SVGs. That second pass was written,
    // run, and taken back out: it cost 56% of the render time (39ms a corpus pass against 25) to
    // confirm a fixed point the first pass already lands on.
    //
    // It was not always so. While ambiguity was scored as a verdict rather than as a margin -- a
    // flat 40 for "a rival is at least as near" -- the repair pass DID move masks, and nego.mmd
    // needed it: "negotiate(adjustRate, self)" came out of the greedy pass 8px from its own
    // connector and flush against a different one. The gradient is what removed the need for it.
    //
    // Then one convention per drawing where that is free. The placer chooses ON or BESIDE label by
    // label, and a reader does not: the second visual review read 01 as two conventions in one
    // picture -- Valid?'s two labels interrupting their lines while In stock?'s hung in the gutter
    // -- and 09 as two under ONE diamond. Measured over the review's 16 sources (44 labels) and
    // differential.mjs's 175 drawings (40 labels), 4 and 7 drawings mixed the two.
    //
    // Rejected: all ON wherever any is. Every label that came out BESIDE did so because ON harmed
    // something -- BESIDE pays 8 and any harm on ON costs 10 or more -- so forcing them on costs
    // exactly that harm, and placements with none fell from 43 to 36 of 44 and from 39 to 23 of 40.
    // Also rejected: all BESIDE wherever any is. It holds 43 and 39, but it is f5e4b8e taken back on
    // every drawing that has a single crowded label: on-line 33 -> 22 of 44, and 16 and 12, whose
    // labels the same review found sitting on their lines, would float again for one exception each.
    //
    // So the drawing follows its majority, and only in the direction that is free. Where at least
    // half the labels are already BESIDE, the rest are offered BESIDE too and take it if it is
    // clean, keeping ON otherwise; where most are ON, the exceptions stay exceptions, since moving
    // them is the harm above. And the second pass is kept only if it leaves no label ON: one that
    // still has to stay ON means the picture mixes anyway, and the plates it moved were spent on
    // nothing -- the first cut kept such a pass, and on render.spec.js's 7-line LR drawing it took
    // one of three plates off its line and left the picture exactly as mixed. Measured: 43/44 and 39/40 unchanged, drawings mixing 4 -> 2 and 7 -> 3, on-line
    // 33 -> 30 of 44 and 16 -> 8 of 40. The two review drawings still mixing are 12 and 16, each one
    // BESIDE among ON labels, whose ON would cost 30 and 10.
    //
    // And then one repair the greedy order does need: a label whose every seat costs something may
    // ask an EARLIER plate near its route to move. The order is source order, so the earlier label
    // took the best seat it saw without knowing a later one had no other. In h04 "supervision
    // timeout" sat ON the one vertical leg between its exits, which was free, and left "DFU request"
    // -- whose run lies 12px under a sibling on each side -- three seats: flush against that plate
    // (50), flush against OTA update's box (100), or ON with "CRC error"'s line along its edge, which
    // `parallelUnder` charges 40 of a 60. It took the 50 and the two plates printed as one strip.
    // Placed the other way round, "DFU request" stands clear above its line (8) and "supervision
    // timeout" sits ON its last run (10): 18 against 58. So each such pair is placed again in the
    // other order, against every other plate, and kept only if the two together cost less.
    //
    // Pairs, not the whole drawing again: the full second pass the note above measured cost 56% of
    // the render time to move nothing. A pair is tried only for a label that scored above zero, only
    // if the seat it would take with the earlier plates near its route lifted out is cheaper than
    // the one it has, and only with a plate that stands in that seat or within a gap of it. "Near"
    // is the label's own extent and two gaps from the route, as far as any of its seats can reach.
    // Measured: the 216-drawing sweep and the held-out twenty render in 174ms a pass against 152,
    // and change in h04 and h02 alone -- h02's "rotated refresh token" gets its line back the same
    // way, from the plate of "Bearer header" above it. Over 600 random labelled state machines,
    // drawings with two plates within 4px went 40 -> 16 with `rectsMeet` and this together.
    // Rejected: charging a meeting at 200 alone. It is the right price, but in h04 it only hands
    // "DFU request" its 60 -- the plate back over the CRC line that `9e12b12` took it off.
    var titleRects = ctx.labelRects.slice();
    ctx.bumpRooms = bumpRooms(routed, ctx);
    function placeOne(r, besideOnly) {
      var placed = besideOnly ? placeEdgeLabel(r.edge, r.points, ctx, r.transit, true) : null;
      // A BESIDE seat facing a sibling is not the clean seat that pass is for; see `facesSibling`.
      if (!placed || placed.crowded || placed.faces) placed = placeEdgeLabel(r.edge, r.points, ctx, r.transit);
      return placed;
    }
    function platesBut(a, b) {
      var out = titleRects.slice();
      for (var k = 0; k < routed.length; k += 1) {
        if (k === a || k === b || !routed[k] || !routed[k].label) continue;
        out.push(routed[k].label.rect);
      }
      return out;
    }
    function reorderPairs(besideOnly) {
      for (var li = 0; li < routed.length; li += 1) {
        var late = routed[li] && routed[li].label;
        if (!late || late.penalty === 0) continue;
        var pts = routed[li].points;
        var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (var pi = 0; pi < pts.length; pi += 1) {
          x0 = Math.min(x0, pts[pi].x); y0 = Math.min(y0, pts[pi].y);
          x1 = Math.max(x1, pts[pi].x); y1 = Math.max(y1, pts[pi].y);
        }
        var reach = Math.max(late.rect.width, late.rect.height) + 2 * LABEL_GAP_PX;
        var around = { x: x0 - reach, y: y0 - reach, width: x1 - x0 + 2 * reach, height: y1 - y0 + 2 * reach };
        // The seat it would take with no earlier plate near its route. No better, and nothing an
        // earlier plate could give up would help, so no pair is tried.
        ctx.labelRects = titleRects.slice();
        for (var oi = 0; oi < routed.length; oi += 1) {
          var other = oi !== li && routed[oi] && routed[oi].label;
          if (other && (oi > li || !rectsOverlap(around, other.rect))) ctx.labelRects.push(other.rect);
        }
        var free = placeOne(routed[li], besideOnly);
        if (!free || free.penalty >= late.penalty) continue;
        var wanted = {
          x: free.rect.x - LABEL_GAP_PX, y: free.rect.y - LABEL_GAP_PX,
          width: free.rect.width + 2 * LABEL_GAP_PX, height: free.rect.height + 2 * LABEL_GAP_PX
        };
        for (var ei = 0; ei < li; ei += 1) {
          var early = routed[ei] && routed[ei].label;
          if (!early || !rectsOverlap(around, early.rect) || !rectsOverlap(wanted, early.rect)) continue;
          ctx.labelRects = platesBut(li, ei);
          var lateNew = placeOne(routed[li], besideOnly);
          if (!lateNew) continue;
          ctx.labelRects.push(lateNew.rect);
          var earlyNew = placeOne(routed[ei], besideOnly);
          // The plate that was there first moves only to a seat no worse than its own or than a
          // clean one -- a stroke within the gap or a head at the plate's end, the 10 that the
          // cheapest real harm costs. Summed alone, the trade took render.spec.js's "found" off
          // a box (108) by putting "record missing" ON its drop with ok's line under it (38 ->
          // 60): cheaper by the weights, and the one placement that test says is never taken.
          if (earlyNew && earlyNew.penalty <= Math.max(early.penalty, 10)
            && lateNew.penalty + earlyNew.penalty < late.penalty + early.penalty) {
            routed[li].label = lateNew;
            routed[ei].label = earlyNew;
            break;
          }
        }
      }
      ctx.labelRects = platesBut(-1, -1);
    }
    function placeLabels(besideOnly) {
      ctx.labelRects = titleRects.slice();
      for (i = 0; i < routed.length; i += 1) {
        if (!routed[i]) continue;
        var placed = placeOne(routed[i], besideOnly);
        routed[i].label = placed;
        if (placed) ctx.labelRects.push(placed.rect);
      }
      reorderPairs(besideOnly);
    }
    // One column per field of plates. `9071d73` let a gap's plates share a place along it, so the
    // gap is shallower, but nothing put them there: each plate takes the middle of its own run,
    // nearest first, and the runs of one gap start and stop at different places, so a gap holding
    // four plates showed them at four places. The third held-out set's reviewer named it in b04,
    // b16 and b20 -- a staggered field a reader hunts through instead of reading as a list.
    //
    // So once every plate is placed, the plates on runs of one axis whose extents along that axis
    // overlap are one field, and the field is offered each place along it in turn: every plate that
    // can stand there ON its own line at no more than its seat costs takes it, and the rest are
    // seated again around them, kept only where that costs each nothing and leaves it on the same
    // kind of seat -- ON or BESIDE, on a run of the same axis. The place most plates can share
    // wins, then the cheapest, then the one nearest the field's middle. No plate pays more, so no
    // harm the score knows of is bought, and no route or box moves, so no drawing changes size.
    //
    // Measured over the review sources, both held-out sets and the sweep, by fields of two or more
    // plates that stand at more than one place or have a plate off its line: 63 of 85 -> 38 of 89
    // in the three sets and 55 of 71 -> 30 of 73 in the sweep; plates off their lines 93 and 66,
    // before and after.
    //
    // Rejected: spreading the lines so every plate has room ON its own line in the column, which is
    // what b04 needs -- its three links between 小程序前端 and 开发者服务器 run 24px apart end to
    // end, one plate's height, so the middle one has no seat beside the others. Holding faces at
    // 48px, a plate and rule 2's gap each side rounded to rule 4's 12, on every labelled face of
    // four or more ends made b04 1696 -> 1416px wide and 296 -> 368 tall (Pele 1201 x 264), and
    // `labelled returns to one face`'s Idle nearly doubled, every line jogged into its target and
    // four aligned pairs stepped. Only on a face sending three or more labelled links to one
    // neighbour: b04 1544 x 324, and a request/response exchange of b04's shape (stack.spec.js)
    // warned label-crowded LR. Two or more: b04 1416 x 384, b11 484 -> 620 tall, and four tests
    // failed -- square corners, the tangent bump and two of label ownership. Each gives the width
    // back as height, so the layout keeps its pitch.
    // Also rejected: re-seating the plates that miss the column with no condition. In b02 it put
    // LISTEN -> CLOSED's "close" ON the short vertical its line turns on, off the run it had sat
    // on, which the score allowed and the picture did not.
    function alignColumns() {
      var placed = [];
      for (var k = 0; k < routed.length; k += 1) if (routed[k] && routed[k].label) placed.push(k);
      // Fields: plates on runs of one axis whose extents along it overlap, joined transitively.
      var fieldOf = placed.map(function (_, f) { return f; });
      function root(f) { while (fieldOf[f] !== f) f = fieldOf[f]; return f; }
      function extent(l) { return l.horizontal ? [l.rect.x, l.rect.x + l.rect.width] : [l.rect.y, l.rect.y + l.rect.height]; }
      for (var a = 0; a < placed.length; a += 1) {
        for (var b = a + 1; b < placed.length; b += 1) {
          var la = routed[placed[a]].label, lb = routed[placed[b]].label;
          if (la.horizontal !== lb.horizontal) continue;
          var ea = extent(la), eb = extent(lb);
          if (ea[0] < eb[1] && eb[0] < ea[1]) fieldOf[root(a)] = root(b);
        }
      }
      var fields = new Map();
      for (a = 0; a < placed.length; a += 1) {
        var r0 = root(a);
        if (!fields.has(r0)) fields.set(r0, []);
        fields.get(r0).push(placed[a]);
      }
      fields.forEach(function (members) {
        if (members.length < 2) return;
        var labels = members.map(function (m) { return routed[m].label; });
        var centre = function (l) { return l.horizontal ? l.x : l.y; };
        var lo = Infinity, hi = -Infinity, aligned = true;
        for (var f = 0; f < labels.length; f += 1) {
          var ef = extent(labels[f]);
          lo = Math.min(lo, ef[0]);
          hi = Math.max(hi, ef[1]);
          if (!labels[f].onLine || centre(labels[f]) !== centre(labels[0])) aligned = false;
        }
        if (aligned) return;
        var others = titleRects.slice();
        for (var o = 0; o < routed.length; o += 1) {
          if (routed[o] && routed[o].label && members.indexOf(o) < 0) others.push(routed[o].label.rect);
        }
        var mid = snap4((lo + hi) / 2);
        var offers = [];
        for (var at = snap4(lo); at <= hi; at += GRID) {
          if (at < lo) continue;
          ctx.labelRects = others.slice();
          var seats = [], total = 0, count = 0;
          for (f = 0; f < members.length; f += 1) {
            var r = routed[members[f]];
            var seat = placeEdgeLabel(r.edge, r.points, ctx, r.transit, false, { horizontal: labels[f].horizontal, at: at });
            if (!seat || seat.penalty > labels[f].penalty) { seats.push(null); continue; }
            seats.push(seat); total += seat.penalty; count += 1; ctx.labelRects.push(seat.rect);
          }
          if (count >= 2) offers.push({ at: at, total: total, seats: seats, count: count });
        }
        // Most plates in the column, then the cheapest, then the nearest the middle of the field.
        offers.sort(function (x, y) { return (y.count - x.count) || (x.total - y.total) || (Math.abs(x.at - mid) - Math.abs(y.at - mid)); });
        var best = null;
        for (var c = 0; c < offers.length && !best; c += 1) {
          // The plates that cannot stand in the column are seated again around it, and the column
          // is kept only if that costs none of them anything and moves none of them on or off its
          // line or onto a run of the other axis. Asked of the best offers only, in order: it is a
          // full search per plate, and asked of every place along the field it tripled the time.
          var offer = offers[c], ok = true;
          ctx.labelRects = others.slice();
          for (f = 0; f < members.length; f += 1) if (offer.seats[f]) ctx.labelRects.push(offer.seats[f].rect);
          var final = offer.seats.slice();
          for (f = 0; f < members.length && ok; f += 1) {
            if (final[f]) continue;
            var rl = routed[members[f]], was = labels[f];
            var again = placeEdgeLabel(rl.edge, rl.points, ctx, rl.transit, false);
            if (!again || again.penalty > was.penalty || again.onLine !== was.onLine || again.horizontal !== was.horizontal) ok = false;
            else { final[f] = again; ctx.labelRects.push(again.rect); }
          }
          if (ok) best = { seats: final };
        }
        if (best) for (f = 0; f < members.length; f += 1) routed[members[f]].label = best.seats[f];
      });
      ctx.labelRects = platesBut(-1, -1);
    }
    function countOn() {
      var on = 0, all = 0;
      for (i = 0; i < routed.length; i += 1) {
        if (!routed[i] || !routed[i].label) continue;
        all += 1;
        if (routed[i].label.onLine) on += 1;
      }
      return { on: on, all: all };
    }
    placeLabels(false);
    var first = countOn();
    if (first.on > 0 && 2 * first.on <= first.all) {
      placeLabels(true);
      if (countOn().on > 0) placeLabels(false);
    }
    alignColumns();
    for (i = 0; i < routed.length; i += 1) {
      if (routed[i] && routed[i].label && routed[i].label.crowded) noteWarning(warnings, "label-crowded");
    }

    // After the labels, not before: a bridge may not land under a mask, and where the masks are is
    // only settled once every one of them has been placed.
    bridgeCrossings(routed, ctx);

    // Always defined, whatever the source asked for: EditorialArrowheadTests locates the arrowhead
    // by the `-pointEnd` id suffix, and a diagram drawn entirely with `---` would otherwise have no
    // marker for it to find and would pass by not looking.
    markers.set("pointEnd", true);

    // --- clusters ---
    //
    // Outermost first. `drawing.clusters` is innermost first, the order a container can be sized
    // in, and painting in it put a parent's rect over its children's. That was invisible while the
    // editorial stylesheet left zones unfilled; a theme that fills them by depth would have every
    // parent's wash cover the nested one, which is the depth the fill is there to show. Ties go to
    // the source index rather than to the sort's stability, as every other sort here does.
    var paintOrder = drawing.clusters.slice().sort(function (a, b) { return (a.depth - b.depth) || (a.index - b.index); });
    var clusters = [];
    for (i = 0; i < paintOrder.length; i += 1) {
      var c = paintOrder[i];
      var body = '<rect x="' + c.x + '" y="' + c.y + '" width="' + c.width + '" height="' + c.height + '"/>';
      if (c.titleLines.length) {
        // Left-anchored at the eyebrow's own box rather than centred: the layout reserved that box
        // at the container's padding, and anchoring to its own x keeps every coordinate exact
        // instead of buying a centre with a half-pixel.
        body += '<g class="cluster-label" transform="translate(' + c.labelX + "," + c.labelY + ')">'
          + '<text text-anchor="start">'
          + tspans(c.titleLines, c.lineHeight, 0, baselineIn(c.lineHeight))
          + "</text></g>";
      }
      // The nesting depth as a class, because it is the one thing a stylesheet cannot work out for
      // itself: `g.cluster` elements are flat siblings, not nested groups. Uncapped here -- how many
      // rungs a theme has is the theme's to say, in MacMermaidTheme.swift.
      clusters.push('<g class="cluster fp-depth-' + c.depth + '" id="' + esc(renderID + "-" + c.id) + '">' + body + "</g>");
    }

    // --- edges ---
    var paths = [];
    var edgeLabels = [];
    for (i = 0; i < routed.length; i += 1) {
      var r = routed[i];
      if (!r) continue;
      var e = r.edge;
      var tokens = [
        e.thickness === "thick" ? "edge-thickness-thick" : "edge-thickness-normal",
        e.pattern === "dotted" ? "edge-pattern-dotted" : "edge-pattern-solid",
        "flowchart-link"
      ];
      if (e.kind) tokens.push("fp-" + e.kind);
      if (r.transit) tokens.push("fp-transit");
      var headName = ARROW_MARKERS[e.arrowEnd];
      var tailName = ARROW_MARKERS[e.arrowStart];
      var headId = (e.kind && headName === "point")
        ? renderID + "-fp-" + e.kind + "-head"
        : renderID + "-flowchart-" + headName + "End";
      // The class attribute before `d`, and its value beginning with the thickness token: both
      // elbow tests split the markup on `class="edge-thickness-normal` and then take the first
      // ` d="` in what follows (RENDERER-SPEC.md §8.6).
      var markup = '<path class="' + tokens.join(" ") + '" data-id="' + esc(e.id) + '" d="'
        + pathOf(r.points, r.hops) + '"' + styleAttribute(e.styles || [], STYLE_EDGE_PROPS, null);
      if (tailName) markup += ' marker-start="url(#' + esc(renderID + "-flowchart-" + tailName + "Start") + ')"';
      if (headName) markup += ' marker-end="url(#' + esc(headId) + ')"';
      paths.push(markup + "/>");

      if (r.label && e.labelLines.length) {
        var kindClass = e.kind ? " fp-" + e.kind : "";
        edgeLabels.push('<g class="edgeLabel"><g class="label' + kindClass + '" data-id="' + esc(e.id)
          + '" transform="translate(' + r.label.x + "," + r.label.y + ')">'
          + '<rect class="background" x="' + (-half4(e.labelWidth)) + '" y="' + (-half4(e.labelHeight))
          + '" width="' + e.labelWidth + '" height="' + e.labelHeight + '"/>'
          + '<text class="edgeLabel" text-anchor="middle">'
          + tspans(e.labelLines, e.lineHeight, 0, -half4(e.labelLines.length * e.lineHeight) + baselineIn(e.lineHeight))
          + "</text></g></g>");
      }
    }

    // --- nodes ---
    //
    // A node in a zone also says which zone depth it sits on, for the same reason the zone says its
    // own: the stylesheet cannot see it, because `g.node` and `g.cluster` are flat siblings. The
    // theme composites a rung's wash over that ground (MacMermaidTheme.swift, `onZones`); without
    // it a sink one zone deep was filled with exactly the zone's own grey.
    var zoneDepth = new Map();
    for (i = 0; i < drawing.clusters.length; i += 1) zoneDepth.set(drawing.clusters[i].id, drawing.clusters[i].depth);
    var nodes = [];
    for (i = 0; i < drawing.nodes.length; i += 1) {
      var n = drawing.nodes[i];
      var decls = authorDeclarations(db, n);
      var textStyle = styleAttribute(decls, STYLE_TEXT_PROPS, { color: "fill" });
      // Only `node default` and the rung. A source's own classDef names are deliberately NOT
      // written here: this file emits no classDef stylesheet, so they would style nothing -- and a
      // source that named itself `fp-store` would claim a rung its structure never earned. The
      // author's declarations still arrive, inline and validated, above.
      var classes = "node default" + (n.rung ? " fp-" + n.rung : "")
        + (n.rung && zoneDepth.has(n.parent) ? " fp-on-depth-" + zoneDepth.get(n.parent) : "");
      nodes.push('<g class="' + classes + '" id="' + esc(renderID + "-" + n.domId)
        + '" transform="translate(' + n.cx + "," + n.cy + ')">'
        + shapeMarkup(n.geometry, n.width, n.height, decls)
        + (n.lines.length
          ? '<g class="label"><text class="nodeLabel" text-anchor="middle"' + textStyle + ">"
            + tspans(n.lines, n.lineHeight, 0, -half4(n.lines.length * n.lineHeight) + baselineIn(n.lineHeight))
            + "</text></g>"
          : "")
        + "</g>");
    }

    // --- markers ---
    var defs = [];
    var ORDER = ["pointEnd", "pointStart", "circleEnd", "circleStart", "crossEnd", "crossStart"];
    for (i = 0; i < ORDER.length; i += 1) {
      if (!markers.has(ORDER[i])) continue;
      defs.push(markerMarkup(renderID + "-flowchart-" + ORDER[i], ORDER[i], "marker flowchart"));
    }
    // One clone per tagged kind. Per-edge arrowhead colour is the one thing CSS cannot reach when
    // every arrow shares a marker, which is why the glue clones at run time; here it is emitted
    // from the start. mermaid's own `marker` class is dropped so that only the theme's `fp-` rule
    // paints it.
    if (markers.has("fp-cross")) {
      defs.push(markerMarkup(renderID + "-fp-cross-head", "pointEnd", "fp-marker fp-marker-cross"));
    }

    var css = baseStylesheet(scope, theme, fontFamily) + "\n"
      + prefixCSS(theme.css, scope) + "\n"
      + scope + " :root{--mermaid-font-family:" + fontFamily + "}";

    var svg = '<svg id="' + esc(renderID) + '" xmlns="http://www.w3.org/2000/svg"'
      + ' xmlns:xlink="http://www.w3.org/1999/xlink" class="flowchart"'
      + ' width="' + drawing.width + '" height="' + drawing.height + '"'
      + ' viewBox="0 0 ' + drawing.width + " " + drawing.height + '"'
      + ' style="max-width: none; width: ' + drawing.width + "px; height: " + drawing.height
      + 'px; background-color: transparent;"'
      + ' role="graphics-document document" aria-roledescription="flowchart-v2">'
      + "<style>" + css + "</style>"
      + '<g class="root">'
      + '<g class="clusters">' + clusters.join("") + "</g>"
      + '<g class="edgePaths">' + paths.join("") + "</g>"
      + '<g class="edgeLabels">' + edgeLabels.join("") + "</g>"
      + '<g class="nodes">' + nodes.join("") + "</g>"
      + "</g><defs>" + defs.join("") + "</defs></svg>";

    var plates = [];
    for (i = 0; i < routed.length; i += 1) if (routed[i] && routed[i].label) plates.push(routed[i].label.rect);
    return { svg: svg, css: css, warnings: warnings, plates: plates, struck: struck };
  }

  // ===========================================================================
  // The app entry.
  //
  // Never throws. A source this cannot draw is a decline -- `{ok:false, reason}` -- and a decline is
  // a route rather than a failure: the glue falls back to mermaid and the reader sees the diagram
  // they would have seen anyway. That distinction is why `MermaidGlueCode` has no "fell back" value
  // and must not grow one (RENDERER-SPEC.md §2.4). The try/catch is the backstop for a bug in this
  // file, not a control path: a throw that reaches it is still a decline to the caller, so a
  // regression degrades to mermaid instead of showing the reader an error card.
  // ===========================================================================

  function render(input) {
    try {
      return renderOrDecline(input);
    } catch (e) {
      return { ok: false, reason: "threw:" + String((e && e.message) || e).slice(0, 120) };
    }
  }

  // How many times a drawing is laid out again for its titles. Room given to one zone moves the
  // routes into the others, so a struck title can appear where none was; one round settles every
  // drawing in the sweep and the held-out twenty, and a first draft of the nested-zone family needed
  // two. Bounded because a route that could follow its title forever must still draw.
  var TITLE_ROUNDS = 3;

  function renderOrDecline(input) {
    var p = input || {};
    if (String(p.diagramType || "") !== "flowchart-v2") return { ok: false, reason: "wrong-type" };
    if (typeof p.measureText !== "function") return { ok: false, reason: "no-measure" };
    var renderID = String(p.renderID || "");
    if (!RENDER_ID.test(renderID)) return { ok: false, reason: "bad-render-id" };
    if (typeof p.source !== "string" || !p.source.length) return { ok: false, reason: "no-source" };

    var theme = (p.theme && typeof p.theme.fontSizePX === "number") ? p.theme : buildFlowTheme(p.theme || {});
    // The same opt-in the glue's editorial passes use. A theme with no `.fp-` rules cannot paint a
    // rung, and a drawing whose structure is tagged but unpainted is strictly worse than mermaid's.
    if (theme.css.indexOf(LADDER_MARKER) === -1) return { ok: false, reason: "no-ladder" };

    var db = new FlowDB();
    db.clear();
    parse(p.source, db);

    var limits = p.limits || {};
    var maxNodes = (typeof limits.maxNodes === "number" && limits.maxNodes > 0) ? limits.maxNodes : MAX_NODES;
    var maxEdges = (typeof limits.maxEdges === "number" && limits.maxEdges > 0) ? limits.maxEdges : MAX_EDGES;
    if (db.getVertices().size > maxNodes) return { ok: false, reason: "limit:nodes" };
    if (db.getEdges().length > maxEdges) return { ok: false, reason: "limit:edges" };

    var unsupported = unsupportedFeature(db);
    if (unsupported) return { ok: false, reason: "unsupported:" + unsupported };

    var drawing = layout(db, { measureText: p.measureText, theme: theme });
    var out = emit(db, drawing, theme, renderID);
    // A route through a zone's title, answered by laying the drawing out again with room for it.
    //
    // The title names the whole group, and a stroke through it leaves the group unnamed: the
    // held-out review's one clear loss to Pele, h14, had three, and h07 one. The router could not
    // avoid them. A node in a zone's first row has its arrival station ARRIVE above its face, and
    // the header leaves less than that between the title and the node, so the station itself is
    // in the title's box: a route arriving from a lane beside the zone turns across the title to
    // reach it, and no cross-line between two stations, one of them inside the box, clears it.
    // Where the route arrives straight down a zone narrower than twice its title, the port is under
    // the title and `slideTitle` has nowhere to go.
    //
    // Rejected on the geometry, not built: the title box as an obstacle in `legIsClear`. It refuses
    // the route but offers it nothing -- the arrival station is in the box -- so the edge would fall
    // to a weaker pass and through the title anyway, and a straight drop could only go round it by
    // two corners more, against a bend budget this file holds at Pele's or better. Measured and
    // rejected: the lane under every titled zone. It clears every title too, but changes 32 of the
    // 248 drawings in the sweep and the held-out twenty and adds 608,128px2 of content to
    // differential.mjs's 231; this changes the 9 that had a struck title and adds 322,304.
    // Strikes over those 248: 13 -> 0, bends unchanged, render 176 -> 184ms a pass. It is a second
    // pass for the reason the plate pass below is: only the first knows where the routes went.
    var titleRoom = null;
    for (var round = 0; round < TITLE_ROUNDS; round += 1) {
      var more = false;
      for (var zid in out.struck) {
        if (!Object.prototype.hasOwnProperty.call(out.struck, zid)) continue;
        titleRoom = titleRoom || {};
        var had = titleRoom[zid] || { lane: false, wide: 0 };
        var got = out.struck[zid];
        var lane = had.lane || got.lane;
        var wide = had.wide + got.wide;
        if (lane !== had.lane || wide !== had.wide) more = true;
        titleRoom[zid] = { lane: lane, wide: wide };
      }
      if (!more) break;
      db = new FlowDB();
      db.clear();
      parse(p.source, db);
      drawing = layout(db, { measureText: p.measureText, theme: theme, titleRoom: titleRoom });
      out = emit(db, drawing, theme, renderID);
    }
    // A plate the placer put outside the content box is given a canvas that holds it, by laying the
    // drawing out again with that much more room on that side. The layout reserves room for the
    // labels it can predict, and the placer still sometimes finds its best position past the last
    // node: 2 plates of 68 over the sweep and the review's 16 sources, the review's 13 by 16px
    // (a 208px label beside the left exit of a diamond whose right exit already has one) and 07 by
    // 8px. Until this, those plates landed in the outer margin, which made the margin a reserve
    // nobody had declared: at 20px 13's plate came out 4px from the image edge, at 16px flush with
    // it, and at 8px the placer could no longer reach it and laid it over both of the diamond's
    // exits. With it, the margin is the same distance from every drawing's last mark again.
    //
    // A second pass rather than a wider first one, because the first is what finds the plate and
    // only it knows how far out it went; on 186 of those 188 drawings it never runs. The
    // limit is the same fact read the other way: the first pass places against the canvas it was
    // given, so a margin too narrow to reach the position it would have chosen still changes the
    // choice, as at 8px.
    var m = drawing.padding;
    var grow = { left: 0, top: 0, right: 0, bottom: 0 };
    for (var k = 0; k < out.plates.length; k += 1) {
      var r = out.plates[k];
      grow.left = Math.max(grow.left, m - r.x);
      grow.top = Math.max(grow.top, m - r.y);
      grow.right = Math.max(grow.right, r.x + r.width - (drawing.width - m));
      grow.bottom = Math.max(grow.bottom, r.y + r.height - (drawing.height - m));
    }
    if (grow.left > 0 || grow.top > 0 || grow.right > 0 || grow.bottom > 0) {
      grow = { left: gridUp(grow.left, 0) / GRID, top: gridUp(grow.top, 0) / GRID,
        right: gridUp(grow.right, 0) / GRID, bottom: gridUp(grow.bottom, 0) / GRID };
      db = new FlowDB();
      db.clear();
      parse(p.source, db);
      drawing = layout(db, { measureText: p.measureText, theme: theme, grow: grow, titleRoom: titleRoom });
      out = emit(db, drawing, theme, renderID);
    }

    // Post-conditions on this module's own output, asserted rather than sanitised: `themeCSS` is
    // app-authored and a source cannot reach it (it is in the glue's SECURE_KEYS), so a hazard here
    // would mean the app shipped one. Declining is the honest answer -- the alternative is emitting
    // a <style> the glue's own scrub would then have to strip out from under us.
    if (STYLE_HAZARDS.test(out.css) || CLOSE_STYLE.test(out.css)) {
      return { ok: false, reason: "unsupported:theme-css" };
    }
    if (!(drawing.width > 0) || !(drawing.height > 0)) return { ok: false, reason: "empty" };

    return {
      ok: true,
      svg: out.svg,
      width: drawing.width,
      height: drawing.height,
      size: { width: drawing.width, height: drawing.height },
      diagramType: "flowchart-v2",
      counts: drawing.counts,
      warnings: out.warnings
    };
  }

  // What this renderer knows it would draw wrongly rather than differently. Each of these is a
  // decline to mermaid, which already handles them -- an unimplemented feature drawn badly is worse
  // than the same feature drawn by the engine that has it.
  function unsupportedFeature(db) {
    var found = null;
    // A Map, walked in insertion order, so which feature a source with two of them declines for is
    // the same answer every time (RENDERER-SPEC.md §5.4).
    db.getVertices().forEach(function (v) {
      if (found !== null) return;
      // `click` binds behaviour to an element. RENDERER-SPEC.md §6 keeps it on mermaid, where the
      // existing scrub already decides what a link may be.
      if (v.link !== undefined || v.haveCallback === true) found = "click";
      // An icon or an image is sized from `assetWidth`/`assetHeight`, which shapeBox ignores; it
      // would lay the node out as a rectangle around a label that is not the content.
      else if (v.icon !== undefined || v.img !== undefined) found = "asset";
    });
    return found;
  }

  var API = {
    version: FLOW_VERSION,
    FlowDB: FlowDB,
    log: log,
    parse: parse,
    layout: layout,
    // Exported because layout reads it and a node-hosted test needs the same projection the app
    // gets; the app itself only ever calls `render`.
    buildFlowTheme: buildFlowTheme,
    render: render
  };

  if (typeof module === "object" && module && module.exports) module.exports = API;
  if (typeof window !== "undefined") window.__flowpeekFlow = API;
})();
