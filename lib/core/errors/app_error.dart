/// Base class for application errors with user-friendly messages
abstract class AppError implements Exception {
  const AppError(this.message, [this.originalError]);

  final String message;
  final Object? originalError;

  /// User-friendly message for display in UI
  String get userMessage => message;

  /// Whether the error is recoverable (user can retry)
  bool get isRecoverable => true;

  /// Error code for logging and analytics
  String get code;

  @override
  String toString() => '[$code] $message';
}

// ==================== Database Errors ====================

/// Database-related errors
class DatabaseError extends AppError {
  const DatabaseError(super.message, [super.originalError, this.operation]);

  final DatabaseOperation? operation;

  @override
  String get code => 'DB_${operation?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (operation) {
      case DatabaseOperation.read:
        return 'Unable to load data. Please try again.';
      case DatabaseOperation.write:
        return 'Unable to save data. Please try again.';
      case DatabaseOperation.delete:
        return 'Unable to delete data. Please try again.';
      case DatabaseOperation.initialize:
        return 'Unable to start the app. Please restart.';
      case null:
        return 'A data error occurred. Please try again.';
    }
  }

  @override
  bool get isRecoverable => operation != DatabaseOperation.initialize;
}

enum DatabaseOperation { read, write, delete, initialize }

// ==================== BLE Errors ====================

/// BLE/Bluetooth-related errors
class BleError extends AppError {
  const BleError(super.message, [super.originalError, this.type]);

  final BleErrorType? type;

  @override
  String get code => 'BLE_${type?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (type) {
      case BleErrorType.unavailable:
        return 'Bluetooth is not available on this device.';
      case BleErrorType.disabled:
        return 'Please turn on Bluetooth to discover people nearby.';
      case BleErrorType.permissionDenied:
        return 'Bluetooth permission is required to discover people nearby.';
      case BleErrorType.connectionFailed:
        return 'Connection failed. Please try again.';
      case BleErrorType.sendFailed:
        return 'Message failed to send. Please try again.';
      case BleErrorType.timeout:
        return 'Connection timed out. Please try again.';
      case BleErrorType.sdkError:
        return 'Communication error. Please restart the app.';
      case null:
        return 'A connection error occurred. Please try again.';
    }
  }

  @override
  bool get isRecoverable =>
      type != BleErrorType.unavailable && type != BleErrorType.sdkError;
}

enum BleErrorType {
  unavailable,
  disabled,
  permissionDenied,
  connectionFailed,
  sendFailed,
  timeout,
  sdkError,
}

// ==================== Permission Errors ====================

/// Permission-related errors
class PermissionError extends AppError {
  const PermissionError(super.message, [super.originalError, this.permission]);

  final PermissionType? permission;

  @override
  String get code => 'PERM_${permission?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (permission) {
      case PermissionType.bluetooth:
        return 'Bluetooth permission is needed to find people nearby.';
      case PermissionType.location:
        return 'Location permission is needed for Bluetooth discovery.';
      case PermissionType.camera:
        return 'Camera permission is needed to take photos.';
      case PermissionType.photos:
        return 'Photo library access is needed to choose photos.';
      case PermissionType.notifications:
        return 'Notifications permission is needed for message alerts.';
      case null:
        return 'Permission is required. Please grant access in Settings.';
    }
  }

  @override
  bool get isRecoverable => true;
}

enum PermissionType {
  bluetooth,
  location,
  camera,
  photos,
  notifications,
}

// ==================== Image Errors ====================

/// Image processing errors
class ImageError extends AppError {
  const ImageError(super.message, [super.originalError, this.operation]);

  final ImageOperation? operation;

  @override
  String get code => 'IMG_${operation?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (operation) {
      case ImageOperation.pick:
        return 'Unable to select image. Please try again.';
      case ImageOperation.compress:
        return 'Unable to process image. Please try another.';
      case ImageOperation.save:
        return 'Unable to save image. Please try again.';
      case ImageOperation.delete:
        return 'Unable to delete image. Please try again.';
      case ImageOperation.load:
        return 'Unable to load image. It may be corrupted.';
      case null:
        return 'An image error occurred. Please try again.';
    }
  }
}

enum ImageOperation { pick, compress, save, delete, load }

// ==================== Profile Errors ====================

/// Profile-related errors
class ProfileError extends AppError {
  const ProfileError(super.message, [super.originalError, this.type]);

  final ProfileErrorType? type;

  @override
  String get code => 'PROFILE_${type?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (type) {
      case ProfileErrorType.notFound:
        return 'Profile not found. Please set up your profile.';
      case ProfileErrorType.saveFailed:
        return 'Unable to save profile. Please try again.';
      case ProfileErrorType.loadFailed:
        return 'Unable to load profile. Please try again.';
      case ProfileErrorType.photoFailed:
        return 'Unable to update photo. Please try again.';
      case ProfileErrorType.validation:
        return 'Please check your profile information.';
      case null:
        return 'A profile error occurred. Please try again.';
    }
  }
}

enum ProfileErrorType {
  notFound,
  saveFailed,
  loadFailed,
  photoFailed,
  validation,
}

// ==================== Chat Errors ====================

/// Chat-related errors
class ChatError extends AppError {
  const ChatError(super.message, [super.originalError, this.type]);

  final ChatErrorType? type;

  @override
  String get code => 'CHAT_${type?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (type) {
      case ChatErrorType.sendFailed:
        return 'Message failed to send. Please try again.';
      case ChatErrorType.loadFailed:
        return 'Unable to load messages. Please try again.';
      case ChatErrorType.photoFailed:
        return 'Photo failed to send. Please try again.';
      case ChatErrorType.peerOffline:
        return "User is not nearby. Message will be delivered when they're in range.";
      case null:
        return 'A messaging error occurred. Please try again.';
    }
  }
}

enum ChatErrorType {
  sendFailed,
  loadFailed,
  photoFailed,
  peerOffline,
}

// ==================== Discovery Errors ====================

/// Discovery-related errors
class DiscoveryError extends AppError {
  const DiscoveryError(super.message, [super.originalError, this.type]);

  final DiscoveryErrorType? type;

  @override
  String get code => 'DISC_${type?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (type) {
      case DiscoveryErrorType.scanFailed:
        return 'Unable to scan for nearby users. Please try again.';
      case DiscoveryErrorType.loadFailed:
        return 'Unable to load discovered users. Please try again.';
      case DiscoveryErrorType.blockFailed:
        return 'Unable to block user. Please try again.';
      case null:
        return 'A discovery error occurred. Please try again.';
    }
  }
}

enum DiscoveryErrorType {
  scanFailed,
  loadFailed,
  blockFailed,
}

// ==================== Network Errors ====================

/// Network-related errors (for future use)
class NetworkError extends AppError {
  const NetworkError(super.message, [super.originalError, this.type]);

  final NetworkErrorType? type;

  @override
  String get code => 'NET_${type?.name.toUpperCase() ?? 'UNKNOWN'}';

  @override
  String get userMessage {
    switch (type) {
      case NetworkErrorType.noConnection:
        return 'No internet connection. Please check your connection.';
      case NetworkErrorType.timeout:
        return 'Connection timed out. Please try again.';
      case NetworkErrorType.serverError:
        return 'Server error. Please try again later.';
      case null:
        return 'A network error occurred. Please try again.';
    }
  }
}

enum NetworkErrorType {
  noConnection,
  timeout,
  serverError,
}
