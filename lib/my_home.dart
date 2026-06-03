import 'dart:async';

import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:ble_working/ble_service.dart';
import 'package:ble_working/peripheral_service.dart';
import 'package:ble_working/permission_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class MyHome extends StatefulWidget {
  const MyHome({super.key});

  @override
  State<MyHome> createState() => _MyHomeState();
}

class _MyHomeState extends State<MyHome> {
  final BlEService bleService = BlEService();
  final PeripheralService peripheralService = PeripheralService();
  final TextEditingController messageController =
  TextEditingController();

  List<Map<String, dynamic>> messages = [];

  bool isSupported = false;
  bool isAdvertising = false;
  bool isScanning = false;

  late StreamSubscription<BluetoothAdapterState> adapterSubscription;
  StreamSubscription<List<ScanResult>>? scanSubscription;

  List<ScanResult> devices = [];

  @override
  void initState() {
    super.initState();

    bleService.onMessageReceived =
        (message) {

      setState(() {

        messages.add({
          "text": message,
          "mine": false,
        });

      });
    };

    peripheralService.onRebroadcastRequired =
        (packet) async {

      print(
          "******** REBROADCAST REQUESTED ********");

      await bleService.broadcastPacket(
          packet);
    };

    initializeBle();
  }

  Future<void> initializeBle() async {
    print(
        "*************** BLE INITIALIZATION STARTED ***************");

    await PermissionService.requestPermissions();

    isSupported = await bleService.isDeviceSupported();

    print(
        "*************** BLE SUPPORTED : $isSupported ***************");

    if (!isSupported) {
      return;
    }

    adapterSubscription = bleService.bluetoothOn();

    await FlutterBluePlus.adapterState
        .where((state) => state == BluetoothAdapterState.on)
        .first;

    print(
        "*************** BLUETOOTH READY ***************");

    scanSubscription = FlutterBluePlus.onScanResults.listen(
          (results) {
        print(
            "*************** ${results.length} DEVICES FOUND ***************");

        if (mounted) {
          setState(() {
            devices = results;
          });
        }

        for (var result in results) {
          print(
              "**************** DEVICE FOUND ****************");

          print(
              "NAME: ${result.advertisementData.advName}");

          print(
              "ID: ${result.device.remoteId}");

          print(
              "RSSI: ${result.rssi}");

          print(
              "SERVICE UUIDS: ${result.advertisementData.serviceUuids}");

          print(
              "************************************************");
        }
      },
      onError: (e) {
        print(
            "\$\$\$\$\$\$\$\$\$\$\$\$\$ SCAN ERROR : $e \$\$\$\$\$\$\$\$\$\$\$\$\$");
      },
    );
  }

  Future<void> startPeripheral() async {
    try {
      print(
          "*************** STARTING PERIPHERAL ***************");

      await peripheralService.initialize();

      await peripheralService.startAdvertising();

      bool? advertising =
      await BlePeripheral.isAdvertising();

      print(
          "*************** IS ADVERTISING : $advertising ***************");

      setState(() {
        isAdvertising = advertising ?? false;
      });

      print(
          "*************** ADVERTISING STARTED ***************");
    } catch (e) {
      print(
          "\$\$\$\$\$\$\$\$\$\$\$\$\$ PERIPHERAL ERROR : $e \$\$\$\$\$\$\$\$\$\$\$\$\$");
    }
  }

  Future<void> startScan() async {
    try {
      print(
          "*************** STARTING SCAN ***************");

      setState(() {
        devices.clear();
        isScanning = true;
      });

      await FlutterBluePlus.startScan(
        withServices: [
          Guid(PeripheralService.serviceUUID),
        ],
        timeout: const Duration(seconds: 15),
      );

      await FlutterBluePlus.isScanning
          .where((value) => value == false)
          .first;

      setState(() {
        isScanning = false;
      });

      print(
          "*************** SCAN COMPLETED ***************");
    } catch (e) {
      setState(() {
        isScanning = false;
      });

      print(
          "\$\$\$\$\$\$\$\$\$\$\$\$\$ SCAN START ERROR : $e \$\$\$\$\$\$\$\$\$\$\$\$\$");
    }
  }

