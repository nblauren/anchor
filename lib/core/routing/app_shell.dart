import 'package:anchor/core/app_lifecycle_observer.dart';
import 'package:anchor/core/screens/splash_screen.dart';
import 'package:anchor/core/theme/app_theme.dart';
import 'package:anchor/features/home/home.dart';
import 'package:anchor/features/onboarding/screens/onboarding_screen.dart';
import 'package:anchor/features/profile/bloc/profile_bloc.dart';
import 'package:anchor/features/profile/bloc/profile_event.dart';
import 'package:anchor/features/profile/bloc/profile_state.dart';
import 'package:anchor/features/profile/screens/profile_setup_screen.dart';
import 'package:anchor/services/ble/ble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App shell that handles routing based on app state:
///   1. Onboarding (intro + BLE permissions) — shown once
///   2. Profile setup — shown when no profile exists
///   3. Main app — HomeScreen with BLE status monitoring
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool? _hasSeenOnboarding;
  bool _isCheckingOnboarding = true;

  @override
  void initState() {
    super.initState();
    _checkOnboardingStatus();
  }

  Future<void> _checkOnboardingStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSeenOnboarding = prefs.getBool('has_seen_onboarding') ?? false;

    if (mounted) {
      setState(() {
        _hasSeenOnboarding = hasSeenOnboarding;
        _isCheckingOnboarding = false;
      });
    }
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_onboarding', true);

    if (mounted) {
      setState(() {
        _hasSeenOnboarding = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isCheckingOnboarding) {
      return const SplashScreen();
    }

    // Onboarding not seen → show merged onboarding + BLE permissions flow.
    if (_hasSeenOnboarding == false) {
      return OnboardingScreen(onComplete: _completeOnboarding);
    }

    // Onboarding done → check profile state.
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        if (_isLoadingProfile(state)) {
          return const SplashScreen();
        }

        if (state.status == ProfileStatus.noProfile) {
          return ProfileSetupScreen(
            onComplete: () {
              context.read<ProfileBloc>().add(const LoadProfile());
            },
          );
        }

        return const _MainAppWrapper();
      },
    );
  }

  bool _isLoadingProfile(ProfileState state) {
    return state.status == ProfileStatus.initial ||
        state.status == ProfileStatus.loading;
  }
}

/// Wrapper that sets up lifecycle observer for BLE and monitors BLE status
/// post-onboarding, showing a persistent banner when Bluetooth is off.
class _MainAppWrapper extends StatefulWidget {
  const _MainAppWrapper();

  @override
  State<_MainAppWrapper> createState() => _MainAppWrapperState();
}

class _MainAppWrapperState extends State<_MainAppWrapper> {
  late AppLifecycleObserver _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = AppLifecycleObserver(
      bleConnectionBloc: context.read<BleConnectionBloc>(),
    );
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BleConnectionBloc, BleConnectionState>(
      buildWhen: (prev, curr) => prev.status != curr.status,
      builder: (context, bleState) {
        final showBanner = bleState.status == BleConnectionStatus.disabled ||
            bleState.status == BleConnectionStatus.noPermission;

        return Column(
          children: [
            if (showBanner) _BluetoothOffBanner(status: bleState.status),
            const Expanded(child: HomeScreen()),
          ],
        );
      },
    );
  }
}

/// Persistent banner shown at the top of the main app when Bluetooth is
/// disabled or permissions are revoked.
class _BluetoothOffBanner extends StatelessWidget {
  const _BluetoothOffBanner({required this.status});

  final BleConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final isPermission = status == BleConnectionStatus.noPermission;
    final message = isPermission
        ? 'Bluetooth permission needed to see people nearby.'
        : 'Bluetooth is off. Turn it on to see people nearby.';

    return Material(
      color: AppTheme.warning.withValues(alpha: 0.15),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.bluetooth_disabled, size: 20, color: AppTheme.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: AppTheme.warning,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  context
                      .read<BleConnectionBloc>()
                      .add(const RequestBlePermissions());
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  minimumSize: Size.zero,
                ),
                child: Text(
                  isPermission ? 'Grant' : 'Fix',
                  style: const TextStyle(
                    color: AppTheme.warning,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
