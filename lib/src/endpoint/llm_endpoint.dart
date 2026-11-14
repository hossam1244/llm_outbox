/// A single completion request routed through an [LlmEndpoint].
///
/// Deliberately minimal: `llm_outbox` is provider-agnostic, so anything
/// provider-specific (model name, tools, generation settings) travels in
/// [metadata] while the queue cares only about what it must persist and
/// retry.
class CompletionRequest {
  const CompletionRequest({
    required this.prompt,
    this.conversationId,
    this.metadata = const {},
  });

  /// The user prompt to send.
  final String prompt;

  /// Optional conversation this prompt belongs to (see [ConversationStore]).
  final String? conversationId;

  /// Provider-specific payload the endpoint understands: model name,
  /// temperature, tool definitions, ...
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
        'prompt': prompt,
        'conversationId': conversationId,
        'metadata': metadata,
      };

  factory CompletionRequest.fromJson(Map<String, Object?> json) =>
      CompletionRequest(
        prompt: json['prompt']! as String,
        conversationId: json['conversationId'] as String?,
        metadata: (json['metadata'] as Map<Object?, Object?>?)?.cast() ??
            const <String, Object?>{},
      );
}

/// The outcome of one completion attempt.
class CompletionResponse {
  const CompletionResponse({required this.text, this.usage});

  /// The completed text.
  final String text;

  /// Provider-reported token usage, if any.
  final LlmUsage? usage;
}

/// Token usage as reported by the provider (nulls when unknown).
class LlmUsage {
  const LlmUsage({this.inputTokens, this.outputTokens});

  final int? inputTokens;
  final int? outputTokens;
}

/// What went wrong on an attempt, so the queue can decide what to do next.
enum LlmFailureKind {
  /// Transient — worth retrying with backoff (429, 5xx, timeout, network).
  transient,

  /// Permanent for this prompt — retrying will not help (400, auth).
  terminal,

  /// Provider asked us to slow down; [LlmFailure.retryAfter] may be set.
  rateLimited,
}

/// A failure surfaced by an [LlmEndpoint].
class LlmFailure implements Exception {
  const LlmFailure(this.kind, this.message, {this.retryAfter});

  final LlmFailureKind kind;
  final String message;

  /// Suggested minimum wait before the next attempt, parsed from e.g. a
  /// `Retry-After` header. Null when the provider did not say.
  final Duration? retryAfter;

  @override
  String toString() => 'LlmFailure($kind): $message';
}

/// The one interface `llm_outbox` needs from your LLM client.
///
/// Implement it over [llm_dart](https://pub.dev/packages/llm_dart),
/// [openai_dart](https://pub.dev/packages/openai_dart), or a raw HTTP call —
/// see `example/` for adapters. The queue retries and dead-letters; the
/// endpoint just performs one attempt.
abstract interface class LlmEndpoint {
  /// Performs a single completion attempt. Throw [LlmFailure] with the
  /// appropriate [LlmFailureKind] so the queue can classify the error.
  Future<CompletionResponse> complete(CompletionRequest request);
}
