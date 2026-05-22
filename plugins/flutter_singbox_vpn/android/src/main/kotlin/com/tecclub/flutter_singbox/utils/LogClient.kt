package com.tecclub.flutter_singbox.utils

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * A client to connect to the sing-box service and receive log updates
 */
class LogClient(
    private val scope: CoroutineScope,
    private val handler: Handler
) {
    private val commandClient = CommandClient(
        scope,
        CommandClient.ConnectionType.Log,
        object : CommandClient.Handler {
            override fun onConnected() {
                handler.onConnected()
            }
            
            override fun onDisconnected() {
                handler.onDisconnected()
            }
            
            override fun clearLog() {
                handler.clearLogs()
            }
            
            override fun appendLog(message: String) {
                handler.appendLog(message)
            }
        }
    )

    fun connect() {
        // Don't reconnect if already connected - this prevents race conditions
        if (commandClient.isConnected()) {
            android.util.Log.d("LogClient", "Already connected to log server, skipping connect")
            return
        }
        
        android.util.Log.d("LogClient", "Connecting to log server")
        scope.launch(Dispatchers.IO) {
            try {
                commandClient.connect()
                android.util.Log.d("LogClient", "Successfully connected to log server")
            } catch (e: Exception) {
                android.util.Log.e("LogClient", "Error connecting to log server", e)
            }
        }
    }

    fun disconnect() {
        android.util.Log.d("LogClient", "Disconnecting from log server")
        scope.launch(Dispatchers.IO) {
            try {
                commandClient.disconnect()
                android.util.Log.d("LogClient", "Successfully disconnected from log server")
            } catch (e: Exception) {
                android.util.Log.e("LogClient", "Error disconnecting from log server", e)
            }
        }
    }
    
    fun isConnected(): Boolean {
        return commandClient.isConnected()
    }

    interface Handler {
        fun onConnected()
        fun onDisconnected()
        fun clearLogs()
        fun appendLog(message: String)
    }
}
