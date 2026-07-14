import 'package:flutter/material.dart';

enum YurichHomeSection { home, profiles, routing, settings }

class HomeNavigationLabels {
  const HomeNavigationLabels({
    required this.home,
    required this.profiles,
    required this.routing,
    required this.settings,
  });

  final String home;
  final String profiles;
  final String routing;
  final String settings;
}

class HomeNavigation extends StatelessWidget {
  const HomeNavigation({
    super.key,
    required this.selected,
    required this.labels,
    required this.onSelected,
  });

  final YurichHomeSection selected;
  final HomeNavigationLabels labels;
  final ValueChanged<YurichHomeSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      height: 64,
      selectedIndex: YurichHomeSection.values.indexOf(selected),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: (index) {
        onSelected(YurichHomeSection.values[index]);
      },
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.shield_outlined),
          selectedIcon: const Icon(Icons.shield),
          label: labels.home,
        ),
        NavigationDestination(
          icon: const Icon(Icons.dns_outlined),
          selectedIcon: const Icon(Icons.dns),
          label: labels.profiles,
        ),
        NavigationDestination(
          icon: const Icon(Icons.route_outlined),
          selectedIcon: const Icon(Icons.route),
          label: labels.routing,
        ),
        NavigationDestination(
          icon: const Icon(Icons.tune_outlined),
          selectedIcon: const Icon(Icons.tune),
          label: labels.settings,
        ),
      ],
    );
  }
}
