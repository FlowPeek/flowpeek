// Stands in for mermaid's config module. The specs set `securityLevel` before parsing, and the
// flowchart data model reads it when it decides whether a `click` href may be kept.
let current = { securityLevel: 'strict' };

export const setConfig = (next) => {
  current = { ...current, ...next };
};

export const getConfig = () => current;
