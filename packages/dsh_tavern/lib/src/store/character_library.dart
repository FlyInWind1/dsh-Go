// Uses the staging/rename and serialized-operation approach of
// app/lib/pets/pet_library.dart at dsh-Go 1c5b220093295f8d069f6bfb06d8b4fc97b9e9c2.
// Pure Dart: the Flutter provider and image work stay outside the UI isolate.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../api.dart';
import '../io/card_codec.dart';

class StoredCharacter {
  const StoredCharacter({required this.id, required this.card, required this.importedAt, this.avatarPath});

  final String id;
  final TavernCard card;
  final DateTime importedAt;
  final String? avatarPath;

  TavernCharacter toCharacter({int chatCount = 0, DateTime? lastChatAt, String? language}) => card.toCharacter(
    id,
    importedAt: importedAt,
    avatarPath: avatarPath,
    chatCount: chatCount,
    lastChatAt: lastChatAt,
    language: language,
  );
}

/// File-backed character library. [root] is `<app support>/tavern`.
///
/// Each import creates a new id. A complete directory is published by rename,
/// so interrupted writes never become visible as a half-imported character.
/// Only one instance should own a root, just as one Tavern owns the app store.
class CharacterLibrary {
  CharacterLibrary(this.root, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Directory root;
  final DateTime Function() _now;
  Future<void> _queue = Future.value();

  Directory get _characters => Directory('${root.path}/characters');

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  Future<StoredCharacter> importCard(Uint8List bytes, {String? fileName}) => _exclusive(() async {
    await _tidy();
    // Decode/ZIP inflate/thumbnail conversion cannot stall Flutter's isolate.
    final decoded = await _decodeImport(bytes);
    final (card, portrait) = decoded;
    final importedAt = _now().toUtc();
    final id = _newId();
    final staging = await _characters.createTemp('.staging-');
    final destination = Directory('${_characters.path}/$id');
    try {
      await File('${staging.path}/card.json').writeAsString(jsonEncode(card.json), flush: true);
      await File('${staging.path}/original.${card.sourceFormat.name}').writeAsBytes(bytes, flush: true);
      if (card.png != null) await File('${staging.path}/source.png').writeAsBytes(card.png!, flush: true);
      if (portrait != null) await File('${staging.path}/portrait.png').writeAsBytes(portrait, flush: true);
      for (final entry in card.assets.entries) {
        if (!isSafeCardAssetPath(entry.key)) throw const TavernImportError('角色卡资源路径无效。');
        final file = File('${staging.path}/resources/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      await File('${staging.path}/library.json').writeAsString(
        jsonEncode({
          'version': 1,
          'importedAt': importedAt.toIso8601String(),
          'sourceFormat': card.sourceFormat.name,
          'sourceFileName': fileName,
          'hasPng': card.png != null,
          'hasPortrait': portrait != null,
          'resources': card.assets.keys.toList(),
        }),
        flush: true,
      );
      // Never overwrite an existing import, even on a random-id collision.
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Character id already exists');
      }
      await staging.rename(destination.path);
    } finally {
      if (await staging.exists()) await _discard(staging);
    }
    return StoredCharacter(
      id: id,
      card: card,
      importedAt: importedAt,
      avatarPath: portrait == null ? null : '${destination.path}/portrait.png',
    );
  });

  Future<StoredCharacter?> read(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    return _read(id);
  });

  Future<List<StoredCharacter>> list() => _exclusive(() async {
    await _tidy();
    final records = <StoredCharacter>[];
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = _name(entity);
      if (!_idPattern.hasMatch(id)) continue;
      final record = await _read(id);
      if (record != null) records.add(record);
    }
    records.sort((a, b) {
      final byTime = b.importedAt.compareTo(a.importedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return records;
  });

  Future<Uint8List> exportCard(String id, {TavernCardFormat format = TavernCardFormat.png}) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final record = await _read(id);
    if (record == null) throw const TavernImportError('角色不存在。');
    final modifiedAt = _now().toUtc();
    final card = record.card;
    return _encodeCard(card, format, modifiedAt);
  });

