import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/chat_repository_interface.dart';
import 'package:anchor/data/repositories/peer_repository_interface.dart';
import 'package:anchor/services/ble/ble.dart' as ble;
import 'package:anchor/services/chat_event_bus.dart';
import 'package:anchor/services/notification_service.dart';
import 'package:anchor/services/transport/transport.dart';

/// Persistent service that saves incoming messages to the database regardless
/// of whether a chat screen is open.
///
/// Previously, messages were only persisted by [ChatBloc] — which meant any
/// message arriving while the chat screen was closed was silently dropped.
/// This service runs as a global singleton (registered in DI) and ensures
/// every incoming text message is saved, triggers notifications, and notifies
/// the [ChatEventBus] so any open UI can update.
class IncomingMessageService {
  IncomingMessageService({
    required TransportManager transportManager,
    required ChatRepositoryInterface chatRepository,
    required PeerRepositoryInterface peerRepository,
    required NotificationService notificationService,
    required ChatEventBus chatEventBus,
  })  : _transportManager = transportManager,
        _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _notificationService = notificationService,
        _chatEventBus = chatEventBus;

  final TransportManager _transportManager;
  final ChatRepositoryInterface _chatRepository;
  final PeerRepositoryInterface _peerRepository;
  final NotificationService _notificationService;
  final ChatEventBus _chatEventBus;

  StreamSubscription<ble.ReceivedMessage>? _messageSubscription;

  void start() {
    _messageSubscription?.cancel();
    _messageSubscription =
        _transportManager.messageReceivedStream.listen(_onMessage);
    Logger.info('IncomingMessageService: started', 'Chat');
  }

  Future<void> _onMessage(ble.ReceivedMessage msg) async {
    try {
      // Skip non-persistable types.
      if (msg.type == ble.MessageType.read ||
          msg.type == ble.MessageType.typing ||
          msg.type == ble.MessageType.wifiTransferReady) {
        return;
      }

      // Blocked peer check.
      if (await _peerRepository.isPeerBlocked(msg.fromPeerId)) return;

      // Get or create conversation.
      final conversation =
          await _chatRepository.getOrCreateConversation(msg.fromPeerId);

      // Save to database (returns null if duplicate).
      final message = await _chatRepository.receiveMessage(
        id: msg.messageId,
        conversationId: conversation.id,
        senderId: msg.fromPeerId,
        contentType: msg.type == ble.MessageType.text
            ? MessageContentType.text
            : MessageContentType.photo,
        textContent: msg.type == ble.MessageType.text ? msg.content : null,
        replyToMessageId: msg.replyToId,
      );

      if (message == null) return; // Duplicate — already in DB.

      Logger.info(
        'IncomingMessageService: persisted ${msg.type.name} from '
        '${msg.fromPeerId.substring(0, 8)}',
        'Chat',
      );

      // Show notification.
      final senderPeer =
          await _peerRepository.getPeerById(msg.fromPeerId);
      await _notificationService.showMessageNotification(
        fromPeerId: msg.fromPeerId,
        fromName: senderPeer?.name ?? 'Someone nearby',
        messagePreview: msg.type == ble.MessageType.text
            ? msg.content
            : 'Photo received',
      );

      // Notify ChatEventBus so any open ChatBloc / ConversationListBloc
      // can update in real time.
      _chatEventBus
        ..notifyMessageAdded(message)
        ..notifyConversationsChanged();
    } on Exception catch (e) {
      Logger.error(
          'IncomingMessageService: failed to persist message', e, null, 'Chat',);
    }
  }

  void dispose() {
    _messageSubscription?.cancel();
  }
}
