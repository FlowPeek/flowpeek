"use strict";
// FlowPeek render glue. Injected as a WKUserScript at .atDocumentStart into
// WKContentWorld.world(name: "flowpeek"), immediately after mermaid.min.js.
// Contract: every entry point ALWAYS resolves with a JSON string and never rejects.
(function () {
  var GLUE_VERSION = "1";
  var CANARY_SOURCE = "flowchart TD\n  A[Start] --> B[End]";
  var MAX_MESSAGE = 2000;
  // What a diagram may not decide for itself. `theme` and `themeVariables` are deliberately absent:
  // choosing a palette is the whole point of Mermaid's theming, and blocking them made every
  // `%%{init: {"theme": ...}}%%` directive and every front-matter `config: theme:` silently do
  // nothing -- three different spellings from Mermaid's own theming page all drew in identical
  // colours. `themeCSS` stays blocked because it is raw CSS rather than values, and the theme's
  // <style> element is the one thing the scrub keeps.
  var SECURE_KEYS = ["htmlLabels", "themeCSS", "fontFamily", "altFontFamily", "layout", "look"];

  // Theme variables reach the page as values inside that kept <style>, so a value carrying its own
  // punctuation could close the declaration and open something else. Nothing here needs more than a
  // colour, a length or a font name.
  // `url(#arrowhead)` is mermaid's own marker reference and points inside the document, which is
  // the same rule the attribute pass applies; anything else a url() could name is off-document.
  var STYLE_HAZARDS = /@import|url\s*\(\s*['"]?(?!#)|expression\s*\(|<\s*\/?\s*script/i;

  // mermaid measures a line of text by appending an <svg><text> to <body> and reading getBBox(),
  // and treats a 0x0 answer as fatal: `if (b.width === 0 && b.height === 0) throw new Error("svg
  // element not in render tree")` -- mermaid's own throw, not WebKit's. For an empty line mermaid
  // measures its placeholder, a zero-width space, and WebKit answers 0x0 where Blink answers the
  // line box height. So every diagram with a blank line failed here while drawing correctly on
  // mermaid.ai; eventmodeling's data blocks were only the case that reached us. Measured: the
  // element is <text>, textContent "\u200b", font 16px sans-serif, attached to <body>.
  //
  // The fix reports the em height for text that genuinely has no visible glyphs, which is what
  // Blink reports and what mermaid's layout expects. Every substitution is named so it stays
  // visible from Swift rather than silently reshaping a diagram.
  var measurementFallbacks = [];
  function noteFallback(name) {
    if (measurementFallbacks.indexOf(name) === -1) measurementFallbacks.push(name);
  }
  (function patchMeasurement() {
    var proto = window.SVGGraphicsElement && window.SVGGraphicsElement.prototype;
    if (!proto || typeof proto.getBBox !== "function" || proto.__flowpeekBBox) return;
    var native = proto.getBBox;
    proto.getBBox = function () {
      var box;
      try {
        box = native.apply(this, arguments);
      } catch (e) {
        // WebKit also throws outright for an element with no renderer; Blink returns zeros.
        noteFallback("getBBox:threw");
        return { x: 0, y: 0, width: 0, height: 0 };
      }
      if (!box || box.width !== 0 || box.height !== 0) return box;
      if (String(this.tagName).toLowerCase() !== "text" || !this.isConnected) return box;
      var size = parseFloat(getComputedStyle(this).fontSize);
      if (!(size > 0)) return box;
      noteFallback("getBBox:emptyText");
      return { x: box.x, y: box.y, width: 0, height: size };
    };
    proto.__flowpeekBBox = true;
  })();

  var cspViolations = [];
  document.addEventListener("securitypolicyviolation", function (e) {
    if (cspViolations.length >= 64) return;
    cspViolations.push(String(e.effectiveDirective || e.violatedDirective || "?") + "<-" + String(e.blockedURI || "?"));
  }, true);

  function now() {
    return (typeof performance !== "undefined" && performance && performance.now) ? performance.now() : Date.now();
  }

  function J(o) {
    o.cspViolations = cspViolations.slice();
    return JSON.stringify(o);
  }

  function fail(code, message, line) {
    return J({ ok: false, code: code, message: String(message).slice(0, MAX_MESSAGE), line: (line === undefined ? null : line) });
  }

  function engine() {
    return (typeof mermaid !== "undefined" && mermaid) ? mermaid : (typeof window !== "undefined" ? window.mermaid : undefined);
  }

  function engineVersion() {
    try {
      var m = engine();
      if (!m) return null;
      var v = m.version;
      if (typeof v === "function") v = v();
      return (typeof v === "string" && v.length) ? v : null;
    } catch (e) {
      return null;
    }
  }

  function parsePayload(p) {
    if (typeof p === "string") return JSON.parse(p);
    return p;
  }

  function buildConfig(p) {
    var cfg = {
      startOnLoad: false,
      securityLevel: "strict",
      htmlLabels: false,
      secure: SECURE_KEYS.slice(),
      suppressErrorRendering: true,
      maxTextSize: 120000,
      maxEdges: 2000,
      deterministicIds: true,
      deterministicIDSeed: String(p.seed || "flowpeek"),
      // 'base' is a blank canvas: only the variables we hand over get applied, so any diagram type
      // whose palette we did not anticipate keeps mermaid's light defaults. eventmodeling hardcodes
      // near-white lanes (fill 250,250,250 on stroke 240,240,240) that ignore themeVariables
      // entirely, so forcing primaryTextColor to white in dark mode produced white text on white
      // boxes. 'default'/'dark' ship complete palettes that mermaid recomputes per appearance --
      // the same diagram becomes fill 40,40,43 with 204,204,204 text -- and our variables still
      // layer on top for the types that do read them.
      theme: p.dark === true ? "dark" : "default",
      themeVariables: p.themeVariables || {},
      themeCSS: p.themeCSS || ""
    };
    if (p.fontFamily) cfg.fontFamily = p.fontFamily;
    applyArrangement(cfg, p.arrangement);
    return cfg;
  }

  // The spacing and edge shape a theme asked for, spread across the per-diagram config blocks that
  // actually read them. mermaid has no single place for these: flowchart, sequence, state and class
  // each keep their own, and a value set on the wrong one is silently ignored.
  //
  // Every field is optional and a theme that sets none leaves `cfg` untouched, so the default theme
  // emits exactly the config it always did -- which is what the golden snapshots check.
  //
  // Deliberately not a loop over the payload's own keys: this is the second guard, after the typed
  // struct on the Swift side, that a theme can only reach spacing. Anything not named here does not
  // arrive, whatever the payload says.
  function applyArrangement(cfg, a) {
    if (!a || typeof a !== "object") return;
    var num = function (v) { return typeof v === "number" && isFinite(v) ? v : null; };
    var flowchart = {}, sequence = {}, state = {}, classDiagram = {};

    var nodeSpacing = num(a.nodeSpacing);
    if (nodeSpacing !== null) { flowchart.nodeSpacing = nodeSpacing; }
    var rankSpacing = num(a.rankSpacing);
    if (rankSpacing !== null) { flowchart.rankSpacing = rankSpacing; }
    var padding = num(a.padding);
    if (padding !== null) { flowchart.padding = padding; classDiagram.padding = padding; }
    var diagramPadding = num(a.diagramPadding);
    if (diagramPadding !== null) {
      flowchart.diagramPadding = diagramPadding;
      state.diagramPadding = diagramPadding;
      classDiagram.diagramPadding = diagramPadding;
    }
    if (typeof a.curve === "string" && a.curve) { flowchart.curve = a.curve; }
    var wrappingWidth = num(a.wrappingWidth);
    if (wrappingWidth !== null) { flowchart.wrappingWidth = wrappingWidth; sequence.wrap = true; }

    if (Object.keys(flowchart).length) cfg.flowchart = flowchart;
    if (Object.keys(sequence).length) cfg.sequence = sequence;
    if (Object.keys(state).length) cfg.state = state;
    if (Object.keys(classDiagram).length) cfg.class = classDiagram;
  }

  // Post-render sweep over the detached node. <style> is deliberately NOT removed:
  // mermaid ships the entire theme as one <style> element inside the SVG.
  // Elements that must never survive anywhere, inside a <foreignObject> label included: each one
  // either fetches something, embeds a document, or animates an attribute we cannot vet.
  var BANNED = "script,iframe,object,embed,link,meta,base,image,img,picture,source,audio,video," +
    "form,input,button,select,textarea,animate,animateTransform,animateMotion,set,handler,math";
  // The tags mermaid's HTML labels are actually built from. Anything else inside a label is
  // unwrapped -- its text is kept, the element is not.
  var LABEL_TAGS = {
    DIV: 1, SPAN: 1, BR: 1, P: 1, B: 1, I: 1, EM: 1, STRONG: 1, U: 1, S: 1,
    SUB: 1, SUP: 1, CODE: 1, PRE: 1, UL: 1, OL: 1, LI: 1, LABEL: 1, SMALL: 1
  };

  function unwrap(el) {
    el.replaceWith.apply(el, Array.prototype.slice.call(el.childNodes));
  }

  function scrub(root) {
    var removed = [];
    root.querySelectorAll(BANNED).forEach(function (n) { removed.push(n.tagName.toLowerCase()); n.remove(); });
    // <foreignObject> is kept, not deleted. eventmodeling emits every node label as one even with
    // htmlLabels off, so deleting them left the boxes empty -- the diagram drew with no text at
    // all. The HTML inside is reduced to the label vocabulary instead, and the attribute pass
    // below then runs over it like any other element. Script cannot execute here regardless: the
    // page has no script-src and default-src is 'none'.
    root.querySelectorAll("foreignObject").forEach(function (fo) {
      var inner = fo.querySelectorAll("*");
      for (var j = 0; j < inner.length; j++) {
        var node = inner[j];
        if (!node.isConnected) continue;
        if (!LABEL_TAGS[node.tagName.toUpperCase()]) {
          removed.push("foreignobject>" + node.tagName.toLowerCase());
          unwrap(node);
        }
      }
    });
    // The theme arrives as one <style>, which is kept -- so it is read once on the way past. A
    // diagram that got a hazard into it through a theme variable loses the stylesheet rather than
    // the diagram: mermaid's shapes carry presentation attributes too, so an unstyled diagram is
    // still a diagram.
    root.querySelectorAll("style").forEach(function (node) {
      if (!STYLE_HAZARDS.test(node.textContent || "")) return;
      removed.push("style-hazard");
      node.remove();
    });
    root.querySelectorAll("a").forEach(function (a) { unwrap(a); });
    var nodes = [root];
    var w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    while (w.nextNode()) nodes.push(w.currentNode);
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var attrs = Array.prototype.slice.call(el.attributes || []);
      for (var k = 0; k < attrs.length; k++) {
        var at = attrs[k];
        var n = at.name.toLowerCase();
        var v = (at.value || "").trim();
        if (n.indexOf("on") === 0) { removed.push("@" + n); el.removeAttribute(at.name); continue; }
        if ((n === "href" || n === "xlink:href" || n === "src" || n === "from" || n === "to") && v.charAt(0) !== "#") {
          removed.push("@" + n); el.removeAttribute(at.name); continue;
        }
        if (n === "style" && /url\s*\(\s*(?!#)/i.test(v)) { removed.push("@style-url"); el.removeAttribute(at.name); }
      }
    }
    return removed;
  }

  // ---------------------------------------------------------------------------
  // Readable labels.
  //
  // A diagram is authoritative about its own colours, with one gap: `style X fill:#fdd` says what
  // the box is, and says nothing about the text on it. mermaid leaves the label at the palette's
  // colour, so under the dark theme a pale fill gets `rgb(204,204,204)` ink on `rgb(255,221,221)`
  // paper, which is 1.27:1 -- text that is there and cannot be read. This pass corrects that one
  // case and touches nothing else.
  //
  // What makes it safe to do automatically is that mermaid marks the author's intent for us: a
  // `color:` in `style` or `classDef` arrives as an inline `fill:...!important` on the <text>
  // itself, and a label the author said nothing about has no style attribute at all. So "the
  // author chose this" is a fact to read, not a guess. Everything else is left alone as well: a
  // label with contrast to spare, a label with no measurable shape behind it, the fills, the
  // strokes and the theme.
  // ---------------------------------------------------------------------------

  function parseRGB(value) {
    var m = /rgba?\(([^)]+)\)/.exec(value || "");
    if (!m) return null;
    var parts = m[1].split(",");
    if (parts.length > 3 && parseFloat(parts[3]) === 0) return null;
    var rgb = [parseFloat(parts[0]), parseFloat(parts[1]), parseFloat(parts[2])];
    if (rgb.some(function (c) { return !isFinite(c); })) return null;
    return rgb;
  }

  function hexToRGB(hex) {
    var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || "").trim());
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  // WCAG 2.1 relative luminance and contrast ratio.
  function luminance(rgb) {
    var c = [rgb[0] / 255, rgb[1] / 255, rgb[2] / 255].map(function (v) {
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }

  function contrast(a, b) {
    var la = luminance(a), lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
  }

  /// The colour an element actually paints, or null if it paints nothing. Zero-sized boxes are the
  /// reason this checks geometry: mermaid puts two opaque `rect`s inside every flowchart label at
  /// 0x0, and reading their fill instead of the node's would say every label is on the theme
  /// background when it is not.
  function paintedFill(el) {
    var cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden") return null;
    if (parseFloat(cs.opacity) === 0 || parseFloat(cs.fillOpacity) === 0) return null;
    var rgb = parseRGB(cs.fill);
    if (!rgb) return null;
    var box = el.getBoundingClientRect();
    if (!(box.width > 0.5 && box.height > 0.5)) return null;
    return { rgb: rgb, box: box };
  }

  /// What is behind a label: the nearest painted shape, in an ancestor, that the label sits inside.
  ///
  /// Measured in client space rather than with getBBox, because a bbox is in its own element's user
  /// space and the shape and the label are in different ones -- comparing them there compares two
  /// unrelated coordinate systems and quietly matches the wrong box.
  function paperUnder(label) {
    var box = label.getBoundingClientRect();
    var authored = false;
    var cx = box.left + box.width / 2, cy = box.top + box.height / 2;
    var el = label.parentElement;
    while (el && el.tagName.toLowerCase() !== "svg") {
      var found = null;
      var kids = el.children;
      for (var i = 0; i < kids.length; i++) {
        var kid = kids[i];
        // Painters order: only what is drawn before the label is behind it.
        if (kid === label || kid.contains(label)) break;
        if (kid.tagName.toLowerCase() === "g") continue;
        var paint = paintedFill(kid);
        if (!paint) continue;
        var r = paint.box;
        if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
          found = paint.rgb;
          // `style N fill:#fdd` and `classDef` reach the shape as an inline fill, the same way a
          // `color:` reaches the text. So the paper knows whether a person chose it.
          authored = /(^|;)\s*fill\s*:/i.test(kid.getAttribute("style") || "");
        }
      }
      if (found) return { rgb: found, authored: authored };
      el = el.parentElement;
    }
    return null;   // nothing measurable behind it; the canvas may be glass, so do not guess
  }

  function authorChoseInk(el, property) {
    return new RegExp("(^|;)\\s*" + property + "\\s*:", "i").test(el.getAttribute("style") || "");
  }

  /// Returns how many labels were corrected.
  function makeLabelsReadable(root, policy) {
    if (!policy || policy.enabled !== true) return 0;
    // Two thresholds, because the two cases are not the same mistake. On a fill a person chose,
    // the palette's ink is simply the wrong ink and the label should clear AA outright. Everywhere
    // else the colours are the theme's own and worth leaving alone: mermaid's dark edge-label chip
    // sits at 4.43:1, which is under AA and perfectly legible, and correcting it would repaint
    // every diagram in the app to fix nothing. So an unauthored label is only touched when it has
    // fallen below the point where text stops being readable at all.
    var authoredRatio = Number(policy.ratio) || 4.5;
    var floorRatio = Number(policy.floor) || 3;
    var darkInk = hexToRGB(policy.darkInk) || [28, 28, 30];
    var lightInk = hexToRGB(policy.lightInk) || [255, 255, 255];
    var corrected = 0;
    // The element that paints the glyphs, which is not always the <text>. mermaid's sequence
    // stylesheet gives `.actor` a fill for the actor box and that rule also matches the actor's
    // <text>, whose computed fill then reads `rgb(236,236,255)` -- the colour of the box behind it.
    // The name is drawn black by a `text.actor > tspan` rule one level down. Reading the <text>
    // there measured ink against itself at 1:1 and "corrected" four labels that were perfectly
    // legible, so the ink is read where it is actually applied: the innermost element with text in
    // it.
    function inkLeaves(el) {
      var leaves = [];
      el.querySelectorAll("tspan").forEach(function (sp) {
        if (sp.querySelector("tspan")) return;
        if (String(sp.textContent || "").trim()) leaves.push(sp);
      });
      return leaves.length ? leaves : [el];
    }

    // SVG labels carry their colour in `fill`; the HTML ones eventmodeling emits carry it in
    // `color`. Both are handled, and an inline value of either means the author has spoken.
    var labels = [];
    root.querySelectorAll("text").forEach(function (t) { labels.push([t, "fill"]); });
    root.querySelectorAll("foreignObject div, foreignObject span").forEach(function (d) {
      if (d.querySelector("div, span")) return;   // only the element the glyphs are actually in
      labels.push([d, "color"]);
    });
    for (var i = 0; i < labels.length; i++) {
      var el = labels[i][0], property = labels[i][1];
      if (!String(el.textContent || "").trim()) continue;
      if (authorChoseInk(el, property)) continue;
      // Read where the colour lands, decide for the label as a whole, write at the top of it.
      var leaves = property === "fill" ? inkLeaves(el) : [el];
      var ink = parseRGB(getComputedStyle(leaves[0])[property]);
      if (!ink) continue;
      if (authorChoseInk(leaves[0], property)) continue;
      var paper = paperUnder(el);
      if (!paper) continue;
      var wanted = paper.authored ? authoredRatio : floorRatio;
      if (contrast(ink, paper.rgb) >= wanted) continue;
      var replacement = contrast(darkInk, paper.rgb) >= contrast(lightInk, paper.rgb)
        ? policy.darkInk : policy.lightInk;
      el.style.setProperty(property, replacement, "important");
      // One inline declaration per label wherever inheritance carries it, which is most diagrams.
      // Where a rule further down wins anyway -- `text.actor > tspan` is one -- the leaves are told
      // as well rather than leaving a correction that changes the file and not the picture.
      var landed = parseRGB(getComputedStyle(leaves[0])[property]);
      var target = hexToRGB(replacement);
      if (!landed || !target || landed[0] !== target[0] || landed[1] !== target[1] || landed[2] !== target[2]) {
        for (var k = 0; k < leaves.length; k++) leaves[k].style.setProperty(property, replacement, "important");
      }
      corrected++;
    }
    return corrected;
  }

  function classify(message) {
    if (/Edge limit exceeded/.test(message)) return "edge-limit";
    if (/No diagram type detected/.test(message)) return "unknown-type";
    return "parse";
  }

  // ---------------------------------------------------------------------------
  // Structural rungs.
  //
  // A theme can say what a node type looks like; it cannot say what a node IS, because mermaid
  // emits no node type, no shape name and no degree. This pass reads the graph's own shape out of
  // the markup -- in-degree, out-degree, declared cylinders, subgraph membership -- and writes
  // class tokens: `fp-backend` / `fp-store` / `fp-entry` / `fp-terminal` / `fp-optional` /
  // `fp-focal` on nodes, `fp-accent` and `fp-cross` on edges and their labels. Not one colour
  // value appears in this file; the theme's stylesheet decides what each token looks like.
  //
  // Three things follow from that, and all three are why it is done this way:
  //
  //   a theme that asks for nothing is untouched. The sweep runs only when the theme's own CSS
  //   carries the marker rule, so the system theme's 124 goldens stay byte-identical;
  //
  //   an author still wins. mermaid emits `classDef` and `style` rules AFTER the theme's
  //   stylesheet and writes them with !important, so a node the author painted keeps the author's
  //   colour without a single check here;
  //
  //   and it is all attributes. Node ids carry the mermaid id, edge data-ids carry the endpoints,
  //   cluster rects and node transforms share one untransformed coordinate space. No getBBox, no
  //   getComputedStyle, no layout -- measured at 0.30ms on a 151-node graph against 3.7ms for the
  //   same walk asking for a bounding box, which is also why it can run on the detached node
  //   before anything is attached.
  //
  // What it deliberately does not do is guess. A diagram with no single busiest node gets no
  // accent at all, which is what the source itself asks for: leave it unaccented rather than
  // promoting an arbitrary node.
  // ---------------------------------------------------------------------------

  // The theme's opt-in. Read from the payload's CSS as a plain string, before mermaid compiles it.
  var LADDER_MARKER = ".fp-ladder";
  // The only families whose markup carries edge endpoints. stateDiagram's data-id is opaque
  // ("edge0"), and about half the supported types emit no edge metadata at all.
  var LADDER_TYPES = { "flowchart-v2": 1, "flowchart-elk": 1, "swimlane": 1 };

  function tagStructure(svg, renderID, diagramType, themeCSS) {
    if (String(themeCSS || "").indexOf(LADDER_MARKER) === -1) return null;
    if (!LADDER_TYPES[String(diagramType || "")]) return null;

    var prefix = String(renderID || "") + "-flowchart-";
    var byId = {}, nodes = [];
    svg.querySelectorAll("g.nodes > g.node").forEach(function (g) {
      var id = String(g.id || "");
      if (id.indexOf(prefix) !== 0) return;
      // "<renderID>-flowchart-<mermaidId>-<counter>", and a mermaid id may itself contain "-" and
      // "_", so take everything up to the trailing counter.
      var m = /^(.+)-(\d+)$/.exec(id.slice(prefix.length));
      if (!m) return;
      var rec = { el: g, id: m[1], inDeg: 0, outDeg: 0, edges: 0, dotted: 0, incoming: [] };
      byId[m[1]] = rec;
      nodes.push(rec);
    });
    if (nodes.length < 2) return null;

    // data-id is "L_" + from + "_" + to + "_" + counter, and both halves may contain underscores --
    // `a_1 --> b_2` emits L_a_1_b_2_0. Resolve the split against the ids that actually exist rather
    // than guessing, and give up rather than guess when none of them matches: an author-defined
    // edge id replaces the convention outright.
    function endpoints(dataID) {
      var m = /^L_(.+)_(\d+)$/.exec(dataID || "");
      if (!m) return null;
      var body = m[1];
      for (var i = 1; i < body.length - 1; i++) {
        if (body.charAt(i) !== "_") continue;
        var from = byId[body.slice(0, i)], to = byId[body.slice(i + 1)];
        if (from && to) return [from, to];
      }
      return null;
    }

    var edges = [];
    svg.querySelectorAll("g.edgePaths path[data-id]").forEach(function (path) {
      var pair = endpoints(path.getAttribute("data-id"));
      if (!pair) return;
      // `.edge-pattern-solid` is worthless as a test: mermaid appends an unconditional
      // "edge-thickness-normal edge-pattern-solid" pair to every edge. Only dashed, dotted and
      // thick carry information.
      var dotted = path.classList.contains("edge-pattern-dotted");
      var patterned = dotted || path.classList.contains("edge-pattern-dashed");
      var edge = {
        path: path,
        id: String(path.getAttribute("data-id") || ""),
        from: pair[0],
        to: pair[1],
        patterned: patterned
      };
      pair[0].outDeg++; pair[1].inDeg++;
      pair[0].edges++; pair[1].edges++;
      if (dotted) { pair[0].dotted++; pair[1].dotted++; }
      pair[1].incoming.push(edge);
      edges.push(edge);
    });
    if (!edges.length) return null;

    // Subgraph membership is not in the DOM: g.clusters and g.nodes are flat siblings even for
    // nested subgraphs. But neither they nor g.root carry a transform, so a cluster rect's
    // x/y/width/height and a node's translate() are directly comparable. Innermost wins.
    var zones = [];
    svg.querySelectorAll("g.clusters > g.cluster").forEach(function (cluster) {
      var r = cluster.querySelector("rect");
      if (!r) return;
      var x = parseFloat(r.getAttribute("x")), y = parseFloat(r.getAttribute("y"));
      var w = parseFloat(r.getAttribute("width")), h = parseFloat(r.getAttribute("height"));
      if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h)) return;
      zones.push({ x: x, y: y, w: w, h: h, area: w * h });
    });

    function zoneOf(rec) {
      if (!zones.length) return null;
      var t = /translate\(\s*([-\d.]+)[\s,]+([-\d.]+)/.exec(rec.el.getAttribute("transform") || "");
      if (!t) return null;
      var cx = parseFloat(t[1]), cy = parseFloat(t[2]), best = null;
      for (var i = 0; i < zones.length; i++) {
        var z = zones[i];
        if (cx < z.x || cx > z.x + z.w || cy < z.y || cy > z.y + z.h) continue;
        if (!best || z.area < best.area) best = z;
      }
      return best;
    }

    // A cylinder is a bare <path class="basic label-container outer-path">; a stadium is a <g> of
    // the same classes holding two paths. That tagName difference is the whole discriminator, and
    // it is the one place a shape decides a rung -- because a cylinder is the author declaring a
    // datastore, not us inferring one.
    function isCylinder(rec) {
      var shape = rec.el.firstElementChild;
      return !!shape && shape.tagName.toLowerCase() === "path" && shape.classList.contains("outer-path");
    }

    // `style X fill:#900` and `classDef` reach the shape as an inline fill -- the same fact
    // `paperUnder` already reads. "The author chose this" is readable, not guessable.
    function authored(rec) {
      var shape = rec.el.firstElementChild;
      return !!shape && /(^|;)\s*fill\s*:/i.test(shape.getAttribute("style") || "");
    }

    var counts = {
      backend: 0, store: 0, entry: 0, terminal: 0, optional: 0, focal: 0, accent: 0, cross: 0
    };
    nodes.forEach(function (n) {
      var rung = isCylinder(n) ? "store"
        : (n.inDeg === 0 && n.outDeg > 0) ? "entry"
        : (n.outDeg === 0 && n.inDeg > 0) ? "terminal"
        : "backend";
      // Author intent outranks computed role: a node reached only by `-.->` is conditional.
      if (n.edges > 0 && n.dotted === n.edges) rung = "optional";
      n.rung = rung;
      n.el.classList.add("fp-" + rung);
      counts[rung]++;
    });

    // ------------------------------------------------------------------------
    // The focal node: one, or none, and none is the common answer.
    //
    // The only structure that names a single thing to look at without inventing a story is a node
    // that is busier than everything else on the page -- the API-gateway case. A rule that fired on
    // "the last node" would fire on every linear chain the app previews, which is how an editorial
    // accent turns into "this is where the arrows stop", the one thing the source calls an
    // anti-pattern. So: strictly one node at the top, and genuinely busy, or nothing.
    // ------------------------------------------------------------------------
    var focal = null;
    if (nodes.length >= 4) {
      var top = null, ties = 0;
      for (var i = 0; i < nodes.length; i++) {
        var degree = nodes[i].inDeg + nodes[i].outDeg;
        if (!top || degree > top.degree) { top = { rec: nodes[i], degree: degree }; ties = 1; }
        else if (degree === top.degree) ties++;
      }
      if (top && ties === 1 && top.degree >= 4) focal = top.rec;
      // The author has already said where to look.
      if (focal && authored(focal)) focal = null;
    }

    // One cloned arrowhead per kind. Every arrow in a flowchart points at the same shared marker,
    // so a per-edge head is the one thing CSS cannot do -- and mermaid clones markers for
    // `linkStyle` itself, which is the precedent. `marker-end="url(#…)"` survives the scrub by
    // construction: it is not one of the attributes the scrub rewrites, and its url() points inside
    // the document.
    var markers = {};
    function retarget(path, kind) {
      var ref = /url\(#([^)]+)\)/.exec(path.getAttribute("marker-end") || "");
      if (!ref) return;
      if (!markers[kind]) {
        var source = null, all = svg.querySelectorAll("marker");
        for (var i = 0; i < all.length; i++) {
          if (all[i].id === ref[1]) { source = all[i]; break; }
        }
        if (!source || !source.parentNode) return;
        var clone = source.cloneNode(true);
        clone.id = String(renderID || "fp") + "-fp-" + kind + "-head";
        // Drop mermaid's own `marker` class so only the theme's fp- rule paints the clone.
        clone.setAttribute("class", "fp-marker fp-marker-" + kind);
        source.parentNode.appendChild(clone);
        markers[kind] = clone;
      }
      path.setAttribute("marker-end", "url(#" + markers[kind].id + ")");
    }

    function tagEdge(edge, kind) {
      edge.path.classList.add("fp-" + kind);
      // The label group carries the same data-id as its path. An author-chosen edge id could carry
      // a quote, which would be a broken selector rather than a styled label.
      if (edge.id && !/["\\\]]/.test(edge.id)) {
        svg.querySelectorAll('g.edgeLabels g.label[data-id="' + edge.id + '"]').forEach(function (l) {
          l.classList.add("fp-" + kind);
        });
      }
      retarget(edge.path, kind);
      counts[kind]++;
    }

    if (focal) {
      focal.el.classList.remove("fp-" + focal.rung);
      counts[focal.rung]--;
      focal.el.classList.add("fp-focal");
      counts.focal = 1;
      // The accent edge is derived from the focal node, never chosen: the one edge into it, with
      // its arrowhead and its label, which is the part that carries the accent off the node and
      // along the flow.
      //
      // It abstains on a tie, the same way the focal node itself does. Breaking the tie on DOM
      // order is deterministic but not defensible on the page: two entry nodes that are alike in
      // every way, one of whose edges is coral, asks the reader to find a difference that is not
      // there. Rendered and looked at, that is exactly how it read. No edge is better than an
      // arbitrary one -- the node still carries the accent.
      var best = null;
      var tied = false;
      for (var e = 0; e < focal.incoming.length; e++) {
        var candidate = focal.incoming[e];
        if (!best || candidate.from.outDeg > best.from.outDeg) {
          best = candidate;
          tied = false;
        } else if (candidate.from.outDeg === best.from.outDeg) {
          tied = true;
        }
      }
      if (best && !tied) tagEdge(best, "accent");
    }

    // The second edge class: a path that leaves one zone and enters another, which is the source's
    // own trigger for it. Both ends have to be IN a zone -- an edge to a node that is in no
    // subgraph has not crossed a boundary, and counting it as one made every edge in a
    // half-grouped diagram "crossing". Capped so it stays a category rather than becoming the
    // default stroke, and an edge the author already patterned is left alone because the class
    // carries its own dash.
    if (zones.length) {
      var crossing = [];
      for (var k = 0; k < edges.length; k++) {
        var edge = edges[k];
        if (edge.patterned || edge.path.classList.contains("fp-accent")) continue;
        var from = zoneOf(edge.from), to = zoneOf(edge.to);
        if (from && to && from !== to) crossing.push(edge);
      }
      if (crossing.length && crossing.length <= 6 && crossing.length * 3 <= edges.length) {
        for (var c = 0; c < crossing.length; c++) tagEdge(crossing[c], "cross");
      }
    }

    // Counts only. Nothing here names a node, an edge or a label: what the reader is previewing
    // never leaves this function.
    return { nodes: nodes.length, edges: edges.length, zones: zones.length, rungs: counts };
  }

  async function render(rawPayload) {
    var p;
    try {
      p = parsePayload(rawPayload);
    } catch (e) {
      return fail("internal", "payload is not valid JSON: " + String((e && e.message) || e));
    }
    if (!p || typeof p.source !== "string") return fail("internal", "payload is missing a source string");

    var mm = engine();
    if (!mm || typeof mm.render !== "function" || typeof mm.parse !== "function") {
      return fail("engine-missing", "the mermaid engine is not present in this content world");
    }
    var diagram = document.getElementById("diagram");
    if (!diagram) return fail("engine-not-ready", "the engine page has no #diagram element");

    diagram.replaceChildren();
    clearGeometry();
    var t0 = now();
    measurementFallbacks = [];
    var wipeMeasure = function () {
      var m = document.getElementById("measure");
      if (m) m.replaceChildren();
    };
    try {
      mm.initialize(buildConfig(p));
      await mm.parse(p.source); // deliberately no options object - we want parse() to throw
      // Render into an attached, off-screen box rather than mermaid's default container: a
      // renderer that measures with getBBox() needs a live render tree, and without this
      // eventmodeling's data blocks throw "svg element not in render tree".
      var measure = document.getElementById("measure");
      var r = await mm.render(String(p.renderID || "fp-0"), p.source, measure || undefined);
      var doc = new DOMParser().parseFromString("<!doctype html><body>" + r.svg, "text/html");
      var svg = doc.body.querySelector("svg");
      if (!svg) { wipeMeasure(); return fail("render-no-svg", "mermaid returned no <svg> element"); }
      var node = document.importNode(svg, true);
      var scrubbed = scrub(node);
      // Structural rungs, on the detached node: this pass touches no layout, so it costs nothing
      // here, and it must run before makeLabelsReadable(), which reads computed fills.
      tagStructure(node, String(p.renderID || "fp-0"), r.diagramType, p.themeCSS);
      diagram.replaceChildren(node);

      // Post-condition: an <svg> is really in the live DOM, or this is a failure.
      var live = diagram.firstElementChild;
      if (!(live instanceof SVGSVGElement)) {
        diagram.replaceChildren();
        clearGeometry();
        wipeMeasure();
        return fail("render-no-svg", "nothing was attached to #diagram");
      }
      if (String(live.textContent || "").indexOf("Maximum text size in diagram exceeded") !== -1) {
        diagram.replaceChildren();
        clearGeometry();
        wipeMeasure();
        return fail("too-large", "mermaid substituted its size-limit placeholder");
      }
      // Ink that can be read on the paper the author chose, before the drawing is measured or
      // handed back: the SVG returned here is the one an export is drawn from, so a corrected
      // label has to be corrected in it too.
      var labelsCorrected = makeLabelsReadable(live, p.labelContrast);

      // Pin the SVG to its natural size and fit it to the stage. The reported width/height are the
      // resolved ones, so a diagram without a viewBox (`info`) is no longer read as "drew nothing".
      bindGestures();
      var geometry = adoptGeometry(live);
      fit();
      wipeMeasure();
      return J({
        ok: true,
        diagramType: String(r.diagramType || ""),
        width: geometry.width,
        height: geometry.height,
        scrubbed: scrubbed,
        labelsCorrected: labelsCorrected,
        svg: live.outerHTML,
        durationMS: Math.round(now() - t0),
        engineVersion: engineVersion(),
        // Two kinds of substitution, both worth reporting: the measurements FlowPeek had
        // to supply because WebKit refused them, and the source the SVG's size was
        // finally read from. Swift keys its "size estimated" notice off the latter's
        // marker and shows the rest as engine detail.
        measurementFallbacks: measurementFallbacks.concat(geometry.measurementFallbacks)
      });
    } catch (e) {
      diagram.replaceChildren();
      clearGeometry();
      wipeMeasure();
      var msg = String((e && e.message) || e);
      return fail(classify(msg), msg, (e && e.hash && e.hash.loc && e.hash.loc.first_line) || null);
    }
  }

  async function selfTest(rawPayload) {
    var p;
    try {
      p = parsePayload(rawPayload) || {};
    } catch (e) {
      p = {};
    }
    var t0 = now();
    var r;
    try {
      r = JSON.parse(await render({
        source: CANARY_SOURCE,
        renderID: p.renderID || "fp-selftest",
        seed: p.seed || "flowpeek-selftest",
        themeVariables: p.themeVariables,
        themeCSS: p.themeCSS,
        fontFamily: p.fontFamily
      }));
    } catch (e) {
      r = { ok: false, code: "internal", message: String((e && e.message) || e) };
    }
    return JSON.stringify({
      ok: r.ok === true,
      code: r.code || null,
      message: r.message || null,
      diagramType: r.diagramType || null,
      width: r.width || 0,
      height: r.height || 0,
      scrubbed: r.scrubbed || [],
      cspViolations: cspViolations.slice(),
      engineVersion: engineVersion(),
      canaryMS: Math.round(now() - t0)
    });
  }

  // ---------------------------------------------------------------------------
  // Viewport: zoom is a transform on #diagram; the *layout* size of #canvas tracks it, so panning
  // is ordinary scrolling and the SVG stays vector-crisp at every scale.
  // ---------------------------------------------------------------------------
  var vp = { w: 0, h: 0, scale: 1, min: 0.05, max: 8, fitMax: 2, pad: 24 };

  function els() {
    return {
      stage: document.getElementById("stage"),
      canvas: document.getElementById("canvas"),
      diagram: document.getElementById("diagram")
    };
  }

  function publish() {
    try {
      var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.flowpeekViewport;
      if (mh) mh.postMessage({ scale: vp.scale, width: vp.w, height: vp.h });
    } catch (e) { /* the host may not have installed a handler (tests, self-test) */ }
  }

  function clampScale(s) {
    if (!isFinite(s) || s <= 0) return vp.scale;
    return Math.min(vp.max, Math.max(vp.min, s));
  }

  function applyLayout() {
    var e = els();
    if (!e.canvas || !e.diagram) return;
    e.canvas.style.width = Math.max(1, Math.round(vp.w * vp.scale)) + "px";
    e.canvas.style.height = Math.max(1, Math.round(vp.h * vp.scale)) + "px";
    e.diagram.style.width = vp.w + "px";
    e.diagram.style.height = vp.h + "px";
    e.diagram.style.transform = "scale(" + vp.scale + ")";
  }

  /// Zooms around a point given in client coordinates; omit the point to zoom about the centre.
  function setScaleAt(next, cx, cy) {
    var e = els();
    if (!e.stage || !e.canvas) return vp.scale;
    next = clampScale(next);
    var prev = vp.scale;
    if (Math.abs(next - prev) < 1e-6) return prev;
    var rect = e.stage.getBoundingClientRect();
    var px = (cx === undefined) ? e.stage.scrollLeft + e.stage.clientWidth / 2 : cx - rect.left + e.stage.scrollLeft;
    var py = (cy === undefined) ? e.stage.scrollTop + e.stage.clientHeight / 2 : cy - rect.top + e.stage.scrollTop;
    var dx = (px - e.canvas.offsetLeft) / prev;
    var dy = (py - e.canvas.offsetTop) / prev;
    vp.scale = next;
    applyLayout();
    e.stage.scrollLeft += dx * next + e.canvas.offsetLeft - px;
    e.stage.scrollTop += dy * next + e.canvas.offsetTop - py;
    publish();
    return vp.scale;
  }

  function setScale(value) {
    return setScaleAt(Number(value));
  }

  function zoomBy(factor) {
    var f = Number(factor);
    return setScaleAt(vp.scale * (isFinite(f) && f > 0 ? f : 1));
  }

  /// Scales the diagram to fill the stage, growing small diagrams up to `fitMax` rather than
  /// leaving them marooned at their natural size, then recentres.
  function fit() {
    var e = els();
    if (!e.stage || !e.canvas || vp.w <= 0 || vp.h <= 0) return vp.scale;
    var aw = Math.max(1, e.stage.clientWidth - vp.pad * 2);
    var ah = Math.max(1, e.stage.clientHeight - vp.pad * 2);
    vp.scale = clampScale(Math.min(vp.fitMax, Math.min(aw / vp.w, ah / vp.h)));
    applyLayout();
    e.stage.scrollLeft = (e.stage.scrollWidth - e.stage.clientWidth) / 2;
    e.stage.scrollTop = (e.stage.scrollHeight - e.stage.clientHeight) / 2;
    publish();
    return vp.scale;
  }

  /// Scrolls the stage by a pixel delta, which is what an arrow key from Swift has to land on:
  /// #stage is the scroller and nothing in this page is focusable, so there is no element a keydown
  /// listener here could ever be delivered to.
  function panBy(dx, dy) {
    var e = els();
    if (!e.stage) return { x: 0, y: 0 };
    var x = Number(dx), y = Number(dy);
    e.stage.scrollLeft += isFinite(x) ? x : 0;
    e.stage.scrollTop += isFinite(y) ? y : 0;
    return { x: e.stage.scrollLeft, y: e.stage.scrollTop };
  }

  function viewport() {
    return { scale: vp.scale, width: vp.w, height: vp.h };
  }

  /// Pins the freshly attached SVG to its natural pixel size. mermaid emits `width="100%"` with a
  /// `max-width` in the style attribute, which silently fits-to-width and then fought the zoom.
  function adoptGeometry(svg) {
    var w = 0, h = 0, fallbacks = [];
    try {
      var vb = svg.viewBox && svg.viewBox.baseVal;
      if (vb) { w = vb.width; h = vb.height; }
    } catch (e) { /* fall through to getBBox */ }
    if (!(w > 0 && h > 0)) {
      fallbacks.push("viewbox");
      try { var bb = svg.getBBox(); w = bb.width; h = bb.height; } catch (e2) { /* keep zero */ }
    }
    // Last resort: the CSS box, which is the size we imposed rather than the size of the drawing.
    // Swift turns this one into a quiet notice, because it is how a diagram comes out cropped.
    if (!(w > 0 && h > 0)) { fallbacks.push("bbox"); w = svg.clientWidth || 0; h = svg.clientHeight || 0; }
    if (w > 0 && h > 0) {
      svg.setAttribute("width", String(w));
      svg.setAttribute("height", String(h));
      svg.style.width = w + "px";
      svg.style.height = h + "px";
      svg.style.maxWidth = "none";
      svg.style.backgroundColor = "transparent";
    }
    vp.w = w;
    vp.h = h;
    return { width: w, height: h, measurementFallbacks: fallbacks };
  }

  function clearGeometry() {
    vp.w = 0;
    vp.h = 0;
    var e = els();
    if (e.canvas) { e.canvas.style.width = "0px"; e.canvas.style.height = "0px"; }
  }

  function bindGestures() {
    var e = els();
    if (!e.stage || e.stage.getAttribute("data-fp-bound") === "1") return;
    e.stage.setAttribute("data-fp-bound", "1");

    // Plain two-finger scrolling pans natively; only the pinch/⌘-wheel form zooms.
    e.stage.addEventListener("wheel", function (ev) {
      if (!ev.ctrlKey && !ev.metaKey) return;
      ev.preventDefault();
      setScaleAt(vp.scale * Math.exp(-ev.deltaY * 0.01), ev.clientX, ev.clientY);
    }, { passive: false });

    var gestureBase = 1;
    e.stage.addEventListener("gesturestart", function (ev) { ev.preventDefault(); gestureBase = vp.scale; }, { passive: false });
    e.stage.addEventListener("gesturechange", function (ev) {
      ev.preventDefault();
      setScaleAt(gestureBase * ev.scale, ev.clientX, ev.clientY);
    }, { passive: false });
    e.stage.addEventListener("gestureend", function (ev) { ev.preventDefault(); }, { passive: false });

    var pan = null;
    e.stage.addEventListener("mousedown", function (ev) {
      if (ev.button !== 0) return;
      pan = { x: ev.clientX, y: ev.clientY, left: e.stage.scrollLeft, top: e.stage.scrollTop };
      e.stage.classList.add("grabbing");
    });
    window.addEventListener("mousemove", function (ev) {
      if (!pan) return;
      ev.preventDefault();
      e.stage.scrollLeft = pan.left - (ev.clientX - pan.x);
      e.stage.scrollTop = pan.top - (ev.clientY - pan.y);
    });
    window.addEventListener("mouseup", function () {
      pan = null;
      e.stage.classList.remove("grabbing");
    });

    e.stage.addEventListener("dblclick", function (ev) {
      ev.preventDefault();
      if (Math.abs(vp.scale - 1) < 0.01) fit(); else setScaleAt(1, ev.clientX, ev.clientY);
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", bindGestures);
  } else {
    bindGestures();
  }

  // The colour the diagram's own theme calls paper, painted behind the drawing.
  //
  // On the document, not on the SVG. `adoptGeometry` forces the SVG's own background transparent
  // and must keep doing so: that is what lets the reader see through to their desktop, and what
  // keeps an exported SVG free of a background it never asked for. Without this the paper reached
  // PNG and PDF -- which are composited against `backgroundHex` in Swift -- but never the preview,
  // so the same diagram was one colour on screen and another in an export of it.
  //
  // An empty or unreadable value means "paint nothing", which is what the transparent canvas needs.
  function setPaper(hex) {
    var ok = typeof hex === "string" && /^#[0-9a-fA-F]{3,8}$/.test(hex);
    var value = ok ? hex : "";
    if (document.documentElement) document.documentElement.style.backgroundColor = value;
    if (document.body) document.body.style.backgroundColor = value;
    return value;
  }

  window.__flowpeek = {
    setPaper: setPaper,
    version: GLUE_VERSION,
    render: render,
    selfTest: selfTest,
    setScale: setScale,
    zoomBy: zoomBy,
    fit: fit,
    panBy: panBy,
    viewport: viewport,
    cspViolations: function () { return cspViolations.slice(); }
  };
})();
