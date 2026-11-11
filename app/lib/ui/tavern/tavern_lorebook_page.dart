// 世界书: the entries a card carries in its own V3 character_book (engine
// T16), listed by order with a switch each; one opens to edit, a new one is
// added, an old one deleted. Each edit goes to the card by the entry's place
// in the book (its index), so entries keep their identity.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../common/brief_notice.dart';
import '../common/discard_guard.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_widgets.dart';

/// One entry of the book, at [index] in its entries array.
typedef TavernBookEntry = ({int index, Map<String, Object?> entry});

/// A card's own book as stored: its name, and its entries highest order
/// first, as ST lists them. Read again whenever the library changes.
final tavernCardBookProvider = FutureProvider.autoDispose
    .family<({String? name, List<TavernBookEntry> entries}), String>((ref, characterId) async {
      ref.watch(tavernCharactersProvider);
      final fields = await ref.watch(tavernProvider).characterFields(characterId);
      final book = fields?['character_book'];
      final entries = <TavernBookEntry>[
        if (book is Map && book['entries'] is List)
          for (final (i, e) in (book['entries'] as List).indexed)
            if (e is Map<String, Object?>) (index: i, entry: e),
      ];
      // Stable: equal orders keep the book's own order.
      final sorted = [...entries]..sort((a, b) => _order(b.entry).compareTo(_order(a.entry)));
      final name = book is Map && book['name'] is String && (book['name'] as String).isNotEmpty
          ? book['name'] as String
          : null;
      return (name: name, entries: sorted);
    });

num _order(Map<String, Object?> e) => switch (e['insertion_order']) {
  final num n => n,
  _ => 0,
};

List<String> _strings(Object? v) => [
  if (v is List)
    for (final s in v)
      if (s is String && s.isNotEmpty) s,
];

/// What a list row calls an entry: its name, else its first key.
String _title(Map<String, Object?> e) {
  final comment = e['comment'] is String ? (e['comment'] as String).trim() : '';
  if (comment.isNotEmpty) return comment;
  final keys = _strings(e['keys']);
  return keys.isNotEmpty ? keys.first : '—';
}

class TavernLorebookPage extends ConsumerWidget {
  const TavernLorebookPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernLorebookPage(characterId: characterId));

  Future<void> _setEnabled(WidgetRef ref, int index, bool on) async {
    await ref.read(tavernProvider).updateCharacterBookEntry(characterId, index, {'enabled': on});
    ref.invalidate(tavernCardBookProvider(characterId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final book = ref.watch(tavernCardBookProvider(characterId)).value;
    void open(TavernBookEntry? entry) =>
        unawaited(Navigator.of(context).push(TavernLorebookEntryPage.route(characterId: characterId, entry: entry)));
    return AppPage.list(
      title: book?.name ?? l10n.tavernLorebook,
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-lore-add'),
          icon: AppIcons.add,
          tooltip: l10n.tavernLorebookAdd,
          onPressed: () => open(null),
        ),
      ],
      children: [
        if (book == null)
          const QuietSpinner()
        else if (book.entries.isEmpty)
          Padding(
            key: const ValueKey('tavern-lore-empty'),
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Text(
              l10n.tavernLorebookStart,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: DshColors.of(context).textTertiary, height: 1.5),
            ),
          )
        else
          SettingsSection(
            title: l10n.tavernLorebookEntries(book.entries.length),
            footer: Text(l10n.tavernLorebookNote),
            children: [
              for (final (i, e) in book.entries.indexed)
                _EntryRow(
                  key: ValueKey('tavern-lore-$i'),
                  entry: e.entry,
                  onOpen: () => open(e),
                  onEnabled: (on) => unawaited(_setEnabled(ref, e.index, on)),
                ),
            ],
          ),
      ],
    );
  }
}

/// An entry in the list: its name, its keys, 常驻 if always on, and a switch.
class _EntryRow extends StatelessWidget {
  const _EntryRow({super.key, required this.entry, required this.onOpen, required this.onEnabled});

