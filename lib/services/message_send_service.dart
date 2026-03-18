import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/utils/logger.dart';
import '../data/local_database/database.dart';
import '../data/repositories/chat_repository.dart';
import '../services/ble/ble.dart' as ble;
import '../services/image_service.dart';
import '../services/transport/transport.dart';

/// Delivery status update emitted by [MessageSendService].
class SendDeliveryUpdate {
  const SendDeliveryUpdate({
    required this.messageId,
    required this.status,
  });

  final String messageId;
  final MessageStatus status;
}

/// A pending outgoing photo registered for consent-first send.
class PendingPhoto {
  const PendingPhoto({
    required this.photoId,
    required this.localPhotoPath,
    required this.messageId,
    required this.peerId,
  });

  final String photoId;
  final String localPhotoPath;
  final String messageId;
  final String peerId;
}

/// FIFO message send queue extracted from ChatBloc.
///
/// Guarantees messages are sent in the order they were typed. Emits
/// [SendDeliveryUpdate]s so BLoCs can update UI state without blocking.
class MessageSendService {
  MessageSendService({
    required TransportManager transportManager,
    required ImageService imageService,
    required ChatRepository chatRepository,
    TransportRetryQueue? retryQueue,
  })  : _transportManager = transportManager,
        _imageService = imageService,
        _chatRepository = chatRepository,
        _retryQueue = retryQueue;

  final TransportManager _transportManager;
  final ImageService _imageService;
  final ChatRepository _chatRepository;
  final TransportRetryQueue? _retryQueue;

  final _deliveryController = StreamController<SendDeliveryUpdate>.broadcast();
  final _pendingPhotoController = StreamController<PendingPhoto>.broadcast();
  final _conversationsChangedController = StreamController<void>.broadcast();

  /// Delivery status updates for sent messages.
  Stream<SendDeliveryUpdate> get deliveryStream => _deliveryController.stream;

  /// Emitted when a pending outgoing photo is registered (for consent-first flow).
  Stream<PendingPhoto> get pendingPhotoStream => _pendingPhotoController.stream;

  /// Emitted when conversation list should be refreshed.
  Stream<void> get conversationsChangedStream =>
      _conversationsChangedController.stream;

  // FIFO send queue
  final List<Future<void> Function()> _sendQueue = [];
  bool _isProcessingQueue = false;

  /// True when the transport for [peerId] has enough bandwidth to send
  /// full-quality photos without BLE compression (LAN or Wi-Fi Aware).
  bool isHighBandwidthForPeer(String peerId) {
    final transport = _transportManager.transportForPeer(peerId) ??
        _transportManager.activeTransport;
    return transport == TransportType.lan ||
        transport == TransportType.wifiAware;
  }

  /// Enqueue a text message for background sending.
  void sendText(MessageEntry message, String peerId, {String? replyToId}) {
    _enqueueSend(() => _sendTextInBackground(message, peerId, replyToId: replyToId));
  }

  /// Enqueue a photo preview for background sending (compress + BLE preview).
  void sendPhoto({
    required String photoPath,
    required MessageEntry message,
    required String peerId,
  }) {
    _enqueueSend(() => _sendPhotoInBackground(
          photoPath: photoPath,
          message: message,
          peerId: peerId,
        ));
  }

  /// Enqueue a photo retry for background sending.
  void retryPhoto(MessageEntry message, String peerId) {
    _enqueueSend(() => _retryPhotoInBackground(message, peerId));
  }

  // ---------------------------------------------------------------------------
  // Background send helpers
  // ---------------------------------------------------------------------------

  Future<void> _sendTextInBackground(
    MessageEntry message,
    String peerId, {
    String? replyToId,
  }) async {
    try {
      final payload = ble.MessagePayload(
        messageId: message.id,
        type: ble.MessageType.text,
        content: message.textContent ?? '',
        replyToId: replyToId,
      );

      final success = await _transportManager.sendMessage(peerId, payload);
      if (success) {
        _emitDelivery(message.id, MessageStatus.sent);
        _conversationsChangedController.add(null);
        return;
      }

      // All transports failed — enqueue for retry when peer reconnects.
      final rq = _retryQueue;
      if (rq != null) {
        rq.enqueue(PendingSend(
          peerId: peerId,
          messageId: message.id,
          type: PendingSendType.text,
          payload: payload,
        ));
        // Leave status as pending — retry queue will update on success/failure.
      } else {
        _emitDelivery(message.id, MessageStatus.failed);
        _conversationsChangedController.add(null);
      }
    } catch (e) {
      Logger.error('Background text send failed', e, null, 'MessageSendService');
      _emitDelivery(message.id, MessageStatus.failed);
    }
  }

