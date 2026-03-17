import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../core/utils/logger.dart';
import 'ble_models.dart';
import 'ble_service_interface.dart';

/// Mock BLE service for testing UI without real Bluetooth
class MockBleService implements BleServiceInterface {
  MockBleService();

  final _uuid = const Uuid();
  final _random = Random();

  // Status
  BleStatus _status = BleStatus.disabled;
  bool _isScanning = false;
  bool _isBroadcasting = false;

  // Stream controllers
  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _peerIdChangedController =
      StreamController<PeerIdChanged>.broadcast();
  final _messageReceivedController = StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController = StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();
  final _anchorDropReceivedController = StreamController<AnchorDropReceived>.broadcast();
  final _reactionReceivedController = StreamController<ReactionReceived>.broadcast();
  final _photoPreviewReceivedController =
      StreamController<ReceivedPhotoPreview>.broadcast();
  final _photoRequestReceivedController =
      StreamController<ReceivedPhotoRequest>.broadcast();

  // Mock data
  final Map<String, DiscoveredPeer> _visiblePeers = {};
  final Map<String, Timer> _peerTimeoutTimers = {};
  Timer? _mockDiscoveryTimer;
  Timer? _peerLostTimer;

  // Cached avatar bytes, loaded on first discovery
  final List<Uint8List?> _avatarCache = List.filled(10, null);
  bool _avatarsLoaded = false;

  static const _mockAvatarPaths = [
    'assets/mock_avatar/uifaces-human-avatar.jpg',
    'assets/mock_avatar/uifaces-human-avatar-2.jpg',
    'assets/mock_avatar/uifaces-human-avatar-3.jpg',
    'assets/mock_avatar/uifaces-human-avatar-4.jpg',
    'assets/mock_avatar/uifaces-human-avatar-5.jpg',
    'assets/mock_avatar/uifaces-human-avatar-6.jpg',
    'assets/mock_avatar/uifaces-human-avatar-7.jpg',
    'assets/mock_avatar/uifaces-human-avatar-8.jpg',
    'assets/mock_avatar/uifaces-human-avatar-9.jpg',
    'assets/mock_avatar/uifaces-human-avatar-10.jpg',
  ];

  Future<void> _loadAvatarsIfNeeded() async {
    if (_avatarsLoaded) return;
    for (var i = 0; i < _mockAvatarPaths.length; i++) {
      try {
        final data = await rootBundle.load(_mockAvatarPaths[i]);
        _avatarCache[i] = data.buffer.asUint8List();
      } catch (_) {
        _avatarCache[i] = null;
      }
    }
    _avatarsLoaded = true;
  }

  // Mock peer data
  static const _mockNames = [
    'Alex',
    'Jordan',
    'Taylor',
    'Morgan',
    'Casey',
    'Riley',
    'Quinn',
    'Avery',
    'Sage',
    'Phoenix',
  ];

  static const _mockBios = [
    'Adventure seeker and coffee enthusiast',
    'Music lover. Dog person.',
    'Traveling the world one step at a time',
    'Foodie looking for restaurant buddies',
    'Tech nerd by day, gamer by night',
    'Artist and creative soul',
    'Fitness junkie. Early bird.',
    null,
    'Bookworm with a sense of humor',
    'Nature lover and outdoor adventurer',
  ];

  // ==================== Lifecycle ====================

  @override
  Future<void> initialize() async {
    Logger.info('MockBleService: Initializing...', 'BLE');
    await Future.delayed(const Duration(milliseconds: 500));
    _setStatus(BleStatus.ready);
    Logger.info('MockBleService: Initialized', 'BLE');
  }

  @override
  Future<void> start() async {
    Logger.info('MockBleService: Starting...', 'BLE');
    await startScanning();
    await broadcastProfile(const BroadcastPayload(
      userId: 'mock-user',
      name: 'Mock User',
    ));
  }

