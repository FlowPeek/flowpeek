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
    return cfg;
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

  function classify(message) {
    if (/Edge limit exceeded/.test(message)) return "edge-limit";
    if (/No diagram type detected/.test(message)) return "unknown-type";
    return "parse";
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

  window.__flowpeek = {
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
