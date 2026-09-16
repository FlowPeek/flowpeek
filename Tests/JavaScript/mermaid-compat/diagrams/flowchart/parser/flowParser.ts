// The specs import a parser object shaped like mermaid's jison export: `parser.yy` is the FlowDB
// they assert against, and `parser.parse(source)` fills it in. FlowPeek's parser is a plain
// function over a database, so this is the whole of the adaptation.
//
// The file is named .ts only because mermaid's specs import it by that name and they are vendored
// unmodified; nothing in it is TypeScript.
import { flowpeekFlow } from '../flowDb.js';

const parser = {
  yy: null as unknown,
  parse(source: string) {
    return flowpeekFlow.parse(source, parser.yy);
  },
};

export default { parser, parse: (source: string) => parser.parse(source) };
