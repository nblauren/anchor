import 'dart:async';

import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/encryption/encryption.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

sealed class ChatE2eeEvent extends Equatable {
  const ChatE2eeEvent();

  @override
  List<Object?> get props => [];
}

/// Initiate the Noise_XK handshake when a conversation is opened.
class InitiateE2eeHandshake extends ChatE2eeEvent {
  const InitiateE2eeHandshake(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// A Noise_XK session was established with [peerId].
class E2eeSessionEstablished extends ChatE2eeEvent {
  const E2eeSessionEstablished(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// The peer's public key was stored — retry handshake if needed.
class _E2eePeerKeyArrived extends ChatE2eeEvent {
  const _E2eePeerKeyArrived(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// The handshake timed out — auto-retry once.
class _E2eeHandshakeTimeout extends ChatE2eeEvent {
  const _E2eeHandshakeTimeout(this.peerId);
  final String peerId;

  @override
  List<Object?> get props => [peerId];
}

/// Reset E2EE state (e.g., when the conversation is closed).
class ResetE2ee extends ChatE2eeEvent {
  const ResetE2ee();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class ChatE2eeState extends Equatable {
  const ChatE2eeState({
    this.isActive = false,
    this.isHandshaking = false,
    this.peerId,
  });

  /// True when a Noise_XK session is established with the current peer.
  final bool isActive;

  /// True while the handshake is in progress.
  final bool isHandshaking;

  /// The peer ID this E2EE state pertains to.
  final String? peerId;

  ChatE2eeState copyWith({
    bool? isActive,
    bool? isHandshaking,
    String? peerId,
    bool clearPeerId = false,
  }) {
    return ChatE2eeState(
      isActive: isActive ?? this.isActive,
      isHandshaking: isHandshaking ?? this.isHandshaking,
      peerId: clearPeerId ? null : (peerId ?? this.peerId),
    );
  }

  @override
  List<Object?> get props => [isActive, isHandshaking, peerId];
}

// ---------------------------------------------------------------------------
// Bloc
// ---------------------------------------------------------------------------

/// Manages E2EE handshake state for the active chat conversation.
///
/// Subscribes to [EncryptionService] streams for session establishment,
/// peer key arrival, and handshake timeouts. Keeps the UI lock icon
/// and "Securing…" banner in sync.
class ChatE2eeBloc extends Bloc<ChatE2eeEvent, ChatE2eeState> {
  ChatE2eeBloc({
    required EncryptionService encryptionService,
  })  : _encryptionService = encryptionService,
        super(const ChatE2eeState()) {
    on<InitiateE2eeHandshake>(_onInitiate);
    on<E2eeSessionEstablished>(_onSessionEstablished);
    on<_E2eePeerKeyArrived>(_onPeerKeyArrived);
    on<_E2eeHandshakeTimeout>(_onHandshakeTimeout);
    on<ResetE2ee>(_onReset);

    _sessionSub = _encryptionService.sessionEstablishedStream.listen((peerId) {
      if (!isClosed) add(E2eeSessionEstablished(peerId));
    });

    _keyStoredSub = _encryptionService.peerKeyStoredStream.listen((peerId) {
      if (!isClosed) add(_E2eePeerKeyArrived(peerId));
    });

    _timeoutSub = _encryptionService.handshakeTimeoutStream.listen((peerId) {
      if (!isClosed) add(_E2eeHandshakeTimeout(peerId));
    });
  }

  final EncryptionService _encryptionService;
  StreamSubscription<String>? _sessionSub;
  StreamSubscription<String>? _keyStoredSub;
  StreamSubscription<String>? _timeoutSub;
  int _handshakeRetryCount = 0;

  /// Initiate handshake when conversation is opened.
  Future<void> _onInitiate(
    InitiateE2eeHandshake event,
    Emitter<ChatE2eeState> emit,
  ) async {
    _handshakeRetryCount = 0;
    final peerId = event.peerId;

    if (_encryptionService.hasSession(peerId)) {
      emit(ChatE2eeState(isActive: true, peerId: peerId));
      return;
    }

    if (_encryptionService.hasPendingHandshake(peerId)) {
      emit(ChatE2eeState(isHandshaking: true, peerId: peerId));
      return;
    }

    emit(ChatE2eeState(isHandshaking: true, peerId: peerId));
    final result = await _encryptionService.initiateHandshake(peerId);
    if (result.hasError) {
      Logger.warning(
        'E2EE handshake initiation failed for $peerId: ${result.error}',
        'ChatE2eeBloc',
      );
      // Keep isHandshaking true — peerKeyStoredStream retries when key arrives.
    }
  }

  void _onSessionEstablished(
    E2eeSessionEstablished event,
    Emitter<ChatE2eeState> emit,
  ) {
    if (state.peerId == null) return;
    if (state.peerId == event.peerId) {
      emit(state.copyWith(isActive: true, isHandshaking: false));
      Logger.info(
        'E2EE session active in chat with ${event.peerId}',
        'ChatE2eeBloc',
      );
    }
  }

  Future<void> _onHandshakeTimeout(
    _E2eeHandshakeTimeout event,
    Emitter<ChatE2eeState> emit,
  ) async {
    if (state.peerId == null || state.peerId != event.peerId) return;
    if (_encryptionService.hasSession(event.peerId)) return;

    // Auto-retry once.
    if (_handshakeRetryCount >= 1) {
      Logger.info(
        'E2EE handshake timed out for ${event.peerId} — max retries reached',
        'ChatE2eeBloc',
      );
      emit(state.copyWith(isHandshaking: false));
      return;
    }

    _handshakeRetryCount++;
    Logger.info(
      'E2EE handshake timed out for ${event.peerId} — auto-retrying '
      '(attempt $_handshakeRetryCount)',
      'ChatE2eeBloc',
    );

    await Future<void>.delayed(const Duration(seconds: 2));
    if (isClosed) return;
    if (_encryptionService.hasSession(event.peerId) ||
        _encryptionService.hasPendingHandshake(event.peerId)) {
      return;
    }

    emit(state.copyWith(isHandshaking: true));
    final result = await _encryptionService.initiateHandshake(event.peerId);
    if (result.hasError) {
      Logger.warning(
        'E2EE handshake auto-retry failed for ${event.peerId}: ${result.error}',
        'ChatE2eeBloc',
      );
    }
  }

  Future<void> _onPeerKeyArrived(
    _E2eePeerKeyArrived event,
    Emitter<ChatE2eeState> emit,
  ) async {
    if (state.peerId == null) return;
    if (state.peerId != event.peerId) return;
    if (_encryptionService.hasSession(event.peerId) ||
        _encryptionService.hasPendingHandshake(event.peerId)) {
      return;
    }

    Logger.info(
      'Public key arrived for ${event.peerId} — retrying E2EE handshake',
      'ChatE2eeBloc',
    );
    emit(state.copyWith(isHandshaking: true));

    final result = await _encryptionService.initiateHandshake(event.peerId);
    if (result.hasError) {
      Logger.warning(
        'E2EE handshake retry failed for ${event.peerId}: ${result.error}',
        'ChatE2eeBloc',
      );
    }
  }

  void _onReset(ResetE2ee event, Emitter<ChatE2eeState> emit) {
    _handshakeRetryCount = 0;
    emit(const ChatE2eeState());
  }

  @override
  Future<void> close() {
    _sessionSub?.cancel();
    _keyStoredSub?.cancel();
    _timeoutSub?.cancel();
    return super.close();
  }
}
