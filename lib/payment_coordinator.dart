import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';

import 'audit/audit_store.dart';
import 'ble_service.dart';
import 'bridge/payment_gateway.dart';
import 'mesh_packet.dart';
import 'peripheral_service.dart';
import 'security/payment_crypto_service.dart';

class PaymentCoordinator {
  PaymentCoordinator({
    required this.ble,
    required this.peripheral,
    required this.crypto,
    required this.gateway,
    required this.audit,
  });

  final BlEService ble;
  final PeripheralService peripheral;
  final PaymentCryptoService crypto;
  final PaymentGateway gateway;
  final AuditStore audit;
  final String bridgeNodeId = const Uuid().v4();
  final Map<String, MeshPacket> _pendingPackets = {};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _flushingPending = false;

  bool isRunning = false;
  void Function(String status)? onStatus;

  Future<void> start() async {
    if (isRunning) return;
    await peripheral.initialize();
    await peripheral.startAdvertising();
    peripheral.onPacketReceived = _handlePacket;
    ble.onPeerCountChanged = (count) {
      onStatus?.call('Mesh active · $count nearby device(s) connected');
      if (count > 0) unawaited(_flushPending());
    };
    ble.onPacketSent = (packet, peerId) => unawaited(
      audit.record(
        direction: 'BLE_SENT',
        packet: packet,
        deviceId: peerId,
        status: 'written',
      ),
    );
    _connectivitySubscription ??= Connectivity().onConnectivityChanged.listen(
      (_) => unawaited(_flushPending()),
    );
    await ble.startAutoDiscovery();
    isRunning = true;
    onStatus?.call('Mesh active · searching for nearby BluePay devices');
  }

  Future<GatewayResult?> submitPayment(MeshPacket packet) async {
    await audit.record(
      direction: 'PAYMENT_CREATED',
      packet: packet,
      deviceId: 'local:$bridgeNodeId',
      status: 'encrypted',
    );
    final claim = await crypto.claimCiphertext(
      ciphertext: packet.ciphertext,
      packetJson: packet.toJson(),
    );
    if (!claim.fresh) {
      return const GatewayResult(accepted: false, message: 'Duplicate packet');
    }
    final localResult = await _tryGateway(packet, hopCount: 0);
    if (localResult != null && localResult.accepted) {
      onStatus?.call(localResult.message);
    } else if (localResult == null || localResult.retryable) {
      _pendingPackets[claim.hash] = packet;
    } else {
      onStatus?.call(localResult.message);
      return localResult;
    }
    final count = await ble.broadcastPacket(packet);
    if (count > 0) {
      onStatus?.call('Payment packet sent to $count nearby device(s)');
    } else if (localResult == null || !localResult.accepted) {
      onStatus?.call('Payment queued for mesh delivery');
    }
    return localResult;
  }

  Future<void> _handlePacket(MeshPacket packet, String sourceDeviceId) async {
    final claim = await crypto.claimCiphertext(
      ciphertext: packet.ciphertext,
      packetJson: packet.toJson(),
    );
    await audit.record(
      direction: 'BLE_RECEIVED',
      packet: packet,
      deviceId: sourceDeviceId,
      status: claim.fresh ? 'received' : 'duplicate',
    );
    if (!claim.fresh) return;
    onStatus?.call('Encrypted payment packet received');

    final result = await _tryGateway(
      packet,
      hopCount: MeshPacket.defaultTtl - packet.ttl + 1,
    );
    if (result != null && result.accepted) {
      onStatus?.call('Bridge submitted packet · ${result.message}');
      return;
    }
    if (result != null && !result.retryable) {
      onStatus?.call('Payment packet rejected by test API');
      return;
    }

    if (packet.ttl > 1) {
      final forwarded = packet.decrementTtl();
      _pendingPackets[claim.hash] = forwarded;
      final count = await ble.broadcastPacket(forwarded);
      onStatus?.call(
        count > 0
            ? 'Forwarded encrypted packet to $count device(s)'
            : 'Packet received; waiting for another mesh connection',
      );
    } else {
      _pendingPackets[claim.hash] = packet;
    }
  }

  Future<GatewayResult?> _tryGateway(
    MeshPacket packet, {
    required int hopCount,
  }) async {
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) return null;
      final result = await gateway.submit(
        packet,
        bridgeNodeId: bridgeNodeId,
        hopCount: hopCount,
      );
      await audit.record(
        direction: 'API_SUBMITTED',
        packet: packet,
        deviceId: 'bridge:$bridgeNodeId',
        status: result.message,
      );
      return result;
    } catch (error) {
      unawaited(
        audit.record(
          direction: 'API_SUBMITTED',
          packet: packet,
          deviceId: 'bridge:$bridgeNodeId',
          status: 'unavailable: $error',
        ),
      );
      onStatus?.call('Payment API unavailable · packet remains on mesh');
      return GatewayResult(
        accepted: false,
        message: error.toString(),
        retryable: true,
      );
    }
  }

  Future<void> _flushPending() async {
    if (_flushingPending || _pendingPackets.isEmpty) return;
    _flushingPending = true;
    try {
      for (final entry in _pendingPackets.entries.toList()) {
        final packet = entry.value;
        final result = await _tryGateway(
          packet,
          hopCount: MeshPacket.defaultTtl - packet.ttl,
        );
        if (result?.accepted == true) {
          _pendingPackets.remove(entry.key);
        } else if (result == null || result.retryable) {
          await ble.broadcastPacket(packet);
        } else {
          _pendingPackets.remove(entry.key);
        }
      }
    } finally {
      _flushingPending = false;
    }
  }

  Future<void> stop() async {
    isRunning = false;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    peripheral.onPacketReceived = null;
    await ble.stop();
    await peripheral.stopAdvertising();
  }
}
