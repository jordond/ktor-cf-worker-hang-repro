# Ktor JS client hangs on Cloudflare Workers under concurrent load

Cloudflare Workers (workerd) cancels requests with error 1101 when
Ktor's JS `HttpClient` is used under concurrent load:

```
The Workers runtime canceled this request because it detected that your
Worker's code had hung and would never generate a response.
```

Same upstream URL, same worker, 30 concurrent requests. Verified on
both local `wrangler dev` and the deployed worker at
`https://ktor-hang.jordond.dev`:

| handler                       | local (wrangler dev) | prod (single-client burst) |
|-------------------------------|---------------------:|---------------------------:|
| Ktor `HttpClient`             | ~28/30               | ~22/30 (range 18 to 27)    |
| `globalThis.fetch` (no Ktor)  | **0/30**             | **0/30**                   |

Swapping the Ktor call for `globalThis.fetch` against the same upstream
makes the hang disappear, isolating the surface to the Ktor JS client.
Both environments saturate near the upper bound because the burst is
single-source: local `wrangler dev` serves it from one isolate, and a
single client against prod funnels through one colo into a small set
of isolates.

## Versions

| Component             | Version                                          |
|-----------------------|--------------------------------------------------|
| Kotlin                | `2.3.21`                                         |
| kotlinx-coroutines    | `1.11.0`                                         |
| Ktor                  | `3.4.3`                                          |
| workerd               | `compatibility_date: 2026-02-25`                 |
| wrangler              | `4.90.0` (runs miniflare locally)                |

No compatibility flags are set. The hang reproduces on stock workerd
with the date above. Toggling
`no_handle_cross_request_promise_resolution` does not change whether
the hang occurs, only which internal error workerd raises before it
fires the hang detector.

## Reproduce

```
npm install
./test-repro.sh                # Ktor path, reproduces the hang
./test-repro.sh --native       # native fetch baseline, hang-free

# Same suite against the deployed worker on real Cloudflare:
./test-repro.sh --remote
./test-repro.sh --remote --native
# Override target: REMOTE_URL=https://your.worker.tld ./test-repro.sh --remote

# Full matrix in one run (warmup, local ktor+native, remote ktor x3, remote native);
# writes suite-report-<timestamp>.md
./test-repro.sh --suite
./test-repro.sh --suite --samples 5    # take 5 prod samples instead of 3
```

The script builds the worker bundle, boots `wrangler dev --local`,
fires a 30 request concurrent burst, classifies each response, and
exits 0 when the outcome matches expectation (Ktor: at least one hang,
native: zero hangs). `--remote` skips the build and local boot and
hits the deployed worker directly.

The worker routes by path:

| path      | handler             |
|-----------|---------------------|
| `/`       | Ktor `HttpClient`   |
| `/native` | `globalThis.fetch`  |

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

## Stack

Captured on real Cloudflare prod with
`no_handle_cross_request_promise_resolution` enabled. The flag is not
required to reproduce the hang itself, but it surfaces the underlying
cross-request access as an explicit error rather than letting workerd
fall back to silent corruption, which makes the failure point legible:

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

Under `Dispatchers.Unconfined`, a fetch promise from request A can
resolve on a microtask owned by request B in the same isolate. The
continuation chain for request A then runs inside request B's context
and touches the `AbortController` registered for request A. The
cross-context resume does not successfully wake request A's outer
`Promise<Response>`, so the worker's `fetch` handler promise never
settles and workerd's hang detector cancels the request with 1101.

With `no_handle_cross_request_promise_resolution` set, workerd raises
the explicit "Cannot perform I/O on behalf of a different request"
error visible in the stack above. Without the flag, the same code
path still produces the 1101 hang at a similar rate (16/30 to 29/30
in our samples) because the outer promise is never resolved either
way.

Native `fetch` does not exhibit this because its abort signal stays
attached to whichever request context invokes it.

## File layout

| Path                              | Purpose                                                 |
|-----------------------------------|---------------------------------------------------------|
| `src/jsMain/kotlin/Main.kt`       | Worker fetch handler + `nativeFetch` comparison helper  |
| `build.gradle.kts`                | Kotlin/JS with `ktor-client-core` + `ktor-client-js`    |
| `wrangler.json`                   | Worker config, custom domain route                      |
| `index.mjs`                       | Module entry, delegates `fetch` to the compiled bundle  |
| `test-repro.sh`                   | End to end harness                                      |
