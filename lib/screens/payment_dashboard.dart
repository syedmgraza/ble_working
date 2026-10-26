import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../audit/audit_store.dart';
import '../bank/account_store.dart';
import '../bank/bank_server_api.dart';
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

const _skyBlue = Color(0xff35a9e8);
const _ink = Color(0xff142b3b);

class PaymentDashboard extends StatefulWidget {
  const PaymentDashboard({
    super.key,
    required this.account,
    required this.api,
    required this.store,
    required this.onAccountChanged,
    required this.onSignOut,
  });
  final Map<String, dynamic> account;
  final BankServerApi api;
  final AccountStore store;
  final ValueChanged<Map<String, dynamic>> onAccountChanged;
  final VoidCallback onSignOut;
  @override
  State<PaymentDashboard> createState() => _PaymentDashboardState();
}

class _PaymentDashboardState extends State<PaymentDashboard>
    with WidgetsBindingObserver {
  final _receiver = TextEditingController();
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  final _ble = BlEService();
  final _peripheral = PeripheralService();
  final _crypto = PaymentCryptoService();
  final _audit = AuditStore();
  late final PaymentCoordinator _coordinator;
  late Map<String, dynamic> _profile;
  late Map<String, double> _pendingDebits;
  late Map<String, Map<String, dynamic>> _pendingPayments;
  final Set<String> _queuedInCoordinator = <String>{};
  String? _serverKey;
  String _meshStatus = 'Starting nearby Bluetooth…';
  String? _error;
  bool _busy = false;
  bool _resumingPending = false;
  bool _meshSupported = false;
  int _tab = 0;
  List<Map<String, dynamic>> _transactions = const [];

  double get _offlineBalance =>
      (_number(_profile['offlineBalance']) -
              _pendingDebits.values.fold<double>(
                0,
                (sum, value) => sum + value,
              ))
          .clamp(0, double.infinity);
  String get _identifier =>
      (_profile['vpa'] ?? _profile['identifier'] ?? _profile['accountNumber'])
          .toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profile = Map<String, dynamic>.from(widget.account);
    final savedDebits = widget.account['pendingDebits'];
    _pendingDebits = savedDebits is Map
        ? savedDebits.map(
            (key, value) => MapEntry(key.toString(), _number(value)),
          )
        : <String, double>{};
    final savedPayments = widget.account['pendingPayments'];
    _pendingPayments = savedPayments is Map
        ? savedPayments.map(
            (key, value) => MapEntry(
              key.toString(),
              Map<String, dynamic>.from(value as Map),
            ),
          )
        : <String, Map<String, dynamic>>{};
    _coordinator =
        PaymentCoordinator(
            ble: _ble,
            peripheral: _peripheral,
            crypto: _crypto,
            gateway: BankPaymentGateway(),
            audit: _audit,
          )
          ..onStatus = (status) {
            if (mounted) setState(() => _meshStatus = status);
          };
    unawaited(_initialize());
    unawaited(_loadKey());
    unawaited(_refreshTransactions());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshProfile());
      unawaited(_resumePendingPayments());
    }
  }

  double _number(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  String _rupees(Object? amount) => '₹${_number(amount).toStringAsFixed(2)}';

  Future<void> _initialize() async {
    try {
      if (!await PermissionService.requestPermissions()) {
        if (mounted)
          setState(() => _meshStatus = 'Bluetooth permissions are required');
        return;
      }
      _meshSupported = await _ble.isDeviceSupported();
      if (!_meshSupported) {
        if (mounted)
          setState(() => _meshStatus = 'Bluetooth LE is not supported');
        return;
      }
      await _coordinator.start();
      unawaited(_resumePendingPayments());
    } catch (error) {
      if (mounted)
        setState(() => _meshStatus = 'Bluetooth startup failed: $error');
    }
  }

  Future<void> _loadKey() async {
    try {
      final saved = await ServerKeyStore().load();
      if (saved != null && saved.isNotEmpty) {
        _serverKey = saved;
        if (mounted) setState(() {});
      }
      unawaited(widget.api.health().catchError((_) => <String, dynamic>{}));
      final body = await widget.api.fetchServerKey();
      final remote = body['publicKey']?.toString();
      if (remote != null && remote.isNotEmpty) {
        await ServerKeyStore().save(remote);
        _serverKey = remote;
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Saved key is used when the phone is offline or the host is asleep.
    }
  }

  Future<void> _refreshProfile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fresh = await widget.api.profile(_identifier);
      _profile = {..._profile, ...fresh, 'identifier': _identifier};
      _profile['pendingDebits'] = _pendingDebits;
      _profile['pendingPayments'] = _pendingPayments;
      await widget.store.save(_profile.cast<String, Object?>());
      widget.onAccountChanged(_profile);
      await _refreshTransactions();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshTransactions() async {
    try {
      final rows = await widget.api.transactions(_identifier);
      final completedHashes = rows
          .map((row) => row['packetHash']?.toString())
          .whereType<String>()
          .toSet();
      final changed = _pendingDebits.keys.any(completedHashes.contains);
      if (changed) {
        _pendingDebits.removeWhere((hash, _) => completedHashes.contains(hash));
        _pendingPayments.removeWhere(
          (hash, _) => completedHashes.contains(hash),
        );
        _queuedInCoordinator.removeWhere(completedHashes.contains);
        _profile['pendingDebits'] = _pendingDebits;
        _profile['pendingPayments'] = _pendingPayments;
        await widget.store.save(_profile.cast<String, Object?>());
      }
      if (mounted) setState(() => _transactions = rows);
    } catch (_) {
      /* passbook is available when online */
    }
  }

  Future<void> _sendPayment() async {
    final recipient = _receiver.text.trim();
    final amount = double.tryParse(_amount.text.trim());
    final pin = _pin.text;
    if (recipient.isEmpty || amount == null || amount <= 0) {
      _message('Enter a valid recipient and amount.');
      return;
    }
    if (pin.length < 4) {
      _message('Enter your payment PIN.');
      return;
    }
    if (amount > _offlineBalance) {
      _message(
        'Your offline wallet has only ${_rupees(_offlineBalance)}. Recharge while online.',
      );
      return;
    }
    if ((_serverKey ?? '').isEmpty) {
      _message(
        'The bank public key is not saved yet. Connect to the internet once, then retry.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final instruction = PaymentInstruction(
        senderVpa: _identifier,
        receiverVpa: recipient,
        amount: amount.toStringAsFixed(2),
        pinHash: await widget.store.sha256Hex(pin),
      );
      final ciphertext = await _crypto.encryptInstruction(
        instructionJson: instruction.encode(),
        serverPublicKeyBase64: _serverKey!,
      );
      final packet = MeshPacket.create(ciphertext);
      final packetHash = await widget.store.sha256Hex(ciphertext);
      final result = await _coordinator.submitPayment(packet);
      if (result == null || result.retryable) {
        _queuedInCoordinator.add(packetHash);
        _pendingDebits[packetHash] = amount;
        _pendingPayments[packetHash] = {
          'packet': jsonDecode(packet.toJson()),
          'amount': amount,
        };
        _profile['pendingDebits'] = _pendingDebits;
        _profile['pendingPayments'] = _pendingPayments;
        await widget.store.save(_profile.cast<String, Object?>());
        widget.onAccountChanged(_profile);
      }
      if (result?.accepted == true) {
        await _refreshProfile();
        _message(result!.message);
      } else if (result == null || result.retryable) {
        _message(
          'Payment queued. ${_rupees(amount)} reserved from your offline wallet.',
        );
      } else {
        _pendingDebits.remove(packetHash);
        _pendingPayments.remove(packetHash);
        _profile['pendingDebits'] = _pendingDebits;
        _profile['pendingPayments'] = _pendingPayments;
        await widget.store.save(_profile.cast<String, Object?>());
        _message('Payment rejected: ${result.message}');
        await _refreshProfile();
      }
      _receiver.clear();
      _amount.clear();
      _pin.clear();
      await _refreshTransactions();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _message('Could not prepare payment: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resumePendingPayments() async {
    if (!_coordinator.isRunning ||
        _pendingPayments.isEmpty ||
        _busy ||
        _resumingPending) {
      return;
    }
    _resumingPending = true;
    try {
      for (final entry in _pendingPayments.entries.toList()) {
        if (_queuedInCoordinator.contains(entry.key)) continue;
        try {
          final packet = MeshPacket.fromJson(jsonEncode(entry.value['packet']));
          final result = await _coordinator.submitPayment(packet);
          if (result == null || result.retryable) {
            _queuedInCoordinator.add(entry.key);
          }
          if (result?.accepted == true ||
              (result != null && !result.retryable)) {
            _queuedInCoordinator.remove(entry.key);
            _pendingPayments.remove(entry.key);
            _pendingDebits.remove(entry.key);
            _profile['pendingPayments'] = _pendingPayments;
            _profile['pendingDebits'] = _pendingDebits;
            await widget.store.save(_profile.cast<String, Object?>());
            if (result?.accepted == true) await _refreshProfile();
          }
        } catch (_) {
          // Keep the encrypted packet for the next retry opportunity.
        }
      }
    } finally {
      _resumingPending = false;
    }
  }

  Future<void> _recharge() async {
    final values = await showDialog<(String, String)>(
      context: context,
      builder: (_) =>
          _RechargeDialog(onlineBalance: _rupees(_profile['balance'])),
    );
    if (values == null) return;
    final amount = double.tryParse(values.$1);
    if (amount == null || amount <= 0 || values.$2.length < 4) {
      _message('Enter a valid amount and PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.recharge(
        identifier: _identifier,
        amount: amount,
        pin: values.$2,
      );
      await _refreshProfile();
      _message('Offline wallet recharged.');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_coordinator.stop());
    _receiver.dispose();
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff3f9fc),
    appBar: AppBar(
      backgroundColor: const Color(0xfff3f9fc),
      title: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: _skyBlue,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: Colors.white,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'BluePay',
            style: TextStyle(fontWeight: FontWeight.w800, color: _ink),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh balances',
          onPressed: _busy ? null : _refreshProfile,
          icon: const Icon(Icons.refresh_rounded),
        ),
        IconButton(
          tooltip: 'Payload history',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => AuditScreen(store: _audit)),
          ),
          icon: const Icon(Icons.history),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'signout') widget.onSignOut();
            if (v == 'audit')
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => AuditScreen(store: _audit),
                ),
              );
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'audit', child: Text('Mesh payload history')),
            PopupMenuItem(value: 'signout', child: Text('Sign out')),
          ],
        ),
      ],
    ),
    body: _tab == 2
        ? _profileTab()
        : _tab == 1
        ? _activityTab()
        : _homeTab(),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (value) => setState(() => _tab = value),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long),
          label: 'Activity',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    ),
  );

  Widget _homeTab() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
    children: [
      Text(
        'Hello, ${_profile['holderName'] ?? _profile['name'] ?? 'there'}',
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w700,
          color: _ink,
        ),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [_skyBlue, Color(0xff168bd0)]),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'OFFLINE WALLET',
              style: TextStyle(
                color: Colors.white70,
                letterSpacing: 1.2,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _rupees(_offlineBalance),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Online balance  ${_rupees(_profile['balance'])}',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _recharge,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: _ink,
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add money'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Use offline wallet for mesh payments',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Card(
        color: Colors.white,
        child: ListTile(
          leading: Icon(
            Icons.bluetooth_connected,
            color: _meshSupported ? Colors.green.shade700 : Colors.red.shade700,
          ),
          title: const Text('Nearby payments'),
          subtitle: Text(
            _meshStatus,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      const SizedBox(height: 14),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pay anyone',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              _input(_receiver, 'UPI ID / VPA', Icons.alternate_email),
              const SizedBox(height: 11),
              _input(
                _amount,
                'Amount',
                Icons.currency_rupee,
                keyboard: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 11),
              _input(
                _pin,
                'Payment PIN',
                Icons.lock_outline,
                keyboard: TextInputType.number,
                secret: true,
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _sendPayment,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                  label: Text(_busy ? 'Processing…' : 'Pay securely'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Payments are encrypted and relayed by nearby BluePay phones when you are offline.',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      const SizedBox(height: 12),
      const Text(
        'Recent bank activity',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      ..._transactions.take(3).map(_transactionTile),
    ],
  );

  Widget _input(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    bool secret = false,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    obscureText: secret,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: const OutlineInputBorder(),
      filled: true,
      fillColor: const Color(0xfffbfdff),
    ),
  );

  Widget _activityTab() => RefreshIndicator(
    onRefresh: _refreshTransactions,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Passbook',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
        const SizedBox(height: 12),
        if (_transactions.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No transactions found. Connect to the internet to refresh your passbook.',
              ),
            ),
          )
        else
          ..._transactions.map(_transactionTile),
      ],
    ),
  );

  Widget _transactionTile(Map<String, dynamic> row) {
    final outgoing = row['senderVpa']?.toString() == _identifier;
    final status = (row['status'] ?? 'UNKNOWN').toString();
    final color = status == 'SETTLED'
        ? Colors.green.shade700
        : status == 'REJECTED'
        ? Colors.red.shade700
        : Colors.black54;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: .10),
          child: Icon(
            outgoing ? Icons.arrow_upward : Icons.arrow_downward,
            color: color,
          ),
        ),
        title: Text(
          outgoing
              ? 'To ${row['receiverVpa'] ?? 'recipient'}'
              : 'From ${row['senderVpa'] ?? 'sender'}',
        ),
        subtitle: Text(
          '${status}${row['failureReason'] == null ? '' : ' · ${row['failureReason']}'}',
        ),
        trailing: Text(
          _rupees(row['amount']),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _profileTab() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Your account',
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: _ink,
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.person, color: _skyBlue),
              title: Text(
                (_profile['holderName'] ?? 'BluePay user').toString(),
              ),
              subtitle: Text(_identifier),
            ),
            ListTile(
              leading: const Icon(Icons.credit_card, color: _skyBlue),
              title: const Text('Account number'),
              subtitle: Text('${_profile['accountNumber'] ?? '—'}'),
            ),
            ListTile(
              leading: const Icon(
                Icons.account_balance_wallet,
                color: _skyBlue,
              ),
              title: const Text('Offline wallet'),
              trailing: Text(_rupees(_offlineBalance)),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance, color: _skyBlue),
              title: const Text('Online balance'),
              trailing: Text(_rupees(_profile['balance'])),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy ? null : _refreshProfile,
        icon: const Icon(Icons.sync),
        label: const Text('Sync account with bank'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: widget.onSignOut,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out'),
      ),
    ],
  );
}

class _RechargeDialog extends StatefulWidget {
  const _RechargeDialog({required this.onlineBalance});
  final String onlineBalance;

  @override
  State<_RechargeDialog> createState() => _RechargeDialogState();
}

class _RechargeDialogState extends State<_RechargeDialog> {
  final _amountController = TextEditingController();
  final _pinController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add money to offline wallet'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Online balance: ${widget.onlineBalance}',
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '₹',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Bank PIN',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (
          _amountController.text,
          _pinController.text,
        )),
        child: const Text('Recharge'),
      ),
    ],
  );
}
