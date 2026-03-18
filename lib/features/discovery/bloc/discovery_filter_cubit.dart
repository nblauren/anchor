import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'discovery_state.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class DiscoveryFilterState extends Equatable {
  const DiscoveryFilterState({
    this.filterPositionIds = const {},
    this.filterInterestIds = const {},
  });

  final Set<int> filterPositionIds;
  final Set<int> filterInterestIds;

  bool get hasActiveFilters =>
      filterPositionIds.isNotEmpty || filterInterestIds.isNotEmpty;

  /// Apply filters to a list of discovered peers.
  List<DiscoveredPeer> applyTo(List<DiscoveredPeer> peers) {
    if (!hasActiveFilters) return peers;
    return peers.where((p) {
      if (filterPositionIds.isNotEmpty &&
          p.position != null &&
          !filterPositionIds.contains(p.position)) {
        return false;
      }
      if (filterInterestIds.isNotEmpty && p.interestIds.isNotEmpty) {
        if (!p.interestIds.any((id) => filterInterestIds.contains(id))) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  DiscoveryFilterState copyWith({
    Set<int>? filterPositionIds,
    Set<int>? filterInterestIds,
  }) {
    return DiscoveryFilterState(
      filterPositionIds: filterPositionIds ?? this.filterPositionIds,
      filterInterestIds: filterInterestIds ?? this.filterInterestIds,
    );
  }

  @override
  List<Object?> get props => [filterPositionIds, filterInterestIds];
}

// ---------------------------------------------------------------------------
// Cubit
// ---------------------------------------------------------------------------

/// Lightweight cubit managing local-only discovery filters (position, interests).
///
/// These filters only affect the UI display — they have no impact on BLE
/// scanning or transport behaviour.
class DiscoveryFilterCubit extends Cubit<DiscoveryFilterState> {
  DiscoveryFilterCubit() : super(const DiscoveryFilterState());

  void togglePosition(int positionId) {
    final updated = Set<int>.from(state.filterPositionIds);
    if (updated.contains(positionId)) {
      updated.remove(positionId);
    } else {
      updated.add(positionId);
    }
    emit(state.copyWith(filterPositionIds: updated));
  }

  void toggleInterest(int interestId) {
    final updated = Set<int>.from(state.filterInterestIds);
    if (updated.contains(interestId)) {
      updated.remove(interestId);
    } else {
      updated.add(interestId);
    }
    emit(state.copyWith(filterInterestIds: updated));
  }

  void clearAll() {
    emit(const DiscoveryFilterState());
  }
}
