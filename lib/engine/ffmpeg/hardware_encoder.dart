/// Decides whether to use Android's MediaCodec hardware encoders.
///
/// Hardware encoding is 5–20× faster than libx264 on a phone, which is the
/// difference between a 40-second export and a 10-minute one. It is also the
/// least reliable part of the Android media stack: encoders advertise support
/// they do not have, reject odd dimensions, and fail differently per vendor.
///
/// The policy here is: probe once, cache, prefer hardware, and let the export
/// engine fall back to software automatically on failure.
library;

import 'dart:io';

import '../../core/logging/app_logger.dart';
import '../../domain/entities/export_settings.dart';
import 'ffmpeg_service.dart';

class EncoderChoice {
  const EncoderChoice({
    required this.encoderName,
    required this.isHardware,
    required this.codec,
  });

  final String encoderName;
  final bool isHardware;
  final VideoCodec codec;

  @override
  String toString() =>
      '$encoderName (${isHardware ? 'hardware' : 'software'})';
}

class HardwareEncoderProbe {
  HardwareEncoderProbe(this._ffmpeg);

  final FFmpegService _ffmpeg;
  static const _log = Log('HardwareEncoder');

  Set<String>? _available;

  /// Encoder names the bundled FFmpeg build actually exposes.
  Future<Set<String>> availableEncoders() async {
    if (_available != null) return _available!;
    if (!Platform.isAndroid) return _available = const {};

    final result = await _ffmpeg.run('-hide_banner -encoders', queued: false);
    final names = <String>{};
    result.fold(
      (output) {
        // Lines look like: " V....D h264_mediacodec       H.264 ..."
        final pattern = RegExp(r'^\s*[VAS][\w.]{5}\s+(\S+)', multiLine: true);
        for (final match in pattern.allMatches(output.logTail)) {
          final name = match.group(1);
          if (name != null) names.add(name);
        }
      },
      (failure) => _log.w('encoder probe failed: ${failure.message}'),
    );

    // The `-encoders` output goes to stdout, which FFmpegKit does not always
    // route into the log callback. If we learned nothing, assume the standard
    // MediaCodec set is present rather than disabling hardware everywhere —
    // a failed encode falls back anyway.
    if (names.isEmpty) {
      _log.d('encoder list empty; assuming default MediaCodec set');
      return _available = const {
        'h264_mediacodec',
        'hevc_mediacodec',
        'libx264',
        'libx265',
      };
    }
    _log.i('encoders discovered', fields: {'count': names.length});
    return _available = names;
  }

  /// Picks an encoder for [settings], honouring the user's preference but
  /// refusing combinations known not to work.
  Future<EncoderChoice> choose(
    ExportSettings settings, {
    required int width,
    required int height,
    bool forceSoftware = false,
  }) async {
    final codec = settings.videoCodec;
    final software = EncoderChoice(
      encoderName: codec.softwareEncoder,
      isHardware: false,
      codec: codec,
    );

    if (forceSoftware || !settings.useHardwareEncoder) return software;
    if (!Platform.isAndroid) return software;

    final encoders = await availableEncoders();
    if (!encoders.contains(codec.hardwareEncoder)) {
      _log.d('${codec.hardwareEncoder} unavailable; using software');
      return software;
    }

    // MediaCodec requires even dimensions on every device and, in practice,
    // multiples of 16 on a number of older SoCs. We only enforce the even
    // rule; the export engine already rounds to even.
    if (width.isOdd || height.isOdd) {
      _log.d('odd dimensions ${width}x$height; using software');
      return software;
    }

    // Very small frames often fail on hardware paths and are fast in software
    // anyway, so there is nothing to gain by risking it.
    if (width < 128 || height < 128) return software;

    return EncoderChoice(
      encoderName: codec.hardwareEncoder,
      isHardware: true,
      codec: codec,
    );
  }

  /// Encoder-specific rate-control flags.
  ///
  /// CRF is a libx264/libx265 concept — MediaCodec has no equivalent, so a
  /// quality-mode export on hardware is translated to a target bitrate.
  List<String> rateControlArgs(
    EncoderChoice choice,
    ExportSettings settings, {
    required int width,
    required int height,
  }) {
    if (choice.isHardware) {
      final kbps = settings.effectiveVideoBitrateKbps(width, height);
      return ['-b:v', '${kbps}k', '-maxrate', '${(kbps * 1.5).round()}k'];
    }
    if (settings.bitrateMode == BitrateMode.custom) {
      final kbps = settings.customVideoBitrateKbps;
      return [
        '-b:v', '${kbps}k',
        '-maxrate', '${(kbps * 1.45).round()}k',
        '-bufsize', '${kbps * 2}k',
      ];
    }
    return ['-crf', '${settings.quality.crf}'];
  }

  /// Speed/efficiency preset. Only meaningful for the software encoders.
  ///
  /// `veryfast` is the right default on a phone: `medium` roughly doubles the
  /// export time for a few percent of bitrate, which nobody notices on a
  /// social upload but everybody notices as a progress bar.
  List<String> presetArgs(EncoderChoice choice) => choice.isHardware
      ? const []
      : ['-preset', 'veryfast'];
}
