import 'dart:convert';

import 'package:http/http.dart' as http;

import '../mesh_packet.dart';

abstract interface class PaymentGateway {
  Future<GatewayResult> submit(
    MeshPacket packet, {
    required String bridgeNodeId,
    required int hopCount,
  });
}

class GatewayResult {
  const GatewayResult({
    required this.accepted,
    required this.message,
    this.retryable = false,
  });

  final bool accepted;
  final String message;
  final bool retryable;
}

/// Uses an explicitly configured test endpoint; otherwise runs a local demo.
/// No payment data is sent to a third-party placeholder service by default.
class DummyPaymentGateway implements PaymentGateway {
  DummyPaymentGateway({http.Client? client})
    : _client = client ?? http.Client();

  static const _endpoint = String.fromEnvironment('PAYMENT_API_URL');
  final http.Client _client;

  @override
  Future<GatewayResult> submit(
    MeshPacket packet, {
    required String bridgeNodeId,
    required int hopCount,
  }) async {
    if (_endpoint.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return const GatewayResult(
        accepted: true,
        message: 'Demo accepted (no bank server configured)',
      );
    }

    final response = await _client
        .post(
          Uri.parse(_endpoint),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'packet': jsonDecode(packet.toJson()),
            'bridgeNodeId': bridgeNodeId,
            'hopCount': hopCount,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return GatewayResult(
        accepted: false,
        message: 'Test API returned HTTP ${response.statusCode}',
        retryable: response.statusCode >= 500,
      );
    }
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['outcome'] is String) {
        final outcome = body['outcome'] as String;
        if (outcome == 'SETTLED') {
          return const GatewayResult(
            accepted: true,
            message: 'Server settled the payment',
          );
        }
        final reason = body['reason']?.toString();
        return GatewayResult(
          accepted: false,
          message: reason == null
              ? 'Server outcome: $outcome'
              : '$outcome: $reason',
          retryable: reason?.contains('internal_error') ?? false,
        );
      }
    } on FormatException {
      // Some simple test endpoints return a non-JSON success response.
    }
    return GatewayResult(
      accepted: true,
      message: 'Test API accepted the packet',
    );
  }
}
