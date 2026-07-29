import 'package:uuid/uuid.dart';

/// Identifier factory.
///
/// Prefixed ids (`clip_…`, `trk_…`) make logs and persisted JSON readable at a
/// glance and make it obvious when the wrong kind of id has been threaded
/// through a call.
abstract final class IdGenerator {
  static const Uuid _uuid = Uuid();

  static String _make(String prefix) => '${prefix}_${_uuid.v4()}';

  static String project() => _make('prj');
  static String track() => _make('trk');
  static String clip() => _make('clip');
  static String effect() => _make('fx');
  static String transition() => _make('trn');
  static String keyframe() => _make('kf');
  static String textLayer() => _make('txt');
  static String sticker() => _make('stk');
  static String asset() => _make('ast');
  static String exportJob() => _make('exp');
  static String subtitle() => _make('sub');

  /// Time-ordered id: lexicographic sort equals chronological sort, which the
  /// recents list relies on.
  static String sortable(String prefix) {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36).padLeft(11, '0');
    return '${prefix}_${ts}_${_uuid.v4().substring(0, 8)}';
  }

  const IdGenerator._();
}
