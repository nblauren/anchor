import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/home/home.dart';
import '../../features/onboarding/onboarding.dart';
import '../../features/profile/bloc/profile_bloc.dart';
import '../../features/profile/bloc/profile_event.dart';
import '../../features/profile/bloc/profile_state.dart';
import '../../features/profile/screens/profile_setup_screen.dart';
import '../../services/ble/ble.dart';
import '../app_lifecycle_observer.dart';
import '../screens/splash_screen.dart';

/// App shell that handles routing based on app state (onboarding, profile, permissions)
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

    if (_hasSeenOnboarding == false) {
      return OnboardingScreen(onComplete: _completeOnboarding);
    }

    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        if (_isLoadingProfile(state)) {
          return const SplashScreen();
        }

        if (state.status == ProfileStatus.noProfile) {
          return _buildSetupFlow(context);
        }

        return const _MainAppWrapper();
      },
    );
  }

  bool _isLoadingProfile(ProfileState state) {
    return state.status == ProfileStatus.initial ||
        state.status == ProfileStatus.loading;
  }

  Widget _buildSetupFlow(BuildContext context) {
    return BlocBuilder<BleConnectionBloc, BleConnectionState>(
      builder: (context, bleState) {
        final needsPermissions = _needsBlePermissions(bleState.status);

        if (needsPermissions) {
          return PermissionsScreen(
            onComplete: () => setState(() {}),
          );
        }

        return ProfileSetupScreen(
          onComplete: () {
            context.read<ProfileBloc>().add(const LoadProfile());
          },
        );
      },
    );
  }

  bool _needsBlePermissions(BleConnectionStatus status) {
    return status == BleConnectionStatus.initial ||
        status == BleConnectionStatus.noPermission ||
        status == BleConnectionStatus.disabled;
  }
}

/// Wrapper that sets up lifecycle observer for BLE
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
    return const HomeScreen();
  }
}
