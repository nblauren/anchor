import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';
import '../../../data/local_database/database.dart';
import '../../../data/repositories/chat_repository.dart';
import '../../../data/repositories/peer_repository.dart';
import '../../../services/ble/ble.dart' as ble;
import '../../../services/chat_event_bus.dart';
import '../../../services/encryption/encryption.dart';
import '../../../services/image_service.dart';
import '../../../services/message_send_service.dart';
import '../../../services/nearby/nearby.dart';
import '../../../services/notification_service.dart';
import '../../../services/transport/transport.dart';
import 'chat_state.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class PhotoTransferEvent extends Equatable {
  const PhotoTransferEvent();

  @override
  List<Object?> get props => [];
}

/// BLE photo transfer progress updated.
class PhotoProgressUpdated extends PhotoTransferEvent {
  const PhotoProgressUpdated(this.progress);
  final ble.PhotoTransferProgress progress;

  @override
  List<Object?> get props => [progress];
}

/// Incoming photo preview received from a peer.
class PhotoPreviewArrived extends PhotoTransferEvent {
  const PhotoPreviewArrived(this.preview);
  final ble.ReceivedPhotoPreview preview;

  @override
  List<Object?> get props => [preview];
}

/// User taps a preview thumbnail to request the full photo.
class RequestFullPhoto extends PhotoTransferEvent {
  const RequestFullPhoto({
    required this.messageId,
    required this.photoId,
    required this.peerId,
  });

  final String messageId;
  final String photoId;
  final String peerId;

  @override
  List<Object?> get props => [messageId, photoId, peerId];
}

/// Sender received a consent photo_request from the receiver.
class PhotoRequestArrived extends PhotoTransferEvent {
  const PhotoRequestArrived(this.request);
  final ble.ReceivedPhotoRequest request;

  @override
  List<Object?> get props => [request];
}

/// Cancel an in-progress photo transfer.
class CancelPhotoTransfer extends PhotoTransferEvent {
  const CancelPhotoTransfer(this.messageId);
  final String messageId;

  @override
  List<Object?> get props => [messageId];
}

/// Register a pending outgoing photo (from background send).
class RegisterPendingPhoto extends PhotoTransferEvent {
  const RegisterPendingPhoto({required this.photo});
  final PendingOutgoingPhoto photo;

  @override
  List<Object?> get props => [photo];
}

/// Nearby Connections transfer progress updated.
class NearbyProgressUpdated extends PhotoTransferEvent {
  const NearbyProgressUpdated(this.progress);
  final NearbyTransferProgress progress;

  @override
  List<Object?> get props => [progress];
}

/// A complete payload was received via Nearby Connections.
class NearbyPayloadArrived extends PhotoTransferEvent {
  const NearbyPayloadArrived(this.payload);
  final NearbyPayloadReceived payload;

  @override
  List<Object?> get props => [payload];
}

/// BLE signal: sender says Wi-Fi transfer is ready.
class WifiTransferReady extends PhotoTransferEvent {
  const WifiTransferReady({
    required this.fromPeerId,
    required this.transferId,
    this.senderNearbyId,
    this.isPreview = false,
    this.photoId,
    this.originalSize,
    this.messageId,
  });

  final String fromPeerId;
  final String transferId;
  final String? senderNearbyId;
  final bool isPreview;
  final String? photoId;
  final int? originalSize;
  final String? messageId;

  @override
  List<Object?> get props =>
      [fromPeerId, transferId, senderNearbyId, isPreview, photoId, originalSize, messageId];
}

/// Internal: a full photo was received via BLE stream listener.
class _BlePhotoReceived extends PhotoTransferEvent {
  const _BlePhotoReceived(this.photo);
  final ble.ReceivedPhoto photo;

  @override
  List<Object?> get props => [photo];
}

/// Internal: a preview was upgraded to a full photo.
class _PreviewUpgraded extends PhotoTransferEvent {
  const _PreviewUpgraded({
    required this.previewMessageId,
    required this.updatedMessage,
  });

  final String previewMessageId;
  final MessageEntry updatedMessage;

  @override
  List<Object?> get props => [previewMessageId, updatedMessage];
}

