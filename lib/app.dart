import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_lifecycle_observer.dart';
import 'core/theme/app_theme.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/chat/screens/chat_list_screen.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/discovery/screens/discovery_screen.dart';
import 'features/onboarding/onboarding.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'features/profile/bloc/profile_event.dart';
import 'features/profile/bloc/profile_state.dart';
import 'features/profile/screens/profile_setup_screen.dart';
import 'features/profile/screens/profile_view_screen.dart';
import 'injection.dart';
import 'services/ble/ble.dart';

/// Main application widget
class AnchorApp extends StatelessWidget {
  const AnchorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<ProfileBloc>(
          create: (context) => getIt<ProfileBloc>()..add(const LoadProfile()),
        ),
        BlocProvider<DiscoveryBloc>(
          create: (context) => getIt<DiscoveryBloc>(),
        ),
        BlocProvider<BleConnectionBloc>(
          create: (context) => getIt<BleConnectionBloc>()..add(const InitializeBleConnection()),
        ),
        BlocProvider<BleStatusBloc>(
          create: (context) => getIt<BleStatusBloc>(),
        ),
      ],
      child: MaterialApp(
        title: 'Anchor',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const _AppEntryPoint(),
      ),
    );
  }
}

/// Entry point that handles routing based on profile and onboarding state
class _AppEntryPoint extends StatefulWidget {
  const _AppEntryPoint();

  @override
  State<_AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<_AppEntryPoint> {
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
    setState(() {
      _hasSeenOnboarding = hasSeenOnboarding;
      _isCheckingOnboarding = false;
    });
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_onboarding', true);
    setState(() {
      _hasSeenOnboarding = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Still checking onboarding status
    if (_isCheckingOnboarding) {
      return const _SplashScreen();
    }

    // Show onboarding if not seen
    if (_hasSeenOnboarding == false) {
      return OnboardingScreen(
        onComplete: _completeOnboarding,
      );
    }

    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        // Show loading while checking for profile
        if (state.status == ProfileStatus.initial ||
            state.status == ProfileStatus.loading) {
          return const _SplashScreen();
        }

        // No profile - show permissions then setup
        if (state.status == ProfileStatus.noProfile) {
          return BlocBuilder<BleConnectionBloc, BleConnectionState>(
            builder: (context, bleState) {
              // Check if permissions need to be requested
              final needsPermissions = bleState.status == BleConnectionStatus.initial ||
                  bleState.status == BleConnectionStatus.noPermission ||
                  bleState.status == BleConnectionStatus.disabled;

              // Show permissions screen if needed, but allow skipping
              if (needsPermissions) {
                return PermissionsScreen(
                  onComplete: () {
                    // Rebuild to show profile setup
                    setState(() {});
                  },
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

        // Profile exists - show main app
        return const _MainScreenWrapper();
      },
    );
  }
}

/// Splash screen with app icon and loading
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.anchor,
              size: 80,
              color: AppTheme.primaryColor,
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(
              color: AppTheme.primaryColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wrapper for main screen with lifecycle handling
class _MainScreenWrapper extends StatefulWidget {
  const _MainScreenWrapper();

  @override
  State<_MainScreenWrapper> createState() => _MainScreenWrapperState();
}

class _MainScreenWrapperState extends State<_MainScreenWrapper> {
  late AppLifecycleObserver _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    // Set up lifecycle observer for BLE
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
    return const _MainScreen();
  }
}

/// Main screen with bottom navigation
class _MainScreen extends StatefulWidget {
  const _MainScreen();

  @override
  State<_MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<_MainScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, profileState) {
        // Create ChatBloc with the user's ID
        final ownUserId = profileState.profileId ?? '';

        return BlocProvider<ChatBloc>(
          create: (context) => getIt<ChatBloc>(param1: ownUserId),
          child: Scaffold(
            body: IndexedStack(
              index: _currentIndex,
              children: const [
                DiscoveryScreen(),
                ChatListScreen(),
                _ProfileTab(),
              ],
            ),
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _currentIndex,
              onTap: (index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.explore),
                  activeIcon: Icon(Icons.explore),
                  label: 'Discover',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.chat_bubble_outline),
                  activeIcon: Icon(Icons.chat_bubble),
                  label: 'Messages',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Profile tab - displays ProfileViewScreen which handles settings navigation
class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    return const ProfileViewScreen();
  }
}
