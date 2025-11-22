import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/theme/app_theme.dart';
import 'features/chat/bloc/chat_bloc.dart';
import 'features/chat/screens/chat_list_screen.dart';
import 'features/discovery/bloc/discovery_bloc.dart';
import 'features/discovery/screens/discovery_screen.dart';
import 'features/profile/bloc/profile_bloc.dart';
import 'features/profile/bloc/profile_event.dart';
import 'features/profile/bloc/profile_state.dart';
import 'features/profile/screens/profile_setup_screen.dart';
import 'features/profile/screens/profile_view_screen.dart';
import 'injection.dart';

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

/// Entry point that handles routing based on profile state
class _AppEntryPoint extends StatelessWidget {
  const _AppEntryPoint();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, state) {
        // Show loading while checking for profile
        if (state.status == ProfileStatus.initial ||
            state.status == ProfileStatus.loading) {
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

        // No profile - show setup
        if (state.status == ProfileStatus.noProfile) {
          return ProfileSetupScreen(
            onComplete: () {
              context.read<ProfileBloc>().add(const LoadProfile());
            },
          );
        }

        // Profile exists - show main app
        return const _MainScreen();
      },
    );
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
                ProfileViewScreen(),
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
