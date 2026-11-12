import 'dart:typed_data';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_sync.dart';

/// The managed profile in FlClash: a file-type [Profile] (no URL, no auto
/// update of its own) whose id is remembered under [prefsKey].
class FlClashProfileSink implements ManagedProfileSink {
  static const prefsKey = 'xc.managed_profile_id';

  final Ref ref;
  int? _lastAppliedId;

  FlClashProfileSink(this.ref);

  static Future<int?> managedProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(prefsKey);
  }

  static Future<void> _remember(int? id) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = id == null
        ? await prefs.remove(prefsKey)
        : await prefs.setInt(prefsKey, id);
    if (!saved) throw StateError('Managed profile preference was not saved');
  }

  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    final core = ref.read(coreHandlerProvider);
    final id = await managedProfileId();
    final existing = ref.read(profilesProvider).getProfile(id);
    final base =
        existing ?? Profile.normal(label: label).copyWith(autoUpdate: false);
    final saved = await base
        .copyWith(
          label: label,
          url: '',
          type: ProfileType.file,
          autoUpdate: false,
          subscriptionInfo: SubscriptionInfo.formHString(subscriptionUserinfo),
        )
        .saveFile(
          yaml,
          validate: (path, key) => core.validateProfile(path, key),
        );
    _lastAppliedId = saved.id;
    ref.read(profilesProvider.notifier).put(saved);
    await _remember(saved.id);
    if (ref.read(currentProfileIdProvider) != saved.id) {
      ref.read(currentProfileIdProvider.notifier).value = saved.id;
    }
    final applied = await ref
        .read(setupActionProvider.notifier)
        .applyProfile(silence: true, force: true);
    if (!applied) {
      throw StateError('Managed profile was not applied by the core');
    }
  }

  @override
  Future<void> remove() async {
    Object? failure;
    StackTrace? trace;
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    int? id = _lastAppliedId;
    await attempt(() async {
      id = await managedProfileId() ?? id;
    });
    await attempt(() async {
      if (!await ref.read(setupActionProvider.notifier).setRunning(false)) {
        throw StateError('Core stop was not acknowledged');
      }
    });
    final profileId = id;
    if (profileId != null) {
      await attempt(() async {
        if (ref.read(profilesProvider).getProfile(profileId) != null) {
          await ref.read(profilesProvider.notifier).del(profileId);
        }
      });
      await attempt(
        () => ref.read(profilesActionProvider.notifier).clearEffect(profileId),
      );
    }
    await attempt(() async {
      if (ref.read(currentProfileIdProvider) == profileId) {
        ref.read(currentProfileIdProvider.notifier).value = null;
      }
    });
    await attempt(() => _remember(null));
    _lastAppliedId = null;
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}
