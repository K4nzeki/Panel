package eu.kanade.tachiyomi.util.system

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import okhttp3.Headers
import java.util.Locale

/**
 * WebView helpers, ported from Mihon (Apache 2.0) without the androidx.webkit
 * parts (user-agent brand spoofing), which need a newer compileSdk than Panel
 * builds with.
 */
object WebViewUtil {
    const val MINIMUM_WEBVIEW_VERSION = 118

    fun supportsWebView(context: Context): Boolean {
        try {
            // Throws MissingWebViewPackageException when WebView isn't installed.
            CookieManager.getInstance()
        } catch (e: Throwable) {
            Log.e("PanelExt", "WebView unavailable", e)
            return false
        }
        return context.packageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW)
    }
}

fun WebView.isOutdated(): Boolean = getWebViewMajorVersion() < WebViewUtil.MINIMUM_WEBVIEW_VERSION

@SuppressLint("SetJavaScriptEnabled")
fun WebView.setDefaultSettings() {
    with(settings) {
        javaScriptEnabled = true
        domStorageEnabled = true
        useWideViewPort = true
        loadWithOverviewMode = true
        cacheMode = WebSettings.LOAD_DEFAULT
        setSupportMultipleWindows(true)
    }
    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
}

fun WebView.setUserAgent(userAgent: String) {
    settings.userAgentString = userAgent
}

fun Headers.toWebViewHeaders(): Map<String, String> {
    return this
        // Unsafe headers make WebView fail with net::ERR_INVALID_ARGUMENT.
        .filter { (name, value) -> isRequestHeaderSafe(name, value) }
        .groupBy(keySelector = { (name, _) -> name }) { (_, value) -> value }
        .mapValues { it.value.getOrNull(0).orEmpty() }
}

// Based on IsRequestHeaderSafe in Chromium's services/network/public/cpp/header_util.cc
private fun isRequestHeaderSafe(rawName: String, rawValue: String): Boolean {
    val name = rawName.lowercase(Locale.ENGLISH)
    val value = rawValue.lowercase(Locale.ENGLISH)
    if (name in unsafeHeaderNames || name.startsWith("proxy-")) return false
    if (name == "connection" && value == "upgrade") return false
    return true
}

private val unsafeHeaderNames = listOf(
    "content-length", "host", "trailer", "te", "upgrade", "cookie2", "keep-alive", "transfer-encoding", "set-cookie",
    // The renderer is killed if it doesn't match the request initiator.
    "origin",
)

private fun WebView.getWebViewMajorVersion(): Int {
    val match = """.*Chrome/(\d+)\..*""".toRegex().matchEntire(getDefaultUserAgentString())
    return match?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0
}

// Based on https://stackoverflow.com/a/29218966
private fun WebView.getDefaultUserAgentString(): String {
    val original: String = settings.userAgentString
    settings.userAgentString = null
    val default = settings.userAgentString
    settings.userAgentString = original
    return default
}
