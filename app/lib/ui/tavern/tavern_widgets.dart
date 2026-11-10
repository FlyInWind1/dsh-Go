// Pieces the tavern's pages share: a character's picture, importing a card,
// deleting with a confirmation, and the long-press action sheet.

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_provider.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The card picture, or — for a card without one — a quiet field in the
/// theme's container colour with the name's first character.
class TavernPortrait extends StatelessWidget {
  const TavernPortrait({super.key, required this.name, this.path, this.radius = AppShape.lg, this.initialSize = 40});

  final String name;
  final String? path;
  final double radius;
  final double initialSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = path;
    final Widget body = file != null
        ? Image.file(File(file), fit: BoxFit.cover, errorBuilder: (_, _, _) => _initial(context))
        : _initial(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(color: scheme.surfaceContainerHighest, child: body),
    );
  }

  Widget _initial(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.characters.isEmpty ? '?' : name.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerHighest],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(fontSize: initialSize, color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

/// Asks, then deletes [character] and its chats. True when it was deleted.
Future<bool> deleteTavernCharacter(BuildContext context, WidgetRef ref, TavernCharacter character) async {
  final l10n = context.l10n;
  final ok = await _confirmDelete(
    context,
    title: l10n.tavernDeleteCharacterTitle(character.name),
    message: l10n.tavernDeleteCharacterMessage,
  );
  if (!ok) return false;
  final tavern = ref.read(tavernProvider);
  // Its chats go with it, and so do their pictures.
  // Never held up by it: without the list, the pictures just stay.
  final chats = await tavern
      .watchChats(characterId: character.id)
      .first
      .timeout(const Duration(seconds: 3))
      .catchError((_) => <TavernChatSummary>[]);
  await tavern.deleteCharacter(character.id);
  for (final chat in chats) {
    await forgetTavernBackground(chat.id);
  }
  return true;
}

/// Asks, then deletes one chat. True when it was deleted.
Future<bool> deleteTavernChat(BuildContext context, WidgetRef ref, String chatId) async {
  final l10n = context.l10n;
  final ok = await _confirmDelete(context, title: l10n.tavernDeleteChatTitle, message: l10n.tavernDeleteChatMessage);
  if (!ok) return false;
  await ref.read(tavernProvider).deleteChat(chatId);
  await forgetTavernBackground(chatId);
  return true;
}

Future<bool> _confirmDelete(BuildContext context, {required String title, required String message}) async {
  final l10n = context.l10n;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.commonCancel)),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(l10n.commonDelete)),
      ],
    ),
  );
  return ok == true;
}

/// A one-row sheet of actions on something the person long-pressed.
Future<void> showTavernActions(BuildContext context, List<(IconData, String, VoidCallback)> actions) =>
    showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        top: false,
        child: SheetGroup(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          children: [
            for (final (icon, title, onTap) in actions)
              SettingsTile(
                icon: icon,
                tinted: false,
                danger: icon == AppIcons.delete,
                title: title,
                onTap: () {
                  Navigator.of(sheet).pop();
                  onTap();
                },
              ),
          ],
        ),
      ),
    );

/// Our own sample card (assets/tavern), written for DSH Go: two greetings,
/// example lines and a small lorebook to try the tavern with.
const tavernSampleCardAsset = 'assets/tavern/sample_innkeeper.json';

/// Imports the sample card; says how it went. Returns the character, or null.
Future<TavernCharacter?> importSampleTavernCard(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final data = await rootBundle.load(tavernSampleCardAsset);
    final character = await ref
        .read(tavernProvider)
        .importCard(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), fileName: 'sample_innkeeper.json');
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    return character;
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
    return null;
  }
}

/// Downloads cards from links. Tests swap it.
final tavernHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

enum _ImportFrom { file, link }

/// 导入: from a file, or from a link to a card file. Returns the imported
/// character so the caller can open it.
Future<TavernCharacter?> showTavernImport(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final from = await showAppSheet<_ImportFrom>(
    context,
    builder: (sheet) => SafeArea(
      top: false,
      child: SheetGroup(
        margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        children: [
          SettingsTile(
            key: const ValueKey('tavern-import-file'),
            icon: AppIcons.files,
            tinted: false,
            title: l10n.tavernImportFromFile,
            subtitle: l10n.tavernImportFromFileSubtitle,
            chevron: false,
            onTap: () => Navigator.of(sheet).pop(_ImportFrom.file),
          ),
          SettingsTile(
            key: const ValueKey('tavern-import-link'),
            icon: AppIcons.link,
            tinted: false,
            title: l10n.tavernImportFromLink,
            subtitle: l10n.tavernImportFromLinkSubtitle,
            chevron: false,
            onTap: () => Navigator.of(sheet).pop(_ImportFrom.link),
          ),
        ],
      ),
    ),
  );
  if (from == null || !context.mounted) return null;
  return switch (from) {
    _ImportFrom.file => importTavernCard(context, ref),
    _ImportFrom.link => importTavernCardFromLink(context, ref),
  };
}

