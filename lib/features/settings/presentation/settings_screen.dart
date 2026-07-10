import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/import_export/export/export_providers.dart';
import 'package:watch_nook/core/import_export/export/import_export_service.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';
import 'package:watch_nook/core/widgets/attribution_footer.dart';
import 'package:watch_nook/features/library/data/tracked_show_sync.dart';
import 'package:watch_nook/features/onboarding/presentation/onboarding_provider.dart';
import 'package:watch_nook/features/settings/data/export_share.dart';
import 'package:watch_nook/features/settings/data/theme_mode_provider.dart';

/// ponytail: one string beats a `package_info_plus` dependency and a platform
/// channel. Swap it in if this ever drifts from `pubspec.yaml`'s `version:`.
const appVersion = '0.1.0';

/// Settings (#35, US-14): appearance, the data you own, and the **mandatory**
/// metadata attribution. Pushed route `/settings` off the shell app bar.
///
/// Everything here reads or writes the user's own data — there is no account to
/// manage, nothing to sign in to, and no setting that leaves the device.
class SettingsScreen extends ConsumerWidget {
  /// Creates the [SettingsScreen].
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          const _ThemeModePicker(),
          const _SectionHeader('Your data'),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import…'),
            subtitle: const Text(
              'Bring your history across from TV Time, Trakt, IMDb or '
              'Letterboxd.',
            ),
            onTap: () => context.push('/import'),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Refresh library'),
            subtitle: const Text(
              'Update episode counts and next episodes for your shows.',
            ),
            onTap: () => _refreshLibrary(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export JSON'),
            subtitle: const Text('Everything you track, in one file.'),
            onTap: () => _export(
              context,
              ref,
              fileName: 'watchnook-export.json',
              mimeType: 'application/json',
              build: (service) => service.exportJson(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Export Letterboxd CSV'),
            subtitle: const Text('Your watched films, ready for Letterboxd.'),
            onTap: () => _export(
              context,
              ref,
              fileName: 'watchnook-letterboxd.csv',
              mimeType: 'text/csv',
              build: (service) => service.exportLetterboxdCsv(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Back up now'),
            subtitle: const Text(
              'Refresh the file Android Auto Backup uploads.',
            ),
            onTap: () => _backUpNow(context, ref),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              'Delete all data',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            subtitle: const Text(
              'Erase your library, watch history, cache and backup. This '
              'cannot be undone.',
            ),
            onTap: () => _deleteAll(context, ref),
          ),
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Watchnook'),
            subtitle: Text('Version $appVersion'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: WatchnookSpacing.screen,
              vertical: WatchnookSpacing.sm,
            ),
            child: Text(
              'No account, no cloud, no ads. Everything you track stays on '
              'this device.',
            ),
          ),
          const AttributionFooter(),
        ],
      ),
    );
  }
}

/// System / Light / Dark / Dynamic. "Dynamic" is Material You — the palette is
/// sourced from the wallpaper on Android 12+, falling back to the Honey brand
/// scheme where the platform supplies no dynamic colours (#51).
class _ThemeModePicker extends ConsumerWidget {
  const _ThemeModePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appThemeModeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WatchnookSpacing.screen,
        vertical: WatchnookSpacing.sm,
      ),
      child: SegmentedButton<AppAppearance>(
        segments: const [
          ButtonSegment(value: AppAppearance.system, label: Text('System')),
          ButtonSegment(value: AppAppearance.light, label: Text('Light')),
          ButtonSegment(value: AppAppearance.dark, label: Text('Dark')),
          ButtonSegment(
            value: AppAppearance.dynamicColor,
            label: Text('Dynamic'),
          ),
        ],
        selected: {appearance},
        onSelectionChanged: (selection) =>
            ref.read(appThemeModeProvider.notifier).setMode(selection.first),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WatchnookSpacing.screen,
        WatchnookSpacing.xl,
        WatchnookSpacing.screen,
        WatchnookSpacing.sm,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Serializes the library and hands the file to the user (Android share sheet).
///
/// A dismissed share sheet is a **silent no-op**, never an error — the user
/// changed their mind, nothing failed. Only a genuine throw (a serialization
/// bug, no share target installed) surfaces a message.
Future<void> _export(
  BuildContext context,
  WidgetRef ref, {
  required String fileName,
  required String mimeType,
  required Future<String> Function(ImportExportService) build,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final contents = await build(ref.read(importExportServiceProvider));
    await ref.read(exportSharerProvider)(
      fileName: fileName,
      contents: contents,
      mimeType: mimeType,
    );
  } on Object catch (e, s) {
    debugPrint('export failed: $e\n$s');
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't export your data.")),
    );
  }
}

/// GDPR "delete everything" (US-D1). Wipes all four surfaces a user's data can
/// hide in — the library + watch events, the disposable metadata cache, and the
/// Auto Backup snapshot — then resets first-run so the app returns to a
/// fresh-install state (the router redirect reacts and reopens onboarding).
/// Deleting the backup file is load-bearing: the manifest allowlist backs up
/// exactly that file, so leaving it would silently re-restore the wiped data on
/// the next launch.
Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
  // Captured before the await so the SnackBar doesn't reach across the gap.
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete all data?'),
      content: const Text(
        'This erases your entire library, watch history, cached metadata and '
        'the on-device backup. It cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete everything'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    await ref.read(libraryDaoProvider).deleteAllUserData();
    await ref.read(mediaCacheDaoProvider).clearAll();
    final backup = await ref.read(autoBackupServiceProvider.future);
    await backup.deleteBackup();
    // Last: resetting first-run flips the router redirect back to onboarding.
    await ref.read(onboardingSeenProvider.notifier).reset();
    messenger.showSnackBar(
      const SnackBar(content: Text('All data deleted.')),
    );
  } on Object catch (e, s) {
    debugPrint('delete-all failed: $e\n$s');
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't delete your data.")),
    );
  }
}

/// Syncs the per-show metadata an import can't fetch (episode counts, show
/// status), so progress labels and the Up-to-date category are accurate. Runs
/// automatically after an import; this is the manual re-run.
Future<void> _refreshLibrary(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context)
    ..showSnackBar(
      const SnackBar(content: Text('Refreshing your library…')),
    );
  try {
    await ref.read(trackedShowSyncProvider).refresh();
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Library refreshed.')),
    );
  } on Object catch (e, s) {
    debugPrint('library refresh failed: $e\n$s');
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't refresh — you may be offline.")),
    );
  }
}

/// Rewrites the Auto Backup snapshot on demand (#32 writes it on every pause;
/// this is for the user who wants to be sure before wiping their phone).
Future<void> _backUpNow(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final backup = await ref.read(autoBackupServiceProvider.future);
    await backup.snapshot();
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Backup updated.')),
    );
  } on Object catch (e, s) {
    debugPrint('manual backup failed: $e\n$s');
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text("Couldn't back up your data.")),
    );
  }
}
