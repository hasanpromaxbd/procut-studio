/// Contract for the bundled + downloadable creative asset library.
library;

import 'package:flutter/foundation.dart';

import '../../core/error/result.dart';

enum LibraryCategory {
  music('Music'),
  soundEffect('Sound FX'),
  sticker('Stickers'),
  emoji('Emoji'),
  filter('Filters'),
  lut('LUT packs'),
  font('Fonts');

  const LibraryCategory(this.label);
  final String label;
}

@immutable
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.name,
    required this.category,
    this.collection = '',
    this.remoteUrl,
    this.bundledAssetPath,
    this.localPath,
    this.previewUrl,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.tags = const [],
    this.attribution,
    this.isPremium = false,
  });

  final String id;
  final String name;
  final LibraryCategory category;

  /// Pack or album this belongs to, e.g. "Cinematic Teal".
  final String collection;

  /// Set for items fetched over the network.
  final String? remoteUrl;

  /// Set for items shipped inside the APK.
  final String? bundledAssetPath;

  /// Set once downloaded/extracted to disk.
  final String? localPath;

  final String? previewUrl;
  final int durationMs;
  final int sizeBytes;
  final List<String> tags;

  /// Licence attribution string; surfaced in Settings → Licences.
  final String? attribution;

  final bool isPremium;

  bool get isDownloaded => localPath != null && localPath!.isNotEmpty;
  bool get isBundled => bundledAssetPath != null;
  Duration get duration => Duration(milliseconds: durationMs);

  LibraryItem copyWith({String? localPath}) => LibraryItem(
    id: id,
    name: name,
    category: category,
    collection: collection,
    remoteUrl: remoteUrl,
    bundledAssetPath: bundledAssetPath,
    localPath: localPath ?? this.localPath,
    previewUrl: previewUrl,
    durationMs: durationMs,
    sizeBytes: sizeBytes,
    tags: tags,
    attribution: attribution,
    isPremium: isPremium,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category.name,
    'collection': collection,
    'remoteUrl': remoteUrl,
    'bundled': bundledAssetPath,
    'local': localPath,
    'preview': previewUrl,
    'durationMs': durationMs,
    'size': sizeBytes,
    'tags': tags,
    'attribution': attribution,
    'premium': isPremium,
  };

  factory LibraryItem.fromJson(Map<String, dynamic> json) => LibraryItem(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    category: LibraryCategory.values.firstWhere(
      (c) => c.name == json['category'],
      orElse: () => LibraryCategory.music,
    ),
    collection: json['collection'] as String? ?? '',
    remoteUrl: json['remoteUrl'] as String?,
    bundledAssetPath: json['bundled'] as String?,
    localPath: json['local'] as String?,
    previewUrl: json['preview'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
    tags: ((json['tags'] as List?) ?? const []).cast<String>(),
    attribution: json['attribution'] as String?,
    isPremium: json['premium'] as bool? ?? false,
  );
}

abstract interface class AssetLibraryRepository {
  /// Catalogue for a category. Bundled items are always present; remote items
  /// are merged in when the network is reachable, and the call still succeeds
  /// offline with just the bundled set.
  Future<Result<List<LibraryItem>>> browse(
    LibraryCategory category, {
    String? collection,
    String? query,
  });

  /// Collection names within a category, for the pack chips.
  Future<Result<List<String>>> collections(LibraryCategory category);

  /// Ensures the item is on disk and returns it with `localPath` populated.
  /// Emits 0..1 progress for remote downloads.
  Future<Result<LibraryItem>> materialise(
    LibraryItem item, {
    void Function(double progress)? onProgress,
  });

  Future<Result<void>> removeDownload(String itemId);

  /// Font family names available for text layers.
  Future<Result<List<String>>> fontFamilies({String? query});
}
