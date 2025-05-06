class MessageModel {
  final String id;
  final String content;
  final String senderId;
  final DateTime createdAt;
  final String conversationId;
  final String mediaType; // Added mediaType
  final String? mediaUrl; // Added mediaUrl, nullable

  MessageModel({
    required this.id,
    required this.content,
    required this.senderId,
    required this.createdAt,
    required this.conversationId,
    required this.mediaType,
    this.mediaUrl,
  });

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    String createdAtStr = json['created_at'] as String? ?? '';
    DateTime createdAt;
    try {
      createdAtStr = createdAtStr.replaceAll(' ', 'T');
      if (!createdAtStr.endsWith('Z') && !createdAtStr.contains('+')) {
        createdAtStr += 'Z';
      }
      createdAt = DateTime.parse(createdAtStr);
    } catch (e) {
      createdAt = DateTime.now();
    }

    return MessageModel(
      id: json['id'] as String? ?? '',
      content: json['content'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      createdAt: createdAt,
      conversationId: json['conversation_id'] as String? ?? '',
      mediaType: json['media_type'] as String? ?? 'text', // Default to 'text'
      mediaUrl: json['media_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'sender_id': senderId,
      'conversation_id': conversationId,
      'media_type': mediaType,
      'media_url': mediaUrl,
    };
  }
}