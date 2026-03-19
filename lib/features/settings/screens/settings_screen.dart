import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../injection.dart';
import '../../../services/ble/ble_connection_bloc.dart';
import '../../../services/database_service.dart';
import '../../../services/panic_service.dart';
import '../../profile/bloc/profile_bloc.dart';
import '../../profile/bloc/profile_event.dart';
import '../../profile/screens/profile_setup_screen.dart';
import 'blocked_users_screen.dart';
import 'debug_menu_screen.dart';

/// Settings screen with app configuration options
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Profile section
          _buildSectionHeader('Profile'),
          _buildTile(
            context,
            icon: Icons.person,
            title: 'Edit Profile',
            subtitle: 'Update your name, bio, and photos',
            onTap: () => _openEditProfile(context),
          ),

          const Divider(height: 32),

          // Privacy section
          _buildSectionHeader('Privacy'),
          _buildTile(
            context,
            icon: Icons.block,
            title: 'Blocked Users',
            subtitle: 'Manage blocked people',
            onTap: () => _openBlockedUsers(context),
          ),
          _buildTile(
            context,
            icon: Icons.warning_amber_rounded,
            title: 'Panic Mode',
            subtitle: 'Emergency wipe — erases all data instantly',
            onTap: () => _confirmPanicMode(context),
            textColor: Colors.red,
          ),

          const Divider(height: 32),

          // Discovery section
          _buildSectionHeader('Discovery'),
          BlocBuilder<BleConnectionBloc, BleConnectionState>(
            builder: (context, bleState) => _buildSwitchTile(
              context,
              icon: Icons.visibility,
              title: 'Visible to Others',
              subtitle: 'Allow nearby people to discover you',
              value: bleState.isVisible,
              onChanged: (value) {
                HapticFeedback.selectionClick();
                context.read<BleConnectionBloc>().add(SetVisibility(value));
              },
            ),
          ),
          BlocBuilder<BleConnectionBloc, BleConnectionState>(
            builder: (context, bleState) => _buildSwitchTile(
              context,
              icon: Icons.battery_saver,
              title: 'Battery Saver Mode',
              subtitle: 'Reduce scanning frequency to save battery',
              value: bleState.isBatterySaver,
              onChanged: (value) {
                HapticFeedback.selectionClick();
                context.read<BleConnectionBloc>().add(SetBatterySaver(value));
              },
            ),
          ),
          BlocBuilder<BleConnectionBloc, BleConnectionState>(
            builder: (context, bleState) => _buildSwitchTile(
              context,
              icon: Icons.hub,
              title: 'Mesh Relay',
              subtitle:
                  'Extend range by forwarding messages through nearby devices',
              value: bleState.isMeshRelay,
              onChanged: (value) {
                HapticFeedback.selectionClick();
                context.read<BleConnectionBloc>().add(SetMeshRelay(value));
              },
            ),
          ),

          const Divider(height: 32),

          // Data section
          _buildSectionHeader('Data'),
          _buildTile(
            context,
            icon: Icons.delete_sweep,
            title: 'Clear Discovery History',
            subtitle: 'Remove all discovered peers',
            onTap: () => _showClearDiscoveryDialog(context),
            textColor: AppTheme.warning,
          ),
          _buildTile(
            context,
            icon: Icons.delete_forever,
            title: 'Clear All Data',
            subtitle: 'Delete profile and all app data',
            onTap: () => _showClearAllDialog(context),
            textColor: AppTheme.error,
          ),

          const Divider(height: 32),

          // Debug section (only in debug mode)
          _buildSectionHeader('Developer'),
          _buildTile(
            context,
            icon: Icons.bug_report,
            title: 'Debug Menu',
            subtitle: 'Testing tools and diagnostics',
            onTap: () => _openDebugMenu(context),
          ),

          const Divider(height: 32),

          // About section
          _buildSectionHeader('About'),
          _buildTile(
            context,
            icon: Icons.info_outline,
            title: 'App Version',
            subtitle: '1.0.0 (Build 1)',
            onTap: null,
          ),
          _buildTile(
            context,
            icon: Icons.code,
            title: 'Open Source Licenses',
            subtitle: 'Third-party libraries',
            onTap: () => _showLicenses(context),
          ),

          const SizedBox(height: 32),

          // App branding
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.anchor,
                  size: 32,
                  color: AppTheme.primaryLight.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Anchor',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const Text(
                  'Connect. Offline. Together.',
                  style: TextStyle(
                    color: AppTheme.textHint,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    Color? textColor,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: (textColor ?? AppTheme.primaryLight).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: textColor ?? AppTheme.primaryLight,
          size: 20,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: textColor ?? AppTheme.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            )
          : null,
      trailing: onTap != null
          ? const Icon(
              Icons.chevron_right,
              color: AppTheme.textSecondary,
            )
          : null,
      onTap: onTap != null
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
    );
  }

  Widget _buildSwitchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppTheme.primaryLight.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          color: AppTheme.primaryLight,
          size: 20,
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            )
          : null,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppTheme.primaryLight,
      ),
    );
  }

  void _openEditProfile(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: context.read<ProfileBloc>(),
          child: ProfileSetupScreen(
            isEditing: true,
            onComplete: () {
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  void _openBlockedUsers(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const BlockedUsersScreen(),
      ),
    );
  }

  void _openDebugMenu(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DebugMenuScreen(),
      ),
    );
  }

  void _showClearDiscoveryDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Clear Discovery History?'),
        content: const Text(
          'This will remove all discovered peers from your history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final db = getIt<DatabaseService>();
              await db.peerRepository.clearOldPeers(Duration.zero);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Discovery history cleared')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showClearAllDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text('Delete All Data?'),
        content: const Text(
          'This will permanently delete your profile, all messages, and app data. You will need to set up your profile again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final db = getIt<DatabaseService>();
              await db.clearAllData();
              if (context.mounted) {
                // Reload profile to trigger setup flow
                context.read<ProfileBloc>().add(const LoadProfile());
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );
  }

  void _confirmPanicMode(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.darkCard,
        title: const Text(
          'Emergency Wipe',
          style: TextStyle(color: Colors.red),
        ),
        content: const Text(
          'This will PERMANENTLY destroy:\n\n'
          '  - All encryption keys\n'
          '  - Your profile and photos\n'
          '  - All messages and conversations\n'
          '  - All app data and preferences\n\n'
          'This cannot be undone. The app will restart as if freshly installed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final panicService = getIt<PanicService>();
              await panicService.executeEmergencyWipe();
              if (context.mounted) {
                context.read<ProfileBloc>().add(const LoadProfile());
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('WIPE EVERYTHING'),
          ),
        ],
      ),
    );
  }

  void _showLicenses(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: 'Anchor',
      applicationVersion: '1.0.0',
      applicationIcon: const Padding(
        padding: EdgeInsets.all(16),
        child: Icon(
          Icons.anchor,
          size: 48,
          color: AppTheme.primaryLight,
        ),
      ),
    );
  }
}
