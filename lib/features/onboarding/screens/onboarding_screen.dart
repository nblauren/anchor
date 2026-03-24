import 'dart:io';

import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Redesigned onboarding: 3 screens (Welcome → Features → Bluetooth setup).
///
/// The user cannot proceed past the Bluetooth screen until permissions are
/// granted and Bluetooth is enabled. On Android, permissions are requested
/// automatically when the Bluetooth page appears.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.onComplete, super.key,
  });

  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _permissionsRequested = false;

  static const _totalPages = 3;

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);

    // Auto-request permissions when landing on the Bluetooth page (page 2).
    if (page == 2 && !_permissionsRequested) {
      _permissionsRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final bloc = context.read<BleConnectionBloc>();
          final status = bloc.state.status;
          if (status == BleConnectionStatus.initial ||
              status == BleConnectionStatus.noPermission) {
            bloc.add(const RequestBlePermissions());
          }
        }
      });
    }
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Page content
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: _onPageChanged,
                // Disable swiping past page 1 to page 2 — user must use button.
                // But allow swiping back freely.
                physics: const ClampingScrollPhysics(),
                children: [
                  _buildWelcomePage(),
                  _buildFeaturesPage(),
                  _buildBluetoothPage(),
                ],
              ),
            ),

            // Page indicators
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _totalPages,
                  (i) => _buildIndicator(i == _currentPage),
                ),
              ),
            ),

            // Bottom action area
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: _currentPage < 2
                  ? _buildNextButton()
                  : _buildBluetoothAction(),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page 1: Welcome
  // ---------------------------------------------------------------------------

  Widget _buildWelcomePage() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App icon / logo area
          Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppTheme.primaryColor.withValues(alpha: 0.2),
                  AppTheme.primaryLight.withValues(alpha: 0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.anchor,
              size: 72,
              color: AppTheme.primaryLight,
            ),
          ),
          const SizedBox(height: 48),

          const Text(
            'Welcome to Anchor',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          const Text(
            'Meet people around you — no internet needed.\nPerfect for cruises, festivals, and events.',
            style: TextStyle(
              fontSize: 16,
              color: AppTheme.textSecondary,
              height: 1.6,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page 2: Key Features
  // ---------------------------------------------------------------------------

  Widget _buildFeaturesPage() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'How it works',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 36),

          _FeatureRow(
            icon: Icons.radar,
            title: 'Find people nearby',
            subtitle: 'Discover others automatically using Bluetooth',
          ),
          SizedBox(height: 24),

          _FeatureRow(
            icon: Icons.chat_bubble_outline,
            title: 'Chat without WiFi',
            subtitle: 'Send messages and photos directly, offline',
          ),
          SizedBox(height: 24),

          _FeatureRow(
            icon: Icons.lock_outline,
            title: '100% private',
            subtitle: 'No accounts, no servers — data stays on your phone',
          ),
          SizedBox(height: 24),

          _FeatureRow(
            icon: Icons.phone_iphone,
            title: 'Keep the app open',
            subtitle:
                "Anchor works best when open — you'll be notified of new people nearby",
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page 3: Bluetooth Setup
  // ---------------------------------------------------------------------------

  Widget _buildBluetoothPage() {
    return BlocBuilder<BleConnectionBloc, BleConnectionState>(
      builder: (context, state) {
        final isReady = state.status == BleConnectionStatus.ready ||
            state.status == BleConnectionStatus.active;
        final isDisabled = state.status == BleConnectionStatus.disabled;
        final isUnavailable = state.status == BleConnectionStatus.unavailable;
        final isChecking = state.status == BleConnectionStatus.checking;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated Bluetooth icon
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.8, end: 1),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutBack,
                builder: (context, value, child) {
                  return Transform.scale(scale: value, child: child);
                },
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: isReady
                        ? AppTheme.success.withValues(alpha: 0.15)
                        : (isDisabled || isUnavailable)
                            ? AppTheme.error.withValues(alpha: 0.1)
                            : AppTheme.primaryLight.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isReady ? Icons.bluetooth_connected : Icons.bluetooth,
                    size: 56,
                    color: isReady
                        ? AppTheme.success
                        : (isDisabled || isUnavailable)
                            ? AppTheme.error
                            : AppTheme.primaryLight,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              Text(
                _bluetoothTitle(state.status),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              Text(
                _bluetoothSubtitle(state.status),
                style: const TextStyle(
                  fontSize: 15,
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),

              // Permission requirements (when not yet granted)
              if (!isReady && !isUnavailable && !isChecking) ...[
                const SizedBox(height: 28),
                _buildPermissionCards(),
              ],

              if (isChecking) ...[
                const SizedBox(height: 28),
                const CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppTheme.primaryLight,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildPermissionCards() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.darkCard.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const _PermissionItem(
            icon: Icons.bluetooth,
            label: 'Bluetooth',
            detail: 'To discover people nearby',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1, color: AppTheme.darkSurface),
          ),
          _PermissionItem(
            icon: Icons.location_on_outlined,
            label: 'Location',
            detail: 'Required by ${Platform.isIOS ? 'iOS' : 'Android'} for Bluetooth',
          ),
          if (Platform.isAndroid) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(height: 1, color: AppTheme.darkSurface),
            ),
            const _PermissionItem(
              icon: Icons.person_search,
              label: 'Nearby Devices',
              detail: 'To find other Anchor users',
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Bottom buttons
  // ---------------------------------------------------------------------------

  Widget _buildNextButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        key: const Key('onboarding_next_btn'),
        onPressed: _nextPage,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        child: Text(
          _currentPage == 0 ? 'Get Started' : 'Next',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildBluetoothAction() {
    return BlocConsumer<BleConnectionBloc, BleConnectionState>(
      listener: (context, state) {
        // Auto-advance once BLE is ready.
        if (state.status == BleConnectionStatus.ready ||
            state.status == BleConnectionStatus.active) {
          widget.onComplete();
        }
      },
      builder: (context, state) {
        final bloc = context.read<BleConnectionBloc>();
        final isReady = state.status == BleConnectionStatus.ready ||
            state.status == BleConnectionStatus.active;
        final isChecking = state.status == BleConnectionStatus.checking;
        final isUnavailable = state.status == BleConnectionStatus.unavailable;

        // Already granted — show green continue.
        if (isReady) {
          return SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: widget.onComplete,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: AppTheme.success,
              ),
              child: const Text(
                'Continue',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }

        // Unavailable hardware — let them continue with a warning.
        if (isUnavailable) {
          return Column(
            children: [
              const Text(
                'Anchor requires Bluetooth to work. Some features will be unavailable.',
                style: TextStyle(color: AppTheme.textHint, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: widget.onComplete,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Continue Without Bluetooth'),
                ),
              ),
            ],
          );
        }

        // Bluetooth off — prompt to enable.
        if (state.status == BleConnectionStatus.disabled) {
          return Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => bloc.add(const RequestBlePermissions()),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text(
                    'Turn On Bluetooth',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'You can also enable Bluetooth in your device settings.',
                style: TextStyle(color: AppTheme.textHint, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          );
        }

        // Need permissions or initial — show grant button.
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed:
                isChecking ? null : () => bloc.add(const RequestBlePermissions()),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: isChecking
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Allow Bluetooth Access',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _bluetoothTitle(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.ready:
      case BleConnectionStatus.active:
        return "You're all set!";
      case BleConnectionStatus.disabled:
        return 'Turn on Bluetooth';
      case BleConnectionStatus.unavailable:
        return 'Bluetooth not available';
      case BleConnectionStatus.error:
        return 'Something went wrong';
      case BleConnectionStatus.initial:
      case BleConnectionStatus.checking:
      case BleConnectionStatus.noPermission:
      case BleConnectionStatus.starting:
        return 'Enable Bluetooth';
    }
  }

  String _bluetoothSubtitle(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.ready:
      case BleConnectionStatus.active:
        return "Bluetooth is ready. Let's set up your profile!";
      case BleConnectionStatus.disabled:
        return 'Anchor needs Bluetooth to find people around you. Please turn it on to continue.';
      case BleConnectionStatus.unavailable:
        return "This device doesn't support the Bluetooth features Anchor needs.";
      case BleConnectionStatus.error:
        return 'There was a problem setting up Bluetooth. Please try again.';
      case BleConnectionStatus.initial:
      case BleConnectionStatus.checking:
      case BleConnectionStatus.noPermission:
      case BleConnectionStatus.starting:
        return 'Anchor uses Bluetooth to discover and connect with people nearby. Your location is never stored or shared.';
    }
  }

  Widget _buildIndicator(bool isActive) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: isActive ? 24 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: isActive
            ? AppTheme.primaryLight
            : AppTheme.primaryLight.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Private helper widgets
// ---------------------------------------------------------------------------

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppTheme.primaryLight.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: AppTheme.primaryLight, size: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PermissionItem extends StatelessWidget {
  const _PermissionItem({
    required this.icon,
    required this.label,
    required this.detail,
  });

  final IconData icon;
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primaryLight, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                ),
              ),
              Text(
                detail,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textHint,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
