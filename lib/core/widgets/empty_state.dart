import 'package:flutter/material.dart';
import 'package:watch_nook/core/theme/watchnook_tokens.dart';

/// The shared "nothing here" panel: an icon, a headline, a supporting line, and
/// optional call-to-action buttons.
///
/// Each screen supplies its **own copy**. An empty library, an empty filter
/// result and an empty search are different situations, and telling a user with
/// 300 titles that "your library is empty" because a filter matched nothing is
/// the easy bug this widget exists to make obvious rather than to hide.
class EmptyState extends StatelessWidget {
  /// Creates an [EmptyState].
  const EmptyState({
    required this.icon,
    required this.headline,
    this.body,
    this.actions = const [],
    super.key,
  });

  /// Large muted glyph above the headline.
  final IconData icon;

  /// The one-line statement of what is empty.
  final String headline;

  /// Optional supporting line: what the user can do about it.
  final String? body;

  /// Optional buttons, laid out in a centred row.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WatchnookSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: WatchnookSpacing.lg),
            Text(
              headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (body case final body?) ...[
              const SizedBox(height: WatchnookSpacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: WatchnookSpacing.xl),
              Wrap(
                spacing: WatchnookSpacing.md,
                runSpacing: WatchnookSpacing.sm,
                alignment: WrapAlignment.center,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
