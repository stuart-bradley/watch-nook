/// Thrown by a `MetadataSource` when a backend request comes back non-2xx.
///
/// Carries the HTTP [statusCode] so the SWR cache wrapper (#13) can branch on
/// it — `429`/`500` fall back to cached data instead of surfacing, everything
/// else propagates. Parse failures (`TypeError`/`FormatException` from a
/// wrong-shaped body) are deliberately *not* wrapped: they signal a contract
/// break, not a transient network state, and propagate as-is (CLAUDE.md
/// `as`-cast gotcha).
class MetadataException implements Exception {
  const MetadataException(this.statusCode, this.message);

  /// The HTTP status that triggered the failure.
  final int statusCode;

  /// The raw response body (or a short reason), for logging/diagnostics.
  final String message;

  @override
  String toString() => 'MetadataException($statusCode): $message';
}
