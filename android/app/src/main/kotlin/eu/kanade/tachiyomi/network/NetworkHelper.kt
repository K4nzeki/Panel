package eu.kanade.tachiyomi.network

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import java.io.File
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * The shared HTTP client handed to every extension (`network.client` in
 * [eu.kanade.tachiyomi.source.online.HttpSource]).
 *
 * Ported from Mihon (Apache 2.0) without its settings screen: no DoH, no
 * verbose logging. Cloudflare's browser check is passed automatically by
 * [CloudflareInterceptor] (a hidden WebView), like in Mihon.
 *
 * The public members are part of the extension API: extensions built against
 * extensions-lib 1.4/1.5 call [cloudflareClient] and [defaultUserAgentProvider]
 * directly, so they must keep these exact names.
 */
class NetworkHelper(
    private val context: Context,
) {

    val cookieJar = AndroidCookieJar()

    private fun clientBuilder(): OkHttpClient.Builder = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .connectTimeout(30.seconds)
        .readTimeout(30.seconds)
        .callTimeout(2.minutes)
        .cache(
            Cache(
                directory = File(context.cacheDir, "network_cache"),
                maxSize = 5L * 1024 * 1024, // 5 MiB
            ),
        )
        .addInterceptor(UncaughtExceptionInterceptor())
        .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))

    val client: OkHttpClient by lazy {
        clientBuilder()
            .addInterceptor(CloudflareInterceptor(context, cookieJar, ::defaultUserAgentProvider))
            .build()
    }

    @Deprecated("The regular client handles Cloudflare by default")
    @Suppress("UNUSED")
    val cloudflareClient: OkHttpClient get() = client

    fun defaultUserAgentProvider(): String = DEFAULT_USER_AGENT

    companion object {
        // Same style of UA Mihon ships by default (a current mobile Chrome).
        const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"
    }
}
