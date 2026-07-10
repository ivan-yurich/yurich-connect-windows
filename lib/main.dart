import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/branding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }

  runApp(const YurichConnectApp());

  if (Platform.isWindows) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showWindowsWindow());
    });
  }
}

Future<void> _showWindowsWindow() async {
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
