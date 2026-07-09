import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';

/// **Mandatory** per-source attribution (CLAUDE.md): TMDB's "not endorsed"
/// notice, or TheTVDB's linked credit. Rendered from the active source's own
/// `attribution()`, so flipping the backend flips the credit with no code
/// change. Neither source bundles a logo yet — `logoAsset` is honoured when one
/// appears.
///
/// Shown on the detail screen (#18) and in Settings → About (#35). It is a
/// licensing obligation, not decoration: do not make it conditional.
class AttributionFooter extends ConsumerWidget {
  /// Creates an [AttributionFooter].
  const AttributionFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final attribution = ref.watch(activeMetadataSourceProvider).attribution();
    final url = Uri.parse(attribution.linkUrl);
    return Padding(
      padding: const EdgeInsets.all(WatchnookSpacing.xl),
      child: Column(
        children: [
          if (attribution.logoAsset case final asset?)
            Image.asset(asset, height: 20),
          Text(
            attribution.notice,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: () => unawaited(
              launchUrl(url, mode: LaunchMode.externalApplication),
            ),
            child: Text(attribution.linkUrl),
          ),
        ],
      ),
    );
  }
}
