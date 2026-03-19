import 'dart:async';
import 'dart:typed_data';

import '../../core/utils/logger.dart';
import 'high_speed_transfer_service.dart';
import 'nearby_models.dart';

/// Mock implementation of [HighSpeedTransferService] for testing and
/// simulator environments where Wi-Fi Direct / Nearby is unavailable.
///
/// Always reports [isAvailable] = false so callers fall back to BLE.
/// Optionally set [simulateAvailable] = true to test the Wi-Fi path
/// with synthetic delays.
class MockHighSpeedTransferService implements HighSpeedTransferService {
  MockHighSpeedTransferService({this.simulateAvailable = false});

  /// When true, pretends Wi-Fi Direct is available and simulates transfers
  /// with a 500 ms delay. Useful for UI testing.
  final bool simulateAvailable;

  final _progressController =
      StreamController<NearbyTransferProgress>.broadcast();
  final _payloadController =
      StreamController<NearbyPayloadReceived>.broadcast();

  bool _initialized = false;

  @override
  Future<void> initialize({required String ownUserId}) async {
    _initialized = true;
    Logger.info('MockHighSpeedTransferService initialized', 'MockNearby');
  }

  @override
  Future<bool> get isAvailable async => _initialized && simulateAvailable;

  @override
  Future<bool> sendPayload({
    required String transferId,
    required String peerId,
    required Uint8List data,
    Duration timeout = const Duration(seconds: 15),
    void Function()? onAdvertising,
  }) async {
    if (!simulateAvailable) return false;

    onAdvertising?.call();

    _progressController.add(NearbyTransferProgress(
      transferId: transferId,
      peerId: peerId,
      status: NearbyTransferStatus.transferring,
      progress: 0.5,
    ));

    await Future.delayed(const Duration(milliseconds: 500));

    _progressController.add(NearbyTransferProgress(
      transferId: transferId,
      peerId: peerId,
      status: NearbyTransferStatus.completed,
      progress: 1.0,
    ));

    return true;
  }

  @override
  Future<bool> receivePayload({
    required String transferId,
    required String peerId,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!simulateAvailable) return false;

    await Future.delayed(const Duration(milliseconds: 500));

    _payloadController.add(NearbyPayloadReceived(
      transferId: transferId,
      fromPeerId: peerId,
      data: Uint8List(0),
      timestamp: DateTime.now(),
    ));

    return true;
  }

  @override
  Future<void> cancelTransfer(String transferId) async {
    _progressController.add(NearbyTransferProgress(
      transferId: transferId,
      peerId: '',
      status: NearbyTransferStatus.cancelled,
      progress: 0,
    ));
  }

  @override
  Stream<NearbyTransferProgress> get transferProgressStream =>
      _progressController.stream;

  @override
  Stream<NearbyPayloadReceived> get payloadReceivedStream =>
      _payloadController.stream;

  @override
  Future<void> dispose() async {
    await _progressController.close();
    await _payloadController.close();
    _initialized = false;
  }
}
