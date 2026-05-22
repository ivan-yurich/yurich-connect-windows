package com.tecclub.flutter_singbox.bg

/**
 * Callback interface for service status changes and alerts
 */
interface ServiceCallback {
    fun onServiceStatusChanged(status: Int)
    fun onServiceAlert(type: Int, message: String?)
    fun onTrafficUpdate(uploadBytes: Long, downloadBytes: Long)
}