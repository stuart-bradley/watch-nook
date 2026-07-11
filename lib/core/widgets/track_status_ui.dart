import 'package:flutter/material.dart';
import 'package:watch_nook/core/database/tables.dart';

/// Presentation of the [TrackStatus] domain enum — the label + icon shown
/// wherever a status is displayed or picked (the detail screen and search).
///
/// Deliberately NOT in `tables.dart`: that's a pure drift layer with no Flutter
/// import, so `IconData` has no home there. This is the single source, so the
/// screens can't drift apart (the bug that had two copies of each switch).
extension TrackStatusUi on TrackStatus {
  String get label => switch (this) {
    TrackStatus.watchlist => 'Watchlist',
    TrackStatus.watching => 'Watching',
    TrackStatus.completed => 'Completed',
    TrackStatus.onHold => 'On hold',
    TrackStatus.dropped => 'Dropped',
  };

  IconData get icon => switch (this) {
    TrackStatus.watchlist => Icons.bookmark_add_outlined,
    TrackStatus.watching => Icons.play_circle_outline,
    TrackStatus.completed => Icons.check_circle_outline,
    TrackStatus.onHold => Icons.pause_circle_outline,
    TrackStatus.dropped => Icons.cancel_outlined,
  };
}

/// The shared status-picker bottom sheet: one row per [TrackStatus], returning
/// the chosen value (or null if dismissed). Used to change a title's status on
/// the detail screen and to pick a status when adding from search.
Future<TrackStatus?> showTrackStatusPicker(BuildContext context) {
  return showModalBottomSheet<TrackStatus>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in TrackStatus.values)
            ListTile(
              leading: Icon(s.icon),
              title: Text(s.label),
              onTap: () => Navigator.pop(context, s),
            ),
        ],
      ),
    ),
  );
}
