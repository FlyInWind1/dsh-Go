import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../api.dart';
import '../io/regex_intake.dart';
import '../regex/regex_types.dart';
import '../regex_library.dart';

/// Managed global scripts. Legacy inline settings remain a separate earlier
/// global source; importing here never rewrites those settings implicitly.
final class RegexLibrary {
  RegexLibrary(this.root, this.worker, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final Directory root;
  final RegexExecutor worker;
  final DateTime Function() _clock;
  final _random = Random.secure();
  List<TavernRegexScript> _scripts = const [];
  Future<void> _queue = Future.value();
  File get _file => File('${root.path}/regex-library.json');

  Future<void> initialize() async {
    if (!await _file.exists()) return;
    final decoded = jsonDecode(await _file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['version'] != 1 || decoded['scripts'] is! List<Object?>) {
      throw const FormatException('Unsupported regex library.');
    }
    final result = <TavernRegexScript>[];
    final ids = <String>{};
    for (final value in decoded['scripts']! as List<Object?>) {
      if (value is! Map<String, Object?> ||
          value['id'] is! String ||
          value['raw'] is! Map<String, Object?> ||
          value['sourceText'] is! String ||
          value['importedAt'] is! String ||
          value['diagnostics'] is! List<Object?> ||
          !ids.add(value['id']! as String)) {
        throw const FormatException('Invalid regex library record.');
      }
      result.add(
        TavernRegexScript(
          id: value['id']! as String,
          sourceText: value['sourceText']! as String,
          raw: value['raw']! as Map<String, Object?>,
          importedAt: DateTime.parse(value['importedAt']! as String),
          diagnostics: [
            for (final item in value['diagnostics']! as List<Object?>)
              TavernRegexDiagnostic.fromJson(item! as Map<String, Object?>),
          ],
        ),
      );
    }
    _scripts = List.unmodifiable(result);
  }

  List<TavernRegexScript> get scripts => List.unmodifiable(_scripts);
  List<Map<String, Object?>> get executionScripts => [
    for (final script in _scripts) {...script.raw, if (!script.compatible) 'disabled': true},
  ];

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<TavernRegexImportResult> importScripts(String text) async {
    final Object? value;
    try {
      value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    } on FormatException {
      throw const TavernImportError('正则文件不是有效JSON。');
    }
    final values = value is List<Object?> ? value : <Object?>[value];
    if (values.any((value) => value is! Map<String, Object?>)) {
      throw const TavernImportError('正则文件须为单个对象或对象数组。');
    }
    final prepared = <({Map<String, Object?> raw, TavernRegexDiagnostic diagnostic})>[];
    for (var index = 0; index < values.length; index++) {
      final raw = values[index]! as Map<String, Object?>;
      final diagnostic = await inspectRegexScript(raw, worker, path: value is List<Object?> ? '\$[$index]' : r'$');
      prepared.add((raw: raw, diagnostic: diagnostic));
    }
    return _exclusive(() async {
      final ids = _scripts.map((value) => value.id).toSet();
      final records = [
        for (final value in prepared)
          TavernRegexScript(
            id: _newId(ids),
            raw: value.raw,
            sourceText: text,
            importedAt: _clock().toUtc(),
            diagnostics: [value.diagnostic],
          ),
      ];
      if (records.isNotEmpty) await _save([..._scripts, ...records]);
      return TavernRegexImportResult(records);
    });
  }

  Future<TavernRegexScript> setEnabled(String id, bool enabled) => _exclusive(() async {
    final original = _require(id);
    final updated = TavernRegexScript(
      id: id,
      sourceText: original.sourceText,
      raw: {...original.raw, 'disabled': !enabled},
      importedAt: original.importedAt,
      diagnostics: original.diagnostics,
    );
    await _save([for (final script in _scripts) script.id == id ? updated : script]);
    return updated;
  });

  Future<void> delete(String id) => _exclusive(() async {
    if (!_scripts.any((script) => script.id == id)) return;
    await _save([
      for (final script in _scripts)
        if (script.id != id) script,
    ]);
  });

  String exportScripts({String? id}) =>
      jsonEncode(id == null ? [for (final script in _scripts) script.raw] : _require(id).raw);

  TavernRegexScript _require(String id) =>
      _scripts.firstWhere((script) => script.id == id, orElse: () => throw const TavernImportError('正则不存在。'));

  String _newId(Set<String> reserved) {
    String id;
    do {
      id = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    } while (!reserved.add(id));
    return id;
  }

  Future<void> _save(List<TavernRegexScript> scripts) async {
    final temporary = File('${_file.path}.writing');
    final text = jsonEncode({
      'version': 1,
      'scripts': [
        for (final script in scripts)
          {
            'id': script.id,
            'raw': script.raw,
            'sourceText': script.sourceText,
            'importedAt': script.importedAt.toIso8601String(),
            'diagnostics': [for (final issue in script.diagnostics) issue.toJson()],
          },
      ],
    });
    try {
      await root.create(recursive: true);
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(_file.path);
      _scripts = List.unmodifiable(scripts);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
