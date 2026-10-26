import 'package:flutter/services.dart';

class ServerKeyStore {
  static const _channel = MethodChannel(
    'com.example.ble_working/payment_crypto',
  );

  Future<String?> load() => _channel.invokeMethod<String>('getServerPublicKey');

  Future<void> save(String publicKey) => _channel.invokeMethod<void>(
    'saveServerPublicKey',
    {'publicKey': publicKey.trim()},
  );
}
