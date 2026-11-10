// One tavern chat (docs/design/roleplay-ui.md §2, §7): the current path of the
// tree, the reply as it streams, alternatives under the last reply (‹ 2/5 ›),
// and a long-press menu for the rest. Messages draw with the chat's own
// widgets for now; the canvas (WebView, ST's display pipeline) replaces the
// list once regex and HTML land (R2).

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../../tavern/tavern_backgrounds.dart';
import '../../tavern/tavern_live2d.dart';
import '../../tavern/tavern_preview.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_quick_replies.dart';
import '../../tavern/tavern_settings.dart';
import '../bots/bot_chat_kit.dart';
import '../chat/composer.dart';
import '../chat/render/markdown_body.dart';
import '../chat/voice/voice_controller.dart';
import '../chat/widgets/notice_row.dart';
import '../chat/widgets/thinking_pill.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/capsule_chip.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../companion/companion_stage.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../onboarding/api_key_page.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../wallpaper/wallpaper_backdrop.dart';
import 'tavern_character_page.dart';
import 'tavern_chat_files.dart';
import 'tavern_dice_sheet.dart';
import 'tavern_ink.dart';
import 'tavern_inspector_page.dart';
import 'tavern_message_edit_page.dart';
import 'tavern_personas.dart';
import 'tavern_reading.dart';
import 'tavern_stage_panel.dart';
import 'tavern_storybook_page.dart';
import 'tavern_vn_view.dart';
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

  /// Scrolled back into the story, away from the newest lines: the chips over
  /// the box fold away for the reading (back when typing).
  final _readingBack = ValueNotifier(false);

  /// The frame's Scaffold: 舞台 slides in from its right edge.
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Wide enough for 舞台 to stand beside the story instead of sliding in.
  static const _stageBesideFrom = 900.0;
  static const _stageWidth = 340.0;

  /// The character's Live2D model in the visual novel, when she has one; set
  /// once it can't be shown, and the card's picture stands in.
  final _stage = CompanionStageController();
  bool _stageFailed = false;

  /// The page the stage last played, played again when it (re)loads.
  TavernPage? _staged;
  late final Tavern _tavern = ref.read(tavernProvider);
  StreamSubscription<void>? _changes;
  StreamSubscription<TavernEvent>? _turn;

  List<TavernMessage>? _messages;

  /// The reply being written: its node, and the text so far. Only the reply
  /// listens to the text: a piece arriving rebuilds it, not the page and every
  /// message on it.
  String? _streamNode;
  final _stream = ValueNotifier<_Streamed>(_nothing);
  String? _error;

  /// The error's button: 「重试」 when trying again can help, 「设置」 when
  /// the key is missing or refused.
  ({String label, VoidCallback onPressed})? _action;

  bool get _running => _turn != null;

  /// Dictation into the box (§6), the main chat's: the system's recognizer,
  /// or the engine's voice model where the on-device host has it.
  late final VoiceInputController _voice;
  late final VoiceInputActiveController _voiceFlag;

  /// The host's connection, only if the app already has one: a chat page
  /// never starts connecting just to offer dictation.
  HostConnection? get _connection =>
      mounted && ref.exists(activeConnectionProvider) ? ref.read(activeConnectionProvider).value : null;

  void _reportVoice() => _voiceFlag.set(_voice.active);

  @override
  void initState() {
    super.initState();
    _changes = _tavern.pathChanges(widget.chatId).listen((_) => unawaited(_reload()));
    unawaited(_reload());
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () => ref.read(voiceSettingsProvider.notifier).ready(),
      // The voice model lives in the on-device engine: it counts for that host only.
      modelReady: () =>
          (_connection?.isLocal ?? false) && ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      client: () => _connection?.client,
    );
    _voiceFlag = ref.read(voiceInputActiveProvider.notifier);
    _voice.addListener(_reportVoice);
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    if (_running) _tavern.stop(widget.chatId);
    unawaited(_turn?.cancel());
    _stream.dispose();
    _voice.removeListener(_reportVoice);
    _voice.dispose();
    // The page is gone, and its dictation with it.
    final flag = _voiceFlag;
    scheduleMicrotask(() => flag.set(false));
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    _readingBack.dispose();
    super.dispose();
  }

  /// Messages per page when scrolling back.
  static const _page = 60;

  /// How many of the latest messages are loaded; grows a page at a time as
  /// you scroll back, and every reload keeps it.
  int _window = _page;

  /// A full window came back: there may be older ones.
  bool _hasOlder = false;
  bool _loadingOlder = false;

  Future<void> _reload() async {
    final window = _window;
    final messages = await _tavern.path(widget.chatId, limit: window);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _hasOlder = messages.length >= window;
    });
  }

  /// Near the oldest loaded message: load another page before it.
  Future<void> _loadOlder() async {
    if (!_hasOlder || _loadingOlder) return;
    setState(() {
      _loadingOlder = true;
      _window += _page;
    });
    await _reload();
    if (mounted) setState(() => _loadingOlder = false);
  }

  void _run(Stream<TavernEvent> Function() start, {String? draft}) {
    setState(() {
      _error = null;
      _action = null;
      _streamNode = null;
    });
    _stream.value = _nothing;
    _turn = start().listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case TavernTurnStarted(:final message):
            setState(() => _streamNode = message.nodeId);
            unawaited(_reload());
          case TavernTextDelta(:final nodeId, :final text):
            _adopt(nodeId);
            _stream.value = (text: _stream.value.text + text, reasoning: _stream.value.reasoning);
          case TavernReasoningDelta(:final nodeId, :final text):
            _adopt(nodeId);
            _stream.value = (text: _stream.value.text, reasoning: _stream.value.reasoning + text);
          case TavernTurnDone():
            _finish();
          case TavernTurnFailed(:final kind, :final detail, :final partial):
            if (partial == null && draft != null && _input.text.isEmpty) _input.text = draft;
            if (kind == TavernFailure.cancelled) return _finish();
            final l10n = context.l10n;
            _finish(
              error: _failureText(kind, detail),
              action: switch (kind) {
                // Trying again cannot help until the key is there.
                TavernFailure.noKey ||
                TavernFailure.badKey => (label: l10n.commonSettings, onPressed: _openKeySettings),
                // Nothing stored: the line is back in the composer, send it
                // again. Half a reply: write that reply again.
                _ => (
                  label: l10n.commonRetry,
                  onPressed: switch (partial) {
                    null when draft != null => _send,
                    final p? => () => _run(() => _tavern.regenerate(widget.chatId, p.nodeId)),
                    null => () => _run(start),
                  },
                ),
              },
            );
        }
      },
      onDone: () {
        if (mounted && _running) _finish();
      },
    );
  }

  /// The reply's node, once known: the page places the reply by it.
  void _adopt(String nodeId) {
    if (_streamNode == null) setState(() => _streamNode = nodeId);
  }

  void _finish({String? error, ({String label, VoidCallback onPressed})? action}) {
    unawaited(_turn?.cancel());
    setState(() {
      _turn = null;
      _streamNode = null;
      _error = error;
      _action = action;
    });
    _stream.value = _nothing;
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
    _run(() => _tavern.send(widget.chatId, text), draft: text);
  }

  void _stop() => _tavern.stop(widget.chatId);

  /// A quick reply sends as it is; on failure it waits in the box.
  void _sendQuick(String text) {
    if (_running) return;
    unawaited(HapticFeedback.selectionClick());
    _run(() => _tavern.send(widget.chatId, text), draft: text);
  }

  /// Long-press: the quick reply goes into the box to change first.
  void _editQuick(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// 接着写: the newest reply goes on from where it stopped.
  void _continueLast() {
    final last = _messages?.lastOrNull;
    if (_running || last == null || last.role != TavernRole.character) return;
    unawaited(HapticFeedback.selectionClick());
    _run(() => _tavern.continueReply(widget.chatId, last.nodeId));
  }

  /// 掷骰: what came up joins whatever is in the box, on a line of its own.
  Future<void> _dice() async {
    final line = await showTavernDice(context);
    if (line == null || !mounted) return;
    final before = _input.text.trimRight();
    final text = before.isEmpty ? line : '$before\n$line';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  /// 帮我写: the model writes your next line into the composer. Nothing is
  /// sent or stored; edit it, then send. Stop keeps what has arrived.
  void _impersonate() {
    if (_running) return;
    unawaited(HapticFeedback.selectionClick());
    _setDraft('');
    setState(() {
      _error = null;
      _action = null;
    });
    _turn = _tavern
        .impersonate(widget.chatId)
        .listen(
          (event) {
            if (!mounted) return;
            switch (event) {
              case TavernTextDelta(:final text):
                _setDraft(_input.text + text);
              case TavernTurnDone(:final message):
                _setDraft(message.text);
                _endDraft();
              case TavernTurnFailed(:final kind, :final detail):
                if (kind == TavernFailure.cancelled) return _endDraft();
                _endDraft(failure: (kind, detail));
              case TavernTurnStarted() || TavernReasoningDelta():
                break;
            }
          },
          onDone: () {
            if (mounted && _running) _endDraft();
          },
        );
    setState(() {});
  }

  void _setDraft(String text) => _input.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

  void _endDraft({(TavernFailure, String?)? failure}) {
    unawaited(_turn?.cancel());
    final l10n = context.l10n;
    setState(() {
      _turn = null;
      _error = switch (failure) {
        (final kind, final detail)? => _failureText(kind, detail),
        null => null,
      };
      _action = switch (failure?.$1) {
        null => null,
        TavernFailure.noKey || TavernFailure.badKey => (label: l10n.commonSettings, onPressed: _openKeySettings),
        _ => (label: l10n.commonRetry, onPressed: _impersonate),
      };
    });
    if (failure == null) _focus.requestFocus();
  }

  /// Where the DeepSeek key is set (as 酒馆设置 opens it); the line waits in
  /// the composer.
  void _openKeySettings() => unawaited(
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ApiKeyPage(onboarding: false))),
  );

  Future<void> _sibling(TavernMessage message, int delta) async {
    if (_running) return;
    final index = message.siblingIndex + delta;
    if (index >= message.siblingCount) {
      _run(() => _tavern.regenerate(widget.chatId, message.nodeId));
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    final messages = _messages ?? const <TavernMessage>[];
    final later = messages.indexWhere((m) => m.nodeId == message.nodeId) < messages.length - 1;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await _tavern.selectSibling(widget.chatId, message.nodeId, index);
    // An earlier message: everything after it is now another branch's.
    if (!later || !mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.tavernSwitchedBranch),
        action: SnackBarAction(
          label: l10n.tavernUndo,
          onPressed: () => unawaited(_tavern.selectSibling(widget.chatId, message.nodeId, message.siblingIndex)),
        ),
      ),
    );
  }

  /// The title's sheet: the character's page, and this chat's own layout.
  Future<void> _quickLook(String? characterId, String name) => showAppSheet<void>(
    context,
    builder: (sheet) => Consumer(
      builder: (context, ref, _) {
        final l10n = context.l10n;
        final own = ref.watch(tavernChatLayoutProvider(widget.chatId));
        final controller = ref.read(tavernChatLayoutProvider(widget.chatId).notifier);
        final scene = ref.watch(tavernChatBackgroundProvider(widget.chatId));
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(name),
                if (characterId != null)
                  SheetGroup(
                    margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                    children: [
                      SettingsTile(
                        key: const ValueKey('tavern-character-details'),
                        icon: AppIcons.info,
                        tinted: false,
                        title: l10n.tavernCharacterDetails,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          unawaited(Navigator.of(this.context).push(TavernCharacterPage.route(characterId)));
                        },
                      ),
                    ],
                  ),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsTile(
                      key: const ValueKey('tavern-chat-persona'),
                      icon: AppIcons.profile,
                      tinted: false,
                      title: l10n.tavernPersona,
                      value: Text(
                        ref.watch(tavernPersonaSelectionProvider(widget.chatId)).value?.persona?.name ??
                            l10n.tavernPersonaNone,
                      ),
                      onTap: _running
                          ? null
                          : () {
                              Navigator.of(sheet).pop();
                              unawaited(showTavernPersonaPicker(this.context, widget.chatId));
                            },
                    ),
                    SettingsTile(
                      key: const ValueKey('tavern-chat-inspect'),
                      icon: AppIcons.code,
                      tinted: false,
                      title: l10n.tavernInspectLatest,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(Navigator.of(this.context).push(TavernInspectorPage.route(widget.chatId)));
                      },
                    ),
                    SettingsTile(
                      key: const ValueKey('tavern-chat-export'),
                      icon: AppIcons.share,
                      tinted: false,
                      title: l10n.tavernExportChat,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(exportTavernChat(this.context, ref, widget.chatId, title: name));
                      },
                    ),
                    SettingsTile(
                      key: const ValueKey('tavern-chat-storybook'),
                      icon: AppIcons.bookmark,
                      tinted: false,
                      title: l10n.tavernStorybookMenu,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        final avatar = ref
                            .read(tavernCharactersProvider)
                            .value
                            ?.where((c) => c.id == characterId)
                            .firstOrNull
                            ?.avatarPath;
                        unawaited(
                          Navigator.of(
                            this.context,
                          ).push(TavernStorybookPage.route(chatId: widget.chatId, character: name, avatarPath: avatar)),
                        );
                      },
                    ),
                  ],
                ),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    SettingsSegmentTile<TavernLayout>(
                      key: const ValueKey('tavern-chat-layout'),
                      title: l10n.tavernChatLayout,
                      tinted: false,
                      segments: [
                        PillSegment(TavernLayout.bubble, l10n.tavernLayoutBubble),
                        PillSegment(TavernLayout.novel, l10n.tavernLayoutNovel),
                        PillSegment(TavernLayout.visualNovel, l10n.tavernLayoutVisualNovel),
                      ],
                      selected: own ?? ref.watch(tavernSettingsProvider.select((s) => s.layout)),
                      onChanged: (layout) => unawaited(controller.set(layout)),
                    ),
                    if (own != null)
                      SettingsTile(
                        key: const ValueKey('tavern-chat-layout-follow'),
                        icon: AppIcons.restart,
                        tinted: false,
                        title: l10n.tavernFollowSettings,
                        onTap: () => unawaited(controller.set(null)),
                      ),
                    SettingsTile(
                      key: const ValueKey('tavern-chat-background'),
                      icon: AppIcons.addImage,
                      tinted: false,
                      title: l10n.tavernBackground,
                      value: Text(scene == null ? l10n.tavernBackgroundNone : l10n.tavernBackgroundChange),
                      onTap: () => unawaited(_chooseBackground()),
                    ),
                    if (scene != null)
                      SettingsTile(
                        key: const ValueKey('tavern-chat-background-remove'),
                        icon: AppIcons.remove,
                        tinted: false,
                        title: l10n.tavernBackgroundRemove,
                        chevron: false,
                        onTap: () => unawaited(ref.read(tavernChatBackgroundProvider(widget.chatId).notifier).remove()),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        );
      },
    ),
  );

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
        // Up to seven rows: scrolls on a short screen instead of overflowing.
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: SheetGroup(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              children: [
                row(_MessageAction.copy, AppIcons.copy, l10n.commonCopy),
                row(_MessageAction.edit, AppIcons.edit, l10n.commonEdit),
                if (character) row(_MessageAction.regenerate, AppIcons.regenerate, l10n.tavernRegenerate),
                if (character && last)
                  row(_MessageAction.continueReply, AppIcons.continueReply, l10n.tavernContinueReply),
                if (character) row(_MessageAction.inspect, AppIcons.code, l10n.tavernInspectMenu),
                if (message.hidden)
                  row(_MessageAction.hide, AppIcons.showSecret, l10n.tavernUnhide)
                else
                  row(_MessageAction.hide, AppIcons.hideSecret, l10n.tavernHide),
                row(_MessageAction.delete, AppIcons.delete, l10n.tavernDeleteFrom, danger: true),
              ],
            ),
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
        if (!_running) _run(() => _tavern.regenerate(widget.chatId, message.nodeId));
      case _MessageAction.continueReply:
        if (!_running) _run(() => _tavern.continueReply(widget.chatId, message.nodeId));
      case _MessageAction.inspect:
        await Navigator.of(context).push(TavernInspectorPage.route(widget.chatId, nodeId: message.nodeId));
      case _MessageAction.hide:
        if (!_running) await _tavern.setHidden(widget.chatId, message.nodeId, !message.hidden);
      case _MessageAction.delete:
        if (!_running) await _tavern.deleteFrom(widget.chatId, message.nodeId);
    }
  }

  /// The stage plays [page]: thinking while a reply starts, then the cues.
  void _cue(TavernPage page) {
    _staged = page;
    if (page.streaming) {
      _stage.command('mood', {'mood': 'thinking'});
      return;
    }
    for (final (type, args) in tavernStageCues(you: page.message.role == TavernRole.user, text: page.text)) {
      _stage.command(type, args);
    }
  }

  late final _stageEvents = CompanionStageEvents(
    onReady: () {
      if (_staged case final page?) _cue(page);
    },
    onFailed: (why) {
      debugPrint('tavern: Live2D stage failed: $why');
      if (mounted) setState(() => _stageFailed = true);
    },
    onTouch: (_, _) {},
    onWake: () {},
    onMood: (_) {},
    onObject: (_) {},
    onActivity: (_) {},
  );

  /// A picture from the gallery under this chat; says so when one can't be used.
  Future<void> _chooseBackground() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final problem = await ref.read(tavernChatBackgroundProvider(widget.chatId).notifier).choose();
    final text = switch (problem) {
      null || LaunchImportProblem.cancelled => null,
      LaunchImportProblem.unavailable => l10n.wallpaperUnavailable,
      LaunchImportProblem.tooLarge || LaunchImportProblem.overLimit => l10n.wallpaperTooLarge,
      LaunchImportProblem.unsupported => l10n.wallpaperUnsupported,
      LaunchImportProblem.unreadable => l10n.wallpaperUnreadable,
    };
    if (text != null) messenger?.showBriefNotice(text);
  }

  /// A whole page for the message (long replies need room); saves only a change.
  Future<void> _edit(TavernMessage message) async {
    final speaker = message.role == TavernRole.user ? context.l10n.tavernYou : message.speaker;
    final text = await Navigator.of(context).push(TavernMessageEditPage.route(speaker: speaker, text: message.text));
    if (text != null && text != message.text && mounted) await _tavern.edit(widget.chatId, message.nodeId, text);
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
    final layout =
        ref.watch(tavernChatLayoutProvider(widget.chatId)) ?? ref.watch(tavernSettingsProvider.select((s) => s.layout));
    final novel = layout == TavernLayout.novel;
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
          _StreamingReply(key: ValueKey('stream-${m.nodeId}'), stream: _stream)
        else
          _MessageRow(
            key: ValueKey(m.nodeId),
            message: m,
            last: m.nodeId == lastCharacter,
            busy: _running,
            onMenu: () => unawaited(_menu(m, last: m.nodeId == lastCharacter)),
            onSibling: (delta) => unawaited(_sibling(m, delta)),
            novel: novel,
            lead: name,
          ),
      if (_running && (_streamNode == null || !(messages?.any((m) => m.nodeId == _streamNode) ?? false)))
        _StreamingReply(key: const ValueKey('stream-pending'), stream: _stream),
    ];

    // Read here, not in the 视觉小说 builder below, which reruns on every
    // piece of the reply.
    final live2d = layout != TavernLayout.visualNovel || characterId == null || _stageFailed
        ? null
        : ref.watch(tavernLive2dProvider(characterId)).value;
    final revealRate = ref.watch(tavernSettingsProvider.select((s) => s.textSpeed.charactersPerSecond));

    final scene = ref.watch(tavernChatBackgroundProvider(widget.chatId));
    final beside = MediaQuery.sizeOf(context).width >= _stageBesideFrom;
    TavernStagePanel stage({double topInset = 0}) =>
        TavernStagePanel(chatId: widget.chatId, turn: messages?.lastOrNull?.nodeId, topInset: topInset);
    return BotChatFrame(
      // The chat's picture, when it has one; the page's gradient otherwise.
      backdrop: (child) => WallpaperBackdrop.scene(picture: scene, child: child),
      scaffoldKey: _scaffold,
      endDrawer: beside
          ? null
          : Drawer(
              key: const ValueKey('tavern-stage-drawer'),
              width: (MediaQuery.sizeOf(context).width * 0.88).clamp(0, 380),
              backgroundColor: Colors.transparent,
              child: AppBackdrop(glow: false, child: SafeArea(child: stage())),
            ),
      header: BotChatHeader(
        face: ClipOval(
          child: TavernPortrait(name: name, path: character?.avatarPath, radius: 0, initialSize: 16),
        ),
        title: name,
        status: status,
        tone: tone,
        scrolledUnder: _scrolled,
        onDetails: () => unawaited(_quickLook(characterId, name)),
        // 舞台 in place of ⓘ (the title opens the quick look); beside the story
        // on a wide screen, it needs no key.
        action: beside ? null : (AppIcons.sidebar, l10n.tavernStage, () => _scaffold.currentState?.openEndDrawer()),
      ),
      // The story under 酒馆设置's text size and spacing.
      body: _beside(
        beside ? stage(topInset: topInset) : null,
        TavernReading(
          child: layout == TavernLayout.visualNovel
              ? ValueListenableBuilder(
                  valueListenable: _stream,
                  builder: (context, streamed, _) => TavernVisualNovelView(
                    pages: [
                      ...tavernPages(messages ?? const [], streamNode: _streamNode, streamText: streamed.text),
                      if (_running &&
                          streamed.text.isNotEmpty &&
                          !(messages?.any((m) => m.nodeId == _streamNode) ?? false))
                        TavernPage(
                          TavernMessage(
                            nodeId: _streamNode ?? '',
                            role: TavernRole.character,
                            speaker: name,
                            text: '',
                            at: DateTime(0),
                          ),
                          streamed.text,
                          streaming: true,
                        ),
                    ],
                    name: name,
                    avatarPath: character?.avatarPath,
                    stage: switch (live2d) {
                      final store? => CompanionStage(
                        key: ValueKey(store.root.path),
                        store: store,
                        controller: _stage,
                        events: _stageEvents,
                        bare: true,
                      ),
                      null => null,
                    },
                    onPage: _cue,
                    revealRate: revealRate,
                    topInset: topInset,
                    onMenu: (m) => unawaited(_menu(m, last: m.nodeId == lastCharacter)),
                    footer: (m, lastPage) =>
                        lastPage && m.role == TavernRole.character && (m.nodeId == lastCharacter || m.siblingCount > 1)
                        ? _Alternatives(
                            message: m,
                            last: m.nodeId == lastCharacter,
                            busy: _running,
                            onSibling: (d) => unawaited(_sibling(m, d)),
                          )
                        : null,
                  ),
                )
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.axis == Axis.vertical) {
                      _scrolled.value = ((n.metrics.maxScrollExtent - n.metrics.pixels) / 24).clamp(0.0, 1.0);
                      _readingBack.value = n.metrics.pixels > 240;
                      // The list runs newest first: what is left above is older.
                      if (n.metrics.extentAfter < 600) unawaited(_loadOlder());
                    }
                    return false;
                  },
                  child: ListView(
                    key: const ValueKey('tavern-transcript'),
                    reverse: true,
                    padding: EdgeInsets.fromLTRB(16, 12, 16, topInset + 8),
                    children: [
                      // Keyed by message: a new one below keeps each row's
                      // state with its message, not with its place.
                      for (final row in rows.reversed)
                        Padding(key: row.key, padding: const EdgeInsets.symmetric(vertical: 6), child: row),
                      if (_hasOlder)
                        const Padding(
                          key: ValueKey('tavern-older'),
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(child: QuietSpinner()),
                        ),
                    ],
                  ),
                ),
        ),
      ),
      bottom: [
        _ErrorSlot(
          error: _error,
          action: _action,
          onDismiss: () => setState(() {
            _error = null;
            _action = null;
          }),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_readingBack, _focus]),
          builder: (context, _) => Composer(
            hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
            controller: _input,
            focusNode: _focus,
            connected: messages != null,
            running: _running,
            onSend: _send,
            onStop: _stop,
            voice: _voice,
            placeholder: l10n.tavernComposerHint(name),
            leading: TavernPersonaKey(chatId: widget.chatId, enabled: !_running),
            tray: !_running && messages != null && (!_readingBack.value || _focus.hasFocus)
                ? _QuickReplyRow(
                    replies: ref.watch(tavernQuickRepliesProvider),
                    onSend: _sendQuick,
                    onEdit: _editQuick,
                    onDice: () => unawaited(_dice()),
                  )
                : null,
            // While the box is empty: 帮我写 (an idea to start from) and, after
            // a reply, 接着写 (it goes on).
            accessory: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (context, value, _) {
                if (value.text.isNotEmpty || _running || messages == null) return const SizedBox.shrink();
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ComposerKey(
                      key: const ValueKey('tavern-write-for-me'),
                      icon: AppIcons.write,
                      label: l10n.tavernWriteForMe,
                      onPressed: _impersonate,
                    ),
                    if (messages.lastOrNull?.role == TavernRole.character)
                      _ComposerKey(
                        key: const ValueKey('tavern-continue'),
                        icon: AppIcons.continueReply,
                        label: l10n.tavernContinueReply,
                        onPressed: _continueLast,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

final _none = TavernMessage(nodeId: '', role: TavernRole.system, speaker: '', text: '', at: DateTime(0));

/// A quiet round key beside the composer's send key, the size of its others.
class _ComposerKey extends StatelessWidget {
  const _ComposerKey({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: SizedBox.square(
            dimension: 40,
            child: Icon(icon, size: 20, color: scheme.onSurface.withValues(alpha: 0.7)),
          ),
        ),
      ),
    );
  }
}

enum _MessageAction { copy, edit, regenerate, continueReply, inspect, hide, delete }

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
    this.novel = false,
    this.lead = '',
  });

  final TavernMessage message;
  final bool last;
  final bool busy;
  final VoidCallback onMenu;
  final ValueChanged<int> onSibling;

  /// 小说 layout: every message full width under its speaker's name.
  final bool novel;

  /// The chat's own character: their name in the accent, others' in their own colours.
  final String lead;

  @override
  Widget build(BuildContext context) {
    final drawn = novel ? _novel(context) : _bubble(context);
    // A reply with alternatives swipes sideways through them, like ‹ ›.
    final swipes = message.role == TavernRole.character && !busy && (last || message.siblingCount > 1);
    final body = swipes
        ? _SwipeToSwitch(
            key: ValueKey('tavern-swipe-${message.nodeId}'),
            canPrevious: message.siblingIndex > 0,
            canNext: message.siblingIndex + 1 < message.siblingCount || last,
            onSwitch: onSibling,
            child: drawn,
          )
        : drawn;
    if (!message.hidden) return body;
    // Hidden from the model: still here for you, faded, and says so.
    final end = !novel && message.role == TavernRole.user;
    return Column(
      crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Opacity(opacity: 0.45, child: body),
        const SizedBox(height: 4),
        _HiddenTag(key: ValueKey('tavern-hidden-${message.nodeId}')),
      ],
    );
  }

  Widget _bubble(BuildContext context) {
    if (message.role == TavernRole.user) {
      return GestureDetector(
        onLongPress: onMenu,
        child: _YourLine(text: message.text),
      );
    }
    final alternatives = last || message.siblingCount > 1;
    // Only the newest reply carries ‹ ›; an older one with others shows how
    // many it has, and swipes like the newest.
    return GestureDetector(
      onLongPress: onMenu,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.reasoning case final reasoning? when reasoning.isNotEmpty) ThinkingPill(reasoning: reasoning),
          MarkdownBody(text: message.text, selectable: false),
          if (alternatives) ...[
            const SizedBox(height: 4),
            if (last)
              _Alternatives(message: message, last: last, busy: busy, onSibling: onSibling)
            else
              _AlternativesCount(message: message),
          ],
        ],
      ),
    );
  }

  Widget _novel(BuildContext context) {
    final theme = Theme.of(context);
    final user = message.role == TavernRole.user;
    final alternatives = !user && (last || message.siblingCount > 1);
    return GestureDetector(
      onLongPress: onMenu,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            user ? context.l10n.tavernYou : message.speaker,
            style: theme.textTheme.labelMedium?.copyWith(
              color: user ? DshColors.of(context).textTertiary : tavernNameColor(context, message.speaker, lead: lead),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (message.reasoning case final reasoning? when reasoning.isNotEmpty) ThinkingPill(reasoning: reasoning),
          Opacity(
            opacity: user ? 0.78 : 1,
            child: MarkdownBody(text: message.text, selectable: false),
          ),
          if (alternatives) ...[
            const SizedBox(height: 4),
            if (last)
              _Alternatives(message: message, last: last, busy: busy, onSibling: onSibling)
            else
              _AlternativesCount(message: message),
          ],
        ],
      ),
    );
  }
}

