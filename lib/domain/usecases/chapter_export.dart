/// Turns chapter markers into the timestamp list a video description wants.
///
/// Pure string work over markers, so it is testable without a timeline, and
/// the platform quirks live in one place instead of being rediscovered by
/// whoever writes the UI.
library;

import '../entities/marker.dart';

enum ChapterFormat {
  /// `0:00 Intro` — what YouTube parses out of a description.
  youtube('YouTube description'),

  /// `00:00:00.000 Intro` — a readable full-precision list.
  plain('Plain list'),

  /// A WebVTT chapter file, for players that take one.
  webvtt('WebVTT file');

  const ChapterFormat(this.label);
  final String label;
}

abstract final class ChapterExport {
  /// Formats [markers] for [format].
  ///
  /// YouTube's rules are specific and unforgiving, so they are enforced here
  /// rather than left to the user to discover: the list must start at 0:00,
  /// be in ascending order, and hold at least three entries, or the platform
  /// ignores the whole thing and shows none.
  static String format(
    Iterable<Marker> markers,
    Duration totalDuration, {
    ChapterFormat format = ChapterFormat.youtube,
  }) {
    final chapters = prepare(markers);
    if (chapters.isEmpty) return '';

    return switch (format) {
      ChapterFormat.youtube => [
        for (final chapter in chapters)
          '${_youtubeStamp(chapter.time)} ${chapter.label}',
      ].join('\n'),
      ChapterFormat.plain => [
        for (final chapter in chapters)
          '${_fullStamp(chapter.time)}  ${chapter.label}',
      ].join('\n'),
      ChapterFormat.webvtt => _webvtt(chapters, totalDuration),
    };
  }

  /// The chapter list as it will be written: sorted, deduplicated, named, and
  /// starting at zero.
  static List<Marker> prepare(Iterable<Marker> markers) {
    final chapters =
        markers.where((m) => m.kind == MarkerKind.chapter).toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    if (chapters.isEmpty) return const [];

    final out = <Marker>[];
    for (final chapter in chapters) {
      // Two chapters at the same second collapse: the platform would show one
      // anyway, and which one it picked would be arbitrary.
      if (out.isNotEmpty && out.last.time.inSeconds == chapter.time.inSeconds) {
        continue;
      }
      out.add(
        chapter.label.trim().isEmpty
            ? chapter.copyWith(label: 'Chapter ${out.length + 1}')
            : chapter,
      );
    }

    // A list that does not begin at zero is rejected wholesale by YouTube, so
    // one is prepended rather than letting the export silently do nothing.
    if (out.first.time > Duration.zero) {
      out.insert(
        0,
        Marker(
          id: 'chapter_start',
          time: Duration.zero,
          label: 'Start',
          kind: MarkerKind.chapter,
        ),
      );
    }
    return out;
  }

  /// Why a list would not work as YouTube chapters, or null when it will.
  static String? youtubeProblem(Iterable<Marker> markers) {
    final chapters = prepare(markers);
    if (chapters.isEmpty) return 'There are no chapter markers yet.';
    if (chapters.length < 3) {
      return 'YouTube needs at least three chapters — there '
          '${chapters.length == 1 ? 'is 1' : 'are ${chapters.length}'}.';
    }
    return null;
  }

  /// `0:00` under an hour, `1:02:03` over it — YouTube accepts both and shows
  /// the shorter form on short videos.
  static String _youtubeStamp(Duration at) {
    final hours = at.inHours;
    final minutes = at.inMinutes % 60;
    final seconds = at.inSeconds % 60;
    final ss = seconds.toString().padLeft(2, '0');
    if (hours == 0) return '$minutes:$ss';
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }

  static String _fullStamp(Duration at) {
    final h = at.inHours.toString().padLeft(2, '0');
    final m = (at.inMinutes % 60).toString().padLeft(2, '0');
    final s = (at.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (at.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  static String _webvtt(List<Marker> chapters, Duration total) {
    final buffer = StringBuffer('WEBVTT\n');
    for (var i = 0; i < chapters.length; i++) {
      // Each chapter runs until the next one starts; the last runs to the end
      // of the programme.
      final end = i + 1 < chapters.length ? chapters[i + 1].time : total;
      buffer
        ..writeln()
        ..writeln('${i + 1}')
        ..writeln('${_fullStamp(chapters[i].time)} --> ${_fullStamp(end)}')
        ..writeln(chapters[i].label);
    }
    return buffer.toString();
  }
}
