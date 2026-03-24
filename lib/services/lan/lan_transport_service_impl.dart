import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/binary_message_codec.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/lan/lan_transport_service.dart';
import 'package:anchor/services/mesh/mesh_packet.dart';
import 'package:uuid/uuid.dart';

// ==================== Internal Data Structures ====================

class _LanPeerMeta {
  _LanPeerMeta({
    required this.lanPeerId,
    required this.userId,
    required this.ipAddress,
    required this.tcpPort,
    required this.name,
    this.age,
    this.bio,
    this.position,
    this.interests,
    this.thumbnailBytes,
    this.publicKeyHex,
    this.signingPublicKeyHex,
  });

  final String lanPeerId;
  final String userId;
  final String ipAddress;
  final int tcpPort;
  final String name;
  final int? age;
  final String? bio;
  final int? position;
  final String? interests;
  Uint8List? thumbnailBytes;
  /// Peer's X25519 public key (64-char hex) for E2EE key exchange.
  final String? publicKeyHex;
  /// Peer's Ed25519 signing public key (64-char hex) for mesh announcement verification.
  final String? signingPublicKeyHex;
}

class _PendingPhoto {
  _PendingPhoto({
    required this.fromPeerId,
    required this.messageId,
    required this.photoId,
    required this.totalChunks,
  });

  final String fromPeerId;
  final String messageId;
  final String photoId;
  final int totalChunks;
  final Map<int, Uint8List> chunks = {}; // chunkIndex → data
}

// ==================== Frame Buffer ====================

/// Accumulates raw bytes from a TCP stream and drains complete length-prefixed
/// frames on demand.
///
/// Frame format: [4 bytes big-endian uint32 length][UTF-8 JSON payload]
class _FrameBuffer {
  final _buf = <int>[];

  void add(List<int> data) => _buf.addAll(data);

  /// Drain all complete frames from buffer.
  List<Uint8List> drain() {
    final frames = <Uint8List>[];
    while (_buf.length >= 4) {
      final length =
          (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
      if (_buf.length < 4 + length) break;
      frames.add(Uint8List.fromList(_buf.sublist(4, 4 + length)));
      _buf.removeRange(0, 4 + length);
    }
    return frames;
  }
}

// ==================== Production Implementation ====================

/// Production implementation of [LanTransportService] using pure `dart:io`.
///
/// ## Transport protocol
///
/// **Discovery**: UDP broadcast beacons on port 47832 every 5 seconds.
/// Peers without thumbnails trigger an async TCP thumb_request after discovery.
///
/// **Messaging / signals**: TCP with length-prefixed JSON frames.
/// Each connection is kept alive and reused for subsequent messages.
///
/// **Photo transfer**: TCP chunking (64 KB chunks, base64-encoded in JSON).
///
/// ## Peer lifecycle
///
/// A peer is considered live until 30 seconds after its last beacon.
/// A background timer (every 10 s) evicts peers that have exceeded the timeout.
class LanTransportServiceImpl implements LanTransportService {
  static const _tag = 'LanTransport';
  static const _udpPort = 47832;
  static const _tcpPortBase = 47833;
  static const _beaconInterval = Duration(seconds: 5);
  static const _peerTimeout = Duration(seconds: 30);
  static const _photoChunkSize = 65536; // 64 KB

  String? _ownUserId;
  ble.BroadcastPayload? _profile;
  String? _lanPeerId;
  int _tcpPort = _tcpPortBase;
  bool _started = false;

  // Sockets
  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  InternetAddress? _broadcastAddress;

  // Timers
  Timer? _beaconTimer;
  Timer? _timeoutTimer;
  Timer? _recoveryTimer;

  // Peer tracking
  final Map<String, _LanPeerMeta> _peers = {};
  final Map<String, DateTime> _lastSeen = {};
  final Map<String, Socket> _outgoingConnections = {};
  final Map<Socket, _FrameBuffer> _frameBuffers = {};

  // Pending photo reassembly
  final Map<String, _PendingPhoto> _pendingPhotos = {};

