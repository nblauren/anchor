import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/wifi_aware/wifi_aware_transport_service.dart';
import 'package:wifi_aware_p2p/wifi_aware_p2p.dart' as wa;

/// Production implementation of [WifiAwareTransportService] using the
/// `wifi_aware_p2p` Flutter plugin.
///
/// ## Architecture
///
/// - **Discovery**: Publishes and subscribes to `com.anchor.discovery`.
///   Profile metadata is encoded in the serviceInfo map. Thumbnails are
///   exchanged via DataConnection after initial discovery.
///
/// - **Messaging**: Small messages (<255 bytes) use L2 `session.sendMessage`.
///   Larger messages use a short-lived DataConnection.
///
/// - **Photo transfer**: Uses `DataConnection.sendStream()` — no Wi-Fi Direct
///   negotiation dance needed (unlike Nearby Connections).
///
/// - **Anchor drops**: Sent as JSON via L2 (well under 255 bytes).
class WifiAwareTransportServiceImpl implements WifiAwareTransportService {
  static const _serviceName = '_anchor-service._tcp';
  static const _idleConnectionTimeout = Duration(seconds: 60);
  static const _l2MaxBytes = 255;

  wa.WifiAwareSession? _session;
  String? _ownUserId;
  bool _started = false;

  // Active peer tracking
  final Map<String, wa.DiscoveredPeer> _activePeers = {};
  final Map<String, DateTime> _lastActivity = {};

  // Active DataConnections by peerId
  final Map<String, wa.DataConnection> _connections = {};

  // Stream controllers — broadcast so multiple listeners can subscribe
  final _peerDiscoveredController =
      StreamController<ble.DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _messageReceivedController =
      StreamController<ble.ReceivedMessage>.broadcast();
  final _photoProgressController =
      StreamController<ble.PhotoTransferProgress>.broadcast();
  final _photoReceivedController =
      StreamController<ble.ReceivedPhoto>.broadcast();
  final _photoPreviewReceivedController =
      StreamController<ble.ReceivedPhotoPreview>.broadcast();
  final _photoRequestReceivedController =
      StreamController<ble.ReceivedPhotoRequest>.broadcast();
  final _anchorDropReceivedController =
      StreamController<ble.AnchorDropReceived>.broadcast();
  final _reactionReceivedController =
      StreamController<ble.ReactionReceived>.broadcast();
  final _availabilityController = StreamController<bool>.broadcast();

