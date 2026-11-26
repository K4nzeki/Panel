package com.readlist.panel.ext

import android.content.Context
import android.content.pm.PackageInfo
import android.os.Build
import java.security.MessageDigest

/**
 * Decides which installed extensions Panel may run. Extension code runs
 * inside Panel with Panel's permissions, so an APK is only loaded when its
 * signing key is trusted:
 *
 * - the key matches the signing fingerprint of one of your repos (that's how
 *   Mihon trusts its "stores"), or
 * - you trusted this package with this exact key yourself (needed for
 *   sideloaded APKs and repos that don't publish a fingerprint).
 *
 * A user-trusted package that gets re-signed with another key (a different
 * author, or a tampered APK) is untrusted again until you approve it.
 * Untrusted APKs are never opened, so none of their code runs.
 */
internal object ExtensionTrust {

    private const val PREFS = "panel_extension_trust"
    private const val KEY_REPO_KEYS = "repo_keys"
    private const val KEY_USER_TRUSTED = "user_trusted" // "pkg:sha256"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Lower-case hex without separators, so "AB:CD" and "abcd" match. */
    fun normalize(key: String): String = key.lowercase().filter { it in '0'..'9' || it in 'a'..'f' }

    fun repoKeys(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_REPO_KEYS, null).orEmpty()

    /** Replaces the repo fingerprints. Returns whether they changed. */
    fun setRepoKeys(context: Context, keys: Collection<String>): Boolean {
        val next = keys.map(::normalize).filter { it.isNotEmpty() }.toSet()
        if (next == repoKeys(context)) return false
        prefs(context).edit().putStringSet(KEY_REPO_KEYS, next).apply()
        return true
    }

    private fun userTrusted(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_USER_TRUSTED, null).orEmpty()

    fun isTrusted(context: Context, pkg: String, signatures: List<String>): Boolean {
        if (signatures.isEmpty()) return false
        val repo = repoKeys(context)
        if (signatures.any { it in repo }) return true
        val user = userTrusted(context)
        return signatures.any { "$pkg:$it" in user }
    }

    /** Trusts [pkg] signed with [signature] (replacing any older key for it). */
    fun trust(context: Context, pkg: String, signature: String) {
        val next = userTrusted(context).filterNot { it.startsWith("$pkg:") }.toMutableSet()
        next += "$pkg:${normalize(signature)}"
        prefs(context).edit().putStringSet(KEY_USER_TRUSTED, next).apply()
    }

    fun untrust(context: Context, pkg: String) {
        val next = userTrusted(context).filterNot { it.startsWith("$pkg:") }.toSet()
        prefs(context).edit().putStringSet(KEY_USER_TRUSTED, next).apply()
    }

    /** SHA-256 of each signing certificate, like Mihon (lower-case hex). */
    @Suppress("DEPRECATION")
    fun signatures(pkgInfo: PackageInfo): List<String> {
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pkgInfo.signingInfo ?: return emptyList()
            if (info.hasMultipleSigners()) info.apkContentsSigners else info.signingCertificateHistory
        } else {
            pkgInfo.signatures
        }
        return sigs.orEmpty().map { sha256(it.toByteArray()) }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
