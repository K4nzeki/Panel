package com.readlist.panel.ext

import android.os.Looper
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Keeps a broken extension from force-closing Panel.
 *
 * Extensions sometimes start their own background work (their own coroutine
 * scopes, threads, Rx schedulers) that Panel's bridge never wraps. When that
 * code throws — say a NoClassDefFoundError for a library the extension
 * expects but Panel doesn't ship — the error goes to the thread's uncaught
 * exception handler, which kills the app.
 *
 * This handler sits in front of the default one. For a background thread
 * whose stack trace runs through an extension's own classes, it logs the
 * error and lets the thread carry on. Everything else (Panel's own bugs, and
 * anything on the main thread, whose looper can't survive an exception) is
 * passed on unchanged, so real crashes still show up.
 */
internal object ExtensionCrashGuard {

    private const val TAG = "PanelExt"

    private val loaders = CopyOnWriteArrayList<DelegateLastPathClassLoader>()

    @Volatile
    private var installed = false

    /** Remembers an extension's class loader, to recognise its code in stack traces. */
    fun register(loader: DelegateLastPathClassLoader) {
        loaders += loader
    }

    @Synchronized
    fun install() {
        if (installed) return
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            val swallow = try {
                thread !== Looper.getMainLooper().thread && fromExtension(error)
            } catch (_: Throwable) {
                false
            }
            if (swallow) {
                Log.e(TAG, "Extension code crashed on ${thread.name}; ignored so Panel keeps running", error)
            } else {
                previous?.uncaughtException(thread, error)
            }
        }
        installed = true
    }

    private fun fromExtension(error: Throwable): Boolean {
        if (loaders.isEmpty()) return false
        val seen = HashSet<Throwable>()
        val pending = ArrayDeque<Throwable>().apply { add(error) }
        while (pending.isNotEmpty()) {
            val t = pending.removeFirst()
            if (!seen.add(t)) continue
            for (frame in t.stackTrace) {
                val name = frame.className
                if (loaders.any { it.owns(name) }) return true
            }
            t.cause?.let(pending::add)
            pending.addAll(t.suppressed)
        }
        return false
    }
}
