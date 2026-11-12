// 整页画布 (tavern_canvas.dart): one web view for the whole story, loaded
// once; messages go in through render(), the reply being written through
// stream() at most every 50 ms. A long press on a message opens the app's own
// message menu. If the web view's renderer goes, it loads again and says so.
// Tests swap the builder (no platform web view there).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_canvas.dart';
import '../../tavern/tavern_canvas_calls.dart';
import '../../tavern/tavern_settings.dart';
import '../../tavern/tavern_st_theme.dart';
import '../common/brief_notice.dart';
import '../theme/theme.dart';
import '../web/web_view_guard.dart';
import 'tavern_ink.dart';
import 'tavern_toasts.dart';

/// What the canvas is handed: the shown messages; the reply being written
/// (its speaker's name and its HTML, null when none) as it changes; what to
/// do when a message is held; and who answers the page's dsh.call, and
/// brings the engine's deliveries back to it, if anyone.
typedef TavernCanvasBuilder = Widget Function({
  required List<TavernCanvasEntry> entries,
  required ValueListenable<(String, String)?> streaming,
  required void Function(String nodeId) onMenu,
  TavernCanvasCalls? calls,
});

/// The libraries card scripts find on the canvas page, as 酒馆助手's pages
/// give them: jQuery and lodash (bundled; licences in THIRD_PARTY_NOTICES.md).
final tavernCanvasLibrariesProvider = FutureProvider<List<String>>(
  (ref) async => [
    await rootBundle.loadString('assets/tavern/jquery-3.7.1.min.js'),
    await rootBundle.loadString('assets/tavern/lodash-4.17.21.min.js'),
  ],
);

/// Builds the canvas. Tests swap it.
final tavernCanvasBuilderProvider = Provider<TavernCanvasBuilder>(
  (ref) =>
      ({required entries, required streaming, required onMenu, calls}) =>
          TavernCanvasView(entries: entries, streaming: streaming, onMenu: onMenu, calls: calls),
);

class TavernCanvasView extends ConsumerStatefulWidget {
  const TavernCanvasView({super.key, required this.entries, required this.streaming, required this.onMenu, this.calls});

  final List<TavernCanvasEntry> entries;
  final ValueListenable<(String, String)?> streaming;
  final void Function(String nodeId) onMenu;
  final TavernCanvasCalls? calls;

  @override
  ConsumerState<TavernCanvasView> createState() => _TavernCanvasViewState();
}

class _TavernCanvasViewState extends ConsumerState<TavernCanvasView> {
  WebViewController? _controller;
  late WebViewGuard _guard = WebViewGuard(onGone: _onGone);
  bool _ready = false;
  Object? _loaded;
  String? _rendered;
  Timer? _streamTimer;
  (String, String)? _streamSent;
  final _toasts = TavernToasts();

  @override
  void initState() {
    super.initState();
    widget.streaming.addListener(_onStream);
    widget.calls?.deliver = _deliver;
  }

  /// The engine's delivery for this page's script context, into its copy;
  /// not before the page is ready (it takes a snapshot then anyway).
  Future<bool> _deliver(Map<String, Object?> delivery) async {
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return false;
    await controller.runJavaScript('window.dsh&&dsh.scripts.deliver(${jsonEncode(delivery)})');
    return true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open();
  }

  @override
  void didUpdateWidget(TavernCanvasView old) {
    super.didUpdateWidget(old);
    if (!identical(old.calls, widget.calls)) {
      if (old.calls?.deliver == _deliver) old.calls?.deliver = null;
      widget.calls?.deliver = _deliver;
    }
    if (old.streaming != widget.streaming) {
      old.streaming.removeListener(_onStream);
      widget.streaming.addListener(_onStream);
    }
    _render();
  }

