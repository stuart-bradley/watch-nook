import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// Re-resolves the library when the active metadata backend changes (ADR-4).
///
/// A backend switch never touches [WatchEvents]. Watched flags are precious and
/// pinned to **aired-order** `(season, episode)` — coordinates both backends
/// share — so this service only (a) relinks each row's ids to the new backend
/// by its universal `imdbId` join key, and (b) *verifies* those watched
/// coordinates still mean the same episodes on the new backend by reconciling
/// **air-dates**. It decides one flag per row, `relinkFailed`:
///
/// > `relinkFailed == true` means "could not confirm this title's watched state
/// > survives the switch — surface for manual review". It NEVER means a watch
/// > row was rewritten or dropped. (INVARIANT — CLAUDE.md episode-identity.)
///
/// Outcomes per row:
/// * **Can't relink** — no `imdbId`, or the new source doesn't resolve it:
///   leave ids/`recordedSource` intact (nothing to point at), set the flag.
/// * **Relinked, episodes reconcile** — update ids + `recordedSource`, clear
///   the flag. Watched rows stand unchanged (their coordinates are valid).
/// * **Relinked, episodes don't reconcile** — a watched coordinate is missing
///   on the new backend, air-dates disagree, or it's a special (season 0):
///   update ids + `recordedSource` (the *show* was found) but set the flag.
///   Watched rows still untouched.
class BackendSwitchService {
  /// [newSource] is the backend being switched **to**; [newKind] is its enum.
  /// [clock] stamps `updatedAt` — inject a fixed clock in tests.
  BackendSwitchService({
    required AppDatabase db,
    required MetadataSource newSource,
    required MetadataSourceKind newKind,
    Clock clock = const Clock(),
  }) : _db = db,
       _newSource = newSource,
       _newKind = newKind,
       _clock = clock;

  final AppDatabase _db;
  final MetadataSource _newSource;
  final MetadataSourceKind _newKind;
  final Clock _clock;

  /// Relinks every library row not already recorded against the new backend.
  Future<BackendSwitchReport> switchAll() async {
    final items = await _db.libraryDao.getAll();
    var relinked = 0;
    var flagged = 0;
    var skipped = 0;
    for (final item in items) {
      if (item.recordedSource == _newKind) {
        skipped++;
        continue;
      }
      final ok = await _relinkItem(item);
      ok ? relinked++ : flagged++;
    }
    return BackendSwitchReport(
      relinked: relinked,
      flagged: flagged,
      skipped: skipped,
    );
  }

  /// Returns true when the row was relinked *and* its episodes reconciled.
  Future<bool> _relinkItem(LibraryItem item) async {
    // 1. A universal join key is required to find the title on the new backend.
    final imdb = item.imdbId;
    if (imdb == null || imdb.isEmpty) {
      await _flagOnly(item);
      return false;
    }

    // 2. Resolve on the new backend. A network/parse failure here is treated
    //    conservatively as "can't relink" — flag, don't scramble.
    final MediaSearchResult? match;
    try {
      match = await _newSource.resolveByExternalId(imdb);
    } on Object {
      await _flagOnly(item);
      return false;
    }
    final newId = match == null ? null : _idFor(match);
    if (newId == null) {
      await _flagOnly(item);
      return false;
    }

    // 3. Reconcile watched episodes by air-date (movies / unwatched are clean).
    final reconciled = await _episodesReconcile(item, newId);

    await _db.libraryDao.updateItem(
      item.id,
      LibraryItemsCompanion(
        tmdbId: _newKind == MetadataSourceKind.tmdb
            ? Value(newId)
            : const Value.absent(),
        tvdbId: _newKind == MetadataSourceKind.tvdb
            ? Value(newId)
            : const Value.absent(),
        recordedSource: Value(_newKind),
        relinkFailed: Value(!reconciled),
        updatedAt: Value(_clock.now()),
      ),
    );
    return reconciled;
  }

  int? _idFor(MediaSearchResult r) =>
      _newKind == MetadataSourceKind.tmdb ? r.tmdbId : r.tvdbId;

  /// Flag without relinking — leaves ids and `recordedSource` intact (there is
  /// nothing to point them at on the new backend).
  Future<void> _flagOnly(LibraryItem item) => _db.libraryDao.updateItem(
    item.id,
    LibraryItemsCompanion(
      relinkFailed: const Value(true),
      updatedAt: Value(_clock.now()),
    ),
  );

  /// True when every watched `(season, episode)` for [item] has a 1:1
  /// counterpart on the new backend at [newShowId] with a consistent air-date.
  Future<bool> _episodesReconcile(LibraryItem item, int newShowId) async {
    if (item.mediaType == MediaType.movie) return true; // no episodes

    final events = await _db.libraryDao.watchEventsFor(item.id);
    final watched = <(int, int)>{};
    for (final e in events) {
      final s = e.seasonNumber;
      final ep = e.episodeNumber;
      if (s == null || ep == null) continue; // movie-shaped row; ignore
      watched.add((s, ep));
    }
    if (watched.isEmpty) return true; // nothing to preserve
    // Specials (season 0) use irregular/absolute numbering that doesn't map
    // 1:1 across backends by aired coordinate — never auto-reconcile them.
    if (watched.any((c) => c.$1 == 0)) return false;

    // New backend's episodes for the watched seasons: coordinate -> airDate.
    final newByCoord = <(int, int), DateTime?>{};
    for (final season in watched.map((c) => c.$1).toSet()) {
      final List<EpisodeInfo> eps;
      try {
        eps = await _newSource.seasonEpisodes(newShowId, season);
      } on Object {
        return false; // can't fetch → can't verify → flag, don't scramble
      }
      for (final e in eps) {
        newByCoord[(e.seasonNumber, e.episodeNumber)] = e.airDate;
      }
    }

    // Old backend's air-dates from the disposable cache (may be cold → absent).
    final oldByCoord = await _oldAirDates(item, watched);

    for (final coord in watched) {
      // Count-divergence guard: a watched episode with no counterpart on the
      // new backend can't be trusted.
      if (!newByCoord.containsKey(coord)) return false;
      final oldAir = oldByCoord[coord];
      final newAir = newByCoord[coord];
      // When both air-dates are known they must agree on the calendar day; a
      // shifted date means the coordinate points at a different episode.
      if (oldAir != null && newAir != null && !_sameDay(oldAir, newAir)) {
        return false;
      }
    }
    return true;
  }

  Future<Map<(int, int), DateTime?>> _oldAirDates(
    LibraryItem item,
    Set<(int, int)> watched,
  ) async {
    final oldKind = item.recordedSource;
    final oldShowId = oldKind == MetadataSourceKind.tmdb
        ? item.tmdbId
        : item.tvdbId;
    final out = <(int, int), DateTime?>{};
    if (oldShowId == null) return out;
    for (final season in watched.map((c) => c.$1).toSet()) {
      final cached = await _db.mediaCacheDao.getEpisodes(
        oldKind,
        oldShowId,
        season,
      );
      for (final e in cached) {
        out[(e.seasonNumber, e.episodeNumber)] = e.airDate;
      }
    }
    return out;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Summary of a [BackendSwitchService.switchAll] pass.
class BackendSwitchReport {
  const BackendSwitchReport({
    required this.relinked,
    required this.flagged,
    required this.skipped,
  });

  /// Rows relinked to the new backend with episodes reconciled cleanly.
  final int relinked;

  /// Rows left `relinkFailed = true` for manual review.
  final int flagged;

  /// Rows already recorded against the new backend (no work needed).
  final int skipped;
}
