/// Centralized JSON field keys for BLE, LAN, and mesh message protocols.
///
/// Extracting hardcoded string literals into named constants:
/// - Prevents typos and inconsistencies across transport layers
/// - Enables IDE refactoring and usage tracking
/// - Provides a single reference for the wire protocol schema
abstract class MessageKeys {
  // ── Common fields ──────────────────────────────────────────────────────

  /// Message type discriminator (e.g. 'peer_announce', 'photo_start').
  static const String type = 'type';

  /// Sender's app-level userId.
  static const String senderId = 'sender_id';

  /// Sender's display name (included in some payloads for convenience).
  static const String senderName = 'sender_name';

  /// Unique message identifier (UUID).
  static const String messageId = 'message_id';

  /// Alternative camelCase message ID used in some LAN/legacy payloads.
  static const String messageIdCamel = 'messageId';

  /// Message content (plaintext text body).
  static const String content = 'content';

  /// Reply-to message ID for threaded conversations.
  static const String replyToId = 'reply_to_id';

  /// Destination user ID for directed mesh routing.
  static const String destinationId = 'destination_id';

  /// Wire format version (1 = encrypted).
  static const String version = 'v';

  /// Nonce for encrypted payloads.
  static const String nonce = 'n';

  /// Ciphertext for encrypted payloads.
  static const String ciphertext = 'c';

  /// Message type index (enum ordinal).
  static const String messageType = 'message_type';

  /// Timestamp (ISO 8601 string).
  static const String timestamp = 'timestamp';

  // ── Profile fields ─────────────────────────────────────────────────────

  /// App-level user ID.
  static const String userId = 'userId';

  /// Display name.
  static const String name = 'name';

  /// User age.
  static const String age = 'age';

  /// User bio.
  static const String bio = 'bio';

  /// Position preference (int enum).
  static const String position = 'pos';

  /// Interests (comma-separated string).
  static const String interests = 'int';

  /// X25519 public key (64-char hex) for E2EE key exchange.
  static const String publicKey = 'pk';

  /// Ed25519 signing public key (64-char hex) for mesh signature verification.
  static const String signingPublicKey = 'spk';

  /// Profile version (monotonically increasing integer).
  static const String profileVersion = 'pv';

  /// Primary thumbnail byte size (from GATT profile characteristic).
  static const String thumbnailSize = 'thumbnail_size';

  /// Number of profile photos available via fff4.
  static const String photoCount = 'photo_count';

  /// Sizes of individual photos in the fff4 concatenated blob.
  static const String fullPhotoSizes = 'full_photo_sizes';

  // ── Mesh / relay fields ────────────────────────────────────────────────

  /// Time-to-live hop counter for mesh relay.
  static const String ttl = 'ttl';

  /// Ordered list of user IDs the message has traversed.
  static const String relayPath = 'relay_path';

  /// List of neighbor user IDs (neighbor_list message).
  static const String peers = 'peers';

  /// Ed25519 signature (base64-encoded).
  static const String signature = 'sig';

  // ── Peer announce fields ───────────────────────────────────────────────

  /// BLE peripheral UUID of the announced peer.
  static const String peerId = 'peer_id';

  /// App-level userId of the announced peer.
  static const String peerUserId = 'peer_user_id';

  /// Base64-encoded thumbnail in peer announce.
  static const String thumbnailB64 = 'thumbnail_b64';

  // ── Photo transfer fields ──────────────────────────────────────────────

  /// Photo identifier (UUID).
  static const String photoId = 'photo_id';

  /// Total number of binary chunks for a photo transfer.
  static const String totalChunks = 'total_chunks';

  /// Total byte size of the photo.
  static const String totalSize = 'total_size';

  /// Original byte size of the full photo (in preview payloads).
  static const String originalSize = 'original_size';

  /// Total number of thumbnail chunks for a preview transfer.
  static const String thumbnailChunks = 'thumbnail_chunks';

  /// Base64-encoded chunk data (legacy JSON photo_chunk).
  static const String data = 'data';

  /// Chunk index (legacy JSON photo_chunk).
  static const String chunkIndex = 'chunk_index';

  // ── Noise handshake fields ─────────────────────────────────────────────

  /// Handshake step number (1, 2, or 3).
  static const String step = 'step';

  /// Handshake payload (base64-encoded).
  static const String payload = 'payload';

  // ── Reaction fields ────────────────────────────────────────────────────

  /// Emoji character for a reaction.
  static const String emoji = 'emoji';

  /// Reaction action ('add' or 'remove').
  static const String action = 'action';

  // ── LAN transport fields ───────────────────────────────────────────────