  @override
  Future<void> stop() async {
    Logger.info('MockBleService: Stopping...', 'BLE');
    await stopScanning();
    await stopBroadcasting();
    _setStatus(BleStatus.ready);
  }

  @override
  Future<void> dispose() async {
    Logger.info('MockBleService: Disposing...', 'BLE');
    _mockDiscoveryTimer?.cancel();
    _peerLostTimer?.cancel();
    for (final timer in _peerTimeoutTimers.values) {
      timer.cancel();
    }

    await _statusController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _peerIdChangedController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();
  }

  // ==================== Status ====================

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async => true;

  @override
  Future<bool> isBluetoothEnabled() async => true;

  @override
  Future<bool> requestPermissions() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return true;
  }

  @override
  Future<bool> hasPermissions() async => true;

  void _setStatus(BleStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  void _updateActiveStatus() {
    if (_isScanning && _isBroadcasting) {
      _setStatus(BleStatus.active);
    } else if (_isScanning) {
      _setStatus(BleStatus.scanning);
    } else if (_isBroadcasting) {
      _setStatus(BleStatus.advertising);
    } else {
      _setStatus(BleStatus.ready);
    }
  }

  // ==================== Broadcasting ====================

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    Logger.info('MockBleService: Broadcasting profile for ${payload.name}', 'BLE');
    _isBroadcasting = true;
    _updateActiveStatus();
  }

  @override
  Future<void> stopBroadcasting() async {
    Logger.info('MockBleService: Stopped broadcasting', 'BLE');
    _isBroadcasting = false;
    _updateActiveStatus();
  }

  @override
  bool get isBroadcasting => _isBroadcasting;

  // ==================== Discovery ====================

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream => _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Stream<PeerIdChanged> get peerIdChangedStream =>
      _peerIdChangedController.stream;

  @override
  Future<void> startScanning() async {
    if (_isScanning) return;

    Logger.info('MockBleService: Starting scan...', 'BLE');
    _isScanning = true;
    _updateActiveStatus();

    // Start discovering mock peers over time
    _startMockDiscovery();
  }

  @override
  Future<void> stopScanning() async {
    Logger.info('MockBleService: Stopping scan...', 'BLE');
    _isScanning = false;
    _mockDiscoveryTimer?.cancel();
    _updateActiveStatus();
  }

  @override
  bool get isScanning => _isScanning;

  void _startMockDiscovery() {
    var peersDiscovered = 0;
    final totalPeers = 5 + _random.nextInt(6); // 5-10 peers

    _loadAvatarsIfNeeded().then((_) {
      _mockDiscoveryTimer = Timer.periodic(
        Duration(milliseconds: 800 + _random.nextInt(1500)),
        (timer) {
          if (!_isScanning || peersDiscovered >= totalPeers) {
            timer.cancel();
            return;
          }

          _discoverMockPeer(peersDiscovered);
          peersDiscovered++;
        },
      );
    });

    // Periodically update RSSI for visible peers
    _peerLostTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _updateMockPeerSignals();
    });
  }

  void _discoverMockPeer(int index) {
    final peerId = _uuid.v4();
    final nameIndex = index % _mockNames.length;
    final avatarIndex = nameIndex % _avatarCache.length;

    final peer = DiscoveredPeer(
      peerId: peerId,
      name: _mockNames[nameIndex],
      age: 22 + _random.nextInt(15),
      bio: _mockBios[nameIndex],
      thumbnailBytes: _avatarCache[avatarIndex],
      rssi: -45 - _random.nextInt(35), // -45 to -80
      timestamp: DateTime.now(),
    );

    _visiblePeers[peerId] = peer;
    _peerDiscoveredController.add(peer);

    Logger.info('MockBleService: Discovered peer ${peer.name} (${peer.peerId.substring(0, 8)})', 'BLE');

    // Set timeout for this peer (they might "leave")
    _peerTimeoutTimers[peerId] = Timer(
      Duration(seconds: 30 + _random.nextInt(60)),
      () => _losePeer(peerId),
    );
  }

  void _updateMockPeerSignals() {
    for (final peerId in _visiblePeers.keys.toList()) {
      final peer = _visiblePeers[peerId]!;

      // Randomly update RSSI
      final newRssi = (peer.rssi ?? -60) + _random.nextInt(11) - 5;
      final clampedRssi = newRssi.clamp(-90, -30);

      final updatedPeer = peer.copyWith(
        rssi: clampedRssi,
        timestamp: DateTime.now(),
      );

      _visiblePeers[peerId] = updatedPeer;
      _peerDiscoveredController.add(updatedPeer);
    }
  }

  void _losePeer(String peerId) {
    if (_visiblePeers.containsKey(peerId)) {
      final peer = _visiblePeers.remove(peerId);
      _peerTimeoutTimers.remove(peerId)?.cancel();
      _peerLostController.add(peerId);
      Logger.info('MockBleService: Lost peer ${peer?.name} ($peerId)', 'BLE');
    }
  }

  // ==================== Messaging ====================

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    Logger.info(
      'MockBleService: Sending ${payload.type.name} to ${peerId.substring(0, 8)}',
      'BLE',
    );

    // Simulate network delay
    await Future.delayed(Duration(milliseconds: 200 + _random.nextInt(300)));

    // 95% success rate
    if (_random.nextDouble() > 0.05) {
      // Schedule echo response after delay
      _scheduleEchoResponse(peerId, payload);
      return true;
    }

    Logger.warning('MockBleService: Message send failed (simulated)', 'BLE');
    return false;
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream => _messageReceivedController.stream;

  void _scheduleEchoResponse(String peerId, MessagePayload originalPayload) {
    if (originalPayload.type != MessageType.text) return;

    Timer(Duration(milliseconds: 800 + _random.nextInt(700)), () {
      final peer = _visiblePeers[peerId];
      final peerName = peer?.name ?? 'Unknown';

      final responses = [
        'Hey! Got your message',
        'Thanks for reaching out!',
        'Nice to hear from you',
        'Cool! Let me think about that',
        'Interesting point!',
      ];

      final response = ReceivedMessage(
        fromPeerId: peerId,
        messageId: _uuid.v4(),
        type: MessageType.text,
        content: '${responses[_random.nextInt(responses.length)]} - $peerName',
        timestamp: DateTime.now(),
      );

      _messageReceivedController.add(response);
      Logger.info('MockBleService: Echo response from ${peerId.substring(0, 8)}', 'BLE');
    });
  }

  // ==================== Drop Anchor ====================

  @override
  Future<bool> sendDropAnchor(String peerId) async {
    Logger.info(
      'MockBleService: Sending drop_anchor to ${peerId.substring(0, 8)}',
      'BLE',
    );

    await Future.delayed(Duration(milliseconds: 150 + _random.nextInt(200)));

    if (!_visiblePeers.containsKey(peerId)) {
      Logger.warning('MockBleService: Peer not reachable for drop anchor', 'BLE');
      return false;
    }

    // Simulate the peer "dropping anchor back" after a short delay
    Timer(Duration(milliseconds: 1000 + _random.nextInt(1500)), () {
      final drop = AnchorDropReceived(
        fromPeerId: peerId,
        timestamp: DateTime.now(),
      );
      _anchorDropReceivedController.add(drop);
      Logger.info('MockBleService: Simulated anchor drop back from ${peerId.substring(0, 8)}', 'BLE');
    });

    return true;
  }

  @override
  Stream<AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  // ==================== Reactions ====================

  @override
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async {
    Logger.info(
      'MockBleService: Sending reaction $emoji ($action) to ${peerId.substring(0, 8)}',
      'BLE',
    );
    await Future.delayed(Duration(milliseconds: 100 + _random.nextInt(100)));
    return _visiblePeers.containsKey(peerId);
  }

  @override
  Stream<ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  // ==================== Photo Transfer ====================

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId, {String? photoId}) async {
    Logger.info(
      'MockBleService: Starting photo transfer to ${peerId.substring(0, 8)} (${photoData.length} bytes)',
      'BLE',
    );

    // Simulate transfer progress
    _simulatePhotoTransfer(peerId, photoData, messageId);

    return true;
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream => _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream => _photoReceivedController.stream;

  @override
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    Logger.info(
      'MockBleService: sendPhotoPreview $photoId (${thumbnailBytes.length}B)',
      'BLE',
    );
    // Simulate sending and immediately fire a mock photo_request back
    // so the UI flow can be tested end-to-end in the mock environment.
    Timer(Duration(milliseconds: 1200 + _random.nextInt(800)), () {
      _photoRequestReceivedController.add(ReceivedPhotoRequest(
        fromPeerId: peerId,
        messageId: _uuid.v4(),
        photoId: photoId,
        timestamp: DateTime.now(),
      ));
      Logger.info('MockBleService: Simulated photo_request for $photoId', 'BLE');
    });
    return true;
  }

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    Logger.info('MockBleService: sendPhotoRequest $photoId', 'BLE');
    return true;
  }

  @override
  Stream<ReceivedPhotoPreview> get photoPreviewReceivedStream =>
      _photoPreviewReceivedController.stream;

  @override
  Stream<ReceivedPhotoRequest> get photoRequestReceivedStream =>
      _photoRequestReceivedController.stream;

  @override
  Future<bool> fetchFullProfilePhotos(String peerId) async {
    Logger.info('MockBleService: fetchFullProfilePhotos (no-op in mock)', 'BLE');
    return false;
  }

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {
    Logger.info('MockBleService: Cancelled photo transfer $messageId', 'BLE');
    _photoProgressController.add(PhotoTransferProgress(
      messageId: messageId,
      peerId: '',
      progress: 0,
      status: PhotoTransferStatus.cancelled,
    ));
  }

  void _simulatePhotoTransfer(String peerId, Uint8List photoData, String messageId) {
    // Emit starting status
    _photoProgressController.add(PhotoTransferProgress(
      messageId: messageId,
      peerId: peerId,
      progress: 0,
      status: PhotoTransferStatus.starting,
    ));

    // Simulate progress over ~3 seconds
    var progress = 0.0;
    Timer.periodic(const Duration(milliseconds: 150), (timer) {
      progress += 0.05 + _random.nextDouble() * 0.05;

      if (progress >= 1.0) {
        timer.cancel();
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: 1.0,
          status: PhotoTransferStatus.completed,
        ));
        Logger.info('MockBleService: Photo transfer completed', 'BLE');
      } else {
        _photoProgressController.add(PhotoTransferProgress(
          messageId: messageId,
          peerId: peerId,
          progress: progress,
          status: PhotoTransferStatus.inProgress,
        ));
      }
    });
  }

  // ==================== Utilities ====================

  @override
  int? getSignalStrength(String peerId) {
    return _visiblePeers[peerId]?.rssi;
  }

  @override
  bool isPeerReachable(String peerId) {
    return _visiblePeers.containsKey(peerId);
  }

  @override
  String? getPeerIdForUserId(String userId) => null;

  @override
  List<String> get visiblePeerIds => _visiblePeers.keys.toList();

  @override
  Future<void> setBatterySaverMode(bool enabled) async {}

  bool _meshRelayEnabled = true;

  @override
  Future<void> setMeshRelayMode(bool enabled) async {
    _meshRelayEnabled = enabled;
  }

  @override
  bool get isMeshRelayEnabled => _meshRelayEnabled;

  @override
  int get meshRelayedPeerCount => 0;

  @override
  int get meshRoutingTableSize => 0;

  @override
  Future<void> sendHandshakeMessage(
      String peerId, int step, Uint8List payload) async {}

  @override
  Stream<NoiseHandshakeReceived> get noiseHandshakeStream =>
      const Stream.empty();
}
