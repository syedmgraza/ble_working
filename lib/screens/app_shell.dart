import 'dart:async';

import 'package:flutter/material.dart';

import '../bank/account_store.dart';
import '../bank/bank_server_api.dart';
import '../security/server_key_store.dart';
import 'payment_dashboard.dart';

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
    backgroundColor: const Color(0xfff5f9fc),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(25),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14168bd0),
                  blurRadius: 25,
                  offset: Offset(0, 9),
                ),
              ],
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: Color(0xff168bd0),
              size: 38,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'BluePay',
            style: TextStyle(
              color: Color(0xff142b3b),
              fontSize: 30,
              letterSpacing: -.6,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Payments that keep moving',
            style: TextStyle(color: Color(0xff718491), fontSize: 14),
          ),
          const SizedBox(height: 30),
          const SizedBox(
            width: 76,
            child: LinearProgressIndicator(
              minHeight: 3,
              borderRadius: BorderRadius.all(Radius.circular(3)),
              color: Color(0xff35a9e8),
              backgroundColor: Color(0xffdcecf5),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EntryBenefit extends StatelessWidget {
  const _EntryBenefit({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: const Color(0xff168bd0), size: 21),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color(0xff142b3b),
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: Color(0xff627582),
                height: 1.4,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    ],
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
  }) {
    final icon = switch (label) {
      'Full name' => Icons.person_outline_rounded,
      'Address' => Icons.location_on_outlined,
      'Date of birth (YYYY-MM-DD)' => Icons.calendar_month_outlined,
      'Mobile number' => Icons.phone_outlined,
      'Email address' => Icons.alternate_email_rounded,
      'Opening balance (₹)' => Icons.account_balance_wallet_outlined,
      'Create your 4-digit PIN' => Icons.lock_outline_rounded,
      _ => Icons.account_circle_outlined,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        obscureText: secret,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, size: 20),
          fillColor: Colors.white,
        ),
      ),
    );
  }

  Widget _accountForm() => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
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
          const SizedBox(height: 24),
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
                    'Email address',
                    keyboard: TextInputType.emailAddress,
                    validator: _required,
                  ),
                  _field(
                    _initialAmount,
                    'Opening balance (₹)',
                    keyboard: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) => double.tryParse(v ?? '') == null
                        ? 'Enter a valid amount'
                        : null,
                  ),
                  _field(
                    _pin,
                    'Create your 4-digit PIN',
                    keyboard: TextInputType.number,
                    secret: true,
                    validator: (v) => (v?.length ?? 0) < 4
                        ? 'PIN must have at least 4 digits'
                        : null,
                  ),
                ],
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            height: 54,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_existing ? 'Continue to BluePay' : 'Create account'),
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 16, color: Color(0xff718491)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Account setup needs internet. Payments can be prepared offline after setup.',
                  style: TextStyle(color: Color(0xff718491), fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _entryIntro({required bool compact}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xffe1f3fc),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.account_balance_wallet_rounded,
              color: Color(0xff168bd0),
            ),
          ),
          const SizedBox(width: 11),
          const Text(
            'BluePay',
            style: TextStyle(
              color: Color(0xff142b3b),
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      SizedBox(height: compact ? 25 : 44),
      Text(
        _existing ? 'Welcome back.' : 'Your money,\nready when you are.',
        style: TextStyle(
          color: const Color(0xff142b3b),
          fontSize: compact ? 28 : 38,
          height: 1.13,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _existing
            ? 'Sign in with your account details to view your wallet and continue.'
            : 'Create your BluePay account and get your offline wallet ready for secure mesh payments.',
        style: const TextStyle(
          color: Color(0xff627582),
          fontSize: 15,
          height: 1.5,
        ),
      ),
      if (!compact) ...[
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xffe9f6fc),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EntryBenefit(
                icon: Icons.shield_outlined,
                title: 'Encrypted by design',
                subtitle: 'Your payment details stay protected in transit.',
              ),
              SizedBox(height: 18),
              _EntryBenefit(
                icon: Icons.bluetooth_connected,
                title: 'Works across the mesh',
                subtitle: 'Nearby BluePay phones can relay packets offline.',
              ),
            ],
          ),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 850;
          final horizontal = constraints.maxWidth < 420 ? 18.0 : 28.0;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: horizontal,
              vertical: wide ? 42 : 24,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _entryIntro(compact: false)),
                          const SizedBox(width: 54),
                          Expanded(child: _accountForm()),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _entryIntro(compact: true),
                          const SizedBox(height: 24),
                          _accountForm(),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    ),
  );

  String? _required(String? value) =>
      value?.trim().isEmpty ?? true ? 'Required' : null;
}
