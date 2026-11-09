// Adapted from SillyTavern public/scripts/PromptManager.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import 'default_preset.dart';

/// A lossless JSON preset plus a normalized, independent execution view.
/// Connection fields are preserved but never used to choose an endpoint or key.
final class ChatPreset {
  ChatPreset(Map<String, Object?> value) : _raw = _copy(value);

  factory ChatPreset.decode(String text) {
    final value = jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text);
    if (value is! Map<String, Object?>) throw const FormatException('Preset must be a JSON object');
    return ChatPreset(value);
  }

  factory ChatPreset.stDefault() => ChatPreset.decode(stDefaultPresetJson);

  final Map<String, Object?> _raw;

  Map<String, Object?> get raw => _copy(_raw);

  /// Unknown fields and legacy keys survive an ordinary import/export cycle.
  String encode({bool includeConnection = true}) {
    final value = raw;
    if (!includeConnection) {
      for (final key in _connectionFields) {
        value.remove(key);
      }
    }
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Map<String, Object?> get settings {
    final defaults = jsonDecode(stDefaultPresetJson) as Map<String, Object?>;
    // Runtime defaults differ slightly from the bundled named Default preset.
    defaults['stream_openai'] = false;
    final defaultPrompts = defaults['prompts'] as List<Object?>;
    (defaultPrompts.first as Map<String, Object?>)['content'] =
        "Write {{char}}'s next reply in a fictional chat between {{charIfNotGroup}} and {{user}}.";
    final result = <String, Object?>{
      ...defaults,
      'show_thoughts': true,
      'reasoning_effort': 'auto',
      'function_calling': false,
      ...raw,
    };
    final builtins = (defaults['prompts'] as List<Object?>).whereType<Map<String, Object?>>().toList();
    final supplied = result['prompts'];
    final prompts = supplied is List<Object?>
        ? supplied.whereType<Map<String, Object?>>().map(_copy).toList()
        : <Map<String, Object?>>[];
    for (final builtin in builtins) {
      if (!prompts.any((prompt) => prompt['identifier'] == builtin['identifier'])) prompts.add(_copy(builtin));
    }
    for (final identifier in ['main', 'nsfw', 'jailbreak']) {
      final legacy = result['${identifier}_prompt'];
      if (legacy is String && legacy.isNotEmpty) {
        prompts.firstWhere((prompt) => prompt['identifier'] == identifier)['content'] = legacy;
        result.remove('${identifier}_prompt');
      }
    }
    for (var i = 0; i < prompts.length; i++) {
      prompts[i]['identifier'] ??= 'unnamed-$i';
    }
    result['prompts'] = prompts;
    final orders = result['prompt_order'];
    final groups = orders is List<Object?>
        ? orders.whereType<Map<String, Object?>>().toList()
        : <Map<String, Object?>>[];
    final active = groups.where((group) => '${group['character_id']}' == '100001').firstOrNull;
    if (active == null || active['order'] is! List<Object?> || (active['order'] as List<Object?>).isEmpty) {
      final defaultGroups = defaults['prompt_order'] as List<Object?>;
      final fallback = defaultGroups.whereType<Map<String, Object?>>().firstWhere((g) => g['character_id'] == 100001);
      groups.add(_copy(fallback));
    }
    result['prompt_order'] = groups;
    return result;
  }

  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, Object?>;

  // Explicit export choice; this does not remove unfamiliar extension data.
  static const _connectionFields = {
    'chat_completion_source',
    'openai_model',
    'claude_model',
    'google_model',
    'vertexai_model',
    'openrouter_model',
    'ai21_model',
    'mistralai_model',
    'cohere_model',
    'perplexity_model',
    'groq_model',
    'chutes_model',
    'siliconflow_model',
    'siliconflow_endpoint',
    'minimax_model',
    'minimax_endpoint',
    'electronhub_model',
    'nanogpt_model',
    'nanogpt_provider',
    'nanogpt_payg_override',
    'deepseek_model',
    'aimlapi_model',
    'xai_model',
    'pollinations_model',
    'pollinations_endpoint',
    'cometapi_model',
    'moonshot_model',
    'fireworks_model',
    'zai_model',
    'zai_endpoint',
    'workers_ai_model',
    'workers_ai_account_id',
    'custom_model',
    'custom_url',
    'custom_include_body',
    'custom_exclude_body',
    'custom_include_headers',
    'reverse_proxy',
    'proxy_password',
    'azure_base_url',
    'azure_deployment_name',
    'azure_api_version',
    'azure_openai_model',
    'vertexai_auth_mode',
    'vertexai_region',
    'vertexai_express_project_id',
    'show_external_models',
    'bypass_status_check',
  };
}
