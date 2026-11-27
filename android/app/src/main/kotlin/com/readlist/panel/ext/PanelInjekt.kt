package com.readlist.panel.ext

import android.app.Application
import android.content.Context
import android.util.Log
import rx.functions.Action0
import rx.plugins.RxJavaHooks
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.network.NetworkHelper
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.protobuf.ProtoBuf
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.addSingletonFactory

/**
 * What extensions can ask Injekt for, mirroring Mihon's registrar:
 * `Injekt.get<Application>()` / `<Context>` (source preferences),
 * `<NetworkHelper>`, `<Json>`, `<ProtoBuf>` and `<JavaScriptEngine>`.
 *
 * Must run before any extension class is instantiated.
 */
object PanelInjekt {

    @Volatile
    private var initialized = false

    @OptIn(ExperimentalSerializationApi::class)
    @Synchronized
    fun init(context: Context) {
        if (initialized) return
        val app = context.applicationContext as Application

        Injekt.addSingleton<Application>(app)
        Injekt.addSingleton<Context>(app)
        Injekt.addSingletonFactory<NetworkHelper> { NetworkHelper(app) }
        Injekt.addSingletonFactory<Json> {
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
            }
        }
        Injekt.addSingletonFactory<ProtoBuf> { ProtoBuf }
        Injekt.addSingletonFactory<JavaScriptEngine> { JavaScriptEngine(app) }

        // Old (lib 1.4/1.5) extensions run on RxJava 1. When code scheduled
        // on an Rx scheduler throws (e.g. an extension's own subscribe()
        // without onError, or an error after its search was cancelled because
        // you left the source picker), Rx 1 hands it to the thread's uncaught
        // exception handler, which force-closes the app. Catch and log it.
        RxJavaHooks.setOnScheduleAction { action ->
            Action0 {
                try {
                    action.call()
                } catch (e: Throwable) {
                    Log.w("PanelExt", "Uncaught error in extension Rx code", e)
                }
            }
        }
        RxJavaHooks.setOnError { e -> Log.w("PanelExt", "Undeliverable extension error", e) }

        initialized = true
    }
}
