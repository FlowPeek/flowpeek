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
  // ===========================================================================

  // mermaid sanitizes every label through DOMPurify, which we have neither the DOM nor the budget
  // for. What the corpus actually pins is narrow: `A(<)` must come out `&lt;` (flow.spec.js:128)
  // while `A <br> end` must survive untouched (flow-singlenode.spec.js:147 and three siblings), and
  // `&`, `>` and `=` must pass through -- the `charTest('>', '&gt;')` and `charTest('=', '&equals;')`
  // cases sit commented out in the vendored file precisely because DOMPurify does not escape them.
  // So the rule is DOMPurify's own early exit plus one distinction: text with no `<` is returned
  // byte-for-byte, and a `<` that does not open a tag DOMPurify would keep becomes an entity.
  var TAG_AT_START = /^<\/?[A-Za-z][^<>]*>/;

  function sanitizeText(txt) {
    if (!txt || txt.indexOf("<") === -1) return txt;
    var out = "";
    var i = 0;
    while (i < txt.length) {
      if (txt.charAt(i) !== "<") {
        out += txt.charAt(i);
        i += 1;
        continue;
      }
      var tag = TAG_AT_START.exec(txt.slice(i));
      if (tag) {
        out += tag[0];
        i += tag[0].length;
      } else {
        out += "&lt;";
        i += 1;
      }
    }
    return out;
  }

  // mermaid routes a `click ... href` target through @braintree/sanitize-url whenever the security
  // level is anything but loose. The package's whole job is the scheme check below; the interspersed
  // whitespace in the pattern is how `java\tscript:` gets caught.
  var UNSAFE_SCHEME = /^[\u0000-\u0020]*(?:j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t|d\s*a\s*t\s*a|v\s*b\s*s\s*c\s*r\s*i\s*p\s*t)\s*:/i;

  function formatUrl(linkStr) {
    var url = String(linkStr).trim();
    if (!url) return undefined;
    if (CONFIG.securityLevel !== "loose") {
      return UNSAFE_SCHEME.test(url) ? "about:blank" : url;
    }
    return url;
  }

  // ===========================================================================
  // The `@{ ... }` metadata loader.
  //
  // mermaid hands the accumulated SHAPE_DATA run to js-yaml under JSON_SCHEMA, wrapping a run with
  // no newline in braces so it parses as a flow mapping (flowDb.reference.ts:141-150). Pulling
  // js-yaml in is not an option here, and the grammar only ever produces a mapping of scalars, so
  // this covers exactly that: flow and block mappings, single- and double-quoted scalars, `|` block
  // scalars, and JSON_SCHEMA's resolution rules -- under which `yes`/`no` stay strings and only
  // `true`/`false`/`null`/numbers convert.
  // ===========================================================================

  function leadingWidth(line) {
    var n = 0;
    while (n < line.length && (line.charAt(n) === " " || line.charAt(n) === "\t")) n += 1;
    return n;
  }

  // Splits on a delimiter that is not inside a quoted scalar. Used for the `,` between flow-mapping
  // entries and for the `:` between a key and its value, which is why `label: "a, b:c"` survives.
  function splitOutsideQuotes(s, delim, once) {
    var parts = [];
    var buf = "";
    var quote = null;
    for (var i = 0; i < s.length; i += 1) {
      var c = s.charAt(i);
      if (quote) {
        buf += c;
        if (c === quote) quote = null;
        continue;
      }
      if (c === '"' || c === "'") {
        quote = c;
        buf += c;
        continue;
      }
      if (c === delim) {
        parts.push(buf);
        if (once) {
          parts.push(s.slice(i + 1));
          return parts;
        }
        buf = "";
        continue;
      }
      buf += c;
    }
    parts.push(buf);
    return parts;
  }

  var YAML_INT = /^-?(?:0|[1-9][0-9]*)$/;
  var YAML_FLOAT = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?$/;

  function unquoteDouble(body) {
    var out = "";
    for (var i = 0; i < body.length; i += 1) {
      var c = body.charAt(i);
      if (c !== "\\") {
        out += c;
        continue;
      }
      i += 1;
      var e = body.charAt(i);
      if (e === "n") out += "\n";
      else if (e === "t") out += "\t";
      else if (e === "r") out += "\r";
      else out += e;
    }
    return out;
  }

  function yamlScalar(raw) {
    if (raw === "" || raw === "~" || raw === "null") return null;
    var last = raw.charAt(raw.length - 1);
    if (raw.length > 1 && raw.charAt(0) === '"' && last === '"') return unquoteDouble(raw.slice(1, -1));
    if (raw.length > 1 && raw.charAt(0) === "'" && last === "'") return raw.slice(1, -1).replace(/''/g, "'");
    if (raw === "true") return true;
    if (raw === "false") return false;
    if (YAML_INT.test(raw)) return parseInt(raw, 10);
    if (YAML_FLOAT.test(raw)) return parseFloat(raw);
    return raw;
  }

  function yamlFlowMapping(src) {
    var doc = {};
    var entries = splitOutsideQuotes(src, ",", false);
    for (var i = 0; i < entries.length; i += 1) {
      if (entries[i].trim() === "") continue;
      var pair = splitOutsideQuotes(entries[i], ":", true);
      if (pair.length < 2) continue;
      doc[pair[0].trim()] = yamlScalar(pair[1].trim());
    }
    return doc;
  }

  function yamlBlockMapping(src) {
    var doc = {};
    var lines = src.split("\n");
    for (var i = 0; i < lines.length; i += 1) {
      if (lines[i].trim() === "") continue;
      var pair = splitOutsideQuotes(lines[i], ":", true);
      if (pair.length < 2) continue;
      var key = pair[0].trim();
      var raw = pair[1].trim();
      if (raw !== "|" && raw !== "|-" && raw !== ">" && raw !== ">-") {
        doc[key] = yamlScalar(raw);
        continue;
      }
      // A block scalar owns every following line indented deeper than its key.
      var indent = leadingWidth(lines[i]);
      var body = [];
      var j = i + 1;
      while (j < lines.length && (lines[j].trim() === "" || leadingWidth(lines[j]) > indent)) {
        body.push(lines[j]);
        j += 1;
      }
      while (body.length && body[body.length - 1].trim() === "") body.pop();
      var strip = body.length ? leadingWidth(body[0]) : 0;
      for (var b = 0; b < body.length; b += 1) body[b] = body[b].slice(strip);
      var folded = raw.charAt(0) === ">" ? body.join(" ") : body.join("\n");
      doc[key] = raw.length === 1 ? folded + "\n" : folded;
      i = j - 1;
    }
    return doc;
  }

  function loadShapeData(metadata) {
    return metadata.indexOf("\n") === -1 ? yamlFlowMapping(metadata) : yamlBlockMapping(metadata);
  }

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

  function R(states, source, action) {
    RULES.push({
      states: states,
      re: new RegExp(typeof source === "string" ? source : source.source, "y"),
      act: action
    });
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

  // A keyword is only ever recognised at a token start, and NODE_STRING below is greedy across `-`,
  // `.`, `_` and `/`, so `a-graph-node` and `endpoint` are single ids while `graph.node` is not.
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
  // The word boundary saves `endpoint`, and the trailing `\s*` swallows the newline after `end` --
  // which is why the subgraph production has no separator of its own.
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
  }

  Lexer.prototype.begin = function (condition) { this.stack.push(condition); };
  Lexer.prototype.popState = function () { if (this.stack.length > 1) this.stack.pop(); };

  Lexer.prototype.next = function () {
    for (;;) {
      // `<<EOF>>` is declared INITIAL-only, but jison-lex answers EOF from any state once the input
      // runs out. Reporting a lexical error instead would turn the unterminated-ellipse case into
      // the wrong kind of failure -- flow-text.spec.js:538 wants a parse error, not a hang.
      if (this.pos >= this.input.length) return { type: "EOF", value: "", pos: this.pos };

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
        throw new Error("Lexical error on line " + lineOf(this.input, this.pos) + ": Unrecognized text.");
      }

      var start = this.pos;
      var depth = this.stack.length;
      this.yytext = matched.text;
      this.pos += matched.text.length;
      var name = matched.rule.act(this);
      // jison would spin here; a rule that neither consumes input nor changes condition can only be
      // reached by input mermaid also cannot lex, so failing loudly is the honest answer.
      if (matched.text.length === 0 && this.stack.length === depth) {
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