/// The capsules above the composer (§6): 快速回复 (tap sends, long-press puts
/// it in the box), then 掷骰.
class _QuickReplyRow extends StatelessWidget {
  const _QuickReplyRow({required this.replies, required this.onSend, required this.onEdit, required this.onDice});

  final List<String> replies;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onEdit;
  final VoidCallback onDice;

  /// The first line, kept short enough for a capsule.
  static String _label(String reply) {
    final line = reply.trim().split('\n').first;
    return line.characters.length > 16 ? '${line.characters.take(16)}…' : line;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SizedBox(
      height: 36,
      child: ListView.separated(
        key: const ValueKey('tavern-quick-replies'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: replies.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => i == replies.length
            ? CapsuleChoiceChip(
                key: const ValueKey('tavern-dice'),
                label: context.l10n.tavernDice,
                selected: false,
                onSelected: onDice,
              )
            : GestureDetector(
                key: ValueKey('tavern-qr-$i'),
                onLongPress: () => onEdit(replies[i]),
                child: CapsuleChoiceChip(
                  label: _label(replies[i]),
                  selected: false,
                  onSelected: () => onSend(replies[i]),
                ),
              ),
      ),
    ),
  );
}

/// Swiping a reply sideways steps through its alternatives: left for the next
/// (past the last on the newest reply, a new one, as › does), right for the
/// previous. The reply follows the finger a little and springs back.
class _SwipeToSwitch extends StatefulWidget {
  const _SwipeToSwitch({
    super.key,
    required this.canPrevious,
    required this.canNext,
    required this.onSwitch,
    required this.child,
  });

