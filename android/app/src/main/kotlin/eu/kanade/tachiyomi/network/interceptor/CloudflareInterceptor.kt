package eu.kanade.tachiyomi.network.interceptor

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import eu.kanade.tachiyomi.network.AndroidCookieJar
import eu.kanade.tachiyomi.util.system.isOutdated
import eu.kanade.tachiyomi.util.system.toWebViewHeaders
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * When a site answers with Cloudflare's browser check, loads the page in a
 * hidden WebView so the check's JavaScript runs and earns the `cf_clearance`
 * cookie, then retries the request with it (WebView and OkHttp share cookies
 * through [AndroidCookieJar]).
 *
 * Ported from Mihon (Apache 2.0). Uses Mihon's path for WebViews without
 * androidx.webkit's isolated worlds (a JavaScript interface), since Panel
 * doesn't ship androidx.webkit. Checks that need a tap ("interactive") can't
 * be solved in the background and fail with [CloudflareBypassException].
 */
class CloudflareInterceptor(
    private val context: Context,
    private val cookieManager: AndroidCookieJar,
    defaultUserAgentProvider: () -> String,
) : WebViewInterceptor(context, defaultUserAgentProvider) {

    private val executor = ContextCompat.getMainExecutor(context)

    // Requests to a host share its lock while one challenge is solved, so
    // concurrent requests wait for one WebView instead of each opening their own.
    private val hostLocks = ConcurrentHashMap<String, ReentrantReadWriteLock>()

    private val listenerScript = """
        addEventListener("message", ({data}) => {
            if (data?.source === "cloudflare-challenge") {
                panelCloudflare?.postMessage(data.event);
            }
        })
    """.trimIndent()

    override fun shouldIntercept(response: Response): Boolean {
        // The official way to detect a challenge:
        // https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/
        return response.header("cf-mitigated") == "challenge" && response.header("Server") in SERVER_CHECK
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val lock = hostLocks.computeIfAbsent(request.url.host) { ReentrantReadWriteLock() }

        val (response, clearance) = lock.read {
            val response = chain.proceed(request)
            if (!shouldIntercept(response)) return response
            response to clearance(request.url)
        }

        // write releases this thread's read hold, so a request made from within
        // another to the same host doesn't wait on itself.
        lock.write {
            // Another request may have solved it while this one waited.
            if (isCleared(request.url, clearance)) {
                response.close()
            } else {
                if (!prepareWebView()) return response
                solve(request, response, clearance)
            }
        }

        return chain.proceed(request)
    }

    override fun intercept(chain: Interceptor.Chain, request: Request, response: Response): Response {
        solve(request, response, clearance(request.url))
        return chain.proceed(request)
    }

    private fun clearance(url: HttpUrl): String? =
        cookieManager.get(url).firstOrNull { it.name == "cf_clearance" }?.value

    private fun isCleared(url: HttpUrl, previousClearance: String?): Boolean {
        val clearance = clearance(url)
        return !clearance.isNullOrBlank() && clearance != previousClearance
    }

    private fun solve(request: Request, response: Response, clearance: String?) {
        try {
            response.close()
            cookieManager.remove(request.url, COOKIE_NAMES, 0)
            resolveWithWebView(request, clearance)
        } catch (e: CloudflareBypassException) {
            // OkHttp's enqueue only handles IOExceptions.
            throw IOException(e.message, e)
        } catch (e: Exception) {
            throw IOException(e)
        }
    }

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    private fun resolveWithWebView(originalRequest: Request, originalClearance: String?) {
        // OkHttp interceptors are synchronous: block this (background) thread
        // until the WebView on the main thread is done.
        val latch = CountDownLatch(1)

        var webview: WebView? = null
        var challengeFound = false
        var cloudflareBypassed = false
        var challengeFailed = false
        var interactive = false
        var isWebViewOutdated = false
        var isRenderProcessGone = false

        val origRequestUrl = originalRequest.url.toString()
        // A WebView only loads pages with GET. The clearance covers the whole
        // site, so for other methods it's earned on the site's root page.
        val challengeUrl = if (originalRequest.method == "GET") {
            origRequestUrl
        } else {
            originalRequest.url.newBuilder().encodedPath("/").query(null).fragment(null).build().toString()
        }
        val headers = originalRequest.headers.toWebViewHeaders()

        // Runs on the main thread: anything thrown here (WebView missing or
        // being updated, renderer trouble) would force-close the app, so it
        // fails the bypass instead.
        executor.execute { try {
            val view = createWebView(originalRequest)
            webview = view

            fun onChallengeEvent(event: String) {
                when (event) {
                    // Needs a tap: can't be solved in the background.
                    "interactiveBegin" -> {
                        interactive = true
                        latch.countDown()
                    }
                    "fail" -> {
                        challengeFailed = true
                        latch.countDown()
                    }
                }
            }

            view.addJavascriptInterface(
                object {
                    @Suppress("unused")
                    @JavascriptInterface
                    fun postMessage(event: String) = onChallengeEvent(event)
                },
                JS_INTERFACE,
            )

            view.webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String) {
                    if (!challengeFailed && isCleared(originalRequest.url, originalClearance)) {
                        cloudflareBypassed = true
                        latch.countDown()
                    }

                    if (url == challengeUrl) {
                        if (!challengeFound) {
                            // The first load didn't return the challenge: nothing to solve.
                            latch.countDown()
                        } else {
                            view.evaluateJavascript(listenerScript, null)
                        }
                    }
                }

                override fun onReceivedHttpError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    errorResponse: WebResourceResponse?,
                ) {
                    if (request?.isForMainFrame == true) {
                        if (errorResponse?.responseHeaders?.get("cf-mitigated") == "challenge") {
                            challengeFound = true
                        } else {
                            latch.countDown()
                        }
                    }
                }

                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    // Not handling it kills the app; failing the bypass is enough.
                    Log.e("PanelExt", "WebView renderer gone during Cloudflare bypass: $origRequestUrl")
                    isRenderProcessGone = true
                    latch.countDown()
                    return true
                }
            }

            view.loadUrl(challengeUrl, headers)
        } catch (e: Throwable) {
            Log.e("PanelExt", "Couldn't start the Cloudflare WebView for $origRequestUrl", e)
            latch.countDown()
        } }

        latch.awaitFor30Seconds()

        executor.execute {
            try {
                // Only destroy() can be called on a WebView whose renderer is gone.
                if (!cloudflareBypassed && !isRenderProcessGone) {
                    isWebViewOutdated = webview?.isOutdated() == true
                }
                webview?.run {
                    if (!isRenderProcessGone) {
                        removeJavascriptInterface(JS_INTERFACE)
                        stopLoading()
                    }
                    destroy()
                }
            } catch (e: Throwable) {
                Log.e("PanelExt", "Couldn't clean up the Cloudflare WebView", e)
            }
        }

        if (!cloudflareBypassed) {
            // A clearance from a failed challenge would only be rejected again.
            cookieManager.remove(originalRequest.url, COOKIE_NAMES, 0)
            throw CloudflareBypassException(
                when {
                    interactive -> "The site's Cloudflare check needs a tap, which Panel can't do in the background"
                    isWebViewOutdated -> "Couldn't pass the site's Cloudflare check. Update Android System WebView and try again"
                    else -> "Couldn't pass the site's Cloudflare check"
                },
            )
        }
    }

    private companion object {
        const val JS_INTERFACE = "panelCloudflare"
        val SERVER_CHECK = arrayOf("cloudflare-nginx", "cloudflare")
        val COOKIE_NAMES = listOf("cf_clearance")
    }
}

/** The Cloudflare check couldn't be passed. Wrapped in an IOException for OkHttp. */
class CloudflareBypassException(message: String) : Exception(message)
