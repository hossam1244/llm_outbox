/// Who authored a message.
enum MessageRole { user, assistant, system }

/// One message in a conversation transcript.
class Message {
  const Message({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    this.partial = false,
  });

  final String id;
  final MessageRole role;
  final String text;
  final DateTime at;

  /// True while (or after) a stream was interrupted mid-message.
  final bool partial;

  Message copyWith({String? text, bool? partial}) => Message(
        id: id,
        role: role,
        text: text ?? this.text,
        at: at,
        partial: partial ?? this.partial,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'at': at.toIso8601String(),
        'partial': partial,
      };

  factory Message.fromJson(Map<String, Object?> json) => Message(
        id: json['id']! as String,
        role: MessageRole.values.byName(json['role']! as String),
        text: json['text']! as String,
        at: DateTime.parse(json['at']! as String),
        partial: json['partial'] as bool? ?? false,
      );
}
