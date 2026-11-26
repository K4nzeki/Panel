package eu.kanade.tachiyomi.network.interceptor

import android.content.Context
import android.webkit.WebSettings
import android.webkit.WebView
import eu.kanade.tachiyomi.util.system.WebViewUtil
import eu.kanade.tachiyomi.util.system.setDefaultSettings
import eu.kanade.tachiyomi.util.system.setUserAgent
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Ported from Mihon (Apache 2.0), without its toasts. */
abstract class WebViewInterceptor(
    private val context: Context,
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {

    private val initWebView by lazy {
        try {
            // Warms up WebView; can fail while Chrome/WebView is being updated.
            WebSettings.getDefaultUserAgent(context)
        } catch (_: Exception) {
        }
    }

    abstract fun shouldIntercept(response: Response): Boolean

    abstract fun intercept(chain: Interceptor.Chain, request: Request, response: Response): Response

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (!shouldIntercept(response)) return response
        if (!prepareWebView()) return response
        return intercept(chain, request, response)
    }

    /** False when the phone has no usable WebView (the original response is returned). */
    protected fun prepareWebView(): Boolean {
        if (!WebViewUtil.supportsWebView(context)) return false
        initWebView
        return true
    }

    fun CountDownLatch.awaitFor30Seconds() {
        await(30, TimeUnit.SECONDS)
    }

    fun createWebView(request: Request): WebView {
        return WebView(context).apply {
            setDefaultSettings()
            // Never send an empty User-Agent: Chromium WebView resets it to the default.
            // Using the request's own UA matters: Cloudflare ties its clearance cookie to it.
            setUserAgent(request.header("User-Agent") ?: defaultUserAgentProvider())
        }
    }
}
