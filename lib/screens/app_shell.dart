import 'dart:async';

import 'package:flutter/material.dart';

import '../bank/account_store.dart';
import '../bank/bank_server_api.dart';
import '../security/server_key_store.dart';
import 'payment_dashboard.dart';

const _sky = Color(0xff36a9e8);

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _api = BankServerApi();
  final _store = AccountStore();
  Map<String, dynamic>? _account;
  bool _splash = true;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final saved = await _store.load();
    if (!mounted) return;
    if (saved != null && (saved['identifier'] ?? saved['vpa']) != null) {
      setState(() {
        _account = saved;
        _splash = false;
      });
      unawaited(_syncSavedAccount(saved));
      unawaited(_refreshServerKey());
      return;
    }
    setState(() => _splash = false);
  }

  Future<void> _syncSavedAccount(Map<String, dynamic> saved) async {
    try {
      final profile = await _api.profile(
        (saved['identifier'] ?? saved['vpa']).toString(),
      );
      saved.addAll(profile);
      await _store.save(saved.cast<String, Object?>());
      if (mounted) setState(() => _account = saved);
    } catch (_) {
      // Previously saved profile remains available while offline.
    }
  }

  Future<void> _refreshServerKey([String? supplied]) async {
    try {
      unawaited(_api.health().catchError((_) => <String, dynamic>{}));
      final key =
          supplied ?? (await _api.fetchServerKey())['publicKey']?.toString();
      if (key != null && key.isNotEmpty) await ServerKeyStore().save(key);
    } catch (_) {
      // An already stored key allows offline packet creation.
    }
  }

  Future<void> _openAccount(Map<String, dynamic> account, {String? key}) async {
    final normalized = <String, Object?>{
      ...account,
      'identifier':
          (account['vpa'] ?? account['accountNumber'] ?? account['identifier'])
              .toString(),
      'offlineBalance': _money(account['offlineBalance']),
    };
    await _store.save(normalized);
    await _refreshServerKey(key);
    if (mounted) setState(() => _account = normalized);
  }

  Future<void> _persistAccount(Map<String, dynamic> account) async {
    final normalized = <String, Object?>{
      ...account,
      'identifier':
          (account['vpa'] ?? account['accountNumber'] ?? account['identifier'])
              .toString(),
    };
    await _store.save(normalized);
    if (mounted) setState(() => _account = normalized);
  }

  double _money(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  @override
  Widget build(BuildContext context) {
    if (_splash) return const _SplashScreen();
    final account = _account;
    if (account != null) {
      return PaymentDashboard(
        account: account,
        api: _api,
        store: _store,
        onAccountChanged: (updated) => unawaited(_persistAccount(updated)),
        onSignOut: () async {
          await _store.clear();
          if (mounted) setState(() => _account = null);
        },
      );
    }
    return _AccountEntry(api: _api, onAccountReady: _openAccount);
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _sky,
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: _sky,
              size: 48,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'BluePay',
            style: TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Payments, even when you are offline',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}

class _AccountEntry extends StatefulWidget {
  const _AccountEntry({required this.api, required this.onAccountReady});
  final BankServerApi api;
  final Future<void> Function(Map<String, dynamic>, {String? key})
  onAccountReady;
  @override
  State<_AccountEntry> createState() => _AccountEntryState();
}

class _AccountEntryState extends State<_AccountEntry> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _dob = TextEditingController();
  final _mobile = TextEditingController();
  final _email = TextEditingController();
  final _initialAmount = TextEditingController(text: '0');
  final _pin = TextEditingController();
  final _identifier = TextEditingController();
  bool _loading = false;
  bool _existing = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _address,
      _dob,
      _mobile,
      _email,
      _initialAmount,
      _pin,
      _identifier,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_existing && !(_formKey.currentState?.validate() ?? false)) return;
    if (_existing && _identifier.text.trim().isEmpty) {
      setState(() => _error = 'Enter your VPA or account number.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Map<String, dynamic> account;
      String? key;
      if (_existing) {
        account = await widget.api.profile(_identifier.text.trim());
      } else {
        account = await widget.api.register({
          'name': _name.text.trim(),
          'address': _address.text.trim(),
          'dob': _dob.text.trim(),
          'mobile': _mobile.text.trim(),
          'email': _email.text.trim(),
          'initialAmount': double.parse(_initialAmount.text),
          'pin': _pin.text,
        });
        key = account['serverPublicKey']?.toString();
      }
      await widget.onAccountReady(account, key: key);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboard,
    bool secret = false,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      keyboardType: keyboard,
      obscureText: secret,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff2f9fd),
    appBar: AppBar(
      title: const Text('Welcome to BluePay'),
      backgroundColor: Colors.transparent,
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Your account, your wallet',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            _existing
                ? 'Load your bank profile to continue.'
                : 'Create a bank account to start paying.',
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 20),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('New account')),
              ButtonSegment(value: true, label: Text('Existing account')),
            ],
            selected: {_existing},
            onSelectionChanged: (selection) => setState(() {
              _existing = selection.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 18),
          if (_existing)
            _field(
              _identifier,
              'VPA or account number',
              validator: (v) => (v?.trim().isEmpty ?? true)
                  ? 'Enter your account identifier'
                  : null,
            )
          else
            Form(
              key: _formKey,
              child: Column(
                children: [
                  _field(_name, 'Full name', validator: _required),
                  _field(_address, 'Address', validator: _required),
                  _field(
                    _dob,
                    'Date of birth (YYYY-MM-DD)',
                    validator: (v) => (v?.trim().isEmpty ?? true)
                        ? 'Enter date of birth'
                        : null,
                  ),
                  _field(
                    _mobile,
                    'Mobile number',
                    keyboard: TextInputType.phone,
                    validator: (v) => (v?.trim().length ?? 0) < 10
                        ? 'Enter a valid mobile number'
                        : null,
                  ),
                  _field(
                    _email,
                    'Email',
                    keyboard: TextInputType.emailAddress,
                    validator: _required,
                  ),
                  _field(
                    _initialAmount,
                    'Initial online balance (₹)',
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) => double.tryParse(v ?? '') == null
                        ? 'Enter a valid amount'
                        : null,
                  ),
                  _field(
                    _pin,
                    'Create 4-digit PIN',
                    keyboard: TextInputType.number,
                    secret: true,
                    validator: (v) => (v?.length ?? 0) < 4
                        ? 'PIN must have at least 4 digits'
                        : null,
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const CircularProgressIndicator()
                  : Text(_existing ? 'Continue' : 'Create account'),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Bank account actions require an internet connection. Payments can be prepared offline after your account and bank key are saved.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  String? _required(String? value) =>
      value?.trim().isEmpty ?? true ? 'Required' : null;
}
