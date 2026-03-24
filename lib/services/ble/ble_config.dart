import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Anchor BLE GATT service and characteristic UUIDs.
///
/// Centralized here so every sub-module references the same constants.
/// These are proper 128-bit random UUIDs (not the BLE SIG 0000xxxx range)
/// to avoid collisions with other apps and third-party BLE devices.
abstract class BleUuids {
  /// Primary Anchor GATT service.
  static final service =
      UUID.fromString('b4b605d3-7718-42a5-88ec-6fbe8c6c3cb9');

  /// fff1 equivalent — Profile metadata (READ, NOTIFY).
  static final profileChar =
      UUID.fromString('02c57431-2cc9-4b9c-9472-37a1efa02bc6');

  /// fff2 equivalent — Thumbnail data (READ).
  static final thumbnailChar =
      UUID.fromString('e353cf0a-85c2-4d2a-b4b1-8a0fa1bfb1f1');

  /// fff3 equivalent — Messaging (WRITE, NOTIFY).
  static final messagingChar =
      UUID.fromString('6c4c3e0a-8d29-48b6-83c3-2d19ee02d398');

  /// fff4 equivalent — Full photos (READ, NOTIFY).
  static final fullPhotosChar =
      UUID.fromString('79118c43-92a1-48b7-98af-d28a0a9dbc72');

  /// fff5 equivalent — Reverse path (WRITE, NOTIFY).
  static final reversePathChar =
      UUID.fromString('9386c87b-79fb-4b5c-ab38-d0e6a0fffd03');
}

/// Runtime configuration for the Anchor BLE service.
///
/// Shared between [BleFacade] (production, uses
/// `bluetooth_low_energy`) and [MockBleService] (tests).
///
/// Use [BleConfig.development] in unit/widget tests and
/// [BleConfig.production] for release builds. All fields have sensible
/// defaults tuned for the cruise-ship environment (high peer density,
/// battery sensitivity, metal interference).
class BleConfig {
  const BleConfig({
    this.useMockService = false,
    this.enableMeshRelay = true,
    this.meshTtl = 7,
    this.photoChunkSize = 4096,
    this.messageTimeout = const Duration(seconds: 30),
    this.scanInterval = const Duration(seconds: 30),
    this.advertisingInterval = const Duration(milliseconds: 500),
    this.peerLostTimeout = const Duration(minutes: 2),
    this.maxThumbnailSize = 15 * 1024, // 15KB max for BLE payload
    this.maxPhotoSize = 500 * 1024, // 500KB max for transfer
    this.highDensityPeerThreshold = 15,
    this.highDensityScanPause = const Duration(seconds: 12),
    this.normalScanPause = const Duration(seconds: 5),
    this.highDensityRelayProbability = 0.65,
    this.rssiFloorNormal = -90,
    this.rssiFloorHighDensity = -78,
    this.dutyCyclePeriod = const Duration(seconds: 15),
    this.dutyCycleNormal = 0.33,
    this.dutyCycleBatterySaver = 0.13,
    this.dutyCycleHighDensity = 0.20,
  });

  /// Use [MockBleService] instead of the real BLE stack.
  /// Set to true in unit/widget tests; always false in production.
  final bool useMockService;

  /// Enable TTL-based mesh relay: text messages are forwarded through
  /// currently-connected intermediate peers. Photos are never relayed.
  final bool enableMeshRelay;

  /// Maximum hops a relayed message may travel (decremented at each relay node).
  /// Messages with TTL == 0 are dropped without forwarding.
  final int meshTtl;

  /// Preferred chunk size (bytes) for photo binary transfers over fff3/fff4.
  /// The actual chunk size is capped to the negotiated GATT MTU at runtime.
  final int photoChunkSize;

  /// GATT write timeout for a single message or chunk delivery.
  final Duration messageTimeout;

  /// Legacy field — use [normalScanPause] / [highDensityScanPause] instead.
  final Duration scanInterval;

  /// BLE advertising interval sent to the platform peripheral manager.
  final Duration advertisingInterval;

  /// Duration of no GATT activity after which a peer is declared "lost".
  /// A [peerLost] event is emitted and the peer is removed from the grid.
  final Duration peerLostTimeout;

  /// Maximum size (bytes) of the primary thumbnail broadcast on fff2.
  /// [ImageService] compresses thumbnails to stay within this budget.
  /// The NSFW classifier runs before a photo is allowed to be set here.
  final int maxThumbnailSize;

  /// Maximum size (bytes) of a full photo before compression is applied
  /// by [ImageService] prior to transfer.
  final int maxPhotoSize;

  /// Number of directly-visible peers that triggers high-density mode,
  /// which increases scan pauses and throttles relay probability.
  final int highDensityPeerThreshold;

  /// Scan pause duration used in high-density mode (≥[highDensityPeerThreshold]
  /// visible peers). Longer pause reduces battery drain and RF congestion.
  final Duration highDensityScanPause;

  /// Scan pause duration used in normal mode (<[highDensityPeerThreshold] peers).
  final Duration normalScanPause;

  /// Probability (0.0–1.0) that a relay-eligible message is actually forwarded
  /// in high-density mode. Probabilistic dropping reduces mesh flooding when
  /// many peers are simultaneously relaying the same message.
  final double highDensityRelayProbability;

  /// Minimum acceptable RSSI in normal mode. Peers weaker than this are
  /// ignored by the scanner. -90 dBm is extremely weak but still usable
  /// for text messaging in metal ship corridors.
  final int rssiFloorNormal;

  /// Minimum acceptable RSSI in high-density mode. When many peers are
  /// visible, tighten the RSSI floor to focus on peers actually in useful
  /// range and reduce connection churn from distant/flaky peripherals.
  final int rssiFloorHighDensity;

  /// Total period for one duty cycle (ON + OFF).
  /// E.g. 15 seconds: scan for 5s ON, then 10s OFF at 0.33 ratio.
  final Duration dutyCyclePeriod;

  /// Fraction of [dutyCyclePeriod] spent scanning in normal mode.
  /// 0.33 = 5s ON / 10s OFF in a 15s period.
  final double dutyCycleNormal;

  /// Fraction of [dutyCyclePeriod] spent scanning in battery saver mode.
  /// 0.13 = ~2s ON / 13s OFF in a 15s period.
  final double dutyCycleBatterySaver;

  /// Fraction of [dutyCyclePeriod] spent scanning in high-density mode.
  /// 0.20 = 3s ON / 12s OFF in a 15s period.
  final double dutyCycleHighDensity;

  /// Create config from environment variables
  factory BleConfig.fromEnvironment() {
    return BleConfig.production;
  }

  /// Development config (always uses mock)
  static const development = BleConfig(
    useMockService: true,
  );

  /// Production config
  static const BleConfig production = BleConfig(
    
  );

  @override
  String toString() {
    return 'BleConfig(useMock: $useMockService)';
  }
}
