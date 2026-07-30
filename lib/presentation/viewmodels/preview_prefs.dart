/// Preview playback preferences.
///
/// Proxy use is a *preference*, not a property of the media: the same project
/// on a stronger device may want full-quality preview. So the choice lives in
/// settings state, not on the asset — the asset only records whether a proxy
/// exists.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';

enum PreviewQuality {
  /// Decode the proxy when one exists — the default; scrubbing 4K on a phone
  /// without one is a slideshow.
  proxy('Smooth (proxy)'),

  /// Always decode the original, accepting dropped frames on heavy media.
  original('Full quality');

  const PreviewQuality(this.label);
  final String label;
}

final previewQualityProvider =
    NotifierProvider<PreviewQualityController, PreviewQuality>(
      PreviewQualityController.new,
    );

class PreviewQualityController extends Notifier<PreviewQuality> {
  static const _key = 'previewQuality';

  @override
  PreviewQuality build() {
    final stored = ref.read(hiveStoreProvider).settings.get(_key);
    return stored == 'original' ? PreviewQuality.original : PreviewQuality.proxy;
  }

  void set(PreviewQuality quality) {
    state = quality;
    unawaited(
      ref.read(hiveStoreProvider).settings.put(_key, quality.name),
    );
  }
}
