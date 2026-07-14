import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/widgets/home_navigation.dart';

void main() {
  const labels = HomeNavigationLabels(
    home: 'Главная',
    profiles: 'Профили',
    routing: 'Маршруты',
    settings: 'Ещё',
  );

  testWidgets('keeps four destinations usable in the minimum window width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    YurichHomeSection selected = YurichHomeSection.home;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: HomeNavigation(
            selected: selected,
            labels: labels,
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );

    expect(find.byType(NavigationDestination), findsNWidgets(4));
    await tester.tap(find.text('Маршруты'));
    expect(selected, YurichHomeSection.routing);
    expect(tester.takeException(), isNull);
  });
}
