// Pieces the tavern's pages share: a character's picture, importing a card,
// deleting with a confirmation, and the long-press action sheet.

import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
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
  if (ok) await ref.read(tavernProvider).deleteCharacter(character.id);
  return ok;
}

/// Asks, then deletes one chat. True when it was deleted.
Future<bool> deleteTavernChat(BuildContext context, WidgetRef ref, String chatId) async {
  final l10n = context.l10n;
  final ok = await _confirmDelete(context, title: l10n.tavernDeleteChatTitle, message: l10n.tavernDeleteChatMessage);
  if (ok) await ref.read(tavernProvider).deleteChat(chatId);
  return ok;
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
