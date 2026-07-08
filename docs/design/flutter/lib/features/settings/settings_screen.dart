import 'package:flutter/material.dart';

import '../../core/theme/watchnook_tokens.dart';

enum Appearance { dark, light, dynamic }

/// Settings — appearance, backup (import / export), and attribution.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Appearance _appearance = Appearance.dark;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    Widget label(String s) => Padding(
          padding: const EdgeInsets.only(
              top: WatchnookSpacing.xl, bottom: WatchnookSpacing.md),
          child: Text(s.toUpperCase(),
              style: text.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            WatchnookSpacing.lg, 0, WatchnookSpacing.lg, WatchnookSpacing.xl),
        children: [
          label('Appearance'),
          SegmentedButton<Appearance>(
            segments: const [
              ButtonSegment(value: Appearance.dark, label: Text('Dark')),
              ButtonSegment(value: Appearance.light, label: Text('Light')),
              ButtonSegment(value: Appearance.dynamic, label: Text('Dynamic')),
            ],
            selected: {_appearance},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _appearance = s.first),
          ),
          label('Backup'),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pushNamed('/import'),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Import…'),
          ),
          const SizedBox(height: WatchnookSpacing.sm),
          OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.upload_outlined),
            label: const Text('Export / backup'),
          ),
          label('About'),
          Container(
            decoration: WatchnookTokens.railCard(context),
            padding: const EdgeInsets.all(WatchnookSpacing.lg),
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'TMDB  ',
                    style: text.labelMedium?.copyWith(
                        color: cs.primary, fontWeight: FontWeight.w800)),
                TextSpan(
                    text:
                        'This product uses the TMDB API but is not endorsed or '
                        'certified by TMDB. Series data from TheTVDB.',
                    style: text.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant, height: 1.5)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
