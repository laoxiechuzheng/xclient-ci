import '../crypto/b64u.dart';
import '../crypto/device_keys.dart';
import '../log.dart';
import 'secure_store.dart';

class DeviceIdentity {
  final String deviceId;
  final DeviceKeyPair keys;

  const DeviceIdentity(this.deviceId, this.keys);

  String get publicKeyB64u => keys.publicB64u;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// Regenerates the identity if either stored half is missing or unreadable.
  static Future<DeviceIdentity> loadOrCreate(SecureStore store) async {
    final id = await store.read(SecureKeys.deviceId);
    final sk = await store.read(SecureKeys.deviceSk);
    if (id != null && _uuid.hasMatch(id) && sk != null) {
      try {
        return DeviceIdentity(
          id,
          await DeviceKeyPair.fromPrivate(b64uDecode(sk)),
        );
      } catch (e) {
        xcLog('device key unreadable, making a new one', warn: true);
      }
    }
    final identity = DeviceIdentity(uuidV4(), await DeviceKeyPair.generate());
    await store.write(SecureKeys.deviceSk, identity.keys.privateB64u);
    await store.write(SecureKeys.deviceId, identity.deviceId);
    return identity;
  }
}
