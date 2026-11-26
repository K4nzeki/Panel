package com.readlist.panel.ext

import eu.kanade.tachiyomi.source.model.Filter

/**
 * Sends a source's search filters to Dart as plain maps, and applies the
 * states Dart sends back onto a fresh copy of them.
 *
 * Encoded filter: `{type, name, state, values?, filters?}` where type is one
 * of header, separator, select, text, checkbox, tristate, sort, group,
 * unknown. Dart sends back a list of states in the same order (null = leave
 * as is): select/tristate → int, text → string, checkbox → bool,
 * sort → `{index, ascending}`, group → list of its children's states.
 */
internal object FilterCodec {

    fun encode(filters: List<Filter<*>>): List<Map<String, Any?>> = filters.map(::encodeOne)

    private fun encodeOne(f: Filter<*>): Map<String, Any?> = when (f) {
        is Filter.Header -> mapOf("type" to "header", "name" to f.name)
        is Filter.Separator -> mapOf("type" to "separator", "name" to f.name)
        is Filter.Select<*> -> mapOf(
            "type" to "select",
            "name" to f.name,
            "values" to f.values.map { it.toString() },
            "state" to f.state,
        )
        is Filter.Text -> mapOf("type" to "text", "name" to f.name, "state" to f.state)
        is Filter.CheckBox -> mapOf("type" to "checkbox", "name" to f.name, "state" to f.state)
        is Filter.TriState -> mapOf("type" to "tristate", "name" to f.name, "state" to f.state)
        is Filter.Sort -> mapOf(
            "type" to "sort",
            "name" to f.name,
            "values" to f.values.toList(),
            "state" to f.state?.let { mapOf("index" to it.index, "ascending" to it.ascending) },
        )
        is Filter.Group<*> -> mapOf(
            "type" to "group",
            "name" to f.name,
            "filters" to f.state.map { child ->
                if (child is Filter<*>) encodeOne(child) else mapOf("type" to "unknown", "name" to child.toString())
            },
        )
    }

    fun apply(filters: List<Filter<*>>, states: List<*>) {
        filters.forEachIndexed { i, f ->
            val s = states.getOrNull(i) ?: return@forEachIndexed
            try {
                applyOne(f, s)
            } catch (_: Exception) {
                // A bad value for one filter shouldn't break the search.
            }
        }
    }

    private fun applyOne(f: Filter<*>, s: Any) {
        when (f) {
            is Filter.Select<*> -> (s as? Number)?.toInt()?.let { if (it in f.values.indices) f.state = it }
            is Filter.Text -> (s as? String)?.let { f.state = it }
            is Filter.CheckBox -> (s as? Boolean)?.let { f.state = it }
            is Filter.TriState -> (s as? Number)?.toInt()?.let { f.state = it.coerceIn(0, 2) }
            is Filter.Sort -> (s as? Map<*, *>)?.let { m ->
                val index = (m["index"] as? Number)?.toInt() ?: return
                if (index !in f.values.indices) return
                f.state = Filter.Sort.Selection(index, m["ascending"] as? Boolean ?: false)
            }
            is Filter.Group<*> -> (s as? List<*>)?.let { childStates ->
                f.state.forEachIndexed { i, child ->
                    val cs = childStates.getOrNull(i)
                    if (child is Filter<*> && cs != null) applyOne(child, cs)
                }
            }
            is Filter.Header, is Filter.Separator -> Unit
        }
    }
}
