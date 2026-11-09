// Pieces the tavern's pages share: a character's picture, and importing a
// card from a file.

import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
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
