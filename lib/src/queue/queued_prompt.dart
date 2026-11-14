import '../endpoint/llm_endpoint.dart';

/// Lifecycle of a queued prompt.
enum PromptState {
  /// Persisted, waiting for its turn.
  pending,

  /// Currently being sent (restored prompts in this state were mid-flight
  /// during a crash and are retried on the next drain).
  sending,

  /// Sending failed and attempts remain — will be retried with backoff.
  failed,

  /// Max attempts exhausted; parked for inspection, never silently dropped.
  dead,

  /// Sent successfully and acknowledged.
  done,
}

/// One prompt inside the [PromptQueue], with its retry bookkeeping.
class QueuedPrompt {
  QueuedPrompt({
    required this.id,
    required this.request,
    required this.enqueuedAt,
    this.state = PromptState.pending,
    this.attempts = 0,
    this.maxAttempts = 3,
    this.lastError,
    this.lastAttemptAt,
    this.completedText,
  });

  final String id;
  final CompletionRequest request;
  final DateTime enqueuedAt;

  PromptState state;
  int attempts;
  int maxAttempts;

  /// Last failure message, kept for dead-letter inspection.
  String? lastError;
  DateTime? lastAttemptAt;

  /// Response text once sent successfully.
  String? completedText;

  bool get isRetryable =>
      state == PromptState.pending || state == PromptState.failed;

  QueuedPrompt copyWith(
          {PromptState? state,
          int? attempts,
          String? lastError,
          DateTime? lastAttemptAt,
          String? completedText}) =>
      QueuedPrompt(
        id: id,
        request: request,
        enqueuedAt: enqueuedAt,
        state: state ?? this.state,
        attempts: attempts ?? this.attempts,
        maxAttempts: maxAttempts,
        lastError: lastError ?? this.lastError,
        lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
        completedText: completedText ?? this.completedText,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'request': request.toJson(),
        'enqueuedAt': enqueuedAt.toIso8601String(),
        'state': state.name,
        'attempts': attempts,
        'maxAttempts': maxAttempts,
        'lastError': lastError,
        'lastAttemptAt': lastAttemptAt?.toIso8601String(),
        'completedText': completedText,
      };

  factory QueuedPrompt.fromJson(Map<String, Object?> json) => QueuedPrompt(
        id: json['id']! as String,
        request: CompletionRequest.fromJson(
            (json['request']! as Map<Object?, Object?>).cast()),
        enqueuedAt: DateTime.parse(json['enqueuedAt']! as String),
        state: PromptState.values.byName(json['state']! as String),
        attempts: json['attempts']! as int,
        maxAttempts: json['maxAttempts']! as int,
        lastError: json['lastError'] as String?,
        lastAttemptAt: json['lastAttemptAt'] == null
            ? null
            : DateTime.parse(json['lastAttemptAt']! as String),
        completedText: json['completedText'] as String?,
      );
}
