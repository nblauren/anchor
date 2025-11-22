import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/discovery_bloc.dart';
import '../bloc/discovery_event.dart';
import '../bloc/discovery_state.dart';
import '../widgets/user_card_widget.dart';

/// Main discovery screen showing a grid of nearby users
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    context.read<DiscoveryBloc>().add(const StartDiscovery());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover'),
        actions: [
          BlocBuilder<DiscoveryBloc, DiscoveryState>(
            builder: (context, state) {
              return IconButton(
                icon: Icon(
                  state.status == DiscoveryStatus.scanning
                      ? Icons.bluetooth_searching
                      : Icons.bluetooth,
                  color: state.status == DiscoveryStatus.scanning
                      ? AppTheme.primaryColor
                      : AppTheme.textSecondary,
                ),
                onPressed: () {
                  if (state.status == DiscoveryStatus.scanning) {
                    context.read<DiscoveryBloc>().add(const StopDiscovery());
                  } else {
                    context.read<DiscoveryBloc>().add(const StartDiscovery());
                  }
                },
              );
            },
          ),
        ],
      ),
      body: BlocBuilder<DiscoveryBloc, DiscoveryState>(
        builder: (context, state) {
          if (state.status == DiscoveryStatus.loading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.status == DiscoveryStatus.error) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.bluetooth_disabled,
                    size: 64,
                    color: AppTheme.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state.errorMessage ?? 'An error occurred',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      context.read<DiscoveryBloc>().add(const StartDiscovery());
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          if (state.discoveredUsers.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    state.status == DiscoveryStatus.scanning
                        ? Icons.radar
                        : Icons.people_outline,
                    size: 80,
                    color: AppTheme.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    state.status == DiscoveryStatus.scanning
                        ? 'Scanning for people nearby...'
                        : 'No one found yet',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'People using Anchor nearby will appear here',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textHint,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  if (state.status != DiscoveryStatus.scanning) ...[
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () {
                        context.read<DiscoveryBloc>().add(const StartDiscovery());
                      },
                      icon: const Icon(Icons.search),
                      label: const Text('Start Scanning'),
                    ),
                  ],
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              context.read<DiscoveryBloc>().add(const RefreshDiscoveredUsers());
            },
            child: CustomScrollView(
              slivers: [
                // Scanning indicator
                if (state.status == DiscoveryStatus.scanning)
                  SliverToBoxAdapter(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: AppTheme.primaryColor.withOpacity(0.1),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primaryColor,
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Scanning for people nearby...',
                            style: TextStyle(color: AppTheme.primaryColor),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Nearby users section
                if (state.nearbyUsers.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.all(16),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        'Nearby Now (${state.nearbyUsers.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 0.75,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final user = state.nearbyUsers[index];
                          return UserCardWidget(
                            user: user,
                            onTap: () => _viewProfile(context, user.profile.id),
                          );
                        },
                        childCount: state.nearbyUsers.length,
                      ),
                    ),
                  ),
                ],

                // All discovered users
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      'Previously Seen (${state.discoveredUsers.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.75,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final user = state.discoveredUsers[index];
                        return UserCardWidget(
                          user: user,
                          onTap: () => _viewProfile(context, user.profile.id),
                        );
                      },
                      childCount: state.discoveredUsers.length,
                    ),
                  ),
                ),
                const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
              ],
            ),
          );
        },
      ),
    );
  }

  void _viewProfile(BuildContext context, String userId) {
    context.read<DiscoveryBloc>().add(ViewUserProfile(userId));
    // TODO: Navigate to profile detail screen
  }
}