  /// Loads the page, again when its look or its guards change.
  void _open() {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final ink = TavernInkScope.maybeOf(context);
    final (noScripts, offline) = ref.read(tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline)));
    // An ST theme's custom CSS, with its colours chosen and its CSS kept on.
    final themeCss = ref.read(tavernSettingsProvider.select((s) => s.palette)) == TavernPalette.st
        ? ref.read(tavernStThemeProvider)?.canvasCss ?? ''
        : '';
    final reading = ref.read(tavernSettingsProvider.select((s) => (s.textSize, s.lineHeight)));
    final text = theme.colorScheme.onSurface;
    // Card scripts get their libraries first; the page waits for them (and
    // goes without, should they not load) — not when scripts do not run.
    final List<String> libraries;
    if (noScripts) {
      libraries = const [];
    } else {
      final loaded = ref.read(tavernCanvasLibrariesProvider);
      if (loaded.isLoading) return;
      libraries = loaded.value ?? const [];
    }
    final key = (
      noScripts,
      offline,
      theme.brightness,
      ink?.dialogue,
      ink?.action,
      theme.colorScheme.primary,
      reading,
      themeCss,
    );
    if (key == _loaded) return;
    _loaded = key;
    _ready = false;
    _rendered = null;
    final document = tavernCanvasDocument(
      text: text,
      accent: theme.colorScheme.primary,
      muted: dsh.textTertiary,
      quote: ink?.dialogue ?? text,
      emphasis: ink?.action ?? text,
      userTint: theme.colorScheme.primary.withValues(alpha: 0.12),
      fontSize: reading.$1,
      lineHeight: reading.$2,
      nonce: _nonce(),
      userLabel: context.l10n.tavernYou,
      labels: TavernCanvasLabels(
        letter: context.l10n.tavernLetter,
        letterFrom: context.l10n.tavernLetterFrom('{from}'),
        taken: context.l10n.tavernItemTaken,
        clue: context.l10n.tavernClue,
        phone: context.l10n.tavernPhoneMessage,
        phoneFrom: context.l10n.tavernPhoneFrom('{from}'),
        roll: context.l10n.tavernRoll,
        rollCheck: context.l10n.tavernRollCheck('{skill}'),
        success: context.l10n.tavernRollSuccess,
        failure: context.l10n.tavernRollFailure,
        game: context.l10n.tavernGameHere,
      ),
      noScripts: noScripts,
      offline: offline,
      libraries: libraries,
      themeCss: themeCss,
    );
    final controller = _controller ??= WebViewController();
    final textZoom = MediaQuery.textScalerOf(context).scale(100).round().clamp(50, 300);
    final dark = theme.brightness == Brightness.dark;
    unawaited(() async {
      await Future.wait(
        [
          controller.setJavaScriptMode(JavaScriptMode.unrestricted),
          controller.setBackgroundColor(Colors.transparent),
          controller.addJavaScriptChannel('DshTavern', onMessageReceived: (m) => _onMessage(m.message)),
          controller.setNavigationDelegate(NavigationDelegate(onNavigationRequest: _onNavigation)),
        ].map((f) => f.catchError((_) {})),
      );
      if (!mounted || controller != _controller) return;
      await _guard.attach(controller, dark: dark, textZoom: textZoom).catchError((_) {});
      if (!mounted || controller != _controller) return;
      await controller.loadHtmlString(document).catchError((_) {});
    }());
  }

  static final _random = Random.secure();
  static String _nonce() => List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  void _onMessage(String message) {
    final Object? data;
    try {
      data = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (data is! Map || !mounted) return;
    switch (data['type']) {
      case 'ready':
        _ready = true;
        _rendered = null;
        _streamSent = null;
        _render();
        _onStream();
      case 'menu':
        if (data['node'] case final String node when node.isNotEmpty) widget.onMenu(node);
      case 'call':
        unawaited(_answer(data));
      case 'ack':
        widget.calls?.acknowledge(data);
      case 'toast':
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger != null) _toasts.show(messenger, data);
    }
  }

  /// A dsh.call from the page, answered to the page that asked (not to one
  /// built since, after the renderer went).
  Future<void> _answer(Map<Object?, Object?> request) async {
    final controller = _controller;
    final calls = widget.calls;
    final reply = calls == null
        ? {
            'id': request['id'],
            'ok': false,
            'error': {'code': 'unsupportedCapability', 'message': 'Nothing answers here.', 'committed': false},
          }
        : await calls.handle(request);
    if (!mounted || controller == null || !identical(controller, _controller)) return;
    await controller.runJavaScript('window.dsh&&dsh.answer(${jsonEncode(reply)})').catchError((_) {});
  }

  /// The messages, when they differ from what the page shows.
  void _render() {
    final controller = _controller;
    if (!_ready || controller == null) return;
    final json = tavernCanvasJson(widget.entries);
    if (json == _rendered) return;
    _rendered = json;
    _streamSent = null;
    unawaited(controller.runJavaScript('window.dsh&&dsh.render($json)').catchError((_) {}));
  }

  /// The reply being written, at most every 50 ms (as ST reflows it).
  void _onStream() {
    if (_streamTimer?.isActive ?? false) return;
    _streamTimer = Timer(const Duration(milliseconds: 50), () {
      final controller = _controller;
      final now = widget.streaming.value;
      if (!mounted || !_ready || controller == null || now == _streamSent) return;
      _streamSent = now;
      final call = now == null
          ? 'window.dsh&&dsh.stream("",null)'
          : 'window.dsh&&dsh.stream(${jsonEncode(now.$1)},${jsonEncode(now.$2)})';
      unawaited(controller.runJavaScript(call).catchError((_) {}));
    });
  }

  /// The page itself stays put; a link opens outside the app.
  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = request.url;
    if (url == 'about:blank' || url.startsWith('data:') || url.startsWith('about:srcdoc')) {
      return NavigationDecision.navigate;
    }
    if (!request.isMainFrame) return NavigationDecision.navigate;
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false));
    }
    return NavigationDecision.prevent;
  }

  /// The renderer went (a heavy card, memory): a new web view, the story
  /// drawn again, and a word that it happened.
  void _onGone(bool crashed) {
    if (!mounted) return;
    final old = _guard;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(old.destroy()));
    ScaffoldMessenger.maybeOf(context)?.showBriefNotice(context.l10n.tavernCanvasReloaded);
    // The handlers the lost page was running will not answer.
    widget.calls?.pageLost();
    setState(() {
      _guard = WebViewGuard(onGone: _onGone);
      _controller = null;
      _loaded = null;
    });
    _open();
  }

  @override
  void dispose() {
    if (widget.calls?.deliver == _deliver) {
      widget.calls?.deliver = null;
      widget.calls?.pageLost();
    }
    widget.streaming.removeListener(_onStream);
    _streamTimer?.cancel();
    _guard.dispose();
    _toasts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      tavernSettingsProvider.select((s) => (s.islandNoScripts, s.islandOffline, s.textSize, s.lineHeight, s.palette)),
      (_, _) => _open(),
    );
    ref.listen(tavernStThemeProvider, (_, _) => _open());
    ref.listen(tavernCanvasLibrariesProvider, (_, next) {
      if (!next.isLoading) _open();
    });
    final controller = _controller;
    if (controller == null) return const SizedBox.expand();
    return WebViewWidget(key: const ValueKey('tavern-canvas'), controller: controller);
  }
}
