/// Base class for application errors
abstract class AppError implements Exception {
  const AppError(this.message, [this.originalError]);

  final String message;
  final Object? originalError;

  @override
  String toString() => 'AppError: $message';
}

/// Database-related errors
class DatabaseError extends AppError {
  const DatabaseError(super.message, [super.originalError]);
}

/// BLE/Bluetooth-related errors
class BleError extends AppError {
  const BleError(super.message, [super.originalError]);
}

/// Image processing errors
class ImageError extends AppError {
  const ImageError(super.message, [super.originalError]);
}

/// Profile-related errors
class ProfileError extends AppError {
  const ProfileError(super.message, [super.originalError]);
}

/// Chat-related errors
class ChatError extends AppError {
  const ChatError(super.message, [super.originalError]);
}

/// Discovery-related errors
class DiscoveryError extends AppError {
  const DiscoveryError(super.message, [super.originalError]);
}

/// Permission-related errors
class PermissionError extends AppError {
  const PermissionError(super.message, [super.originalError]);
}
