import 'dart:convert';

import 'package:flutter/services.dart';

class AccountStore {
  static const _channel = MethodChannel(
    'com.example.ble_working/payment_crypto',
  );

  Future<Map<String, dynamic>?> load() async {
    final value = await _channel.invokeMethod<String>('loadAccount');
    if (value == null || value.isEmpty) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }

  Future<void> save(Map<String, Object?> account) => _channel
      .invokeMethod<void>('saveAccount', {'accountJson': jsonEncode(account)});

  Future<void> clear() => _channel.invokeMethod<void>('clearAccount');

  Future<String> sha256Hex(String value) async =>
      (await _channel.invokeMethod<String>('sha256Hex', {'value': value}))!;
}
