import 'package:csv/csv.dart';

/// The data rows of [text] as `header → value` maps, plus how many rows were
/// dropped.
///
/// A row is dropped when its field count disagrees with the header's. Real
/// exports end in a truncated row often enough that this must cost one row, not
/// the file (AD-7). Values stay `String`: callers reach for `int.tryParse`, not
/// an `as` cast — an `as` failure raises `TypeError`, which `on Exception` does
/// not catch (CLAUDE.md).
({List<Map<String, String>> rows, int skipped}) parseCsv(String text) {
  // An explicit delimiter disables auto-detection: a header holding more
  // semicolons than commas would otherwise re-read the whole file as SSV.
  final table = const CsvDecoder(fieldDelimiter: ',').convert(text);
  if (table.isEmpty) return (rows: const [], skipped: 0);

  final header = [for (final cell in table.first) '$cell'.trim()];
  final rows = <Map<String, String>>[];
  var skipped = 0;

  for (final row in table.skip(1)) {
    if (row.length != header.length) {
      skipped++;
      continue;
    }
    rows.add({
      for (var i = 0; i < header.length; i++) header[i]: '${row[i]}'.trim(),
    });
  }

  return (rows: rows, skipped: skipped);
}
