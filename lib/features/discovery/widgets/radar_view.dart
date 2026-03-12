import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../bloc/discovery_state.dart';
import 'radar_peer_sheet.dart';

// ── Ring bucketing ────────────────────────────────────────────────────────────

/// Classifies a peer into one of four proximity rings (0 = closest, 3 = farthest).
///
/// Direct peers are bucketed purely by RSSI.
/// Relayed peers are pushed outward by hop count so that multi-hop mesh
/// peers always appear farther than single-hop or direct ones.
int radarRingFor(DiscoveredPeer peer) {
  if (peer.isRelayed) {
    // Each hop beyond 0 adds at least one ring of distance.
    final hopOffset = peer.hopCount.clamp(1, 3);
    return (hopOffset + 1).clamp(1, 3);
  }

  final rssi = peer.rssi;
  if (rssi == null) return 2; // unknown → middle ring
  if (rssi >= -55) return 0; // Very close
  if (rssi >= -65) return 1; // Close
  if (rssi >= -75) return 2; // Moderate
  return 3; // Distant / weak
}

// ── Stable per-peer angle ─────────────────────────────────────────────────────

/// Returns a stable angle in [0, 2π) for a peer, seeded from their peer ID.
/// Using the ID as a seed ensures the dot doesn't jump position across
/// timer-driven refreshes.
double _stableAngle(String peerId) {
  final seed = peerId.hashCode.abs();
  return (seed % 3600) / 3600 * 2 * math.pi;
}

// ── Data model ────────────────────────────────────────────────────────────────

/// Minimal data fed to [RadarPainter] for each peer dot.
class _RadarDot {
  const _RadarDot({
    required this.peer,
    required this.ring,
    required this.angle,
  });

  final DiscoveredPeer peer;
  final int ring; // 0–3
  final double angle; // radians
}

// ── Ring metadata ─────────────────────────────────────────────────────────────

const _ringRadiusFraction = [0.22, 0.44, 0.66, 0.85];
const _ringColors = [
  Color(0xFF00BCD4), // teal  – very close
  Color(0xFF26A69A), // green-teal – close
  Color(0xFF1565C0), // deep blue – moderate
  Color(0xFF512DA8), // deep purple – distant
];
const _ringLabels = ['Very close', 'Close', 'Moderate', 'Distant'];

// ── RadarView ─────────────────────────────────────────────────────────────────

/// Radar-style proximity visualization for discovered peers.
///
/// Shows peers as colored dots on concentric rings. Ring placement is derived
/// from RSSI (direct peers) or hop count (relayed peers). No real direction
/// or GPS is used — dots are placed at stable but randomised angles.
///
/// The widget self-refreshes every [refreshInterval] while visible.
class RadarView extends StatefulWidget {
  const RadarView({
    super.key,
    required this.peers,
    this.refreshInterval = const Duration(seconds: 3),
    this.highDensityThreshold = 50,
  });

  final List<DiscoveredPeer> peers;
  final Duration refreshInterval;
  final int highDensityThreshold;

  /// A [ValueNotifier] that the parent [DiscoveryScreen] listens to in order
  /// to open a [PeerDetailScreen] when the user taps a dot inside the sheet.
  static final ValueNotifier<DiscoveredPeer?> _peerTapNotifier =
      ValueNotifier(null);

  static void listenForPeerTaps(ValueChanged<DiscoveredPeer> onTap) {
    _peerTapNotifier.addListener(() {
      final peer = _peerTapNotifier.value;
      if (peer != null) {
        _peerTapNotifier.value = null;
        onTap(peer);
      }
    });
  }

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Timer? _refreshTimer;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  /// The set of peer IDs seen last refresh — used to detect new nearby arrivals.
  final Set<String> _knownPeerIds = {};

  /// Whether a new peer appeared since last frame (triggers pulse animation).
  bool _newPeerArrived = false;