/// Peer went out of range — cancel active downloads from them.
class PhotoPeerLost extends PhotoTransferEvent {
  const PhotoPeerLost(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// Peer ID changed due to MAC rotation — update transfer mappings.
class PhotoPeerIdMigrated extends PhotoTransferEvent {
  const PhotoPeerIdMigrated({
    required this.oldPeerId,
    required this.newPeerId,
  });

  final String oldPeerId;
  final String newPeerId;

  @override
  List<Object?> get props => [oldPeerId, newPeerId];
}

/// Reset transfer state (e.g. when conversation is closed).
class ClearPhotoTransfers extends PhotoTransferEvent {
  const ClearPhotoTransfers();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class PhotoTransferState extends Equatable {
  const PhotoTransferState({
    this.photoTransfers = const {},
    this.pendingOutgoingPhotos = const {},
  });

  final Map<String, PhotoTransferInfo> photoTransfers;
  final Map<String, PendingOutgoingPhoto> pendingOutgoingPhotos;

  PhotoTransferInfo? getTransferProgress(String messageId) =>
      photoTransfers[messageId];

  PhotoTransferState copyWith({
    Map<String, PhotoTransferInfo>? photoTransfers,
    Map<String, PendingOutgoingPhoto>? pendingOutgoingPhotos,
  }) {
    return PhotoTransferState(
      photoTransfers: photoTransfers ?? this.photoTransfers,
      pendingOutgoingPhotos:
          pendingOutgoingPhotos ?? this.pendingOutgoingPhotos,
    );
  }

  @override
  List<Object?> get props => [photoTransfers, pendingOutgoingPhotos];
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages photo transfer progress, pending outgoing photos, and all
/// photo-related transport events (BLE, Wi-Fi Direct, Nearby Connections).
///
/// Communicates with ChatBloc via [ChatEventBus] when messages are
/// created, updated, or when the conversations list needs refreshing.
class PhotoTransferBloc
    extends Bloc<PhotoTransferEvent, PhotoTransferState> {
  PhotoTransferBloc({
    required ChatRepository chatRepository,
    required PeerRepository peerRepository,
    required ImageService imageService,
    required TransportManager transportManager,
    required NotificationService notificationService,
    required ChatEventBus chatEventBus,
    required MessageSendService messageSendService,
    String? ownUserId,
    HighSpeedTransferService? highSpeedTransferService,
    EncryptionService? encryptionService,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _imageService = imageService,
        _transportManager = transportManager,
        _notificationService = notificationService,
        _chatEventBus = chatEventBus,
        _messageSendService = messageSendService,
        _highSpeedService = highSpeedTransferService,
        _encryptionService = encryptionService,
        super(const PhotoTransferState()) {
    on<PhotoProgressUpdated>(_onPhotoTransferProgress);
    on<PhotoPreviewArrived>(_onPhotoPreviewReceived);
    on<RequestFullPhoto>(_onRequestFullPhoto);
    on<PhotoRequestArrived>(_onPhotoRequestReceived);
    on<CancelPhotoTransfer>(_onCancelPhotoTransfer);
    on<RegisterPendingPhoto>(_onRegisterPendingPhoto);
    on<NearbyProgressUpdated>(_onNearbyTransferProgress);
    on<NearbyPayloadArrived>(_onNearbyPayloadCompleted);
    on<WifiTransferReady>(_onWifiTransferReady);
    on<_BlePhotoReceived>(_onBlePhotoReceived);
    on<_PreviewUpgraded>(_onPreviewUpgraded);
    on<PhotoPeerLost>(_onPhotoPeerLost);
    on<PhotoPeerIdMigrated>(_onPhotoPeerIdMigrated);
    on<ClearPhotoTransfers>(_onClearPhotoTransfers);

    // Subscribe to transport manager photo streams.
    _photoProgressSub = _transportManager.photoProgressStream.listen(
      (progress) => add(PhotoProgressUpdated(progress)),
    );
    _photoReceivedSub = _transportManager.photoReceivedStream.listen(
      (photo) => add(_BlePhotoReceived(photo)),
    );
    _photoPreviewSub = _transportManager.photoPreviewReceivedStream.listen(
      (preview) => add(PhotoPreviewArrived(preview)),
    );
    _photoRequestSub = _transportManager.photoRequestReceivedStream.listen(
      (request) => add(PhotoRequestArrived(request)),
    );

    // Nearby / Wi-Fi Direct: initialize and subscribe to streams.
    final highSpeed = _highSpeedService;
    if (highSpeed != null) {
      highSpeed.initialize(ownUserId: ownUserId ?? '').then((_) {
        Logger.info('HighSpeedTransferService initialized', 'PhotoTransfer');
      }).catchError((e) {
        Logger.warning('HighSpeedTransferService init deferred: $e', 'PhotoTransfer');
      });

      _nearbyProgressSub = highSpeed.transferProgressStream.listen(
        (progress) => add(NearbyProgressUpdated(progress)),
      );
      _nearbyPayloadSub = highSpeed.payloadReceivedStream.listen(
        (payload) => add(NearbyPayloadArrived(payload)),
      );
    }

    // Subscribe to pending outgoing photos from MessageSendService.
    _pendingPhotoSub = _messageSendService.pendingPhotoStream.listen((photo) {
      if (!isClosed) {
        add(RegisterPendingPhoto(
          photo: PendingOutgoingPhoto(
            photoId: photo.photoId,
            localPhotoPath: photo.localPhotoPath,
            messageId: photo.messageId,
            peerId: photo.peerId,
          ),
        ));
      }
    });

    // Subscribe to general message stream for wifiTransferReady signals.
    _wifiReadySub = _transportManager.messageReceivedStream.listen((msg) {
      if (msg.type != ble.MessageType.wifiTransferReady) return;
      try {
        final parsed = jsonDecode(msg.content) as Map<String, dynamic>;
        final transferId = parsed['transfer_id'] as String? ?? msg.content;
        final senderNearbyId = parsed['sender_nearby_id'] as String?;

        if (parsed['is_preview'] == true) {
          add(WifiTransferReady(
            fromPeerId: msg.fromPeerId,
            transferId: transferId,
            senderNearbyId: senderNearbyId,
            isPreview: true,
            photoId: parsed['photo_id'] as String?,
            originalSize: parsed['original_size'] as int?,
            messageId: parsed['message_id'] as String?,
          ));
        } else {
          add(WifiTransferReady(
            fromPeerId: msg.fromPeerId,
            transferId: transferId,
            senderNearbyId: senderNearbyId,
          ));
        }
      } catch (_) {
        add(WifiTransferReady(
          fromPeerId: msg.fromPeerId,
          transferId: msg.content,
        ));
      }
    });
  }

  final ChatRepository _chatRepository;
  final PeerRepository _peerRepository;
  final ImageService _imageService;
  final TransportManager _transportManager;
  final NotificationService _notificationService;
  final ChatEventBus _chatEventBus;
  final MessageSendService _messageSendService;
  final HighSpeedTransferService? _highSpeedService;
  final EncryptionService? _encryptionService;

  StreamSubscription<ble.PhotoTransferProgress>? _photoProgressSub;
  StreamSubscription<ble.ReceivedPhoto>? _photoReceivedSub;
  StreamSubscription<ble.ReceivedPhotoPreview>? _photoPreviewSub;
  StreamSubscription<ble.ReceivedPhotoRequest>? _photoRequestSub;
  StreamSubscription<NearbyTransferProgress>? _nearbyProgressSub;
  StreamSubscription<NearbyPayloadReceived>? _nearbyPayloadSub;
  StreamSubscription<ble.ReceivedMessage>? _wifiReadySub;
  StreamSubscription? _pendingPhotoSub;

  /// Photo download timeout timers (keyed by messageId).
  final Map<String, Timer> _photoDownloadTimers = {};

  /// Metadata from BLE signal for pending Wi-Fi Direct preview transfers.
  /// Keyed by photoId (without 'preview-' prefix).
  final Map<String, Map<String, dynamic>> _pendingPreviewMeta = {};

  /// Maps Nearby transferId → BLE device ID so payload handler can resolve
  /// the correct conversation.
  final Map<String, String> _transferToBleId = {};

  /// The peer name for the currently active conversation — set by the UI
  /// for notification display.
  String? activePeerName;

  /// The peerId for the currently active conversation — set by the UI.
  String? activePeerId;

  /// Whether the transport for [peerId] supports high-bandwidth transfers.
  bool _isHighBandwidthForPeer(String peerId) {
    final transport = _transportManager.transportForPeer(peerId) ??
        _transportManager.activeTransport;
    return transport == TransportType.lan ||
        transport == TransportType.wifiAware;
  }

  // ---------------------------------------------------------------------------
  // BLE photo transfer progress
  // ---------------------------------------------------------------------------

  void _onPhotoTransferProgress(
    PhotoProgressUpdated event,
    Emitter<PhotoTransferState> emit,
  ) {
    final progress = event.progress;
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers);

    if (progress.status == ble.PhotoTransferStatus.completed) {
      _photoDownloadTimers.remove(progress.messageId)?.cancel();
      updatedTransfers.remove(progress.messageId);
      _chatEventBus.notifyStatusUpdated(
          progress.messageId, MessageStatus.sent);
    } else if (progress.status == ble.PhotoTransferStatus.failed ||
        progress.status == ble.PhotoTransferStatus.cancelled) {
      _photoDownloadTimers.remove(progress.messageId)?.cancel();
      updatedTransfers.remove(progress.messageId);
      _chatEventBus.notifyStatusUpdated(
          progress.messageId, MessageStatus.failed);
    } else {
      updatedTransfers[progress.messageId] = PhotoTransferInfo(
        messageId: progress.messageId,
        progress: progress.progress,
        isSending: true,
      );
    }

    emit(state.copyWith(photoTransfers: updatedTransfers));
  }

  // ---------------------------------------------------------------------------
  // Photo preview received (receiver side)
  // ---------------------------------------------------------------------------

  Future<void> _onPhotoPreviewReceived(
    PhotoPreviewArrived event,
    Emitter<PhotoTransferState> emit,
  ) async {
    try {
      final preview = event.preview;

      if (await _peerRepository.isPeerBlocked(preview.fromPeerId)) return;

      final conversation =
          await _chatRepository.getOrCreateConversation(preview.fromPeerId);

      final String? thumbnailPath = preview.thumbnailBytes.isNotEmpty
          ? await _imageService.saveChatThumbnail(preview.thumbnailBytes)
          : null;

      final metadata = jsonEncode({
        'photo_id': preview.photoId,
        'original_size': preview.originalSize,
      });

      final message = await _chatRepository.receivePhotoPreview(
        id: preview.messageId,
        conversationId: conversation.id,
        senderId: preview.fromPeerId,
        textContent: metadata,
        thumbnailPath: thumbnailPath,
      );

      final previewSender =
          await _peerRepository.getPeerById(preview.fromPeerId);
      await _notificationService.showMessageNotification(
        fromPeerId: preview.fromPeerId,
        fromName: previewSender?.name ?? activePeerName ?? 'Someone nearby',
        messagePreview:
            'Photo (${preview.formattedOriginalSize}) – Tap to download',
      );

      // Notify ChatBloc to add the message to the UI.
      _chatEventBus.notifyMessageAdded(message);
      _chatEventBus.notifyConversationsChanged();
    } catch (e) {
      Logger.error('Failed to handle photo preview', e, null, 'PhotoTransfer');
    }
  }

  // ---------------------------------------------------------------------------
  // Request full photo (receiver taps thumbnail)
  // ---------------------------------------------------------------------------

  Future<void> _onRequestFullPhoto(
    RequestFullPhoto event,
    Emitter<PhotoTransferState> emit,
  ) async {
    try {
      _chatEventBus.notifyStatusUpdated(event.messageId, MessageStatus.pending);

      final updatedTransfers =
          Map<String, PhotoTransferInfo>.from(state.photoTransfers);
      updatedTransfers[event.messageId] = PhotoTransferInfo(
        messageId: event.messageId,
        progress: 0,
        isSending: false,
      );
      emit(state.copyWith(photoTransfers: updatedTransfers));

      final requestMsgId = const Uuid().v4();
      final success = await _transportManager.sendPhotoRequest(
        peerId: event.peerId,
        messageId: requestMsgId,
        photoId: event.photoId,
      );

      if (!success) {
        _photoDownloadTimers.remove(event.messageId)?.cancel();
        _chatEventBus.notifyStatusUpdated(
            event.messageId, MessageStatus.delivered);
        final revertedTransfers =
            Map<String, PhotoTransferInfo>.from(state.photoTransfers)
              ..remove(event.messageId);
        emit(state.copyWith(photoTransfers: revertedTransfers));
      } else {
        _photoDownloadTimers[event.messageId]?.cancel();
        _photoDownloadTimers[event.messageId] = Timer(
          const Duration(seconds: 45),
          () {
            if (!isClosed &&
                state.photoTransfers.containsKey(event.messageId)) {
              Logger.warning(
                'PhotoTransferBloc: Photo download timed out for ${event.messageId}',
                'PhotoTransfer',
              );
              _cancelPhotoDownload(event.messageId);
            }
          },
        );
      }
    } catch (e) {
      Logger.error('Failed to send photo request', e, null, 'PhotoTransfer');
    }
  }

  // ---------------------------------------------------------------------------
  // Photo request received (sender side — consent to send full photo)
  // ---------------------------------------------------------------------------

  Future<void> _onPhotoRequestReceived(
    PhotoRequestArrived event,
    Emitter<PhotoTransferState> emit,
  ) async {
    try {
      final request = event.request;
      var pending = state.pendingOutgoingPhotos[request.photoId];

      if (pending == null) {
        final storedMessage =
            await _chatRepository.findMessageByPhotoId(request.photoId);
        if (storedMessage == null || storedMessage.photoPath == null) {
          Logger.warning(
            'PhotoTransferBloc: photo_request for unknown photoId ${request.photoId} — not found in DB',
            'PhotoTransfer',
          );
          return;
        }
        pending = PendingOutgoingPhoto(
          photoId: request.photoId,
          localPhotoPath: storedMessage.photoPath!,
          messageId: storedMessage.id,
          peerId: request.fromPeerId,
        );
        Logger.info(
          'PhotoTransferBloc: Recovered photo ${request.photoId} from DB for re-send',
          'PhotoTransfer',
        );
      }

      Logger.info(
        'PhotoTransferBloc: Sending full photo for ${request.photoId}',
        'PhotoTransfer',
      );

      final updatedPending =
          Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos)
            ..remove(request.photoId);
      emit(state.copyWith(pendingOutgoingPhotos: updatedPending));

      final Uint8List photoBytes;
      if (_isHighBandwidthForPeer(request.fromPeerId)) {
        final absolutePath =
            await resolvePhotoPath(pending.localPhotoPath) ??
                pending.localPhotoPath;
        photoBytes = await File(absolutePath).readAsBytes();
      } else {
        final absolutePath =
            await resolvePhotoPath(pending.localPhotoPath) ??
                pending.localPhotoPath;
        photoBytes =
            await _imageService.compressForBleTransfer(absolutePath);
      }

      // Fire-and-forget: run in background so we don't block the event queue.
      _sendFullPhoto(
        request: request,
        pending: pending,
        photoBytes: photoBytes,
      );
    } catch (e) {
      Logger.error('Failed to handle photo request', e, null, 'PhotoTransfer');
    }
  }

  Future<void> _sendFullPhoto({
    required ble.ReceivedPhotoRequest request,
    required PendingOutgoingPhoto pending,
    required Uint8List photoBytes,
  }) async {
    try {
      final success = await _transportManager.sendPhoto(
        request.fromPeerId,
        photoBytes,
        pending.messageId,
        photoId: request.photoId,
      );

      if (success) {
        _chatEventBus.notifyStatusUpdated(
            pending.messageId, MessageStatus.read);
      } else {
        Logger.warning(
          'PhotoTransferBloc: Photo send failed for ${request.photoId}',
          'PhotoTransfer',
        );
      }
    } catch (e) {
      Logger.error('_sendFullPhoto failed', e, null, 'PhotoTransfer');
    }
  }

  // ---------------------------------------------------------------------------
  // Cancel photo transfer
  // ---------------------------------------------------------------------------

  Future<void> _onCancelPhotoTransfer(
    CancelPhotoTransfer event,
    Emitter<PhotoTransferState> emit,
  ) async {
    await _transportManager.cancelPhotoTransfer(event.messageId);
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers)
          ..remove(event.messageId);
    emit(state.copyWith(photoTransfers: updatedTransfers));
  }

  void _cancelPhotoDownload(String messageId) {
    _photoDownloadTimers.remove(messageId)?.cancel();
    add(CancelPhotoTransfer(messageId));
    _chatEventBus.notifyStatusUpdated(messageId, MessageStatus.delivered);
  }

  // ---------------------------------------------------------------------------
  // Register pending outgoing photo
  // ---------------------------------------------------------------------------

  void _onRegisterPendingPhoto(
    RegisterPendingPhoto event,
    Emitter<PhotoTransferState> emit,
  ) {
    final updatedPending =
        Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
    updatedPending[event.photo.photoId] = event.photo;
    emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
  }

  // ---------------------------------------------------------------------------
  // BLE photo received (stream listener → event)
  // ---------------------------------------------------------------------------

  Future<void> _onBlePhotoReceived(
    _BlePhotoReceived event,
    Emitter<PhotoTransferState> emit,
  ) async {
    try {
      final photo = event.photo;
      if (await _peerRepository.isPeerBlocked(photo.fromPeerId)) return;

      final conversation =
          await _chatRepository.getOrCreateConversation(photo.fromPeerId);

      final photoPath =
          await _imageService.saveReceivedPhoto(photo.photoBytes);

      // Find preview message by photoId in the DB.
      final matchId = photo.photoId ?? photo.messageId;
      final previewMsg = await _chatRepository.findPreviewByPhotoId(matchId);

      if (previewMsg != null) {
        final upgraded = await _chatRepository.upgradePreviewToPhoto(
          messageId: previewMsg.id,
          fullPhotoPath: photoPath,
        );
        add(_PreviewUpgraded(
          previewMessageId: previewMsg.id,
          updatedMessage: upgraded ?? previewMsg,
        ));
      } else {
        final message = await _chatRepository.receiveMessage(
          conversationId: conversation.id,
          senderId: photo.fromPeerId,
          contentType: MessageContentType.photo,
          photoPath: photoPath,
        );
        _chatEventBus.notifyMessageAdded(message);
      }

      Logger.info(
        'PhotoTransferBloc: Received full photo from ${photo.fromPeerId.substring(0, 8)}',
        'PhotoTransfer',
      );
    } catch (e) {
      Logger.error('Failed to handle BLE photo', e, null, 'PhotoTransfer');
    }
  }

  // ---------------------------------------------------------------------------
  // Preview → full photo upgrade
  // ---------------------------------------------------------------------------

  void _onPreviewUpgraded(
    _PreviewUpgraded event,
    Emitter<PhotoTransferState> emit,
  ) {
    _photoDownloadTimers.remove(event.previewMessageId)?.cancel();
    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers)
          ..remove(event.previewMessageId);
    emit(state.copyWith(photoTransfers: updatedTransfers));

    // Notify ChatBloc to swap the message in its messages list.
    _chatEventBus.notifyMessageUpdated(event.updatedMessage);
  }

  // ---------------------------------------------------------------------------
  // Wi-Fi Direct / Nearby handlers
  // ---------------------------------------------------------------------------

  void _onNearbyTransferProgress(
    NearbyProgressUpdated event,
    Emitter<PhotoTransferState> emit,
  ) {
    final progress = event.progress;

    String? messageId;
    for (final pending in state.pendingOutgoingPhotos.values) {
      if (pending.photoId == progress.transferId) {
        messageId = pending.messageId;
        break;
      }
    }

    messageId ??= state.photoTransfers.keys.where((key) {
      final info = state.photoTransfers[key];
      return info != null && info.transport == TransportType.wifiDirect;
    }).firstOrNull;

    if (messageId == null) return;

    final updatedTransfers =
        Map<String, PhotoTransferInfo>.from(state.photoTransfers);

    if (progress.isComplete || progress.isFailed) {
      updatedTransfers.remove(messageId);
      if (progress.isComplete) {
        _chatEventBus.notifyStatusUpdated(messageId, MessageStatus.sent);
      }
    } else {
      updatedTransfers[messageId] = PhotoTransferInfo(
        messageId: messageId,
        progress: progress.progress,
        isSending: true,
        transport: TransportType.wifiDirect,
      );
    }

    emit(state.copyWith(photoTransfers: updatedTransfers));
  }

  Future<void> _onNearbyPayloadCompleted(
    NearbyPayloadArrived event,
    Emitter<PhotoTransferState> emit,
  ) async {
    try {
      final payload = event.payload;

      final bleDeviceId =
          _transferToBleId.remove(payload.transferId) ?? payload.fromPeerId;

      if (await _peerRepository.isPeerBlocked(bleDeviceId)) return;

      // ── Preview / thumbnail transfer ──────────────────────────────────
      if (payload.transferId.startsWith('preview-')) {
        final photoId = payload.transferId.substring('preview-'.length);
        Logger.info(
          'PhotoTransferBloc: Received thumbnail via Wi-Fi Direct for $photoId',
          'PhotoTransfer',
        );

        final conversation =
            await _chatRepository.getOrCreateConversation(bleDeviceId);

        final thumbnailPath =
            await _imageService.saveChatThumbnail(payload.data);

        final originalSize =
            _pendingPreviewMeta[photoId]?['original_size'] as int? ??
                payload.data.length;
        _pendingPreviewMeta.remove(photoId);

        final metadata = jsonEncode({
          'photo_id': photoId,
          'original_size': originalSize,
        });

        final message = await _chatRepository.receivePhotoPreview(
          conversationId: conversation.id,
          senderId: bleDeviceId,
          textContent: metadata,
          thumbnailPath: thumbnailPath,
        );

        final wifiSender = await _peerRepository.getPeerById(bleDeviceId);
        await _notificationService.showMessageNotification(
          fromPeerId: bleDeviceId,
          fromName: wifiSender?.name ?? activePeerName ?? 'Someone nearby',
          messagePreview: 'Photo – Tap to download',
        );

        _chatEventBus.notifyMessageAdded(message);
        _chatEventBus.notifyConversationsChanged();
        return;
      }

      // ── Full photo transfer ───────────────────────────────────────────
      final conversation =
          await _chatRepository.getOrCreateConversation(bleDeviceId);

      Uint8List photoBytes = payload.data;
      if (photoBytes.length > 25 && photoBytes[0] == 0x01) {
        final enc = _encryptionService;
        if (enc != null) {
          final decrypted = await enc.decryptBytes(
            bleDeviceId,
            EncryptedPayload(
              nonce: photoBytes.sublist(1, 25),
              ciphertext: photoBytes.sublist(25),
            ),
          );
          if (decrypted != null) photoBytes = decrypted;
        }
      }

      final photoPath = await _imageService.saveReceivedPhoto(photoBytes);

      final previewMsg =
          await _chatRepository.findPreviewByPhotoId(payload.transferId);

      if (previewMsg != null) {
        final upgraded = await _chatRepository.upgradePreviewToPhoto(
          messageId: previewMsg.id,
          fullPhotoPath: photoPath,
        );
        add(_PreviewUpgraded(
          previewMessageId: previewMsg.id,
          updatedMessage: upgraded ?? previewMsg,
        ));
      } else {
        final message = await _chatRepository.receiveMessage(
          conversationId: conversation.id,
          senderId: bleDeviceId,
          contentType: MessageContentType.photo,
          photoPath: photoPath,
        );
        _chatEventBus.notifyMessageAdded(message);
      }

      Logger.info(
        'PhotoTransferBloc: Received photo via Wi-Fi Direct from ${bleDeviceId.substring(0, 8)}',
        'PhotoTransfer',
      );
    } catch (e) {
      Logger.error(
          'Failed to handle Nearby payload', e, null, 'PhotoTransfer');
    }
  }

  Future<void> _onWifiTransferReady(
    WifiTransferReady event,
    Emitter<PhotoTransferState> emit,
  ) async {
    final hsService = _highSpeedService;
    if (hsService == null) return;

    Logger.info(
      'PhotoTransferBloc: Wi-Fi transfer ready from ${event.fromPeerId} '
      'for ${event.transferId} (preview=${event.isPreview})',
      'PhotoTransfer',
    );

    _transferToBleId[event.transferId] = event.fromPeerId;

    if (event.isPreview) {
      if (event.photoId != null) {
        _pendingPreviewMeta[event.photoId!] = {
          'original_size': event.originalSize ?? 0,
          'message_id': event.messageId,
        };
      }
    } else {
      final previewMsg =
          await _chatRepository.findPreviewByPhotoId(event.transferId);

      if (previewMsg != null) {
        final updatedTransfers =
            Map<String, PhotoTransferInfo>.from(state.photoTransfers);
        updatedTransfers[previewMsg.id] = PhotoTransferInfo(
          messageId: previewMsg.id,
          progress: 0,
          isSending: false,
          transport: TransportType.wifiDirect,
        );
        emit(state.copyWith(photoTransfers: updatedTransfers));
      }
    }

    hsService
        .receivePayload(
      transferId: event.transferId,
      peerId: event.senderNearbyId ?? event.fromPeerId,
    )
        .then((success) {
      if (!success) {
        Logger.warning(
          'PhotoTransferBloc: Wi-Fi receive failed for ${event.transferId}',
          'PhotoTransfer',
        );
      }
    }).catchError((e) {
      Logger.error('PhotoTransferBloc: Wi-Fi receive error', e, null,
          'PhotoTransfer');
    });
  }

  // ---------------------------------------------------------------------------
  // Peer loss / migration
  // ---------------------------------------------------------------------------

  void _onPhotoPeerLost(
    PhotoPeerLost event,
    Emitter<PhotoTransferState> emit,
  ) {
    if (activePeerId != event.peerId) return;

    final transfersToCancel = <String>[];
    for (final entry in state.photoTransfers.entries) {
      if (!entry.value.isSending) {
        transfersToCancel.add(entry.key);
      }
    }

    if (transfersToCancel.isEmpty) return;

    for (final messageId in transfersToCancel) {
      _cancelPhotoDownload(messageId);
    }

    Logger.info(
      'PhotoTransferBloc: Cancelled ${transfersToCancel.length} photo download(s) — '
      'peer ${event.peerId.substring(0, 8)} lost',
      'PhotoTransfer',
    );
  }

  void _onPhotoPeerIdMigrated(
    PhotoPeerIdMigrated event,
    Emitter<PhotoTransferState> emit,
  ) {
    // Update pending outgoing photos targeting the old peerId.
    final updatedPending =
        Map<String, PendingOutgoingPhoto>.from(state.pendingOutgoingPhotos);
    var changed = false;
    for (final entry in updatedPending.entries.toList()) {
      if (entry.value.peerId == event.oldPeerId) {
        updatedPending[entry.key] = PendingOutgoingPhoto(
          photoId: entry.value.photoId,
          localPhotoPath: entry.value.localPhotoPath,
          messageId: entry.value.messageId,
          peerId: event.newPeerId,
        );
        changed = true;
      }
    }
    if (changed) {
      emit(state.copyWith(pendingOutgoingPhotos: updatedPending));
    }

    // Update transferToBleId mappings.
    for (final entry in _transferToBleId.entries.toList()) {
      if (entry.value == event.oldPeerId) {
        _transferToBleId[entry.key] = event.newPeerId;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Clear state
  // ---------------------------------------------------------------------------

  void _onClearPhotoTransfers(
    ClearPhotoTransfers event,
    Emitter<PhotoTransferState> emit,
  ) {
    for (final timer in _photoDownloadTimers.values) {
      timer.cancel();
    }
    _photoDownloadTimers.clear();
    emit(const PhotoTransferState());
  }

  @override
  Future<void> close() {
    _photoProgressSub?.cancel();
    _photoReceivedSub?.cancel();
    _photoPreviewSub?.cancel();
    _photoRequestSub?.cancel();
    _nearbyProgressSub?.cancel();
    _nearbyPayloadSub?.cancel();
    _wifiReadySub?.cancel();
    _pendingPhotoSub?.cancel();
    for (final timer in _photoDownloadTimers.values) {
      timer.cancel();
    }
    _photoDownloadTimers.clear();
    return super.close();
  }
}
