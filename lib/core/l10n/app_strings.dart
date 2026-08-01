/// The app's user-facing strings, in English and Bengali.
///
/// ## Why not gen_l10n
///
/// A typed abstract class does the one thing ARB tooling cannot: the compiler
/// itself proves both languages implement every string. A missing Bengali
/// translation is a build error here, not a silent English fallback at
/// runtime. No codegen step, no stale generated files, and a translation
/// review is one readable file.
///
/// ## Bengali conventions
///
/// - Editing terms of art (clip, track, keyframe, export) stay in English
///   script where a Bengali coinage would be *less* clear to a Bengali
///   editor — the same call CapCut's and Premiere's bn communities make.
/// - Bengali numerals are not used; timecodes and counts stay Western Arabic
///   to match the ruler and every number the engine prints.
/// - No Hindi/Devanagari. Everything below is Bengali script or Latin.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../di/providers.dart';

/// Every string surface the UI reads. Both languages must implement all of
/// it — that constraint is the point.
abstract class AppStrings {
  const AppStrings();

  Locale get locale;

  // ── Home ─────────────────────────────────────────────────────────────
  String get newProject;
  String get projects;
  String get templates;
  String get noProjectsYet;
  String get deleteProject;
  String get deleteProjectWarning;
  String get cancel;
  String get delete;
  String get rename;
  String get duplicateAction;

  // ── Editor chrome ────────────────────────────────────────────────────
  String get undo;
  String get redo;
  String get history;
  String get export;
  String get compositionGuides;
  String get scopes;
  String get reframe;
  String get saveAsTemplate;
  String get projectName;
  String get save;

  // ── Tool rail ────────────────────────────────────────────────────────
  String get toolMedia;
  String get toolSplit;
  String get toolSpeed;
  String get toolEffects;
  String get toolTransition;
  String get toolText;
  String get toolRecord;
  String get toolAi;
  String get toolMask;
  String get toolMarker;
  String get toolCopy;
  String get toolPaste;
  String get toolRotate;
  String get toolFlip;
  String get toolFreeze;
  String get toolReverse;
  String get toolTrim;
  String get toolMotion;
  String get toolBeats;
  String get toolMixer;
  String get toolTrack;
  String get toolDelete;
  String get toolDuplicate;
  String get toolJumpCut;
  String get toolGroup;
  String get toolLayout;
  String get toolCaptions;

  /// The media *manager*, distinct from the import button.
  String get toolMedia2;
  String get toolCurves;
  String get toolChapters;
  String get toolAudioDetail;
  String get toolMulticam;
  String get toolPrerender;

  // ── Export ───────────────────────────────────────────────────────────
  String get startExport;
  String get addToQueue;
  String get exportQueue;
  String get clearFinished;
  String get exportComplete;
  String get exportFailed;
  String get saveToGallery;
  String get share;

  // ── Settings ─────────────────────────────────────────────────────────
  String get settings;
  String get appearance;
  String get language;
  String get languageSystem;
  String get aiServer;
  String get storage;
  String get diagnostics;
  String get recentLogs;
  String get crashReports;
  String get crashReportsBlurb;
  String get about;

  // ── Common ───────────────────────────────────────────────────────────
  String get selectClipFirst;
  String get done;
  String get apply;

  String clipCount(int n);
}

class AppStringsEn extends AppStrings {
  const AppStringsEn();

  @override
  Locale get locale => const Locale('en');

  @override
  String get newProject => 'New project';
  @override
  String get projects => 'Projects';
  @override
  String get templates => 'Templates';
  @override
  String get noProjectsYet => 'Nothing here yet — start your first edit.';
  @override
  String get deleteProject => 'Delete project';
  @override
  String get deleteProjectWarning =>
      'The project and its edits are removed. Imported media stays on your '
      'device.';
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get rename => 'Rename';
  @override
  String get duplicateAction => 'Duplicate';

  @override
  String get undo => 'Undo';
  @override
  String get redo => 'Redo';
  @override
  String get history => 'Edit history';
  @override
  String get export => 'Export';
  @override
  String get compositionGuides => 'Composition guides';
  @override
  String get scopes => 'Scopes';
  @override
  String get reframe => 'Reframe for another aspect';
  @override
  String get saveAsTemplate => 'Save as template';
  @override
  String get projectName => 'Project name';
  @override
  String get save => 'Save';