  Future<void> _sendPhotoInBackground({
    required String photoPath,
    required MessageEntry message,
    required String peerId,
  }) async {
    try {
      // 1. Compress photo for storage (chat quality, ~100-200 KB).
      final compressedPath = await _imageService.compressForChat(photoPath);
      final absolutePath =
          await resolvePhotoPath(compressedPath) ?? compressedPath;

      final int previewOriginalSize;
      if (isHighBandwidthForPeer(peerId)) {
        previewOriginalSize = await File(absolutePath).length();
      } else {
        previewOriginalSize =
            (await _imageService.compressForBleTransfer(absolutePath)).length;
      }

      // Persist the compressed relative path.
      await _chatRepository.updateMessagePhotoPath(message.id, compressedPath);

      // 2. Generate a stable UUID that links preview -> full-transfer.
      const uuidGen = Uuid();
      final photoId = uuidGen.v4();

      // 3. Persist photoId in the message row.
      await _chatRepository.updateMessagePhotoId(message.id, photoId);

      // Register pending outgoing photo via stream.
      _pendingPhotoController.add(PendingPhoto(
        photoId: photoId,
        localPhotoPath: absolutePath,
        messageId: message.id,
        peerId: peerId,
      ));

      // 4. Send lightweight notification (no thumbnail).
      final previewSent = await _transportManager.sendPhotoPreview(
        peerId: peerId,
        messageId: message.id,
        photoId: photoId,
        thumbnailBytes: Uint8List(0),
        originalSize: previewOriginalSize,
      );

      if (!previewSent) {
        _emitDelivery(message.id, MessageStatus.failed);
        _conversationsChangedController.add(null);
        return;
      }

      _emitDelivery(message.id, previewSent ? MessageStatus.sent : MessageStatus.failed);
      _conversationsChangedController.add(null);
    } catch (e) {
      Logger.error('Background photo send failed', e, null, 'MessageSendService');
      _emitDelivery(message.id, MessageStatus.failed);
    }
  }

  Future<void> _retryPhotoInBackground(
    MessageEntry message,
    String peerId,
  ) async {
    try {
      final absolutePath =
          await resolvePhotoPath(message.photoPath) ?? message.photoPath!;
      final bleBytes = isHighBandwidthForPeer(peerId)
          ? await File(absolutePath).readAsBytes()
          : await _imageService.compressForBleTransfer(absolutePath);
      const uuidGen = Uuid();
      final photoId = uuidGen.v4();

      _pendingPhotoController.add(PendingPhoto(
        photoId: photoId,
        localPhotoPath: absolutePath,
        messageId: message.id,
        peerId: peerId,
      ));

      final success = await _transportManager.sendPhotoPreview(
        peerId: peerId,
        messageId: message.id,
        photoId: photoId,
        thumbnailBytes: Uint8List(0),
        originalSize: bleBytes.length,
      );

      _emitDelivery(message.id, success ? MessageStatus.sent : MessageStatus.failed);
      _conversationsChangedController.add(null);
    } catch (e) {
      Logger.error('Background photo retry failed', e, null, 'MessageSendService');
      _emitDelivery(message.id, MessageStatus.failed);
    }
  }

  // ---------------------------------------------------------------------------
  // Queue management
  // ---------------------------------------------------------------------------

  void _enqueueSend(Future<void> Function() task) {
    _sendQueue.add(task);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    while (_sendQueue.isNotEmpty) {
      final task = _sendQueue.removeAt(0);
      try {
        await task();
      } catch (e) {
        Logger.error('Send queue task failed', e, null, 'MessageSendService');
      }
    }
    _isProcessingQueue = false;
  }

  void _emitDelivery(String messageId, MessageStatus status) {
    _deliveryController.add(SendDeliveryUpdate(
      messageId: messageId,
      status: status,
    ));
  }

  void dispose() {
    _deliveryController.close();
    _pendingPhotoController.close();
    _conversationsChangedController.close();
  }
}
