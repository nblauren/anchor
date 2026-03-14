import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../services/ble/ble.dart';

/// Permissions setup screen explaining and requesting BLE permissions
class PermissionsScreen extends StatelessWidget {
  const PermissionsScreen({
    super.key,
    required this.onComplete,
  });

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<BleConnectionBloc, BleConnectionState>(
      listener: (context, state) {
        // Auto-advance when permissions granted and BLE ready
        if (state.status == BleConnectionStatus.ready ||
            state.status == BleConnectionStatus.active) {
          onComplete();
        }
      },
      builder: (context, state) {
        return Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Spacer(),

                  // Bluetooth icon
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryLight.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.bluetooth,
                      size: 64,
                      color: _getIconColor(state.status),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Title
                  Text(
                    _getTitle(state.status),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),

                  // Description
                  Text(
                    _getDescription(state.status),
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 24),

                  // Permission requirements list
                  if (state.status == BleConnectionStatus.noPermission ||
                      state.status == BleConnectionStatus.initial)
                    _buildRequirementsList(),

                  const Spacer(),

                  // Action button
                  _buildActionButton(context, state),

                  const SizedBox(height: 16),

                  // Skip option (for testing)
                  TextButton(
                    key: const Key('permissions_skip_btn'),
                    onPressed: onComplete,
                    child: const Text('Skip for now'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Color _getIconColor(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.active:
      case BleConnectionStatus.ready:
        return AppTheme.success;
      case BleConnectionStatus.disabled:
      case BleConnectionStatus.unavailable:
      case BleConnectionStatus.error:
        return AppTheme.error;
      default:
        return AppTheme.primaryLight;
    }
  }

  String _getTitle(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.unavailable:
        return 'Bluetooth Not Available';
      case BleConnectionStatus.disabled:
        return 'Turn On Bluetooth';
      case BleConnectionStatus.noPermission:
        return 'Enable Permissions';
      case BleConnectionStatus.ready:
      case BleConnectionStatus.active:
        return 'You\'re All Set!';
      case BleConnectionStatus.error:
        return 'Something Went Wrong';
      default:
        return 'Enable Bluetooth';
    }
  }

  String _getDescription(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.unavailable:
        return 'This device doesn\'t support Bluetooth Low Energy, which is required for Anchor to discover nearby people.';
      case BleConnectionStatus.disabled:
        return 'Anchor uses Bluetooth to discover and connect with people nearby. Please turn on Bluetooth to continue.';
      case BleConnectionStatus.noPermission:
        return 'Anchor needs Bluetooth and Location permissions to find people around you. Your location is never stored or shared.';
      case BleConnectionStatus.ready:
      case BleConnectionStatus.active:
        return 'Bluetooth is ready. You can now discover and connect with people nearby!';
      case BleConnectionStatus.error:
        return 'There was a problem setting up Bluetooth. Please try again.';
      default:
        return 'Grant permissions to start discovering people nearby.';
    }
  }

  Widget _buildRequirementsList() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildRequirementItem(
            Icons.bluetooth,
            'Bluetooth',
            'To discover nearby devices',
          ),
          const Divider(height: 24),
          _buildRequirementItem(
            Icons.location_on_outlined,
            'Location',
            'Required by ${Platform.isIOS ? 'iOS' : 'Android'} for Bluetooth',
          ),
          if (Platform.isAndroid) ...[
            const Divider(height: 24),
            _buildRequirementItem(
              Icons.person_search,
              'Nearby Devices',
              'To find other Anchor users',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRequirementItem(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.primaryLight.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppTheme.primaryLight, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(BuildContext context, BleConnectionState state) {
    final bloc = context.read<BleConnectionBloc>();

    switch (state.status) {
      case BleConnectionStatus.unavailable:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onComplete,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Continue Anyway'),
          ),
        );

      case BleConnectionStatus.disabled:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => bloc.add(const RequestBlePermissions()),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Open Settings'),
          ),
        );

      case BleConnectionStatus.noPermission:
      case BleConnectionStatus.initial:
      case BleConnectionStatus.checking:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: state.status == BleConnectionStatus.checking
                ? null
                : () => bloc.add(const RequestBlePermissions()),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: state.status == BleConnectionStatus.checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Grant Permissions'),
          ),
        );

      case BleConnectionStatus.ready:
      case BleConnectionStatus.starting:
      case BleConnectionStatus.active:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onComplete,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: AppTheme.success,
            ),
            child: const Text('Continue'),
          ),
        );

      case BleConnectionStatus.error:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => bloc.add(const InitializeBleConnection()),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Text('Try Again'),
          ),
        );
    }
  }
}
