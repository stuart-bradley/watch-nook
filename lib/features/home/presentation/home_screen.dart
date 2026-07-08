import 'package:flutter/material.dart';

/// Placeholder home surface. The library grid lands in M2 (#15); onboarding +
/// routing wraps this in #4.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watchnook')),
      body: const SizedBox.shrink(),
    );
  }
}
