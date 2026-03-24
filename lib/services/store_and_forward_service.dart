import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:anchor/core/constants/app_constants.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/data/local_database/database.dart';
import 'package:anchor/data/repositories/chat_repository.dart';
import 'package:anchor/data/repositories/peer_repository.dart';
import 'package:anchor/data/repositories/profile_repository.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/transport/transport_manager.dart';

/// Persists outgoing messages across sessions and retries delivery
/// whenever the target peer is (re)discovered via any transport.
///
/// ## Improvements over v1
///
/// - **Exponential backoff**: delay = min(2^retryCount, 300) seconds + jitter
/// - **Extended TTL**: 7 days (cruise duration) instead of 24h
/// - **Photo retry persistence**: photo messages are retried, not just text
/// - **Cross-transport dedup**: uses cooldown on canonical peerId (= userId)
///   to avoid duplicate sends when peer appears on multiple transports
/// - **User notification**: emits expiry events so UI can show "Message expired"
///
/// Flow:
///   1. On app startup, [initialize] expires stale messages (> 7 days) and
///      subscribes to [TransportManager.peerDiscoveredStream].
///   2. When a peer appears, [_retryPendingForPeer] queries the DB for
///      pending/failed messages in that conversation and attempts
///      re-delivery with exponential backoff.
///   3. [messageStatusStream] emits [MessageDeliveryUpdate] events so that any
///      open ChatBloc can update its in-memory state immediately.
///   4. [messageExpiredStream] emits message IDs that were expired, so UI can
///      show "Message could not be delivered" labels.
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
  final _random = Random();

  String? _ownUserId;
  bool _initialized = false;

  StreamSubscription<ble.DiscoveredPeer>? _peerDiscoveredSub;

  /// Canonical peer IDs (= userId) for which a retry wave is currently
  /// in-flight or was recently completed. Prevents duplicate concurrent
  /// retry attempts and cross-transport double-retries (e.g. BLE then LAN).
  final Set<String> _inFlightPeerIds = {};

  final _messageStatusController =
      StreamController<MessageDeliveryUpdate>.broadcast();

  final _messageExpiredController = StreamController<String>.broadcast();

  /// Emits whenever a queued message is successfully delivered or permanently
  /// fails. Open ChatBloc instances subscribe to refresh their UI state.
  Stream<MessageDeliveryUpdate> get messageStatusStream =>
      _messageStatusController.stream;

  /// Emits message IDs that were expired (too old to retry).
  Stream<String> get messageExpiredStream => _messageExpiredController.stream;

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
    // Use 7 days for cruise duration instead of 24h.
    await _chatRepository.expireStaleOutgoingMessages(
      _ownUserId!,
      const Duration(days: AppConstants.storeForwardTtlDays),
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
    await _messageExpiredController.close();
  }

  // ==================== Private ====================

  /// Called when a peer is (re)discovered on any transport.
  ///
  /// Since the canonical peerId IS the stable userId, a single dedup set
  /// suffices — no need for separate peerId vs userId tracking.
  /// The in-flight guard prevents concurrent retry waves for the same peer.
  /// Cleared immediately after the retry wave completes — no arbitrary cooldown.
  void _onPeerDiscovered(String peerId) {
    if (_ownUserId == null) return;

    if (_inFlightPeerIds.contains(peerId)) return;
    _inFlightPeerIds.add(peerId);
    _retryPendingForPeer(peerId).whenComplete(() {
      _inFlightPeerIds.remove(peerId);
    });
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

      // Filter out messages that have exceeded max retries
      final retriable = messages.where((m) =>
          m.retryCount < AppConstants.messageMaxCrossSessionRetries,).toList();

      final expired = messages.where((m) =>
          m.retryCount >= AppConstants.messageMaxCrossSessionRetries,).toList();

      // Mark expired messages
      for (final msg in expired) {
        await _chatRepository.updateMessageStatus(msg.id, MessageStatus.failed);
        _messageExpiredController.add(msg.id);
      }

      if (retriable.isEmpty) return;

      // Priority sort: pending (never attempted) first, then by creation time.
      // This ensures fresh messages are tried before older retries.
      retriable.sort((a, b) {
        final aIsFresh = a.retryCount == 0 ? 0 : 1;
        final bIsFresh = b.retryCount == 0 ? 0 : 1;
        if (aIsFresh != bIsFresh) return aIsFresh.compareTo(bIsFresh);
        return a.createdAt.compareTo(b.createdAt);
      });

      Logger.info(
        'StoreAndForward: Retrying ${retriable.length} message(s) '
        'for peer ${peerId.substring(0, 8)} '
        '(${expired.length} expired)',
        'StoreForward',
      );

      // Transition all retriable messages to 'queued' status.
      for (final message in retriable) {
        if (message.status != MessageStatus.queued) {
          await _chatRepository.updateMessageStatus(
              message.id, MessageStatus.queued,);
          _messageStatusController.add(
            MessageDeliveryUpdate(
                messageId: message.id, status: MessageStatus.queued,),
          );
        }
      }

      for (final message in retriable) {
        // Exponential backoff: check if enough time has passed since last attempt
        if (!_shouldRetryNow(message)) {
          Logger.debug(
            'StoreAndForward: Skipping ${message.id.substring(0, 8)} '
            '(backoff not elapsed)',
            'StoreForward',
          );
          continue;
        }
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

  /// Check if enough time has elapsed since the last retry attempt
  /// (exponential backoff).
  bool _shouldRetryNow(MessageEntry message) {
    if (message.lastAttemptAt == null) return true;
    final backoffSeconds = _backoffDelay(message.retryCount);
    final elapsed = DateTime.now().difference(message.lastAttemptAt!);
    return elapsed.inSeconds >= backoffSeconds;
  }

  /// Calculate exponential backoff delay with proportional jitter.
  ///
  /// delay = min(2^retryCount, 300) + random(0..baseDelay/2)
  /// Retry 0: ~1-1.5s, Retry 1: ~2-3s, Retry 2: ~4-6s, ... cap 5 min
  /// Proportional jitter prevents thundering herd at high retry counts.
  int _backoffDelay(int retryCount) {
    final baseDelay = min(pow(2, retryCount).toInt(), 300);
    final maxJitter = max(1, baseDelay ~/ 2);
    final jitter = _random.nextInt(maxJitter);
    return baseDelay + jitter;
  }

  Future<void> _retrySingleMessage(MessageEntry message, String peerId) async {
    try {
      final newRetryCount = message.retryCount + 1;
      await _chatRepository.updateRetryMetadata(
        message.id,
        retryCount: newRetryCount,
        lastAttemptAt: DateTime.now(),
      );

      bool success;

      if (message.contentType == MessageContentType.text) {
        final payload = ble.MessagePayload(
          messageId: message.id,
          type: ble.MessageType.text,
          content: message.textContent ?? '',
        );
        success = await _transportManager.sendMessage(peerId, payload);
      } else {
        // Photo / photoPreview: re-send a lightweight photo preview notification
        // so the recipient can tap to download. The full photo is sent on-demand
        // when the recipient requests it.
        final photoId = _extractPhotoId(message);
        success = await _transportManager.sendPhotoPreview(
          peerId: peerId,
          messageId: message.id,
          photoId: photoId ?? message.id,
          thumbnailBytes: Uint8List(0),
          originalSize: 0,
        );
      }

      final newStatus = success ? MessageStatus.sent : MessageStatus.failed;
      if (success) {
        await _chatRepository.updateMessageStatus(message.id, newStatus);
      }
      // Don't mark as failed on transport failure — leave as pending for
      // the next retry wave when the peer reconnects.

      _messageStatusController.add(
        MessageDeliveryUpdate(messageId: message.id, status: newStatus),
      );

      if (success) {
        Logger.info(
          'StoreAndForward: Delivered ${message.id.substring(0, 8)} '
          '(retry #$newRetryCount)',
          'StoreForward',
        );
      } else {
        Logger.debug(
          'StoreAndForward: Retry #$newRetryCount failed for '
          '${message.id.substring(0, 8)} — will retry with backoff',
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
  /// Extract the photoId from a photo message's textContent JSON.
  /// Returns null if not found.
  String? _extractPhotoId(MessageEntry message) {
    final text = message.textContent;
    if (text == null || text.isEmpty) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return json['photo_id'] as String?;
    } catch (_) {
      return null;
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
