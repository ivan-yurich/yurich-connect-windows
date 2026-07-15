import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/branding.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final startHidden =
      Platform.isWindows &&
      arguments.any((argument) => argument.toLowerCase() == '--autostart');
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }

  runApp(const YurichConnectApp());

  if (Platform.isWindows) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_prepareWindowsWindow(startHidden: startHidden));
    });
  }
}

Future<void> _prepareWindowsWindow({required bool startHidden}) async {
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(430, 760),
      minimumSize: Size(390, 620),
      center: true,
      title: YurichBranding.appName,
    ),
    () async {
      if (startHidden) {
        await windowManager.hide();
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );
  await windowManager.setPreventClose(true);
}
