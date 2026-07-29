/// App settings, storage management and diagnostics.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/di/providers.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/utils/time_utils.dart';
import '../../../data/datasources/remote/http_ai_backend.dart';
import '../../../domain/repositories/ai_repository.dart';
import '../../viewmodels/ai_settings_controller.dart';
import '../../widgets/common/glass_panel.dart';

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;
  void set(ThemeMode mode) => state = mode;
}

final cacheSizeProvider = FutureProvider<int>(
  (ref) async =>
      (await ref.watch(mediaRepositoryProvider).cacheSizeBytes()).getOrElse(0),
);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final cacheSize = ref.watch(cacheSizeProvider);
    final capabilities = ref.watch(aiCapabilitiesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        children: [
          const SectionHeader(title: 'Appearance'),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
            ],
            selected: {themeMode},
            onSelectionChanged: (selection) =>
                ref.read(themeModeProvider.notifier).set(selection.first),
          ),

          const SectionHeader(title: 'AI server'),
          const _AiBackendForm(),

          const SectionHeader(title: 'AI features'),
          capabilities.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text('$error'),
            data: (available) => Column(
              children: [
                for (final capability in AiCapability.values)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      available.contains(capability)
                          ? Icons.check_circle_rounded
                          : Icons.cloud_off_rounded,
                      color: available.contains(capability)
                          ? Theme.of(context).colorScheme.secondary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(capability.label),
                    subtitle: Text(
                      capability.requiresModel
                          ? (available.contains(capability)
                                ? 'Ready — using your configured backend'
                                : 'Needs an AI backend')
                          : 'Runs on this device',
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: Text(
                    'Captions, background removal and tracking need a neural '
                    'model. ProCut ships none, so these route to an inference '
                    'endpoint you configure. Everything else is signal '
                    'processing that runs locally.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SectionHeader(title: 'Storage'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cached_rounded),
            title: const Text('Cached thumbnails, waveforms and proxies'),
            subtitle: Text(
              cacheSize.when(
                loading: () => 'Measuring…',
                error: (_, _) => 'Unknown',
                data: TimeUtils.formatBytes,
              ),
            ),
            trailing: TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await ref.read(mediaRepositoryProvider).clearDerivedCache();
                ref.invalidate(cacheSizeProvider);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Cache cleared')),
                );
              },
              child: const Text('Clear'),
            ),
          ),
          Text(
            'Clearing is always safe — these files are regenerated on demand. '
            'Your projects and exports are untouched.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),

          const SectionHeader(title: 'Diagnostics'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.receipt_long_rounded),
            title: const Text('Recent logs'),
            subtitle: const Text('Useful when reporting a failed export'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const _LogScreen()),
            ),
          ),

          const SectionHeader(title: 'About'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text(AppConstants.appName),
            subtitle: const Text(
              'Project format v${AppConstants.projectSchemaVersion}',
            ),
          ),
          const SizedBox(height: Spacing.xxl),
        ],
      ),
    );
  }
}

/// Configures the inference endpoint the model-backed features use.
class _AiBackendForm extends ConsumerStatefulWidget {
  const _AiBackendForm();

  @override
  ConsumerState<_AiBackendForm> createState() => _AiBackendFormState();
}

class _AiBackendFormState extends ConsumerState<_AiBackendForm> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(aiSettingsProvider);
    _url = TextEditingController(text: settings.baseUrl);
    _key = TextEditingController(text: settings.apiKey);
    _model = TextEditingController(text: settings.transcriptionModel);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reachable = ref.watch(aiBackendReachableProvider);
    final configured = ref.watch(aiSettingsProvider).isConfigured;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Captions, background removal and tracking need a neural model. '
          'ProCut ships none — point this at an OpenAI-compatible server '
          '(faster-whisper, speaches, whisper.cpp) and they light up.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.md),
        TextField(
          controller: _url,
          onChanged: (_) => setState(() => _dirty = true),
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'http://192.168.1.10:8000/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        TextField(
          controller: _key,
          onChanged: (_) => setState(() => _dirty = true),
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'API key (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        TextField(
          controller: _model,
          onChanged: (_) => setState(() => _dirty = true),
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Transcription model',
            hintText: 'whisper-1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _dirty ? _save : null,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Save & test'),
              ),
            ),
            if (configured) ...[
              const SizedBox(width: Spacing.sm),
              TextButton(onPressed: _clear, child: const Text('Clear')),
            ],
          ],
        ),
        if (configured && !_dirty) ...[
          const SizedBox(height: Spacing.sm),
          reachable.when(
            loading: () => Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Spacing.sm),
                Text('Testing…', style: theme.textTheme.bodySmall),
              ],
            ),
            error: (_, _) => Text(
              'Could not reach the server',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            data: (ok) => Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_rounded : Icons.error_rounded,
                  size: 16,
                  color: ok
                      ? theme.colorScheme.secondary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    ok
                        ? 'Server reachable'
                        : 'Not reachable — check the address and that this '
                              'device is on the same network',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _save() async {
    await ref.read(aiSettingsControllerProvider).save(
          AiSettings(
            baseUrl: _url.text,
            apiKey: _key.text,
            transcriptionModel: _model.text.trim().isEmpty
                ? 'whisper-1'
                : _model.text.trim(),
          ),
        );
    if (mounted) setState(() => _dirty = false);
  }

  Future<void> _clear() async {
    await ref.read(aiSettingsControllerProvider).clear();
    if (!mounted) return;
    _url.clear();
    _key.clear();
    _model.text = 'whisper-1';
    setState(() => _dirty = false);
  }
}

class _LogScreen extends StatelessWidget {
  const _LogScreen();

  @override
  Widget build(BuildContext context) {
    final records = AppLogger.ringBuffer.records.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: 'Clear',
            onPressed: () {
              AppLogger.ringBuffer.clear();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: records.isEmpty
          ? const EmptyState(
              icon: Icons.inbox_rounded,
              title: 'Nothing logged yet',
              message: 'Logs appear here as you edit and export.',
            )
          : ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final record = records[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    '${record.scope}: ${record.message}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  subtitle: record.error == null
                      ? null
                      : Text(
                          '${record.error}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 11,
                          ),
                        ),
                  leading: Text(
                    record.level.tag,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: switch (record.level) {
                        LogLevel.error => Theme.of(context).colorScheme.error,
                        LogLevel.warning => Colors.orange,
                        _ => Theme.of(context).colorScheme.onSurfaceVariant,
                      },
                    ),
                  ),
                );
              },
            ),
    );
  }
}
