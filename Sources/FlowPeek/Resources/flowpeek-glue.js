"use strict";
// FlowPeek render glue. Injected as a WKUserScript at .atDocumentStart into
// WKContentWorld.world(name: "flowpeek"), immediately after mermaid.min.js.
// Contract: every entry point ALWAYS resolves with a JSON string and never rejects.
(function () {
  var GLUE_VERSION = "1";
  var CANARY_SOURCE = "flowchart TD\n  A[Start] --> B[End]";
  var MAX_MESSAGE = 2000;
  var SECURE_KEYS = ["htmlLabels", "theme", "themeVariables", "themeCSS", "fontFamily", "altFontFamily", "layout", "look"];

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
      theme: "base",
      themeVariables: p.themeVariables || {},
      themeCSS: p.themeCSS || ""
    };
    if (p.fontFamily) cfg.fontFamily = p.fontFamily;
    return cfg;
  }

  // Post-render sweep over the detached node. <style> is deliberately NOT removed:
  // mermaid ships the entire theme as one <style> element inside the SVG.
  function scrub(root) {
    var removed = [];
    root.querySelectorAll("script,foreignObject,image,iframe,object,embed,link,meta,animate,set,handler,audio,video,source")
      .forEach(function (n) { removed.push(n.tagName.toLowerCase()); n.remove(); });
    root.querySelectorAll("a").forEach(function (a) { a.replaceWith.apply(a, Array.prototype.slice.call(a.childNodes)); });
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
    try {
      mm.initialize(buildConfig(p));
      await mm.parse(p.source); // deliberately no options object - we want parse() to throw
      var r = await mm.render(String(p.renderID || "fp-0"), p.source);
      var doc = new DOMParser().parseFromString("<!doctype html><body>" + r.svg, "text/html");
      var svg = doc.body.querySelector("svg");
      if (!svg) return fail("render-no-svg", "mermaid returned no <svg> element");
      var node = document.importNode(svg, true);
      var scrubbed = scrub(node);
      diagram.replaceChildren(node);

      // Post-condition: an <svg> is really in the live DOM, or this is a failure.
      var live = diagram.firstElementChild;
      if (!(live instanceof SVGSVGElement)) {
        diagram.replaceChildren();
        clearGeometry();
        return fail("render-no-svg", "nothing was attached to #diagram");
      }
      if (String(live.textContent || "").indexOf("Maximum text size in diagram exceeded") !== -1) {
        diagram.replaceChildren();
        clearGeometry();
        return fail("too-large", "mermaid substituted its size-limit placeholder");
      }
      // Pin the SVG to its natural size and fit it to the stage. The reported width/height are the
      // resolved ones, so a diagram without a viewBox (`info`) is no longer read as "drew nothing".
      bindGestures();
      var geometry = adoptGeometry(live);
      fit();
      return J({
        ok: true,
        diagramType: String(r.diagramType || ""),
        width: geometry.width,
        height: geometry.height,
        scrubbed: scrubbed,
        svg: live.outerHTML,
        durationMS: Math.round(now() - t0),
        engineVersion: engineVersion(),
        measurementFallbacks: geometry.measurementFallbacks
      });
    } catch (e) {
      diagram.replaceChildren();
      clearGeometry();
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
    viewport: viewport,
    cspViolations: function () { return cspViolations.slice(); }
  };
})();
