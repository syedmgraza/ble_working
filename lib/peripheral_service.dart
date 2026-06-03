import 'dart:convert';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

class PeripheralService {
  static const String serviceUUID =
      "12345678-1234-5678-1234-56789abcdef0";

  static const String characteristicUUID =
      "87654321-4321-8765-4321-fedcba987654";

  String? connectedDeviceId;

  Future<void> initialize() async {
    print(
        "******** INITIALIZING PERIPHERAL ********");

    await BlePeripheral.initialize();

    BlePeripheral.setAdvertisingStatusUpdateCallback(
          (advertising, error) {
        print(
            "******** ADVERTISING=$advertising ERROR=$error ********");
      },
    );

    BlePeripheral.setConnectionStateChangeCallback(
          (deviceId, connected) {
        connectedDeviceId =
        connected ? deviceId : null;

        print(
            "******** CONNECTION STATE CHANGED ********");

        print(
            "DEVICE ID : $deviceId");

        print(
            "CONNECTED : $connected");
      },
    );

    BlePeripheral.setWriteRequestCallback(
          (deviceId, characteristicId, offset, value) {
        try {
          String message =
          utf8.decode(value!);

          print(
              "******** MESSAGE RECEIVED ********");

          print(
              "FROM DEVICE : $deviceId");

          print(
              "CHARACTERISTIC : $characteristicId");

          print(
              "MESSAGE : $message");

          print(
              "***********************************");
              processPacket(message);
        } catch (e) {
          print(
              "\$\$\$\$\$\$\$ MESSAGE PARSE ERROR \$\$\$\$\$\$\$");

          print(e);
        }
      },
    );

    await BlePeripheral.addService(
      BleService(
        uuid: serviceUUID,
        primary: true,
        characteristics: [
          BleCharacteristic(
            uuid: characteristicUUID,
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.write.index,
              CharacteristicProperties.notify.index,
            ],
            permissions: [
              AttributePermissions.readable.index,
              AttributePermissions.writeable.index,
            ],
          ),
        ],
      ),
    );

    print(
        "******** SERVICE ADDED ********");
  }

  Future<void> startAdvertising() async {
    print(
        "******** START ADVERTISING ********");

    await BlePeripheral.startAdvertising(
      services: [serviceUUID],
    );
  }

  Future<void> stopAdvertising() async {
    print(
        "******** STOP ADVERTISING ********");

    await BlePeripheral.stopAdvertising();
  }

  Future<void> sendMessage(
      String message,
      ) async {
    try {
      print(
          "******** SENDING MESSAGE FROM PERIPHERAL ********");

      print(
          "MESSAGE : $message");

      await BlePeripheral.updateCharacteristic(
        characteristicId: characteristicUUID,
        value: Uint8List.fromList(
          utf8.encode(message),
        ),
      );

      print(
          "******** MESSAGE SENT ********");
    } catch (e) {
      print(
          "\$\$\$\$\$\$\$ SEND ERROR \$\$\$\$\$\$\$");

      print(e);
    }
  }
  Future<void> processPacket(
      String packet,
      ) async {

    final connectivity =
    await Connectivity()
        .checkConnectivity();

    if (connectivity.contains(
        ConnectivityResult.none)) {

      print(
          "\$\$\$\$\$\$\$ NO INTERNET FOUND \$\$\$\$\$\$\$");

      return;
    }

    print(
        "******** INTERNET AVAILABLE ********");

    await hitDummyApi(packet);
  }
  Future<void> hitDummyApi(
      String packet,
      ) async {

    try {

      print(
          "******** HITTING API ********");

      final response =
      await http.post(
        Uri.parse(
          "https://jsonplaceholder.typicode.com/posts",
        ),
        headers: {
          "Content-Type":
          "application/json",
        },
        body: jsonEncode({
          "message": packet,
        }),
      );

      print(
          "******** API RESPONSE ********");

      print(
          response.statusCode);

      print(
          response.body);

    } catch (e) {

      print(
          "\$\$\$\$\$\$\$ API ERROR \$\$\$\$\$\$\$");

      print(e);
    }
  }
}