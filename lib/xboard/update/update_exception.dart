/// Why an update step stopped. [code] is stable for logs and tests;
/// [displayMessage] is the Chinese text the UI shows.
class XcUpdateException implements Exception {
  final String code;
  final String detail;

  const XcUpdateException(this.code, [this.detail = '']);

  static const noReleaseUrls = 'no_release_urls';
  static const releaseFetch = 'release_fetch';
  static const releaseInvalid = 'release_invalid';
  static const notNewer = 'not_newer';
  static const noAsset = 'no_asset';
  static const download = 'download';
  static const size = 'size_mismatch';
  static const checksum = 'sha256_mismatch';
  static const permission = 'install_permission';
  static const packageMismatch = 'package_mismatch';
  static const install = 'install_failed';
  static const aborted = 'install_aborted';
  static const signature = 'codesign';
  static const unsupported = 'unsupported';

  String get displayMessage => switch (code) {
    noReleaseUrls => '服务器没有提供新版本的下载信息',
    releaseFetch => '无法获取新版本信息，请检查网络后重试',
    releaseInvalid => '新版本信息校验失败，已拒绝安装',
    notNewer => '服务器提供的版本不比当前版本新',
    noAsset => '新版本暂未提供适用于本设备的安装包',
    download => '下载失败，请检查网络后重试',
    size || checksum => '安装包校验失败，已删除并拒绝安装',
    permission => '需要允许“安装未知应用”权限才能完成更新',
    packageMismatch => '安装包与当前应用的签名或包名不一致，已拒绝安装',
    install => '安装失败，请重试',
    aborted => '安装已取消',
    signature => '新版本的代码签名校验失败，已拒绝安装',
    unsupported => '当前平台不支持自动更新',
    _ => '更新失败',
  };

  @override
  String toString() =>
      'XcUpdateException($code${detail.isEmpty ? '' : ': $detail'})';
}
