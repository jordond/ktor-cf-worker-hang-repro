import io.ktor.client.HttpClient
import io.ktor.client.plugins.logging.LogLevel
import io.ktor.client.plugins.logging.Logging
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.promise
import org.w3c.fetch.Request
import org.w3c.fetch.Response
import org.w3c.fetch.ResponseInit
import kotlin.js.Promise

private fun responseInit(status: Short): ResponseInit {
    val headers: dynamic = js("({})")
    headers["content-type"] = "text/plain"
    return ResponseInit(status = status, headers = headers)
}

// Dispatchers.Unconfined keeps continuations on the request's microtask
// context. Dispatchers.Default on Kotlin/JS dispatches via setTimeout(0)
// which workerd does not count as request I/O and produces its own hang
// surface, so we use Unconfined to isolate the Ktor-specific issue.
private fun requestScope(): CoroutineScope =
    CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

// Installing the Logging plugin makes the hang rate worse (28/30 vs
// ~24/30 in our local burst). Comment the install block out to see the
// reduced rate. Real Cloudflare prod drops near zero without Logging
// because edge traffic is distributed across many isolates; local
// wrangler dev serves the entire burst from one isolate, so the base
// Ktor JS engine still hangs.
private fun makeClient(): HttpClient =
    HttpClient {
        expectSuccess = true
        install(Logging) {
            level = LogLevel.NONE
        }
    }

@OptIn(ExperimentalJsExport::class)
@JsExport
fun fetch(
    request: Request,
    @Suppress("UNUSED_PARAMETER") env: dynamic,
    @Suppress("UNUSED_PARAMETER") ctx: dynamic,
): Promise<Response> {
    // /native -> nativeFetch (no Ktor, hang-free baseline)
    // anything else -> Ktor HttpClient (reproduces the hang)
    val path = try {
        org.w3c.dom.url.URL(request.url).pathname
    } catch (_: Throwable) {
        "/"
    }
    if (path.trimEnd('/') == "/native") return nativeFetch()

    val scope = requestScope()
    return scope
        .promise {
            val client = makeClient()
            try {
                val body = client
                    .get("https://www.cloudflare.com/cdn-cgi/trace")
                    .bodyAsText()
                Response(body, responseInit(200))
            } catch (cause: Throwable) {
                val stack = cause.stackTraceToString()
                console.error("worker exception", stack)
                Response("EXC: $stack", responseInit(500))
            } finally {
                client.close()
            }
        }
}

// Comparison probe. Same upstream call without Ktor, using the native
// fetch() that Cloudflare Workers exposes. Routed via /native to confirm
// the hang is specific to Ktor.
private fun nativeFetch(): Promise<Response> =
    Promise<dynamic> { resolve, reject ->
        js("globalThis.fetch")("https://www.cloudflare.com/cdn-cgi/trace")
            .then({ r: dynamic -> resolve(r) }, { e: dynamic -> reject(e) })
    }.then { r: dynamic ->
        (r.text() as Promise<String>).then { text ->
            Response(text, responseInit(200))
        }
    }.unsafeCast<Promise<Response>>()
