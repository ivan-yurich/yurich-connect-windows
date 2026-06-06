import 'package:flutter/material.dart';

import 'branding.dart';
import 'screens/home_screen.dart';

class YurichConnectApp extends StatelessWidget {
  const YurichConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF15B8FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: YurichBranding.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF07101C),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF07101C),
          foregroundColor: Color(0xFFEAF7FF),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0D1A2B),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF10233A),
          hintStyle: const TextStyle(color: Color(0xFF8BAEC7)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF15B8FF)),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
