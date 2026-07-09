import 'package:flutter/material.dart';

/// Up Next tab — this week's episodes for tracked shows. Placeholder: the
/// upcoming/calendar view lands in #21. The nav shell (AD-5) ships it here in
/// #17 so the grid has its home structure.
class UpNextScreen extends StatelessWidget {
  const UpNextScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.upcoming_outlined,
            size: 48,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          const Text('Upcoming episodes land here soon.'),
        ],
      ),
    );
  }
}
