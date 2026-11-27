package com.readlist.panel.ext

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** An installed extension whose sources were created. */
internal data class LoadedExtension(
    val pkg: String,
    val name: String,
    val versionName: String,
    val versionCode: Long,
    val libVersion: Double,
    /** 0 = safe, 1 = mixed, 2 = 18+ (Mihon's content warning levels). */
    val contentWarning: Int,
    val sources: List<Source>,
)

/** An installed extension that couldn't be used, and why. */
internal data class FailedExtension(
    val pkg: String,
    val name: String,
    val versionName: String,
    val versionCode: Long,
    val reason: String,
    /** Installed fine, but its signing key isn't trusted yet (see [ExtensionTrust]). */
    val untrusted: Boolean = false,
    /** The key to show and trust (SHA-256 of the signing certificate). */
    val signature: String? = null,
)

/**
 * Finds installed Mihon / Tachiyomi extension apps and creates their sources.
 *
 * Ported from Mihon's ExtensionLoader (Apache 2.0), without Mihon's private
 * (in-app) installs or content filters. Only extensions with a trusted
 * signing key are opened (see [ExtensionTrust]).
 *
 * Results are cached per package and version code, so calling [load] again is
 * cheap and only (re)loads apps that were installed or updated since.
 */
internal object ExtensionLoader {

    private const val TAG = "PanelExt"

    private const val EXTENSION_FEATURE = "tachiyomi.extension"
    private const val METADATA_SOURCE_CLASS = "tachiyomi.extension.class"
    private const val METADATA_NSFW = "tachiyomi.extension.nsfw"
    private const val METADATA_NAME = "tachiyomix.name"
    private const val METADATA_EXTENSION_LIB = "tachiyomix.extensionLib"
    private const val METADATA_CONTENT_WARNING = "tachiyomix.contentWarning"

    // Mihon supports 1.4 and 1.6; 1.5 builds use the same API as 1.4.
    private const val LIB_VERSION_MIN = 1.4
    private const val LIB_VERSION_MAX = 1.6

