// ignore_for_file: must_be_immutable

import 'dart:async';
import 'dart:typed_data';

import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/ble_service_interface.dart';

/// Controllable [BleServiceInterface] for unit and widget tests.
///
/// All stream events are injected via the public StreamControllers, giving
/// tests full control over discovery, messaging, and photo events without
/// requiring any Bluetooth hardware or platform channels.
///
/// Usage:
/// ```dart
/// final fake = FakeBleService();
/// // Simulate a peer arriving
/// fake.emitPeerDiscovered(DiscoveredPeer(...));
/// // Simulate receiving a message
/// fake.emitMessage(ReceivedMessage(...));
/// ```
class FakeBleService implements BleServiceInterface {
  FakeBleService();

  // ── Stream controllers (test-injectable) ──────────────────────────────────

  final _statusController = StreamController<BleStatus>.broadcast();
  final _peerDiscoveredController = StreamController<DiscoveredPeer>.broadcast();
  final _peerLostController = StreamController<String>.broadcast();
  final _peerIdChangedController = StreamController<PeerIdChanged>.broadcast();
  final _messageReceivedController = StreamController<ReceivedMessage>.broadcast();
  final _photoProgressController = StreamController<PhotoTransferProgress>.broadcast();
  final _photoReceivedController = StreamController<ReceivedPhoto>.broadcast();
  final _anchorDropReceivedController = StreamController<AnchorDropReceived>.broadcast();
  final _reactionReceivedController = StreamController<ReactionReceived>.broadcast();
  final _photoPreviewReceivedController = StreamController<ReceivedPhotoPreview>.broadcast();
  final _photoRequestReceivedController = StreamController<ReceivedPhotoRequest>.broadcast();

  // ── Recorded calls (for verification) ────────────────────────────────────

  final List<String> sendMessageCalls = [];
  final List<String> sendDropAnchorCalls = [];
  final List<String> sendPhotoPreviewCalls = [];
  final List<String> sendPhotoRequestCalls = [];
  final List<String> fetchFullProfilePhotosCalls = [];
  bool startScanningCalled = false;
  bool stopScanningCalled = false;
  bool broadcastProfileCalled = false;

  // ── Control flags ─────────────────────────────────────────────────────────

  BleStatus _status = BleStatus.ready;
  bool _isScanning = false;
  bool _isBroadcasting = false;
  bool _meshEnabled = true;
  bool sendMessageResult = true;
  bool sendDropAnchorResult = true;

  // ── Injection helpers ─────────────────────────────────────────────────────

  void emitPeerDiscovered(DiscoveredPeer peer) =>
      _peerDiscoveredController.add(peer);

  void emitPeerLost(String peerId) => _peerLostController.add(peerId);

  void emitMessage(ReceivedMessage msg) => _messageReceivedController.add(msg);

  void emitAnchorDrop(AnchorDropReceived drop) =>
      _anchorDropReceivedController.add(drop);

  void emitPeerIdChanged(PeerIdChanged change) =>
      _peerIdChangedController.add(change);

  void emitPhotoPreview(ReceivedPhotoPreview preview) =>
      _photoPreviewReceivedController.add(preview);

  void emitPhotoRequest(ReceivedPhotoRequest request) =>
      _photoRequestReceivedController.add(request);

  void emitPhotoProgress(PhotoTransferProgress progress) =>
      _photoProgressController.add(progress);

  void emitPhotoReceived(ReceivedPhoto photo) =>
      _photoReceivedController.add(photo);

  void setStatus(BleStatus s) {
    _status = s;
    _statusController.add(s);
  }

  // ── BleServiceInterface implementation ────────────────────────────────────

  @override
  Future<void> initialize() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    _isScanning = false;
    _isBroadcasting = false;
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _peerDiscoveredController.close();
    await _peerLostController.close();
    await _peerIdChangedController.close();
    await _messageReceivedController.close();
    await _photoProgressController.close();
    await _photoReceivedController.close();
    await _anchorDropReceivedController.close();
    await _reactionReceivedController.close();
    await _photoPreviewReceivedController.close();
    await _photoRequestReceivedController.close();
  }

  @override
  BleStatus get status => _status;

  @override
  Stream<BleStatus> get statusStream => _statusController.stream;

  @override
  Future<bool> isBluetoothAvailable() async => true;

  @override
  Future<bool> isBluetoothEnabled() async => true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> hasPermissions() async => true;

  @override
  Future<void> broadcastProfile(BroadcastPayload payload) async {
    broadcastProfileCalled = true;
    _isBroadcasting = true;
  }

  @override
  Future<void> stopBroadcasting() async => _isBroadcasting = false;

  @override
  bool get isBroadcasting => _isBroadcasting;

  @override
  Stream<DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Stream<PeerIdChanged> get peerIdChangedStream =>
      _peerIdChangedController.stream;

  @override
  Future<void> startScanning() async {
    startScanningCalled = true;
    _isScanning = true;
  }

  @override
  Future<void> stopScanning() async {
    stopScanningCalled = true;
    _isScanning = false;
  }

  @override
  bool get isScanning => _isScanning;

  @override
  Future<bool> sendMessage(String peerId, MessagePayload payload) async {
    sendMessageCalls.add(peerId);
    return sendMessageResult;
  }

  @override
  Stream<ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  @override
  Future<bool> sendPhoto(String peerId, Uint8List photoData, String messageId,
      {String? photoId}) async => true;

  @override
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async {
    sendPhotoPreviewCalls.add(peerId);
    return true;
  }

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async {
    sendPhotoRequestCalls.add(peerId);
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
    fetchFullProfilePhotosCalls.add(peerId);
    return true;
  }

  @override
  Stream<PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<void> cancelPhotoTransfer(String messageId) async {}

  @override
  Future<void> setBatterySaverMode(bool enabled) async {}

  @override
  int? getSignalStrength(String peerId) => null;

  @override
  bool isPeerReachable(String peerId) => false;

  @override
  List<String> get visiblePeerIds => const [];

  @override
  Future<bool> sendDropAnchor(String peerId) async {
    sendDropAnchorCalls.add(peerId);
    return sendDropAnchorResult;
  }

  @override
  Stream<AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  @override
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async => true;

  @override
  Stream<ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  @override
  Future<void> setMeshRelayMode(bool enabled) async => _meshEnabled = enabled;

  @override
  bool get isMeshRelayEnabled => _meshEnabled;

  @override
  int get meshRelayedPeerCount => 0;

  @override
  int get meshRoutingTableSize => 0;

  @override
  String? getPeerIdForUserId(String userId) => null;

  @override
  Future<void> sendHandshakeMessage(
      String peerId, int step, Uint8List payload) async {}

  @override
  Stream<NoiseHandshakeReceived> get noiseHandshakeStream =>
      const Stream.empty();
}
