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
    // vitest's default per-test budget is 5000 ms, and the corpus sweeps here are synchronous loops
    // that render every SWEEP source and pass when they finish. Over 40 idle runs the slowest, the
    // [Straight] corpus sweep that draws every aligned pair as one segment, peaked at 2853 ms (57%
    // of that budget) and 19 tests passed 1000 ms. Under 10 busy-loop processes on this 10-core
    // machine the maximum rose to 4010 ms; under 30, 3 of 3 runs failed with "Test timed out in
    // 5000ms" at 5127-9642 ms in: arrival's "holds at every rank spacing, tight and loose" and
    // "leaves a head-length of shaft behind the head", render's "bridges a crossing on a corner's
    // tangent" and "renders the same source to the same bytes, twice and from a fresh module",
    // answers' "a plate beside its line faces the line of another edge", and straight's "draws every
    // aligned, unobstructed pair as one segment". The budget was measuring the machine, not the
    // renderer, whose output is byte-identical across renders and processes.
    testTimeout: 30000,
    reporters: ['default'],
  },
});
