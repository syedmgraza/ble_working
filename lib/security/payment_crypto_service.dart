import 'package:flutter/services.dart';

/// Uses Android's standard crypto provider so OAEP/GCM match the Java server.
class PaymentCryptoService {
  static const _channel = MethodChannel(
    'com.example.ble_working/payment_crypto',
  );

  Future<String> encryptInstruction({
    required String instructionJson,
    required String serverPublicKeyBase64,
  }) async {
    if (serverPublicKeyBase64.trim().isEmpty) {
      throw StateError('Configure the bank server public key first.');
    }
    final result = await _channel.invokeMethod<String>('encryptPayment', {
      'instructionJson': instructionJson,
      'serverPublicKeyBase64': serverPublicKeyBase64,
    });
    if (result == null || result.isEmpty) {
      throw StateError('The payment payload could not be encrypted.');
    }
    return result;
  }

  Future<({String hash, bool fresh})> claimCiphertext({
    required String ciphertext,
    required String packetJson,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'claimCiphertext',
      {'ciphertext': ciphertext, 'packetJson': packetJson},
    );
    if (result == null) throw StateError('Deduplication store unavailable.');
    return (hash: result['hash']! as String, fresh: result['fresh']! as bool);
  }

  Future<void> releaseCiphertext(String ciphertext) => _channel
      .invokeMethod<void>('releaseCiphertext', {'ciphertext': ciphertext});
}
