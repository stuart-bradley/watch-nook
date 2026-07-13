import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:watch_nook/core/metadata/metadata_providers.dart';
import 'package:watch_nook/core/metadata/models/metadata_models.dart';

part 'search_providers.g.dart';

/// Live search results for the active backend (#16). An empty query
/// short-circuits to an empty list (no network); otherwise it goes straight to
/// the source's `search`. Search is **not** cached (unlike details) — it's
/// always live. The keystroke debounce lives in the screen (a UI concern).
@riverpod
Future<List<MediaSearchResult>> searchResults(Ref ref, String query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  return ref.watch(activeMetadataSourceProvider).search(q);
}
