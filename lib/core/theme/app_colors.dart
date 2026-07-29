/// ProCut Studio brand palette.
///
/// Original design language: cool "ink" neutrals so footage is judged against a
/// near-neutral surround, with a violet→cyan brand ramp reserved for
/// interactive affordances. Track colours are chosen to stay distinguishable
/// against both themes and to survive the most common colour-vision
/// deficiencies (they differ in lightness, not just hue).
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // ── Brand ────────────────────────────────────────────────────────────
  static const Color brandViolet = Color(0xFF7C5CFF);
  static const Color brandIndigo = Color(0xFF5B45E0);
  static const Color brandCyan = Color(0xFF00E5C0);
  static const Color brandRose = Color(0xFFFF4D6D);
  static const Color brandAmber = Color(0xFFFFB020);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandViolet, brandCyan],
  );

  static const LinearGradient dangerGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF4D6D), Color(0xFFFF8A3D)],
  );

  // ── Dark surfaces (the primary experience) ───────────────────────────
  static const Color inkBackground = Color(0xFF0A0B10);
  static const Color inkSurface = Color(0xFF12141C);
  static const Color inkSurfaceHigh = Color(0xFF1A1D27);
  static const Color inkSurfaceHigher = Color(0xFF232734);
  static const Color inkOutline = Color(0xFF2E3340);
  static const Color inkTextPrimary = Color(0xFFF2F4F8);
  static const Color inkTextSecondary = Color(0xFFA6ADBD);
  static const Color inkTextTertiary = Color(0xFF6B7285);

  // ── Light surfaces ───────────────────────────────────────────────────
  static const Color paperBackground = Color(0xFFF7F8FC);
  static const Color paperSurface = Color(0xFFFFFFFF);
  static const Color paperSurfaceHigh = Color(0xFFF0F2F8);
  static const Color paperOutline = Color(0xFFD9DEEA);
  static const Color paperTextPrimary = Color(0xFF11131A);
  static const Color paperTextSecondary = Color(0xFF505769);
  static const Color paperTextTertiary = Color(0xFF858DA0);

  // ── Timeline track identity ──────────────────────────────────────────
  /// Video tracks: cool blue-violet, the "primary picture" channel.
  static const Color trackVideo = Color(0xFF6C8CFF);

  /// Audio tracks: green, conventionally the waveform colour.
  static const Color trackAudio = Color(0xFF2ED573);

  /// Text layers: amber — high contrast against both video and audio.
  static const Color trackText = Color(0xFFFFB020);

  /// Image/overlay layers.
  static const Color trackOverlay = Color(0xFF00C2D1);

  /// Sticker layers.
  static const Color trackSticker = Color(0xFFFF6BAA);

  /// Effect-only (adjustment) tracks.
  static const Color trackEffect = Color(0xFFB47CFF);

  // ── Timeline chrome ──────────────────────────────────────────────────
  static const Color playhead = Color(0xFFFF3B5C);
  static const Color snapGuide = Color(0xFF00E5C0);
  static const Color selectionRing = Color(0xFFFFFFFF);
  static const Color keyframeDiamond = Color(0xFFFFD166);
  static const Color waveform = Color(0xFF9BE8C0);

  // ── Semantic ─────────────────────────────────────────────────────────
  static const Color success = Color(0xFF2ED573);
  static const Color warning = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF4D6D);
  static const Color info = Color(0xFF4DA3FF);

  const AppColors._();
}
