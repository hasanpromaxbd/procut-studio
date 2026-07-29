/// Title creation and styling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/entities/clip.dart';
import '../../../../domain/entities/text_style_spec.dart';
import '../../../viewmodels/editor_controller.dart';
import '../../../widgets/common/glass_panel.dart';

class TextSheet extends ConsumerStatefulWidget {
  const TextSheet({required this.projectId, super.key});

  final String projectId;

  @override
  ConsumerState<TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends ConsumerState<TextSheet> {
  late final TextEditingController _text;
  TextStyleSpec _style = const TextStyleSpec();
  TextAnimation _animationIn = TextAnimation.fadeIn;
  String? _editingClipId;

  /// A curated shortlist. The full Google Fonts catalogue (1500+ families) is
  /// reachable through "More fonts" — showing all of them up front is a wall
  /// of names nobody reads.
  static const List<String> _featuredFonts = [
    'Inter',
    'Montserrat',
    'Bebas Neue',
    'Playfair Display',
    'Oswald',
    'Poppins',
    'Anton',
    'Lobster',
    'Roboto Mono',
    'Caveat',
    'Archivo Black',
    'DM Serif Display',
  ];

  static const List<int> _swatches = [
    0xFFFFFFFF,
    0xFF000000,
    0xFF7C5CFF,
    0xFF00E5C0,
    0xFFFF4D6D,
    0xFFFFB020,
    0xFF4DA3FF,
    0xFF2ED573,
  ];

  @override
  void initState() {
    super.initState();
    final editor = ref.read(editorControllerProvider(widget.projectId));
    final selectedId = editor?.selectedClipId;
    final found = selectedId == null
        ? null
        : editor!.timeline.findClip(selectedId);
    final clip = found?.$2;

    // Editing an existing title rather than making a new one.
    if (clip is TextClip) {
      _editingClipId = clip.id;
      _text = TextEditingController(text: clip.text);
      _style = clip.style;
      _animationIn = clip.animationIn;
    } else {
      _text = TextEditingController();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(
      editorControllerProvider(widget.projectId).notifier,
    );
    final theme = Theme.of(context);

    return ToolSheet(
      title: _editingClipId == null ? 'Add text' : 'Edit text',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Preview(text: _text.text, style: _style),
          const SizedBox(height: Spacing.lg),
          TextField(
            controller: _text,
            autofocus: _editingClipId == null,
            maxLines: 3,
            minLines: 1,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Your text',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),

          const SectionHeader(title: 'Font'),
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _featuredFonts.length,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, index) {
                final family = _featuredFonts[index];
                final selected = _style.fontFamily == family;
                return ChoiceChip(
                  selected: selected,
                  label: Text(
                    family,
                    style: _safeFont(family, theme.textTheme.bodyMedium),
                  ),
                  onSelected: (_) =>
                      setState(() => _style = _style.copyWith(fontFamily: family)),
                );
              },
            ),
          ),

          const SectionHeader(title: 'Colour'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final colour in _swatches)
                _Swatch(
                  colour: Color(colour),
                  selected: _style.color == colour && !_style.hasGradient,
                  onTap: () => setState(
                    () => _style = _style.copyWith(
                      color: colour,
                      gradientColors: const [],
                    ),
                  ),
                ),
              _Swatch(
                gradient: AppColors.brandGradient,
                selected: _style.hasGradient,
                onTap: () => setState(
                  () => _style = _style.copyWith(
                    gradientColors: const [0xFF7C5CFF, 0xFF00E5C0],
                  ),
                ),
              ),
            ],
          ),

