package com.tecclub.flutter_singbox.utils

import com.tecclub.flutter_singbox.constant.TrafficStats
import io.nekohasekai.libbox.StatusMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * A client to connect to the sing-box service and receive status updates
 */
class StatusClient(
    private val scope: CoroutineScope,
    private val handler: Handler
) {
    private val commandClient = CommandClient(
        scope,
        CommandClient.ConnectionType.Status,
        object : CommandClient.Handler {
            override fun updateStatus(status: StatusMessage) {
                handler.onStatusUpdate(status)
            }
        }
    )

    fun connect() {
        // Don't reconnect if already connected - this prevents race conditions
        if (commandClient.isConnected()) {
            android.util.Log.e("StatusClient", "Already connected to status server, skipping connect")
            return
        }
        
        android.util.Log.e("StatusClient", "Connecting to status server")
        scope.launch(Dispatchers.IO) {
            try {
                commandClient.connect()
                android.util.Log.e("StatusClient", "Successfully connected to status server")
            } catch (e: Exception) {
                android.util.Log.e("StatusClient", "Error connecting to status server", e)
            }
        }
    }

    fun disconnect() {
        android.util.Log.e("StatusClient", "Disconnecting from status server")
        scope.launch(Dispatchers.IO) {
            try {
                commandClient.disconnect()
                android.util.Log.e("StatusClient", "Successfully disconnected from status server")
            } catch (e: Exception) {
                android.util.Log.e("StatusClient", "Error disconnecting from status server", e)
            }
        }
    }
    
    // Check if client is connected
    fun isConnected(): Boolean {
        return commandClient.isConnected()
    }

    interface Handler {
        fun onStatusUpdate(status: StatusMessage)
    }
}