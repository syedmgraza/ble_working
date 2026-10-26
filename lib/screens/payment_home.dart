import 'dart:async';

import 'package:flutter/material.dart';

import '../audit/audit_store.dart';
import '../ble_service.dart';
import '../bridge/payment_gateway.dart';
import '../mesh_packet.dart';
import '../models/payment_instruction.dart';
import '../payment_coordinator.dart';
import '../peripheral_service.dart';
import '../permission_service.dart';
import '../security/payment_crypto_service.dart';
import '../security/server_key_store.dart';
import 'audit_screen.dart';

const _developmentServerPublicKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnrSxX/vtL/5SUooJkyEwgpLn7RXk1UN1zR7dNrrsbUAPjcFMcveutQJdIvVkypRe4mFdwm71VMZwgJ6g5zEtXwuFTAFjTeJnPOjiWHPlZGSAo3y0yrl7VgOLbCOG6BKKF3Lko7Gma05aSwK4xbRtQd0QEGfO/pljImSVLyL38mSTs8m/QN2TSrslNgwqbMS83+F7YZ84rqPY21sYQ2dBtXQSHrn1X6dPnuPZ1L8aj72MqqbpZ4slBt8jB4E/9ewhniUtwwsoP7kpCKQSxudeRQfyXQRBaK0gQuuu2oeAVyL28bSwiqdVEZEIcPKIooSYd7QxUHb95oOjUCyy/awSdwIDAQAB';
const _buildServerPublicKey = String.fromEnvironment(
  'SERVER_PUBLIC_KEY_BASE64',
  defaultValue: _developmentServerPublicKey,
);

class PaymentHome extends StatefulWidget {
  const PaymentHome({super.key});

  @override
  State<PaymentHome> createState() => _PaymentHomeState();
}

class _PaymentRow {
  const _PaymentRow({
    required this.receiver,
    required this.amount,
    required this.status,
    required this.time,
  });

  final String receiver;
  final String amount;
  final String status;
  final DateTime time;
}

class _PaymentHomeState extends State<PaymentHome> {
  final _sender = TextEditingController(text: 'alice@bank');
  final _receiver = TextEditingController();
  final _amount = TextEditingController();
  final _ble = BlEService();
  final _peripheral = PeripheralService();
  final _crypto = PaymentCryptoService();
  final _auditStore = AuditStore();
  final _serverKeyStore = ServerKeyStore();
  late final PaymentCoordinator _coordinator;
  final List<_PaymentRow> _payments = [];
  String _meshStatus = 'Starting Bluetooth payment mesh…';
  bool _busy = false;
  bool _supported = false;
  String _serverPublicKey = _buildServerPublicKey;

  @override
  void initState() {
    super.initState();
    _coordinator =
        PaymentCoordinator(
            ble: _ble,
            peripheral: _peripheral,
            crypto: _crypto,
            gateway: DummyPaymentGateway(),
            audit: _auditStore,
          )
          ..onStatus = (status) {
            if (mounted) setState(() => _meshStatus = status);
          };
    unawaited(_initialize());
    unawaited(_loadServerPublicKey());
  }

  Future<void> _loadServerPublicKey() async {
    try {
      final saved = await _serverKeyStore.load();
      if (mounted && saved != null && saved.isNotEmpty) {
        setState(() => _serverPublicKey = saved);
      }
    } catch (_) {
      // The build-time key remains available if native preferences are unavailable.
    }
  }