          const SectionHeader(title: 'Style'),
          LabeledSlider(
            label: 'Size',
            value: _style.fontSize,
            min: 0.02,
            max: 0.2,
            formatter: (v) => '${(v * 100).toStringAsFixed(1)}%',
            onChanged: (v) => setState(() => _style = _style.copyWith(fontSize: v)),
          ),
          LabeledSlider(
            label: 'Outline',
            value: _style.strokeWidth,
            min: 0,
            max: 0.25,
            formatter: (v) => v < 0.001 ? 'Off' : v.toStringAsFixed(2),
            onChanged: (v) =>
                setState(() => _style = _style.copyWith(strokeWidth: v)),
          ),
          LabeledSlider(
            label: 'Glow',
            value: _style.glowRadius,
            min: 0,
            max: 0.4,
            formatter: (v) => v < 0.001 ? 'Off' : v.toStringAsFixed(2),
            onChanged: (v) =>
                setState(() => _style = _style.copyWith(glowRadius: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Drop shadow'),
            value: _style.shadow.isVisible,
            onChanged: (on) => setState(
              () => _style = _style.copyWith(
                shadow: on ? const TextShadowSpec() : TextShadowSpec.none,
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('All caps'),
            value: _style.allCaps,
            onChanged: (on) =>
                setState(() => _style = _style.copyWith(allCaps: on)),
          ),

          const SectionHeader(title: 'Animation'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final animation in TextAnimation.values)
                ChoiceChip(
                  label: Text(_animationLabel(animation)),
                  selected: _animationIn == animation,
                  onSelected: (_) => setState(() => _animationIn = animation),
                ),
            ],
          ),

          const SizedBox(height: Spacing.xl),
          GradientButton(
            label: _editingClipId == null ? 'Add title' : 'Save changes',
            icon: Icons.check_rounded,
            expand: true,
            onPressed: _text.text.trim().isEmpty
                ? null
                : () {
                    if (_editingClipId == null) {
                      controller.addTextLayer(_text.text, style: _style);
                      // Apply the chosen entry animation to the clip we just
                      // created — addTextLayer selects it for us.
                      final id = ref
                          .read(editorControllerProvider(widget.projectId))
                          ?.selectedClipId;
                      if (id != null) {
                        controller.updateTextClip(
                          id,
                          animationIn: _animationIn,
                        );
                      }
                    } else {
                      controller.updateTextClip(
                        _editingClipId!,
                        text: _text.text,
                        style: _style,
                        animationIn: _animationIn,
                      );
                    }
                    Navigator.of(context).pop();
                  },
          ),
        ],
      ),
    );
  }

  static TextStyle? _safeFont(String family, TextStyle? base) {
    try {
      return GoogleFonts.getFont(family, textStyle: base);
    } catch (_) {
      // Family not in the manifest, or offline with nothing cached.
      return base;
    }
  }

  static String _animationLabel(TextAnimation animation) => switch (animation) {
    TextAnimation.none => 'None',
    TextAnimation.fadeIn => 'Fade',
    TextAnimation.slideUp => 'Slide up',
    TextAnimation.slideDown => 'Slide down',
    TextAnimation.popIn => 'Pop',
    TextAnimation.typewriter => 'Typewriter',
    TextAnimation.wordByWord => 'Word by word',
    TextAnimation.bounce => 'Bounce',
    TextAnimation.glitchIn => 'Glitch',
    TextAnimation.wipe => 'Wipe',
    TextAnimation.neonFlicker => 'Neon',
  };
}

class _Preview extends StatelessWidget {
  const _Preview({required this.text, required this.style});

  final String text;
  final TextStyleSpec style;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Spacing.sm),
      child: Text(
        text.isEmpty
            ? 'Preview'
            : (style.allCaps ? text.toUpperCase() : text),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: _TextSheetState._safeFont(
          style.fontFamily,
          TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: style.hasGradient ? null : Color(style.color),
            letterSpacing: style.letterSpacing * 28,
            foreground: style.hasGradient
                ? (Paint()
                    ..shader = LinearGradient(
                      colors: style.gradientColors.map(Color.new).toList(),
                    ).createShader(const Rect.fromLTWH(0, 0, 240, 40)))
                : null,
            shadows: style.shadow.isVisible
                ? [
                    Shadow(
                      color: Color(style.shadow.color),
                      offset: const Offset(1.5, 2),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.onTap,
    this.colour,
    this.gradient,
  });

  final Color? colour;
  final Gradient? gradient;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: colour,
          gradient: gradient,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}
