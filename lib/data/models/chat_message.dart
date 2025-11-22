import 'package:equatable/equatable.dart';

/// Chat message model for local storage and mesh transmission
class ChatMessage extends Equatable {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
    this.isDelivered = false,
    this.isRead = false,
    this.isSentByMe = false,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String receiverId;
  final String content;
  final DateTime timestamp;
  final bool isDelivered;
  final bool isRead;
  final bool isSentByMe;

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? receiverId,
    String? content,
    DateTime? timestamp,
    bool? isDelivered,
    bool? isRead,
    bool? isSentByMe,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isDelivered: isDelivered ?? this.isDelivered,
      isRead: isRead ?? this.isRead,
      isSentByMe: isSentByMe ?? this.isSentByMe,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'conversationId': conversationId,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isDelivered': isDelivered,
      'isRead': isRead,
      'isSentByMe': isSentByMe,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isDelivered: json['isDelivered'] as bool? ?? false,
      isRead: json['isRead'] as bool? ?? false,
      isSentByMe: json['isSentByMe'] as bool? ?? false,
    );
  }

  @override
  List<Object?> get props => [
        id,
        conversationId,
        senderId,
        receiverId,
        content,
        timestamp,
        isDelivered,
        isRead,
        isSentByMe,
      ];
}
