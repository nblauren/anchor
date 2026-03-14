import 'dart:async';

import '../core/constants/app_constants.dart';
import '../core/utils/logger.dart';
import '../data/local_database/database.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/peer_repository.dart';
import '../data/repositories/profile_repository.dart';
import 'ble/ble_models.dart' as ble;
import 'transport/transport_manager.dart';

/// Persists outgoing text messages across sessions and retries delivery
/// whenever the target peer is (re)discovered via BLE/Wi-Fi Aware.
///
/// Flow:
///   1. On app startup, [initialize] expires stale messages (> 24 h old) and
///      subscribes to [TransportManager.peerDiscoveredStream].
///   2. When a peer appears, [_retryPendingForPeer] queries the DB for
///      pending/failed text messages in that conversation and attempts
///      re-delivery sequentially via [TransportManager.sendMessage].
///   3. [messageStatusStream] emits [MessageDeliveryUpdate] events so that any
///      open [ChatBloc] can update its in-memory state immediately.
///
/// Only text messages are retried; photo retries require re-sending a BLE
/// preview notification which is managed separately by [ChatBloc].
class StoreAndForwardService {
  StoreAndForwardService({
    required ChatRepository chatRepository,
    required PeerRepository peerRepository,
    required ProfileRepository profileRepository,
    required TransportManager transportManager,
  })  : _chatRepository = chatRepository,
        _peerRepository = peerRepository,
        _profileRepository = profileRepository,
        _transportManager = transportManager;

  final ChatRepository _chatRepository;
  final PeerRepository _peerRepository;
  final ProfileRepository _profileRepository;
  final TransportManager _transportManager;

  String? _ownUserId;
  bool _initialized = false;

  StreamSubscription<ble.DiscoveredPeer>? _peerDiscoveredSub;

  /// Peer IDs for which a retry wave is currently in-flight this session.
  /// Prevents duplicate concurrent retry attempts for the same peer.
  final Set<String> _inFlightPeerIds = {};

  final _messageStatusController =
      StreamController<MessageDeliveryUpdate>.broadcast();

  /// Emits whenever a queued message is successfully delivered or permanently
  /// fails. Open [ChatBloc] instances subscribe to refresh their UI state.
  Stream<MessageDeliveryUpdate> get messageStatusStream =>
      _messageStatusController.stream;

  /// Initialise the service. Safe to call multiple times — subsequent calls
  /// are no-ops after the first successful initialisation.
  ///
  /// If no profile exists yet (first launch before onboarding), returns
  /// without error and can be retried later via another [initialize] call.
  Future<void> initialize() async {
    if (_initialized) return;

    final profile = await _profileRepository.getProfile();
    if (profile == null) {
      Logger.info(
        'StoreAndForward: No profile found, deferring init',
        'StoreForward',
      );
      return;
    }

    _ownUserId = profile.id;
    _initialized = true;

    // Expire messages that are too old to be worth retrying.
    await _chatRepository.expireStaleOutgoingMessages(
      _ownUserId!,
      const Duration(hours: AppConstants.messageRetryWindowHours),
    );

    _peerDiscoveredSub =
        _transportManager.peerDiscoveredStream.listen((peer) {
      _onPeerDiscovered(peer.peerId);
    });

    Logger.info(
      'StoreAndForward: Initialized for user ${_ownUserId!.substring(0, 8)}',
      'StoreForward',
    );
  }

  Future<void> dispose() async {
    await _peerDiscoveredSub?.cancel();
    await _messageStatusController.close();
  }

  // ==================== Private ====================

  void _onPeerDiscovered(String peerId) {
    if (_ownUserId == null) return;
    if (_inFlightPeerIds.contains(peerId)) return;
    _inFlightPeerIds.add(peerId);
    _retryPendingForPeer(peerId).whenComplete(
      () => _inFlightPeerIds.remove(peerId),
    );
  }

  Future<void> _retryPendingForPeer(String peerId) async {
    final ownId = _ownUserId;
    if (ownId == null) return;

    try {
      if (await _peerRepository.isPeerBlocked(peerId)) return;

      final conversation =
          await _chatRepository.getConversationByPeerId(peerId);
      if (conversation == null) return;

      final messages = await _chatRepository.getPendingOutgoingMessages(
        ownUserId: ownId,
        conversationId: conversation.id,
      );

      if (messages.isEmpty) return;

      Logger.info(
        'StoreAndForward: Retrying ${messages.length} message(s) '
        'for peer ${peerId.substring(0, 8)}',
        'StoreForward',
      );

      for (final message in messages) {
        await _retrySingleMessage(message, peerId);
      }
    } catch (e) {
      Logger.error(
        'StoreAndForward: Retry failed for peer $peerId',
        e,
        null,
        'StoreForward',
      );
    }
  }

  Future<void> _retrySingleMessage(MessageEntry message, String peerId) async {
    try {
      final newRetryCount = message.retryCount + 1;
      await _chatRepository.updateRetryMetadata(
        message.id,
        retryCount: newRetryCount,
        lastAttemptAt: DateTime.now(),
      );

      final payload = ble.MessagePayload(
        messageId: message.id,
        type: ble.MessageType.text,
        content: message.textContent ?? '',
      );

      final success = await _transportManager.sendMessage(peerId, payload);

      final newStatus = success ? MessageStatus.sent : MessageStatus.failed;
      await _chatRepository.updateMessageStatus(message.id, newStatus);

      _messageStatusController.add(
        MessageDeliveryUpdate(messageId: message.id, status: newStatus),
      );

      if (success) {
        Logger.info(
          'StoreAndForward: Delivered ${message.id.substring(0, 8)} '
          '(retry #$newRetryCount)',
          'StoreForward',
        );
      }
    } catch (e) {
      Logger.error(
        'StoreAndForward: Single message retry failed',
        e,
        null,
        'StoreForward',
      );
    }
  }
}

/// Carries the outcome of a background delivery attempt.
class MessageDeliveryUpdate {
  const MessageDeliveryUpdate({
    required this.messageId,
    required this.status,
  });

  final String messageId;
  final MessageStatus status;
}
