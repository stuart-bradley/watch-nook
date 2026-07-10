import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The launcher icon must be a real branded **adaptive** icon, not the stock
/// Flutter template (a blue background + white "F"). Regression: the early
/// builds shipped that placeholder and a blank splash. These pin the generated
/// artifacts so a `flutter create`-style reset, or a bad icon regen, is caught
/// in CI rather than on a user's home screen.
void main() {
  test('an adaptive launcher icon is generated (API 26+)', () {
    final xml = File(
      'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    );
    expect(xml.existsSync(), isTrue, reason: 'no adaptive icon — regen it');

    final content = xml.readAsStringSync();
    expect(content, contains('<adaptive-icon'));
    expect(content, contains('ic_launcher_foreground'));
    // Android-13 themed-icon layer.
    expect(content, contains('ic_launcher_monochrome'));
  });

  test('the launcher background is the Honey brand colour', () {
    final colors = File(
      'android/app/src/main/res/values/colors.xml',
    ).readAsStringSync();
    expect(colors, contains('#E9BF64'));
  });
}
