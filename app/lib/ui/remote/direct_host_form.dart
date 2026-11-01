import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/direct/direct_link.dart';
import '../../state/hosts_state.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'link_progress.dart';
import '../common/discard_guard.dart';
import '../common/smooth_size.dart';

/// Add or edit a direct-connect host (own reverse proxy / tunnel), with a
/// "测试连接" that runs the real login against the origin.
class DirectHostFormPage extends ConsumerStatefulWidget {
  const DirectHostFormPage({super.key, this.existing});

  /// Null to add a new host.
  final DirectHostConfig? existing;

  @override
  ConsumerState<DirectHostFormPage> createState() => _DirectHostFormPageState();
}

enum _F { url, token }

class _DirectHostFormPageState extends ConsumerState<DirectHostFormPage> {
  late final String _id = widget.existing?.id ?? DirectHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.url ?? '');
  final _token = TextEditingController();

  bool _saving = false;
  String? _formError;
  Map<_F, String> _errors = const {};
  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  DirectHostLink? _test;
  StreamSubscription<HostLinkStatus>? _testSub;
  HostLinkStatus? _testStatus;

  bool get _editing => widget.existing != null;

  late String _clean;
  late final Listenable _edits = Listenable.merge([_name, _url, _token]);

  String _signature() => jsonEncode({'name': _name.text, 'url': _url.text, 'token': _token.text});

  @override
  void initState() {
    super.initState();
    _clean = _signature();
    if (_editing) unawaited(_loadToken());
  }

  Future<void> _loadToken() async {
    final token = await ref.read(hostsProvider.notifier).loadDirectToken(_id);
    if (mounted && token != null) setState(() => _token.text = token);
  }

  @override
  void dispose() {
    unawaited(_testSub?.cancel());
    unawaited(_test?.close());
    for (final c in [_name, _url, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The config as typed; null (with [_errors] set) when incomplete.
  DirectHostConfig? _draft() {
    final typed = _url.text.trim();
    final url = DirectHostConfig.normalizeOrigin(typed);
    // A pasted launch URL fills the token field too (once).
    final pastedToken = url == null ? null : DirectHostConfig.tokenFrom(typed);
    final errors = <_F, String>{
      if (url == null) _F.url: context.l10n.remoteDirectErrUrl,
    };
    if (url != null && pastedToken != null && _token.text.isEmpty) {
      _token.text = pastedToken;
    }
    if (_token.text.trim().isEmpty) errors[_F.token] = context.l10n.remoteDirectErrToken;
    setState(() {
      _errors = errors;
      _formError = null;
    });
    if (errors.isNotEmpty) {
      final first = _F.values.firstWhere(errors.containsKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _fieldKeys[first]!.currentContext;
        if (target == null || !target.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.3,
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.glide,
          ),
        );
      });
      return null;
    }
    return DirectHostConfig(
      id: _id,
      name: _name.text.trim().isEmpty ? Uri.parse(url!).host : _name.text.trim(),
      url: url!,
    );
  }

  void _edited(_F field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  Future<void> _runTest() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    await _testSub?.cancel();
    await _test?.close();
    final token = _token.text.trim();
    final link = DirectHostLink(
      config: config,
      loadToken: () async => token,
      retryFirstOpen: false,
    );
    _test = link;
    setState(() => _testStatus = const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    _testSub = link.statuses.listen((s) {
      if (mounted && s.phase != HostLinkPhase.idle) setState(() => _testStatus = s);
    });
    try {
      await link.open();
    } catch (_) {
      // Shown in the progress card.
    } finally {
      await _testSub?.cancel();
      _testSub = null;
      if (identical(_test, link)) _test = null;
      await link.close();
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final config = _draft();
    if (config == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(hostsProvider.notifier).saveDirect(config, token: _token.text.trim());
      if (mounted) Navigator.of(context).pop(config);
    } catch (_) {
      if (mounted) setState(() => _formError = context.l10n.commonSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final name = widget.existing!.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteDeleteHostTitle(name)),
        content: Text(context.l10n.remoteDeleteHostBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(hostsProvider.notifier).removeDirect(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final testing = _test != null;
    final mono = AppType.mono(size: 15, color: scheme.onSurface, height: 1.4);

    final page = AppPage.list(
      title: _editing ? l10n.remoteEditHost : l10n.remoteAddDirect,
      subtitle: _editing ? null : Text(l10n.remoteDirectSectionHint),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(hintText: l10n.remoteHostNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.url],
                      error: _errors[_F.url],
                      label: l10n.remoteDirectUrl,
                      helper: l10n.remoteDirectUrlHint,
                      child: TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        style: mono,
                        onChanged: (_) => _edited(_F.url),
                        decoration: InputDecoration(
                          hintText: 'https://dsh.example.com',
                          error: _errors[_F.url] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.token],
                      error: _errors[_F.token],
                      label: l10n.remoteDirectToken,
                      helper: l10n.remoteDirectTokenHint,
                      child: TextField(
                        controller: _token,
                        autocorrect: false,
                        style: mono,
                        onChanged: (_) => _edited(_F.token),
                        decoration: InputDecoration(
                          error: _errors[_F.token] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            _Reveal(
              child: _testStatus == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: LinkProgressCard(status: _testStatus!, onRetry: testing ? null : _runTest),
                    ),
            ),
            if (_formError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
              ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.remoteDeleteHost),
                ),
              ),
            const SizedBox(height: 88),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: _DirectFormBar(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: testing || _saving ? null : _runTest,
                    icon: testing
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.testConnection, size: 19),
                    label: Text(testing ? l10n.remoteTesting : l10n.remoteTestConnection),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _saving ? null : _save, child: Text(l10n.commonSave)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Same bottom bar as the SSH form (that one is private there).
class _DirectFormBar extends StatelessWidget {
  const _DirectFormBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom), child: Row(children: children)),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}
