import 'package:flutter/material.dart';

import 'branding.dart';
import 'screens/home_screen.dart';

class YurichConnectApp extends StatelessWidget {
  const YurichConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF20C4F4),
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF111923),
          error: const Color(0xFFFF6B6B),
        );

    return MaterialApp(
      title: YurichBranding.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0F14),
          foregroundColor: Color(0xFFE8F7FF),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111923),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF162633),
          hintStyle: const TextStyle(color: Color(0xFF91A4B7)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF20C4F4)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF111923),
          indicatorColor: Color(0x3320C4F4),
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