  @override
  String get toolMedia => 'Media';
  @override
  String get toolSplit => 'Split';
  @override
  String get toolSpeed => 'Speed';
  @override
  String get toolEffects => 'Effects';
  @override
  String get toolTransition => 'Transition';
  @override
  String get toolText => 'Text';
  @override
  String get toolRecord => 'Record';
  @override
  String get toolAi => 'AI';
  @override
  String get toolMask => 'Mask';
  @override
  String get toolMarker => 'Marker';
  @override
  String get toolCopy => 'Copy';
  @override
  String get toolPaste => 'Paste';
  @override
  String get toolRotate => 'Rotate';
  @override
  String get toolFlip => 'Flip';
  @override
  String get toolFreeze => 'Freeze';
  @override
  String get toolReverse => 'Reverse';
  @override
  String get toolTrim => 'Trim';
  @override
  String get toolMotion => 'Motion';
  @override
  String get toolBeats => 'Beats';
  @override
  String get toolMixer => 'Mixer';
  @override
  String get toolTrack => 'Track';
  @override
  String get toolDelete => 'Delete';
  @override
  String get toolDuplicate => 'Duplicate';
  @override
  String get toolJumpCut => 'Jump cut';
  @override
  String get toolGroup => 'Group';
  @override
  String get toolLayout => 'Layout';
  @override
  String get toolCaptions => 'Captions';
  @override
  String get toolMedia2 => 'Manage';
  @override
  String get toolCurves => 'Curves';
  @override
  String get toolChapters => 'Chapters';
  @override
  String get toolAudioDetail => 'Audio';
  @override
  String get toolMulticam => 'Multicam';
  @override
  String get toolPrerender => 'Smooth';

  @override
  String get startExport => 'Start export';
  @override
  String get addToQueue => 'Add to the export queue';
  @override
  String get exportQueue => 'Export queue';
  @override
  String get clearFinished => 'Clear finished';
  @override
  String get exportComplete => 'Export complete';
  @override
  String get exportFailed => 'Export failed';
  @override
  String get saveToGallery => 'Save to gallery';
  @override
  String get share => 'Share';

  @override
  String get settings => 'Settings';
  @override
  String get appearance => 'Appearance';
  @override
  String get language => 'Language';
  @override
  String get languageSystem => 'Follow the system';
  @override
  String get aiServer => 'AI server';
  @override
  String get storage => 'Storage';
  @override
  String get diagnostics => 'Diagnostics';
  @override
  String get recentLogs => 'Recent logs';
  @override
  String get crashReports => 'Crash reports';
  @override
  String get crashReportsBlurb =>
      'Stored on this device only — nothing is sent anywhere';
  @override
  String get about => 'About';

  @override
  String get selectClipFirst => 'Select a clip first.';
  @override
  String get done => 'Done';
  @override
  String get apply => 'Apply';

  @override
  String clipCount(int n) => n == 1 ? '1 clip' : '$n clips';
}

class AppStringsBn extends AppStrings {
  const AppStringsBn();

  @override
  Locale get locale => const Locale('bn');

  @override
  String get newProject => 'নতুন প্রজেক্ট';
  @override
  String get projects => 'প্রজেক্টসমূহ';
  @override
  String get templates => 'টেমপ্লেট';
  @override
  String get noProjectsYet => 'এখনো কিছু নেই — প্রথম এডিট শুরু করুন।';
  @override
  String get deleteProject => 'প্রজেক্ট মুছুন';
  @override
  String get deleteProjectWarning =>
      'প্রজেক্ট ও তার সব এডিট মুছে যাবে। ইমপোর্ট করা মিডিয়া ডিভাইসেই থাকবে।';
  @override
  String get cancel => 'বাতিল';
  @override
  String get delete => 'মুছুন';
  @override
  String get rename => 'নাম বদলান';
  @override
  String get duplicateAction => 'কপি করুন';

  @override
  String get undo => 'আনডু';
  @override
  String get redo => 'রিডু';
  @override
  String get history => 'এডিট হিস্ট্রি';
  @override
  String get export => 'এক্সপোর্ট';
  @override
  String get compositionGuides => 'কম্পোজিশন গাইড';
  @override
  String get scopes => 'স্কোপ';
  @override
  String get reframe => 'অন্য অনুপাতে রিফ্রেম';
  @override
  String get saveAsTemplate => 'টেমপ্লেট হিসেবে সংরক্ষণ';
  @override
  String get projectName => 'প্রজেক্টের নাম';
  @override
  String get save => 'সংরক্ষণ';

