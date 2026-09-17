#!/usr/bin/env node
// Re-vendors mermaid's flowchart parser specs into Tests/JavaScript/mermaid-compat.
//
// They are the bar FlowPeek's own parser has to clear, so they are kept byte-for-byte as mermaid
// wrote them: when mermaid is upgraded, re-run this and the diff is a readable account of what
// changed about the grammar. The version comes from package.json rather than being written here
// twice -- the tests and the bundled engine must always be the same mermaid.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).dependencies.mermaid;
const base =
  `https://raw.githubusercontent.com/mermaid-js/mermaid/mermaid%40${version}/packages/mermaid/src`;

const OUT = join(root, "Tests/JavaScript/mermaid-compat");

// [remote path, local path]. The specs run; the rest is reference the specs were written against
// and is named `.reference` so nothing imports it by accident.
const FILES = [
  ...[
    "flow.spec.js", "flow-arrows.spec.js", "flow-comments.spec.js", "flow-direction.spec.js",
    "flow-edges.spec.js", "flow-huge.spec.js", "flow-interactions.spec.js", "flow-lines.spec.js",
    "flow-md-string.spec.js", "flow-node-data.spec.js", "flow-singlenode.spec.js",
    "flow-style.spec.js", "flow-text.spec.js", "flow-vertice-chaining.spec.js", "subgraph.spec.js",
  ].map((f) => [`diagrams/flowchart/parser/${f}`, `diagrams/flowchart/parser/${f}`]),
  ["diagram-api/comments.ts", "diagram-api/comments.ts"],
  ["diagrams/flowchart/parser/flow.jison", "diagrams/flowchart/parser/flow.jison.reference"],
  ["diagrams/flowchart/flowDb.ts", "diagrams/flowchart/flowDb.reference.ts"],
  ["diagrams/flowchart/types.ts", "diagrams/flowchart/types.reference.ts"],
];

let changed = 0;
for (const [remote, local] of FILES) {
  const response = await fetch(`${base}/${remote}`);
  if (!response.ok) {
    console.error(`FAIL ${remote}: HTTP ${response.status}`);
    process.exit(1);
  }
  const body = await response.text();
  const path = join(OUT, local);
  mkdirSync(dirname(path), { recursive: true });
  let before = null;
  try { before = readFileSync(path, "utf8"); } catch { /* new file */ }
  if (before !== body) { writeFileSync(path, body); changed += 1; }
}
console.log(`mermaid ${version}: ${FILES.length} files, ${changed} changed`);
