/// Semver takes precedence; build numbers break ties only when both sides carry one.
/// A policy without a build treats every build of that semantic version as current.
class AppVersion implements Comparable<AppVersion> {
  final int major;
  final int minor;
  final int patch;
  final List<String> preRelease;
  final int? build;

  const AppVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
    this.build,
  });

  static final _pattern = RegExp(
    r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+(\d+))?$',
  );

  /// Null for malformed versions; an explicit build overrides a +build suffix.
  static AppVersion? tryParse(String text, {int? build}) {
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    int part(int group) => int.parse(match.group(group) ?? '0');
    final pre = match.group(4);
    final suffix = match.group(5);
    return AppVersion(
      part(1),
      part(2),
      part(3),
      preRelease: pre == null ? const [] : pre.split('.'),
      build: build ?? (suffix == null ? null : int.parse(suffix)),
    );
  }

  static AppVersion? fromParts(String version, String build) =>
      tryParse(version, build: int.tryParse(build.trim()));

  AppVersion withBuild(int? build) =>
      AppVersion(major, minor, patch, preRelease: preRelease, build: build);

  int compareSemver(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return _comparePreRelease(preRelease, other.preRelease);
  }

  @override
  int compareTo(AppVersion other) {
    final semver = compareSemver(other);
    if (semver != 0) return semver;
    final left = build;
    final right = other.build;
    if (left == null || right == null) return 0;
    return left.compareTo(right);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  static int _comparePreRelease(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) {
      return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = int.tryParse(a[i]);
      final y = int.tryParse(b[i]);
      final int result;
      if (x != null && y != null) {
        result = x.compareTo(y);
      } else if (x != null) {
        result = -1;
      } else if (y != null) {
        result = 1;
      } else {
        result = a[i].compareTo(b[i]);
      }
      if (result != 0) return result;
    }
    return a.length.compareTo(b.length);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0 && build == other.build;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease.join('.'));

  @override
  String toString() {
    final pre = preRelease.isEmpty ? '' : '-${preRelease.join('.')}';
    return '$major.$minor.$patch$pre${build == null ? '' : '+$build'}';
  }
}
