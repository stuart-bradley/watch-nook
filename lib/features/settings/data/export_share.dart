import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:share_plus/share_plus.dart';

part 'export_share.g.dart';

/// Hands a generated export to the user. Returns false when they backed out of
/// the share sheet without choosing a destination.
typedef ExportSharer =
    Future<bool> Function({
      required String fileName,
      required String contents,
      required String mimeType,
    });

/// The real Android hand-off: the system share sheet ("Save to Files", Drive,
/// email, …). Overridden in tests — the platform channel is the one thing
/// `flutter test` cannot drive.
///
/// **Why not `file_selector`, which is already a dependency?** Because
/// `file_selector_android` implements `openFile`, `openFiles` and
/// `getDirectoryPath` and *nothing else*: `getSaveLocation()` falls through to
/// `FileSelectorPlatform`'s base implementation, which throws
/// `UnimplementedError`. A "pick where to save" dialog does not exist on
/// Android through that package, and `getDirectoryPath` hands back a SAF
/// `content://` tree URI that `dart:io` cannot write to. The share sheet is
/// both the working path and the one Android users already expect from an
/// "export my data" button.
@riverpod
ExportSharer exportSharer(Ref ref) =>
    ({required fileName, required contents, required mimeType}) async {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(contents),
              name: fileName,
              mimeType: mimeType,
            ),
          ],
          // Data-backed XFiles have no path, so share_plus needs the name
          // spelled out or the receiving app sees a random temp filename.
          fileNameOverrides: [fileName],
        ),
      );
      return result.status == ShareResultStatus.success;
    };
