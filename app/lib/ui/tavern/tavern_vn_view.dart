// 视觉小说 layout (docs/design/roleplay-ui.md §4): the character's picture on
// the stage, one paragraph at a time in a glass box at the bottom; tap the box
// for the next one. Built natively for now; the canvas (R2) adds backgrounds
// and expression sprites from the card's assets.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../chat/render/markdown_body.dart';
import '../companion/companion_log.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_widgets.dart';

/// One page of the story: a paragraph of a message.
class TavernPage {
  const TavernPage(this.message, this.text, {this.streaming = false});
  final TavernMessage message;
  final String text;
  final bool streaming;
}

/// The path cut into pages, the reply being written included.
List<TavernPage> tavernPages(List<TavernMessage> messages, {String? streamNode, String streamText = ''}) => [
  for (final m in messages)
    for (final paragraph in _paragraphs(m.nodeId == streamNode ? streamText : m.text))
      TavernPage(m, paragraph, streaming: m.nodeId == streamNode),
];

Iterable<String> _paragraphs(String text) =>
    text.split(RegExp(r'\n\s*\n')).map((p) => p.trim()).where((p) => p.isNotEmpty);

class TavernVisualNovelView extends StatefulWidget {
  const TavernVisualNovelView({
    super.key,
    required this.pages,
    required this.name,
    required this.avatarPath,
    required this.topInset,
    required this.onMenu,
    required this.footer,
    this.stage,
    this.onPage,
  });

  final List<TavernPage> pages;

  /// The character on stage.
  final String name;
  final String? avatarPath;
  final double topInset;
  final ValueChanged<TavernMessage> onMenu;

  /// Under the box on the last page: the reply's alternatives.
  final Widget? Function(TavernMessage message, bool lastPage) footer;

  /// The character's Live2D stage, in place of the card's picture.
  final Widget? stage;

  /// A page came up: a new one, or one reached by stepping back and forth.
  final ValueChanged<TavernPage>? onPage;

  @override
  State<TavernVisualNovelView> createState() => _TavernVisualNovelViewState();
}

class _TavernVisualNovelViewState extends State<TavernVisualNovelView> {
  /// The page shown; null follows the newest.
  int? _page;

  /// The backlog is open over the stage.
  bool _log = false;

  int get _last => widget.pages.length - 1;

  @override
  void didUpdateWidget(TavernVisualNovelView old) {
    super.didUpdateWidget(old);
    // Reading the newest page when more arrive: keep up with them.
    if (_page != null && _page! >= old.pages.length - 1) _page = null;
    if (_page != null && _page! > _last) _page = null;
  }

  void _next() {
    final at = _page ?? _last;
    if (at < _last) setState(() => _page = at + 1 == _last ? null : at + 1);
  }

  void _previous() {
    final at = _page ?? _last;
    if (at > 0) setState(() => _page = at - 1);
  }

  /// The page last told to [TavernVisualNovelView.onPage]: its message, where
  /// it is, and whether it was still being written.
  (String, int, bool)? _told;

  void _tell(TavernPage? page, int at) {
    final onPage = widget.onPage;
    if (page == null || onPage == null) return;
    final key = (page.message.nodeId, at, page.streaming);
    if (key == _told) return;
    _told = key;
    // After this frame: the page is on screen before the stage reacts to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) onPage(page);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final pages = widget.pages;
    final at = (_page ?? _last).clamp(0, pages.isEmpty ? 0 : _last);
    final page = pages.isEmpty ? null : pages[at];
    final user = page?.message.role == TavernRole.user;
    final speaker = page == null ? widget.name : (user ? context.l10n.tavernYou : page.message.speaker);
    _tell(page, at);
    final stage = widget.stage;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [scheme.primaryContainer.withValues(alpha: 0.35), Colors.transparent],
              ),
            ),
          ),
        ),
        // Her Live2D model, across the stage: she listens while you speak.
        if (stage != null)
          Positioned(
            key: const ValueKey('tavern-vn-stage'),
            left: 0,
            right: 0,
            top: widget.topInset,
            bottom: 170,
            child: stage,
          )
        // Else the card's picture, dimmed a little while you speak.
        else
          Positioned(
            left: 40,
            right: 40,
            top: widget.topInset + 8,
            bottom: 190,
            child: Center(
              child: AnimatedOpacity(
                opacity: user ? 0.55 : 1,
                duration: AppMotion.of(context, AppMotion.standard),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: TavernPortrait(
                    name: widget.name,
                    path: widget.avatarPath,
                    radius: AppShape.xl,
                    initialSize: 96,
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 8,
          child: GestureDetector(
            key: const ValueKey('tavern-vn-box'),
            behavior: HitTestBehavior.opaque,
            onTap: _next,
            onLongPress: page == null ? null : () => widget.onMenu(page.message),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 200) _previous();
              if (v < -200) _next();
            },
            // Up over the box: the backlog, as in a visual novel.
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -300) setState(() => _log = true);
            },
            child: GlassSurface(
              tier: GlassTier.sheet,
              borderRadius: AppShape.radiusXl,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        speaker,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: user ? dsh.textTertiary : scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (pages.length > 1)
                        Text(
                          '${at + 1}/${pages.length}',
                          style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                        ),
                      SizedBox.square(
                        dimension: 32,
                        child: IconButton(
                          key: const ValueKey('tavern-vn-log'),
                          tooltip: context.l10n.tavernLog,
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          color: dsh.textTertiary,
                          onPressed: () => setState(() => _log = true),
                          icon: Icon(AppIcons.history),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 72, maxHeight: 220),
                    child: SingleChildScrollView(
                      reverse: page?.streaming ?? false,
                      child: AnimatedSwitcher(
                        duration: AppMotion.of(context, AppMotion.quick),
                        child: SizedBox(
                          key: ValueKey(at),
                          width: double.infinity,
                          child: page == null
                              ? const SizedBox.shrink()
                              : MarkdownBody(text: page.text, streaming: page.streaming, selectable: false),
                        ),
                      ),
                    ),
                  ),
                  if (page != null) ?widget.footer(page.message, at == _last),
                ],
              ),
            ),
          ),
        ),
        // The backlog is drawn for a dark stage (伙伴小屋's), whatever the
        // app's brightness; it starts under the floating header.
        Positioned.fill(
          top: widget.topInset,
          child: CompanionLogTransition(
            child: _log
                ? Theme(
                    key: const ValueKey('tavern-vn-backlog'),
                    data: buildDarkTheme(),
                    child: CompanionLog(
                      entries: [
                        for (final page in pages)
                          if (page.message.role == TavernRole.user)
                            CompanionLogEntry.you(_plain(page.text))
                          else
                            CompanionLogEntry.her(_plain(page.text)),
                      ],
                      name: widget.name,
                      onClose: () => setState(() => _log = false),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// A page as the backlog shows it: plain text, Markdown emphasis dropped.
String _plain(String text) => text.replaceAll(RegExp(r'(\*\*|\*|__)'), '');
