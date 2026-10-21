// The order within a rank decides how many crossings a drawing has before a single connector is
// routed, and a crossing the order did not need is one no routing pass can take back.
//
// The third visual review traced every remaining loss to Pele on its sixteen sources to this phase:
// the dense DAG (11) could not be followed, the state machine (03) routed every back edge around
// the outside, and 02 put Redis between Postgres and S3 so that Auth -> Redis crossed both edges
// into Postgres. Run against the ordering before this file, with bridged crossings counted as
// crossings, these tests found 2 crossing pairs on 03, 1 on 07, 1 on 08 and 24 on 11; Pele draws
// 2, 1, 1 and 17 on the same sources.
//
// Two defects, both in `layoutLevel`'s ordering. Its barycentre sweeps stopped in a local minimum
// they could not leave (11, 03, 07), and a zone was ordered with no knowledge of the edges that
// leave it (02, 08), because those belong to the level that holds both ends.
//
// Pele is not crossing-free and zero is not the target: what is asserted is that these reach the
// counts the order allows -- none on three of them, two on 02 that the order does not cause --
// and that 11 now draws fewer than Pele does.

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureText } from './measure.js';

const require = createRequire(import.meta.url);
const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const flow = require(join(root, 'Sources/FlowPeek/Resources/flowpeek-flow.js'));

const EDITORIAL = {
  dark: false,
  fontFamily: "'Geist', sans-serif",
  monoFontFamily: "'Geist', sans-serif",
  themeVariables: { fontSize: '12px', lineColor: '#4f5d75', nodeBorder: '#2d3142', mainBkg: '#f5f5f5' },
  themeCSS: '.fp-ladder { --fp-ladder: on; }',
  arrangement: {
    nodeSpacing: 32, rankSpacing: 40, padding: 16, diagramPadding: 24,
    curve: 'rounded', flowchartCurve: 'step', wrappingWidth: 160,
  },
};

const ARCHITECTURE = [
  'flowchart LR',
  '    subgraph Clients', '        web[Web App]', '        ios[iOS App]', '        android[Android App]', '    end',
  '    subgraph Edge', '        cdn[CDN]', '        gw{{API Gateway}}', '    end',
  '    subgraph Services', '        auth[Auth Service]', '        orders[Order Service]', '        billing[Billing Service]', '    end',
  '    subgraph Data', '        pg[(Postgres)]', '        redis[(Redis)]', '        s3[(S3)]', '    end',
  '    web --> cdn --> gw', '    ios --> gw', '    android --> gw',
  '    gw --> auth', '    gw --> orders', '    gw --> billing',
  '    auth --> redis', '    orders --> pg', '    billing --> pg', '    orders --> s3',
].join('\n');

const STATE_MACHINE = [
  'flowchart TD',
  '    idle[Idle] -->|connect| connecting[Connecting]',
  '    connecting -->|success| online[Online]',
  '    connecting -->|timeout| retry[Retry wait]',
  '    connecting -->|auth error| failed[Failed]',
  '    retry -->|backoff elapsed| connecting',
  '    online -->|heartbeat lost| retry',
  '    online -->|user logout| idle',
  '    failed -->|user retries| connecting',
  '    failed -->|give up| idle',
  '    online -->|server shutdown notice| draining[Draining]',
  '    draining -->|drained| idle',
].join('\n');

const BACK_EDGES = [
  'flowchart LR',
  '    plan[Plan] --> design[Design] --> build[Build] --> test[Test] --> review[Review] --> release[Release] --> monitor[Monitor]',
  '    test -->|fails| build', '    review -->|changes requested| design', '    monitor -->|incident| plan',
  '    release -->|rollback| build', '    monitor -->|feedback| design',
].join('\n');

const NESTED = [
  'flowchart TD',
  '    subgraph Cloud[AWS Account]', '        subgraph VPC[Production VPC]',
  '            subgraph Public[Public Subnet]', '                alb[Load Balancer]', '                nat[NAT Gateway]', '            end',
  '            subgraph Private[Private Subnet]', '                app1[App Server 1]', '                app2[App Server 2]',
  '                subgraph DB[Database Tier]', '                    primary[(Primary)]', '                    replica[(Replica)]', '                end',
  '            end', '        end', '        s3[(S3 Bucket)]', '    end',
  '    user[User] --> alb', '    alb --> app1', '    alb --> app2', '    app1 --> primary', '    app2 --> primary',
  '    primary --> replica', '    app1 --> nat', '    app2 --> s3',
].join('\n');

const DENSE = [
  'flowchart TD',
  '    A --> B & C & D', '    B --> E & F', '    C --> E & G', '    D --> F & G & H',
  '    E --> I & J', '    F --> I & K', '    G --> J & K & L', '    H --> L',
  '    I --> M', '    J --> M & N', '    K --> N', '    L --> N & M',
  '    A --> M', '    B --> N', '    D --> I', '    C --> L',
].join('\n');

