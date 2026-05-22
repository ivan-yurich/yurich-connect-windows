// package com.tecclub.flutter_singbox.ktx

// import android.app.Activity
// import android.content.ActivityNotFoundException
// import androidx.activity.result.ActivityResultLauncher
// import com.google.android.material.dialog.MaterialAlertDialogBuilder

// fun Activity.startFilesForResult(
//     launcher: ActivityResultLauncher<String>, input: String
// ) {
//     try {
//         return launcher.launch(input)
//     } catch (_: ActivityNotFoundException) {
//     } catch (_: SecurityException) {
//     }
//     val builder = MaterialAlertDialogBuilder(this)
//     builder.setPositiveButton(resources.getString(android.R.string.ok), null)
//     builder.setMessage(com.google.android.material.R.string.error_a11y_label)
//     builder.show()
// }