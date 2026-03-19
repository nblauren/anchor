import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/profile_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../injection.dart';
import '../../../services/database_service.dart';
import '../../chat/bloc/chat_bloc.dart';
import '../../chat/bloc/chat_e2ee_bloc.dart';
import '../../chat/bloc/conversation_list_bloc.dart';
import '../../chat/bloc/photo_transfer_bloc.dart';
import '../../chat/bloc/reaction_bloc.dart';
import '../bloc/anchor_drop_bloc.dart';
import '../bloc/discovery_bloc.dart';
import '../bloc/discovery_event.dart';
import '../bloc/discovery_filter_cubit.dart';
import '../bloc/discovery_state.dart';
import '../widgets/peer_grid_tile.dart';
import '../widgets/radar_view.dart';
import 'anchor_drops_screen.dart';
import 'peer_detail_screen.dart';

enum _ViewMode { grid, radar }

/// Discovery screen showing grid of nearby peers
class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  bool _meshTipDismissed = false;
  _ViewMode _viewMode = _ViewMode.grid;
  bool _batteryWarningDismissed = false;

  static const _prefKeyViewMode = 'discovery_view_mode';
  static const _prefKeyBatteryDismissed = 'radar_battery_warning_dismissed';

  @override
  void initState() {
    super.initState();
    context.read<DiscoveryBloc>().add(const LoadDiscoveredPeers());
    _loadPrefs();
    // Listen for peer taps from inside the RadarView peer sheet
    RadarView.listenForPeerTaps(_openPeerDetail);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKeyViewMode);
    final batteryDismissed = prefs.getBool(_prefKeyBatteryDismissed) ?? false;
    if (mounted) {
      setState(() {
        _viewMode = saved == 'radar' ? _ViewMode.radar : _ViewMode.grid;
        _batteryWarningDismissed = batteryDismissed;
      });
    }
  }

  Future<void> _setViewMode(_ViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyViewMode, mode.name);
  }

  Future<void> _dismissBatteryWarning() async {
    setState(() => _batteryWarningDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyBatteryDismissed, true);
  }

  Future<void> _onRefresh() async {
    context.read<DiscoveryBloc>().add(const RefreshPeers());
    // Wait a bit for visual feedback
    await Future.delayed(const Duration(milliseconds: 500));
  }


  Future<void> _openPeerDetail(DiscoveredPeer peer) async {
    final discoveryBloc = context.read<DiscoveryBloc>();
    final chatBloc = context.read<ChatBloc>();
    final photoTransferBloc = context.read<PhotoTransferBloc>();
    final anchorDropBloc = context.read<AnchorDropBloc>();
    final convListBloc = context.read<ConversationListBloc>();

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: discoveryBloc),
            BlocProvider.value(value: chatBloc),
            BlocProvider.value(value: photoTransferBloc),
            BlocProvider.value(value: context.read<ChatE2eeBloc>()),
            BlocProvider.value(value: context.read<ReactionBloc>()),
            BlocProvider.value(value: anchorDropBloc),
            BlocProvider.value(value: convListBloc),
          ],
          child: PeerDetailScreen(peer: peer),
        ),
      ),
    );

    // Reload conversations when returning so unread badges reflect any chat opened
    if (mounted) {
      context.read<ConversationListBloc>().add(const LoadConversations());
    }
  }

  void _showFilterSheet(BuildContext context, DiscoveryState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => BlocProvider.value(
        value: context.read<DiscoveryFilterCubit>(),
        child: const _FilterSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        // Discovery error listener
        BlocListener<DiscoveryBloc, DiscoveryState>(
          listenWhen: (prev, curr) => curr.errorMessage != null,
          listener: (context, state) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.errorMessage!)),
            );
            context.read<DiscoveryBloc>().add(const ClearDiscoveryError());
          },
        ),
        // Anchor drop incoming notification listener
        BlocListener<AnchorDropBloc, AnchorDropState>(
          listenWhen: (prev, curr) =>
              curr.incomingAnchorDropName != null &&
              curr.incomingAnchorDropName != prev.incomingAnchorDropName,
          listener: (context, state) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '${state.incomingAnchorDropName} dropped anchor on you!',
                ),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
      ],
      child: BlocBuilder<DiscoveryBloc, DiscoveryState>(
        builder: (context, state) {
          final filterState = context.watch<DiscoveryFilterCubit>().state;
          return Scaffold(
            appBar: AppBar(
              centerTitle: false,
              title: const Text('Discover'),
              actions: [
                // Anchor drops page
                IconButton(
                  key: const Key('discovery_anchor_drops_btn'),
                  icon: const Icon(Icons.anchor_rounded),
                  tooltip: 'Anchor Drops',
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MultiBlocProvider(
                          providers: [
                            BlocProvider.value(
                                value: context.read<DiscoveryBloc>()),
                            BlocProvider.value(value: context.read<ChatBloc>()),
                            BlocProvider.value(value: context.read<PhotoTransferBloc>()),
                            BlocProvider.value(value: context.read<ChatE2eeBloc>()),
                            BlocProvider.value(value: context.read<ReactionBloc>()),
                          ],
                          child: AnchorDropsScreen(
                            anchorDropRepository:
                                getIt<DatabaseService>().anchorDropRepository,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                // View mode toggle: Grid / Radar
                IconButton(
                  key: const Key('discovery_view_toggle_btn'),
                  icon: Icon(
                    _viewMode == _ViewMode.grid
                        ? Icons.radar
                        : Icons.grid_view_rounded,
                  ),
                  tooltip: _viewMode == _ViewMode.grid
                      ? 'Switch to Radar'
                      : 'Switch to Grid',
                  onPressed: () => _setViewMode(
                    _viewMode == _ViewMode.grid
                        ? _ViewMode.radar
                        : _ViewMode.grid,
                  ),
                ),
                // Filter button (grid mode only)
                if (_viewMode == _ViewMode.grid)
                  Stack(
                    children: [
                      IconButton(
                        key: const Key('discovery_filter_btn'),
                        icon: const Icon(Icons.tune_rounded),
                        tooltip: 'Filter',
                        onPressed: () => _showFilterSheet(context, state),
                      ),
                      if (filterState.hasActiveFilters)
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppTheme.primaryLight,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            body: _buildBody(state, filterState),
          );
        },
      ),
    );
  }

  Widget _buildBody(DiscoveryState state, DiscoveryFilterState filterState) {
    if (state.status == DiscoveryStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == DiscoveryStatus.error && !state.hasPeers) {
      return _buildErrorState(state);
    }

    if (_viewMode == _ViewMode.radar) {
      return _buildRadarBody(state);
    }

    if (!state.hasPeers) {
      return _buildEmptyState();
    }

    final filteredPeers = filterState.applyTo(state.visiblePeers);

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Responsive column count: 2 for phones, 3 for tablets
          final crossAxisCount = constraints.maxWidth > 600 ? 5 : 3;

          return BlocBuilder<ConversationListBloc, ConversationListState>(
            builder: (context, convListState) {
              // Build a map of peerId → unreadCount from chat conversations
              final unreadByPeer = <String, int>{
                for (final conv in convListState.conversations)
                  if (conv.unreadCount > 0)
                    conv.conversation.peerId: conv.unreadCount,
              };

              final anchorDropState =
                  context.watch<AnchorDropBloc>().state;

              final hasRelayedPeers =
                  filteredPeers.any((p) => p.isRelayed);

              return CustomScrollView(
                slivers: [
                  // Active filter strip
                  if (filterState.hasActiveFilters)
                    SliverToBoxAdapter(
                      child: _buildActiveFilterStrip(context, filterState),
                    ),
                  // Tip card: shown once when relayed peers appear
                  if (hasRelayedPeers && !_meshTipDismissed)
                    SliverToBoxAdapter(
                      child: _buildMeshTipCard(),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.all(12),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final peer = filteredPeers[index];
                          return PeerGridTile(
                            key: ValueKey(peer.peerId),
                            peer: peer,
                            unreadCount: unreadByPeer[peer.peerId] ?? 0,
                            onTap: () => _openPeerDetail(peer),
                            anchorDropped: anchorDropState
                                .droppedAnchorPeerIds
                                .contains(peer.peerId),
                          );
                        },
                        childCount: filteredPeers.length,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        childAspectRatio: 1,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  // ── Radar mode body ──────────────────────────────────────────────────────────

  Widget _buildRadarBody(DiscoveryState state) {
    return Column(
      children: [
        // Battery warning banner (shown until dismissed)
        if (!_batteryWarningDismissed)
          _RadarBatteryBanner(onDismiss: _dismissBatteryWarning),

        // Radar canvas — passes ALL visible (unfiltered) peers since radar
        // shows proximity density, not filtered subsets
        Expanded(
          child: RadarView(
            peers: state.peers.where((p) => !p.isBlocked).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildActiveFilterStrip(
      BuildContext context, DiscoveryFilterState filterState) {
    final cubit = context.read<DiscoveryFilterCubit>();
    return Container(
      color: AppTheme.primaryLight.withAlpha(20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.tune_rounded,
              size: 14, color: AppTheme.primaryLight),
          const SizedBox(width: 6),
          Expanded(
            child: Wrap(
              spacing: 6,
              children: [
                for (final id in filterState.filterPositionIds)
                  _FilterChip(
                    label: ProfileConstants.positionMap[id] ?? '?',
                    onRemove: () => cubit.togglePosition(id),
                  ),
                for (final id in filterState.filterInterestIds)
                  _FilterChip(
                    label: ProfileConstants.interestMap[id] ?? '?',
                    onRemove: () => cubit.toggleInterest(id),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => cubit.clearAll(),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.primaryLight,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Clear', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildMeshTipCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF312E81).withValues(alpha: 0.6), // deep indigo
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF818CF8).withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.hub_outlined, color: Color(0xFF818CF8), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Some people are visible via mesh relay. '
              'Metal walls can reduce range — move closer for direct connection.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _meshTipDismissed = true),
            child: Icon(
              Icons.close,
              size: 16,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
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
                        color: AppTheme.primaryLight.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.radar,
                        size: 64,
                        color: AppTheme.primaryLight.withValues(alpha: 0.6),
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

// ── Radar battery warning banner ──────────────────────────────────────────────

class _RadarBatteryBanner extends StatelessWidget {
  const _RadarBatteryBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.warning.withAlpha(25),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.battery_alert, size: 16, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Radar updates every few seconds — turn off when not needed to save battery.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.warning,
                  ),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(Icons.close, size: 14, color: AppTheme.warning),
          ),
        ],
      ),
    );
  }
}

// ── Small chip shown in the active filter strip ───────────────────────────────

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primaryLight.withAlpha(38),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryLight.withAlpha(102)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
                color: AppTheme.primaryLight,
                fontSize: 11,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child:
                const Icon(Icons.close, size: 12, color: AppTheme.primaryLight),
          ),
        ],
      ),
    );
  }
}

// ── Modal bottom sheet with position + interest filters ───────────────────────

class _FilterSheet extends StatelessWidget {
  const _FilterSheet();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DiscoveryFilterCubit, DiscoveryFilterState>(
      builder: (context, state) {
        final cubit = context.read<DiscoveryFilterCubit>();

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (_, controller) => ListView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title row
              Row(
                children: [
                  Text(
                    'Filter Discovery',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  if (state.hasActiveFilters)
                    TextButton(
                      onPressed: () {
                        cubit.clearAll();
                        Navigator.pop(context);
                      },
                      child: const Text('Clear all'),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // Position filter
              Text(
                'Position',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // "Any" chip — selected when no position filters active
                  FilterChip(
                    label: const Text('Any'),
                    selected: state.filterPositionIds.isEmpty,
                    onSelected: (_) => cubit.clearAll(),
                    selectedColor: AppTheme.primaryLight.withAlpha(51),
                    labelStyle: TextStyle(
                      color: state.filterPositionIds.isEmpty
                          ? AppTheme.primaryLight
                          : AppTheme.textSecondary,
                      fontWeight: state.filterPositionIds.isEmpty
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: state.filterPositionIds.isEmpty
                          ? AppTheme.primaryLight
                          : Colors.white24,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    backgroundColor: AppTheme.darkCard,
                  ),
                  ...ProfileConstants.positionMap.entries.map((e) {
                    final selected = state.filterPositionIds.contains(e.key);
                    return FilterChip(
                      label: Text(e.value),
                      selected: selected,
                      onSelected: (_) => cubit.togglePosition(e.key),
                      selectedColor: AppTheme.primaryLight.withAlpha(51),
                      labelStyle: TextStyle(
                        color: selected
                            ? AppTheme.primaryLight
                            : AppTheme.textSecondary,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                      side: BorderSide(
                        color:
                            selected ? AppTheme.primaryLight : Colors.white24,
                      ),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                      backgroundColor: AppTheme.darkCard,
                    );
                  }),
                ],
              ),

              const SizedBox(height: 24),

              // Interest filter
              Text(
                'Interests',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppTheme.textSecondary,
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Show peers that match at least one selected interest.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textHint),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ProfileConstants.interestMap.entries.map((e) {
                  final selected = state.filterInterestIds.contains(e.key);
                  return FilterChip(
                    label: Text(e.value),
                    selected: selected,
                    onSelected: (_) => cubit.toggleInterest(e.key),
                    selectedColor: AppTheme.primaryLight.withAlpha(51),
                    checkmarkColor: AppTheme.primaryLight,
                    backgroundColor: AppTheme.darkCard,
                    labelStyle: TextStyle(
                      color: selected
                          ? AppTheme.primaryLight
                          : AppTheme.textSecondary,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                    side: BorderSide(
                      color: selected ? AppTheme.primaryLight : Colors.white24,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  );
                }).toList(),
              ),

              const SizedBox(height: 24),

              // Apply / Done button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
