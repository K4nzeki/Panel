package eu.kanade.tachiyomi.network

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.Duration.Companion.seconds

/**
 * Part of the extension API: a few sources run small scripts (unpacking
 * obfuscated image lists, computing tokens).
 *
 * Mihon uses QuickJS (from JitPack). Panel runs the script in a throwaway,
 * hidden WebView instead, so no extra library is needed. Results match
 * QuickJS for what extensions use: strings, numbers (Int when whole, else
 * Double), booleans, null; arrays and objects come back as List / Map.
 * A script that throws makes [evaluate] throw.
 */
@Suppress("UNUSED")
class JavaScriptEngine(context: Context) {

    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    @Suppress("UNCHECKED_CAST")
    suspend fun <T> evaluate(script: String): T = withTimeout(30.seconds) {
        withContext(Dispatchers.Main) { evaluateOnMain(script) as T }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private suspend fun evaluateOnMain(script: String): Any? = suspendCancellableCoroutine { cont ->
        val view = WebView(app)
        view.settings.javaScriptEnabled = true
        cont.invokeOnCancellation { main.post { view.destroy() } }

        // Indirect eval runs the script in global scope, like QuickJS.
        val wrapped = """
            (function () {
                try {
                    const v = (0, eval)(${JsonPrimitive(script)});
                    return JSON.stringify({ ok: v === undefined ? null : v });
                } catch (e) {
                    return JSON.stringify({ err: String(e) });
                }
            })()
        """.trimIndent()

        view.webViewClient = object : WebViewClient() {
            private var started = false

            override fun onPageFinished(webView: WebView, url: String) {
                if (started) return
                started = true
                webView.evaluateJavascript(wrapped) { raw ->
                    webView.destroy()
                    if (!cont.isActive) return@evaluateJavascript
                    try {
                        cont.resume(decodeResult(raw))
                    } catch (e: Exception) {
                        cont.resumeWithException(e)
                    }
                }
            }
        }
        view.loadDataWithBaseURL(null, "<html><body></body></html>", "text/html", "utf-8", null)
    }

    /** evaluateJavascript gives a JSON literal of our JSON string: decode twice. */
    private fun decodeResult(raw: String?): Any? {
        val outer = Json.parseToJsonElement(raw ?: "null")
        val text = (outer as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: throw IllegalStateException("JavaScript returned nothing")
        val result = Json.parseToJsonElement(text).jsonObject
        result["err"]?.let { throw IllegalStateException("JavaScript error: ${it.jsonPrimitive.content}") }
        return toKotlin(result["ok"] ?: JsonNull)
    }

    private fun toKotlin(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonPrimitive -> when {
            e.isString -> e.content
            e.booleanOrNull != null -> e.booleanOrNull
            else -> e.content.toLongOrNull()?.let { if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else it }
                ?: e.content.toDoubleOrNull()
        }
        is JsonArray -> e.map(::toKotlin)
        is JsonObject -> e.mapValues { toKotlin(it.value) }
    }
}
