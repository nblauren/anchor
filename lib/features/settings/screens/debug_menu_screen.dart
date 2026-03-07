import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/logger.dart';
import '../../../injection.dart';
import '../../../services/ble/ble.dart';
import '../../../services/database_service.dart';
import '../../discovery/bloc/discovery_bloc.dart';
import '../../discovery/bloc/discovery_event.dart';

/// Debug menu for testing and diagnostics
class DebugMenuScreen extends StatefulWidget {
  const DebugMenuScreen({super.key});

  @override
  State<DebugMenuScreen> createState() => _DebugMenuScreenState();
}

class _DebugMenuScreenState extends State<DebugMenuScreen> {
  final _messageController = TextEditingController();
  String _logs = '';
  bool _isMockBle = false;

  @override
  void initState() {
    super.initState();
    _checkBleType();
    _loadLogs();
  }

  void _checkBleType() {
    final bleService = getIt<BleServiceInterface>();
    setState(() {
      _isMockBle = bleService is MockBleService;
    });
  }

  void _loadLogs() {
    final recent = Logger.getRecentLogs();
    setState(() {
      _logs = recent.isNotEmpty
          ? recent
          : 'No logs yet.\n\nBLE Service: ${_isMockBle ? 'Mock' : 'FlutterBluePlus'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Menu'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadLogs,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // BLE Status section
          _buildSection(
            'BLE Status',
            [
              _buildInfoRow('Service Type', _isMockBle ? 'Mock' : 'FlutterBluePlus'),
              _buildBleStatusRow(),
            ],
          ),

          const SizedBox(height: 24),

          // Mock Data section
          _buildSection(
            'Mock Data',
            [
              _buildActionButton(
                'Add Mock Peers',
                'Generate 5 fake nearby users',
                Icons.people_alt,
                _addMockPeers,
              ),
              _buildActionButton(
                'Simulate Incoming Message',
                'Receive a test message',
                Icons.message,
                _simulateIncomingMessage,
              ),
              _buildActionButton(
                'Simulate Peer Discovered',
                'Add a single mock peer',
                Icons.person_add,
                _simulatePeerDiscovered,
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Database section
          _buildSection(
            'Database',
            [
              _buildActionButton(
                'Clear All Peers',
                'Remove all discovered peers',
                Icons.delete_outline,
                _clearAllPeers,
                isDestructive: true,
              ),
              _buildActionButton(
                'Clear All Messages',
                'Delete all conversations',
                Icons.delete_sweep,
                _clearAllMessages,
                isDestructive: true,
              ),
              _buildActionButton(
                'Export Database Stats',
                'Show database info',
                Icons.analytics,
                _showDatabaseStats,
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Logging section
          _buildSection(
            'Logs',
            [
              Container(
                height: 200,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _logs,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copyLogs,
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy Logs'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _clearLogs,
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('Clear Logs'),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 24),

          // Test Message section
          _buildSection(
            'Send Test Message',
            [
              TextField(
                controller: _messageController,
                decoration: const InputDecoration(
                  hintText: 'Enter test message...',
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _sendTestBroadcast,
                  child: const Text('Broadcast Message'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildBleStatusRow() {
    return BlocBuilder<BleConnectionBloc, BleConnectionState>(
      builder: (context, state) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Status',
                  style: TextStyle(color: AppTheme.textSecondary)),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _getStatusColor(state.status),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    state.status.name,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Color _getStatusColor(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.active:
        return AppTheme.success;
      case BleConnectionStatus.ready:
      case BleConnectionStatus.starting:
        return AppTheme.warning;
      default:
        return AppTheme.error;
    }
  }

  Widget _buildActionButton(
    String title,
    String subtitle,
    IconData icon,
    VoidCallback onTap, {
    bool isDestructive = false,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          icon,
          color: isDestructive ? AppTheme.error : AppTheme.primaryColor,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? AppTheme.error : null,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
      ),
    );
  }

  Future<void> _addMockPeers() async {
    try {
      context.read<DiscoveryBloc>().add(const LoadMockPeers());
      _showSnackBar('Added mock peers');
      _appendLog('Added mock peers');
    } catch (e) {
      _showSnackBar('Failed to add mock peers');
    }
  }

  Future<void> _simulateIncomingMessage() async {
    final db = getIt<DatabaseService>();
    final peers = await db.peerRepository.getAllPeers();

    if (peers.isEmpty) {
      _showSnackBar('No peers available. Add mock peers first.');
      return;
    }

    final peer = peers.first;

    // Get or create conversation
    final conv = await db.chatRepository.getOrCreateConversation(peer.peerId);

    // Add a test message
    await db.chatRepository.addMessage(
      conversationId: conv.id,
      senderId: peer.peerId,
      textContent: 'Test message from ${peer.name} at ${DateTime.now()}',
    );

    _showSnackBar('Simulated message from ${peer.name}');
    _appendLog('Received test message from ${peer.name}');
  }

  Future<void> _simulatePeerDiscovered() async {
    final db = getIt<DatabaseService>();

    final names = ['Alex', 'Jordan', 'Taylor', 'Morgan', 'Casey'];
    final name = names[DateTime.now().millisecond % names.length];
    final peerId = 'mock_${DateTime.now().millisecondsSinceEpoch}';

    await db.peerRepository.upsertPeer(
      peerId: peerId,
      name: name,
      age: 20 + (DateTime.now().second % 15),
      bio: 'Just joined Anchor!',
      rssi: -50 - (DateTime.now().second % 40),
    );

    if (!mounted) return;
    context.read<DiscoveryBloc>().add(const LoadDiscoveredPeers());
    _showSnackBar('Discovered: $name');
    _appendLog('Peer discovered: $name ($peerId)');
  }

  Future<void> _clearAllPeers() async {
    final confirmed = await _showConfirmDialog(
      'Clear All Peers?',
      'This will remove all discovered peers.',
    );

    if (confirmed) {
      final db = getIt<DatabaseService>();
      await db.peerRepository.clearOldPeers(Duration.zero);
      if (!mounted) return;
      context.read<DiscoveryBloc>().add(const LoadDiscoveredPeers());
      _showSnackBar('All peers cleared');
      _appendLog('Cleared all peers');
    }
  }

  Future<void> _clearAllMessages() async {
    final confirmed = await _showConfirmDialog(
      'Clear All Messages?',
      'This will delete all conversations and messages.',
    );

    if (confirmed) {
      final db = getIt<DatabaseService>();
      await db.chatRepository.clearAllConversations();
      _showSnackBar('All messages cleared');
      _appendLog('Cleared all messages');
    }
  }

  Future<void> _showDatabaseStats() async {
    final db = getIt<DatabaseService>();

    final peerCount =
        await db.peerRepository.getPeerCount(includeBlocked: true);
    final blockedCount = (await db.peerRepository.getBlockedPeers()).length;
    final convCount =
        (await db.chatRepository.getConversationsWithPeers()).length;

    final stats = '''
Database Statistics:
- Total Peers: $peerCount
- Blocked Peers: $blockedCount
- Conversations: $convCount
''';

    _appendLog(stats);

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppTheme.darkCard,
          title: const Text('Database Stats'),
          content: Text(stats),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  void _copyLogs() {
    Clipboard.setData(ClipboardData(text: _logs));
    _showSnackBar('Logs copied to clipboard');
  }

  void _clearLogs() {
    Logger.clearBuffer();
    setState(() {
      _logs = 'Logs cleared at ${DateTime.now()}';
    });
  }

  void _sendTestBroadcast() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      _showSnackBar('Please enter a message');
      return;
    }

    try {
      final bleService = getIt<BleServiceInterface>();
      await bleService.broadcastProfile(
        BroadcastPayload(
          userId: 'test_user',
          name: 'Test Broadcast',
          age: null,
          bio: message,
          thumbnailBytes: Uint8List(0),
        ),
      );
      _messageController.clear();
      _showSnackBar('Broadcast sent');
      _appendLog('Sent broadcast: $message');
    } catch (e) {
      _showSnackBar('Broadcast failed: $e');
    }
  }

  void _appendLog(String message) {
    setState(() {
      _logs = '${DateTime.now().toIso8601String()}: $message\n$_logs';
    });
    Logger.info(message, 'Debug');
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<bool> _showConfirmDialog(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: AppTheme.darkCard,
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: AppTheme.error),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }
}
