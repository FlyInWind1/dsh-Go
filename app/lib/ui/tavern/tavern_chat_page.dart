// One tavern chat (docs/design/roleplay-ui.md §2, §7): the current path of the
// tree, the reply as it streams, alternatives under the last reply (‹ 2/5 ›),
// and a long-press menu for the rest. Messages draw with the chat's own
// widgets for now; the canvas (WebView, ST's display pipeline) replaces the
// list once regex and HTML land (R2).

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../../tavern/tavern_preview.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_chat_kit.dart';
import '../chat/composer.dart';
import '../chat/render/markdown_body.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_character_page.dart';
import 'tavern_widgets.dart';

class TavernChatPage extends ConsumerStatefulWidget {
  const TavernChatPage({super.key, required this.chatId});

  final String chatId;

  static Route<void> route(String chatId) => MaterialPageRoute<void>(builder: (_) => TavernChatPage(chatId: chatId));

  @override
  ConsumerState<TavernChatPage> createState() => _TavernChatPageState();
}

class _TavernChatPageState extends ConsumerState<TavernChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);
  late final Tavern _tavern = ref.read(tavernProvider);
  StreamSubscription<void>? _changes;
  StreamSubscription<TavernEvent>? _turn;

  List<TavernMessage>? _messages;

  /// The reply being written: its node and the text so far.
  String? _streamNode;
  String _streamText = '';
  String? _error;

  bool get _running => _turn != null;

  @override
  void initState() {
    super.initState();
    _changes = _tavern.pathChanges(widget.chatId).listen((_) => unawaited(_reload()));
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    if (_running) _tavern.stop(widget.chatId);
    unawaited(_turn?.cancel());
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final messages = await _tavern.path(widget.chatId);
    if (mounted) setState(() => _messages = messages);
  }

  void _run(Stream<TavernEvent> turn, {String? draft}) {
    setState(() {
      _error = null;
      _streamNode = null;
      _streamText = '';
    });
    _turn = turn.listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case TavernTurnStarted(:final message):
            setState(() => _streamNode = message.nodeId);
            unawaited(_reload());
          case TavernTextDelta(:final nodeId, :final text):
            setState(() {
              _streamNode ??= nodeId;
              _streamText += text;
            });
          case TavernReasoningDelta():
            break;
          case TavernTurnDone():
            _finish();
          case TavernTurnFailed(:final kind, :final detail, :final partial):
            if (partial == null && draft != null && _input.text.isEmpty) _input.text = draft;
            _finish(error: kind == TavernFailure.cancelled ? null : _failureText(kind, detail));
        }
      },
      onDone: () {
        if (mounted && _running) _finish();
      },
    );
  }

  void _finish({String? error}) {
    unawaited(_turn?.cancel());
    setState(() {
      _turn = null;
      _streamNode = null;
      _streamText = '';
      _error = error;
    });
    unawaited(_reload());
  }

  String _failureText(TavernFailure kind, String? detail) {
    final l10n = context.l10n;
    return switch (kind) {
      TavernFailure.noKey => l10n.tavernErrorNoKey,
      TavernFailure.badKey => l10n.tavernErrorBadKey,
      TavernFailure.busy => l10n.tavernErrorBusy,
      TavernFailure.network => l10n.tavernErrorNetwork,
      TavernFailure.contextTooLong => l10n.tavernErrorTooLong,
      _ => detail == null ? l10n.commonFailedTryAgain : l10n.tavernErrorDetail(detail),
    };
  }

  void _send() {
    if (_running) return;
    final text = _input.text;
    _input.clear();
    _run(_tavern.send(widget.chatId, text), draft: text);
  }

  void _stop() => _tavern.stop(widget.chatId);

  Future<void> _sibling(TavernMessage message, int delta) async {
    if (_running) return;
    final index = message.siblingIndex + delta;
    if (index >= message.siblingCount) {
      _run(_tavern.regenerate(widget.chatId, message.nodeId));
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    await _tavern.selectSibling(widget.chatId, message.nodeId, index);
  }

  Future<void> _menu(TavernMessage message, {required bool last}) async {
    final l10n = context.l10n;
    final character = message.role == TavernRole.character;
    final action = await showAppSheet<_MessageAction>(
      context,
      builder: (sheet) {
        Widget row(_MessageAction action, IconData icon, String title, {bool danger = false}) => SettingsTile(
          key: ValueKey('tavern-menu-${action.name}'),
          icon: icon,
          tinted: false,
          danger: danger,
          title: title,
          onTap: () => Navigator.of(sheet).pop(action),
        );
        return SafeArea(
          top: false,
          child: SheetGroup(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            children: [
              row(_MessageAction.copy, AppIcons.copy, l10n.commonCopy),
              row(_MessageAction.edit, AppIcons.edit, l10n.commonEdit),
              if (character) row(_MessageAction.regenerate, AppIcons.regenerate, l10n.tavernRegenerate),
              if (character && last) row(_MessageAction.continueReply, AppIcons.forward, l10n.tavernContinueReply),
              row(_MessageAction.delete, AppIcons.delete, l10n.tavernDeleteFrom, danger: true),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
      case _MessageAction.edit:
        await _edit(message);
      case _MessageAction.regenerate:
        if (!_running) _run(_tavern.regenerate(widget.chatId, message.nodeId));
      case _MessageAction.continueReply:
        if (!_running) _run(_tavern.continueReply(widget.chatId, message.nodeId));
      case _MessageAction.delete:
        if (!_running) await _tavern.deleteFrom(widget.chatId, message.nodeId);
    }
  }

  Future<void> _edit(TavernMessage message) async {
    final l10n = context.l10n;
    final field = TextEditingController(text: message.text);
    final text = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.commonEdit),
        content: TextField(controller: field, maxLines: 10, minLines: 3, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(field.text), child: Text(l10n.commonSave)),
        ],
      ),
    );
    field.dispose();
    if (text != null && text != message.text) await _tavern.edit(widget.chatId, message.nodeId, text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final characterId = ref
        .watch(tavernChatsProvider(null))
        .value
        ?.where((c) => c.id == widget.chatId)
        .firstOrNull
        ?.characterId;
    final characters = ref.watch(tavernCharactersProvider).value;
    final character = characters?.where((c) => c.id == characterId).firstOrNull;
    final name = character?.name ?? l10n.tavernTitle;
    final preview = _tavern is TavernPreview;
    final messages = _messages;
    final (String status, StatusTone tone) = switch (()) {
      _ when _running => (l10n.tavernReplying, StatusTone.busy),
      _ when preview => (l10n.tavernPreviewStatus, StatusTone.warn),
      _ => (l10n.tavernReady, StatusTone.ok),
    };
    final topInset = BotChatHeader.heightOf(context);
    final lastCharacter = messages?.lastWhere((m) => m.role == TavernRole.character, orElse: () => _none).nodeId;

    final rows = <Widget>[
      for (final m in messages ?? const <TavernMessage>[])
        if (m.nodeId == _streamNode)
          _StreamingReply(key: ValueKey('stream-${m.nodeId}'), text: _streamText)
        else
          _MessageRow(
            key: ValueKey(m.nodeId),
            message: m,
            last: m.nodeId == lastCharacter,
            busy: _running,
            onMenu: () => unawaited(_menu(m, last: m.nodeId == lastCharacter)),
            onSibling: (delta) => unawaited(_sibling(m, delta)),
          ),
      if (_running && (_streamNode == null || !(messages?.any((m) => m.nodeId == _streamNode) ?? false)))
        _StreamingReply(key: const ValueKey('stream-pending'), text: _streamText),
    ];

    return BotChatFrame(
      header: BotChatHeader(
        face: ClipOval(
          child: TavernPortrait(name: name, path: character?.avatarPath, radius: 0, initialSize: 16),
        ),
        title: name,
        status: status,
        tone: tone,
        scrolledUnder: _scrolled,
        onDetails: () {
          if (characterId != null) unawaited(Navigator.of(context).push(TavernCharacterPage.route(characterId)));
        },
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical) {
            _scrolled.value = ((n.metrics.maxScrollExtent - n.metrics.pixels) / 24).clamp(0.0, 1.0);
          }
          return false;
        },
        child: ListView(
          key: const ValueKey('tavern-transcript'),
          reverse: true,
          padding: EdgeInsets.fromLTRB(16, 12, 16, topInset + 8),
          children: [
            for (final row in rows.reversed) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: row),
          ],
        ),
      ),
      bottom: [
        BotErrorSlot(error: _error, onDismiss: () => setState(() => _error = null)),
        Composer(
          hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
          controller: _input,
          focusNode: _focus,
          connected: messages != null,
          running: _running,
          onSend: _send,
          onStop: _stop,
          placeholder: l10n.tavernComposerHint(name),
        ),
      ],
    );
  }
}

