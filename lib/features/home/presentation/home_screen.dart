import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder home surface. The library grid + bottom-nav shell land in #17;
/// #16 adds the Search action so the search/add flow is reachable in the app.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watchnook'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: const SizedBox.shrink(),
    );
  }
}
