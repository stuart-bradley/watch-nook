import 'package:flutter/foundation.dart';
import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/library_item_ids.dart';
import 'package:watch_nook/core/database/tables.dart';
import 'package:watch_nook/core/metadata/metadata_source.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

/// A backend id **together with the backend that minted it**.
///
/// Ids are namespaced per backend: TMDB's `95396` and TVDB's `95396` are two
/// unrelated titles. Passing a bare `int` to a metadata lookup therefore does
/// not fail when it is the wrong backend's id — it returns a perfectly valid
/// response describing a completely different title, which then caches and
/// renders as this one. That is the failure mode the episode-identity
/// invariant exists to prevent, and until this type existed the rule "only
/// ever hand a source its own ids" was a convention held up by comments and
/// hand-written `recordedSource == active` checks at each call site.
///
/// Making the pairing part of the value moves the rule from prose to the type
/// system: there is nowhere to get an id from that does not also say which
/// catalogue it belongs to, and every [MetadataSource] rejects a foreign one
/// (see [idFor]) instead of answering it.
@immutable
final class SourceRef {
  const SourceRef(this.kind, this.id);

  /// The backend that minted [id].
  final MetadataSourceKind kind;

  /// The id, meaningful only within [kind]'s catalogue.
  final int id;

  /// The raw id for a caller that *is* [expected]'s backend.
  ///
  /// Throws [ArgumentError] on a foreign reference. This is a programming
  /// error, not a runtime condition — every construction site pairs the id
  /// with its own backend, so reaching here means a reference was carried
  /// across a backend boundary. Failing loudly is the point: the alternative
  /// is querying the wrong catalogue and getting an answer.
  int idFor(MetadataSourceKind expected) {
    if (kind != expected) {
      throw ArgumentError.value(
        this,
        'ref',
        'minted by ${kind.name}, handed to ${expected.name}',
      );
    }
    return id;
  }

  @override
  bool operator ==(Object other) =>
      other is SourceRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'SourceRef(${kind.name}:$id)';
}

/// Builds the reference for a tracked row — see [LibraryItemSourceRef.refFor].
extension LibraryItemSourceRef on LibraryItem {
  /// The reference to fetch this row's metadata with, or null when there is
  /// nothing safe to fetch.
  ///
  /// **The one place the "is this row's backend the active one?" rule lives.**
  /// Null in the two cases every caller treats identically — render the stored
  /// row and fetch nothing:
  ///
  /// - the row has no id for its own backend (offline add / import), and
  /// - the row was recorded against a backend that is no longer [active].
  ///
  /// The second is the load-bearing one. ADR-2 makes flipping the backend an
  /// operator action taken remotely, so rows keep the ids of the backend they
  /// were recorded against until the user relinks from Settings. A row's own
  /// `recordedSource` id is the only id it has, and it is worthless to any
  /// other catalogue.
  SourceRef? refFor(MetadataSourceKind active) {
    if (recordedSource != active) return null;
    final id = sourceIdFor(active);
    return id == null ? null : SourceRef(active, id);
  }
}

/// Builds the reference for a search hit — see
/// [MediaSearchResultSourceRef.refFor].
extension MediaSearchResultSourceRef on MediaSearchResult {
  /// The reference to preview an **untracked** search hit with — the pre-add
  /// twin of [LibraryItemSourceRef.refFor].
  ///
  /// INVARIANT: the detail screen previews a hit through this reference and
  /// `addToLibrary` stores the row under it, so what you preview is what gets
  /// added. A hit carrying no id for [active] cannot be fetched.
  SourceRef? refFor(MetadataSourceKind active) {
    final id = switch (active) {
      MetadataSourceKind.tmdb => tmdbId,
      MetadataSourceKind.tvdb => tvdbId,
    };
    return id == null ? null : SourceRef(active, id);
  }
}
