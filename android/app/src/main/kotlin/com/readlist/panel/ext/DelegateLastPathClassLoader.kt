package com.readlist.panel.ext

import dalvik.system.PathClassLoader
import java.net.URL
import java.util.Collections
import java.util.Enumeration

/**
 * Loads an extension APK's classes. Lookup order: the boot class loader
 * (Android framework), then the extension's own dex, then Panel (the parent),
 * which supplies the extension API (eu.kanade.tachiyomi.*), OkHttp, Jsoup,
 * RxJava, Injekt, kotlinx and the Kotlin stdlib.
 *
 * Ported from Mihon's DelegateLastClassLoaderCompat (Apache 2.0). Mihon uses
 * the platform DelegateLastClassLoader only on Android 17+, because ART can
 * crash on older versions with it; this backport is safe everywhere.
 */
internal class DelegateLastPathClassLoader(
    dexPath: String,
    librarySearchPath: String?,
    parent: ClassLoader,
) : PathClassLoader(dexPath, librarySearchPath, parent) {

    private val bootClassLoader: ClassLoader? = Any::class.java.classLoader

    /** Whether [className] was loaded from this extension's own APK. */
    fun owns(className: String): Boolean {
        val c = findLoadedClass(className) ?: return false
        return c.classLoader === this
    }

    override fun loadClass(name: String?, resolve: Boolean): Class<*> {
        findLoadedClass(name)?.let { return it }

        if (bootClassLoader != null) {
            try {
                return bootClassLoader.loadClass(name)
            } catch (_: ClassNotFoundException) {
            }
        }

        val fromSelf = try {
            return findClass(name)
        } catch (e: ClassNotFoundException) {
            e
        }

        return try {
            parent.loadClass(name)
        } catch (_: ClassNotFoundException) {
            throw fromSelf
        }
    }

    override fun getResource(name: String?): URL? {
        return bootClassLoader?.getResource(name)
            ?: findResource(name)
            ?: parent?.getResource(name)
    }

    override fun getResources(name: String?): Enumeration<URL> {
        val resources = buildList {
            bootClassLoader?.getResources(name)?.let { addAll(it.toList()) }
            findResources(name)?.let { addAll(it.toList()) }
            parent?.getResources(name)?.let { addAll(it.toList()) }
        }
        return Collections.enumeration(resources)
    }
}
