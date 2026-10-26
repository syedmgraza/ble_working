import 'package:flutter/material.dart';

import '../audit/audit_store.dart';

class AuditScreen extends StatefulWidget {
  const AuditScreen({required this.store, super.key});

  final AuditStore store;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late Future<List<AuditRecord>> _records;

  @override
  void initState() {
    super.initState();
    _records = widget.store.load();
  }

  Future<void> _refresh() async {
    final records = widget.store.load();
    setState(() => _records = records);
    await records;
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear payload history?'),
        content: const Text(
          'This removes the saved demo records from this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.clear();
    await _refresh();
  }

  void _showRecord(AuditRecord record) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(record.direction),
        content: SingleChildScrollView(
          child: SelectableText(
            'Device ID\n${record.deviceId}\n\nStatus\n${record.status}'
            '\n\nTime\n${record.timestamp.toLocal()}\n\nEncrypted packet\n'
            '${record.packetJson}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payload history'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<AuditRecord>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load history: ${snapshot.error}'),
            );
          }
          final records = snapshot.data ?? const <AuditRecord>[];
          if (records.isEmpty) {
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 180),
                  Center(child: Text('No payloads recorded yet.')),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final record = records[index];
                final received = record.direction == 'BLE_RECEIVED';
                return ListTile(
                  onTap: () => _showRecord(record),
                  leading: CircleAvatar(
                    child: Icon(received ? Icons.south_west : Icons.north_east),
                  ),
                  title: Text(record.direction.replaceAll('_', ' ')),
                  subtitle: Text(
                    '${record.deviceId}\n${record.status}\n'
                    '${record.timestamp.toLocal()}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
