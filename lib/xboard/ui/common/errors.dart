import '../../core/net/api_exception.dart';

String xcErrorText(Object error) {
  if (error is! XbApiException) return '操作失败，请稍后重试';
  final server = error.displayMessage.trim();
  return switch (error.kind) {
    XbErrorKind.network => '网络连接失败，请检查网络后重试',
    XbErrorKind.tls => '安全连接失败：服务器证书校验未通过',
    XbErrorKind.pinMismatch => '服务器证书与预期不符，已阻止连接',
    XbErrorKind.unauthorized => '登录已过期，请重新登录',
    XbErrorKind.deviceRevoked => '此设备已被移除，请重新登录',
    XbErrorKind.deviceLimit => '登录设备数已达上限，请在设备管理中移除不用的设备',
    XbErrorKind.rateLimited => _rateLimitText(error, server),
    XbErrorKind.server => '服务器繁忙，请稍后重试',
    XbErrorKind.notFound => '面板未开启此功能',
    XbErrorKind.badResponse => '服务器返回了无法识别的数据',
    XbErrorKind.validation ||
    XbErrorKind.failed ||
    XbErrorKind.deviceUnknown ||
    XbErrorKind.replay => server.isEmpty ? '操作失败，请稍后重试' : server,
  };
}

String _rateLimitText(XbApiException error, String server) {
  final wait = error.retryAfter;
  if (wait != null && wait.inSeconds > 0) {
    final minutes = (wait.inSeconds + 59) ~/ 60;
    return '尝试次数过多，请 $minutes 分钟后再试';
  }
  return server.isEmpty ? '尝试次数过多，请稍后再试' : server;
}

String xcLoginErrorText(Object error) {
  // Login 429 means the panel temporarily locked password attempts.
  if (error is XbApiException && error.kind == XbErrorKind.rateLimited) {
    final wait = error.retryAfter;
    if (wait != null && wait.inSeconds > 0) {
      final minutes = (wait.inSeconds + 59) ~/ 60;
      return '密码错误次数过多，账号已临时锁定，请 $minutes 分钟后再试';
    }
    return '密码错误次数过多，账号已临时锁定，请稍后再试';
  }
  return xcErrorText(error);
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? validateLoginEmail(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '请输入邮箱';
  if (!_emailPattern.hasMatch(text)) return '邮箱格式不正确';
  return null;
}

String? validateLoginPassword(String? value) {
  final text = value ?? '';
  if (text.isEmpty) return '请输入密码';
  if (text.length < 8) return '密码至少 8 位';
  return null;
}
