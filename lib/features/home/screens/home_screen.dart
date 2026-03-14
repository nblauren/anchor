import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../injection.dart';
import '../../chat/bloc/chat_bloc.dart';
import '../../chat/bloc/chat_state.dart';
import '../../chat/screens/chat_list_screen.dart';
import '../../discovery/screens/discovery_screen.dart';
import '../../profile/bloc/profile_bloc.dart';
import '../../profile/bloc/profile_state.dart';
import '../../profile/screens/profile_view_screen.dart';

/// Main screen with bottom navigation bar
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProfileBloc, ProfileState>(
      builder: (context, profileState) {
        final ownUserId = profileState.profileId ?? '';

        // Don't create ChatBloc until we have a real userId — avoids a second
        // initialization when the profile loads and the key would change from
        // '' to the actual UUID.
        if (ownUserId.isEmpty) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return BlocProvider<ChatBloc>(
          key: ValueKey(ownUserId),
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
            bottomNavigationBar: BlocBuilder<ChatBloc, ChatState>(
              builder: (context, chatState) {
                final unreadCount = chatState.totalUnreadCount;
                return BottomNavigationBar(
                  currentIndex: _currentIndex,
                  onTap: _onTabTapped,
                  items: [
                    const BottomNavigationBarItem(
                      icon: Icon(Icons.explore),
                      activeIcon: Icon(Icons.explore),
                      label: 'Discover',
                    ),
                    BottomNavigationBarItem(
                      icon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text('$unreadCount'),
                        child: const Icon(Icons.chat_bubble_outline),
                      ),
                      activeIcon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text('$unreadCount'),
                        child: const Icon(Icons.chat_bubble),
                      ),
                      label: 'Messages',
                    ),
                    const BottomNavigationBarItem(
                      icon: Icon(Icons.person_outline),
                      activeIcon: Icon(Icons.person),
                      label: 'Profile',
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
  }
}
