package com.readlist.panel.ext

import android.content.Context
import android.util.Log
import eu.kanade.tachiyomi.network.HttpException
import eu.kanade.tachiyomi.network.interceptor.CloudflareBypassException
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.net.UnknownHostException
import kotlin.time.Duration.Companion.seconds

/**
 * The `com.readlist.panel/extensions` channel: Dart's ApkSource talks to the
 * installed Mihon extensions through it.
 *
 * Extensions:
 * - `getInstalledSources {reload?: bool}` → list of source maps (see [sourceToMap])
 * - `getLoadErrors` → installed extensions that weren't loaded, and why
 *   (`untrusted: true` + `signature` for ones waiting to be trusted)
 * - `setTrustedKeys {keys: [fingerprint]}` → signing keys of your repos
 * - `trustExtension {pkg, signature}` / `untrustExtension {pkg}`
 *
 * Browsing (Stage 2):
 * - `searchManga {sourceId, mode: popular|latest|search, page, query?, filters?}`
 *   → `{mangas: [manga map], hasNextPage}`
 * - `getFilterList {sourceId}` → filters (see [FilterCodec])
 *
 * Reading:
 * - `getChapterList {sourceId, mangaUrl, title?}` → chapter maps, newest first
 * - `getPageList {sourceId, chapterUrl, chapterName?}` → `[{index, url, imageUrl}]`
 * - `fetchImage {sourceId, index, url, imageUrl?}` → `{bytes, contentType, imageUrl}`,
 *   fetched with the extension's own client and image request (its headers,
 *   cookies and interceptors), resolving the image url first when needed.
 *
 * Errors use these codes: `not_found` (no such source loaded), `offline`,
 * `timeout`, `http` (details.httpCode), `cloudflare` (check not passed),
 * `cancelled`, `extension` (anything else).
 *
 * Extension code runs on the IO dispatcher (old Rx-based extensions block
 * their thread); answers go back to Dart on the main thread.
 */
class ExtensionBridge(context: Context) : MethodChannel.MethodCallHandler {

    private val app: Context = context.applicationContext

    // One scope for the app's lifetime: a slow site shouldn't be cancelled
    // just because the activity was recreated (rotation, theme change).
    private val scope get() = sharedScope