  List<_RadarDot> _dots = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeOut,
    );

    _rebuild();
    _startTimer();
  }

  @override
  void didUpdateWidget(RadarView old) {
    super.didUpdateWidget(old);
    _rebuild();
    // Adjust timer rate if peer count crosses density threshold
    final isHighDensity = widget.peers.length > widget.highDensityThreshold;
    final wasHighDensity = old.peers.length > old.highDensityThreshold;
    if (isHighDensity != wasHighDensity) {
      _startTimer(); // restarts with new interval
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _stopTimer();
    }
  }

  void _startTimer() {
    _stopTimer();
    final interval = widget.peers.length > widget.highDensityThreshold
        ? const Duration(seconds: 5)
        : widget.refreshInterval;
    _refreshTimer = Timer.periodic(interval, (_) => _rebuild());
  }

  void _stopTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _rebuild() {
    if (!mounted) return;

    final newIds = widget.peers.map((p) => p.peerId).toSet();
    final hasNew = newIds.difference(_knownPeerIds).isNotEmpty;
    _knownPeerIds
      ..clear()
      ..addAll(newIds);

    final dots = widget.peers
        .where((p) => !p.isBlocked)
        .map((p) => _RadarDot(
              peer: p,
              ring: radarRingFor(p),
              angle: _stableAngle(p.peerId),
            ))
        .toList();

    setState(() {
      _dots = dots;
      _newPeerArrived = hasNew;
    });

    if (hasNew) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _stopTimer();
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    super.dispose();
  }

  // ── Ring density for heat coloring ─────────────────────────────────────────

  /// Count of peers per ring (0–3).
  List<int> get _ringCounts {
    final counts = List.filled(4, 0);
    for (final d in _dots) {
      counts[d.ring]++;
    }
    return counts;
  }

  // ── Tap handling ───────────────────────────────────────────────────────────

  void _onTapDown(TapDownDetails details, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final tap = details.localPosition;
    final dist = (tap - center).distance;

    // Determine which ring was tapped
    int tappedRing = -1;
    for (int i = 0; i < 4; i++) {
      final ringR = _ringRadiusFraction[i] * radius;
      if (dist <= ringR + 16) {
        // 16px hit slop
        tappedRing = i;
        break;
      }
    }

    // Also check if a specific dot was tapped (within 20px)
    _RadarDot? tappedDot;
    for (final dot in _dots) {
      final ringR = _ringRadiusFraction[dot.ring] * radius;
      final dx = ringR * math.cos(dot.angle);
      final dy = ringR * math.sin(dot.angle);
      final dotCenter = center + Offset(dx, dy);
      if ((tap - dotCenter).distance < 20) {
        tappedDot = dot;
        break;
      }
    }

    final ring = tappedDot?.ring ?? tappedRing;
    if (ring < 0) return;

    final peersInRing = _dots
        .where((d) => d.ring == ring)
        .map((d) => d.peer)
        .toList();

    if (peersInRing.isNotEmpty) {
      _showRingSheet(ring, peersInRing);
    }
  }

  void _showRingSheet(int ring, List<DiscoveredPeer> peers) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => RadarPeerSheet(
        ringLabel: _ringLabels[ring],
        ringColor: _ringColors[ring],
        peers: peers,
        onPeerTap: (peer) {
          Navigator.pop(context);
          // Notify parent so it can open the peer detail screen.
          RadarView._peerTapNotifier.value = peer;
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final counts = _ringCounts;

    return Column(
      children: [
        // ── Legend ───────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: _buildLegend(counts),
        ),

        // ── Radar canvas ─────────────────────────────────────────────────────
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = math.min(constraints.maxWidth, constraints.maxHeight);
              return Center(
                child: GestureDetector(
                  onTapDown: (d) =>
                      _onTapDown(d, Size(size, size)),
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (_, __) => CustomPaint(
                      size: Size(size, size),
                      painter: _RadarPainter(
                        dots: _dots,
                        ringCounts: counts,
                        pulseValue: _newPeerArrived ? _pulseAnimation.value : 0,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // ── Zone description ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: _buildZoneDescription(counts),
        ),
      ],
    );
  }

  Widget _buildLegend(List<int> counts) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: List.generate(4, (i) {
        final n = counts[i];
        if (n == 0) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _ringColors[i],
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${_ringLabels[i]} ($n)',
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildZoneDescription(List<int> counts) {
    final innerCount = counts[0] + counts[1];
    final outerCount = counts[2] + counts[3];
    final total = innerCount + outerCount;

    if (total == 0) {
      return const Text(
        'No one detected nearby. Move around to find people.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.textHint, fontSize: 13),
      );
    }

    String label;
    if (innerCount >= 5) {
      label = '🔥 High energy zone! $innerCount people very close';
    } else if (innerCount > 0) {
      label = '✨ $innerCount ${innerCount == 1 ? 'person' : 'people'} nearby';
    } else if (outerCount >= 10) {
      label = '🌐 Busy area — $outerCount people in range via mesh';
    } else {
      label = '🔵 $total ${total == 1 ? 'person' : 'people'} detected — quiet area, explore!';
    }

    return Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500),
    );
  }
}

// ── CustomPainter ─────────────────────────────────────────────────────────────

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.dots,
    required this.ringCounts,
    required this.pulseValue,
  });

  final List<_RadarDot> dots;
  final List<int> ringCounts;
  final double pulseValue; // 0.0–1.0 for pulse ring animation

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2 - 4;

    _drawBackground(canvas, size, center, maxRadius);
    _drawRings(canvas, center, maxRadius);
    if (pulseValue > 0) _drawPulse(canvas, center, maxRadius);
    _drawDots(canvas, center, maxRadius);
    _drawYou(canvas, center);
  }

  // ── Background ──────────────────────────────────────────────────────────────

  void _drawBackground(
      Canvas canvas, Size size, Offset center, double maxRadius) {
    // Clip to circle
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: maxRadius)));

    // Dark radial gradient background
    final bgPaint = Paint()
      ..shader = const RadialGradient(
        colors: [
          Color(0xFF1A2332),
          Color(0xFF0D1520),
        ],
        stops: [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: maxRadius));
    canvas.drawCircle(center, maxRadius, bgPaint);

    // Subtle grid spokes (8 directions)
    final spokePaint = Paint()
      ..color = Colors.white.withAlpha(10)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      canvas.drawLine(
        center,
        center + Offset(maxRadius * math.cos(angle), maxRadius * math.sin(angle)),
        spokePaint,
      );
    }
  }

  // ── Concentric rings ────────────────────────────────────────────────────────

  void _drawRings(Canvas canvas, Offset center, double maxRadius) {
    for (int i = 0; i < 4; i++) {
      final r = _ringRadiusFraction[i] * maxRadius;
      final density = ringCounts[i];
      final heatAlpha = (density * 8).clamp(0, 40).toInt();

      // Heat fill — warmer glow when more people in this ring
      if (density > 0) {
        final heatPaint = Paint()
          ..color = _ringColors[i].withAlpha(heatAlpha)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, r, heatPaint);
      }

      // Ring outline
      final ringPaint = Paint()
        ..color = _ringColors[i].withAlpha(60)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, r, ringPaint);

      // Label on the right side of the ring
      _drawRingLabel(canvas, center, r, _ringLabels[i], _ringColors[i]);
    }
  }

  void _drawRingLabel(
      Canvas canvas, Offset center, double r, String label, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color.withAlpha(120),
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    tp.paint(
      canvas,
      center + Offset(r + 4, -tp.height / 2),
    );
  }

  // ── Pulse ring (new peer arrived) ───────────────────────────────────────────

  void _drawPulse(Canvas canvas, Offset center, double maxRadius) {
    final r = maxRadius * 0.22 * (1 + pulseValue * 0.5);
    final alpha = ((1 - pulseValue) * 180).toInt().clamp(0, 180);
    final pulsePaint = Paint()
      ..color = Colors.cyanAccent.withAlpha(alpha)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, r, pulsePaint);
  }

  // ── Peer dots ────────────────────────────────────────────────────────────────

  void _drawDots(Canvas canvas, Offset center, double maxRadius) {
    for (final dot in dots) {
      final r = _ringRadiusFraction[dot.ring] * maxRadius;
      final dx = r * math.cos(dot.angle);
      final dy = r * math.sin(dot.angle);
      final pos = center + Offset(dx, dy);

      final color = _ringColors[dot.ring];

      // Glow halo
      final glowPaint = Paint()
        ..color = color.withAlpha(40)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(pos, 8, glowPaint);

      // Dot fill
      final dotPaint = Paint()
        ..color = color.withAlpha(220)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 5, dotPaint);

      // Dot outline
      final outlinePaint = Paint()
        ..color = Colors.white.withAlpha(160)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(pos, 5, outlinePaint);

      // Relay hop indicator: small diamond for mesh-relayed peers
      if (dot.peer.isRelayed) {
        final relayPaint = Paint()
          ..color = Colors.white.withAlpha(180)
          ..style = PaintingStyle.fill;
        final diamond = Path()
          ..moveTo(pos.dx, pos.dy - 8)
          ..lineTo(pos.dx + 3, pos.dy - 5)
          ..lineTo(pos.dx, pos.dy - 2)
          ..lineTo(pos.dx - 3, pos.dy - 5)
          ..close();
        canvas.drawPath(diamond, relayPaint);
      }
    }
  }

  // ── "You" dot in center ──────────────────────────────────────────────────────

  void _drawYou(Canvas canvas, Offset center) {
    // Outer glow
    final glowPaint = Paint()
      ..color = AppTheme.primaryColor.withAlpha(50)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(center, 14, glowPaint);

    // Filled circle
    final fillPaint = Paint()
      ..color = AppTheme.primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 9, fillPaint);

    // White border
    final borderPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, 9, borderPaint);

    // "You" text
    final tp = TextPainter(
      text: const TextSpan(
        text: 'You',
        style: TextStyle(
          color: Colors.white,
          fontSize: 7,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center + Offset(-tp.width / 2, 12));
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.dots != dots ||
      old.ringCounts != ringCounts ||
      old.pulseValue != pulseValue;
}