    @Suppress("DEPRECATION")
    private val PACKAGE_FLAGS = PackageManager.GET_CONFIGURATIONS or
        PackageManager.GET_META_DATA or
        PackageManager.GET_SIGNATURES or
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else 0)

    private val mutex = Mutex()

    @Volatile
    private var loaded: Map<String, LoadedExtension> = emptyMap()

    @Volatile
    var failed: List<FailedExtension> = emptyList()
        private set

    @Volatile
    private var sourcesById: Map<Long, Source> = emptyMap()

    /** A source by its Mihon id, if its extension is loaded. */
    fun source(id: Long): Source? = sourcesById[id]

    /**
     * Scans installed apps and returns every loaded extension.
     * [forceReload] recreates all sources, even unchanged ones.
     */
    suspend fun load(context: Context, forceReload: Boolean = false): List<LoadedExtension> =
        mutex.withLock {
            withContext(Dispatchers.IO) {
                val pm = context.packageManager
                val packages = installedExtensionPackages(pm)
                val previous = if (forceReload) emptyMap() else loaded

                val results = packages
                    .map { pkg ->
                        async {
                            // One broken package must not stop the others loading.
                            try {
                                val cached = previous[pkg.packageName]
                                // Trust is checked again every time: removing a repo
                                // or revoking trust unloads the extension.
                                val trusted = ExtensionTrust.isTrusted(
                                    context,
                                    pkg.packageName,
                                    ExtensionTrust.signatures(pkg),
                                )
                                if (trusted && cached != null && cached.versionCode == pkg.longVersion()) {
                                    cached
                                } else {
                                    loadCatching(context, pkg)
                                }
                            } catch (e: Throwable) {
                                Log.e(TAG, "Extension check failed: ${pkg.packageName}", e)
                                fail(pkg, pkg.packageName, e.rootMessage)
                            }
                        }
                    }
                    .awaitAll()

                val ok = results.filterIsInstance<LoadedExtension>()
                loaded = ok.associateBy { it.pkg }
                failed = results.filterIsInstance<FailedExtension>()
                sourcesById = buildMap {
                    for (ext in ok) for (s in ext.sources) {
                        val id = runCatching { s.id }.getOrNull() ?: continue
                        // First one wins, like Mihon.
                        if (id !in this) put(id, s)
                    }
                }
                ok.sortedBy { it.name.lowercase() }
            }
        }

    /**
     * Lists apps with only the light GET_CONFIGURATIONS flag, then reads full
     * info (metadata, signatures) for the extensions alone. Asking for
     * signatures of every app at once can go over the binder limit on phones
     * with many apps (TransactionTooLargeException / "Package manager has died").
     */
    @Suppress("DEPRECATION")
    private fun installedExtensionPackages(pm: PackageManager): List<PackageInfo> {
        val light = PackageManager.GET_CONFIGURATIONS
        val all = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getInstalledPackages(PackageManager.PackageInfoFlags.of(light.toLong()))
        } else {
            pm.getInstalledPackages(light)
        }
        return all
            .filter { info -> info.reqFeatures.orEmpty().any { it.name == EXTENSION_FEATURE } }
            .mapNotNull { info ->
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        pm.getPackageInfo(info.packageName, PackageManager.PackageInfoFlags.of(PACKAGE_FLAGS.toLong()))
                    } else {
                        pm.getPackageInfo(info.packageName, PACKAGE_FLAGS)
                    }
                } catch (e: Exception) {
                    // Uninstalled in the meantime.
                    Log.w(TAG, "Couldn't read ${info.packageName}", e)
                    null
                }
            }
    }

    private fun loadCatching(context: Context, pkgInfo: PackageInfo): Any = try {
        loadExtension(context, pkgInfo)
    } catch (e: Throwable) {
        Log.e(TAG, "Extension load error: ${pkgInfo.packageName}", e)
        fail(pkgInfo, pkgInfo.packageName, e.rootMessage)
    }

    private fun fail(
        pkgInfo: PackageInfo,
        name: String,
        reason: String,
        untrusted: Boolean = false,
        signature: String? = null,
    ) = FailedExtension(
        pkg = pkgInfo.packageName,
        name = name,
        versionName = pkgInfo.versionName.orEmpty(),
        versionCode = pkgInfo.longVersion(),
        reason = reason,
        untrusted = untrusted,
        signature = signature,
    )

    private fun loadExtension(context: Context, pkgInfo: PackageInfo): Any {
        val pm = context.packageManager
        val appInfo = pkgInfo.applicationInfo
        val metaData = appInfo?.metaData
        val pkgName = pkgInfo.packageName

        val extName = metaData?.getString(METADATA_NAME)
            ?: appInfo?.let { pm.getApplicationLabel(it).toString().substringAfter("Tachiyomi: ") }
            ?: pkgName

        if (appInfo == null || metaData == null) return fail(pkgInfo, extName, "Malformed extension (no metadata)")

        val versionName = pkgInfo.versionName
        if (versionName.isNullOrEmpty()) return fail(pkgInfo, extName, "Malformed extension (no version)")

        val libVersion = metaData.getFloat(METADATA_EXTENSION_LIB)
            .takeUnless { it == 0.0f }
            ?.toString()
            ?.toDouble()
            ?: versionName.substringBeforeLast('.').toDoubleOrNull()
        if (libVersion == null || libVersion < LIB_VERSION_MIN || libVersion > LIB_VERSION_MAX) {
            return fail(
                pkgInfo,
                extName,
                "Unsupported extension lib $libVersion (Panel supports $LIB_VERSION_MIN–$LIB_VERSION_MAX)",
            )
        }

        // Before any of the APK's code is touched.
        val signatures = ExtensionTrust.signatures(pkgInfo)
        if (signatures.isEmpty()) return fail(pkgInfo, extName, "The extension isn't signed")
        if (!ExtensionTrust.isTrusted(context, pkgName, signatures)) {
            return fail(pkgInfo, extName, "Not trusted yet", untrusted = true, signature = signatures.last())
        }

        val contentWarning = when {
            metaData.containsKey(METADATA_CONTENT_WARNING) -> metaData.getInt(METADATA_CONTENT_WARNING).coerceIn(0, 2)
            metaData.getInt(METADATA_NSFW) == 1 -> 2
            else -> 0
        }

        val sourceClasses = metaData.getString(METADATA_SOURCE_CLASS)
        if (sourceClasses.isNullOrBlank()) return fail(pkgInfo, extName, "Malformed extension (no source class)")

        val classLoader = DelegateLastPathClassLoader(appInfo.sourceDir, null, context.classLoader)
        ExtensionCrashGuard.register(classLoader)

        val sources = sourceClasses
            .split(";")
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { if (it.startsWith(".")) pkgName + it else it }
            .flatMap { className ->
                try {
                    when (val obj = Class.forName(className, false, classLoader).getDeclaredConstructor().newInstance()) {
                        is Source -> listOf(obj)
                        is SourceFactory -> obj.createSources()
                        else -> throw IllegalStateException("Unknown source class type: ${obj.javaClass}")
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "Extension load error: $extName ($className)", e)
                    return fail(pkgInfo, extName, e.rootMessage)
                }
            }

        return LoadedExtension(
            pkg = pkgName,
            name = extName,
            versionName = versionName,
            versionCode = pkgInfo.longVersion(),
            libVersion = libVersion,
            contentWarning = contentWarning,
            sources = sources,
        )
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.longVersion(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

    private val Throwable.rootMessage: String
        get() {
            val root = generateSequence(this) { it.cause }.last()
            return listOfNotNull(root::class.simpleName, root.message).joinToString(": ")
        }
}
