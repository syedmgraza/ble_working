import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Payment payload serialized using the field names expected by the Java model.
class PaymentInstruction {
  PaymentInstruction({
    required this.senderVpa,
    required this.receiverVpa,
    required this.amount,
    this.pinHash = '',
    String? nonce,
    int? signedAt,
  }) : nonce = nonce ?? const Uuid().v4(),
       signedAt = signedAt ?? DateTime.now().millisecondsSinceEpoch;

  final String senderVpa;
  final String receiverVpa;
  final String amount;
  final String pinHash;
  final String nonce;
  final int signedAt;

  Map<String, Object> toJson() => {
    'senderVpa': senderVpa,
    'receiverVpa': receiverVpa,
    'amount': amount,
    'pinHash': pinHash,
    'nonce': nonce,
    'signedAt': signedAt,
  };

  String encode() => jsonEncode(toJson());
}