  final bool canPrevious;
  final bool canNext;
  final ValueChanged<int> onSwitch;
  final Widget child;

  @override
  State<_SwipeToSwitch> createState() => _SwipeToSwitchState();
}

class _SwipeToSwitchState extends State<_SwipeToSwitch> {
  static const _distance = 64.0;
  static const _flick = 600.0;

  double _dx = 0;
  bool _dragging = false;

  void _update(DragUpdateDetails d) {
    final next = _dx + d.delta.dx;
    setState(() {
      _dragging = true;
      _dx = next.clamp(widget.canNext ? -160.0 : 0.0, widget.canPrevious ? 160.0 : 0.0);
    });
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (widget.canNext && (_dx <= -_distance || v <= -_flick)) {
      widget.onSwitch(1);
    } else if (widget.canPrevious && (_dx >= _distance || v >= _flick)) {
      widget.onSwitch(-1);
    }
    setState(() {
      _dragging = false;
      _dx = 0;
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragUpdate: _update,
    onHorizontalDragEnd: _end,
    onHorizontalDragCancel: () => setState(() {
      _dragging = false;
      _dx = 0;
    }),
    child: AnimatedContainer(
      duration: _dragging ? Duration.zero : AppMotion.of(context, AppMotion.standard),
      curve: AppMotion.std,
      // Half the finger's travel: it gives, but stays readable.
      transform: Matrix4.translationValues(_dx / 2, 0, 0),
      child: widget.child,
    ),
  );
}

/// 「模型看不到这条」 under a hidden message.
class _HiddenTag extends StatelessWidget {
  const _HiddenTag({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = DshColors.of(context).textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.hideSecret, size: 14, color: color),
        const SizedBox(width: 4),
        Text(context.l10n.tavernHiddenFromModel, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// ‹ 2/5 ›: the previous and next alternative; past the last one (on the last
/// reply) › writes a new one.
/// The story, with 舞台 at its right when there is room for both.
Widget _beside(Widget? stage, Widget story) => stage == null
    ? story
    : Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: story),
          SizedBox(width: _TavernChatPageState._stageWidth, child: stage),
        ],
      );

/// Your line in the bubble layout: the app's bubble, with the story's
/// Markdown and colours inside (your *actions* in italics, as hers are).
class _YourLine extends StatelessWidget {
  const _YourLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: LayoutBuilder(
        builder: (context, constraints) => ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.82),
          child: DecoratedBox(
            decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              // The bubble's own text colour for the narration.
              child: Theme(
                data: theme.copyWith(colorScheme: theme.colorScheme.copyWith(onSurface: surfaces.onUserBubble)),
                child: MarkdownBody(text: text, selectable: false),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An older reply's alternatives, as a count: switched by swiping.
class _AlternativesCount extends StatelessWidget {
  const _AlternativesCount({required this.message});

  final TavernMessage message;

  @override
  Widget build(BuildContext context) => Text(
    '${message.siblingIndex + 1}/${message.siblingCount}',
    key: ValueKey('tavern-alt-${message.nodeId}'),
    style: AppType.tabular(Theme.of(context).textTheme.labelSmall!.copyWith(color: DshColors.of(context).textTertiary)),
  );
}

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
    // The keys' own padding would indent the row; line its ‹ up with the text.
    return Transform.translate(
      offset: const Offset(-10, 0),
      child: Row(
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
      ),
    );
  }
}

/// What has arrived of the reply being written.
typedef _Streamed = ({String text, String reasoning});

const _Streamed _nothing = (text: '', reasoning: '');

/// The reply being written, rebuilt alone as each piece arrives.
class _StreamingReply extends StatelessWidget {
  const _StreamingReply({super.key, required this.stream});

  final ValueListenable<_Streamed> stream;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: stream,
    builder: (context, streamed, _) {
      final (:text, :reasoning) = streamed;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (reasoning.isNotEmpty) ThinkingPill(reasoning: reasoning, active: text.isEmpty, streaming: true),
          if (text.isEmpty && reasoning.isEmpty)
            const Align(alignment: Alignment.centerLeft, child: TypingIndicator())
          else if (text.isNotEmpty)
            MarkdownBody(text: text, streaming: true, selectable: false),
        ],
      );
    },
  );
}

/// The last turn's error over the composer, with 「重试」 when it can retry.
class _ErrorSlot extends StatelessWidget {
  const _ErrorSlot({required this.error, required this.action, required this.onDismiss});

  final String? error;
  final ({String label, VoidCallback onPressed})? action;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SmoothSize(
    duration: AppMotion.of(context, AppMotion.standard),
    curve: AppMotion.std,
    alignment: Alignment.bottomCenter,
    child: error == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ErrorBanner(
              key: const ValueKey('tavern-error'),
              message: error!,
              onDismiss: onDismiss,
              action: action,
            ),
          ),
  );
}
