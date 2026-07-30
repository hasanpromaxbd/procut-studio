/// The Bengali translation, held to the standard a compiler cannot enforce.
///
/// The abstract class already guarantees every key exists in both languages.
/// What it cannot guarantee: that the Bengali is actually Bengali (no
/// Devanagari — the classic model-assisted slip), that translated keys were
/// actually translated rather than pasted, and that pluralisation works.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:procut_studio/core/l10n/app_strings.dart';

/// Every string accessor, so a new key added to the class must be added here
/// too — the analyzer cannot enumerate getters, but a reviewer diffing this
/// list against the class can.
final List<(String, String Function(AppStrings))> _accessors = [
  ('newProject', (s) => s.newProject),
  ('projects', (s) => s.projects),
  ('templates', (s) => s.templates),
  ('noProjectsYet', (s) => s.noProjectsYet),
  ('deleteProject', (s) => s.deleteProject),
  ('deleteProjectWarning', (s) => s.deleteProjectWarning),
  ('cancel', (s) => s.cancel),
  ('delete', (s) => s.delete),
  ('rename', (s) => s.rename),
  ('duplicateAction', (s) => s.duplicateAction),
  ('undo', (s) => s.undo),
  ('redo', (s) => s.redo),
  ('history', (s) => s.history),
  ('export', (s) => s.export),
  ('compositionGuides', (s) => s.compositionGuides),
  ('scopes', (s) => s.scopes),
  ('reframe', (s) => s.reframe),
  ('saveAsTemplate', (s) => s.saveAsTemplate),
  ('projectName', (s) => s.projectName),
  ('save', (s) => s.save),
  ('toolMedia', (s) => s.toolMedia),
  ('toolSplit', (s) => s.toolSplit),
  ('toolSpeed', (s) => s.toolSpeed),
  ('toolEffects', (s) => s.toolEffects),
  ('toolTransition', (s) => s.toolTransition),
  ('toolText', (s) => s.toolText),
  ('toolRecord', (s) => s.toolRecord),
  ('toolAi', (s) => s.toolAi),
  ('toolMask', (s) => s.toolMask),
  ('toolMarker', (s) => s.toolMarker),
  ('toolCopy', (s) => s.toolCopy),
  ('toolPaste', (s) => s.toolPaste),
  ('toolRotate', (s) => s.toolRotate),
  ('toolFlip', (s) => s.toolFlip),
  ('toolFreeze', (s) => s.toolFreeze),
  ('toolReverse', (s) => s.toolReverse),
  ('toolTrim', (s) => s.toolTrim),
  ('toolMotion', (s) => s.toolMotion),
  ('toolBeats', (s) => s.toolBeats),
  ('toolMixer', (s) => s.toolMixer),
  ('toolTrack', (s) => s.toolTrack),
  ('toolDelete', (s) => s.toolDelete),
  ('toolDuplicate', (s) => s.toolDuplicate),
  ('toolJumpCut', (s) => s.toolJumpCut),
  ('toolGroup', (s) => s.toolGroup),
  ('startExport', (s) => s.startExport),
  ('addToQueue', (s) => s.addToQueue),
  ('exportQueue', (s) => s.exportQueue),
  ('clearFinished', (s) => s.clearFinished),
  ('exportComplete', (s) => s.exportComplete),
  ('exportFailed', (s) => s.exportFailed),
  ('saveToGallery', (s) => s.saveToGallery),
  ('share', (s) => s.share),
  ('settings', (s) => s.settings),
  ('appearance', (s) => s.appearance),
  ('language', (s) => s.language),
  ('languageSystem', (s) => s.languageSystem),
  ('aiServer', (s) => s.aiServer),
  ('storage', (s) => s.storage),
  ('diagnostics', (s) => s.diagnostics),
  ('recentLogs', (s) => s.recentLogs),
  ('crashReports', (s) => s.crashReports),
  ('crashReportsBlurb', (s) => s.crashReportsBlurb),
  ('about', (s) => s.about),
  ('selectClipFirst', (s) => s.selectClipFirst),
  ('done', (s) => s.done),
  ('apply', (s) => s.apply),
];

const _en = AppStringsEn();
const _bn = AppStringsBn();

/// Keys deliberately identical in both languages: technical terms a Bengali
/// editor uses in English. Additions here need a reason, not just a shrug.
const _intentionallyShared = {'toolAi'};

void main() {
  test('no string is empty in either language', () {
    for (final (name, get) in _accessors) {
      expect(get(_en).trim(), isNotEmpty, reason: 'en $name');
      expect(get(_bn).trim(), isNotEmpty, reason: 'bn $name');
    }
  });

  test('the Bengali contains no Devanagari', () {
    // U+0900–U+097F is Devanagari (Hindi); Bengali is U+0980–U+09FF. A single
    // Devanagari *letter* means a Hindi word slipped in. The danda । (U+0964)
    // and double danda (U+0965) are excluded: Unicode files them under
    // Devanagari, but they are the correct sentence punctuation for Bengali
    // too — there is no separate Bengali danda.
    final devanagari = RegExp(r'[\u0900-\u0963\u0966-\u097F]');
    for (final (name, get) in _accessors) {
      expect(
        devanagari.hasMatch(get(_bn)),
        isFalse,
        reason: 'bn $name contains Devanagari: "${get(_bn)}"',
      );
    }
    expect(devanagari.hasMatch(_bn.clipCount(2)), isFalse);
  });

  test('every translated key actually contains Bengali script', () {
    final bengali = RegExp(r'[ঀ-৿]');
    for (final (name, get) in _accessors) {
      if (_intentionallyShared.contains(name)) continue;
      expect(
        bengali.hasMatch(get(_bn)),
        isTrue,
        reason:
            'bn $name has no Bengali script — untranslated copy-paste? '
            '"${get(_bn)}"',
      );
    }
  });

  test('translated keys differ from the English', () {
    for (final (name, get) in _accessors) {
      if (_intentionallyShared.contains(name)) continue;
      expect(get(_bn), isNot(get(_en)), reason: 'bn $name == en $name');
    }
  });

  test('pluralisation holds in both languages', () {
    expect(_en.clipCount(1), '1 clip');
    expect(_en.clipCount(3), '3 clips');
    expect(_bn.clipCount(1), contains('১'));
    expect(_bn.clipCount(3), contains('3'));
  });

  test('locales report themselves correctly', () {
    expect(_en.locale.languageCode, 'en');
    expect(_bn.locale.languageCode, 'bn');
  });
}
