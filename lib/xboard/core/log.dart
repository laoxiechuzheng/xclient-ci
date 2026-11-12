/// Where XClient core logs go. The runtime points this at FlClash's
/// `commonPrint`; tests leave it silent. Never pass secrets, tokens, keys,
/// e-mail addresses or subscription content.
typedef XcLogSink = void Function(String message, {required bool warn});

XcLogSink? xcLogSink;

void xcLog(String message, {bool warn = false}) {
  xcLogSink?.call('[xclient] $message', warn: warn);
}
