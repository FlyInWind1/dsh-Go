// Adapted from SillyTavern src/prompt-converters.js and
// src/endpoints/backends/chat-completions.js (AGPL-3.0).
// Source commit: 7e8663cd9c184a550b37238218bdd32c6efc68e9 (1.19.0).
import 'dart:convert';

import 'preset.dart';
import 'prompt_types.dart';

/// The text-only `semi_tools` path used by ST's native DeepSeek backend.
/// It preserves historical tool messages even when no new tools are configured.
List<PromptSegment> postProcessDeepSeek(
  List<PromptSegment> input, {
  required String userName,
  required String characterName,
  List<String> groupNames = const [],
  List<Map<String, Object?>> tools = const [],
  required PromptTokenCounter counter,
}) {
  var messages = <PromptSegment>[];
  for (final item in input) {
    final message = jsonDecode(jsonEncode(item.message)) as Map<String, Object?>;
    var content = message['content'] as String? ?? '';
    final role = message['role'];
    final name = message['name'];
    if (role == 'system' &&
        name == 'example_assistant' &&
        characterName.isNotEmpty &&
        !content.startsWith('$characterName: ') &&
        !groupNames.any((name) => content.startsWith('$name: '))) {
      content = '$characterName: $content';
    }
    if (role == 'system' && name == 'example_user' && userName.isNotEmpty && !content.startsWith('$userName: ')) {
      content = '$userName: $content';
    }
    if (name is String && name.isNotEmpty && role != 'system' && !content.startsWith('$name: ')) {
      content = '$name: $content';
    }
    message['content'] = content;
    message.remove('name');
    message.remove('reasoning');
    message.remove('reasoning_content');
    messages.add(_segment(item, message, counter));
  }
  messages = _merge(messages, counter);
  if (messages.isEmpty) {
    const message = <String, Object?>{'role': 'user', 'content': "Let's get started."};
    messages.add(
      PromptSegment(
        id: 'empty-prompt',
        message: message,
        sources: const [PromptSource('control', 'empty-prompt')],
        tokens: counter.countMessage(message),
      ),
    );
  }
  for (var i = 1; i < messages.length; i++) {
    final item = messages[i];
    if (item.message['role'] == 'system') {
      messages[i] = _segment(item, {...item.message, 'role': 'user'}, counter);
    }
  }
  messages = _merge(messages, counter);
  final hasTools = tools.isNotEmpty || messages.any((message) => message.message['role'] == 'tool');
  if (!hasTools && messages.last.message['role'] == 'assistant') {
    messages[messages.length - 1] = _segment(messages.last, {...messages.last.message, 'prefix': true}, counter);
  }
  for (var i = 0; i < messages.length; i++) {
    final item = messages[i];
    if (item.message['tool_calls'] is List<Object?>) {
      messages[i] = _segment(item, {...item.message, 'reasoning_content': ''}, counter);
    }
  }
  return messages;
}

PromptSegment _segment(PromptSegment original, Map<String, Object?> message, PromptTokenCounter counter) =>
    PromptSegment(
      id: original.id,
      message: message,
      sources: original.sources,
      tokens: counter.countMessage(_countable(message)),
    );

Map<String, Object?> _countable(Map<String, Object?> message) => {
  'role': message['role'],
  'content': message['content'],
  if (message.containsKey('name')) 'name': message['name'],
};

List<PromptSegment> _merge(List<PromptSegment> input, PromptTokenCounter counter) {
  final result = <PromptSegment>[];
  for (final item in input) {
    if (result.isNotEmpty &&
        result.last.message['role'] == item.message['role'] &&
        item.message['content'] != '' &&
        item.message['role'] != 'tool') {
      final previous = result.removeLast();
      final message = {...previous.message, 'content': '${previous.message['content']}\n\n${item.message['content']}'};
      result.add(
        PromptSegment(
          id: '${previous.id}+${item.id}',
          message: message,
          sources: [...previous.sources, ...item.sources],
          tokens: counter.countMessage(_countable(message)),
        ),
      );
    } else {
      result.add(item);
    }
  }
  return result;
}

/// Produces the actual DeepSeek request, not the browser-to-ST intermediate body.
Map<String, Object?> deepSeekRequestBody({
  required List<PromptSegment> messages,
  required Map<String, Object?> settings,
  required String model,
  required String generationType,
  List<String> stops = const [],
  List<Map<String, Object?>> tools = const [],
  Object? toolChoice,
}) {
  final thinking = presetTruthy(settings['show_thoughts']);
  final topP = _sampling(settings, 'top_p', 1);
  final effort = settings.containsKey('reasoning_effort') ? settings['reasoning_effort'] : 'auto';
  final body = <String, Object?>{
    'messages': messages.map((message) => message.message).toList(),
    'model': model,
    'temperature': _sampling(settings, 'temperature', 1),
    // Both ST's frontend and sendDeepSeekRequest forward this value unchanged;
    // only the prompt-budget calculation uses numeric coercion.
    'max_tokens': settings.containsKey('openai_max_tokens') ? settings['openai_max_tokens'] : 300,
    'stream': presetTruthy(settings['stream_openai']) && generationType != 'quiet',
    'presence_penalty': _sampling(settings, 'presence_penalty', 0),
    'frequency_penalty': _sampling(settings, 'frequency_penalty', 0),
    'top_p': topP == 0 ? 2.220446049250313e-16 : topP,
    if (stops.isNotEmpty) 'stop': stops.take(4).toList(),
    // ST's normal DeepSeek frontend excludes seed, though its backend accepts it.
    'thinking': {'type': thinking ? 'enabled' : 'disabled'},
    if (thinking && effort != 'auto')
      'reasoning_effort': switch (effort) {
        'min' || 'low' => 'low',
        'max' => 'max',
        _ => 'high',
      },
  };
  if (tools.isNotEmpty) {
    final copy = jsonDecode(jsonEncode(tools)) as List<Object?>;
    for (final tool in copy.whereType<Map<String, Object?>>()) {
      final function = tool['function'];
      if (function is! Map<String, Object?>) continue;
      final parameters = function['parameters'];
      if (parameters is Map<String, Object?> &&
          parameters['required'] is List<Object?> &&
          (parameters['required'] as List<Object?>).isEmpty) {
        parameters.remove('required');
      }
    }
    body['tools'] = copy;
    if (toolChoice != null) body['tool_choice'] = toolChoice;
  }
  return body;
}

num? _sampling(Map<String, Object?> settings, String key, num fallback) =>
    settings.containsKey(key) ? presetSamplingNumber(settings[key]) : fallback;
