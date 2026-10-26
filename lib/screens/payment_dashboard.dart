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

class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xffe1f3fc),
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.account_balance_wallet_rounded,
          color: Color(0xff168bd0),
          size: 21,
        ),
      ),
      const SizedBox(width: 10),
      const Text(
        'BluePay',
        style: TextStyle(
          color: _ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -.35,
        ),
      ),
    ],
  );
}

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
    backgroundColor: const Color(0xfff5f9fc),
    appBar: AppBar(
      backgroundColor: const Color(0xfff5f9fc),
      toolbarHeight: 70,
      titleSpacing: 20,
      title: const _BrandLockup(),
      actions: [
        IconButton(
          tooltip: 'Refresh balances',
          onPressed: _busy ? null : _refreshProfile,
          icon: const Icon(Icons.sync_rounded),
        ),
        IconButton(
          tooltip: 'Payload history',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => AuditScreen(store: _audit)),
          ),
          icon: const Icon(Icons.receipt_long_outlined),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 18, left: 4),
          child: PopupMenuButton<String>(
            tooltip: 'Account options',
            onSelected: (v) {
              if (v == 'signout') widget.onSignOut();
              if (v == 'audit') {
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AuditScreen(store: _audit),
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'audit', child: Text('Mesh packet history')),
              PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
            child: CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xffdff1fb),
              child: Text(
                ((_profile['holderName'] ?? 'B').toString().trim().isEmpty
                        ? 'B'
                        : (_profile['holderName'] ?? 'B').toString().trim()[0])
                    .toUpperCase(),
                style: const TextStyle(
                  color: Color(0xff168bd0),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
    body: AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: _tab == 2
          ? _profileTab(key: const ValueKey('profile'))
          : _tab == 1
          ? _activityTab(key: const ValueKey('activity'))
          : _homeTab(key: const ValueKey('home')),
    ),
    bottomNavigationBar: NavigationBar(
      height: 72,
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

  Widget _homeTab({Key? key}) => LayoutBuilder(
    key: key,
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      final horizontalPadding = constraints.maxWidth < 420 ? 18.0 : 30.0;
      final summary = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide) ...[_welcomeHeader(), const SizedBox(height: 16)],
          _walletCard(),
          const SizedBox(height: 16),
          _meshCard(),
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Recent activity',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _tab = 1),
                child: const Text('View all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_transactions.isEmpty)
            _emptyActivity()
          else
            ..._transactions.take(wide ? 5 : 3).map(_transactionTile),
        ],
      );
      final payment = _paymentCard();
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          18,
          horizontalPadding,
          32,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: summary),
                      const SizedBox(width: 24),
                      Expanded(flex: 9, child: payment),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _welcomeHeader(),
                      const SizedBox(height: 18),
                      summary,
                      const SizedBox(height: 22),
                      payment,
                    ],
                  ),
          ),
        ),
      );
    },
  );

  Widget _welcomeHeader() => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Good ${_greeting()}, ${_firstName()}',
                style: const TextStyle(
                  color: _ink,
                  fontSize: 23,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.25,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Here’s your wallet at a glance.',
                style: TextStyle(color: Color(0xff718491), fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _firstName() {
    final name = (_profile['holderName'] ?? 'there').toString().trim();
    return name.isEmpty ? 'there' : name.split(RegExp(r'\s+')).first;
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'morning';
    if (hour < 17) return 'afternoon';
    return 'evening';
  }

  Widget _walletCard() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff38afe9), Color(0xff147fbd)],
      ),
      borderRadius: BorderRadius.circular(22),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1a167caf),
          blurRadius: 20,
          offset: Offset(0, 9),
        ),
      ],
    ),
    child: Stack(
      children: [
        Positioned(
          right: 12,
          top: 10,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: .10),
                width: 13,
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'OFFLINE WALLET',
                    style: TextStyle(
                      color: Color(0xffd8f0fc),
                      fontSize: 11,
                      letterSpacing: 1.25,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.wifi_off_rounded,
                  color: Colors.white.withValues(alpha: .85),
                  size: 19,
                ),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _rupees(_offlineBalance),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.7,
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              'Available for secure nearby payments',
              style: TextStyle(
                color: Colors.white.withValues(alpha: .85),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 22),
            Divider(color: Colors.white.withValues(alpha: .22), height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Online balance',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .75),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _rupees(_profile['balance']),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _recharge,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xff116d9f),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 12,
                    ),
                    minimumSize: const Size(0, 44),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 19),
                  label: const Text('Add money'),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  );

  Widget _meshCard() {
    final connected = _meshStatus.toLowerCase().contains('active');
    final color = connected ? const Color(0xff238a62) : const Color(0xffb17a23);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffe5edf2)),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.bluetooth_connected_rounded,
              color: color,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bluetooth mesh',
                  style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _meshStatus,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xff718491),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ],
      ),
    );
  }

  Widget _paymentCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xffe5f5fc),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.north_east_rounded,
                  color: Color(0xff168bd0),
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Send money',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Pay by UPI ID or VPA',
                      style: TextStyle(color: Color(0xff718491), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _input(
            _receiver,
            'Recipient UPI ID',
            Icons.alternate_email,
            hint: 'name@bank',
          ),
          const SizedBox(height: 14),
          _input(
            _amount,
            'Amount',
            Icons.currency_rupee_rounded,
            keyboard: const TextInputType.numberWithOptions(decimal: true),
            prefixText: '₹ ',
          ),
          const SizedBox(height: 14),
          _input(
            _pin,
            'Payment PIN',
            Icons.lock_outline_rounded,
            keyboard: TextInputType.number,
            secret: true,
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 54,
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
                  : const Icon(Icons.arrow_forward_rounded, size: 19),
              label: Text(
                _busy ? 'Preparing secure payment…' : 'Review and pay',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 15),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.shield_outlined, size: 16, color: Color(0xff718491)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Encrypted for the bank. If you are offline, nearby BluePay devices can relay the payment.',
                  style: TextStyle(
                    color: Color(0xff718491),
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _emptyActivity() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe5edf2)),
      borderRadius: BorderRadius.circular(17),
    ),
    child: const Row(
      children: [
        Icon(Icons.receipt_long_outlined, color: Color(0xff91a1ab)),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'Your bank transactions will appear here.',
            style: TextStyle(color: Color(0xff718491), fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _input(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
    bool secret = false,
    String? hint,
    String? prefixText,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    obscureText: secret,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon),
      prefixText: prefixText,
    ),
  );

  Widget _activityTab({Key? key}) => RefreshIndicator(
    key: key,
    onRefresh: _refreshTransactions,
    child: LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: constraints.maxWidth < 420 ? 18 : 30,
          vertical: 24,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Activity',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                      letterSpacing: -.4,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Your payments and their latest bank status.',
                    style: TextStyle(color: Color(0xff718491), fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  if (_transactions.isEmpty)
                    _emptyActivity()
                  else
                    ..._transactions.map(_transactionTile),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _transactionTile(Map<String, dynamic> row) {
    final outgoing = row['senderVpa']?.toString() == _identifier;
    final status = (row['status'] ?? 'UNKNOWN').toString();
    final color = status == 'SETTLED'
        ? Colors.green.shade700
        : status == 'REJECTED'
        ? Colors.red.shade700
        : const Color(0xffa06b18);
    final signedAmount = '${outgoing ? '−' : '+'}${_rupees(row['amount'])}';
    final dateValue = row['settledAt'] ?? row['signedAt'];
    final parsedDate = dateValue == null
        ? null
        : DateTime.tryParse('$dateValue');
    final dateLabel = parsedDate == null
        ? 'Bank transaction'
        : '${parsedDate.day.toString().padLeft(2, '0')}/${parsedDate.month.toString().padLeft(2, '0')}/${parsedDate.year}';
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        leading: CircleAvatar(
          radius: 21,
          backgroundColor: color.withValues(alpha: .09),
          child: Icon(
            outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
            color: color,
            size: 19,
          ),
        ),
        title: Text(
          outgoing
              ? 'To ${row['receiverVpa'] ?? 'recipient'}'
              : 'From ${row['senderVpa'] ?? 'sender'}',
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  dateLabel,
                  style: const TextStyle(
                    color: Color(0xff84939d),
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 9),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .25,
                  ),
                ),
              ),
            ],
          ),
        ),
        trailing: Text(
          signedAmount,
          style: TextStyle(
            color: outgoing ? _ink : const Color(0xff238a62),
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _profileTab({Key? key}) => LayoutBuilder(
    key: key,
    builder: (context, constraints) => SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: constraints.maxWidth < 420 ? 18 : 30,
        vertical: 24,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Profile',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                  letterSpacing: -.4,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Your BluePay account details.',
                style: TextStyle(color: Color(0xff718491), fontSize: 14),
              ),
              const SizedBox(height: 22),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: const Color(0xffe1f3fc),
                        child: Text(
                          _firstName().isEmpty
                              ? 'B'
                              : _firstName()[0].toUpperCase(),
                          style: const TextStyle(
                            color: Color(0xff168bd0),
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (_profile['holderName'] ?? 'BluePay user')
                                  .toString(),
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _identifier,
                              style: const TextStyle(
                                color: Color(0xff718491),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.verified_user_outlined,
                        color: Color(0xff238a62),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, size) {
                  final wide = size.maxWidth > 540;
                  final offline = _accountBalanceCard(
                    'Offline wallet',
                    _rupees(_offlineBalance),
                    Icons.wifi_off_rounded,
                    const Color(0xff168bd0),
                  );
                  final online = _accountBalanceCard(
                    'Online balance',
                    _rupees(_profile['balance']),
                    Icons.account_balance_outlined,
                    const Color(0xff238a62),
                  );
                  return wide
                      ? Row(
                          children: [
                            Expanded(child: offline),
                            const SizedBox(width: 14),
                            Expanded(child: online),
                          ],
                        )
                      : Column(
                          children: [
                            offline,
                            const SizedBox(height: 12),
                            online,
                          ],
                        );
                },
              ),
              const SizedBox(height: 14),
              Card(
                child: Column(
                  children: [
                    _profileDetail(
                      Icons.credit_card_outlined,
                      'Account number',
                      '${_profile['accountNumber'] ?? '—'}',
                    ),
                    const Divider(height: 1, indent: 58, endIndent: 18),
                    _profileDetail(
                      Icons.alternate_email_rounded,
                      'Payment address',
                      _identifier,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _busy ? null : _refreshProfile,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                label: const Text('Sync with bank'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: widget.onSignOut,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xffad4141),
                ),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _accountBalanceCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .09),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xff718491),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _profileDetail(IconData icon, String label, String value) => ListTile(
    leading: Icon(icon, color: const Color(0xff6e8795), size: 21),
    title: Text(
      label,
      style: const TextStyle(color: Color(0xff718491), fontSize: 12),
    ),
    subtitle: Text(
      value,
      style: const TextStyle(
        color: _ink,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
    ),
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
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
    contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
    actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    title: const Row(
      children: [
        CircleAvatar(
          backgroundColor: Color(0xffe1f3fc),
          foregroundColor: Color(0xff168bd0),
          child: Icon(Icons.add_card_rounded),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            'Add money',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xfff0f8fc),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_balance_outlined,
                  size: 18,
                  color: Color(0xff718491),
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    'Online balance',
                    style: TextStyle(color: Color(0xff718491), fontSize: 13),
                  ),
                ),
                Text(
                  widget.onlineBalance,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '₹',
              prefixIcon: Icon(Icons.currency_rupee_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Bank PIN',
              prefixIcon: Icon(Icons.lock_outline_rounded),
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
