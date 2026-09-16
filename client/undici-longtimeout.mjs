// Raise undici transport timeouts for local-LLM serving.
//
// undici defaults BOTH headersTimeout and bodyTimeout to 300_000 ms. A vLLM
// request emits no response bytes until generation begins, and generation begins
// only after the whole prompt is prefilled. On a large context that exceeds five
// minutes, so undici kills the socket and the client reports a bare `terminated`
// (code: TRANSPORT) while the server completes the work and logs HTTP 200.
//
// dsh's provider timeoutMs / streamIdleTimeoutMs are application-level and never
// reach undici. Node's built-in fetch reads the dispatcher from the well-known
// symbol Symbol.for('undici.globalDispatcher.1'), which is exactly what the npm
// undici package's setGlobalDispatcher writes, so this reaches built-in fetch.
//
// The import is RELATIVE to this file: install.sh places this file at
// ~/.local/lib/undici-longtimeout.mjs and installs undici 8.10.0 into
// ~/.local/lib/undici-patch/ next to it. The launcher loads it through
// NODE_OPTIONS="--import <this file>".
import { setGlobalDispatcher, Agent } from './undici-patch/node_modules/undici/index.js'
setGlobalDispatcher(new Agent({
  headersTimeout: 3_600_000,
  bodyTimeout: 3_600_000,
  keepAliveTimeout: 600_000,
  keepAliveMaxTimeout: 600_000,
}))
