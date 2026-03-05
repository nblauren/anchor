import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/discovery_bloc.dart';
import '../bloc/discovery_event.dart';
import '../bloc/discovery_state.dart';
import '../widgets/peer_grid_tile.dart';
import 'peer_detail_screen.dart';

/// Discovery screen showing grid of nearby peers
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    // Load peers on screen open
    context.read<DiscoveryBloc>().add(const LoadDiscoveredPeers());
  }

  Future<void> _onRefresh() async {
    context.read<DiscoveryBloc>().add(const RefreshPeers());
    // Wait a bit for visual feedback
    await Future.delayed(const Duration(milliseconds: 500));
  }

  void _loadMockData() {
    context.read<DiscoveryBloc>().add(const LoadMockPeers());
  }

  void _openPeerDetail(DiscoveredPeer peer) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => BlocProvider.value(
          value: context.read<DiscoveryBloc>(),
          child: PeerDetailScreen(peer: peer),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<DiscoveryBloc, DiscoveryState>(
      listener: (context, state) {
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.errorMessage!)),
          );
          context.read<DiscoveryBloc>().add(const ClearDiscoveryError());
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Discover'),
            actions: [
              // Peer count badge
              if (state.hasPeers)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.people,
                        size: 16,
                        color: AppTheme.primaryColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${state.peerCount}',
                        style: const TextStyle(
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              // Debug: Load mock data
              IconButton(
                icon: const Icon(Icons.bug_report),
                tooltip: 'Load mock data',
                onPressed: _loadMockData,
              ),
            ],
          ),
          body: _buildBody(state),
        );
      },
    );
  }

  Widget _buildBody(DiscoveryState state) {
    if (state.status == DiscoveryStatus.loading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (state.status == DiscoveryStatus.error && !state.hasPeers) {
      return _buildErrorState(state);
    }

    if (!state.hasPeers) {
      return _buildEmptyState();
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Responsive column count: 2 for phones, 3 for tablets
          final crossAxisCount = constraints.maxWidth > 600 ? 3 : 2;

          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              childAspectRatio: 0.75, // Taller cards
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: state.visiblePeers.length,
            itemBuilder: (context, index) {
              final peer = state.visiblePeers[index];
              return PeerGridTile(
                peer: peer,
                onTap: () => _openPeerDetail(peer),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: ListView(
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Animated radar icon
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.radar,
                        size: 64,
                        color: AppTheme.primaryColor.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'No one nearby',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'When other Anchor users are nearby,\nthey\'ll appear here.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                    const SizedBox(height: 32),
                    // Pull to refresh hint
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.arrow_downward,
                          size: 16,
                          color: AppTheme.textHint,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Pull down to scan',
                          style: TextStyle(
                            color: AppTheme.textHint,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Debug button
                    OutlinedButton.icon(
                      onPressed: _loadMockData,
                      icon: const Icon(Icons.bug_report, size: 18),
                      label: const Text('Load test data'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(DiscoveryState state) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: AppTheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              state.errorMessage ?? 'Please try again',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                context.read<DiscoveryBloc>().add(const LoadDiscoveredPeers());
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
