# mermaid compatibility harness

The `*.spec.js` files under `diagrams/flowchart/parser/` are **vendored byte-for-byte from
mermaid** (tag `mermaid@11.17.2`, the version this app bundles — see `package.json`). They are the
bar FlowPeek's own flowchart parser has to clear: every flowchart mermaid accepts, FlowPeek accepts,
and understands to mean the same thing.

Do not edit them. When mermaid is upgraded, re-vendor them with `npm run vendor:mermaid-tests` and
let the diff tell you what changed about the grammar.

`flow.jison.reference`, `flowDb.reference.ts` and `types.reference.ts` are vendored too, and are
reference only — the grammar and the data model the specs are written against. Nothing imports them.

The rest of this directory is the shim that lets the vendored specs run against FlowPeek's renderer
instead of mermaid's. The layout mirrors mermaid's `src/` so the specs' own import paths resolve
unmodified:

    diagrams/flowchart/parser/*.spec.js   import './flowParser.ts'
                                          import '../flowDb.js'
                                          import '../../../config.js'
                                          import '../../../diagram-api/comments.js'
                                          import '../../../logger.js'

`comments.ts` is vendored as well: `cleanupComments` is mermaid's own pre-parse step and two specs
call it directly, so reimplementing it would be testing our copy rather than their behaviour.

The implementation under test is `Sources/FlowPeek/Resources/flowpeek-flow.js`, the same file the
app ships into its WebView.

mermaid is MIT licensed, Copyright (c) 2014 - 2022 Knut Sveidqvist. See THIRD_PARTY_NOTICES.md.
