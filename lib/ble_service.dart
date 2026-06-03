import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_working/peripheral_service.dart';

import 'mesh_packet.dart';

class BlEService {
  BluetoothCharacteristic? chatCharacteristic;
  BluetoothDevice? connectedDevice;
  Function(String)? onMessageReceived;

  final List<BluetoothDevice>
  connectedDevices = [];

  Future<bool> isDeviceSupported() {
    return FlutterBluePlus.isSupported;
  }

  StreamSubscription<BluetoothAdapterState> bluetoothOn() {
    return FlutterBluePlus.adapterState.listen(
          (BluetoothAdapterState state) async {
        switch (state) {
          case BluetoothAdapterState.on:
            debugPrint('Bluetooth is ON');
            break;

          case BluetoothAdapterState.off:
            debugPrint('Bluetooth is OFF');

            if (!kIsWeb && Platform.isAndroid) {
              try {
                await FlutterBluePlus.turnOn();
              } catch (e) {
                debugPrint('Unable to turn on Bluetooth: $e');
              }
            }
            break;

          default:
            debugPrint('Bluetooth state: $state');
        }
      },
    );
  }

  Future<void> scanDevices() async {
    await FlutterBluePlus.adapterState
        .where((state) => state == BluetoothAdapterState.on)
        .first;

    FlutterBluePlus.onScanResults.listen(
          (results) {
        for (ScanResult result in results) {
          print(
              "******** DEVICE ${result.device.remoteId} ********");

          print(
              "NAME : ${result.advertisementData.advName}");

          print(
              "SERVICE UUIDS : ${result.advertisementData.serviceUuids}");
        }
      },
      onError: (e) {
        debugPrint('Scan Error: $e');
      },
    );

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
    );

    await FlutterBluePlus.isScanning
        .where((value) => value == false)
        .first;

    debugPrint('Scan Completed');
  }

  Future<void> connectToDevice(
      BluetoothDevice device,
      ) async {
    try {
      print(
          "******** CONNECTING TO ${device.remoteId} ********");

      await device.connect(
        license: License.nonprofit,
      );

      connectedDevice = device;
      connectedDevices.add(device);
      print(
          "******** CONNECTED SUCCESSFULLY ********");

      List<BluetoothService> services =
      await device.discoverServices();

      print(
          "******** TOTAL SERVICES ${services.length} ********");

      for (var service in services) {
        print(
            "******** SERVICE ${service.uuid} ********");

        if (service.uuid
            .toString()
            .toLowerCase() ==
            PeripheralService.serviceUUID
                .toLowerCase()) {
          print(
              "******** OUR SERVICE FOUND ********");

          for (var characteristic
          in service.characteristics) {
            print(
                "******** CHAR ${characteristic.uuid} ********");

            if (characteristic.uuid
                .toString()
                .toLowerCase() ==
                PeripheralService
                    .characteristicUUID
                    .toLowerCase()) {

              chatCharacteristic =
                  characteristic;

              print(
                  "******** CHAT CHARACTERISTIC FOUND ********");

              try {

                await characteristic.setNotifyValue(true);

                print(
                    "******** NOTIFICATIONS ENABLED ********");

                characteristic.lastValueStream.listen(
                      (data) {

                    try {

                      if (data.isEmpty) return;

                      String msg =
                      utf8.decode(data);

                      print(
                          "******** MESSAGE FROM PERIPHERAL ********");

                      print(
                          "MESSAGE : $msg");

                      onMessageReceived?.call(msg);

                    } catch (e) {

                      print(
                          "\$\$\$\$\$\$\$ NOTIFICATION ERROR \$\$\$\$\$\$\$");

                      print(e);
                    }
                  },
                );

              } catch (e) {

                print(
                    "\$\$\$\$\$\$\$ ENABLE NOTIFICATION ERROR \$\$\$\$\$\$\$");

                print(e);
              }
            }
          }
        }
      }

      if (chatCharacteristic == null) {
        print(
            "\$\$\$\$\$\$\$ CHAT CHARACTERISTIC NOT FOUND \$\$\$\$\$\$\$");
      }
    } catch (e) {
      print(
          "\$\$\$\$\$\$\$ CONNECTION ERROR \$\$\$\$\$\$\$");

      print(e);
    }
  }

  Future<void> broadcastPacket(
      MeshPacket packet) async {

    print(
        "******** BROADCAST START ********");

    print(
        "CONNECTED DEVICES = ${connectedDevices.length}");

    for(var device in connectedDevices){

      print(
          "******** TARGET DEVICE ${device.remoteId} ********");

      try{

        List<BluetoothService>
        services =
        await device.discoverServices();

        print(
            "SERVICES = ${services.length}");

        for(var service in services){

          print(
              "SERVICE UUID = ${service.uuid}");

          if(service.uuid
              .toString()
              .toLowerCase()
              ==
              PeripheralService
                  .serviceUUID
                  .toLowerCase()){

            print(
                "******** MESH SERVICE FOUND ********");

            for(var characteristic
            in service.characteristics){

              print(
                  "CHAR UUID = ${characteristic.uuid}");

              if(characteristic.uuid
                  .toString()
                  .toLowerCase()
                  ==
                  PeripheralService
                      .characteristicUUID
                      .toLowerCase()){

                print(
                    "******** FORWARDING PACKET ********");

                print(
                    packet.toJson());

                await characteristic.write(
                  utf8.encode(
                    packet.toJson(),
                  ),
                );

                print(
                    "******** PACKET FORWARDED ********");
              }
            }
          }
        }

      }catch(e){

        print(
            "\$\$\$\$\$\$\$ BROADCAST ERROR \$\$\$\$\$\$\$");

        print(e);
      }
    }
  }
  Future<void> sendMessage(
      String message,
      ) async {
    if (chatCharacteristic == null) {
      print(
          "\$\$\$\$\$\$\$ NO CHARACTERISTIC FOUND \$\$\$\$\$\$\$");
      return;
    }

    try {
      print(
          "******** SENDING MESSAGE ********");

      print(
          "MESSAGE : $message");

      MeshPacket packet =
      MeshPacket.create(message);

      await chatCharacteristic!.write(
        utf8.encode(packet.toJson()),
      );

      print(
          "******** MESSAGE SENT ********");
    } catch (e) {
      print(
          "\$\$\$\$\$\$\$ SEND ERROR \$\$\$\$\$\$\$");

      print(e);
    }
  }

  Future<void> disconnect() async {
    try {
      if (connectedDevice != null) {
        await connectedDevice!.disconnect();

        print(
            "******** DEVICE DISCONNECTED ********");
      }
    } catch (e) {
      print(
          "\$\$\$\$\$\$\$ DISCONNECT ERROR \$\$\$\$\$\$\$");

      print(e);
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }
}