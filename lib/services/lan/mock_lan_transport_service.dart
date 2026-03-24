import 'dart:async';
import 'dart:typed_data';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_models.dart' as ble;
import 'package:anchor/services/lan/lan_transport_service.dart';

/// Mock implementation of [LanTransportService] for testing and simulator
/// environments where a real network interface may not be available.
///
/// Set [simulateAvailable] = true to test the LAN transport path.
/// All send methods return false by default.
class MockLanTransportService implements LanTransportService {
  MockLanTransportService({this.simulateAvailable = false});

  final bool simulateAvailable;
  bool _initialized = false;

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

  @override
  Future<void> initialize({
    required String ownUserId,
    required ble.BroadcastPayload profile,
  }) async {
    _initialized = true;
    Logger.info('MockLanTransportService initialized', 'MockLan');
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
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
    _initialized = false;
  }

  @override
  Future<bool> get isAvailable async => _initialized && simulateAvailable;

  @override
  Stream<bool> get availabilityStream => _availabilityController.stream;

  @override
  Stream<ble.DiscoveredPeer> get peerDiscoveredStream =>
      _peerDiscoveredController.stream;

  @override
  Stream<String> get peerLostStream => _peerLostController.stream;

  @override
  Future<void> updateProfile(ble.BroadcastPayload payload) async {}

  @override
  Future<bool> sendMessage(String peerId, ble.MessagePayload payload) async =>
      false;

  @override
  Stream<ble.ReceivedMessage> get messageReceivedStream =>
      _messageReceivedController.stream;

  @override
  Future<bool> sendPhoto(
    String peerId,
    Uint8List photoData,
    String messageId, {
    String? photoId,
  }) async =>
      false;

  @override
  Stream<ble.PhotoTransferProgress> get photoProgressStream =>
      _photoProgressController.stream;

  @override
  Stream<ble.ReceivedPhoto> get photoReceivedStream =>
      _photoReceivedController.stream;

  @override
  Future<bool> sendPhotoPreview({
    required String peerId,
    required String messageId,
    required String photoId,
    required Uint8List thumbnailBytes,
    required int originalSize,
  }) async =>
      false;

  @override
  Future<bool> sendPhotoRequest({
    required String peerId,
    required String messageId,
    required String photoId,
  }) async =>
      false;

  @override
  Stream<ble.ReceivedPhotoPreview> get photoPreviewReceivedStream =>
      _photoPreviewReceivedController.stream;

  @override
  Stream<ble.ReceivedPhotoRequest> get photoRequestReceivedStream =>
      _photoRequestReceivedController.stream;

  @override
  Future<bool> sendDropAnchor(String peerId) async => false;

  @override
  Stream<ble.AnchorDropReceived> get anchorDropReceivedStream =>
      _anchorDropReceivedController.stream;

  @override
  Future<bool> sendReaction({
    required String peerId,
    required String messageId,
    required String emoji,
    required String action,
  }) async =>
      false;

  @override
  Stream<ble.ReactionReceived> get reactionReceivedStream =>
      _reactionReceivedController.stream;

  @override
  Future<bool> sendHandshakeMessage(
          String peerId, int step, Uint8List payload,) async =>
      false;

  @override
  Stream<ble.NoiseHandshakeReceived> get noiseHandshakeStream =>
      _noiseHandshakeController.stream;

  @override
  Future<bool> sendRawBytes(String peerId, Uint8List data) async => false;

  @override
  bool isPeerReachable(String peerId) => false;
}
