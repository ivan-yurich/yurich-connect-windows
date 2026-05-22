// package com.tecclub.flutter_singbox.ui.theme

// import android.app.Activity
// import android.os.Build
// import androidx.compose.foundation.isSystemInDarkTheme
// import androidx.compose.material3.MaterialTheme
// import androidx.compose.material3.darkColorScheme
// import androidx.compose.material3.dynamicDarkColorScheme
// import androidx.compose.material3.dynamicLightColorScheme
// import androidx.compose.material3.lightColorScheme
// import androidx.compose.runtime.Composable
// import androidx.compose.runtime.SideEffect
// import androidx.compose.ui.graphics.toArgb
// import androidx.compose.ui.platform.LocalContext
// import androidx.compose.ui.platform.LocalView
// import androidx.core.view.WindowCompat

// private val DarkColorScheme = darkColorScheme(
//     primary = androidx.compose.ui.graphics.Color(0xFF90CAF9),
//     secondary = androidx.compose.ui.graphics.Color(0xFF81D4FA),
//     tertiary = androidx.compose.ui.graphics.Color(0xFF80DEEA)
// )

// private val LightColorScheme = lightColorScheme(
//     primary = androidx.compose.ui.graphics.Color(0xFF2196F3),
//     secondary = androidx.compose.ui.graphics.Color(0xFF03A9F4),
//     tertiary = androidx.compose.ui.graphics.Color(0xFF00BCD4)
// )

// @Composable
// fun SingBoxAndroidTheme(
//     darkTheme: Boolean = isSystemInDarkTheme(),
//     dynamicColor: Boolean = true,
//     content: @Composable () -> Unit
// ) {
//     val colorScheme = when {
//         dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
//             val context = LocalContext.current
//             if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
//         }
//         darkTheme -> DarkColorScheme
//         else -> LightColorScheme
//     }
//     val view = LocalView.current
//     if (!view.isInEditMode) {
//         SideEffect {
//             val window = (view.context as Activity).window
//             window.statusBarColor = colorScheme.primary.toArgb()
//             WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
//         }
//     }

//     MaterialTheme(
//         colorScheme = colorScheme,
//         content = content
//     )
// }