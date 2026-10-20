#!/usr/bin/env node
// engine_spec §9 T4 — offline conformance pass over the VENDORED renderer bundles.
// Loads Sources/FlowPeek/Resources/mermaid.min.js into a bare vm context (no DOM, no
// fetch, no fs) and asserts the bundle is self-contained, that its detector registry
// matches the checked-in table byte for byte, and that zenuml is absent. Then the same
// self-containment pass over pele.global.js, plus the version pin.
// Exits non-zero on any violation.

import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const bundlePath = join(root, "Sources/FlowPeek/Resources/mermaid.min.js");
// engine_spec §9 T4(c): the SAME corpus Tests/FlowPeekCoreTests/MermaidDetectorCorpusTests.swift
// drives through MermaidDetector's hand-maintained table. One file, so the two cannot diverge.
const corpusPath = join(root, "Tests/Fixtures/detector_corpus.json");

// mermaid 11.17.2 addDiagrams() registration order — mermaid.js:191816-191884.
// Regenerate with `npm run conformance` output whenever mermaid.min.js is re-vendored;
// a drift here means detector keywords changed and MermaidDetector must be revisited.
const EXPECTED_REGISTRY = [
  "error", "---", "flowchart-elk", "mindmap", "architecture", "c4", "kanban",
  "classDiagram", "class", "er", "gantt", "info", "pie", "requirement", "sequence",
  "swimlane", "flowchart-v2", "flowchart", "timeline", "gitGraph", "stateDiagram",
  "state", "journey", "quadrantChart", "sankey", "packet", "xychart", "block",
  "eventmodeling", "treeView", "radar", "ishikawa", "treemap", "railroad",
  "railroadEbnf", "railroadAbnf", "railroadPeg", "venn", "wardley", "cynefin",
];