function draw(source) {
  const out = flow.render({ source, renderID: 'fp-0', diagramType: 'flowchart-v2', theme: EDITORIAL, measureText });
  expect(out.reason || 'ok').toBe('ok');
  return out;
}

function laidOut(source) {
  const db = new flow.FlowDB();
  db.clear();
  flow.parse(source, db);
  return flow.layout(db, { measureText, theme: flow.buildFlowTheme(EDITORIAL) });
}

/** Each connector's corner skeleton, a bridge read as its chord, so a bridged crossing still counts. */
function routes(svg) {
  const re = /<path class="[^"]*flowchart-link[^"]*" data-id="([^"]*)" d="([^"]*)"/g;
  return [...svg.matchAll(re)].map(([, id, d]) => {
    const tokens = d.match(/[A-Za-z]|-?\d+(?:\.\d+)?/g) ?? [];
    const points = [];
    let command = null;
    for (let i = 0; i < tokens.length;) {
      if (/^[A-Za-z]$/.test(tokens[i])) command = tokens[i++];
      const take = (n) => tokens.slice(i, (i += n)).map(Number);
      if (command === 'M' || command === 'L') { const [x, y] = take(2); points.push({ x, y }); }
      else if (command === 'Q') { const [, , x, y] = take(4); points.push({ x, y }); }
      else if (command === 'A') { const v = take(7); points.push({ x: v[5], y: v[6] }); }
      else throw new Error(`unexpected path command ${command} in ${d}`);
    }
    return { id, points };
  });
}

const orient = (a, b, c) => Math.sign((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x));
const properly = (a, b, c, d) => orient(a, b, c) * orient(a, b, d) < 0 && orient(c, d, a) * orient(c, d, b) < 0;

/** Pairs of connectors that cross at least once, by data-id. */
function crossingPairs(source) {
  const all = routes(draw(source).svg);
  const found = [];
  for (let i = 0; i < all.length; i += 1) {
    for (let j = i + 1; j < all.length; j += 1) {
      const p = all[i].points, q = all[j].points;
      let hit = false;
      for (let a = 0; a + 1 < p.length && !hit; a += 1) {
        for (let b = 0; b + 1 < q.length && !hit; b += 1) hit = properly(p[a], p[a + 1], q[b], q[b + 1]);
      }
      if (hit) found.push(`${all[i].id} x ${all[j].id}`);
    }
  }
  return found;
}

describe('[Order] the order within a rank costs no crossing it can avoid', () => {
  it('orders a zone by where its edges come from: Redis above S3 above Postgres', () => {
    // Data has no edge inside it. Ordered by its own edges alone it kept declaration order, and
    // Auth -> Redis crossed Order -> Postgres and Billing -> Postgres. Those three are gone.
    //
    // The two left are iOS -> API Gateway climbing over CDN, kept as an exact set so that losing
    // either, or gaining one, fails. They are not the order's: CDN is iOS's height because it is
    // lined up with API Gateway, and the cure that was measured -- dummies for an edge entering a
    // zone, so the zone keeps it a corridor -- drew no crossing here but sent iOS and Android up to
    // the gateway's left tip on one vertical, sharing 8px, because between CDN's clearance and the
    // last turn before the tip there is room for one climb and not two. A run two connectors share
    // reads as a join, which costs a reader more than two bridges do.
    const drawing = laidOut(ARCHITECTURE);
    const y = (id) => drawing.nodes.find((n) => n.id === id).y;
    expect(y('redis')).toBeLessThan(y('s3'));
    expect(y('s3')).toBeLessThan(y('pg'));
    expect(crossingPairs(ARCHITECTURE)).toEqual(['L_web_cdn_0 x L_ios_gw_0', 'L_cdn_gw_0 x L_ios_gw_0']);
  });

  it('draws the state machine with no crossing', () => {
    expect(crossingPairs(STATE_MACHINE)).toEqual([]);
  });

  it('draws the back-edge chain with no crossing', () => {
    expect(crossingPairs(BACK_EDGES)).toEqual([]);
  });

  it('draws the nested zones with no crossing', () => {
    // App Server 1 -> NAT Gateway crossed Load Balancer -> App Server 2 because the Private Subnet
    // was ordered without NAT Gateway, which is outside it.
    expect(crossingPairs(NESTED)).toEqual([]);
  });

  it('draws the dense DAG with fewer crossing pairs than Pele does', () => {
    // 24 pairs before, against Pele's 17 on the same source. The order this lands on has 12
    // crossings between adjacent ranks, the least a 60-start search finds.
    expect(crossingPairs(DENSE).length).toBeLessThan(17);
  });
});
