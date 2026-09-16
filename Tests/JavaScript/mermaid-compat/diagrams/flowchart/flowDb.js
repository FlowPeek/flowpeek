// The specs import `FlowDB` from here, exactly as they do inside mermaid. It is FlowPeek's own,
// taken straight off the renderer the app ships -- no adapter in between, because an adapter is
// somewhere the two could quietly disagree.
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', '..');

export const flowpeekFlow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));
export const FlowDB = flowpeekFlow.FlowDB;
