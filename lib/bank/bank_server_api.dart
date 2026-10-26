import 'dart:convert';

import 'package:http/http.dart' as http;

import '../mesh_packet.dart';
import '../bridge/payment_gateway.dart';

class BankServerApi {
  BankServerApi({http.Client? client}) : _client = client ?? http.Client();

  static final Uri _base = Uri.parse('https://bankserver-v4uc.onrender.com');
  final http.Client _client;

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final uri = _base.replace(path: path, queryParameters: query);
    final response = await switch (method) {
      'GET' => _client.get(uri, headers: const {'Accept': 'application/json'}),
      _ => _client.post(
        uri,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ),
    }.timeout(const Duration(seconds: 35));
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['error'] ?? decoded['reason']
          : null;
      throw BankApiException(
        message?.toString() ??
            'Bank server returned HTTP ${response.statusCode}',
        response.statusCode,
      );
    }
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Future<Map<String, dynamic>> health() => _request('GET', '/api/health');
  Future<Map<String, dynamic>> fetchServerKey() =>
      _request('GET', '/api/server-key');

  Future<Map<String, dynamic>> register(Map<String, Object?> values) =>
      _request('POST', '/api/accounts/register', body: values);

  Future<Map<String, dynamic>> recharge({
    required String identifier,
    required double amount,
    required String pin,
  }) => _request(
    'POST',
    '/api/accounts/recharge',
    body: {'identifier': identifier, 'amount': amount, 'pin': pin},
  );

  Future<Map<String, dynamic>> profile(String identifier) =>
      _request('GET', '/api/accounts/$identifier');

  Future<List<Map<String, dynamic>>> transactions(
    String identifier, {
    String? status,
  }) async {
    final result = await _request(
      'GET',
      '/api/accounts/$identifier/transactions',
      query: status == null ? null : {'status': status},
    );
    final data = result['data'];
    if (data is List) return data.cast<Map<String, dynamic>>();
    return const [];
  }
}

class BankApiException implements Exception {
  const BankApiException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}

class BankPaymentGateway implements PaymentGateway {
  BankPaymentGateway({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  static final Uri _endpoint = Uri.parse(
    'https://bankserver-v4uc.onrender.com/api/bridge/ingest',
  );

  @override
  Future<GatewayResult> submit(
    MeshPacket packet, {
    required String bridgeNodeId,
    required int hopCount,
  }) async {
    final response = await _client
        .post(
          _endpoint,
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'packet': jsonDecode(packet.toJson()),
            'bridgeNodeId': bridgeNodeId,
            'hopCount': hopCount,
          }),
        )
        .timeout(const Duration(seconds: 35));
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return GatewayResult(
        accepted: false,
        message:
            'Bank server returned an unreadable response (${response.statusCode})',
        retryable: response.statusCode >= 500 || response.statusCode == 408,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          (body['error'] ??
                  body['reason'] ??
                  'Bank server returned HTTP ${response.statusCode}')
              .toString();
      return GatewayResult(
        accepted: false,
        message: message,
        retryable: response.statusCode >= 500 || response.statusCode == 408,
      );
    }
    final outcome = body['outcome']?.toString() ?? 'INVALID';
    final reason = body['reason']?.toString();
    switch (outcome) {
      case 'SETTLED':
        return const GatewayResult(
          accepted: true,
          message: 'Payment settled by bank',
        );
      case 'DUPLICATE_DROPPED':
        return const GatewayResult(
          accepted: true,
          message: 'Already delivered and processed',
        );
      case 'REJECTED':
      case 'INVALID':
        return GatewayResult(
          accepted: false,
          message: reason ?? 'Payment $outcome',
          retryable: false,
        );
      default:
        return GatewayResult(
          accepted: false,
          message: 'Unknown bank response: $outcome',
          retryable: true,
        );
    }
  }
}