  final Map<String, Object?> entry;
  final VoidCallback onOpen;
  final ValueChanged<bool> onEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final keys = _strings(entry['keys']);
    final on = entry['enabled'] != false;
    return InkWell(
      onTap: onOpen,
      splashFactory: rowSplash(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Opacity(
                opacity: on ? 1 : 0.5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _title(entry),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                        if (entry['constant'] == true)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              l10n.tavernLorebookConstant,
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                            ),
                          ),
                      ],
                    ),
                    if (keys.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          l10n.tavernLorebookKeys(keys.join('、')),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Switch(value: on, onChanged: onEnabled),
          ],
        ),
      ),
    );
  }
}

/// One entry, edited; [entry] null for a new one, added on save.
class TavernLorebookEntryPage extends ConsumerStatefulWidget {
  const TavernLorebookEntryPage({super.key, required this.characterId, this.entry});

  final String characterId;
  final TavernBookEntry? entry;

  static Route<void> route({required String characterId, TavernBookEntry? entry}) => MaterialPageRoute<void>(
    builder: (_) => TavernLorebookEntryPage(characterId: characterId, entry: entry),
  );

  @override
  ConsumerState<TavernLorebookEntryPage> createState() => _TavernLorebookEntryPageState();
}

class _TavernLorebookEntryPageState extends ConsumerState<TavernLorebookEntryPage> {
  Map<String, Object?> get _old => widget.entry?.entry ?? const {};

  late final _name = TextEditingController(text: _old['comment'] is String ? _old['comment'] as String : '');
  late final _keys = TextEditingController(text: _strings(_old['keys']).join('，'));
  late final _secondary = TextEditingController(text: _strings(_old['secondary_keys']).join('，'));
  late final _content = TextEditingController(text: _old['content'] is String ? _old['content'] as String : '');
  late final _order = TextEditingController(text: '${_old['insertion_order'] is num ? _old['insertion_order'] : 100}');
  late bool _constant = _old['constant'] == true;
  late bool _enabled = _old['enabled'] != false;
  late bool _after = _old['position'] == 'after_char';
  late final _edits = Listenable.merge([_name, _keys, _secondary, _content, _order]);

