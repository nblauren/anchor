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

  /// Create config from environment variables
  factory BleConfig.fromEnvironment() {
    const useMock = bool.fromEnvironment('USE_MOCK_BLE', defaultValue: false);

    return const BleConfig(
      useMockService: useMock,
    );
  }

  /// Development config (always uses mock)
  static const development = BleConfig(
    useMockService: true,
  );

  /// Production config
  static const BleConfig production = BleConfig(
    useMockService: false,
  );

  @override
  String toString() {
    return 'BleConfig(useMock: $useMockService)';
  }
}
