import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:watch_nook/features/home/presentation/home_screen.dart';

void main() {
  // No `await` before runApp — the "remote config never blocks boot" invariant.
  // #4 swaps in the router + Honey theme; #5 wires non-blocking remote config.
  runApp(const ProviderScope(child: WatchnookApp()));
}

class WatchnookApp extends StatelessWidget {
  const WatchnookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Watchnook',
      debugShowCheckedModeBanner: false,
      home: HomeScreen(),
    );
  }
}
