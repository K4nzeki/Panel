package com.readlist.panel.ext

import android.app.Application
import android.content.Context
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

        initialized = true
    }
}