  @override
  void dispose() {
    adapterSubscription.cancel();
    scanSubscription?.cancel();
    super.dispose();
  }

  Widget buildStatusCard() {
    return Card(
      margin: const EdgeInsets.all(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              "BLE Supported : $isSupported",
            ),
            const SizedBox(height: 8),
            Text(
              "Advertising : ${isAdvertising ? "ON" : "OFF"}",
            ),
            const SizedBox(height: 8),
            Text(
              "Scanning : ${isScanning ? "YES" : "NO"}",
            ),
          ],
        ),
      ),
    );
  }

  Widget buildButtons() {
    return Row(
      mainAxisAlignment:
      MainAxisAlignment.spaceEvenly,
      children: [
        ElevatedButton.icon(
          onPressed: startPeripheral,
          icon:
          const Icon(Icons.broadcast_on_home),
          label: const Text(
            "Start Peripheral",
          ),
        ),
        ElevatedButton.icon(
          onPressed: startScan,
          icon: const Icon(Icons.search),
          label: const Text("Scan"),
        ),
      ],
    );
  }

  Widget buildDeviceList() {
    if (devices.isEmpty) {
      return const Center(
        child: Text(
          "No Devices Found",
        ),
      );
    }

    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final result = devices[index];

        return Card(
          margin: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 5,
          ),
          child: ListTile(
            leading:
            const Icon(Icons.bluetooth),
            title: Text(
              result.advertisementData.advName
                  .isEmpty
                  ? "Unknown Device"
                  : result
                  .advertisementData
                  .advName,
            ),
            subtitle: Column(
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [
                Text(
                  result.device.remoteId
                      .toString(),
                ),
                Text(
                  "RSSI : ${result.rssi}",
                ),
                Text(
                  result
                      .advertisementData
                      .serviceUuids
                      .join(", "),
                  style: const TextStyle(
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            trailing: ElevatedButton(
              onPressed: () async {
                await bleService
                    .connectToDevice(
                  result.device,
                );

                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(
                    const SnackBar(
                      content: Text(
                        "Connection Attempted",
                      ),
                    ),
                  );
                }
              },
              child: const Text(
                "Connect",
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "BLE Central / Peripheral",
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),

          buildButtons(),

          buildStatusCard(),

          const SizedBox(height: 10),

          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [

                Expanded(
                  child: TextField(
                    controller:
                    messageController,
                    decoration:
                    const InputDecoration(
                      hintText:
                      "Enter message",
                      border:
                      OutlineInputBorder(),
                    ),
                  ),
                ),

                IconButton(
                  icon:
                  const Icon(Icons.send),
                  onPressed: () async {

                    if (messageController.text
                        .trim()
                        .isEmpty) {
                      return;
                    }

                    String text =
                        messageController.text;

                    await bleService.sendMessage(
                      text,
                    );

                    setState(() {

                      messages.add({
                        "text": text,
                        "mine": true,
                      });

                    });

                    messageController.clear();
                  },
                ),
              ],
            ),
          ),

          const Divider(),

      Expanded(
        child: ListView.builder(
          itemCount: messages.length,
          itemBuilder:
              (context, index) {

            final msg =
            messages[index];

            return Align(
              alignment:
              msg["mine"]
                  ? Alignment
                  .centerRight
                  : Alignment
                  .centerLeft,
              child: Container(
                margin:
                const EdgeInsets.all(
                  8,
                ),
                padding:
                const EdgeInsets.all(
                  12,
                ),
                decoration:
                BoxDecoration(
                  color:
                  msg["mine"]
                      ? Colors.blue
                      : Colors
                      .grey
                      .shade300,
                  borderRadius:
                  BorderRadius
                      .circular(
                    12,
                  ),
                ),
                child: Text(
                  msg["text"],
                  style:
                  TextStyle(
                    color:
                    msg["mine"]
                        ? Colors
                        .white
                        : Colors
                        .black,
                  ),
                ),
              ),
            );
          },
        ),
      ),
          const Divider(),
          Expanded(
            flex: 1,
            child: buildDeviceList(),
          ),
        ],
      ),
    );
  }
}