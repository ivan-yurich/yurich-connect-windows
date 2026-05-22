package com.tecclub.flutter_singbox.bg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class AppChangeReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "AppChangeReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "App change detected: ${intent.action}")
        
        // This would handle per-app proxy settings updates when apps are installed
        // For now, we'll just log the event
        
        if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) {
            Log.d(TAG, "App is being updated, not handling")
            return
        }
        
        val packageName = intent.dataString?.substringAfter("package:")
        if (packageName.isNullOrBlank()) {
            Log.d(TAG, "Missing package name in intent")
            return
        }
        
        Log.d(TAG, "Package changed: $packageName")
    }
}