/// Asks for a link to a card file (PNG, JSON or CHARX), downloads it and
/// imports it; says how it went. A link already on the clipboard is filled in.
Future<TavernCharacter?> importTavernCardFromLink(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final client = ref.read(tavernHttpClientProvider);
  final tavern = ref.read(tavernProvider);
  // Only a convenience: never wait long on the clipboard.
  final clip = await Clipboard.getData(Clipboard.kTextPlain)
      .timeout(const Duration(milliseconds: 500), onTimeout: () => null)
      .catchError((Object _) => null);
  final copied = clip?.text?.trim() ?? '';
  if (!context.mounted) return null;
  final link = await showAppDialog<String>(
    context: context,
    builder: (_) => _LinkDialog(initial: copied.startsWith(RegExp('https?://')) ? copied : ''),
  );
  if (link == null || link.trim().isEmpty) return null;
  final uri = Uri.tryParse(link.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkInvalid)));
    return null;
  }
  final http.Response response;
  try {
    response = await client.get(uri).timeout(const Duration(seconds: 60));
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkFailed)));
    return null;
  }
  if (response.statusCode != 200) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkStatus(response.statusCode))));
    return null;
  }
  // A card site's page rather than the card file itself.
  if ((response.headers['content-type'] ?? '').contains('text/html')) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernLinkIsPage)));
    return null;
  }
  final name = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'card';
  try {
    final character = await tavern.importCard(response.bodyBytes, fileName: name);
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    return character;
  } on TavernImportError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.isLorebook ? l10n.tavernImportLorebook : l10n.tavernImportFailed)));
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
  }
  return null;
}

/// Picks a card file and imports it; says how it went. Returns the character,
/// or null when nothing was imported.
Future<TavernCharacter?> importTavernCard(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final file = (await FilePicker.pickFiles()).firstOrNull;
  if (file == null) return null;
  try {
    final character = await ref.read(tavernProvider).importCard(await file.readAsBytes(), fileName: file.name);
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImported(character.name))));
    return character;
  } on TavernImportError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.isLorebook ? l10n.tavernImportLorebook : l10n.tavernImportFailed)));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernImportFailed)));
  }
  return null;
}

/// Hands a card file to the system share sheet (save to Files, send to a
/// chat, open in another tavern): written into the app cache first, as the
/// diagnostics bundle is. Tests swap it.
final tavernCardSinkProvider = Provider<Future<void> Function(String name, Uint8List bytes, String mime)>(
  (ref) => (name, bytes, mime) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/tavern_export');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime, name: name)],
        fileNameOverrides: [name],
      ),
    );
  },
);

/// A file name from a character's name: no path or reserved characters.
@visibleForTesting
String tavernCardFileName(String name, TavernCardFormat format) {
  final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  return '${safe.isEmpty ? 'character' : safe}.${format.name}';
}

/// Exports [character] as a card in [format] and shares it.
Future<void> shareTavernCard(
  BuildContext context,
  WidgetRef ref,
  TavernCharacter character,
  TavernCardFormat format,
) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final sink = ref.read(tavernCardSinkProvider);
  try {
    final bytes = await ref.read(tavernProvider).exportCard(character.id, format: format);
    final mime = switch (format) {
      TavernCardFormat.png => 'image/png',
      TavernCardFormat.json => 'application/json',
      TavernCardFormat.charx => 'application/zip',
    };
    await sink(tavernCardFileName(character.name, format), bytes, mime);
  } on Object {
    messenger.showSnackBar(SnackBar(content: Text(l10n.tavernExportFailed)));
  }
}

/// Asks for a card file's link; owns its field, so it is let go with the route.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.initial});

  final String initial;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.tavernImportFromLink),
      content: TextField(
        key: const ValueKey('tavern-link-field'),
        controller: _field,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(hintText: 'https://…/card.png'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        TextButton(
          key: const ValueKey('tavern-link-go'),
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: Text(l10n.tavernImport),
        ),
      ],
    );
  }
}
