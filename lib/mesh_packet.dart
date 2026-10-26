import 'dart:convert';

import 'package:uuid/uuid.dart';

/// BLE transport envelope, matching the bank server's MeshPacket JSON model.
class MeshPacket {
  const MeshPacket({
    required this.packetId,
    required this.ttl,
    required this.createdAt,
    required this.ciphertext,
  });

  static const int defaultTtl = 5;

  final String packetId;
  final int ttl;
  final int createdAt;
  final String ciphertext;

  factory MeshPacket.create(String ciphertext) => MeshPacket(
    packetId: const Uuid().v4(),
    ttl: defaultTtl,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    ciphertext: ciphertext,
  );

  String toJson() => jsonEncode({
    'packetId': packetId,
    'ttl': ttl,
    'createdAt': createdAt,
    'ciphertext': ciphertext,
  });

  factory MeshPacket.fromJson(String source) {
    final map = jsonDecode(source) as Map<String, dynamic>;
    final packet = MeshPacket(
      packetId: map['packetId'] as String,
      ttl: (map['ttl'] as num).toInt(),
      createdAt: (map['createdAt'] as num).toInt(),
      ciphertext: map['ciphertext'] as String,
    );
    if (packet.packetId.isEmpty ||
        packet.ciphertext.isEmpty ||
        packet.ttl < 0) {
      throw const FormatException('Invalid mesh packet');
    }
    return packet;
  }

  MeshPacket decrementTtl() => MeshPacket(
    packetId: packetId,
    ttl: ttl - 1,
    createdAt: createdAt,
    ciphertext: ciphertext,
  );
}
