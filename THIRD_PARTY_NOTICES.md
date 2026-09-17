# Third-party notices

FlowPeek includes:

- Mermaid 11.17.2 — Copyright Mermaid contributors — MIT License — https://github.com/mermaid-js/mermaid
- Sparkle 2.9.2 — Copyright Sparkle Project — MIT License — https://github.com/sparkle-project/Sparkle

Both packages are redistributed under the MIT License. Their complete license texts are available in the corresponding upstream source distributions and package artifacts pinned by this repository.

## mermaid flowchart parser tests

`Tests/JavaScript/mermaid-compat/` vendors, unmodified, the flowchart parser specifications from
mermaid 11.17.2 — the same version bundled in `Sources/FlowPeek/Resources/mermaid.min.js`. They are
run against FlowPeek's own flowchart parser so that it accepts every flowchart mermaid accepts and
resolves it to the same meaning. `diagram-api/comments.ts`, `flow.jison.reference`,
`flowDb.reference.ts` and `types.reference.ts` are vendored from the same tag.

    The MIT License (MIT)
    Copyright (c) 2014 - 2022 Knut Sveidqvist
    https://github.com/mermaid-js/mermaid
