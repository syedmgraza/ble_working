import 'dart:convert';
import 'package:uuid/uuid.dart';

class MeshPacket {
  final String packetId;
  final int ttl;
  final String payload;

  MeshPacket({
    required this.packetId,
    required this.ttl,
    required this.payload,
  });

  factory MeshPacket.create(String payload) {
    return MeshPacket(
      packetId: const Uuid().v4(),
      ttl: 5,
      payload: payload,
    );
  }

  String toJson() {
    return jsonEncode({
      "packetId": packetId,
      "ttl": ttl,
      "payload": payload,
    });
  }

  factory MeshPacket.fromJson(String json) {
    Map<String, dynamic> map =
    jsonDecode(json);

    return MeshPacket(
      packetId: map["packetId"],
      ttl: map["ttl"],
      payload: map["payload"],
    );
  }

  MeshPacket decrementTTL() {
    return MeshPacket(
      packetId: packetId,
      ttl: ttl - 1,
      payload: payload,
    );
  }
}