  // Subscriptions
  StreamSubscription<wa.DiscoveredPeer>? _peerDiscoveredSub;
  StreamSubscription<String>? _peerLostSub;
  StreamSubscription<wa.PeerMessage>? _messageSub;
  StreamSubscription<wa.DataConnection>? _incomingConnectionSub;
  StreamSubscription<bool>? _availabilitySub;
  Timer? _idleTimer;

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  }) async {
    _ownUserId = ownUserId;

    // Listen for availability changes
    _availabilitySub =
        wa.WifiAwareP2P.onAvailabilityChanged.listen((available) {
      _availabilityController.add(available);
      Logger.info(
        'WifiAwareTransport: availability changed to $available',
        'WifiAware',
      );
    });

    Logger.info('WifiAwareTransport: initialized', 'WifiAware');
  }

  @override
  Future<void> start() async {
    if (_started) return;

    try {
      _session = await wa.WifiAwareP2P.startSession();
      _started = true;

      // Subscribe to session streams
      _peerDiscoveredSub = _session!.onPeerDiscovered.listen(_onPeerDiscovered);
      _peerLostSub = _session!.onPeerLost.listen(_onPeerLost);
      _messageSub = _session!.onMessageReceived.listen(_onMessageReceived);
      _incomingConnectionSub =
          _session!.onIncomingConnection.listen(_onIncomingConnection);

      // Start idle connection cleanup timer
      _idleTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _cleanupIdleConnections(),
      );

      Logger.info('WifiAwareTransport: session started', 'WifiAware');
    } catch (e) {
      Logger.error(
          'WifiAwareTransport: failed to start session', e, null, 'WifiAware',);
      _started = false;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) return;

    _idleTimer?.cancel();
    _idleTimer = null;

    // Close all active connections
    for (final conn in _connections.values) {
      try {
        await conn.close();
      } catch (_) {}
    }
    _connections.clear();
    _activePeers.clear();
    _lastActivity.clear();

    // Cancel subscriptions
    await _peerDiscoveredSub?.cancel();
    await _peerLostSub?.cancel();
    await _messageSub?.cancel();
    await _incomingConnectionSub?.cancel();

    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
    _started = false;

    Logger.info('WifiAwareTransport: stopped', 'WifiAware');
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _availabilitySub?.cancel();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _photoPreviewReceivedController.close();
    await _photoRequestReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();
    await _availabilityController.close();
  }

  // ==================== Status ====================

  @override
  Future<bool> get isSupported => wa.WifiAwareP2P.isSupported();

  @override
  Future<bool> get isAvailable => wa.WifiAwareP2P.isAvailable();

  @override
  Stream<bool> get availabilityStream => _availabilityController.stream;

  // ==================== Discovery ====================

  @override
  Stream<ble.DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  // ==================== Profile ====================

  @override
  Future<void> updateProfile(ble.BroadcastPayload payload) async {
    final session = _session;
    if (session == null) return;

    final serviceInfo = _encodeProfileToServiceInfo(payload);

    try {
      // Publish with updated service info
      await session.stopPublish();
      await session.publish(
        serviceName: _serviceName,
        serviceInfo: serviceInfo,
      );

      // Also subscribe so we discover other peers
      await session.stopSubscribe();
      await session.subscribe(
        serviceName: _serviceName,
        type: wa.SubscribeType.active,
      );

      Logger.info(
          'WifiAwareTransport: profile updated and published', 'WifiAware',);
    } catch (e) {
      Logger.error(
          'WifiAwareTransport: failed to update profile', e, null, 'WifiAware',);
    }
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final session = _session;
    if (session == null) return false;

    try {
      final json = jsonEncode(payload.toJson());
      final bytes = Uint8List.fromList(utf8.encode(json));

      if (bytes.length <= _l2MaxBytes) {
        await session.sendMessage(peerId, bytes);
      } else {
        // Large message — use DataConnection
        final conn = await _getOrOpenConnection(peerId);
        await conn.send(bytes);
      }

      _lastActivity[peerId] = DateTime.now();
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: failed to send message to $peerId',
        e,
        null,
        'WifiAware',
      );
      return false;
    }
  }

  @override
  Stream<ble.ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  // ==================== Photo Transfer ====================

  @override
  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async {
    try {
      final conn = await _getOrOpenConnection(peerId);

      // Send header first
      final header = jsonEncode({
        'type': 'photo_data',
        'message_id': messageId,
        'photo_id': photoId ?? messageId,
        'total_size': photoData.length,
      });
      await conn.send(Uint8List.fromList(utf8.encode(header)));

      // Small delay to let header arrive
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Stream the photo data
      _photoProgressController.add(ble.PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: ble.PhotoTransferStatus.inProgress,
      ),);

      // Listen to send progress
      StreamSubscription<double>? progressSub;
      progressSub = conn.onSendProgress.listen((progress) {
        _photoProgressController.add(ble.PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: progress,
          status: ble.PhotoTransferStatus.inProgress,
        ),);
      });

      await conn.sendStream(photoData);

      await progressSub.cancel();

      _photoProgressController.add(ble.PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 1,
        status: ble.PhotoTransferStatus.completed,
      ),);

      _lastActivity[peerId] = DateTime.now();
      Logger.info(
        'WifiAwareTransport: photo sent to $peerId (${photoData.length} bytes)',
        'WifiAware',
      );
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: photo send failed to $peerId',
        e,
        null,
        'WifiAware',
      );
      _photoProgressController.add(ble.PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: 0,
        status: ble.PhotoTransferStatus.failed,
        errorMessage: e.toString(),
      ),);
      return false;
    }
  }

  @override
  Stream<ble.PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ble.ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  // ==================== Photo Consent Flow ====================

  @override
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    final session = _session;
    if (session == null) return false;

    try {
      final json = jsonEncode({
        'type': 'photoPreview',
        'messageId': messageId,
        'photoId': photoId,
        'originalSize': originalSize,
      });
      final bytes = Uint8List.fromList(utf8.encode(json));

      // photoPreview metadata is small enough for L2
      if (bytes.length <= _l2MaxBytes) {
        await session.sendMessage(peerId, bytes);
      } else {
        final conn = await _getOrOpenConnection(peerId);
        await conn.send(bytes);
      }

      _lastActivity[peerId] = DateTime.now();
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: failed to send photo preview',
        e,
        null,
        'WifiAware',
      );
      return false;
    }
  }

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    final session = _session;
    if (session == null) return false;

    try {
      final json = jsonEncode({
        'type': 'photoRequest',
        'messageId': messageId,
        'photoId': photoId,
      });
      final bytes = Uint8List.fromList(utf8.encode(json));

      // photo_request is small enough for L2
      await session.sendMessage(peerId, bytes);
      _lastActivity[peerId] = DateTime.now();
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: failed to send photo request',
        e,
        null,
        'WifiAware',
      );
      return false;
    }
  }

  @override
  Stream<ble.ReceivedPhotoPreview> get photoPreviewReceivedStream =>
      _photoPreviewReceivedController.stream;

  @override
  Stream<ble.ReceivedPhotoRequest> get photoRequestReceivedStream =>
      _photoRequestReceivedController.stream;

  // ==================== Anchor Drops ====================

  @override
  Future<bool> sendDropAnchor(String peerId) async {
    final session = _session;
    if (session == null) return false;

    try {
      final json = jsonEncode({
        'type': 'drop_anchor',
        'sender_id': _ownUserId ?? '',
        'timestamp': DateTime.now().toIso8601String(),
      });
      final bytes = Uint8List.fromList(utf8.encode(json));

      await session.sendMessage(peerId, bytes);
      _lastActivity[peerId] = DateTime.now();
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: failed to send anchor drop',
        e,
        null,
        'WifiAware',
      );
      return false;
    }
  }

  @override
  Stream<ble.AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  // ==================== Reactions ====================

  @override
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async {
    final session = _session;
    if (session == null) return false;

    try {
      final json = jsonEncode({
        'type': 'reaction',
        'sender_id': _ownUserId ?? '',
        'message_id': messageId,
        'emoji': emoji,
        'action': action,
        'timestamp': DateTime.now().toIso8601String(),
      });
      final bytes = Uint8List.fromList(utf8.encode(json));
      await session.sendMessage(peerId, bytes);
      _lastActivity[peerId] = DateTime.now();
      return true;
    } catch (e) {
      Logger.error(
        'WifiAwareTransport: failed to send reaction',
        e,
        null,
        'WifiAware',
      );
      return false;
    }
  }

  @override
  Stream<ble.ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  // ==================== Pairing ====================

  @override
  Future<bool> hasPairedDevices() => wa.WifiAwareP2P.hasPairedDevices();

  @override
  Future<bool> requestPairing() => wa.WifiAwareP2P.requestPairing();

  // ==================== Utilities ====================

  @override
  bool isPeerReachable(String peerId) => _activePeers.containsKey(peerId);

  @override
  int? getDistanceMm(String peerId) => _activePeers[peerId]?.distanceMm;

  // ==================== Private Handlers ====================

  void _onPeerDiscovered(wa.DiscoveredPeer waPeer) {
    _activePeers[waPeer.peerId] = waPeer;
    _lastActivity[waPeer.peerId] = DateTime.now();

    // Parse profile metadata from serviceInfo
    final info = waPeer.serviceInfo ?? {};
    final userId = info['userId'];
    final anchorPeer = ble.DiscoveredPeer(
      peerId: waPeer.peerId,
      userId: userId != null && userId.isNotEmpty ? userId : null,
      name: info['name'] ?? 'Unknown',
      age: int.tryParse(info['age'] ?? ''),
      bio: info['bio'],
      position: int.tryParse(info['position'] ?? ''),
      interests: info['interests'],
      timestamp: DateTime.now(),
      fullPhotoCount: int.tryParse(info['photoCount'] ?? '0') ?? 0,
    );

    _peerDiscoveredController.add(anchorPeer);

    // Fetch thumbnail via DataConnection
    _fetchThumbnail(waPeer.peerId);

    Logger.info(
      'WifiAwareTransport: peer discovered ${info['name'] ?? waPeer.peerId}',
      'WifiAware',
    );
  }

  void _onPeerLost(String peerId) {
    _activePeers.remove(peerId);
    _lastActivity.remove(peerId);

    // Close any open connection
    final conn = _connections.remove(peerId);
    conn?.close().catchError((_) {});

    _peerLostController.add(peerId);
    Logger.info('WifiAwareTransport: peer lost $peerId', 'WifiAware');
  }

  void _onMessageReceived(wa.PeerMessage msg) {
    _lastActivity[msg.peerId] = DateTime.now();

    try {
      final json = jsonDecode(utf8.decode(msg.data)) as Map<String, dynamic>;
      _routeMessage(msg.peerId, json, msg.receivedAt);
    } catch (e) {
      Logger.warning(
        'WifiAwareTransport: failed to decode message from ${msg.peerId}',
        'WifiAware',
      );
    }
  }

  void _onIncomingConnection(wa.DataConnection conn) {
    _connections[conn.peerId] = conn;
    _lastActivity[conn.peerId] = DateTime.now();
    _listenToConnection(conn);
    Logger.info(
      'WifiAwareTransport: incoming connection from ${conn.peerId}',
      'WifiAware',
    );
  }

  /// Route a decoded JSON message to the appropriate stream controller.
  void _routeMessage(
    String fromPeerId,
    Map<String, dynamic> json,
    DateTime timestamp,
  ) {
    final type = json['type'] as String?;

    switch (type) {
      case 'drop_anchor':
        _anchorDropReceivedController.add(ble.AnchorDropReceived(
          fromPeerId: fromPeerId,
          timestamp: timestamp,
        ),);

      case 'reaction':
        final msgId = json['message_id'] as String?;
        final emoji = json['emoji'] as String?;
        final action = json['action'] as String?;
        if (msgId != null && emoji != null && action != null) {
          _reactionReceivedController.add(ble.ReactionReceived(
            fromPeerId: fromPeerId,
            messageId: msgId,
            emoji: emoji,
            action: action,
            timestamp: timestamp,
          ),);
        }

      case 'photoPreview':
        _photoPreviewReceivedController.add(ble.ReceivedPhotoPreview(
          fromPeerId: fromPeerId,
          messageId: json['messageId'] as String? ?? '',
          photoId: json['photoId'] as String? ?? '',
          thumbnailBytes: Uint8List(0), // No thumbnail in L2 message
          originalSize: json['originalSize'] as int? ?? 0,
          timestamp: timestamp,
        ),);

      case 'photoRequest':
        _photoRequestReceivedController.add(ble.ReceivedPhotoRequest(
          fromPeerId: fromPeerId,
          messageId: json['messageId'] as String? ?? '',
          photoId: json['photoId'] as String? ?? '',
          timestamp: timestamp,
        ),);

      case 'thumbnail_response':
        // Handled in _listenToConnection for DataConnection
        break;

      case 'photo_data':
        // Photo header — handled in _listenToConnection
        break;

      default:
        // Regular message (text, typing, read, etc.)
        if (json.containsKey('messageId')) {
          try {
            final payload = ble.MessagePayload.fromJson(json);
            _messageReceivedController.add(ble.ReceivedMessage(
              fromPeerId: fromPeerId,
              messageId: payload.messageId,
              type: payload.type,
              content: payload.content,
              timestamp: timestamp,
            ),);
          } catch (e) {
            Logger.warning(
              'WifiAwareTransport: unrecognised message type: $type',
              'WifiAware',
            );
          }
        }
    }
  }

  /// Fetch thumbnail from a peer via DataConnection after initial discovery.
  Future<void> _fetchThumbnail(String peerId) async {
    try {
      final conn = await _getOrOpenConnection(peerId);

      // Send thumbnail request
      final request = jsonEncode({'type': 'thumbnail_request'});
      await conn.send(Uint8List.fromList(utf8.encode(request)));

      // Thumbnail data arrives via _listenToConnection
    } catch (e) {
      Logger.warning(
        'WifiAwareTransport: failed to fetch thumbnail from $peerId',
        'WifiAware',
      );
    }
  }

  /// Get an existing connection or open a new one.
  Future<wa.DataConnection> _getOrOpenConnection(String peerId) async {
    final existing = _connections[peerId];
    if (existing != null) return existing;

    final session = _session;
    if (session == null) {
      throw StateError('WifiAwareTransport: no active session');
    }

    final conn = await session.openConnection(peerId);
    _connections[peerId] = conn;
    _listenToConnection(conn);
    return conn;
  }

  /// Listen to data arriving on a DataConnection.
  void _listenToConnection(wa.DataConnection conn) {
    // Accumulator for incoming photo data
    final photoBuffer = <int>[];
    String? pendingPhotoMessageId;
    String? pendingPhotoId;
    int? pendingPhotoTotalSize;

    conn.onDataReceived.listen(
      (data) {
        _lastActivity[conn.peerId] = DateTime.now();

        // Try to decode as JSON first (headers, messages, thumbnails)
        try {
          final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          final type = json['type'] as String?;

          if (type == 'thumbnail_response') {
            // Thumbnail data is base64-encoded in JSON
            final thumbBase64 = json['data'] as String?;
            if (thumbBase64 != null) {
              final thumbBytes = base64Decode(thumbBase64);
              final info = _activePeers[conn.peerId]?.serviceInfo ?? {};
              _peerDiscoveredController.add(ble.DiscoveredPeer(
                peerId: conn.peerId,
                name: info['name'] ?? 'Unknown',
                age: int.tryParse(info['age'] ?? ''),
                bio: info['bio'],
                position: int.tryParse(info['position'] ?? ''),
                interests: info['interests'],
                thumbnailBytes: Uint8List.fromList(thumbBytes),
                timestamp: DateTime.now(),
                fullPhotoCount: int.tryParse(info['photoCount'] ?? '0') ?? 0,
              ),);
            }
            return;
          }

          if (type == 'thumbnail_request') {
            // Peer wants our thumbnail — respond if we have one
            // This is handled by the TransportManager which holds the profile
            return;
          }

          if (type == 'photo_data') {
            // Photo header — start accumulating
            pendingPhotoMessageId = json['message_id'] as String?;
            pendingPhotoId = json['photo_id'] as String?;
            pendingPhotoTotalSize = json['total_size'] as int?;
            photoBuffer.clear();
            return;
          }

          // Route other JSON messages
          _routeMessage(conn.peerId, json, DateTime.now());
        } catch (_) {
          // Not JSON — binary photo data
          if (pendingPhotoMessageId != null) {
            photoBuffer.addAll(data);

            // Emit progress
            if (pendingPhotoTotalSize != null && pendingPhotoTotalSize! > 0) {
              final progress = photoBuffer.length / pendingPhotoTotalSize!;
              _photoProgressController.add(ble.PhotoTransferProgress(
                messageId: pendingPhotoMessageId!,
                peerId: conn.peerId,
                progress: progress.clamp(0.0, 1.0),
                status: ble.PhotoTransferStatus.inProgress,
              ),);
            }

            // Check if complete
            if (pendingPhotoTotalSize != null &&
                photoBuffer.length >= pendingPhotoTotalSize!) {
              _photoReceivedController.add(ble.ReceivedPhoto(
                fromPeerId: conn.peerId,
                messageId: pendingPhotoMessageId!,
                photoBytes: Uint8List.fromList(photoBuffer),
                timestamp: DateTime.now(),
                photoId: pendingPhotoId,
              ),);

              _photoProgressController.add(ble.PhotoTransferProgress(
                messageId: pendingPhotoMessageId!,
                peerId: conn.peerId,
                progress: 1,
                status: ble.PhotoTransferStatus.completed,
              ),);

              // Reset
              pendingPhotoMessageId = null;
              pendingPhotoId = null;
              pendingPhotoTotalSize = null;
              photoBuffer.clear();
            }
          }
        }
      },
      onError: (Object e) {
        Logger.error(
          'WifiAwareTransport: connection error from ${conn.peerId}',
          e,
          null,
          'WifiAware',
        );
      },
      onDone: () {
        _connections.remove(conn.peerId);
      },
    );
  }

  /// Close connections that have been idle for [_idleConnectionTimeout].
  void _cleanupIdleConnections() {
    final now = DateTime.now();
    final toRemove = <String>[];

    for (final entry in _lastActivity.entries) {
      if (now.difference(entry.value) > _idleConnectionTimeout) {
        final conn = _connections[entry.key];
        if (conn != null) {
          conn.close().catchError((_) {});
          toRemove.add(entry.key);
        }
      }
    }

    for (final peerId in toRemove) {
      _connections.remove(peerId);
      Logger.debug(
        'WifiAwareTransport: closed idle connection to $peerId',
        'WifiAware',
      );
    }
  }

  /// Encode a [BroadcastPayload] into a serviceInfo map for publishing.
  Map<String, String> _encodeProfileToServiceInfo(
      ble.BroadcastPayload payload,) {
    return {
      'userId': payload.userId,
      'name': payload.name,
      'age': payload.age?.toString() ?? '',
      'bio': payload.bio ?? '',
      'position': payload.position?.toString() ?? '',
      'interests': payload.interests ?? '',
      'photoCount': payload.thumbnailsList?.length.toString() ?? '0',
    };
  }
}
