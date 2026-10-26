import 'package:flutter/services.dart';

import '../mesh_packet.dart';

class AuditRecord {
  const AuditRecord({
    required this.direction,
    required this.packetJson,
    required this.deviceId,
    required this.status,
    required this.timestamp,
  });

  final String direction;
  final String packetJson;
  final String deviceId;
  final String status;
  final DateTime timestamp;

  factory AuditRecord.fromMap(Map<dynamic, dynamic> map) => AuditRecord(
    direction: map['direction'] as String? ?? 'UNKNOWN',
    packetJson: map['packetJson'] as String? ?? '',
    deviceId: map['deviceId'] as String? ?? 'unknown',
    status: map['status'] as String? ?? '',
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (map['timestamp'] as num?)?.toInt() ?? 0,
    ),
  );
}

class AuditStore {
  static const _channel = MethodChannel(
    'com.example.ble_working/payment_crypto',
  );

  Future<void> record({
    required String direction,
    required MeshPacket packet,
    required String deviceId,
    required String status,
  }) => _channel.invokeMethod<void>('appendAuditRecord', {
    'direction': direction,
    'packetJson': packet.toJson(),
    'deviceId': deviceId,
    'status': status,
  });

  Future<List<AuditRecord>> load() async {
    final values =
        await _channel.invokeListMethod<Object?>('readAuditRecords') ??
        const <Object?>[];
    return values
        .whereType<Map<dynamic, dynamic>>()
        .map(AuditRecord.fromMap)
        .toList(growable: false);
  }

  Future<void> clear() => _channel.invokeMethod<void>('clearAuditRecords');
}
