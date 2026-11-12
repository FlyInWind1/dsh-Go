// A card script's toastr on the canvas (tavern_canvas.dart posts it), shown
// as the app's own notice.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../tavern/tavern_canvas.dart';

/// The notices one canvas's card scripts ask for. One already up or waiting
/// takes the new words rather than another queueing behind it; a notice of
/// the app's own is never put away for one, it waits its turn.
class TavernToasts {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _bar;
  final _text = ValueNotifier<(String, String)>(('', ''));
  bool _disposed = false;

  /// Shows what [data] (the page's {type:'toast', level, title, message})
  /// says on [messenger], if anything.
  void show(ScaffoldMessengerState messenger, Map<Object?, Object?> data) {
    final toast = tavernToast(data);
    if (_disposed || toast == null) return;
    _text.value = (toast.title, toast.message);
    if (_bar != null) return;
    final bar = _bar = messenger.showSnackBar(
      SnackBar(
        key: const ValueKey('tavern-canvas-toast'),
        content: Builder(
          builder: (context) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ScaffoldMessenger.of(context).removeCurrentSnackBar(reason: SnackBarClosedReason.dismiss),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              // The title as a heading over the words, as toastr sets it.
              child: ValueListenableBuilder<(String, String)>(
                valueListenable: _text,
                builder: (_, text, _) => Text.rich(
                  key: const ValueKey('tavern-canvas-toast-text'),
                  TextSpan(
                    children: [
                      if (text.$1.isNotEmpty)
                        TextSpan(
                          text: text.$1,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      if (text.$1.isNotEmpty && text.$2.isNotEmpty) const TextSpan(text: '\n'),
                      if (text.$2.isNotEmpty) TextSpan(text: text.$2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        padding: EdgeInsets.zero,
        duration: toast.duration,
      ),
    );
    unawaited(
      bar.closed.whenComplete(() {
        if (identical(_bar, bar)) _bar = null;
        if (_disposed) _text.dispose();
      }),
    );
  }

  /// Done with: a notice still up reads its words until it goes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bar == null) _text.dispose();
  }
}
