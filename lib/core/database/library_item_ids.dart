import 'package:watch_nook/core/database/app_database.dart';
import 'package:watch_nook/core/database/tables.dart';

/// The canonical `LibraryItem → backend source-id` mapping, in one place so
/// up_next, detail and the tracked-show sync don't each re-derive it (and so
/// the library feature no longer reaches across to up_next for it).
///
/// A row's ids are namespaced per backend; `sourceIdFor` returns the id column
/// the given kind pins — never the other backend's, per the episode-identity
/// invariant. Null when the row has no id for that backend (offline / import
/// add), which every caller reads as "can't fetch metadata for this row".
extension LibraryItemSourceId on LibraryItem {
  int? sourceIdFor(MetadataSourceKind kind) => switch (kind) {
    MetadataSourceKind.tmdb => tmdbId,
    MetadataSourceKind.tvdb => tvdbId,
  };
}
