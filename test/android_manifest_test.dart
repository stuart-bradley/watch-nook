import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app's one network dependency is the metadata API. Flutter's scaffold
/// declares the INTERNET permission only in the **debug/profile** manifests, so
/// a **release** build (what users download) ships with no network access at
/// all unless `src/main/AndroidManifest.xml` also declares it — every request
/// then fails "Failed host lookup". That failure is invisible to debug/profile
/// builds and to the rest of `just check`, so this pins it here.
///
/// Regression: the first release build (v0.1.0-rc1) shipped with no INTERNET
/// permission and could not reach TMDB at all.
void main() {
  test('the release (src/main) manifest declares the INTERNET permission', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains('android.permission.INTERNET'),
      reason: 'Release APKs have no network without this; debug/profile mask it.',
    );
  });
}
