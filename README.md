# Ktor JS client hangs on Cloudflare Workers under concurrent load

Cloudflare Workers (workerd) cancels requests with error 1101 when Ktor's
JS `HttpClient` is used under concurrent load:

```
The Workers runtime canceled this request because it detected that your
Worker's code had hung and would never generate a response.
```

Same upstream URL, same worker, same compatibility flag, 30 concurrent
requests against `wrangler dev --local`:

| handler                                | hangs    |
|----------------------------------------|---------:|
| Ktor `HttpClient` + `Logging` plugin   | 29/30    |
| Ktor `HttpClient`, no plugins          | 29/30    |
| `globalThis.fetch` (no Ktor)           | **0/30** |

The native `fetch` path is verified clean against the same upstream,
same wrangler dev, same compatibility flag. The hang surface is the
Ktor JS client, not Kotlin/JS coroutines, not `Dispatchers.Unconfined`,
not the worker scaffolding, not the compatibility flag.

Local single-isolate bursts saturate both Ktor variants near the upper
bound; the `Logging` plugin and the base engine are indistinguishable
under this load. On real Cloudflare prod the no-plugin rate drops close
to zero because edge traffic is distributed across many isolates, while
the `Logging` variant continues to hang at a high rate. Local
`wrangler dev` serves the entire burst from one isolate, which keeps
the underlying issue visible for both.

## Versions

| Component             | Version                                  |
|-----------------------|------------------------------------------|
| Kotlin                | `2.3.21`                                 |
| kotlinx-coroutines    | `1.11.0`                                 |
| Ktor                  | `3.4.3`                                  |
| workerd               | `compatibility_date: 2026-02-25`         |
| compatibility flags   | `["no_handle_cross_request_promise_resolution"]` |
| wrangler              | `4.90.0` (runs miniflare locally)        |

## Reproduce

```
npm install
./test-repro.sh                # Ktor path with Logging plugin (worst rate)
./test-repro.sh --no-logging   # Ktor path without Logging plugin
./test-repro.sh --native       # native fetch baseline, hang-free
```

The script builds the worker bundle, boots `wrangler dev --local`, fires
a 30 request concurrent burst, classifies each response, and exits 0
when the outcome matches expectation (Ktor: at least one hang; native:
zero hangs).

The worker routes by path:

| path          | handler                                  |
|---------------|------------------------------------------|
| `/`           | Ktor `HttpClient` with `Logging` plugin  |
| `/no-logging` | Ktor `HttpClient`, no plugins            |
| `/native`     | `globalThis.fetch`                       |

Sample output:

```
=== burst summary ===
    1  http=500  time=0.097s  body=hang
    2  http=500  time=0.387s  body=hang
   ...
    7  http=200  time=0.266s  body=ok
   ...
   30  http=500  time=0.077s  body=hang

  hangs=29  ok=1  exception=0  empty=0  total=30

=== sample hang body (burst_1.body) ===
Error: The Workers runtime canceled this request because it detected that
your Worker's code had hung and would never generate a response. ...
```

To compare paths against the same wrangler dev session, run
`./test-repro.sh --native` (or `--no-logging`) after the default
invocation. Result: 30/30 ok against `/native`; `/no-logging` reproduces
the hang at the same rate as `/`.

## Stack

Captured on real Cloudflare prod (same Ktor `HttpClient` configuration):

```
CompletionHandlerException: Exception in completion handler ChildHandleNode
  ... at resumeUnconfined (index.js:34587:7)
Caused by: CompletionHandlerException: Exception in completion handler InvokeOnCancelling
Caused by: Error: Cannot perform I/O on behalf of a different request.
  I/O objects (such as streams, request/response bodies, and others) created
  in the context of one request handler cannot be accessed from a different
  request's handler. (I/O type: RefcountedCanceler)
    at InvokeOnCancelling.c10_1
```

## Suspected mechanism

`ktor-client-js` registers `Job.invokeOnCancelling { ... }` listeners
whose bodies hold the per-call fetch `AbortController`. workerd binds
that controller (`RefcountedCanceler`) to the originating request's
`ExecutionContext`.

Under `Dispatchers.Unconfined`, when one request's fetch promise
resolves on a microtask owned by a different in-flight request in the
same isolate, the cancellation listener fires inside the foreign
context. workerd's `no_handle_cross_request_promise_resolution` rejects
the cross-request I/O access. The throw cascades through
`CompletionHandlerException`. The outer fetch handler promise is left
unresolved. workerd's hang detector cancels with 1101.

Native `fetch` does not exhibit this because its abort signal stays
attached to whichever request's context invokes it.

## File layout

| Path                              | Purpose                                          |
|-----------------------------------|--------------------------------------------------|
| `src/jsMain/kotlin/Main.kt`       | Worker fetch handler + `nativeFetch` comparison helper. |
| `build.gradle.kts`                | Kotlin/JS with `ktor-client-core` + `ktor-client-js`. |
| `wrangler.json`                   | Compatibility flag enabled.                      |
| `index.mjs`                       | Module entry. Polyfills `process.hrtime`.        |
| `test-repro.sh`                   | End to end harness.                              |
