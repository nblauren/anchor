/// Configuration for BLE service
class BleConfig {
  const BleConfig({
    this.useMockService = false,
    this.enableMeshRelay = true,
    this.meshTtl = 3,
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

  /// Whether to use MockBleService (for testing) or real BLE service
  final bool useMockService;

  /// Enable mesh relay (messages hop through intermediate devices)
  final bool enableMeshRelay;

  /// Time-to-live for relay messages (number of hops)
  final int meshTtl;

  /// Size of photo chunks for transfer (4-8KB recommended)
  final int photoChunkSize;

  /// Timeout for message delivery confirmation
  final Duration messageTimeout;

  /// Interval between scans
  final Duration scanInterval;

  /// BLE advertising interval
  final Duration advertisingInterval;

  /// Time before considering a peer as "lost"
  final Duration peerLostTimeout;

  /// Maximum thumbnail size for BLE broadcast (15KB limit)
  final int maxThumbnailSize;

  /// Maximum photo size for transfer
  final int maxPhotoSize;

  /// Number of direct peers above which "high density" mode is activated
  final int highDensityPeerThreshold;

  /// Scan pause duration in high-density mode (longer = less battery drain)
  final Duration highDensityScanPause;

  /// Scan pause duration in normal mode
  final Duration normalScanPause;

  /// Probability of relaying a mesh message in high-density mode (0.0–1.0).
  /// Reduces relay flood when many peers are in range.
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
