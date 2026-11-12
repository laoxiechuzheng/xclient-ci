/// Messages may reach logs; never include secrets.
class XcCryptoException implements Exception {
  final String code;
  final String message;

  const XcCryptoException(this.code, [this.message = '']);

  static const badFormat = 'bad_format';
  static const unknownKid = 'unknown_kid';
  static const badSignature = 'bad_signature';
  static const badVersion = 'bad_version';
  static const binding = 'binding_mismatch';
  static const expired = 'expired';
  static const notYetValid = 'not_yet_valid';
  static const decrypt = 'decrypt_failed';
  static const badKey = 'bad_key';
  static const brand = 'brand_mismatch';
  static const rollback = 'rollback';
  static const insecureUrl = 'insecure_url';

  @override
  String toString() =>
      'XcCryptoException($code${message.isEmpty ? '' : ': $message'})';
}
