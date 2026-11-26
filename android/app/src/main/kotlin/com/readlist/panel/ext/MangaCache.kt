package com.readlist.panel.ext

import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga

/**
 * The SManga / SChapter objects extensions returned this session, by source
 * and url.
 *
 * Dart only keeps their urls (as keys). Some extensions also need other
 * fields they filled in earlier (title, thumbnail, memo...) when listing
 * chapters or pages, so the original object is reused when it's still here;
 * otherwise a fresh one is made from the url and name Dart sends.
 */
internal class SessionCache<V : Any>(private val max: Int) {

    private val map = object : LinkedHashMap<String, V>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, V>?) = size > max
    }

    private fun key(sourceId: Long, url: String) = "$sourceId\n$url"

    @Synchronized
    fun put(sourceId: Long, url: String, value: V) {
        map[key(sourceId, url)] = value
    }

    @Synchronized
    fun get(sourceId: Long, url: String): V? = map[key(sourceId, url)]
}

internal object MangaCache {
    private val cache = SessionCache<SManga>(2000)

    fun put(sourceId: Long, manga: SManga) {
        val url = runCatching { manga.url }.getOrNull() ?: return
        cache.put(sourceId, url, manga)
    }

    fun get(sourceId: Long, url: String): SManga? = cache.get(sourceId, url)
}

internal object ChapterCache {
    private val cache = SessionCache<SChapter>(5000)

    fun put(sourceId: Long, chapter: SChapter) {
        val url = runCatching { chapter.url }.getOrNull() ?: return
        cache.put(sourceId, url, chapter)
    }

    fun get(sourceId: Long, url: String): SChapter? = cache.get(sourceId, url)
}