    init {
        PanelInjekt.init(app)
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    /** Loads the extensions in the background so the first search is quick. Logs what it found. */
    fun warmUp() {
        scope.launch {
            try {
                val exts = ExtensionLoader.load(app)
                Log.i(TAG, "Loaded ${exts.size} extension(s), ${exts.sumOf { it.sources.size }} source(s)")
                for (ext in exts) {
                    val names = ext.sources.joinToString { s ->
                        runCatching { "${s.name} [${s.lang}] id=${s.id}" }.getOrDefault("?")
                    }
                    Log.i(TAG, "  ${ext.name} ${ext.versionName} (lib ${ext.libVersion}): $names")
                }
                for (f in ExtensionLoader.failed) {
                    Log.w(TAG, "  NOT loaded: ${f.name} ${f.versionName} (${f.pkg}): ${f.reason}")
                }
            } catch (e: Throwable) {
                if (e is CancellationException) throw e
                Log.e(TAG, "Extension warm-up failed", e)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstalledSources" -> respond(result) {
                val reload = call.argument<Boolean>("reload") ?: false
                ExtensionLoader.load(app, forceReload = reload).flatMap { ext ->
                    ext.sources.mapNotNull { source -> sourceToMap(ext, source) }
                }
            }

            "getLoadErrors" -> respond(result) {
                ExtensionLoader.load(app)
                ExtensionLoader.failed.map {
                    mapOf(
                        "pkg" to it.pkg,
                        "name" to it.name,
                        "version" to it.versionName,
                        "versionCode" to it.versionCode,
                        "reason" to it.reason,
                        "untrusted" to it.untrusted,
                        "signature" to it.signature,
                    )
                }
            }

            "setTrustedKeys" -> respond(result) {
                val keys = call.argument<List<String>>("keys").orEmpty()
                ExtensionTrust.setRepoKeys(app, keys)
            }

            "trustExtension" -> respond(result) {
                val pkg = requireNotNull(call.argument<String>("pkg")) { "pkg missing" }
                val signature = requireNotNull(call.argument<String>("signature")) { "signature missing" }
                ExtensionTrust.trust(app, pkg, signature)
                null
            }

            "untrustExtension" -> respond(result) {
                val pkg = requireNotNull(call.argument<String>("pkg")) { "pkg missing" }
                ExtensionTrust.untrust(app, pkg)
                null
            }

            "searchManga" -> respond(result) {
                val source = sourceFor(call)
                val page = call.argument<Number>("page")?.toInt()?.coerceAtLeast(1) ?: 1
                val mode = call.argument<String>("mode") ?: "search"
                val mangasPage = runExtension {
                    when (mode) {
                        "popular" -> source.getPopularManga(page)
                        "latest" -> source.getLatestUpdates(page)
                        else -> {
                            val query = call.argument<String>("query").orEmpty()
                            val filters = source.getFilterList()
                            call.argument<List<*>>("filters")?.let { FilterCodec.apply(filters, it) }
                            source.getSearchManga(page, query, filters)
                        }
                    }
                }
                mapOf(
                    "mangas" to mangasPage.mangas.mapNotNull { mangaToMap(source, it) },
                    "hasNextPage" to mangasPage.hasNextPage,
                )
            }

            "getChapterList" -> respond(result) {
                val source = sourceFor(call)
                val id = source.id
                val url = requireNotNull(call.argument<String>("mangaUrl")) { "mangaUrl missing" }
                val manga = MangaCache.get(id, url) ?: SManga.create().also {
                    it.url = url
                    it.title = call.argument<String>("title").orEmpty()
                }
                val chapters = runExtension {
                    source.getMangaUpdate(manga, emptyList(), fetchDetails = false, fetchChapters = true).chapters
                }
                chapters.mapNotNull { chapter ->
                    prepareNewChapter(source, chapter, manga)
                    chapterToMap(source, chapter)
                }
            }

            "getPageList" -> respond(result) {
                val source = sourceFor(call)
                val url = requireNotNull(call.argument<String>("chapterUrl")) { "chapterUrl missing" }
                val chapter = ChapterCache.get(source.id, url) ?: SChapter.create().also {
                    it.url = url
                    it.name = call.argument<String>("chapterName").orEmpty()
                }
                val pages = runExtension { source.getPageList(chapter) }
                // Extensions return pages in reading order; their index is kept
                // because some use it when building the image request.
                pages.map { mapOf("index" to it.index, "url" to it.url, "imageUrl" to it.imageUrl) }
            }

            "fetchImage" -> respond(result) {
                val source = sourceFor(call) as? HttpSource
                    ?: throw IllegalStateException("This source can't load images")
                val page = Page(
                    index = call.argument<Number>("index")?.toInt() ?: 0,
                    url = call.argument<String>("url").orEmpty(),
                    imageUrl = call.argument<String>("imageUrl")?.takeIf { it.isNotBlank() },
                )
                runExtension {
                    if (page.imageUrl.isNullOrBlank()) page.imageUrl = source.getImageUrl(page)
                    source.getImage(page).use { response ->
                        val body = response.body
                        mapOf(
                            "bytes" to body.bytes(),
                            "contentType" to body.contentType()?.toString(),
                            "imageUrl" to page.imageUrl,
                        )
                    }
                }
            }

            "getFilterList" -> respond(result) {
                val source = sourceFor(call)
                runExtension { FilterCodec.encode(source.getFilterList()) }
            }

            else -> result.notImplemented()
        }
    }

    // ---- Helpers ----

    /** The loaded source named by the `sourceId` argument. */
    private suspend fun sourceFor(call: MethodCall): Source {
        val id = call.argument<String>("sourceId")?.toLongOrNull()
            ?: throw NotFound("No source id given")
        ExtensionLoader.source(id)?.let { return it }
        // Called before the warm-up finished, or the extension was just installed.
        ExtensionLoader.load(app)
        return ExtensionLoader.source(id)
            ?: throw NotFound("This source's extension isn't installed or trusted")
    }

    /** Runs extension code on the IO dispatcher with an overall time limit. */
    private suspend fun <T> runExtension(block: suspend () -> T): T =
        withContext(Dispatchers.IO) { withTimeout(EXTENSION_TIMEOUT) { block() } }

    /** Runs [block] in the background and answers Dart on the main thread. */
    private fun respond(result: MethodChannel.Result, block: suspend () -> Any?) {
        scope.launch {
            val value = try {
                block()
            } catch (e: Throwable) {
                safeReportError(result, e)
                return@launch
            }
            // Encoding the answer can throw (a value the channel codec doesn't
            // support, e.g. something an extension put in a field). Uncaught,
            // that kills the app on the main thread; report it to Dart instead.
            try {
                result.success(value)
            } catch (e: Throwable) {
                Log.e(TAG, "Couldn't send an extension answer to Dart", e)
                safeReportError(result, e)
            }
        }
    }

    /** [reportError] must never throw: it runs on the main thread. */
    private fun safeReportError(result: MethodChannel.Result, e: Throwable) {
        try {
            reportError(result, e)
        } catch (inner: Throwable) {
            Log.e(TAG, "Couldn't report an extension error", inner)
            runCatching { result.error("extension", e.javaClass.simpleName, null) }
        }
    }

    private fun reportError(result: MethodChannel.Result, e: Throwable) {
        val root = generateSequence(e) { it.cause }.last()
        when {
            e is TimeoutCancellationException ->
                result.error("timeout", "The site took too long to answer", null)
            e is CancellationException ->
                result.error("cancelled", "Cancelled", null)
            e is NotFound ->
                result.error("not_found", e.message, null)
            generateSequence(e) { it.cause }.firstOrNull { it is CloudflareBypassException } != null -> {
                val cf = generateSequence(e) { it.cause }.first { it is CloudflareBypassException }
                result.error("cloudflare", cf.message, null)
            }
            root is UnknownHostException ->
                result.error("offline", root.message ?: "No connection", null)
            e is HttpException || root is HttpException -> {
                val code = (e as? HttpException ?: root as HttpException).code
                result.error("http", "HTTP error $code", mapOf("httpCode" to code))
            }
            else -> {
                Log.e(TAG, "Extension call failed", e)
                val message = root.message?.takeIf { it.isNotBlank() } ?: root.javaClass.simpleName
                result.error("extension", message, mapOf("trace" to e.stackTraceToString().take(4000)))
            }
        }
    }

    /** Null when the extension's source throws while describing itself. */
    private fun sourceToMap(ext: LoadedExtension, source: Source): Map<String, Any?>? = try {
        val http = source as? HttpSource
        mapOf(
            "id" to source.id.toString(),
            "name" to source.name,
            "lang" to source.lang,
            "supportsLatest" to source.supportsLatest,
            "baseUrl" to http?.let { runCatching { it.baseUrl }.getOrNull() },
            // What the extension sends with every request (User-Agent, Referer...);
            // Dart uses it for cover images.
            "headers" to http?.let { h ->
                runCatching { h.headers.names().associateWith { name -> h.headers.values(name).joinToString(", ") } }
                    .getOrNull()
            },
            "configurable" to (source is ConfigurableSource),
            "pkg" to ext.pkg,
            "extName" to ext.name,
            "version" to ext.versionName,
            "versionCode" to ext.versionCode,
            "libVersion" to ext.libVersion,
            "contentWarning" to ext.contentWarning,
            "nsfw" to (ext.contentWarning == 2),
        )
    } catch (e: Throwable) {
        Log.e(TAG, "Couldn't describe a source of ${ext.pkg}", e)
        null
    }

    /** Null when the manga has no url or title (extensions leave lateinits unset). */
    private fun mangaToMap(source: Source, manga: SManga): Map<String, Any?>? {
        val url = runCatching { manga.url }.getOrNull() ?: return null
        val title = runCatching { manga.title }.getOrNull() ?: return null
        val id = runCatching { source.id }.getOrNull()
        if (id != null) MangaCache.put(id, manga)
        return mapOf(
            "url" to url,
            "title" to title,
            "thumbnailUrl" to manga.thumbnail_url,
            "author" to manga.author,
            "artist" to manga.artist,
            "description" to manga.description,
            "genre" to manga.genre,
            "status" to manga.status,
            "initialized" to manga.initialized,
            // The page for "open in browser"; no network involved.
            "webUrl" to (source as? HttpSource)?.let { runCatching { it.getMangaUrl(manga) }.getOrNull() },
        )
    }

    /** Deprecated in the API, but older extensions still fix chapter numbers here. */
    @Suppress("DEPRECATION")
    private fun prepareNewChapter(source: Source, chapter: SChapter, manga: SManga) {
        if (source is HttpSource) runCatching { source.prepareNewChapter(chapter, manga) }
    }

    /** Null when the chapter has no url or name. */
    private fun chapterToMap(source: Source, chapter: SChapter): Map<String, Any?>? {
        val url = runCatching { chapter.url }.getOrNull() ?: return null
        val name = runCatching { chapter.name }.getOrNull() ?: return null
        runCatching { source.id }.getOrNull()?.let { ChapterCache.put(it, chapter) }
        return mapOf(
            "url" to url,
            "name" to name,
            "chapterNumber" to chapter.chapter_number.toDouble(),
            "scanlator" to chapter.scanlator,
            "dateUpload" to chapter.date_upload,
            "webUrl" to (source as? HttpSource)?.let { runCatching { it.getChapterUrl(chapter) }.getOrNull() },
        )
    }

    private class NotFound(message: String) : Exception(message)

    companion object {
        const val CHANNEL = "com.readlist.panel/extensions"
        private const val TAG = "PanelExt"
        private val EXTENSION_TIMEOUT = 60.seconds

        // Last line of defence: anything that still escapes a call (extension
        // code is third-party) is logged instead of force-closing Panel.
        private val crashGuard = CoroutineExceptionHandler { _, e ->
            Log.e(TAG, "Uncaught error in extension call", e)
        }

        private val sharedScope =
            CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate + crashGuard)
    }
}
