import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';

import 'mesh_packet.dart';

class _FrameBuffer {
  _FrameBuffer(this.total);
  final int total;
  int nextIndex = 0;
  final BytesBuilder bytes = BytesBuilder(copy: false);
}

/// BLE GATT peripheral. It accepts framed packet writes and reassembles them.
class PeripheralService {
  static const String serviceUUID = '12345678-1234-5678-1234-56789abcdef0';
  static const String characteristicUUID =
      '87654321-4321-8765-4321-fedcba987654';

  final Map<String, _FrameBuffer> _buffers = {};
  bool _initialized = false;
  bool isAdvertising = false;
  void Function(MeshPacket packet, String sourceDeviceId)? onPacketReceived;

  Future<void> initialize() async {
    if (_initialized) return;
    await BlePeripheral.initialize();
    BlePeripheral.setAdvertisingStatusUpdateCallback((advertising, error) {
      isAdvertising = advertising;
    });
    BlePeripheral.setWriteRequestCallback((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (characteristicId.toLowerCase() != characteristicUUID.toLowerCase() ||
          value == null ||
          offset != 0) {
        return null;
      }
      try {
        final complete = _acceptFrame(deviceId, value);
        if (complete != null) {
          onPacketReceived?.call(
            MeshPacket.fromJson(utf8.decode(complete)),
            deviceId,
          );
        }
      } catch (_) {
        _buffers.remove(deviceId);
      }
      return null;
    });
    await BlePeripheral.addService(
      BleService(
        uuid: serviceUUID,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: characteristicUUID,
            properties: [CharacteristicProperties.write.index],
            permissions: [AttributePermissions.writeable.index],
          ),
        ],
      ),
    );
    _initialized = true;
  }

  List<int>? _acceptFrame(String deviceId, List<int> frame) {
    if (frame.length < 6 || frame[0] != 0xB1) {
      throw const FormatException('Invalid BLE frame');
    }
    final index = (frame[1] << 8) | frame[2];
    final total = (frame[3] << 8) | frame[4];
    if (total == 0 || total > 0xffff || index >= total) {
      throw const FormatException('Invalid BLE frame sequence');
    }
    if (index == 0) _buffers[deviceId] = _FrameBuffer(total);
    final buffer = _buffers[deviceId];
    if (buffer == null || buffer.total != total || buffer.nextIndex != index) {
      _buffers.remove(deviceId);
      throw const FormatException('Missing or out-of-order BLE frame');
    }
    buffer.bytes.add(frame.sublist(5));
    buffer.nextIndex++;
    if (buffer.nextIndex != buffer.total) return null;
    _buffers.remove(deviceId);
    return buffer.bytes.takeBytes();
  }

  Future<void> startAdvertising() async {
    await initialize();
    await BlePeripheral.startAdvertising(services: [serviceUUID]);
    isAdvertising = true;
  }

  Future<void> stopAdvertising() async {
    await BlePeripheral.stopAdvertising();
    isAdvertising = false;
  }
}
