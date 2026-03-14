import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/connection/connection_manager.dart';
import 'package:anchor/services/ble/connection/peer_connection.dart';
import 'package:anchor/services/ble/gatt/gatt_write_queue.dart';
import 'package:anchor/services/ble/mesh/mesh_relay_service.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

// ── Mocks & fakes ────────────────────────────────────────────────────────────

class MockConnectionManager extends Mock implements ConnectionManager {}

class MockGattWriteQueue extends Mock implements GattWriteQueue {}

class MockPeripheral extends Mock implements Peripheral {}

class MockGATTCharacteristic extends Mock implements GATTCharacteristic {}

// Fakes used as fallback values so mocktail any() matchers work with
// native bluetooth_low_energy types in sound null-safe mode.
class FakePeripheral extends Fake implements Peripheral {}

class FakeGATTCharacteristic extends Fake implements GATTCharacteristic {}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Build a standard mesh relay JSON packet.
Map<String, dynamic> buildRelayJson({
  String type = 'message',
  String senderId = 'sender-user',
  String destinationId = 'dest-user',
  int ttl = 3,
  List<String>? relayPath,
  String messageId = 'msg-1',
  String content = 'Hello',
}) {
  return {
    'type': type,
    'sender_id': senderId,
    'destination_id': destinationId,
    'message_id': messageId,
    'content': content,
    'ttl': ttl,
    'relay_path': relayPath ?? [senderId],
    'message_type': 0,
  };
}

/// Build a peer_announce JSON packet.
Map<String, dynamic> buildAnnounceJson({
  String messageId = 'ann-1',
  String peerId = 'relayed-peer-id',
  String peerUserId = 'relayed-user',
  String name = 'Relayed Bob',
  int ttl = 2,
  List<String>? relayPath,
}) {
  return {
    'type': 'peer_announce',
    'message_id': messageId,
    'peer_id': peerId,
    'peer_user_id': peerUserId,
    'name': name,
    'ttl': ttl,
    'relay_path': relayPath ?? ['originator'],
  };
}

/// Create a [PeerConnection] with a non-null messaging characteristic.
PeerConnection fakePeerConn(String peerId) {
  return PeerConnection(
    peerId: peerId,
    peripheral: MockPeripheral(),
    messagingChar: MockGATTCharacteristic(),
  );
}

