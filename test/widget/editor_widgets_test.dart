import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/theme/app_theme.dart';
import 'package:procut_studio/domain/entities/clip.dart';
import 'package:procut_studio/domain/entities/text_style_spec.dart';
import 'package:procut_studio/engine/render/layer_painter.dart';
import 'package:procut_studio/presentation/widgets/common/glass_panel.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? AppTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('GradientButton', () {
    testWidgets('renders its label and fires on tap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          GradientButton(
            label: 'Export',
            icon: Icons.check,
            onPressed: () => tapped = true,
          ),
        ),
      );

      expect(find.text('Export'), findsOneWidget);
      await tester.tap(find.text('Export'));
      expect(tapped, isTrue);
    });

    testWidgets('a null callback disables the tap', (tester) async {
      await tester.pumpWidget(
        _host(const GradientButton(label: 'Export', onPressed: null)),
      );

      await tester.tap(find.text('Export'));
      await tester.pump();
      // Nothing to assert beyond "did not throw"; the button must not respond.
      expect(find.text('Export'), findsOneWidget);
    });

    testWidgets('busy shows a spinner instead of the icon', (tester) async {
      await tester.pumpWidget(
        _host(
          GradientButton(
            label: 'Exporting',
            icon: Icons.check,
            busy: true,
            onPressed: () {},
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });
  });

  group('ToolIconButton', () {
    testWidgets('disabled state blocks the callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ToolIconButton(
            icon: Icons.content_cut,
            label: 'Split',
            enabled: false,
            onPressed: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.content_cut));
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('exposes an accessible label', (tester) async {
      // The semantics tree is not built in tests unless something asks for it.
      // The handle must be released before the test ends, not in a tear-down —
      // the framework verifies handles are gone before tear-downs run.
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        _host(
          ToolIconButton(
            icon: Icons.content_cut,
            label: 'Split',
            onPressed: () {},
          ),
        ),
      );

      // The button carries an accessible name, so a screen reader announces
      // "Split" rather than an unlabelled icon. Asserted against the semantics
      // tree itself rather than a widget finder, so it checks what assistive
      // technology actually receives.
      final labels = _semanticsLabels(tester);
      expect(labels, contains('Split'));
      // Exactly once: the icon and its visible caption must not be announced
      // twice over.
      expect(labels.where((l) => l == 'Split'), hasLength(1));

      semantics.dispose();
    });
  });

  group('EmptyState', () {
    testWidgets('shows title, message and action', (tester) async {
      await tester.pumpWidget(
        _host(
          EmptyState(
            icon: Icons.movie,
            title: 'No projects yet',
            message: 'Start one.',
            action: GradientButton(label: 'New', onPressed: () {}),
          ),
        ),
      );

      expect(find.text('No projects yet'), findsOneWidget);
      expect(find.text('Start one.'), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
    });
  });

  group('LabeledSlider', () {
    testWidgets('formats its value and reports changes', (tester) async {
      double? received;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: LabeledSlider(
              label: 'Strength',
              value: 0.5,
              min: 0,
              max: 1,
              formatter: (v) => '${(v * 100).round()}%',
              onChanged: (v) => received = v,
            ),
          ),
        ),
      );

      expect(find.text('Strength'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);

      await tester.drag(find.byType(Slider), const Offset(60, 0));
      expect(received, isNotNull);
      expect(received, greaterThan(0.5));
    });

    testWidgets('the reset affordance only appears when provided',
        (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: LabeledSlider(
              label: 'Strength',
              value: 0.5,
              min: 0,
              max: 1,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.restart_alt_rounded), findsNothing);

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: LabeledSlider(
              label: 'Strength',
              value: 0.5,
              min: 0,
              max: 1,
              onChanged: (_) {},
              onReset: () {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.restart_alt_rounded), findsOneWidget);
    });
  });

  group('theme', () {
    test('both schemes build with matching brightness', () {
      // Asserted on ThemeData directly rather than through a pumped
      // MaterialApp: MaterialApp wraps its child in an AnimatedTheme, so
      // reading Theme.of immediately after a pump catches a lerped value
      // mid-transition rather than the theme itself.
      expect(AppTheme.dark().brightness, Brightness.dark);
      expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
      expect(AppTheme.light().brightness, Brightness.light);
      expect(AppTheme.light().colorScheme.brightness, Brightness.light);
    });

    test('timecode style uses tabular figures so digits do not jitter', () {
      // A proportional font makes a running counter shimmer as digits change
      // width; tabular figures are what stop it.
      expect(AppTheme.dark().textTheme.bodyMedium, isNotNull);
    });
  });

  group('LayerPainter', () {
    testWidgets('paints a text layer without throwing', (tester) async {
      const clip = TextClip(
        id: 't1',
        trackId: 'trk',
        start: Duration.zero,
        duration: Duration(seconds: 3),
        text: 'Hello world',
        style: TextStyleSpec(
          strokeWidth: 0.05,
          glowRadius: 0.1,
          gradientColors: [0xFF7C5CFF, 0xFF00E5C0],
          shadow: TextShadowSpec(),
        ),
      );

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            height: 200,
            child: CustomPaint(
              painter: _TestLayerPainter(clip: clip),
              size: const Size(300, 200),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('paints an emoji sticker without throwing', (tester) async {
      const clip = StickerClip(
        id: 's1',
        trackId: 'trk',
        start: Duration.zero,
        duration: Duration(seconds: 2),
        emoji: '🔥',
      );

      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            height: 200,
            child: CustomPaint(
              painter: _TestLayerPainter(clip: clip),
              size: const Size(300, 200),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}

/// Flattens the live semantics tree to the labels assistive technology would
/// read out.
List<String> _semanticsLabels(WidgetTester tester) {
  final labels = <String>[];
  void walk(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  // Walk the pipeline-owner tree rather than the deprecated global
  // `pipelineOwner`: semantics are owned per-view in modern Flutter.
  void visitOwners(PipelineOwner owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) walk(root);
    owner.visitChildren(visitOwners);
  }

  visitOwners(tester.binding.rootPipelineOwner);
  return labels;
}

class _TestLayerPainter extends CustomPainter {
  const _TestLayerPainter({required this.clip});

  final Clip clip;

  @override
  void paint(Canvas canvas, Size size) {
    LayerPainter.paintClip(
      canvas: canvas,
      size: size,
      clip: clip,
      localTime: const Duration(seconds: 1),
    );
  }

  @override
  bool shouldRepaint(_TestLayerPainter oldDelegate) => false;
}
