import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'shared_preferences_provider.g.dart';

/// The app's [SharedPreferences]. `main.dart` resolves the async
/// `getInstance()` at startup and overrides this with the real instance.
///
/// The base throws so any code path that forgot the override (or a test that
/// didn't set one) fails loudly rather than silently using a stub.
@Riverpod(keepAlive: true)
SharedPreferences sharedPreferences(Ref ref) =>
    throw UnimplementedError('sharedPreferencesProvider must be overridden');
