package eu.kanade.tachiyomi

import android.content.Context
import android.os.Build
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/**
 * Part of the extension API: some extensions send the host app's version.
 * Mihon reads BuildConfig; Panel reads its own package info instead.
 */
@Suppress("UNUSED")
object AppInfo {

    private val info by lazy {
        val context = Injekt.get<Context>()
        context.packageManager.getPackageInfo(context.packageName, 0)
    }

    @Suppress("DEPRECATION")
    fun getVersionCode(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toInt() else info.versionCode

    fun getVersionName(): String = info.versionName.orEmpty()

    fun getSupportedImageMimeTypes(): List<String> =
        listOf("image/avif", "image/gif", "image/heif", "image/jpeg", "image/jxl", "image/png", "image/webp")
}