final _none = TavernMessage(nodeId: '', role: TavernRole.system, speaker: '', text: '', at: DateTime(0));

enum _MessageAction { copy, edit, regenerate, continueReply, delete }

/// A message on the path: the user's in a bubble, the character's as text;
/// the last character message carries its alternatives.
class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.message,
    required this.last,
    required this.busy,
    required this.onMenu,
    required this.onSibling,
  });

  final TavernMessage message;
  final bool last;
  final bool busy;
  final VoidCallback onMenu;
  final ValueChanged<int> onSibling;

  @override
  Widget build(BuildContext context) {
    if (message.role == TavernRole.user) {
      return GestureDetector(
        onLongPress: onMenu,
        child: BotUserMessage(text: message.text),
      );
    }
    final alternatives = last || message.siblingCount > 1;
    return GestureDetector(
      onLongPress: onMenu,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(text: message.text, selectable: false),
          if (alternatives) ...[
            const SizedBox(height: 4),
            _Alternatives(message: message, last: last, busy: busy, onSibling: onSibling),
          ],
        ],
      ),
    );
  }
}

/// ‹ 2/5 ›: the previous and next alternative; past the last one (on the last
/// reply) › writes a new one.
class _Alternatives extends StatelessWidget {
  const _Alternatives({required this.message, required this.last, required this.busy, required this.onSibling});

  final TavernMessage message;
  final bool last;
  final bool busy;
  final ValueChanged<int> onSibling;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final style = AppType.tabular(Theme.of(context).textTheme.labelSmall!.copyWith(color: dsh.textTertiary));
    final atEnd = message.siblingIndex >= message.siblingCount - 1;
    final canNext = !atEnd || last;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('tavern-prev'),
          tooltip: l10n.tavernPrevious,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: dsh.textTertiary,
          onPressed: busy || message.siblingIndex == 0 ? null : () => onSibling(-1),
          icon: Icon(AppIcons.keyLeft),
        ),
        Text('${message.siblingIndex + 1}/${message.siblingCount}', style: style),
        IconButton(
          key: const ValueKey('tavern-next'),
          tooltip: atEnd ? l10n.tavernRegenerate : l10n.tavernNext,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: dsh.textTertiary,
          onPressed: busy || !canNext ? null : () => onSibling(1),
          icon: Icon(atEnd ? AppIcons.regenerate : AppIcons.keyRight),
        ),
      ],
    );
  }
}

class _StreamingReply extends StatelessWidget {
  const _StreamingReply({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => text.isEmpty
      ? const Align(alignment: Alignment.centerLeft, child: TypingIndicator())
      : MarkdownBody(text: text, streaming: true, selectable: false);
}
