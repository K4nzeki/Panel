import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme.dart';

/// Bump when the terms change in a way people should see again: the
/// first-run notice then shows once more.
const legalTermsVersion = 1;
const _ackKey = 'legal_terms_ack_v';

/// The sections of Panel's legal terms. Shared by [LegalScreen] and the
/// first-run notice so both always say the same thing.
const legalSections = <(String, String)>[
  (
    'What Panel is',
    'Panel is a personal reading tracker and reader. It does not host, '
        'upload, own, sell or distribute any manga, manhwa, manhua, comics '
        'or other content. Everything you track is saved on this device '
        'only.',
  ),
  (
    'Third-party extensions and sources',
    'Chapters, covers and titles shown in Panel come from third-party '
        'sources you choose: MangaDex, websites listed by extension repos '
        'you add, and extensions you install. They are not made, run, '
        'checked or endorsed by Panel. Their content, accuracy, '
        'availability, safety and legality are the responsibility of '
        'those sources, and their own terms apply.',
  ),
  (
    'Your responsibility',
    'You decide which repos, extensions and sources to use and what to '
        'read or download. You are responsible for making sure that doing '
        'so is legal where you live and respects the rights of the people '
        'who made the work. Please support creators by reading through '
        'official releases when you can.',
  ),
  (
    'Copyright',
    'All titles, artwork and trademarks belong to their owners. Panel does '
        'not claim any rights to them. Copyright questions about content '
        'belong with the source that provides it; Panel cannot remove '
        'content from third-party sites.',
  ),
  (
    'No warranty',
    'Panel is provided "as is" and "as available", without warranties of '
        'any kind, express or implied, including fitness for a particular '
        'purpose, accuracy and non-infringement. Sources can stop working, '
        'change or show wrong information at any time.',
  ),
  (
    'No liability',
    'To the fullest extent the law allows, the developers of Panel are not '
        'liable for any damage or loss arising from using the app or any '
        'third-party extension, source or content, including lost data, '
        'device problems or legal claims.',
  ),
  (
    'Changes',
    'These terms may be updated with new versions of the app. Continuing '
        'to use Panel after an update means you accept the updated terms.',
  ),
];

/// Settings → Legal terms & disclaimer.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Legal terms & disclaimer')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Please read this so you know what Panel is responsible for — '
            'and what it isn’t.',
            style: context.text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
          ),
          for (final (title, body) in legalSections) ...[
            const SizedBox(height: 20),
            Text(title, style: context.text.titleMedium),
            const SizedBox(height: 6),
            Text(body, style: context.text.bodyMedium?.copyWith(height: 1.5)),
          ],
        ],
      ),
    );
  }
}

Future<void> openLegalTerms(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const LegalScreen()));

/// Shows the disclaimer once (and again after [legalTermsVersion] goes up),
/// until it's acknowledged.
Future<void> showLegalNoticeOnce(BuildContext context, WidgetRef ref) async {
  final prefs = ref.read(sharedPrefsProvider);
  if ((prefs.getInt(_ackKey) ?? 0) >= legalTermsVersion) return;
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        icon: const Icon(Icons.gavel_rounded),
        title: const Text('Before you start'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Panel doesn’t host any content. Titles, covers and chapters '
                'come from third-party sources and extensions you choose, '
                'which Panel doesn’t control or endorse.\n\n'
                'You’re responsible for using them legally where you live. '
                'Panel is provided as is, with no warranty and no liability '
                'for third-party content.',
              ),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () => openLegalTerms(ctx),
                child: const Text('Read the full terms'),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) await prefs.setInt(_ackKey, legalTermsVersion);
}