  /// The Tavern layer deletes this character's chats as part of its operation.
  /// This method owns only the files; it cannot reach an unrelated character.
  Future<void> delete(String id) => _exclusive(() async {
    _requireId(id);
    await _tidy();
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final trash = await directory.rename('${_characters.path}/.trash-${_newId()}');
    await _discard(trash);
  });

  Future<StoredCharacter?> _read(String id) async {
    final directory = Directory('${_characters.path}/$id');
    final type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Character folder is not a directory');
    final metadataValue = jsonDecode(await File('${directory.path}/library.json').readAsString());
    if (metadataValue is! Map<String, Object?> || metadataValue['version'] != 1) {
      throw const TavernImportError('资料库元数据版本无效。');
    }
    final formatValue = metadataValue['sourceFormat'];
    final sourceFormat = switch (formatValue) {
      'png' => TavernCardFormat.png,
      'json' => TavernCardFormat.json,
      'charx' => TavernCardFormat.charx,
      _ => throw const TavernImportError('资料库原件格式无效。'),
    };
    final resourcePaths = metadataValue['resources'];
    if (resourcePaths is! List<Object?>) throw const TavernImportError('资料库资源目录无效。');
    final assets = <String, Uint8List>{};
    for (final path in resourcePaths) {
      if (path is! String || !isSafeCardAssetPath(path)) throw const TavernImportError('资料库资源路径无效。');
      assets[path] = await File('${directory.path}/resources/$path').readAsBytes();
    }
    final cardJson = await File('${directory.path}/card.json').readAsBytes();
    final parsed = await _decodeStored(cardJson);
    final importedAtValue = metadataValue['importedAt'];
    if (importedAtValue is! String) throw const TavernImportError('资料库导入时间无效。');
    final importedAt = DateTime.tryParse(importedAtValue);
    if (importedAt == null) throw const TavernImportError('资料库导入时间无效。');
    final card = TavernCard(
      json: parsed.json,
      assets: assets,
      png: metadataValue['hasPng'] == true ? await File('${directory.path}/source.png').readAsBytes() : null,
      originalBytes: await File('${directory.path}/original.${sourceFormat.name}').readAsBytes(),
      sourceFormat: sourceFormat,
    );
    return StoredCharacter(
      id: id,
      card: card,
      importedAt: importedAt,
      avatarPath: metadataValue['hasPortrait'] == true ? '${directory.path}/portrait.png' : null,
    );
  }

  Future<void> _tidy() async {
    await _characters.create(recursive: true);
    await for (final entity in _characters.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _name(entity);
      if (name.startsWith('.staging-') || name.startsWith('.trash-')) await _discard(entity);
    }
  }
}

final _idPattern = RegExp(r'^card-[0-9a-f]{32}$');

// Top-level helpers keep an isolate callback from capturing the library's
// operation queue (and its unsendable Futures) through a surrounding closure.
Future<(TavernCard, Uint8List?)> _decodeImport(Uint8List bytes) => Isolate.run(() {
  const codec = CardCodec();
  final card = codec.decode(bytes);
  return (card, codec.portraitPng(card));
});

Future<TavernCard> _decodeStored(Uint8List bytes) => Isolate.run(() => const CardCodec().decode(bytes));

Future<Uint8List> _encodeCard(TavernCard card, TavernCardFormat format, DateTime modifiedAt) =>
    Isolate.run(() => const CardCodec().encode(card, format: format, modifiedAt: modifiedAt));

String _newId() {
  final random = Random.secure();
  return 'card-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

void _requireId(String id) {
  if (!_idPattern.hasMatch(id)) throw ArgumentError.value(id, 'id', 'Invalid character id');
}

String _name(FileSystemEntity entity) => entity.uri.pathSegments.lastWhere((part) => part.isNotEmpty);

Future<void> _discard(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on FileSystemException {
    // The rename already made deletion final. Retry residual cleanup on the
    // next operation; never restore a character the user deleted.
  }
}
