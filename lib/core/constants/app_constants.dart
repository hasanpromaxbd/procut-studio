/// App-wide invariants. Anything a designer or product owner might want to
/// tune lives here rather than being scattered through the engine.
library;

abstract final class AppConstants {
  static const String appName = 'ProCut Studio';
  static const String appTagline = 'Cut. Compose. Command.';

  /// Bumped whenever the persisted project JSON shape changes in a way that
  /// needs migration. See `ProjectMigrations`.
  static const int projectSchemaVersion = 3;

  /// Auto-save cadence while the editor is open.
  static const Duration autoSaveInterval = Duration(seconds: 12);

  /// Debounce applied to edits before an auto-save fires, so dragging a clip
  /// does not write 60 revisions per second.
  static const Duration autoSaveDebounce = Duration(milliseconds: 900);

  /// How many undo steps are retained per project.
  static const int undoStackLimit = 100;

  /// Rolling backups kept per project.
  static const int projectBackupCount = 5;

  /// Speed range exposed by the speed tool.
  static const double minClipSpeed = 0.1;
  static const double maxClipSpeed = 10.0;

  /// A clip may never be trimmed shorter than this — below one frame the
  /// encoder has nothing to emit.
  static const Duration minClipDuration = Duration(milliseconds: 40);

  /// Longest transition we allow; beyond this the overlap eats whole clips.
  static const Duration maxTransitionDuration = Duration(seconds: 5);
  static const Duration defaultTransitionDuration = Duration(milliseconds: 600);

  /// Default project settings for a fresh timeline.
  static const int defaultFps = 30;
  static const int defaultWidth = 1080;
  static const int defaultHeight = 1920;

  /// Thumbnail cache budget. ~200 decoded 96×54 RGBA frames ≈ 4 MB.
  static const int thumbnailCacheCapacity = 240;
  static const int thumbnailPixelWidth = 96;

  /// Waveform resolution: samples stored per second of audio.
  static const int waveformSamplesPerSecond = 40;

  /// Preview render budget. We target 60fps; if the compositor misses this
  /// twice in a row it drops to a proxy resolution.
  static const Duration frameBudget = Duration(microseconds: 16667);

  /// Directory names under the app documents dir.
  static const String projectsDirName = 'projects';
  static const String mediaDirName = 'media';
  static const String cacheDirName = 'cache';
  static const String thumbnailsDirName = 'thumbnails';
  static const String waveformsDirName = 'waveforms';
  static const String exportsDirName = 'exports';
  static const String backupsDirName = 'backups';
  static const String recordingsDirName = 'recordings';
  static const String proxiesDirName = 'proxies';

  /// Hive box names.
  static const String boxProjects = 'projects';
  static const String boxSettings = 'settings';
  static const String boxMediaMeta = 'media_meta';
  static const String boxRecents = 'recents';

  /// Extension used for exported/imported project bundles.
  static const String projectBundleExtension = 'pcstudio';

  /// Media the importer will accept.
  static const Set<String> supportedVideoExtensions = {
    'mp4', 'mov', 'm4v', 'mkv', '3gp', 'webm', 'avi',
  };
  static const Set<String> supportedAudioExtensions = {
    'mp3', 'aac', 'm4a', 'wav', 'ogg', 'opus', 'flac',
  };
  static const Set<String> supportedImageExtensions = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic',
  };

  const AppConstants._();
}
