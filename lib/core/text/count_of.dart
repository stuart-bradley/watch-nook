/// "1 episode", "0 episodes", "2 rewatches": a count and its noun, singular
/// only for exactly one. The one place the app pluralises a count, so two
/// screens showing the same count cannot disagree. They once did: the preview's season
/// rows and the library grid both read "1 episodes".
///
/// [plural] is for nouns that don't just take an "s" ("rewatch" → "rewatches").
String countOf(int n, String noun, [String? plural]) =>
    '$n ${n == 1 ? noun : plural ?? '${noun}s'}';