  /// LAN-specific peer identifier (UUID, distinct from BLE peer ID).
  static const String lanPeerId = 'lanPeerId';

  /// TCP port for LAN messaging.
  static const String tcpPort = 'tcpPort';

  /// Sender's LAN peer ID (in TCP frame envelope).
  static const String fromPeerId = 'fromPeerId';

  /// Sender's app userId (in TCP frame envelope).
  static const String fromUserId = 'fromUserId';

  /// Nested payload object in TCP frame envelope.
  static const String payloadObj = 'payload';

  /// Photo ID (camelCase, used in LAN photo payloads).
  static const String photoIdCamel = 'photoId';

  /// Chunk index (camelCase, used in LAN photo payloads).
  static const String chunkIndexCamel = 'chunkIndex';

  /// Total chunks (camelCase, used in LAN photo payloads).
  static const String totalChunksCamel = 'totalChunks';

  /// Original size (camelCase, used in LAN photo payloads).
  static const String originalSizeCamel = 'originalSize';

  /// Thumbnail data (base64, used in LAN photo preview).
  static const String thumbnail = 'thumbnail';

  /// Reply-to ID (camelCase, used in LAN chat payloads).
  static const String replyToIdCamel = 'replyToId';

  /// Message type string (camelCase, used in LAN chat payloads).
  static const String messageTypeCamel = 'messageType';

  /// Content field (camelCase alias).
  static const String contentCamel = 'content';

  // ── Gossip sync fields ─────────────────────────────────────────────────

  /// Golomb-Coded Set data (base64-encoded).
  static const String gcs = 'gcs';

  /// Message count in gossip sync payloads (reuses 'n' key).
  static const String gossipCount = 'n';

  // ── LAN-specific position/interests (non-abbreviated) ──────────────────

  /// Position (full word form used in LAN beacons).
  static const String positionFull = 'position';

  /// Interests (full word form used in LAN beacons).
  static const String interestsFull = 'interests';
}

/// Message type string values used in the 'type' field.
///
/// These are the wire-protocol type discriminators sent as JSON values
/// in the 'type' field of BLE and LAN messages.
abstract class MessageTypes {
  // ── Discovery / mesh ───────────────────────────────────────────────────

  /// Peer announcement broadcast via mesh relay.
  static const String peerAnnounce = 'peer_announce';

  /// Neighbor list for mesh routing table maintenance.
  static const String neighborList = 'neighbor_list';

  /// LAN beacon (UDP discovery).
  static const String anchorHello = 'anchor_hello';

  // ── Profile exchange ───────────────────────────────────────────────────

  /// Request peer's profile via fff3 bidirectional channel.
  static const String profileRequest = 'profile_request';

  /// Response with profile data via fff3 bidirectional channel.
  static const String profileData = 'profile_data';

  // ── Chat / messaging ───────────────────────────────────────────────────

  /// Standard text or chat message (legacy JSON path).
  static const String message = 'message';

  /// LAN chat message type.
  static const String chatMessage = 'chat_message';

  // ── Photo transfer ─────────────────────────────────────────────────────

  /// Start of a binary photo transfer (metadata).
  static const String photoStart = 'photo_start';

  /// Legacy JSON photo chunk.
  static const String photoChunk = 'photo_chunk';

  /// Photo preview (thumbnail for consent flow).
  static const String photoPreview = 'photo_preview';

  /// Request to download a full photo.
  static const String photoRequest = 'photo_request';

  // ── Signals ────────────────────────────────────────────────────────────

  /// Wi-Fi Direct transfer ready signal.
  static const String wifiTransferReady = 'wifiTransferReady';

  /// Transfer complete signal.
  static const String transferComplete = 'transfer_complete';

  /// Read receipt signal.
  static const String readReceipt = 'read_receipt';

  // ── Interactions ───────────────────────────────────────────────────────

  /// Drop anchor signal.
  static const String dropAnchor = 'drop_anchor';

  /// Message reaction (emoji).
  static const String reaction = 'reaction';

  // ── E2EE ───────────────────────────────────────────────────────────────

  /// Noise_XK handshake message.
  static const String noiseHandshake = 'noise_hs';

  // ── Gossip sync ──────────────────────────────────────────────────────

  /// Gossip sync message (GCS-based reconciliation).
  static const String gossipSync = 'gossip_sync';

  /// Gossip request message (missing message IDs).
  static const String gossipRequest = 'gossip_request';

  // ── Thumbnail exchange ─────────────────────────────────────────────────

  /// Request peer's thumbnail via TCP.
  static const String thumbRequest = 'thumb_request';

  /// Response with thumbnail data via TCP.
  static const String thumbResponse = 'thumb_response';
}