// Every construct that would make the bundle reach outside itself at render time.
const FORBIDDEN = [
  ["dynamic import", /\bimport\s*\(/g],
  ["chunks reference", /chunks\//g],
  ["new Worker", /new\s+Worker\b/g],
  ["createObjectURL", /createObjectURL/g],
  ["new Function", /new\s+Function\b/g],
  ["bare eval", /(?:^|[^.\w$])eval\s*\(/g],
];

const failures = [];
const fail = (message) => failures.push(message);

// Shared by both bundles, because the rule is the same one and a copy of this loop is how the
// second bundle ends up checked against a stale list.
function scanForbidden(label, text) {
  for (const [name, pattern] of FORBIDDEN) {
    const count = (text.match(pattern) ?? []).length;
    console.log(`${count === 0 ? "ok   " : "FAIL "} ${label} ${name}: ${count}`);
    if (count !== 0) {
      fail(`${name} appears ${count} time(s) in ${label}; that bundle is no longer self-contained`);
    }
  }
}

let source;
try {
  source = readFileSync(bundlePath, "utf8");
} catch (error) {
  console.error(`FAIL  cannot read the vendored bundle at ${bundlePath}`);
  console.error(`      ${error.message}`);
  console.error("      run `npm run vendor:mermaid` first");
  process.exit(1);
}

console.log(`bundle  ${bundlePath}`);
console.log(`bytes   ${Buffer.byteLength(source)}`);

// (a) self-containment
scanForbidden("mermaid", source);

// Bare context: no document, no window, no fetch, no require, no process.
const sandbox = { console: { log() {}, warn() {}, error() {}, debug() {}, info() {} } };
const context = createContext(sandbox);

let mermaid;
try {
  runInContext(source, context, { filename: "mermaid.min.js" });
  mermaid = sandbox.mermaid;
} catch (error) {
  console.error(`FAIL  the bundle threw while loading in a bare vm context: ${error.message}`);
  process.exit(1);
}

if (!mermaid || typeof mermaid.getRegisteredDiagramsMetadata !== "function") {
  console.error("FAIL  the bundle did not expose a usable `mermaid` global in a bare vm context");
  process.exit(1);
}

// Populating the registry is itself the strongest self-containment proof: addDiagrams()
// runs every built-in loader, and this context has no DOM, no fetch and no filesystem.
try {
  const parsed = await mermaid.parse("graph TD;A-->B");
  console.log(`ok    parse() offline in a bare vm context: ${parsed.diagramType}`);
  if (parsed.diagramType !== "flowchart-v2") {
    fail(`\`graph TD\` resolved to ${parsed.diagramType}, not flowchart-v2; flowchart.defaultRenderer changed`);
  }
} catch (error) {
  console.error(`FAIL  parse() threw offline: ${error.message}`);
  process.exit(1);
}

// (b) registry parity
const registry = mermaid.getRegisteredDiagramsMetadata().map((entry) => entry.id);
const sameOrder =
  registry.length === EXPECTED_REGISTRY.length &&
  registry.every((id, index) => id === EXPECTED_REGISTRY[index]);

if (sameOrder) {
  console.log(`ok    registry: ${registry.length} ids match the checked-in table in order`);
} else {
  fail("the live detector registry drifted from the checked-in table");
  const missing = EXPECTED_REGISTRY.filter((id) => !registry.includes(id));
  const added = registry.filter((id) => !EXPECTED_REGISTRY.includes(id));
  console.error(`FAIL  registry drift (live ${registry.length}, expected ${EXPECTED_REGISTRY.length})`);
  if (missing.length) console.error(`      missing: ${missing.join(", ")}`);
  if (added.length) console.error(`      added:   ${added.join(", ")}`);
  if (!missing.length && !added.length) console.error("      same ids, different registration order — tie-breaking changed");
  console.error(`      live:     ${JSON.stringify(registry)}`);
  console.error(`      expected: ${JSON.stringify(EXPECTED_REGISTRY)}`);
}

// (c) detectType() agrees with MermaidDetector's Swift table over the whole corpus.
// Registry-id parity above is strictly weaker: a detector's regex can lose its bare form or
// tighten a boundary while all 40 ids stay byte-identical, and the Swift table would drift silently.
let corpus;
try {
  corpus = JSON.parse(readFileSync(corpusPath, "utf8"));
} catch (error) {
  console.error(`FAIL  cannot read the shared detector corpus at ${corpusPath}`);
  console.error(`      ${error.message}`);
  process.exit(1);
}

// `detectType` takes the effective config, and the flowchart/class/state detectors branch on
// `defaultRenderer`. Without it the legacy `flowchart` / `class` / `state` detectors win and every
// v2 id reads as drift. "dagre-wrapper" is mermaid 11.17.2's default — the only value that appears
// in the bundle — so this is what the running engine actually resolves.
const DETECT_CONFIG = {
  flowchart: { defaultRenderer: "dagre-wrapper" },
  class: { defaultRenderer: "dagre-wrapper" },
  state: { defaultRenderer: "dagre-wrapper" },
};

const disagreements = [];
for (const entry of corpus.cases) {
  let live = null;
  try {
    live = mermaid.detectType(entry.source, DETECT_CONFIG);
  } catch {
    live = null; // UnknownDiagramError — no detector claimed the text.
  }
  if (live !== entry.expected) {
    disagreements.push(
      `${entry.id}: live ${JSON.stringify(live)} vs table ${JSON.stringify(entry.expected)} for ${JSON.stringify(entry.source)}`
    );
  }
}

if (disagreements.length === 0) {
  console.log(`ok    detectType agrees with the Swift detector table on all ${corpus.cases.length} corpus rows`);
} else {
  fail(`detectType disagrees with MermaidDetector's table on ${disagreements.length} corpus row(s)`);
  console.error(`FAIL  detector drift on ${disagreements.length} of ${corpus.cases.length} rows`);
  for (const line of disagreements) console.error(`      ${line}`);
}

// (d) zenuml is an external diagram and must never be present
if (registry.includes("zenuml")) {
  fail("zenuml is registered; the bundle now needs registerExternalDiagrams and can reach the network");
  console.error("FAIL  zenuml present in the registry");
} else {
  console.log("ok    zenuml absent");
}

let zenumlDetects = false;
try {
  mermaid.detectType("zenuml\n  A->B: hi");
  zenumlDetects = true;
} catch {
  // UnknownDiagramError — the expected outcome.
}
if (zenumlDetects) {
  fail("detectType() resolved a zenuml source; FlowPeek would offer a diagram mermaid cannot render");
  console.error("FAIL  detectType('zenuml …') resolved instead of throwing");
} else {
  console.log("ok    detectType rejects zenuml");
}

// ---------------------------------------------------------------------------
// (e) Pele — the third renderer, vendored the same way and so checked the same way.
//
// Extended here rather than written as a sibling script. What this gate asserts is that the
// scripts injected into the engine's content world reach nothing at render time; that is a
// property of the SET FlowPeek ships, not of mermaid, and the set is now four files. Release CI
// runs one command for it (.github/workflows/release.yml, "Run the test suites"), and a sibling
// would be a second line there, a second entry in docs/RELEASING.md and a second habit — the one
// that is forgotten is the one that drifts, which is the same reason `vendor:pele` copies from
// node_modules instead of fetching.
//
// Pele's half is shorter than mermaid's because less is pinned. There is no Swift-side table for
// it to agree with: nothing routes to Pele yet, so no detector list, no corpus. What is left is
// what vendoring itself promises — self-containment, a render with no DOM, and that the bundle
// in the repo is the release package.json names.
const pelePath = join(root, "Sources/FlowPeek/Resources/pele.global.js");

let peleSource;
try {
  peleSource = readFileSync(pelePath, "utf8");
} catch (error) {
  console.error(`FAIL  cannot read the vendored bundle at ${pelePath}`);
  console.error(`      ${error.message}`);
  console.error("      run `npm run vendor:pele` first");
  process.exit(1);
}

console.log(`\nbundle  ${pelePath}`);
console.log(`bytes   ${Buffer.byteLength(peleSource)}`);

scanForbidden("pele", peleSource);

// The pin. Pele exports no version — `Object.keys(pele)` is PeleError, detectType, enableZoom,
// forgetTextWidths, mount, parse, register, registered, render, supports — so the only version
// the bundle states about itself is its first-line banner. FlowPeek ships offline: a `pele@1`
// that drifted under a later `npm install` while this file stayed put would be a renderer nobody
// could reproduce from package.json, so the two are compared rather than trusted.
const pinned = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).dependencies.pele;
const banner = /^\/\*!\s*Pele\s+(\d+\.\d+\.\d+)\b/.exec(peleSource);
if (!banner) {
  fail("pele.global.js has no `/*! Pele <version>` banner; the vendored bundle cannot be pinned");
  console.error("FAIL  pele banner missing");
} else if (banner[1] !== pinned) {
  fail(`pele.global.js is ${banner[1]} but package.json pins ${pinned}; re-run \`npm run vendor:pele\``);
  console.error(`FAIL  pele version drift: bundle ${banner[1]}, package.json ${pinned}`);
} else {
  console.log(`ok    pele banner ${banner[1]} matches the package.json pin`);
}

// Its own bare context, so nothing mermaid left on the first one can stand in for something Pele
// would otherwise need.
const peleSandbox = { console: { log() {}, warn() {}, error() {}, debug() {}, info() {} } };
const peleContext = createContext(peleSandbox);

let pele;
try {
  runInContext(peleSource, peleContext, { filename: "pele.global.js" });
  pele = peleSandbox.pele;
} catch (error) {
  console.error(`FAIL  pele.global.js threw while loading in a bare vm context: ${error.message}`);
  process.exit(1);
}

if (!pele || typeof pele.render !== "function") {
  console.error("FAIL  pele.global.js did not expose a usable `pele` global in a bare vm context");
  process.exit(1);
}

// Rendering in this context is the self-containment proof, and a stronger one than `node --check`:
// a bare vm has no document, no window, no fetch and no filesystem, so an SVG coming back out of
// it is a renderer that builds its own markup as a string. That is what lets Pele be injected as a
// plain WKUserScript beside the other two instead of needing a page to be ready first.
try {
  const drawn = pele.render("flowchart TD\n  A[Start] --> B[End]");
  if (typeof drawn?.svg !== "string" || !drawn.svg.startsWith("<svg")) {
    fail("pele.render() returned no SVG markup offline");
    console.error(`FAIL  pele.render() gave ${JSON.stringify(drawn)?.slice(0, 120)}`);
  } else {
    console.log(`ok    pele.render() offline in a bare vm context: ${drawn.mermaidType}, ${drawn.width}x${drawn.height}`);
  }
} catch (error) {
  console.error(`FAIL  pele.render() threw offline: ${error.message}`);
  process.exit(1);
}

if (failures.length) {
  console.error(`\n${failures.length} conformance violation(s):`);
  for (const message of failures) console.error(`  - ${message}`);
  process.exit(1);
}

console.log("\nconformance OK");
