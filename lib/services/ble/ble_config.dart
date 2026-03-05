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
