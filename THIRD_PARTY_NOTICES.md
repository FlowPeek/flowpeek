# Third-party notices

FlowPeek includes:

- Mermaid 11.17.2 — Copyright Mermaid contributors — MIT License — https://github.com/mermaid-js/mermaid
- Pele 1.7.0 — Copyright (c) 2026 kepano — MIT License — https://github.com/obsidianmd/pele
- Sparkle 2.9.2 — Copyright Sparkle Project — MIT License — https://github.com/sparkle-project/Sparkle

All three packages are redistributed under the MIT License. Their complete license texts are available in the corresponding upstream source distributions and package artifacts pinned by this repository.

`Sources/FlowPeek/Resources/pele.global.js` is the `dist/pele.global.js` of the `pele` 1.7.0 npm
package, copied unmodified by `npm run vendor:pele`. Pele's own notice records that the Mermaid
specifications under its `tests/compat`, and the grammar files beside them, come from Mermaid,
also under the MIT License.

Pele's licence carries a second notice, and it covers bytes FlowPeek redistributes: the reset icon
of Pele's zoom controls is "rotate-ccw" from Lucide v1.14.0 (https://lucide.dev), Copyright (c)
2026 Lucide Icons and Contributors, under the ISC License. The path data is in the bundle we ship —
`M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8M3 3v5h5`, in the markup `pele.enableZoom` builds
— so the notice travels with the file whether or not FlowPeek ever calls that function.

## mermaid flowchart parser tests

`Tests/JavaScript/mermaid-compat/` vendors, unmodified, the flowchart parser specifications from
mermaid 11.17.2 — the same version bundled in `Sources/FlowPeek/Resources/mermaid.min.js`. They are
run against FlowPeek's own flowchart parser so that it accepts every flowchart mermaid accepts and
resolves it to the same meaning. `diagram-api/comments.ts`, `flow.jison.reference`,
`flowDb.reference.ts` and `types.reference.ts` are vendored from the same tag.

    The MIT License (MIT)
    Copyright (c) 2014 - 2022 Knut Sveidqvist
    https://github.com/mermaid-js/mermaid
