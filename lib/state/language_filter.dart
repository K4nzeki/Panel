import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// The language you read in, picked in the Extension store. Also limits the
/// extension sources shown on Discover and in the source picker, so you only
/// see series in that language. Null = every language. Saved on the phone.
class ContentLanguageNotifier extends Notifier<String?> {
  static const _key = 'content_lang_v1';

  @override
  String? build() {
    final v = ref.read(sharedPrefsProvider).getString(_key);
    return (v == null || v.isEmpty || v == '*') ? null : v;
  }

  /// [lang] = null (or '*') for every language.
  void set(String? lang) {
    final v = (lang == null || lang == '*') ? null : lang;
    if (v == state) return;
    state = v;
    ref.read(sharedPrefsProvider).setString(_key, v ?? '*');
  }
}

final contentLanguageProvider =
    NotifierProvider<ContentLanguageNotifier, String?>(
        ContentLanguageNotifier.new);

/// Whether something in [lang] should show with the [filter] language.
/// Multi-language ("all") and unknown ones always show.
bool matchesLanguage(String? filter, String lang) =>
    filter == null || lang.isEmpty || lang == 'all' || lang == filter;
