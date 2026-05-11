import io.ktor.client.HttpClient
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

@OptIn(ExperimentalJsExport::class)
@JsExport
fun fetch(
    request: Request,
    @Suppress("UNUSED_PARAMETER") env: dynamic,
    @Suppress("UNUSED_PARAMETER") ctx: dynamic,
): Promise<Response> {
    val path = try {
        org.w3c.dom.url.URL(request.url).pathname
    } catch (_: Throwable) {
        "/"
    }
    if (path.trimEnd('/') == "/native") return nativeFetch()

    val scope = requestScope()
    return scope
        .promise {
            val client = HttpClient { expectSuccess = true }
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

private fun nativeFetch(): Promise<Response> =
    js("globalThis.fetch")("https://www.cloudflare.com/cdn-cgi/trace")
        .unsafeCast<Promise<dynamic>>()
        .then { r: dynamic ->
            (r.text() as Promise<String>).then { text ->
                Response(text, responseInit(200))
            }
        }
        .unsafeCast<Promise<Response>>()
