library;

const xcDelayTimeoutText = '超时';

/// Cap rounding at 109 to preserve [10, 110); the raw cache stays unchanged.
const _maxShown = 109;

bool isDelayOk(int? raw) => raw != null && raw > 0;

bool isDelayFailure(int? raw) => raw != null && raw < 0;

int displayDelay(int raw) {
  if (raw <= 0) {
    return 10;
  }
  final shown = (10 + 100 * raw / (raw + 150)).round();
  return shown > _maxShown ? _maxShown : shown;
}

String? displayDelayText(int? raw, {bool unit = true}) {
  if (raw == null || raw == 0) {
    return null;
  }
  if (raw < 0) {
    return xcDelayTimeoutText;
  }
  final shown = displayDelay(raw);
  return unit ? '$shown ms' : '$shown';
}
