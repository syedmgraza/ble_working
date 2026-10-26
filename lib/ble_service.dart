import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'mesh_packet.dart';
import 'peripheral_service.dart';

class _Peer {
  const _Peer(this.device, this.characteristic, this.connectionSubscription);
  final BluetoothDevice device;
  final BluetoothCharacteristic characteristic;
  final StreamSubscription<BluetoothConnectionState> connectionSubscription;
}

/// Foreground Android BLE discovery and app-level packet forwarding.
class BlEService {
  final Map<String, _Peer> _peers = {};
  final Set<String> _connecting = {};
  StreamSubscription<List<ScanResult>>? _scanResults;
  bool _running = false;
  String? lastError;
  void Function(int count)? onPeerCountChanged;
  void Function(MeshPacket packet, String peerDeviceId)? onPacketSent;

  int get connectedPeerCount => _peers.length;

  Future<bool> isDeviceSupported() => FlutterBluePlus.isSupported;

  Future<void> startAutoDiscovery() async {
    if (_running) return;
    _running = true;
    _scanResults ??= FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        if (result.advertisementData.serviceUuids.any(
          (uuid) =>
              uuid.toString().toLowerCase() ==
              PeripheralService.serviceUUID.toLowerCase(),
        )) {
          unawaited(_connect(result.device));
        }
      }
    }, onError: (Object error) => lastError = error.toString());
    unawaited(_scanLoop());
  }

  Future<void> _scanLoop() async {
    while (_running) {
      try {
        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState != BluetoothAdapterState.on) {
          lastError = 'Bluetooth is turned off';
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        await FlutterBluePlus.startScan(
          withServices: [Guid(PeripheralService.serviceUUID)],
          timeout: const Duration(seconds: 15),
        );
        await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
      } catch (error) {
        lastError = error.toString();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    final id = device.remoteId.toString();
    if (_peers.containsKey(id) || !_connecting.add(id)) return;
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 12),
      );
      try {
        await device.requestMtu(247);
      } catch (_) {
        // The negotiated default MTU is still supported by the frame codec.
      }
      final services = await device.discoverServices();
      BluetoothCharacteristic? characteristic;
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() !=
            PeripheralService.serviceUUID.toLowerCase()) {
          continue;
        }
        for (final candidate in service.characteristics) {
          if (candidate.uuid.toString().toLowerCase() ==
              PeripheralService.characteristicUUID.toLowerCase()) {
            characteristic = candidate;
            break;
          }
        }
      }
      if (characteristic == null) {
        await device.disconnect();
        return;
      }
      late final StreamSubscription<BluetoothConnectionState>
      connectionSubscription;
      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _peers.remove(id);
          unawaited(connectionSubscription.cancel());
          onPeerCountChanged?.call(_peers.length);
        }
      });
      _peers[id] = _Peer(device, characteristic, connectionSubscription);
      onPeerCountChanged?.call(_peers.length);
    } catch (error) {
      lastError = error.toString();
      try {
        await device.disconnect();
      } catch (_) {}
    } finally {
      _connecting.remove(id);
    }
  }

  Future<int> broadcastPacket(MeshPacket packet) async {
    if (packet.ttl <= 0) return 0;
    final bytes = packet.toJson().codeUnits;
    var sent = 0;
    for (final peer in _peers.values.toList()) {
      try {
        final maxFrameBytes = math.max(20, peer.device.mtuNow - 3).toInt();
        final frames = _encodeFrames(bytes, maxFrameBytes);
        for (final frame in frames) {
          await peer.characteristic.write(frame);
        }
        sent++;
        onPacketSent?.call(packet, peer.device.remoteId.toString());
      } catch (error) {
        lastError = error.toString();
      }
    }
    return sent;
  }

  List<List<int>> _encodeFrames(List<int> packet, int maxFrameBytes) {
    const headerBytes = 5;
    final chunkSize = maxFrameBytes - headerBytes;
    if (chunkSize <= 0) throw StateError('BLE MTU is too small.');
    final total = (packet.length / chunkSize).ceil();
    if (total > 0xffff) throw StateError('Payment packet exceeds BLE limit.');
    return List.generate(total, (index) {
      final start = index * chunkSize;
      final end = math.min(start + chunkSize, packet.length).toInt();
      return <int>[
        0xB1,
        (index >> 8) & 0xff,
        index & 0xff,
        (total >> 8) & 0xff,
        total & 0xff,
        ...packet.sublist(start, end),
      ];
    });
  }

  Future<void> stop() async {
    _running = false;
    await FlutterBluePlus.stopScan();
    await _scanResults?.cancel();
    _scanResults = null;
    for (final peer in _peers.values.toList()) {
      await peer.connectionSubscription.cancel();
      try {
        await peer.device.disconnect();
      } catch (_) {}
    }
    _peers.clear();
    onPeerCountChanged?.call(0);
  }
}
