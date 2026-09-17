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
      // The theme's stylesheet paints edge labels in a mono face, and the payload carries no name
      // for it. Reading the field here rather than inventing a stack means the measurement follows
      // the moment the payload grows one; until then an edge label is measured in the sans and its
      // width is approximate. That is the one number in this file that is not the thing it
      // measures, and it is why the backing rect gets a wider pad than the text needs.
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
    // stylesheet rather than off the style guide. The guide puts arrow labels at 8px mono; the
    // theme's `.edgeLabel` rule changes the family, the weight and the tracking and leaves the size
    // alone (MacMermaidTheme.swift:339-345), so the painted size is the base size. Measuring the
    // guide's 8px would size every backing rect for type nobody will see.
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
        letterSpacing: "0.04em"
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

  function wrapOneLine(line, measure, style, maxPX) {
    var text = line.replace(/\s+/g, " ").replace(/^ /, "").replace(/ $/, "");
    if (text === "") return [""];
    if (measure(text, style).w <= maxPX) return [text];

    var words = text.split(" ");
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
      for (;;) {
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

  function shapeLabel(text, metrics, style, maxPX) {
    // Split before decoding, never after. `<br/>` is a line break because the sanitizer kept it as
    // markup; `&lt;br/&gt;` is four visible characters because the author escaped it, and decoding
    // first would turn the second into the first.
    var hard = String(text === undefined || text === null ? "" : text).split(BREAK_TAG);
    var lines = [];
    for (var i = 0; i < hard.length; i += 1) {
      var wrapped = wrapOneLine(decodeRefs(hard[i]), metrics.measure, style, maxPX);
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
        dotted: 0,
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
      var arrows = db.destructEdgeType(raw.type);
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
      if (fromNode) { fromNode.outDeg += 1; fromNode.edges += 1; if (edge.pattern === "dotted") fromNode.dotted += 1; }
      if (toNode) { toNode.inDeg += 1; toNode.edges += 1; if (edge.pattern === "dotted") toNode.dotted += 1; }
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

    function positionsOf(ls) {
      var pos = [];
      for (var a = 0; a < m; a += 1) pos.push(0);
      for (var b = 0; b < ls.length; b += 1) for (var c = 0; c < ls[b].length; c += 1) pos[ls[b][c]] = c;
      return pos;
    }

    function crossings(ls) {
      var pos = positionsOf(ls);
      var total = 0;
      for (var g = 0; g + 1 < ls.length; g += 1) {
        var here = [];
        for (var a = 0; a < segments.length; a += 1) {
          if (segments[a].gap !== g) continue;
          here.push([pos[segments[a].u], pos[segments[a].v]]);
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
      var from = down ? 1 : ls.length - 2;
      var stop = down ? ls.length : -1;
      var step = down ? 1 : -1;
      for (var r2 = from; r2 !== stop; r2 += step) {
        var layer = ls[r2];
        var keyed = [];
        for (var a = 0; a < layer.length; a += 1) {
          var id = layer[a];
          var fixed = down ? nbrUp[id] : nbrDown[id];
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

    var best = copyLayers(layers);
    var bestCross = crossings(layers);
    for (i = 0; i < 8 && bestCross > 0; i += 1) {
      sweep(layers, (i % 2) === 0);
      var cross = crossings(layers);
      if (cross < bestCross) { bestCross = cross; best = copyLayers(layers); }
    }
    layers = best;

    for (i = 0; i < layers.length; i += 1) {
      for (j = 0; j < layers[i].length; j += 1) items[layers[i][j]].order = j;
    }

    // --- coordinates along the rank (the O axis) --------------------------
    var oPos = [];
    for (i = 0; i < m; i += 1) oPos.push(0);
    for (i = 0; i < layers.length; i += 1) {
      var cursor = 0;
      for (j = 0; j < layers[i].length; j += 1) {
        var it = items[layers[i][j]];
        oPos[layers[i][j]] = cursor;
        cursor += it.oSize + env.spaceU;
      }
    }

    function centreOf(idx) {
      return oPos[idx] + items[idx].oSize / 2;
    }

    // Four alternating passes of: ask each node where its neighbours in the rank above (or below)
    // would like it, then walk the rank left to right honouring the minimum gap, then slide the
    // whole rank by the average of what everyone gave up. The straightforward alternative -- pack
    // each rank and centre it -- draws a fan as a block of boxes with the parent over the middle of
    // the block rather than over its own children, which is what the eye follows.
    for (var pass = 0; pass < 4; pass += 1) {
      var downward = (pass % 2) === 0;
      var order = [];
      for (i = 0; i < layers.length; i += 1) order.push(downward ? i : layers.length - 1 - i);
      for (var oi = 0; oi < order.length; oi += 1) {
        var lr = order[oi];
        var layer2 = layers[lr];
        if (!layer2.length) continue;
        var want = [];
        for (i = 0; i < layer2.length; i += 1) {
          var idx = layer2[i];
          var fixed2 = downward ? nbrUp[idx] : nbrDown[idx];
          if (!fixed2.length) { want.push(oPos[idx]); continue; }
          var acc = 0;
          for (j = 0; j < fixed2.length; j += 1) acc += centreOf(fixed2[j]);
          want.push(Math.round(acc / fixed2.length - items[idx].oSize / 2));
        }
        var put = [];
        for (i = 0; i < layer2.length; i += 1) {
          var lowest = (i === 0) ? want[i] : put[i - 1] + items[layer2[i - 1]].oSize + env.spaceU;
          put.push(Math.max(want[i], lowest));
        }
        var drift = 0;
        for (i = 0; i < layer2.length; i += 1) drift += want[i] - put[i];
        drift = Math.round(drift / layer2.length);
        for (i = 0; i < layer2.length; i += 1) oPos[layer2[i]] = put[i] + drift;
      }
    }

    var minO = 0;
    var first = true;
    for (i = 0; i < m; i += 1) {
      if (first || oPos[i] < minO) { minO = oPos[i]; first = false; }
    }
    for (i = 0; i < m; i += 1) oPos[i] -= minO;

    var totalO = 0;
    for (i = 0; i < m; i += 1) {
      var end = oPos[i] + items[i].oSize;
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
    // How much of the gap each of its two faces has to be left alone for. A gap is not symmetric:
    // the face an edge LEAVES needs a stub plus room to round the corner off it, and the face an
    // edge ARRIVES at needs that plus the arrowhead and a shaft behind it. Which face is which is a
    // property of the edges in the gap, not of the gap, so it is read off them -- an all-forward
    // gap only ever has arrivals on its far face, and reserving ARRIVE on both instead cost 6.47%
    // of drawing area over the 300-source corpus against 2.24% for this.
    var gapLoNeed = [];
    var gapHiNeed = [];
    for (i = 0; i < maxRank; i += 1) {
      gapLanes.push(0); gapLabel.push(0);
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
      seg.forkAt = (segEdge.chain.length > 2) ? -1
        : ((!segBack && seg.gap === segEdge.lowRank) ? seg.u
          : ((segBack && seg.gap + 1 === segEdge.highRank) ? seg.v : -1));
      seg.forkBack = segBack;
      seg.forkOff = (seg.forkAt < 0) ? 0
        : ((seg.forkAt === seg.u ? cv : cu) - centreOf(seg.forkAt));
      var lbl = seg.edge.labelBox;
      if (lbl) {
        var along = vertical ? lbl.h : lbl.w;
        if (along > gapLabel[seg.gap]) gapLabel[seg.gap] = along;
      }
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
    for (i = 0; i < segments.length; i += 1) {
      var rest = segments[i];
      if (rest.gap >= maxRank || rest.lo === rest.hi) continue;
      if (rest.inFork) continue;
      units.push({ segs: [rest], index: rest.edge.index, fork: null, step: 0 });
    }
    units.sort(function (p, q) { return (p.index - q.index) || (p.step - q.step); });
    for (i = 0; i < units.length; i += 1) {
      var unit = units[i];
      var floorL = unit.fork ? (unit.fork.floor || 0) : 0;
      var got = takeLane(unit.segs[0].gap, unit.segs, floorL);
      // A fork's pairs ladder outwards, one lane apart at least, whatever else claims the gap first.
      if (unit.fork) unit.fork.floor = got + 1;
    }

    var rankSize = [];
    for (i = 0; i <= maxRank; i += 1) rankSize.push(0);
    for (i = 0; i < m; i += 1) if (items[i].rSize > rankSize[items[i].rank]) rankSize[items[i].rank] = items[i].rSize;
    for (i = 0; i <= maxRank; i += 1) rankSize[i] = even(rankSize[i]);

    var gapSize = [];
    for (i = 0; i < maxRank; i += 1) {
      var lanes = gapLanes[i];
      var needed = gapLoNeed[i] + Math.max(0, lanes - 1) * LANE_GAP + gapHiNeed[i];
      // An edge label lives in the gap, so the gap has to hold it. The router decides which side of
      // the stroke it goes on; reserving the room is the only part layout can settle.
      var labelled = gapLabel[i] + 2 * STUB;
      gapSize.push(Math.max(env.rankU, needed, labelled));
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
      var used = Math.max(0, gapLanes[i] - 1) * LANE_GAP;
      var slack = band - gapLoNeed[i] - used - gapHiNeed[i];
      laneAt.push(bandStart + gapLoNeed[i] + Math.floor(slack / 2));
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
      sg2.laneR = (sg2.lane >= 0) ? laneAt[sg2.gap] + sg2.lane * LANE_GAP : laneAt[sg2.gap];
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

  function authoredFill(db, vertex) {
    var decls = (vertex.styles || []).slice();
    var classes = ["default", "node"].concat(vertex.classes || []);
    decls = decls.concat(db.getCompiledStyles(classes));
    for (var i = 0; i < decls.length; i += 1) {
      if (/^\s*fill\s*:/i.test(String(decls[i]))) return true;
    }
    return false;
  }

  function tagLadder(db, model) {
    var counts = { backend: 0, store: 0, entry: 0, terminal: 0, optional: 0, focal: 0, accent: 0, cross: 0 };
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
      // Author intent outranks computed role: a node reached only by `-.->` is conditional.
      if (n.edges > 0 && n.dotted === n.edges) rung = "optional";
      n.rung = rung;
      counts[rung] += 1;
    }

    // One focal node, or none, and none is the common answer. A rule that fired on "the last node"
    // would fire on every linear chain, which is how an editorial accent turns into "this is where
    // the arrows stop" -- SKILL.md §1 calls coral-on-everything the anti-pattern that erases the
    // signal, and an accent that always fires is the same erasure by a slower route.
    var focal = null;
    if (nodes.length >= 4) {
      var top = null;
      var ties = 0;
      for (i = 0; i < nodes.length; i += 1) {
        var degree = nodes[i].inDeg + nodes[i].outDeg;
        if (!top || degree > top.degree) { top = { node: nodes[i], degree: degree }; ties = 1; }
        else if (degree === top.degree) ties += 1;
      }
      if (top && ties === 1 && top.degree >= 4) focal = top.node;
      if (focal && authoredFill(db, focal.vertex)) focal = null;
    }

    if (focal) {
      counts[focal.rung] -= 1;
      focal.rung = "focal";
      counts.focal = 1;
      // Derived from the focal node, never chosen: the one edge into it whose source is busiest. It
      // abstains on a tie for the same reason the focal node does -- two alike edges, one of them
      // coral, asks the reader to find a difference that is not there.
      var best = null;
      var tied = false;
      for (i = 0; i < focal.incoming.length; i += 1) {
        var candidate = focal.incoming[i];
        var source = model.nodeById.get(candidate.from);
        var outDeg = source ? source.outDeg : -1;
        if (!best || outDeg > best.outDeg) { best = { edge: candidate, outDeg: outDeg }; tied = false; }
        else if (outDeg === best.outDeg) { tied = true; }
      }
      if (best && !tied) { best.edge.kind = "accent"; counts.accent = 1; }
    }

    // A path that leaves one zone and enters another. Membership is read off the parse tree here,
    // where the glue has to infer it from overlapping rects, so "innermost" is simply the parent.
    // Both ends have to be in a zone: an edge to a node in no subgraph has not crossed a boundary,
    // and counting it as one made every edge in a half-grouped diagram "crossing".
    if (model.clusters.length > 0) {
      var crossing = [];
      for (i = 0; i < model.edges.length; i += 1) {
        var e = model.edges[i];
        if (e.kind === "accent" || e.pattern === "dotted" || e.pattern === "invisible") continue;
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
  // Measured off the emitted paths, every geometry on every face, three connectors to a face: 308
  // of 360 ports land exactly on the outline, none lands outside it, and the deepest any sank past
  // it is 3.63px -- under one grid step, which is what ceil() can cost. ports.spec.js holds those
  // three numbers.
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
    for (i = 0; i < faces.length; i += 1) {
      var fx = faces[i];
      if (!fx.fixed) continue;
      fx.group.sort(function (p, q) {
        var pk = fx.alongX ? centreX(p.other) : centreY(p.other);
        var qk = fx.alongX ? centreX(q.other) : centreY(q.other);
        if (pk !== qk) return pk - qk;
        if (p.edge.index !== q.edge.index) return p.edge.index - q.edge.index;
        return p.end - q.end;
      });
      recordSlots(fx);
      fx.offsets = clusterAt(fx.run.anchor, fx.group.length, fx.run, fx.span);
      settleFace(fx, fx.group);
    }

    for (i = 0; i < model.edges.length; i += 1) desirePorts(model.edges[i], model);

    mirrorForks(faces);

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
      f.group.sort(function (p, q) {
        if (p.desire !== q.desire) return p.desire - q.desire;
        var pk = f.alongX ? centreX(p.other) : centreY(p.other);
        var qk = f.alongX ? centreX(q.other) : centreY(q.other);
        if (pk !== qk) return pk - qk;
        if (p.edge.index !== q.edge.index) return p.edge.index - q.edge.index;
        return p.end - q.end;
      });
      for (var g2 = 0; g2 < f.group.length; g2 += 1) f.desires.push(f.group[g2].desire);
      recordSlots(f);
      f.offsets = placeFace(f);
      settleFace(f, f.group);
    }

    for (i = 0; i < model.edges.length; i += 1) alignUnitJog(model.edges[i], model);
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
      }
    }
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
  function mirrorForks(faces) {
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
        return { lo: a.face.base + a.face.run.lo, hi: a.face.base + a.face.run.hi };
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
      var p = face.desires[k] - MIN_PITCH * k;
      blocks.push({ vals: [p], value: p, n: 1 });
      while (blocks.length > 1 && blocks[blocks.length - 2].value > blocks[blocks.length - 1].value) {
        var b = blocks.pop();
        var a = blocks[blocks.length - 1];
        a.vals = a.vals.concat(b.vals);
        a.n += b.n;
        a.value = middleOf(a.vals);
      }
    }
    var top = span.hi - MIN_PITCH * (N - 1);
    var out = [];
    for (k = 0; k < blocks.length; k += 1) {
      var v = Math.min(top, Math.max(span.lo, blocks[k].value));
      for (var j = 0; j < blocks[k].n; j += 1) out.push(v + MIN_PITCH * out.length);
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
      } else {
        group[g].edge.endPoint = point;
        group[g].edge.endInset = inset;
      }
    }
    face.group = group;
  }

  // SKILL.md §6 rule 4's "at least 12px between adjacent attach points", in grid units.
  var MIN_PITCH = 3;

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
      if (Math.abs(face.offsets[i] - want) < MIN_PITCH) return false;
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

  function layout(db, options) {
    var opts = options || {};
    // Accepts either the projection or the raw payload it is projected from, so a caller that
    // already built the theme does not pay for it twice and a test can pass nothing at all.
    var theme = (opts.theme && typeof opts.theme.fontSizePX === "number")
      ? opts.theme
      : buildFlowTheme(opts.theme || {});
    var metrics = makeMetrics(opts.measureText, theme);
    var arrangement = theme.arrangement;
    var env = {
      spaceU: arrangement.nodeSpacing / GRID,
      rankU: arrangement.rankSpacing / GRID
    };
    var padU = arrangement.padding / GRID;
    var marginU = arrangement.diagramPadding / GRID;
    var wrapPX = arrangement.wrappingWidth;

    var rootDir = normaliseDirection(opts.direction || db.getDirection(), "TB");
    var model = buildModel(db, rootDir);
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
        var shaped = shapeLabel(text, metrics, metrics.edge, wrapPX);
        edge.label = shaped;
        // The backing rect is 8px wider than the text on each side rather than 4. Half of that is
        // SKILL.md §6 rule 2 wanting the mask clear of the stroke; the other half is slack against
        // the one measurement this file knows is approximate -- the theme paints edge labels in a
        // mono face whose name the payload does not carry, so the width here is the sans width.
        // How much slack a real Geist/Geist Mono pair needs has not been measured.
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
      layoutLevel(inner, env);
      var title = String(cluster.title || "");
      var header = 0;
      if (title.length > 0) {
        cluster.label = shapeLabel(title, metrics, metrics.cluster, wrapPX);
        // dd-arch.md: the eyebrow sits 4px inside the top of the zone and there is at least 16px
        // between its baseline box and the first enclosed node. The 2 units here plus the padding
        // below buy 20px, which is the near side of that.
        header = even(cluster.label.h + 2);
      } else {
        cluster.label = null;
      }
      cluster.header = header;
      cluster.contentDX = padU;
      cluster.contentDY = padU + header;
      cluster.w = even(inner.contentW + 2 * padU);
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
    place("", marginU, marginU);

    assignPorts(model);
    var counts = tagLadder(db, model);

    var widthU = root.contentW + 2 * marginU;
    var heightU = root.contentH + 2 * marginU;
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
        start: { x: px(e2.startPoint.x), y: px(e2.startPoint.y), side: e2.startSide, inset: px(e2.startInset) },
        end: { x: px(e2.endPoint.x), y: px(e2.endPoint.y), side: e2.endSide, inset: px(e2.endInset) },
        channel: channel,
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
  // stay on the grid without a second rounding rule.
  var LABEL_GAP_PX = 8;
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

  // `strict` counts down the demands rather than switching them: 3 wants daylight from every border
  // this edge is not attached to -- 12px from a node's, a stub from a zone's hairline -- AND no
  // shared run with a stroke already drawn; 2 drops the daylight; 1 keeps only "not behind a box";
  // 0 accepts whatever the first candidate was.
  function legIsClear(p, q, ctx, strict, edge) {
    var i;
    var box;
    for (i = 0; i < ctx.boxes.length; i += 1) {
      if (hitsBox(p, q, ctx.boxes[i])) return false;
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
    var anchor = (preferred !== null && preferred >= lo && preferred <= hi) ? preferred : snap4((lo + hi) / 2);
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

  function joinStations(stations, travel, edge, ctx, strict) {
    var pts = [stations[0]];
    var other = (travel === "y") ? "x" : "y";
    for (var i = 0; i + 1 < stations.length; i += 1) {
      // Only the first leg gets the reserved lane: it is the lane in the gap the edge has to leave
      // its SOURCE by, which is the one place two edges out of one rank would otherwise stack.
      var pref = (i === 0 && edge.channel && edge.channel.axis === travel) ? edge.channel.value : null;
      var mid = connect(stations[i], stations[i + 1], travel, pref, ctx, strict, edge);
      if (mid === null) mid = connect(stations[i], stations[i + 1], other, null, ctx, strict, edge);
      if (mid === null) return null;
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
    var stations = [A];
    for (var i = 0; i < edge.via.length; i += 1) stations.push({ x: edge.via[i].x, y: edge.via[i].y });
    stations.push(B);
    var travel = (dS.x === 0) ? "y" : "x";

    var body = joinStations(stations, travel, edge, ctx, 3);
    var crowded = false;
    var transit = false;
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

  function hopFits(run, centre, existing) {
    if (centre - HOP_CLEAR < run.lo || centre + HOP_CLEAR > run.hi) return false;
    for (var i = 0; i < existing.length; i += 1) {
      if (Math.abs(existing[i].at - centre) < 2 * HOP_R) return false;
    }
    return true;
  }

  function placeHop(seg, x, y, ctx) {
    var existing = seg.owner.hops[seg.index] || [];
    var hop;
    if (seg.horizontal) {
      if (!hopFits(seg.run, x, existing)) return false;
      // The bump goes to -y on a horizontal run and to -x on a vertical one, whichever way the run
      // travels, so a drawing reads its bridges as one gesture. In SVG's y-down frame sweep 1 is
      // the increasing-angle direction, which lifts a left-to-right arc upwards and drops a
      // right-to-left one; the sign of the run is what keeps the bump on the same side of both.
      hop = {
        at: x, box: { x: x - HOP_R, y: y - HOP_R, width: 2 * HOP_R, height: HOP_R },
        from: { x: x - seg.u * HOP_R, y: y }, to: { x: x + seg.u * HOP_R, y: y },
        sweep: seg.u > 0 ? 1 : 0
      };
    } else {
      if (!hopFits(seg.run, y, existing)) return false;
      hop = {
        at: y, box: { x: x - HOP_R, y: y - HOP_R, width: HOP_R, height: 2 * HOP_R },
        from: { x: x, y: y - seg.u * HOP_R }, to: { x: x, y: y + seg.u * HOP_R },
        sweep: seg.u > 0 ? 0 : 1
      };
    }
    // A grid step of air around the bump, not just no overlap. A crest that stops on a node's
    // border is read as part of the border; the nodes are painted after the strokes, so it would be
    // a bump with its top shaved off.
    var near = {
      x: hop.box.x - GRID, y: hop.box.y - GRID,
      width: hop.box.width + 2 * GRID, height: hop.box.height + 2 * GRID
    };
    var i;
    for (i = 0; i < ctx.boxes.length; i += 1) {
      if (rectsOverlap(near, ctx.boxes[i])) return false;
    }
    for (i = 0; i < ctx.labelRects.length; i += 1) {
      if (rectsOverlap(near, ctx.labelRects[i])) return false;
    }
    existing.push(hop);
    existing.sort(function (a, b) { return a.at - b.at; });
    seg.owner.hops[seg.index] = existing;
    return true;
  }

  function bridgeCrossings(routed, ctx) {
    var segs = [];
    var i;
    for (i = 0; i < routed.length; i += 1) {
      var r = routed[i];
      if (!r) continue;
      r.hops = [];
      var runs = straightRuns(r.points);
      for (var s = 0; s + 1 < r.points.length; s += 1) {
        r.hops.push(null);
        var p = r.points[s], q = r.points[s + 1];
        // The STRAIGHT stretch, not the corner-to-corner segment. Two routes whose segments meet
        // inside one of them's corner arc do not cross as drawn -- one of them has already turned
        // away -- and a bump there bridges nothing. Found by a test that read the crossings off the
        // emitted `d` while the pass was still reading them off the route's corners.
        var horizontal = p.y === q.y;
        var u = sign(horizontal ? q.x - p.x : q.y - p.y);
        if (runs[s].hi - runs[s].lo <= 0) continue;
        segs.push({
          owner: r, order: i, index: s, horizontal: horizontal, u: u, run: runs[s],
          fixed: horizontal ? p.y : p.x
        });
      }
    }
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
        if (!(x > H.run.lo && x < H.run.hi)) continue;
        if (!(y > V.run.lo && y < V.run.hi)) continue;
        var wH = hopWeight(H.owner.edge), wV = hopWeight(V.owner.edge);
        var first = (wH !== wV) ? (wH < wV ? H : V) : (H.order > V.order ? H : V);
        var second = (first === H) ? V : H;
        if (!placeHop(first, x, y, ctx)) placeHop(second, x, y, ctx);
      }
    }
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

  // SKILL.md §6 rules 2 and 6 together: the mask sits clear of its own stroke by LABEL_GAP_PX, and
  // it sits clear of every node -- nodes are painted last, so a mask that lands under one is
  // covered and its text becomes a fragment on a node border. Every candidate is offered both
  // sides of every segment, longest segment first, because the longest run is the one with room
  // beside it; the fallback when none is clear keeps the label rather than dropping the author's
  // word, which is the lesser of the two failures.
  // How badly a mask lands where it is proposed. Zero is what every placement in the measured
  // corpus scores; the weights only order the failures, and they order them by how much the reader
  // loses. A mask outside the viewBox is clipped and the word is gone; a mask inside a node is
  // covered by the node's fill, because nodes are painted last (SKILL.md §6 rule 6); a mask over
  // another mask makes two words one; a mask over a stroke hides a connector. In that order.
  function labelPenalty(rect, own, ctx) {
    var penalty = 0;
    var i;
    if (rect.x < 0 || rect.y < 0 || rect.x + rect.width > ctx.width || rect.y + rect.height > ctx.height) {
      penalty += 1000;
    }
    for (i = 0; i < ctx.boxes.length; i += 1) if (rectsOverlap(rect, ctx.boxes[i])) penalty += 100;
    for (i = 0; i < ctx.labelRects.length; i += 1) if (rectsOverlap(rect, ctx.labelRects[i])) penalty += 50;
    // Strokes are tested against the mask grown by LABEL_GAP_PX, so "clear" means the gap rule 2
    // asks for rather than merely not touching: a stroke nearer than 8px counts as a clash. The
    // annotated segment sits at exactly 8 by construction, which grazes this margin and does not
    // cross it -- the one placement that is allowed to be that close is the one the gap was
    // measured from.
    var near = {
      x: rect.x - LABEL_GAP_PX, y: rect.y - LABEL_GAP_PX,
      width: rect.width + 2 * LABEL_GAP_PX, height: rect.height + 2 * LABEL_GAP_PX
    };
    for (i = 0; i < ctx.drawn.length; i += 1) {
      if (segmentCrossesRect(ctx.drawn[i][0], ctx.drawn[i][1], near)) penalty += 10;
    }
    // Its own route counts too: the perpendicular offset clears only the segment the label
    // annotates, and a mask wider than that segment reaches the leg around the corner from it.
    for (i = 0; i < own.length; i += 1) {
      if (segmentCrossesRect(own[i][0], own[i][1], near)) penalty += 10;
    }
    return penalty;
  }

  // SKILL.md §6 rule 2: the mask sits clear of its own stroke by LABEL_GAP_PX so the connector stays
  // traceable under its own annotation. Every segment is offered both sides, longest first, because
  // the longest run is the one with open canvas beside it -- and every candidate is scored rather
  // than the first clear one taken, so that when a crowded drawing has no clear placement the label
  // lands on the least damaging one instead of wherever the search happened to stop.
  function placeEdgeLabel(edge, points, ctx, preferEarly) {
    if (!(edge.labelWidth > 0) || !(edge.labelHeight > 0)) return null;
    var halfW = half4(edge.labelWidth);
    var halfH = half4(edge.labelHeight);
    var segs = [];
    var own = [];
    for (var i = 0; i + 1 < points.length; i += 1) {
      var p = points[i], q = points[i + 1];
      own.push([p, q]);
      segs.push({
        p: p, q: q, at: i,
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
      for (var s = 0; s < 2; s += 1) {
        // Above a horizontal run and to the right of a vertical one, which is where the style guide
        // puts an arrow label; the other side is the second try, not a different rule.
        var side = seg.horizontal ? (s === 0 ? -1 : 1) : (s === 0 ? 1 : -1);
        // Three positions along the run, midpoint first. Sliding is what makes a crowded drawing
        // solvable at all: the midpoint of the longest segment is the reading position, but a
        // quarter of the way along is still unambiguously that connector's label and is often the
        // only place with open canvas beside it.
        var lo = seg.horizontal ? Math.min(seg.p.x, seg.q.x) : Math.min(seg.p.y, seg.q.y);
        var hi = seg.horizontal ? Math.max(seg.p.x, seg.q.x) : Math.max(seg.p.y, seg.q.y);
        var mid = snap4((lo + hi) / 2);
        // Every grid step along the run, nearest the midpoint first. Three positions were enough
        // while a fan's legs were long; a rhombus's two branches leave its apex 16px apart and turn
        // within 24px of it, and on `B -->|yes| C / B -->|no| D` every one of the six positions the
        // quarter rule offered was inside 8px of one of the route's own corners. Stepping the run
        // costs a handful of candidates on a diagram this file already budgets nine nodes for.
        var alongs = [mid];
        for (var step = GRID; mid - step >= lo || mid + step <= hi; step += GRID) {
          if (mid - step >= lo) alongs.push(mid - step);
          if (mid + step <= hi) alongs.push(mid + step);
        }
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
          var penalty = labelPenalty(rect, own, ctx);
          if (best === null || penalty < best.penalty) {
            best = { x: cx, y: cy, rect: rect, penalty: penalty, crowded: penalty > 0 };
            if (penalty === 0) return best;
          }
        }
      }
    }
    return best;
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
      // `!important` is not decoration here: mermaid writes author styles that way and both the
      // focal-abstention rule and the live label-contrast pass read `style="fill:…"` off the shape
      // to learn that a person chose it (flowpeek-glue.js:702, :260-265). A class would make both
      // blind, which is why RENDERER-SPEC.md §4.2 puts author colour inline.
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
  function shapeMarkup(geometry, w, h, styleAttr) {
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
        return '<g class="basic label-container outer-path"' + styleAttr + ">"
          + '<path d="' + pill + '"/><path d="' + pill + '"/></g>';
      case "circle":
        return '<circle class="basic label-container" cx="0" cy="0" r="' + W + '"' + styleAttr + "/>";
      case "doublecircle":
        return '<g class="basic label-container"' + styleAttr + ">"
          + '<circle cx="0" cy="0" r="' + W + '"/>'
          + '<circle cx="0" cy="0" r="' + Math.max(GRID, W - 4) + '"/></g>';
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
    for (i = 0; i < drawing.nodes.length; i += 1) boxById.set(drawing.nodes[i].id, drawing.nodes[i]);

    var ctx = {
      boxes: drawing.nodes,
      // Borders a stroke has to stay clear of without being kept out of what they enclose.
      rails: drawing.clusters,
      // The same objects, by the id an edge names its ends with, so the route check can tell the
      // box a port is attached to from the ones it has to stay off. An end that names a subgraph
      // finds nothing here, which is correct: a zone rect is not among the boxes either.
      boxById: boxById,
      drawn: [],
      labelRects: [],
      width: drawing.width,
      height: drawing.height
    };
    // The zone eyebrows are in the label set before any edge label is placed, so an edge label
    // cannot land on a subgraph's title. They are not obstacles for the strokes: a connector
    // entering a zone has to cross the zone, and the zone rect is painted first, so it is behind
    // everything either way.
    for (i = 0; i < drawing.clusters.length; i += 1) {
      var cl = drawing.clusters[i];
      if (cl.labelWidth > 0) {
        ctx.labelRects.push({ x: cl.labelX, y: cl.labelY, width: cl.labelWidth, height: cl.labelHeight });
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

    for (i = 0; i < routed.length; i += 1) {
      if (!routed[i]) continue;
      var placed = placeEdgeLabel(routed[i].edge, routed[i].points, ctx, routed[i].transit);
      if (!placed) continue;
      if (placed.crowded) noteWarning(warnings, "label-crowded");
      routed[i].label = placed;
      ctx.labelRects.push(placed.rect);
    }
    // After the labels, not before: a bridge may not land under a mask, and where the masks are is
    // only settled once every one of them has been placed.
    bridgeCrossings(routed, ctx);

    // Always defined, whatever the source asked for: EditorialArrowheadTests locates the arrowhead
    // by the `-pointEnd` id suffix, and a diagram drawn entirely with `---` would otherwise have no
    // marker for it to find and would pass by not looking.
    markers.set("pointEnd", true);

    // --- clusters ---
    var clusters = [];
    for (i = 0; i < drawing.clusters.length; i += 1) {
      var c = drawing.clusters[i];
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
      clusters.push('<g class="cluster" id="' + esc(renderID + "-" + c.id) + '">' + body + "</g>");
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
    var nodes = [];
    for (i = 0; i < drawing.nodes.length; i += 1) {
      var n = drawing.nodes[i];
      var decls = authorDeclarations(db, n);
      var shapeStyle = styleAttribute(decls, STYLE_SHAPE_PROPS, null);
      var textStyle = styleAttribute(decls, STYLE_TEXT_PROPS, { color: "fill" });
      // Only `node default` and the rung. A source's own classDef names are deliberately NOT
      // written here: this file emits no classDef stylesheet, so they would style nothing -- and a
      // source that named itself `fp-focal` would take the theme's one accent away from the node
      // that earned it. The author's declarations still arrive, inline and validated, above.
      var classes = "node default" + (n.rung ? " fp-" + n.rung : "");
      nodes.push('<g class="' + classes + '" id="' + esc(renderID + "-" + n.domId)
        + '" transform="translate(' + n.cx + "," + n.cy + ')">'
        + shapeMarkup(n.geometry, n.width, n.height, shapeStyle)
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
    if (markers.has("fp-accent")) {
      defs.push(markerMarkup(renderID + "-fp-accent-head", "pointEnd", "fp-marker fp-marker-accent"));
    }
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

    return { svg: svg, css: css, warnings: warnings };
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
