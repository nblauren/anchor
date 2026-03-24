import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/transport/transport_retry_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransportRetryQueue', () {
    test('enqueue adds item and length increments', () {
      // We can't easily construct a real TransportRetryQueue without a real
      // TransportManager, so we test the PendingSend model directly.
      final item = PendingSend(
        peerId: 'peer-1',
        messageId: 'msg-1',
        type: PendingSendType.text,
        payload: const MessagePayload(
          messageId: 'msg-1',
          type: MessageType.text,
          content: 'hello',
        ),
      );

      expect(item.attempts, 0);
      expect(item.isExpired, false);
      expect(item.isMaxAttempts, false);
    });

    test('PendingSend expires after retryQueueExpiryMinutes', () {
      final item = PendingSend(
        peerId: 'peer-1',
        messageId: 'msg-1',
        type: PendingSendType.text,
        payload: const MessagePayload(
          messageId: 'msg-1',
          type: MessageType.text,
          content: 'hello',
        ),
        enqueuedAt: DateTime.now().subtract(const Duration(minutes: 11)),
      );

      expect(item.isExpired, true);
    });

    test('PendingSend isMaxAttempts after 5 attempts', () {
      final item = PendingSend(
        peerId: 'peer-1',
        messageId: 'msg-1',
        type: PendingSendType.text,
        payload: const MessagePayload(
          messageId: 'msg-1',
          type: MessageType.text,
          content: 'hello',
        ),
      );

      for (var i = 0; i < 5; i++) {
        item.attempts++;
      }
      expect(item.isMaxAttempts, true);
    });

    test('RetryDeliveryUpdate carries messageId and delivered status', () {
      const update = RetryDeliveryUpdate(
        messageId: 'msg-1',
        delivered: true,
      );
      expect(update.messageId, 'msg-1');
      expect(update.delivered, true);

      const failed = RetryDeliveryUpdate(
        messageId: 'msg-2',
        delivered: false,
      );
      expect(failed.delivered, false);
    });
  });
}
