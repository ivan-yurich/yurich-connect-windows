import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/branding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(430, 760),
        minimumSize: Size(390, 620),
        center: true,
        title: YurichBranding.appName,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    await windowManager.setPreventClose(true);
  }
  runApp(const YurichConnectApp());
}
