// Stands in for mermaid's logger.
//
// It re-exports the renderer's OWN log object rather than building a lookalike. A spec that spies
// on a warning has to spy on the object the parser actually calls, and two objects that merely
// share a shape would leave the spy watching one while the parser talks to the other -- which is
// exactly what happened: the parser emitted mermaid's warning verbatim and the spec still recorded
// zero calls.
import { flowpeekFlow } from './diagrams/flowchart/flowDb.js';

export const log = flowpeekFlow.log;
export const setLogLevel = () => {};
