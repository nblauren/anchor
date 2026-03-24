import 'package:anchor/data/models/chat_message.dart';
import 'package:equatable/equatable.dart';

/// Conversation model representing a chat between two users
class Conversation extends Equatable {
  const Conversation({
    required this.id,
    required this.participantId,
    required this.participantName,
    required this.createdAt, required this.updatedAt, this.participantPhotoUrl,
    this.lastMessage,
    this.unreadCount = 0,
  });

  final String id;
  final String participantId;
  final String participantName;
  final String? participantPhotoUrl;
  final ChatMessage? lastMessage;
  final int unreadCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation copyWith({
    String? id,
    String? participantId,
    String? participantName,
    String? participantPhotoUrl,
    ChatMessage? lastMessage,
    int? unreadCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      participantId: participantId ?? this.participantId,
      participantName: participantName ?? this.participantName,
      participantPhotoUrl: participantPhotoUrl ?? this.participantPhotoUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'participantId': participantId,
      'participantName': participantName,
      'participantPhotoUrl': participantPhotoUrl,
      'lastMessage': lastMessage?.toJson(),
      'unreadCount': unreadCount,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      participantId: json['participantId'] as String,
      participantName: json['participantName'] as String,
      participantPhotoUrl: json['participantPhotoUrl'] as String?,
      lastMessage: json['lastMessage'] != null
          ? ChatMessage.fromJson(json['lastMessage'] as Map<String, dynamic>)
          : null,
      unreadCount: json['unreadCount'] as int? ?? 0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  @override
  List<Object?> get props => [
        id,
        participantId,
        participantName,
        participantPhotoUrl,
        lastMessage,
        unreadCount,
        createdAt,
        updatedAt,
      ];
}
