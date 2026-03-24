import 'dart:io';
import 'dart:typed_data';

import 'package:anchor/core/constants/profile_constants.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/features/profile/bloc/profile_state.dart';
import 'package:anchor/services/ble/ble.dart' as ble;
import 'package:anchor/services/image_service.dart' show resolvePhotoPath;
import 'package:anchor/services/transport/transport.dart';

/// Encapsulates the logic for broadcasting a user's profile over the
/// transport layer (BLE, Wi-Fi Aware, LAN).
///
/// Extracted from [ProfileBloc] to keep the bloc focused on state management
/// and isolate the transport/BLE side effects.
class ProfileBroadcastService {
  ProfileBroadcastService({
    required TransportManager transportManager,
  }) : _transportManager = transportManager;

  final TransportManager _transportManager;

  /// Build a [ble.BroadcastPayload] from the current profile state and
  /// broadcast it via the transport manager.
  ///
  /// Also initializes and starts the transport manager on the first call
  /// (idempotent for subsequent calls).
  Future<void> broadcast(ProfileState state) async {
    if (state.profileId == null || state.name == null) {
      Logger.warning('Cannot broadcast - no profile', 'ProfileBroadcastService');
      return;
    }

    try {
      // Collect thumbnails for all profile photos in display order.
      final sortedPhotos = state.sortedPhotos;
      final allThumbnails = <Uint8List>[];

      Logger.info(
        'broadcast: photos=${sortedPhotos.length}',
        'ProfileBroadcastService',
      );

      for (final photo in sortedPhotos) {
        final resolvedPath = await resolvePhotoPath(photo.thumbnailPath);
        if (resolvedPath != null) {
          final bytes = await File(resolvedPath).readAsBytes();
          allThumbnails.add(bytes);
        }
      }

      final payload = ble.BroadcastPayload(
        userId: state.profileId!,
        name: state.name!,
        age: state.age,
        bio: state.bio,
        position: state.position,
        interests: state.interestIds.isNotEmpty
            ? ProfileConstants.encodeInterests(state.interestIds)
            : null,
        thumbnailBytes: allThumbnails.isNotEmpty ? allThumbnails.first : null,
        thumbnailsList: allThumbnails.isNotEmpty ? allThumbnails : null,
      );

      // Initialize TransportManager on first broadcast (idempotent).
      await _transportManager.initialize(
        ownUserId: state.profileId!,
        profile: payload,
      );
      Logger.debug('broadcast: transport initialized', 'ProfileBroadcastService');
      await _transportManager.start();
      Logger.debug('broadcast: transport started', 'ProfileBroadcastService');

      // Broadcast via all active transports.
      await _transportManager.broadcastProfile(payload);

      Logger.info(
        'Profile broadcast (${allThumbnails.length} photos, '
        'primary: ${allThumbnails.isNotEmpty ? allThumbnails.first.length : 0}B, '
        'transport: ${_transportManager.activeTransport})',
        'ProfileBroadcastService',
      );
    } catch (e) {
      Logger.error('Failed to broadcast profile', e, null, 'ProfileBroadcastService');
    }
  }
}
