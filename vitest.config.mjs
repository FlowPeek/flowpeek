import { defineConfig } from 'vitest/config';

// The vendored mermaid specs and the shim that points them at FlowPeek's renderer. Nothing else in
// the repo is JavaScript with tests, so the include is narrow on purpose: a stray .spec.js
// elsewhere is a mistake rather than something to pick up.
export default defineConfig({
  test: {
    include: ['Tests/JavaScript/**/*.spec.js'],
    // mermaid's own vitest config enables globals, and its specs are vendored unmodified -- they
    // call describe/it/expect without importing them.
    globals: true,
    environment: 'node',
    reporters: ['default'],
  },
});
