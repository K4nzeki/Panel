# Mihon / Tachiyomi extensions are separate APKs loaded at runtime. They call
# into these classes by name, so R8 must keep them exactly as they are, even
# though Panel's own code never uses most of them.

# The extension API (ported from Mihon) and the Panel loader.
-keep class eu.kanade.tachiyomi.** { *; }
-keep class tachiyomi.core.common.** { *; }
-keep class mihon.core.common.** { *; }
-keep class com.readlist.panel.ext.** { *; }

# Libraries extensions are compiled against (compileOnly) and get from the host.
-keep,allowoptimization class kotlin.** { public protected *; }
-keep,allowoptimization class kotlinx.coroutines.** { public protected *; }
-keep,allowoptimization class kotlinx.serialization.** { public protected *; }
-keep,allowoptimization class okhttp3.** { public protected *; }
-keep,allowoptimization class okio.** { public protected *; }
-keep,allowoptimization class org.jsoup.** { public protected *; }
-keep,allowoptimization class rx.** { public protected *; }
-keep,allowoptimization class uy.kohesive.injekt.** { public protected *; }
-keep,allowoptimization class androidx.preference.** { public protected *; }

# Kotlin metadata/annotations some extensions read via kotlinx.serialization.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod, Exceptions

-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn org.jspecify.annotations.**
-dontwarn com.google.re2j.**
-dontwarn javax.annotation.**

# The Cloudflare WebView calls back into Kotlin through @JavascriptInterface.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