void main() {
  setUpAll(() {
    // Register fallback values for native BLE types so any() matchers compile
    // in sound null-safe mode without needing real BLE hardware.
    registerFallbackValue(FakePeripheral());
    registerFallbackValue(FakeGATTCharacteristic());
    registerFallbackValue(WritePriority.meshRelay);
    registerFallbackValue(Uint8List(0));
  });

  late MockConnectionManager mockConn;
  late MockGattWriteQueue mockQueue;
  late MeshRelayService relay;

  setUp(() {
    mockConn = MockConnectionManager();
    mockQueue = MockGattWriteQueue();

    // Default stubs — individual tests override as needed
    when(() => mockConn.connectedPeerIds).thenReturn([]);
    when(() => mockConn.canSendTo(any())).thenReturn(false);
    when(() => mockConn.isDeadPeer(any())).thenReturn(false);
    when(() => mockConn.activeConnectionCount).thenReturn(0);
    when(() => mockConn.getConnection(any())).thenReturn(null);

    // Stub void method so it's a no-op instead of MissingStubError
    when(() => mockQueue.enqueueFireAndForget(
          peerId: any(named: 'peerId'),
          peripheral: any(named: 'peripheral'),
          characteristic: any(named: 'characteristic'),
          data: any(named: 'data'),
          priority: any(named: 'priority'),
        )).thenReturn(null);

    relay = MeshRelayService(
      connectionManager: mockConn,
      writeQueue: mockQueue,
      config: BleConfig.development,
    );

    // Provide own userId so loop detection works
    relay.getOwnUserId = () => 'own-user';
    relay.getVisiblePeerCount = () => 0;
    relay.getAppUserIdForPeer = (_) => null;
    relay.isDirectPeer = (_) => false;
  });

  // ── TTL enforcement ───────────────────────────────────────────────────────

  group('maybeRelayMessage TTL', () {
    test('drops message when TTL = 0 — no writes enqueued', () {
      final json = buildRelayJson(ttl: 0, relayPath: ['sender']);

      relay.maybeRelayMessage(json, 'from-peer');

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });

    test('drops message when TTL is negative', () {
      final json = buildRelayJson(ttl: -1);

      relay.maybeRelayMessage(json, 'from-peer');

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });

    test('forwards message when TTL = 1 (decrements to 0 in payload)', () {
      when(() => mockConn.connectedPeerIds).thenReturn(['relay-peer']);
      when(() => mockConn.canSendTo('relay-peer')).thenReturn(true);
      when(() => mockConn.isDeadPeer(any())).thenReturn(false);
      when(() => mockConn.getConnection('relay-peer')).thenReturn(fakePeerConn('relay-peer'));
      when(() => mockConn.activeConnectionCount).thenReturn(1);

      final json = buildRelayJson(ttl: 1, relayPath: ['sender']);

      relay.maybeRelayMessage(json, 'sender-peer');

      // At least one write should have been attempted
      verify(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          )).called(1);
    });
  });

  // ── Loop detection ────────────────────────────────────────────────────────

  group('maybeRelayMessage loop detection', () {
    test('drops message already containing own userId in relay_path', () {
      // own-user is already in the relay path — should not re-relay
      final json = buildRelayJson(
        ttl: 3,
        relayPath: ['sender', 'own-user'],
      );

      relay.maybeRelayMessage(json, 'from-peer');

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });

    test('relays message when relay_path does not contain own userId', () {
      when(() => mockConn.connectedPeerIds).thenReturn(['next-hop']);
      when(() => mockConn.canSendTo('next-hop')).thenReturn(true);
      when(() => mockConn.isDeadPeer(any())).thenReturn(false);
      when(() => mockConn.getConnection('next-hop')).thenReturn(fakePeerConn('next-hop'));
      when(() => mockConn.activeConnectionCount).thenReturn(1);

      final json = buildRelayJson(ttl: 2, relayPath: ['other-user']);

      relay.maybeRelayMessage(json, 'from-peer');

      verify(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          )).called(1);
    });
  });

  // ── Disabled relay ────────────────────────────────────────────────────────

  group('maybeRelayMessage when disabled', () {
    test('does not relay when enabled = false', () {
      relay.enabled = false;

      when(() => mockConn.connectedPeerIds).thenReturn(['p1']);
      when(() => mockConn.canSendTo('p1')).thenReturn(true);

      final json = buildRelayJson(ttl: 3);

      relay.maybeRelayMessage(json, 'from');

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });
  });

  // ── Relay excludes sender ─────────────────────────────────────────────────

  group('maybeRelayMessage excludes original sender', () {
    test('does not relay back to the peer that sent the message', () {
      when(() => mockConn.connectedPeerIds).thenReturn(['sender-peer', 'other-peer']);
      when(() => mockConn.canSendTo(any())).thenReturn(true);
      when(() => mockConn.isDeadPeer(any())).thenReturn(false);
      when(() => mockConn.getConnection('other-peer')).thenReturn(fakePeerConn('other-peer'));
      when(() => mockConn.getConnection('sender-peer')).thenReturn(null);
      when(() => mockConn.activeConnectionCount).thenReturn(2);

      final json = buildRelayJson(ttl: 2, relayPath: ['originator']);

      relay.maybeRelayMessage(json, 'sender-peer');

      // Only 'other-peer' should receive the relay, not 'sender-peer'
      verify(() => mockQueue.enqueueFireAndForget(
            peerId: 'other-peer',
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          )).called(1);

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: 'sender-peer',
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });
  });

  // ── Routing table ─────────────────────────────────────────────────────────

  group('handleNeighborList', () {
    test('updates routing table size', () {
      expect(relay.routingTableSize, 0);

      relay.handleNeighborList({
        'type': 'neighbor_list',
        'sender_id': 'node-A',
        'peers': ['user-1', 'user-2', 'user-3'],
        'ttl': 1,
      });

      expect(relay.routingTableSize, 1);
    });

    test('stores neighbor list for findBestRelayPeer lookup', () {
      relay.handleNeighborList({
        'type': 'neighbor_list',
        'sender_id': 'relay-node-user',
        'peers': ['target-user'],
        'ttl': 1,
      });

      // 'relay-node-peer' knows 'target-user'
      relay.getAppUserIdForPeer = (peerId) =>
          peerId == 'relay-node-peer' ? 'relay-node-user' : null;

      when(() => mockConn.connectedPeerIds).thenReturn(['relay-node-peer']);
      when(() => mockConn.canSendTo('relay-node-peer')).thenReturn(true);

      final best = relay.findBestRelayPeer('target-user', '');
      expect(best, 'relay-node-peer');
    });

    test('ignores entries with empty sender_id', () {
      relay.handleNeighborList({
        'type': 'neighbor_list',
        'sender_id': '',
        'peers': ['user-X'],
        'ttl': 1,
      });

      expect(relay.routingTableSize, 0);
    });

    test('updates existing entry for same sender', () {
      relay.handleNeighborList({
        'sender_id': 'node-A',
        'peers': ['user-1', 'user-2'],
        'ttl': 1,
      });
      relay.handleNeighborList({
        'sender_id': 'node-A',
        'peers': ['user-3'], // replaced
        'ttl': 1,
      });

      expect(relay.routingTableSize, 1); // still 1 entry for node-A

      relay.getAppUserIdForPeer = (p) => p == 'peer-A' ? 'node-A' : null;
      when(() => mockConn.connectedPeerIds).thenReturn(['peer-A']);
      when(() => mockConn.canSendTo('peer-A')).thenReturn(true);

      // user-1 is gone from the updated list
      expect(relay.findBestRelayPeer('user-1', ''), isNull);
      // user-3 is in the new list
      expect(relay.findBestRelayPeer('user-3', ''), 'peer-A');
    });
  });

  // ── findBestRelayPeer ─────────────────────────────────────────────────────

  group('findBestRelayPeer', () {
    test('returns null when no routing info available', () {
      when(() => mockConn.connectedPeerIds).thenReturn([]);

      expect(relay.findBestRelayPeer('some-user', ''), isNull);
    });

    test('returns null when peer connected but does not know destination', () {
      relay.handleNeighborList({
        'sender_id': 'relay-user',
        'peers': ['unrelated-user'],
        'ttl': 1,
      });

      relay.getAppUserIdForPeer = (p) => p == 'relay-peer' ? 'relay-user' : null;
      when(() => mockConn.connectedPeerIds).thenReturn(['relay-peer']);
      when(() => mockConn.canSendTo('relay-peer')).thenReturn(true);

      expect(relay.findBestRelayPeer('target-user', ''), isNull);
    });

    test('excludes specified peer from best relay selection', () {
      relay.handleNeighborList({
        'sender_id': 'relay-A-user',
        'peers': ['target-user'],
        'ttl': 1,
      });
      relay.handleNeighborList({
        'sender_id': 'relay-B-user',
        'peers': ['target-user'],
        'ttl': 1,
      });

      relay.getAppUserIdForPeer = (p) {
        if (p == 'peer-A') return 'relay-A-user';
        if (p == 'peer-B') return 'relay-B-user';
        return null;
      };
      when(() => mockConn.connectedPeerIds).thenReturn(['peer-A', 'peer-B']);
      when(() => mockConn.canSendTo(any())).thenReturn(true);

      // Exclude peer-A — should fall back to peer-B
      final best = relay.findBestRelayPeer('target-user', 'peer-A');
      expect(best, 'peer-B');
    });
  });

  // ── handlePeerAnnounce ────────────────────────────────────────────────────

  group('handlePeerAnnounce', () {
    test('fires onRelayedPeerDiscovered with correct peer data', () {
      RelayedPeerResult? result;
      relay.onRelayedPeerDiscovered = (r) => result = r;

      final announce = buildAnnounceJson(
        peerId: 'remote-peer',
        peerUserId: 'remote-user',
        name: 'Bob',
      );

      relay.handlePeerAnnounce(announce, 'from-peer');

      expect(result, isNotNull);
      expect(result!.peer.peerId, 'remote-peer');
      expect(result!.peer.name, 'Bob');
      expect(result!.peer.isRelayed, isTrue);
      expect(result!.userId, 'remote-user');
    });

    test('deduplicates by message_id — fires callback only once', () {
      int callCount = 0;
      relay.onRelayedPeerDiscovered = (_) => callCount++;

      final announce = buildAnnounceJson(messageId: 'ann-dup');

      relay.handlePeerAnnounce(announce, 'from-peer-1');
      relay.handlePeerAnnounce(announce, 'from-peer-2'); // same message_id

      expect(callCount, 1);
    });

    test('ignores announces for own userId', () {
      relay.getOwnUserId = () => 'own-user';

      RelayedPeerResult? result;
      relay.onRelayedPeerDiscovered = (r) => result = r;

      // Announce for own peer
      final selfAnnounce = buildAnnounceJson(peerUserId: 'own-user');

      relay.handlePeerAnnounce(selfAnnounce, 'from-peer');

      expect(result, isNull);
    });

    test('does not fire callback if peer is directly visible', () {
      relay.isDirectPeer = (peerId) => peerId == 'direct-peer-id';

      RelayedPeerResult? result;
      relay.onRelayedPeerDiscovered = (r) => result = r;

      final announce = buildAnnounceJson(peerId: 'direct-peer-id');

      relay.handlePeerAnnounce(announce, 'from-peer');

      expect(result, isNull);
    });

    test('decodes hop count from relay_path length', () {
      RelayedPeerResult? result;
      relay.onRelayedPeerDiscovered = (r) => result = r;

      final announce = buildAnnounceJson(
        relayPath: ['originator', 'hop-1', 'hop-2'],
      );

      relay.handlePeerAnnounce(announce, 'from-peer');

      expect(result!.peer.hopCount, 3);
    });

    test('decodes base64 thumbnail when present', () {
      RelayedPeerResult? result;
      relay.onRelayedPeerDiscovered = (r) => result = r;

      final thumbData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b64 = base64Encode(thumbData);

      final announce = {
        ...buildAnnounceJson(),
        'thumbnail_b64': b64,
      };

      relay.handlePeerAnnounce(announce, 'from-peer');

      expect(result!.peer.thumbnailBytes, orderedEquals(thumbData));
    });
  });

  // ── announcePeerToMesh throttle ───────────────────────────────────────────

  group('announcePeerToMesh', () {
    test('does nothing when disabled', () {
      relay.enabled = false;

      when(() => mockConn.activeConnectionCount).thenReturn(2);

      final peer = DiscoveredPeer(
        peerId: 'direct-peer',
        name: 'Alice',
        timestamp: DateTime.now(),
      );

      relay.announcePeerToMesh(peer);

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });

    test('does nothing for relayed peers (only announce direct peers)', () {
      when(() => mockConn.activeConnectionCount).thenReturn(2);
      when(() => mockConn.connectedPeerIds).thenReturn(['p1']);
      when(() => mockConn.isDeadPeer(any())).thenReturn(false);
      when(() => mockConn.getConnection('p1')).thenReturn(fakePeerConn('p1'));

      final relayed = DiscoveredPeer(
        peerId: 'relayed-peer',
        name: 'Relayed',
        timestamp: DateTime.now(),
        isRelayed: true,
      );

      relay.announcePeerToMesh(relayed);

      verifyNever(() => mockQueue.enqueueFireAndForget(
            peerId: any(named: 'peerId'),
            peripheral: any(named: 'peripheral'),
            characteristic: any(named: 'characteristic'),
            data: any(named: 'data'),
            priority: any(named: 'priority'),
          ));
    });
  });

  // ── clear() ───────────────────────────────────────────────────────────────

  group('clear', () {
    test('resets routing table', () {
      relay.handleNeighborList({
        'sender_id': 'node-A',
        'peers': ['user-1'],
        'ttl': 1,
      });

      expect(relay.routingTableSize, 1);
      relay.clear();
      expect(relay.routingTableSize, 0);
    });

    test('clears seen announce IDs so same message can arrive again', () {
      int callCount = 0;
      relay.onRelayedPeerDiscovered = (_) => callCount++;

      final announce = buildAnnounceJson(messageId: 'ann-clear');
      relay.handlePeerAnnounce(announce, 'from');
      expect(callCount, 1);

      relay.clear(); // reset seen IDs

      // Can now process the same announcement again
      relay.handlePeerAnnounce(announce, 'from');
      expect(callCount, 2);
    });
  });
}