  // Stream controllers — all broadcast
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
  final _noiseHandshakeController =
      StreamController<ble.NoiseHandshakeReceived>.broadcast();
  final _availabilityController = StreamController<bool>.broadcast();

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  }) async {
    _ownUserId = ownUserId;
    _profile = profile;
    _lanPeerId = const Uuid().v4();
    Logger.info(
      'LanTransportServiceImpl initialized, lanPeerId=$_lanPeerId',
      _tag,
    );
  }

  @override
  Future<void> start() async {
    if (_started) return;
    if (_lanPeerId == null) {
      Logger.warning('start() called before initialize()', _tag);
      return;
    }

    // Bind UDP socket for broadcast beaconing
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reusePort: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen(
        _onUdpDatagram,
        onError: (Object e) {
          Logger.warning('LAN: UDP socket error — disabling LAN: $e', _tag);
          _disableLan();
        },
      );
      Logger.info('LAN: UDP socket bound on port $_udpPort', _tag);
    } catch (e) {
      Logger.error('LAN: Failed to bind UDP socket', e, null, _tag);
      return;
    }

    // Bind TCP server, incrementing port on conflict
    var port = _tcpPortBase;
    while (true) {
      try {
        _tcpServer = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        _tcpPort = port;
        Logger.info('LAN: TCP server listening on port $_tcpPort', _tag);
        break;
      } on SocketException {
        port++;
        if (port > _tcpPortBase + 20) {
          Logger.error('LAN: Could not bind TCP server (tried 20 ports)', null, null, _tag);
          _udpSocket?.close();
          _udpSocket = null;
          return;
        }
      }
    }

    _tcpServer!.listen(
      _handleIncomingConnection,
      onError: (Object e) => Logger.error('LAN: TCP server error', e, null, _tag),
    );

    // Start timers
    _beaconTimer = Timer.periodic(_beaconInterval, (_) => _sendBeacon());
    // Check peer timeouts on each beacon cycle instead of a separate 10s poll.
    // This reduces worst-case detection lag from 10s to the beacon interval (5s).
    _timeoutTimer = Timer.periodic(
      _beaconInterval,
      (_) => _checkPeerTimeouts(),
    );

    _started = true;
    _broadcastAddress = await _computeBroadcastAddress();
    Logger.info('LAN: broadcast address = $_broadcastAddress', _tag);

    // Send first beacon immediately
    _sendBeacon();
    Logger.info('LAN: transport started', _tag);
  }

  @override
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    // Close outgoing connections
    for (final socket in _outgoingConnections.values) {
      try {
        await socket.close();
      } catch (_) {}
    }
    _outgoingConnections.clear();
    _frameBuffers.clear();

    await _tcpServer?.close();
    _tcpServer = null;

    _udpSocket?.close();
    _udpSocket = null;

    // Emit peerLost for all known peers
    for (final peerId in List<String>.from(_peers.keys)) {
      _peerLostController.add(peerId);
    }
    _peers.clear();
    _lastSeen.clear();
    _pendingPhotos.clear();

    Logger.info('LAN: transport stopped', _tag);
  }

  @override
  Future<void> dispose() async {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    await stop();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _photoPreviewReceivedController.close();
    await _photoRequestReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();
    await _noiseHandshakeController.close();
    await _availabilityController.close();
    Logger.info('LAN: transport disposed', _tag);
  }

  // ==================== Status ====================

  @override
  Future<bool> get isAvailable async {
    try {
      final interfaces = await NetworkInterface.list();
      // Only consider Wi-Fi interfaces — cellular (pdp_ip/rmnet/wwan) does not
      // support LAN broadcast. iOS Wi-Fi = en0/en1; Android Wi-Fi = wlan*.
      return interfaces.any((i) {
        final name = i.name.toLowerCase();
        final isWifi = name.startsWith('en') || name.startsWith('wlan');
        return isWifi &&
            i.addresses.any(
              (a) => !a.isLoopback && a.type == InternetAddressType.IPv4,
            );
      });
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<bool> get availabilityStream => _availabilityController.stream;

  // ==================== Discovery Streams ====================

  @override
  Stream<ble.DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  // ==================== Profile ====================

  @override
  Future<void> updateProfile(ble.BroadcastPayload payload) async {
    _profile = payload;
    // Next beacon automatically picks up the updated profile
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async {
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final binaryData = BinaryMessageCodec.encodeMessage(
      senderId: _ownUserId ?? '',
      messageId: payload.messageId,
      messageType: payload.type,
      content: payload.content,
      replyToId: payload.replyToId,
    );
    return _sendBinaryFrame(socket, binaryData);
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
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final id = photoId ?? const Uuid().v4();
    final totalChunks = (photoData.length / _photoChunkSize).ceil();

    _photoProgressController.add(ble.PhotoTransferProgress(
      messageId: messageId,
      peerId: peerId,
      progress: 0,
      status: ble.PhotoTransferStatus.starting,
    ),);

    for (var i = 0; i < totalChunks; i++) {
      final start = i * _photoChunkSize;
      final end = min(start + _photoChunkSize, photoData.length);
      final chunk = photoData.sublist(start, end);

      final envelope = {
        'v': 1,
        'type': 'photo_chunk',
        'fromPeerId': _lanPeerId,
        'fromUserId': _ownUserId,
        'payload': {
          'messageId': messageId,
          'photoId': id,
          'chunkIndex': i,
          'totalChunks': totalChunks,
          'data': base64Encode(chunk),
        },
      };

      final sent = await _sendFrame(socket, envelope);
      if (!sent) {
        _photoProgressController.add(ble.PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: i / totalChunks,
          status: ble.PhotoTransferStatus.failed,
          errorMessage: 'Failed to send chunk $i',
        ),);
        return false;
      }

      _photoProgressController.add(ble.PhotoTransferProgress(
        messageId: messageId,
        peerId: peerId,
        progress: (i + 1) / totalChunks,
        status: i + 1 == totalChunks
            ? ble.PhotoTransferStatus.completed
            : ble.PhotoTransferStatus.inProgress,
      ),);
    }

    return true;
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
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final envelope = {
      'v': 1,
      'type': 'photo_preview',
      'fromPeerId': _lanPeerId,
      'fromUserId': _ownUserId,
      'payload': {
        'messageId': messageId,
        'photoId': photoId,
        'originalSize': originalSize,
        'thumbnail': base64Encode(thumbnailBytes),
      },
    };
    return _sendFrame(socket, envelope);
  }

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final envelope = {
      'v': 1,
      'type': 'photo_request',
      'fromPeerId': _lanPeerId,
      'fromUserId': _ownUserId,
      'payload': {
        'messageId': messageId,
        'photoId': photoId,
      },
    };
    return _sendFrame(socket, envelope);
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
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final binaryData = BinaryMessageCodec.encodeAnchorDrop(
      senderId: _ownUserId ?? '',
    );
    return _sendBinaryFrame(socket, binaryData);
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
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final binaryData = BinaryMessageCodec.encodeReaction(
      senderId: _ownUserId ?? '',
      targetMessageId: messageId,
      emoji: emoji,
      action: action,
    );
    return _sendBinaryFrame(socket, binaryData);
  }

  @override
  Stream<ble.ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  // ==================== Utilities ====================

  @override
  bool isPeerReachable(String peerId) => _peers.containsKey(peerId);

  // ==================== Private — UDP ====================

  void _sendBeacon() {
    if (_udpSocket == null || _profile == null || _lanPeerId == null) return;

    final beacon = {
      'v': 1,
      'type': 'anchor_hello',
      'userId': _ownUserId,
      'lanPeerId': _lanPeerId,
      'tcpPort': _tcpPort,
      'name': _profile!.name,
      if (_profile!.age != null) 'age': _profile!.age,
      if (_profile!.bio != null) 'bio': _profile!.bio,
      if (_profile!.position != null) 'position': _profile!.position,
      if (_profile!.interests != null && _profile!.interests!.isNotEmpty)
        'interests': _profile!.interests,
      if (_profile!.publicKeyHex != null) 'pk': _profile!.publicKeyHex,
      if (_profile!.signingPublicKeyHex != null) 'spk': _profile!.signingPublicKeyHex,
    };

    try {
      final data = utf8.encode(jsonEncode(beacon));
      final dest = _broadcastAddress ?? InternetAddress('255.255.255.255');
      _udpSocket!.send(data, dest, _udpPort);
    } catch (e) {
      // Recompute broadcast address and retry once — IP may have changed.
      _computeBroadcastAddress().then((addr) {
        if (addr != null && addr.address != _broadcastAddress?.address) {
          _broadcastAddress = addr;
          Logger.info('LAN: Broadcast address updated to $addr', _tag);
        } else {
          Logger.warning('LAN: Beacon send failed — disabling LAN: $e', _tag);
          _disableLan();
        }
      });
    }
  }

  /// Computes the subnet directed broadcast address for the Wi-Fi interface.
  /// iOS blocks 255.255.255.255 (limited broadcast); directed broadcast works.
  /// Assumes /24 subnet — the most common setup on ship/hotel Wi-Fi.
  Future<InternetAddress?> _computeBroadcastAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (!name.startsWith('en') && !name.startsWith('wlan')) continue;
        for (final addr in iface.addresses) {
          if (addr.isLoopback || addr.type != InternetAddressType.IPv4) continue;
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            return InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
          }
        }
      }
    } catch (e) {
      Logger.warning('LAN: Failed to compute broadcast address: $e', _tag);
    }
    return null;
  }

  /// Called when LAN becomes non-functional (no route, socket error, etc.).
  /// Stops the service, notifies TransportManager to fall back to BLE, and
  /// starts a recovery timer that restarts LAN when Wi-Fi returns.
  void _disableLan() {
    if (!_started) return;
    stop();
    _availabilityController.add(false);
    _startRecoveryTimer();
  }

  int _recoveryAttempt = 0;

  void _startRecoveryTimer() {
    _recoveryTimer?.cancel();
    _recoveryAttempt = 0;
    _scheduleRecoveryAttempt();
  }

  /// Schedule the next recovery attempt with exponential backoff (5s → 60s cap).
  void _scheduleRecoveryAttempt() {
    final delaySec = min(5 * pow(2, _recoveryAttempt).toInt(), 60);
    _recoveryTimer = Timer(Duration(seconds: delaySec), () async {
      if (_started) {
        _recoveryTimer = null;
        return;
      }
      final available = await isAvailable;
      if (available) {
        Logger.info('LAN: Wi-Fi returned — restarting LAN transport', _tag);
        _recoveryTimer = null;
        _recoveryAttempt = 0;
        await start();
        if (_started) {
          _availabilityController.add(true);
        }
      } else {
        _recoveryAttempt++;
        _scheduleRecoveryAttempt();
      }
    });
  }

  void _onUdpDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    final datagram = _udpSocket?.receive();
    if (datagram == null) return;

    try {
      final json = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;

      if (json['type'] != 'anchor_hello') return;

      final lanPeerId = json['lanPeerId'] as String?;
      if (lanPeerId == null || lanPeerId == _lanPeerId) return; // Own beacon

      final userId = json['userId'] as String? ?? '';
      final tcpPort = json['tcpPort'] as int? ?? _tcpPortBase;
      final name = json['name'] as String? ?? 'Unknown';
      final age = json['age'] as int?;
      final bio = json['bio'] as String?;
      final position = json['position'] as int?;
      final interests = json['interests'] as String?;
      final pk = json['pk'] as String?;
      final publicKeyHex = (pk != null && pk.length == 64) ? pk : null;
      final spk = json['spk'] as String?;
      final signingPublicKeyHex = (spk != null && spk.length == 64) ? spk : null;
      final ipAddress = datagram.address.address;

      _lastSeen[lanPeerId] = DateTime.now();

      if (!_peers.containsKey(lanPeerId)) {
        // New peer
        final meta = _LanPeerMeta(
          lanPeerId: lanPeerId,
          userId: userId,
          ipAddress: ipAddress,
          tcpPort: tcpPort,
          name: name,
          age: age,
          bio: bio,
          position: position,
          interests: interests,
          publicKeyHex: publicKeyHex,
          signingPublicKeyHex: signingPublicKeyHex,
        );
        _peers[lanPeerId] = meta;

        // Emit without thumbnail first
        _peerDiscoveredController.add(_buildDiscoveredPeer(meta));

        // Request thumbnail asynchronously
        unawaited(_requestThumbnail(lanPeerId));
      } else {
        // Known peer — check if profile changed
        final existing = _peers[lanPeerId]!;
        if (existing.name != name ||
            existing.age != age ||
            existing.bio != bio ||
            existing.position != position ||
            existing.interests != interests ||
            existing.publicKeyHex != publicKeyHex ||
            existing.signingPublicKeyHex != signingPublicKeyHex) {
          final updated = _LanPeerMeta(
            lanPeerId: lanPeerId,
            userId: userId,
            ipAddress: ipAddress,
            tcpPort: tcpPort,
            name: name,
            age: age,
            bio: bio,
            position: position,
            interests: interests,
            thumbnailBytes: existing.thumbnailBytes,
            publicKeyHex: publicKeyHex,
            signingPublicKeyHex: signingPublicKeyHex,
          );
          _peers[lanPeerId] = updated;
          _peerDiscoveredController.add(_buildDiscoveredPeer(updated));
        }
      }
    } catch (e) {
      Logger.debug('LAN: Failed to parse UDP datagram: $e', _tag);
    }
  }

  void _checkPeerTimeouts() {
    final now = DateTime.now();
    final timedOut = <String>[];

    for (final entry in _lastSeen.entries) {
      if (now.difference(entry.value) > _peerTimeout) {
        timedOut.add(entry.key);
      }
    }

    for (final peerId in timedOut) {
      Logger.debug('LAN: peer $peerId timed out', _tag);
      _peers.remove(peerId);
      _lastSeen.remove(peerId);
      _outgoingConnections.remove(peerId);
      _peerLostController.add(peerId);
    }
  }

  // ==================== Private — TCP ====================

  void _handleIncomingConnection(Socket socket) {
    Logger.debug(
      'LAN: incoming connection from ${socket.remoteAddress.address}',
      _tag,
    );

    final buffer = _FrameBuffer();
    _frameBuffers[socket] = buffer;

    socket.listen(
      (data) {
        buffer.add(data);
        for (final frame in buffer.drain()) {
          _handleFrame(frame, socket.remoteAddress.address, socket);
        }
      },
      onError: (Object e) {
        Logger.debug('LAN: incoming socket error: $e', _tag);
        _frameBuffers.remove(socket);
        socket.destroy();
      },
      onDone: () {
        _frameBuffers.remove(socket);
        socket.destroy();
      },
      cancelOnError: true,
    );
  }

  void _handleFrame(Uint8List frame, String fromIp, Socket replySocket) {
    try {
      // Binary MeshPacket detection: version byte 0x01
      if (frame.isNotEmpty && BinaryMessageCodec.isBinary(frame) && frame[0] == 0x01) {
        _handleBinaryFrame(frame, fromIp);
        return;
      }

      // Legacy JSON path
      final json = jsonDecode(utf8.decode(frame)) as Map<String, dynamic>;
      final type = json['type'] as String?;
      final fromPeerId = json['fromPeerId'] as String?;
      final payload = json['payload'] as Map<String, dynamic>? ?? {};

      if (type == null || fromPeerId == null) return;

      switch (type) {
        case 'chat_message':
          final rawType = payload['messageType'] as String? ?? 'text';
          final ble.MessageType messageType;
          try {
            messageType = ble.MessageType.values.byName(rawType);
          } catch (_) {
            Logger.debug('LAN: unknown messageType "$rawType" — skipping', _tag);
            return;
          }
          _messageReceivedController.add(ble.ReceivedMessage(
            fromPeerId: fromPeerId,
            messageId: payload['messageId'] as String? ?? const Uuid().v4(),
            type: messageType,
            content: payload['content'] as String? ?? '',
            timestamp: DateTime.now(),
            replyToId: payload['replyToId'] as String?,
          ),);

        case 'photo_preview':
          final thumbnailB64 = payload['thumbnail'] as String?;
          if (thumbnailB64 == null) return;
          _photoPreviewReceivedController.add(ble.ReceivedPhotoPreview(
            fromPeerId: fromPeerId,
            messageId: payload['messageId'] as String? ?? const Uuid().v4(),
            photoId: payload['photoId'] as String? ?? const Uuid().v4(),
            thumbnailBytes: base64Decode(thumbnailB64),
            originalSize: payload['originalSize'] as int? ?? 0,
            timestamp: DateTime.now(),
          ),);

        case 'photo_request':
          _photoRequestReceivedController.add(ble.ReceivedPhotoRequest(
            fromPeerId: fromPeerId,
            messageId: payload['messageId'] as String? ?? const Uuid().v4(),
            photoId: payload['photoId'] as String? ?? const Uuid().v4(),
            timestamp: DateTime.now(),
          ),);

        case 'photo_chunk':
          _handlePhotoChunk(fromPeerId, payload);

        case 'noise_hs':
          final step = payload['step'] as int?;
          final dataB64 = payload['data'] as String?;
          if (step != null && dataB64 != null) {
            _noiseHandshakeController.add(ble.NoiseHandshakeReceived(
              fromPeerId: fromPeerId,
              step: step,
              payload: Uint8List.fromList(base64Decode(dataB64)),
            ),);
          }

        case 'drop_anchor':
          _anchorDropReceivedController.add(ble.AnchorDropReceived(
            fromPeerId: fromPeerId,
            timestamp: DateTime.now(),
          ),);

        case 'reaction':
          _reactionReceivedController.add(ble.ReactionReceived(
            fromPeerId: fromPeerId,
            messageId: payload['messageId'] as String? ?? '',
            emoji: payload['emoji'] as String? ?? '',
            action: payload['action'] as String? ?? 'add',
            timestamp: DateTime.now(),
          ),);

        case 'thumb_request':
          // Send our thumbnail back on the same socket
          unawaited(_sendThumbnailResponse(replySocket));

        case 'thumb_response':
          final dataB64 = payload['data'] as String?;
          if (dataB64 != null) {
            _handleThumbnailResponse(fromPeerId, base64Decode(dataB64));
          }

        default:
          Logger.debug('LAN: unknown message type: $type', _tag);
      }
    } catch (e) {
      Logger.error('LAN: Failed to handle frame', e, null, _tag);
    }
  }

  /// Handle a binary MeshPacket received via TCP.
  void _handleBinaryFrame(Uint8List frame, String fromIp) {
    final decoded = BinaryMessageCodec.decode(frame);
    if (decoded == null) {
      Logger.warning('LAN: Failed to decode binary MeshPacket', _tag);
      return;
    }

    final packet = decoded.packet;
    // Resolve sender: look up userId from IP → peer mapping
    final fromPeerId = _resolveUserIdFromIp(fromIp) ?? packet.senderId;

    switch (packet.type) {
      case PacketType.message:
        final chat = BinaryMessageCodec.decodeChatPayload(packet);
        if (chat == null) return;
        _messageReceivedController.add(ble.ReceivedMessage(
          fromPeerId: fromPeerId,
          messageId: packet.messageId,
          type: chat.messageType,
          content: chat.content ?? '',
          timestamp: packet.timestamp,
          replyToId: chat.replyToId,
          isEncrypted: chat.isEncrypted,
        ),);

      case PacketType.handshake:
        final hs = BinaryMessageCodec.decodeHandshakePayload(packet);
        if (hs != null) {
          _noiseHandshakeController.add(ble.NoiseHandshakeReceived(
            fromPeerId: fromPeerId,
            step: hs.step,
            payload: hs.payload,
          ),);
        }

      case PacketType.anchorDrop:
        _anchorDropReceivedController.add(ble.AnchorDropReceived(
          fromPeerId: fromPeerId,
          timestamp: packet.timestamp,
        ),);

      case PacketType.reaction:
        final reaction = BinaryMessageCodec.decodeReactionPayload(packet);
        if (reaction != null) {
          _reactionReceivedController.add(ble.ReactionReceived(
            fromPeerId: fromPeerId,
            messageId: reaction.targetMessageId,
            emoji: reaction.emoji,
            action: reaction.action,
            timestamp: packet.timestamp,
          ),);
        }

      case PacketType.gossipSync:
      case PacketType.gossipRequest:
        // Gossip sync is handled at the BLE layer (GossipSyncService).
        // LAN gossip support can be added later if needed.
        Logger.debug('LAN: gossip packet ignored (handled via BLE)', _tag);

      case PacketType.ack:
      case PacketType.photoPreview:
      case PacketType.photoRequest:
      case PacketType.photoData:
      case PacketType.wifiTransferReady:
      case PacketType.readReceipt:
      case PacketType.peerAnnounce:
      case PacketType.neighborList:
        Logger.debug('LAN: unhandled binary packet type: ${packet.type.name}', _tag);
    }
  }

  /// Resolve a userId from IP address by looking up known peers.
  String? _resolveUserIdFromIp(String ip) {
    for (final entry in _peers.entries) {
      if (entry.value.ipAddress == ip) {
        return entry.value.userId;
      }
    }
    return null;
  }

  void _handlePhotoChunk(String fromPeerId, Map<String, dynamic> payload) {
    final messageId = payload['messageId'] as String? ?? '';
    final photoId = payload['photoId'] as String? ?? '';
    final chunkIndex = payload['chunkIndex'] as int? ?? 0;
    final totalChunks = payload['totalChunks'] as int? ?? 1;
    final dataB64 = payload['data'] as String?;

    if (dataB64 == null) return;

    final pending = _pendingPhotos.putIfAbsent(
      messageId,
      () => _PendingPhoto(
        fromPeerId: fromPeerId,
        messageId: messageId,
        photoId: photoId,
        totalChunks: totalChunks,
      ),
    );

    pending.chunks[chunkIndex] = base64Decode(dataB64);

    // Emit progress
    _photoProgressController.add(ble.PhotoTransferProgress(
      messageId: messageId,
      peerId: fromPeerId,
      progress: pending.chunks.length / totalChunks,
      status: pending.chunks.length == totalChunks
          ? ble.PhotoTransferStatus.completed
          : ble.PhotoTransferStatus.inProgress,
    ),);

    // Check if all chunks received
    if (pending.chunks.length == totalChunks) {
      // Reassemble in order
      final sortedKeys = pending.chunks.keys.toList()..sort();
      final assembled = <int>[];
      for (final key in sortedKeys) {
        assembled.addAll(pending.chunks[key]!);
      }

      _photoReceivedController.add(ble.ReceivedPhoto(
        fromPeerId: fromPeerId,
        messageId: messageId,
        photoBytes: Uint8List.fromList(assembled),
        timestamp: DateTime.now(),
        photoId: photoId.isNotEmpty ? photoId : null,
      ),);

      _pendingPhotos.remove(messageId);
    }
  }

  void _handleThumbnailResponse(String fromPeerId, Uint8List thumbnailBytes) {
    final meta = _peers[fromPeerId];
    if (meta == null) return;

    meta.thumbnailBytes = thumbnailBytes;
    _peerDiscoveredController.add(_buildDiscoveredPeer(meta));
    Logger.debug('LAN: received thumbnail for $fromPeerId', _tag);
  }

  Future<void> _requestThumbnail(String peerId) async {
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return;

    final envelope = {
      'v': 1,
      'type': 'thumb_request',
      'fromPeerId': _lanPeerId,
      'fromUserId': _ownUserId,
      'payload': <String, dynamic>{},
    };
    await _sendFrame(socket, envelope);
  }

  Future<void> _sendThumbnailResponse(Socket socket) async {
    final thumb = _profile?.thumbnailBytes;
    if (thumb == null) return;

    final envelope = {
      'v': 1,
      'type': 'thumb_response',
      'fromPeerId': _lanPeerId,
      'fromUserId': _ownUserId,
      'payload': {
        'data': base64Encode(thumb),
      },
    };
    await _sendFrame(socket, envelope);
  }

  /// Get an existing outgoing socket for [peerId] or connect a new one.
  /// Returns null if the peer is unknown or the connection fails.
  Future<Socket?> _getOrConnectSocket(String peerId) async {
    // Return existing socket if still open
    final existing = _outgoingConnections[peerId];
    if (existing != null) {
      return existing;
    }

    final meta = _peers[peerId];
    if (meta == null) {
      Logger.warning('LAN: no known peer for id $peerId', _tag);
      return null;
    }

    try {
      final socket = await Socket.connect(
        meta.ipAddress,
        meta.tcpPort,
        timeout: const Duration(seconds: 5),
      );

      // Set up read loop on the new outgoing socket
      final buffer = _FrameBuffer();
      _frameBuffers[socket] = buffer;

      socket.listen(
        (data) {
          buffer.add(data);
          for (final frame in buffer.drain()) {
            _handleFrame(frame, meta.ipAddress, socket);
          }
        },
        onError: (Object e) {
          Logger.debug('LAN: outgoing socket error for $peerId: $e', _tag);
          _outgoingConnections.remove(peerId);
          _frameBuffers.remove(socket);
          socket.destroy();
        },
        onDone: () {
          _outgoingConnections.remove(peerId);
          _frameBuffers.remove(socket);
          socket.destroy();
        },
        cancelOnError: true,
      );

      _outgoingConnections[peerId] = socket;
      Logger.debug('LAN: connected to $peerId at ${meta.ipAddress}:${meta.tcpPort}', _tag);
      return socket;
    } catch (e) {
      Logger.error('LAN: Failed to connect to $peerId', e, null, _tag);
      return null;
    }
  }

  /// Write a length-prefixed JSON frame to [socket].
  Future<bool> _sendFrame(Socket socket, Map<String, dynamic> envelope) async {
    try {
      final payload = utf8.encode(jsonEncode(envelope));
      final header = ByteData(4)..setUint32(0, payload.length);
      socket
        ..add(Uint8List.view(header.buffer))
        ..add(payload);
      await socket.flush();
      return true;
    } catch (e) {
      Logger.error('LAN: send failed', e, null, _tag);
      return false;
    }
  }

  /// Write a length-prefixed binary frame to [socket].
  Future<bool> _sendBinaryFrame(Socket socket, Uint8List data) async {
    try {
      final header = ByteData(4)..setUint32(0, data.length);
      socket
        ..add(Uint8List.view(header.buffer))
        ..add(data);
      await socket.flush();
      return true;
    } catch (e) {
      Logger.error('LAN: binary send failed', e, null, _tag);
      return false;
    }
  }

  ble.DiscoveredPeer _buildDiscoveredPeer(_LanPeerMeta meta) {
    return ble.DiscoveredPeer(
      peerId: meta.lanPeerId,
      userId: meta.userId,
      name: meta.name,
      age: meta.age,
      bio: meta.bio,
      position: meta.position,
      interests: meta.interests,
      thumbnailBytes: meta.thumbnailBytes,
      timestamp: DateTime.now(),
      publicKeyHex: meta.publicKeyHex,
      signingPublicKeyHex: meta.signingPublicKeyHex,
    );
  }

  @override
  Stream<ble.NoiseHandshakeReceived> get noiseHandshakeStream =>
      _noiseHandshakeController.stream;

  @override
  Future<bool> sendHandshakeMessage(
      String peerId, int step, Uint8List payload,) async {
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;

    final binaryData = BinaryMessageCodec.encodeHandshake(
      senderId: _ownUserId ?? '',
      step: step,
      handshakePayload: payload,
    );
    return _sendBinaryFrame(socket, binaryData);
  }

  @override
  Future<bool> sendRawBytes(String peerId, Uint8List data) async {
    final socket = await _getOrConnectSocket(peerId);
    if (socket == null) return false;
    return _sendBinaryFrame(socket, data);
  }
}

// Suppress unawaited_futures lint for fire-and-forget async calls.
void unawaited(Future<void> future) {}
