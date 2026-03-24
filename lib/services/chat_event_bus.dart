import 'dart:async';

import 'package:anchor/data/local_database/database.dart';

/// Lightweight event bus for inter-bloc communication in the chat feature.
///
/// BLoCs publish events here; other BLoCs subscribe. This decouples
/// [PhotoTransferBloc], [ReactionBloc], [ActiveChatBloc], and
/// [ConversationListBloc] without direct references between them.
class ChatEventBus {
  final _messageAdded = StreamController<MessageEntry>.broadcast();
  final _statusUpdated =
      StreamController<({String messageId, MessageStatus status})>.broadcast();
  final _conversationsChanged = StreamController<void>.broadcast();
  final _messageUpdated = StreamController<MessageEntry>.broadcast();

  /// A new message was added to a conversation (incoming or photo received).
  Stream<MessageEntry> get messageAdded => _messageAdded.stream;

  /// A message's delivery status was updated.
  Stream<({String messageId, MessageStatus status})> get statusUpdated =>
      _statusUpdated.stream;

  /// The conversation list needs to be refreshed.
  Stream<void> get conversationsChanged => _conversationsChanged.stream;

  /// A message was updated in-place (e.g. photo preview → full photo).
  Stream<MessageEntry> get messageUpdated => _messageUpdated.stream;

  void notifyMessageAdded(MessageEntry msg) => _messageAdded.add(msg);

  void notifyStatusUpdated(String messageId, MessageStatus status) =>
      _statusUpdated.add((messageId: messageId, status: status));

  void notifyConversationsChanged() => _conversationsChanged.add(null);

  void notifyMessageUpdated(MessageEntry msg) => _messageUpdated.add(msg);

  void dispose() {
    _messageAdded.close();
    _statusUpdated.close();
    _conversationsChanged.close();
    _messageUpdated.close();
  }
}
