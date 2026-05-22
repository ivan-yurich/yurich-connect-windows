package com.tecclub.flutter_singbox.database

import android.content.Context
import android.util.Base64
import com.tecclub.flutter_singbox.Application
import com.tecclub.flutter_singbox.bg.ProxyService
import com.tecclub.flutter_singbox.bg.VPNService
import com.tecclub.flutter_singbox.config.SimpleConfigManager
import com.tecclub.flutter_singbox.constant.ServiceMode
import com.tecclub.flutter_singbox.constant.SettingsKey
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ObjectInputStream

object Settings {
    // Using SharedPreferences for persistent storage
    private val preferences by lazy {
        Application.application.getSharedPreferences("flutter_singbox_preferences", Context.MODE_PRIVATE)
    }

    // Constants for per-app proxy modes
    const val PER_APP_PROXY_OFF = "off"
    const val PER_APP_PROXY_INCLUDE = "include"
    const val PER_APP_PROXY_EXCLUDE = "exclude"

    // Settings with persistence
    var perAppProxyMode: String
        get() = preferences.getString("per_app_proxy_mode", PER_APP_PROXY_OFF) ?: PER_APP_PROXY_OFF
        set(value) = preferences.edit().putString("per_app_proxy_mode", value).apply()
    
    val perAppProxyEnabled: Boolean get() = perAppProxyMode != PER_APP_PROXY_OFF
    
    var perAppProxyList: List<String>
        get() {
            val listJson = preferences.getString("per_app_proxy_list", "[]") ?: "[]"
            return try {
                val jsonArray = org.json.JSONArray(listJson)
                List(jsonArray.length()) { jsonArray.getString(it) }
            } catch (e: Exception) {
                android.util.Log.e("Settings", "Error parsing app list", e)
                emptyList()
            }
        }
        set(value) {
            val jsonArray = org.json.JSONArray()
            value.forEach { jsonArray.put(it) }
            preferences.edit().putString("per_app_proxy_list", jsonArray.toString()).apply()
        }
    
    var activeConfigPath: String = ""
    var activeProfileName: String = "Default Profile"
    var serviceMode: String = ServiceMode.VPN
    var configOptions: String = ""
    var debugMode: Boolean = false
    var disableMemoryLimit: Boolean = false
    var dynamicNotification: Boolean = true
    var systemProxyEnabled: Boolean = true
    var startedByUser: Boolean = false

    fun serviceClass(): Class<*> {
        // Always return VPNService for simplicity
        return VPNService::class.java
    }

    private var currentServiceMode: String? = null

    suspend fun rebuildServiceMode(): Boolean {
        // Always use VPN mode
        var newMode = ServiceMode.VPN
        
        if (currentServiceMode == newMode) {
            return false
        }
        currentServiceMode = newMode
        return true
    }

    private suspend fun needVPNService(): Boolean {
        // Simplified implementation - assume we always need VPN service
        return true
    }
}