import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/import_export/import/import_record.dart';
import 'package:watch_nook/core/metadata/metadata_exception.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// What the [Resolver] decided about one [ImportRecord].
@immutable
sealed class Resolution {
  const Resolution(this.record);

  /// The record this decision is about.
  final ImportRecord record;
}

/// Resolved without asking anyone: the record carried an id we trust, or its
/// title matched exactly one candidate. [match] is null on the id-in-our-own-
/// namespace rung, where no lookup was needed and the record's own fields win.
@immutable
class Auto extends Resolution {
  /// Creates an [Auto] resolution.
  const Auto(super.record, [this.match]);

  /// The backend hit that confirmed the record, if one was fetched.
  final MediaSearchResult? match;
}

/// The title search could not pick a single confident candidate. Goes to the
/// confirmation queue; [candidates] are the top hits for a human to choose
/// from (possibly empty — the search found nothing to offer).
@immutable
class Ambiguous extends Resolution {
  /// Creates an [Ambiguous] resolution.
  const Ambiguous(super.record, this.candidates);

  /// Top hits to show, best first.
  final List<MediaSearchResult> candidates;
}

/// The backend could not be reached (offline, 429, 5xx). The record is **still
/// applied** with the ids and title it already carries (US-13) — an import must
/// never fail because the metadata API is down. Artwork backfills on first
/// view, off the stale-while-revalidate cache.
@immutable
class Unresolved extends Resolution {
  /// Creates an [Unresolved] resolution.
  const Unresolved(super.record, this.reason);

  /// Why the lookup was abandoned, for the summary/diagnostics.
  final String reason;
}

/// How many candidates a human is asked to choose between.
const _maxCandidates = 5;

/// Folds a title to its comparable form: lowercase, then every run of
/// non-letter/non-digit collapsed to a single space.
///
/// Unicode-aware on purpose (`\p{L}`, not `[a-z]`): folding to ASCII would
/// erase a wholly non-Latin title to the empty string, and two different such
/// titles would then compare *equal* — a wrong auto-match, which is the one
/// failure this resolver must never produce.
///
// ponytail: no diacritic folding, so `Shōgun` != `Shogun` and that pair falls
// to the confirmation queue rather than auto-matching. Safe direction. Add
// `package:diacritic` here if accented-vs-ASCII titles show up in the queue.
String normalizeTitle(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// Turns an [ImportRecord] into a [Resolution] by taking the **cheapest rung
/// that resolves** (AD-3):
///
/// 1. `imdbId` → [MetadataSource.resolveByExternalId] (universal join key).
/// 2. an id already in the active source's own namespace → auto, **no network
///    call at all**; the record's title/year carry through.
/// 2b. a *foreign* id the backend can map — a TVDB id under TMDB → `/find`.
/// 3. `search(title)` → confident iff **exactly one** candidate matches the
///    normalized title and its year is within a year. Anything else is
///    [Ambiguous] and a human decides.
/// 4. any [MetadataException] → [Unresolved], and the record is applied anyway.
class Resolver {
  /// Creates a [Resolver] over the active [source]. [sourceKind] must be the
  /// backend [source] actually is — it decides which of `tmdbId`/`tvdbId` is
  /// "our own" id at rung 2.
  const Resolver({required this.source, required this.sourceKind});

  /// The active metadata backend.
  final MetadataSource source;

  /// Which backend [source] is.
  final MetadataSourceKind sourceKind;

  /// Resolves one record. Never throws for a backend failure.
  Future<Resolution> resolve(ImportRecord record) async {
    // Rung 1 — the universal id. A null answer isn't a failure (this backend
    // just doesn't know the title); fall through to the cheaper rungs.
    final imdbId = record.imdbId;
    if (imdbId != null) {
      try {
        final hit = await source.resolveByExternalId(imdbId);
        if (hit != null) return Auto(record, hit);
      } on MetadataException catch (e) {
        return Unresolved(record, e.toString());
      }
    }

    // Rung 2 — already an id we could query with. Nothing to look up.
    final ownId = switch (sourceKind) {
      MetadataSourceKind.tmdb => record.tmdbId,
      MetadataSourceKind.tvdb => record.tvdbId,
    };
    if (ownId != null) return Auto(record);

    // Rung 2b — a *foreign* id the active backend can map deterministically.
    // The load-bearing case: a TV Time show carries only a TheTVDB id, and the
    // active backend is TMDB — map it via /find?external_source=tvdb_id instead
    // of falling to fuzzy title search (which missed ~1 in 3 shows). A null
    // answer isn't a failure; fall through to search.
    final foreign = _foreignId(record);
    if (foreign != null) {
      try {
        final hit = await source.resolveByExternalId(
          foreign.$1,
          kind: foreign.$2,
        );
        if (hit != null) return Auto(record, hit);
      } on MetadataException catch (e) {
        return Unresolved(record, e.toString());
      }
    }

    // Rung 3 — no ids at all (Letterboxd, TV Time's movie UUIDs).
    final List<MediaSearchResult> hits;
    try {
      hits = await source.search(record.title, kind: _kindOf(record.mediaType));
    } on MetadataException catch (e) {
      return Unresolved(record, e.toString());
    }

    final confident = hits.where((c) => _isConfident(record, c)).toList();
    if (confident.length == 1) return Auto(record, confident.single);
    return Ambiguous(record, hits.take(_maxCandidates).toList());
  }

  /// A candidate is confident only when the folded titles are equal **and** the
  /// years agree to within one (release-vs-air-year skew). A missing year on
  /// either side abstains rather than disqualifies — plenty of exports omit it.
  ///
  /// Deliberately strict: two same-titled candidates both pass, `length != 1`,
  /// and the pair goes to a human. A loose threshold here silently files the
  /// wrong show under someone's watch history.
  bool _isConfident(ImportRecord record, MediaSearchResult candidate) {
    if (normalizeTitle(candidate.title) != normalizeTitle(record.title)) {
      return false;
    }
    final want = record.year;
    final got = candidate.year;
    return want == null || got == null || (want - got).abs() <= 1;
  }

  /// A foreign id (and its namespace) the active backend can resolve, or null.
  /// Only TMDB↔TVDB is bridgeable today: under TMDB a record's TVDB id maps via
  /// `/find`. Under TVDB the TVDB id is the *own* id (rung 2), so nothing here.
  (String, ExternalIdKind)? _foreignId(ImportRecord record) =>
      switch (sourceKind) {
        MetadataSourceKind.tmdb when record.tvdbId != null => (
          record.tvdbId!.toString(),
          ExternalIdKind.tvdb,
        ),
        _ => null,
      };

  static MediaKind _kindOf(MediaType type) => switch (type) {
    MediaType.movie => MediaKind.movie,
    MediaType.tv => MediaKind.tv,
  };
}