  Future<void> _configureServerKey() async {
    final controller = TextEditingController(text: _serverPublicKey);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Bank server public key'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Paste Base64 X.509 RSA public key',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save key'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    try {
      await _serverKeyStore.save(value);
      if (mounted) setState(() => _serverPublicKey = value);
      if (mounted) _showMessage('Public key saved on this phone.');
    } catch (error) {
      if (mounted) _showMessage('Invalid RSA public key: $error');
    }
  }

  Future<void> _initialize() async {
    final permissionsGranted = await PermissionService.requestPermissions();
    if (!permissionsGranted) {
      if (mounted) {
        setState(() => _meshStatus = 'Bluetooth permissions are required');
      }
      return;
    }
    _supported = await _ble.isDeviceSupported();
    if (!_supported) {
      if (mounted) {
        setState(() => _meshStatus = 'Bluetooth LE is not supported');
      }
      return;
    }
    try {
      await _coordinator.start();
    } catch (error) {
      if (mounted) setState(() => _meshStatus = 'Mesh startup failed: $error');
    }
  }

  Future<void> _sendPayment() async {
    final senderVpa = _sender.text.trim();
    final receiverVpa = _receiver.text.trim();
    final amount = double.tryParse(_amount.text.trim());
    if (senderVpa.isEmpty ||
        receiverVpa.isEmpty ||
        amount == null ||
        amount <= 0) {
      _showMessage('Enter valid sender, receiver, and amount.');
      return;
    }
    if (_serverPublicKey.isEmpty) {
      _showMessage(
        'Configure SERVER_PUBLIC_KEY_BASE64 to encrypt for the bank server.',
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final instruction = PaymentInstruction(
        senderVpa: senderVpa,
        receiverVpa: receiverVpa,
        amount: amount.toStringAsFixed(2),
      );
      final ciphertext = await _crypto.encryptInstruction(
        instructionJson: instruction.encode(),
        serverPublicKeyBase64: _serverPublicKey,
      );
      final result = await _coordinator.submitPayment(
        MeshPacket.create(ciphertext),
      );
      if (!mounted) return;
      setState(() {
        _payments.insert(
          0,
          _PaymentRow(
            receiver: receiverVpa,
            amount: amount.toStringAsFixed(2),
            status: result == null
                ? 'Queued on mesh'
                : result.accepted
                ? (result.message.startsWith('Demo')
                      ? 'Demo accepted'
                      : 'Settled')
                : result.retryable
                ? 'Pending retry'
                : 'Rejected',
            time: DateTime.now(),
          ),
        );
        _receiver.clear();
        _amount.clear();
      });
    } catch (error) {
      _showMessage('Could not create payment packet: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    unawaited(_coordinator.stop());
    _sender.dispose();
    _receiver.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xfff4f7fb),
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet_rounded),
            SizedBox(width: 10),
            Text('BluePay'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Configure server public key',
            onPressed: _configureServerKey,
            icon: Icon(_serverPublicKey.isEmpty ? Icons.key_off : Icons.key),
          ),
          IconButton(
            tooltip: 'Payload history',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AuditScreen(store: _auditStore),
              ),
            ),
            icon: const Icon(Icons.history),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          children: [
            Card(
              color: const Color(0xff153d7a),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'BLUETOOTH PAYMENT MESH',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Send securely, even offline',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.bluetooth_connected,
                          color: _supported
                              ? Colors.lightGreenAccent
                              : Colors.orangeAccent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _meshStatus,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Send money',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _sender,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Your VPA',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _receiver,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Pay to UPI ID',
                        hintText: 'name@bank',
                        prefixIcon: Icon(Icons.alternate_email),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        prefixText: '₹ ',
                        prefixIcon: Icon(Icons.currency_rupee),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _sendPayment,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_outline),
                        label: Text(
                          _busy ? 'Preparing secure payment…' : 'Pay securely',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Prototype only · payment packets are encrypted for the configured server. No real money is moved.',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent activity',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text('${_payments.length}'),
              ],
            ),
            const SizedBox(height: 10),
            if (_payments.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(22),
                  child: Center(
                    child: Text('Your payment activity will appear here.'),
                  ),
                ),
              )
            else
              ..._payments.map(
                (payment) => Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.arrow_upward_rounded),
                    ),
                    title: Text(payment.receiver),
                    subtitle: Text(
                      '${payment.status} · ${TimeOfDay.fromDateTime(payment.time).format(context)}',
                    ),
                    trailing: Text(
                      '₹${payment.amount}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