  @override
  String get toolMedia => 'মিডিয়া';
  @override
  String get toolSplit => 'কাটুন';
  @override
  String get toolSpeed => 'গতি';
  @override
  String get toolEffects => 'ইফেক্ট';
  @override
  String get toolTransition => 'ট্রানজিশন';
  @override
  String get toolText => 'টেক্সট';
  @override
  String get toolRecord => 'রেকর্ড';
  @override
  String get toolAi => 'AI';
  @override
  String get toolMask => 'মাস্ক';
  @override
  String get toolMarker => 'মার্কার';
  @override
  String get toolCopy => 'কপি';
  @override
  String get toolPaste => 'পেস্ট';
  @override
  String get toolRotate => 'ঘোরান';
  @override
  String get toolFlip => 'উল্টান';
  @override
  String get toolFreeze => 'ফ্রিজ';
  @override
  String get toolReverse => 'রিভার্স';
  @override
  String get toolTrim => 'ট্রিম';
  @override
  String get toolMotion => 'মোশন';
  @override
  String get toolBeats => 'বিট';
  @override
  String get toolMixer => 'মিক্সার';
  @override
  String get toolTrack => 'ট্র্যাক';
  @override
  String get toolDelete => 'মুছুন';
  @override
  String get toolDuplicate => 'ডুপ্লিকেট';
  @override
  String get toolJumpCut => 'জাম্প কাট';
  @override
  String get toolGroup => 'গ্রুপ';
  @override
  String get toolLayout => 'লেআউট';
  @override
  String get toolCaptions => 'ক্যাপশন';
  @override
  String get toolMedia2 => 'ম্যানেজ';
  @override
  String get toolCurves => 'কার্ভ';
  @override
  String get toolChapters => 'চ্যাপ্টার';
  @override
  String get toolAudioDetail => 'অডিও';
  @override
  String get toolMulticam => 'মাল্টিক্যাম';
  @override
  String get toolPrerender => 'স্মুথ';

  @override
  String get startExport => 'এক্সপোর্ট শুরু করুন';
  @override
  String get addToQueue => 'এক্সপোর্ট কিউতে যোগ করুন';
  @override
  String get exportQueue => 'এক্সপোর্ট কিউ';
  @override
  String get clearFinished => 'শেষ হওয়াগুলো সরান';
  @override
  String get exportComplete => 'এক্সপোর্ট সম্পন্ন';
  @override
  String get exportFailed => 'এক্সপোর্ট ব্যর্থ';
  @override
  String get saveToGallery => 'গ্যালারিতে সংরক্ষণ';
  @override
  String get share => 'শেয়ার';

  @override
  String get settings => 'সেটিংস';
  @override
  String get appearance => 'চেহারা';
  @override
  String get language => 'ভাষা';
  @override
  String get languageSystem => 'সিস্টেম অনুযায়ী';
  @override
  String get aiServer => 'AI সার্ভার';
  @override
  String get storage => 'স্টোরেজ';
  @override
  String get diagnostics => 'ডায়াগনস্টিকস';
  @override
  String get recentLogs => 'সাম্প্রতিক লগ';
  @override
  String get crashReports => 'ক্র্যাশ রিপোর্ট';
  @override
  String get crashReportsBlurb =>
      'শুধু এই ডিভাইসে থাকে — কোথাও পাঠানো হয় না';
  @override
  String get about => 'সম্পর্কে';

  @override
  String get selectClipFirst => 'আগে একটা ক্লিপ সিলেক্ট করুন।';
  @override
  String get done => 'হয়ে গেছে';
  @override
  String get apply => 'প্রয়োগ করুন';

  @override
  String clipCount(int n) => n == 1 ? '১টি ক্লিপ' : '$nটি ক্লিপ';
}

/// The user's choice: a fixed language, or null to follow the system.
final localeOverrideProvider =
    NotifierProvider<LocaleOverrideController, Locale?>(
      LocaleOverrideController.new,
    );

class LocaleOverrideController extends Notifier<Locale?> {
  static const key = 'locale';

  @override
  Locale? build() {
    final stored = ref.read(hiveStoreProvider).settings.get(key);
    return stored == null || stored.isEmpty ? null : Locale(stored);
  }

  void set(Locale? locale) {
    state = locale;
    // Fire-and-forget: losing a language preference to a crash costs one tap.
    unawaited(
      ref.read(hiveStoreProvider).settings.put(key, locale?.languageCode ?? ''),
    );
  }
}

/// Resolves the strings for the active locale. Bengali only when asked for or
/// when the device itself is Bengali — everything else gets English.
final stringsProvider = Provider<AppStrings>((ref) {
  final override = ref.watch(localeOverrideProvider);
  final locale =
      override ?? WidgetsBinding.instance.platformDispatcher.locale;
  return locale.languageCode == 'bn'
      ? const AppStringsBn()
      : const AppStringsEn();
});
