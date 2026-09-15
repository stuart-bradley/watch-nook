/// "1 episode", "0 episodes", "12 titles": a count and its noun, singular only
/// for exactly one. The one place the app pluralises, so two screens showing
/// the same count cannot disagree. They once did: the preview's season rows
/// and the library grid both read "1 episodes".
///
/// ponytail: regular English plurals only (noun + "s"); take a plural argument
/// when a noun that doesn't follow the rule turns up.
String countOf(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';
