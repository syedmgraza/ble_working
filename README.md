# BluePay Mesh prototype

Android Flutter prototype for creating an encrypted payment instruction and
forwarding its packet over a foreground Bluetooth LE mesh session. A device
with network connectivity submits the encrypted packet through the dummy
payment gateway.

## RSA public-key setup

The app includes a development Base64 X.509 RSA public key, so every installed
copy can use it immediately. Tap the key icon to replace it with another key;
the app validates and stores that key in Android app-private preferences, so
it is available while the phone is offline. The key can also be overridden at
launch:

```powershell
flutter run --dart-define=SERVER_PUBLIC_KEY_BASE64=<base64-public-key>
```

To call a test endpoint instead of the built-in local demo response, also pass
`--dart-define=PAYMENT_API_URL=https://your-test-host/your-ingestion-route`.
The request body contains `packet`, `bridgeNodeId`, and `hopCount`.

## Implementation layout

- `lib/screens/` contains the payment UI.
- `lib/models/` contains the Java-compatible payment instruction model.
- `lib/security/` calls Android crypto through a platform channel.
- `lib/` BLE services advertise, discover, connect, frame, and forward packets.
- `lib/bridge/` isolates the replaceable dummy/test API client.
- `android/.../MainActivity.kt` implements RSA-OAEP + AES-GCM packing and a
  SHA-256 keyed `ConcurrentHashMap` deduplication cache.

The included development key is not the key used by `ServerKeyHolder`, which
generates a new pair on each server startup. The local demo gateway does not
decrypt packets. Replace this default when a stable server key is provisioned;
keep the matching private key on the server side only.

## Payload history

Open the history icon to view the encrypted packet JSON sent and received by
this phone, the peer device ID, timestamp, and outcome. Android stores the
records in app-private storage and keeps the newest 2,000 entries. These are
demo diagnostics; they are not encrypted at rest and should not be treated as
financial records.

The built-in demo gateway only simulates acceptance. It does not move money.
The deduplication map and pending packets are process-memory only. The shared
server code currently does not authenticate the sender with a digital
signature, so encryption alone must not be treated as proof of payment approval.
