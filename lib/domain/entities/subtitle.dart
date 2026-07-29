/// Timed text produced by auto-caption, before it becomes [TextClip]s.
library;

import 'package:flutter/foundation.dart';

@immutable
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
    this.confidence = 1.0,
    this.speaker,
  });

  final Duration start;
  final Duration end;
  final String text;

  /// 0..1 from the recogniser. The review UI highlights low-confidence cues so
  /// the user checks those first instead of re-reading everything.
  final double confidence;

  final String? speaker;

  Duration get duration => end - start;
  bool get isUncertain => confidence < 0.75;

  SubtitleCue copyWith({
    Duration? start,
    Duration? end,
    String? text,
    double? confidence,
    String? speaker,
  }) => SubtitleCue(
    start: start ?? this.start,
    end: end ?? this.end,
    text: text ?? this.text,
    confidence: confidence ?? this.confidence,
    speaker: speaker ?? this.speaker,
  );

  Map<String, dynamic> toJson() => {
    'startUs': start.inMicroseconds,
    'endUs': end.inMicroseconds,
    'text': text,
    'confidence': confidence,
    if (speaker != null) 'speaker': speaker,
  };

  factory SubtitleCue.fromJson(Map<String, dynamic> json) => SubtitleCue(
    start: Duration(microseconds: (json['startUs'] as num?)?.toInt() ?? 0),
    end: Duration(microseconds: (json['endUs'] as num?)?.toInt() ?? 0),
    text: json['text'] as String? ?? '',
    confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    speaker: json['speaker'] as String?,
  );
}

@immutable
class SubtitleTrack {
  const SubtitleTrack({
    required this.cues,
    this.language = 'en',
    this.isMachineGenerated = true,
  });

  final List<SubtitleCue> cues;
  final String language;

  /// Always true for auto-caption output. Surfaced in the UI so the user knows
  /// the text has not been proofread.
  final bool isMachineGenerated;

  bool get isEmpty => cues.isEmpty;
  Duration get duration => cues.isEmpty ? Duration.zero : cues.last.end;

  /// Splits cues so none exceeds [maxCharacters], breaking on word boundaries
  /// and dividing the time proportionally. Long single cues are unreadable on
  /// a phone screen.
  SubtitleTrack wrapped({int maxCharacters = 42}) {
    final out = <SubtitleCue>[];
    for (final cue in cues) {
      if (cue.text.length <= maxCharacters) {
        out.add(cue);
        continue;
      }
      final words = cue.text.split(RegExp(r'\s+'));
      final chunks = <String>[];
      var current = StringBuffer();
      for (final word in words) {
        if (current.isEmpty) {
          current.write(word);
        } else if (current.length + 1 + word.length <= maxCharacters) {
          current.write(' $word');
        } else {
          chunks.add(current.toString());
          current = StringBuffer(word);
        }
      }
      if (current.isNotEmpty) chunks.add(current.toString());

      final totalChars = chunks.fold<int>(0, (s, c) => s + c.length);
      var cursor = cue.start;
      for (final chunk in chunks) {
        final share = totalChars == 0 ? 0.0 : chunk.length / totalChars;
        final slice = Duration(
          microseconds: (cue.duration.inMicroseconds * share).round(),
        );
        out.add(
          cue.copyWith(start: cursor, end: cursor + slice, text: chunk),
        );
        cursor += slice;
      }
    }
    return SubtitleTrack(
      cues: out,
      language: language,
      isMachineGenerated: isMachineGenerated,
    );
  }

  /// Standard SRT, for exporting captions as a sidecar file.
  String toSrt() {
    final buffer = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      buffer
        ..writeln(i + 1)
        ..writeln('${_srtTime(cue.start)} --> ${_srtTime(cue.end)}')
        ..writeln(cue.text)
        ..writeln();
    }
    return buffer.toString();
  }

  static String _srtTime(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = d.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$h:$m:$s,$ms';
  }

  Map<String, dynamic> toJson() => {
    'cues': cues.map((c) => c.toJson()).toList(),
    'language': language,
    'machine': isMachineGenerated,
  };

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) => SubtitleTrack(
    cues: ((json['cues'] as List?) ?? const [])
        .map((e) => SubtitleCue.fromJson((e as Map).cast<String, dynamic>()))
        .toList(),
    language: json['language'] as String? ?? 'en',
    isMachineGenerated: json['machine'] as bool? ?? true,
  );
}
