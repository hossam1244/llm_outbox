import 'dart:convert';

import '../endpoint/llm_endpoint.dart';

/// Programmable [LlmEndpoint] for tests and demos: script any sequence of
/// responses or failures, with optional latency simulation.
///
/// ```dart
/// final fake = FakeLlmEndpoint()
///   ..enqueueFailure(const LlmFailure(LlmFailureKind.rateLimited, 'slow down',
///       retryAfter: Duration(milliseconds: 10)))
///   ..enqueueText('Recovered!');
/// ```
class FakeLlmEndpoint implements LlmEndpoint {
  final _script = <_Step>[];
  final List<CompletionRequest> requests = [];

  /// Throws when true — simulates "the user went offline".
  bool offline = false;

  void enqueueText(String text, {LlmUsage? usage}) {
    _script.add(_Respond(CompletionResponse(text: text, usage: usage)));
  }

  void enqueueResponse(CompletionResponse response) {
    _script.add(_Respond(response));
  }

  void enqueueFailure(LlmFailure failure) {
    _script.add(_Fail(failure));
  }

  /// Artificial per-attempt latency.
  Duration latency = Duration.zero;

  @override
  Future<CompletionResponse> complete(CompletionRequest request) async {
    requests.add(request);
    if (offline) {
      throw const LlmFailure(
          LlmFailureKind.transient, 'offline: no connectivity');
    }
    if (latency > Duration.zero) {
      await Future<void>.delayed(latency);
    }
    final step = _script.isEmpty ? const _MissingScript() : _script.removeAt(0);
    return step.run();
  }

  /// Steps still waiting to be consumed.
  int get remainingScript => _script.length;
}

sealed class _Step {
  Future<CompletionResponse> run();
}

class _Respond implements _Step {
  _Respond(this.response);
  final CompletionResponse response;

  @override
  Future<CompletionResponse> run() async => response;
}

class _Fail implements _Step {
  _Fail(this.failure);
  final LlmFailure failure;

  @override
  Future<CompletionResponse> run() async => throw failure;
}

class _MissingScript implements _Step {
  const _MissingScript();

  @override
  Future<CompletionResponse> run() async => throw const LlmFailure(
      LlmFailureKind.terminal, 'FakeLlmEndpoint: script exhausted');
}

/// Whether a [Cassette] records from a real endpoint or replays fixtures.
enum CassetteMode { record, replay }

/// Record/replay cassettes: record a real endpoint once, replay it forever
/// in tests — deterministic, offline, free.
class Cassette implements LlmEndpoint {
  Cassette.record(LlmEndpoint inner)
      : _inner = inner,
        _fixture = null,
        mode = CassetteMode.record;

  Cassette.replay(Map<String, String> fixture)
      : _inner = null,
        _fixture = fixture,
        mode = CassetteMode.replay;

  final LlmEndpoint? _inner;
  final Map<String, String>? _fixture;
  final CassetteMode mode;

  final _recorded = <String, String>{};

  static String _keyFor(CompletionRequest request) =>
      jsonEncode(request.toJson());

  @override
  Future<CompletionResponse> complete(CompletionRequest request) async {
    final key = _keyFor(request);
    if (mode == CassetteMode.record) {
      final response = await _inner!.complete(request);
      _recorded[key] = response.text;
      return response;
    }
    final text = _fixture![key];
    if (text == null) {
      throw LlmFailure(LlmFailureKind.terminal,
          'cassette miss: no recorded response for $key');
    }
    return CompletionResponse(text: text);
  }

  /// Recorded request→response pairs (record mode) for persisting as JSON.
  Map<String, String> get recorded => Map.unmodifiable(_recorded);

  /// Serializes the cassette to a JSON string for storage.
  String dump() => jsonEncode(_recorded);

  /// Builds a replay cassette from a previously dumped JSON string.
  static Cassette replayFrom(String json) => Cassette.replay(
      (jsonDecode(json) as Map<Object?, Object?>).cast<String, String>());
}