  late final Map<String, Object?> _start = _fields();
  bool _saving = false;
  bool _leaving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _keys, _secondary, _content, _order]) {
      c.dispose();
    }
    super.dispose();
  }

  static List<String> _split(String text) => [
    for (final part in text.split(RegExp(r'[,，、\n]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  /// The entry as the form now has it, in the card's own field names.
  Map<String, Object?> _fields() {
    final secondary = _split(_secondary.text);
    return {
      'comment': _name.text.trim(),
      'keys': _split(_keys.text),
      'secondary_keys': secondary,
      'selective': secondary.isNotEmpty,
      'content': _content.text,
      'constant': _constant,
      'enabled': _enabled,
      'position': _after ? 'after_char' : 'before_char',
      'insertion_order': int.tryParse(_order.text.trim()) ?? 100,
    };
  }

  /// What changed since the page opened: only that is written.
  Map<String, Object?> _changes() {
    final now = _fields();
    return {
      for (final MapEntry(:key, :value) in now.entries)
        if ('$value' != '${_start[key]}') key: value,
    };
  }

  bool _dirty() => !_leaving && _changes().isNotEmpty;

  Future<void> _save() async {
    if (_saving) return;
    final navigator = Navigator.of(context);
    final tavern = ref.read(tavernProvider);
    final l10n = context.l10n;
    final changes = _changes();
    final entry = widget.entry;
    if (entry != null && changes.isEmpty) {
      _leaving = true;
      navigator.pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (entry == null) {
        await tavern.addCharacterBookEntry(widget.characterId, _fields());
      } else {
        await tavern.updateCharacterBookEntry(widget.characterId, entry.index, changes);
      }
      if (!mounted) return;
      ref.invalidate(tavernCardBookProvider(widget.characterId));
      _leaving = true;
      navigator.pop();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ArgumentError || e is TavernImportError ? '${l10n.commonSaveFailed}：$e' : l10n.commonSaveFailed;
        });
      }
    }
  }

  Future<void> _delete() async {
    final entry = widget.entry!;
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await confirmTavernDelete(
      context,
      title: l10n.tavernLorebookEntryDeleteTitle(_title(entry.entry)),
      message: l10n.tavernLorebookEntryDeleteMessage,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(tavernProvider).deleteCharacterBookEntry(widget.characterId, entry.index);
    } on Object {
      messenger?.showBriefNotice(l10n.commonSaveFailed);
      return;
    }
    if (!mounted) return;
    ref.invalidate(tavernCardBookProvider(widget.characterId));
    _leaving = true;
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = !_saving;
    TextField field(TextEditingController controller, {int? maxLines = 1, int? minLines, TextInputType? keyboard}) =>
        TextField(
          controller: controller,
          enabled: enabled,
          maxLines: maxLines,
          minLines: minLines,
          keyboardType: keyboard,
        );
    final body = <Widget>[
      SettingsSection(
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                key: const ValueKey('tavern-lore-name'),
                label: l10n.tavernLorebookFieldName,
                helper: l10n.tavernLorebookFieldNameHelp,
                child: field(_name),
              ),
              FormFieldBlock(
                key: const ValueKey('tavern-lore-keys'),
                label: l10n.tavernLorebookFieldKeys,
                helper: l10n.tavernLorebookFieldKeysHelp,
                child: field(_keys),
              ),
              FormFieldBlock(
                key: const ValueKey('tavern-lore-content'),
                label: l10n.tavernLorebookFieldContent,
                child: field(_content, maxLines: 16, minLines: 5, keyboard: TextInputType.multiline),
              ),
            ],
          ),
        ],
      ),
      SettingsSection(
        children: [
          SettingsSwitchTile(
            key: const ValueKey('tavern-lore-enabled'),
            title: l10n.tavernLorebookFieldEnabled,
            value: _enabled,
            onChanged: enabled ? (on) => setState(() => _enabled = on) : null,
          ),
          SettingsSwitchTile(
            key: const ValueKey('tavern-lore-constant'),
            title: l10n.tavernLorebookConstant,
            subtitle: l10n.tavernLorebookFieldConstantSubtitle,
            value: _constant,
            onChanged: enabled ? (on) => setState(() => _constant = on) : null,
          ),
          SettingsSegmentTile<bool>(
            key: const ValueKey('tavern-lore-position'),
            title: l10n.tavernLorebookFieldPosition,
            segments: [
              PillSegment(false, l10n.tavernLorebookBeforeChar),
              PillSegment(true, l10n.tavernLorebookAfterChar),
            ],
            selected: _after,
            onChanged: (after) => setState(() => _after = after),
          ),
        ],
      ),
      SettingsSection(
        children: [
          FormFieldGroup(
            children: [
              FormFieldBlock(
                key: const ValueKey('tavern-lore-secondary'),
                label: l10n.tavernLorebookFieldSecondary,
                helper: l10n.tavernLorebookFieldSecondaryHelp,
                child: field(_secondary),
              ),
              FormFieldBlock(
                key: const ValueKey('tavern-lore-order'),
                label: l10n.tavernLorebookFieldOrder,
                helper: l10n.tavernLorebookFieldOrderHelp,
                child: field(_order, keyboard: TextInputType.number),
              ),
            ],
          ),
        ],
      ),
      if (widget.entry != null)
        SettingsSection(
          children: [
            SettingsTile(
              key: const ValueKey('tavern-lore-delete'),
              icon: AppIcons.delete,
              danger: true,
              tinted: false,
              title: l10n.tavernLorebookEntryDelete,
              chevron: false,
              onTap: enabled ? () => unawaited(_delete()) : null,
            ),
          ],
        ),
      if (_error case final error?)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(
            error,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
          ),
        ),
      const SizedBox(height: FormBottomBar.height),
    ];
    return DiscardGuard(
      listenable: _edits,
      isDirty: _dirty,
      child: Stack(
        children: [
          AppPage.list(
            title: widget.entry == null ? l10n.tavernLorebookEntryNew : l10n.tavernLorebookEntryEdit,
            children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body)],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                key: const ValueKey('tavern-lore-save'),
                onPressed: enabled ? _save : null,
                child: Text(l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
