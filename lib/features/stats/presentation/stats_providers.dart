import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/features/stats/domain/stats_snapshot.dart';

/// The live stats stream (#34): one join over the **user-owned tables**, folded
/// in Dart by [statsFrom]. Repaints on any watch write, so marking an episode
/// updates the counts, hours and streak immediately.
///
/// A plain `StreamProvider` rather than `@riverpod` — it takes no parameters,
/// so the generator would only add machinery. (The exposed type is the pure
/// [StatsSnapshot], not a Drift row, so the `InvalidTypeException` rule in
/// CLAUDE.md does not bite here either way.)
///
/// `clock.now()` is read per emission, so the streak is recomputed on every DB
/// write. It is *not* recomputed on a bare passage of time: leave the app open
/// across midnight without watching anything and the streak card still shows
/// yesterday's number.
/// ponytail: no midnight timer — the number is right the moment you watch
/// something, which is the only moment anyone looks at it.
final StreamProvider<StatsSnapshot> statsProvider =
    StreamProvider<StatsSnapshot>(
      (ref) => ref
          .watch(libraryDaoProvider)
          .watchAllEvents()
          .map((rows) => statsFrom(rows, clock.now())),
    );
