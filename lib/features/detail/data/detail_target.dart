import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';
import 'package:watch_nook/core/metadata/source_ref.dart';

/// Why a title on the detail screen cannot have its metadata fetched.
///
/// Both cases render identically — the stored row alone, no network. They have
/// very different fixes: one is waiting on the user to relink from Settings,
/// the other has no reliable fix in the app (a search opens the same row
/// untouched; only a re-import that matches it can fill the id). The one place
/// that branches on it is the Unverified notice, which must not send an
/// Unlinked row to a relink that cannot help it.
enum Unfetchable {
  /// The row was recorded against a backend that is no longer the active one
  /// (ADR-2 flips it remotely). Its ids belong to the other catalogue and mean
  /// something else entirely in this one; a relink from Settings repairs it.
  recordedAgainstAnotherBackend,

  /// The row has no id for its own backend at all — an offline add, or an
  /// import that matched on title alone.
  noIdForItsBackend,
}

/// What the detail screen is looking at: which title, from which backend, and
/// whether it is already tracked.
///
/// The screen used to answer this inline, as a chain of nullable expressions
/// whose `!`s were sound only because of a branch in the widget above it. As a
/// sealed value it is answerable — and testable — without rendering anything.
sealed class DetailTarget {
  const DetailTarget();

  /// The reference to fetch metadata with, or null when nothing may be
  /// fetched. **The only place fetchability is decided** is
  /// [LibraryItemSourceRef.refFor] / [MediaSearchResultSourceRef.refFor]; the
  /// cases below merely carry its answer.
  SourceRef? get fetchRef;

  /// What kind of title this is — null only for [UnknownTitle], which has no
  /// body to render. Deliberately not defaulted: a wrong media type silently
  /// picks the wrong fetch and the wrong layout.
  MediaType? get mediaType;
}

/// A tracked row whose own backend is the active one and which carries an id
/// for it — the ordinary case.
final class TrackedTitle extends DetailTarget {
  const TrackedTitle(this.item, this.ref);

  final LibraryItem item;
  final SourceRef ref;

  @override
  SourceRef? get fetchRef => ref;

  @override
  MediaType get mediaType => item.mediaType;
}

/// A tracked row nothing may fetch for, and why.
///
/// Handing its id to the active source would not fail — it would return a
/// different title's data, which then caches and renders as this one. The
/// screen shows what the row itself stores and asks the network for nothing.
final class StrandedTitle extends DetailTarget {
  const StrandedTitle(this.item, this.reason);

  final LibraryItem item;
  final Unfetchable reason;

  @override
  SourceRef? get fetchRef => null;

  @override
  MediaType get mediaType => item.mediaType;
}

/// An untracked search hit being previewed. [ref] is null when the hit carries
/// no id for the active backend, which previews the title from the hit's own
/// thin fields.
final class PreviewTitle extends DetailTarget {
  const PreviewTitle(this.result, this.ref);

  final MediaSearchResult result;
  final SourceRef? ref;

  @override
  SourceRef? get fetchRef => ref;

  @override
  MediaType get mediaType => mediaTypeOf(result.kind);
}

/// Neither a row nor a hit — a restored deep link to `/preview`, whose `extra`
/// does not survive the trip.
final class UnknownTitle extends DetailTarget {
  const UnknownTitle();

  @override
  SourceRef? get fetchRef => null;

  @override
  MediaType? get mediaType => null;
}

/// Resolves what the detail screen is looking at.
///
/// Exactly one of [item] (tracked) / [result] (preview) is expected; neither
/// gives [UnknownTitle], and a tracked row wins if somehow both are passed.
DetailTarget detailTargetOf({
  required LibraryItem? item,
  required MediaSearchResult? result,
  required MetadataSourceKind active,
}) {
  if (item != null) {
    final ref = item.refFor(active);
    if (ref != null) return TrackedTitle(item, ref);
    // Fetchability was already decided above. This only labels *why*, and must
    // not re-decide it — the two facts are read in the same order `refFor`
    // reads them.
    return StrandedTitle(
      item,
      item.recordedSource != active
          ? Unfetchable.recordedAgainstAnotherBackend
          : Unfetchable.noIdForItsBackend,
    );
  }
  if (result != null) return PreviewTitle(result, result.refFor(active));
  return const UnknownTitle();
}
