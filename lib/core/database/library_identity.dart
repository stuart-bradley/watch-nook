import 'package:flutter_riverpod/flutter_riverpod.dart';
// The family/StreamProvider types live in the misc barrel, not the main one.
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/database_provider.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// "Is this title already in the library, and under what status?" — asked by
/// search (the row badge, and where a tap goes) and by the detail screen (which
/// must never offer to add something already tracked).
///
/// Lives in **core**, beside `LibraryDao.findByIdentity` which answers it, and
/// beside `library_item_ids.dart` — the same reason that one exists. It is a
/// library-domain question that no feature owns: putting it in `detail` made
/// `search` depend on `detail` for it.

/// How the library identifies a title — as much of it as the caller knows. A
/// record, so it works as a provider family key (structural equality).
typedef TitleIdentity = ({
  MediaType mediaType,
  String? imdbId,
  int? tmdbId,
  int? tvdbId,
  String title,
  int? year,
});

/// The identity of a search hit, enriched by [details] when they've loaded.
///
/// **This is the invariant, as a function.** `LibraryDao.findByIdentity` runs a
/// cascade (imdb → tmdb → tvdb → title+year), so a *weaker* identity finds
/// fewer rows. Feed the membership check a weaker identity than the add-time
/// dedupe gets and the two disagree: the screen offers "Add to library" for a
/// title that is already tracked, and the add then returns the existing row
/// untouched.
///
/// The gap that bites: a TMDB **search** result carries no `imdbId` — only its
/// **details** do — and `imdbId` is the strongest key in the cascade, the only
/// one that matches an imdb-keyed import (Trakt / TV Time) whose title spelling
/// or year differs from the search hit. So callers that have details pass them,
/// and the answer is re-resolved when they arrive.
///
/// Both the membership check and the add build their identity from here, so
/// they cannot drift apart field by field.
TitleIdentity identityOf(MediaSearchResult result, [MediaDetails? details]) => (
  mediaType: mediaTypeOf(result.kind),
  imdbId: details?.imdbId ?? result.imdbId,
  tmdbId: result.tmdbId,
  tvdbId: result.tvdbId,
  title: details?.title ?? result.title,
  year: details?.year ?? result.year,
);

/// Ticks on every `LibraryItems` write. Plain `StreamProvider` (CLAUDE.md: no
/// `@riverpod` over a Drift read).
final libraryRevisionProvider = StreamProvider<int>(
  (ref) => ref.watch(libraryDaoProvider).watchRevision(),
);

/// The tracked row for a title, if the library already has it — null if not.
///
/// **Live, not a snapshot.** It re-resolves whenever the library changes
/// ([libraryRevisionProvider]), because *every* writer moves this answer: the
/// add path, an import merge, a restore (which reassigns row ids), a
/// delete-all, a backend relink, and — for the status this reports — the detail
/// screen's own dropdown. A hand-invalidated cache is wrong the moment any of
/// those runs without knowing to invalidate it: a stale badge naming a status
/// the user has since changed, or a tap routing to a row id that is now gone.
///
/// So no writer has to remember anything: change the library, this repaints.
final FutureProviderFamily<LibraryItem?, TitleIdentity> trackedItemProvider =
    FutureProvider.family<LibraryItem?, TitleIdentity>((ref, id) async {
      await ref.watch(libraryRevisionProvider.future);
      return ref
          .watch(libraryDaoProvider)
          .findByIdentity(
            mediaType: id.mediaType,
            imdbId: id.imdbId,
            tmdbId: id.tmdbId,
            tvdbId: id.tvdbId,
            title: id.title,
            year: id.year,
          );
    });
