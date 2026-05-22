// package com.tecclub.flutter_singbox

// import android.Manifest
// import android.annotation.SuppressLint
// import android.content.BroadcastReceiver
// import android.content.Context
// import android.content.Intent
// import android.content.IntentFilter
// import android.net.VpnService
// import android.os.Bundle
// import android.widget.Toast
// import androidx.activity.ComponentActivity
// import androidx.activity.compose.setContent
// import androidx.activity.enableEdgeToEdge
// import androidx.activity.result.contract.ActivityResultContracts
// import androidx.compose.foundation.layout.*
// import androidx.compose.foundation.rememberScrollState
// import androidx.compose.foundation.verticalScroll
// import androidx.compose.material3.*
// import androidx.compose.runtime.*
// import io.nekohasekai.libbox.StatusMessage
// import com.tecclub.flutter_singbox.utils.StatusClient
// import androidx.compose.ui.Alignment
// import androidx.compose.ui.Modifier
// import androidx.compose.ui.text.font.FontWeight
// import androidx.compose.ui.unit.dp
// import androidx.core.content.ContextCompat
// import androidx.lifecycle.lifecycleScope
// import kotlinx.coroutines.launch
// import com.tecclub.flutter_singbox.bg.BoxService
// import com.tecclub.flutter_singbox.bg.ServiceConnection
// import com.tecclub.flutter_singbox.config.SimpleConfigManager
// import com.tecclub.flutter_singbox.constant.Action
// import com.tecclub.flutter_singbox.constant.Alert
// import com.tecclub.flutter_singbox.constant.Status
// import com.tecclub.flutter_singbox.constant.ServiceMode
// import com.tecclub.flutter_singbox.bg.ServiceNotification
// import com.tecclub.flutter_singbox.database.Settings
// import com.tecclub.flutter_singbox.ui.theme.SingBoxAndroidTheme
// import kotlinx.coroutines.Dispatchers
// import kotlinx.coroutines.launch
// import kotlinx.coroutines.withContext

// class SimplifiedMainActivity : ComponentActivity(), ServiceConnection.Callback, StatusClient.Handler {

//     private var isConnected = mutableStateOf(false)
//     private var configText = mutableStateOf("")
//     private var vpnStatus = mutableStateOf(Status.Stopped)
//     private var uplinkSpeed = mutableStateOf(0L)
//     private var downlinkSpeed = mutableStateOf(0L)
//     private var uplinkTotal = mutableStateOf(0L)
//     private var downlinkTotal = mutableStateOf(0L)
//     private var connectionsIn = mutableStateOf(0)
//     private var connectionsOut = mutableStateOf(0)
    
//     // Session data tracking (reset when connection starts)
//     private var sessionStartTime = mutableStateOf(0L)
//     private var sessionStartUplinkTotal = mutableStateOf(0L)
//     private var sessionStartDownlinkTotal = mutableStateOf(0L)
//     private var sessionUplinkTotal = mutableStateOf(0L)
//     private var sessionDownlinkTotal = mutableStateOf(0L)
    
//     private val connection = ServiceConnection(this, this, false)
//     private val statusClient by lazy { StatusClient(lifecycleScope, this) }


//     override fun onServiceStatusChanged(status: Status) {
//         android.util.Log.d("SimplifiedMainActivity", "Service status changed to: $status")
//         vpnStatus.value = status
//         isConnected.value = status == Status.Started
        
//         // Connect or disconnect the status client based on the connection state
//         if (status == Status.Started) {
//             // Reset session data when connection starts
//             sessionStartTime.value = System.currentTimeMillis()
//             // We'll set the start totals in the first onStatusUpdate callback
//             // For now, just initialize session totals to 0
//             sessionUplinkTotal.value = 0L
//             sessionDownlinkTotal.value = 0L
//             statusClient.connect()
//         } else if (status == Status.Stopped) {
//             statusClient.disconnect()
//         }
        
//         // Show a toast with the new status for debugging
//         val statusText = when (status) {
//             Status.Stopped -> "VPN Disconnected"
//             Status.Starting -> "VPN Connecting..."
//             Status.Started -> "VPN Connected"
//             Status.Stopping -> "VPN Disconnecting..."
//         }
//         Toast.makeText(this, statusText, Toast.LENGTH_SHORT).show()
//     }
    
//     override fun onStatusUpdate(status: StatusMessage) {
//         android.util.Log.d("SimplifiedMainActivity", "Status update received: in=${status.connectionsIn}, out=${status.connectionsOut}, up=${status.uplink}, down=${status.downlink}")
//         uplinkSpeed.value = status.uplink
//         downlinkSpeed.value = status.downlink
//         uplinkTotal.value = status.uplinkTotal
//         downlinkTotal.value = status.downlinkTotal
//         connectionsIn.value = status.connectionsIn
//         connectionsOut.value = status.connectionsOut
        
//         // If this is the first status update after connecting, store the starting totals
//         if (sessionStartTime.value > 0 && sessionStartUplinkTotal.value == 0L && sessionStartDownlinkTotal.value == 0L) {
//             sessionStartUplinkTotal.value = status.uplinkTotal
//             sessionStartDownlinkTotal.value = status.downlinkTotal
//             android.util.Log.d("SimplifiedMainActivity", "Session start values initialized: up=${sessionStartUplinkTotal.value}, down=${sessionStartDownlinkTotal.value}")
//         }
        
//         // Calculate session data as the difference between current totals and starting totals
//         sessionUplinkTotal.value = status.uplinkTotal - sessionStartUplinkTotal.value
//         sessionDownlinkTotal.value = status.downlinkTotal - sessionStartDownlinkTotal.value
        
//         android.util.Log.d("SimplifiedMainActivity", "Session data: up=${sessionUplinkTotal.value}, down=${sessionDownlinkTotal.value}")
//     }
//     private val vpnPermissionLauncher = registerForActivityResult(
//         ActivityResultContracts.StartActivityForResult()
//     ) { result ->
//         if (result.resultCode == RESULT_OK) {
//             startVpn()
//         } else {
//             Toast.makeText(this, "VPN permission denied", Toast.LENGTH_SHORT).show()
//         }
//     }
    
//     private val statusReceiver = object : BroadcastReceiver() {
//         override fun onReceive(context: Context?, intent: Intent?) {
//             if (intent?.action == Action.BROADCAST_STATUS_CHANGED) {
//                 val statusOrdinal = intent.getIntExtra(Action.EXTRA_STATUS, Status.Stopped.ordinal)
//                 val status = Status.values()[statusOrdinal]
                
//                 // Log the received status
//                 android.util.Log.d("SimplifiedMainActivity", "Received status broadcast: $status")
                
//                 // Update UI state
//                 vpnStatus.value = status
//                 isConnected.value = status == Status.Started
                
//                 // Show a toast with the new status
//                 val statusText = when (status) {
//                     Status.Stopped -> "VPN Disconnected"
//                     Status.Starting -> "VPN Connecting..."
//                     Status.Started -> "VPN Connected"
//                     Status.Stopping -> "VPN Disconnecting..."
//                 }
//                 Toast.makeText(context, "Broadcast: $statusText", Toast.LENGTH_SHORT).show()
//             }
//         }
//     }
    
//     private val alertReceiver = object : BroadcastReceiver() {
//         override fun onReceive(context: Context?, intent: Intent?) {
//             if (intent?.action == Action.BROADCAST_ALERT) {
//                 val alertOrdinal = intent.getIntExtra(Action.EXTRA_ALERT, -1)
//                 val message = intent.getStringExtra(Action.EXTRA_ALERT_MESSAGE)
                
//                 val alertMessage = if (alertOrdinal >= 0 && alertOrdinal < Alert.values().size) {
//                     when (Alert.values()[alertOrdinal]) {
//                         Alert.EmptyConfiguration -> "Empty configuration"
//                         Alert.StartService -> "Failed to start service${if (message?.isNotEmpty() == true) ": $message" else ""}"
//                         Alert.CreateService -> "Failed to create service${if (message?.isNotEmpty() == true) ": $message" else ""}"
//                         Alert.VpnNoAddress -> "No VPN address configured"
//                         else -> "Error: ${if (message?.isNotEmpty() == true) message else "Unknown issue"}"
//                     }
//                 } else {
//                     "Unknown error"
//                 }
                
//                 Toast.makeText(this@SimplifiedMainActivity, alertMessage, Toast.LENGTH_LONG).show()
//             }
//         }
//     }

//     // Traffic stats receiver
//     // No longer need a separate trafficReceiver since we're using StatusClient

//     override fun onCreate(savedInstanceState: Bundle?) {
//         super.onCreate(savedInstanceState)
//         enableEdgeToEdge()
        
//         // Load saved configuration
//         loadConfig()
        
//         // Register receivers with RECEIVER_NOT_EXPORTED flag for Android 12+ compatibility
//         registerReceiver(statusReceiver, IntentFilter(Action.BROADCAST_STATUS_CHANGED), 
//             Context.RECEIVER_NOT_EXPORTED)
//         registerReceiver(alertReceiver, IntentFilter(Action.BROADCAST_ALERT), 
//             Context.RECEIVER_NOT_EXPORTED)
        
//         setContent {
//             SingBoxAndroidTheme {
//                 Surface(
//                     modifier = Modifier.fillMaxSize(),
//                     color = MaterialTheme.colorScheme.background
//                 ) {
//                     MainScreen()
//                 }
//             }
//         }
        
//         // Try to connect to service to get current status when the app starts
//         checkServiceStatus()
//     }
    
//     override fun onDestroy() {
//         super.onDestroy()
//         try {
//             unregisterReceiver(statusReceiver)
//             unregisterReceiver(alertReceiver)
//         } catch (e: Exception) {
//             // Ignore if receivers not registered
//         }
        
//         // Disconnect status client
//         statusClient.disconnect()
//     }
    
//     // Variable to hold the periodic status check job
//     private var statusCheckJob: kotlinx.coroutines.Job? = null
    
//     override fun onResume() {
//         super.onResume()
//         // Check service status when app is reopened
//         checkServiceStatus()
        
//         // Setup periodic status checking
//         statusCheckJob = lifecycleScope.launch {
//             while (true) {
//                 kotlinx.coroutines.delay(5000) // Check every 5 seconds
//                 checkServiceStatus()
//             }
//         }
        
//         // Connect to status client if VPN is running
//         if (vpnStatus.value == Status.Started) {
//             statusClient.connect()
//         }
//     }
    
//     override fun onPause() {
//         super.onPause()
//         // Cancel the periodic status check when app is paused
//         statusCheckJob?.cancel()
//         statusCheckJob = null
        
//         // We'll keep the status client connected even when paused
//         // The service will still be running in the background
//     }
    
//     private fun checkServiceStatus() {
//         android.util.Log.d("SimplifiedMainActivity", "Checking service status...")
//         lifecycleScope.launch {
//             try {
//                 // Check if VPN service is running using Android's ActivityManager
//                 val manager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
//                 val isServiceRunning = withContext(Dispatchers.IO) {
//                     manager.getRunningServices(Integer.MAX_VALUE).any { 
//                         it.service.className.contains("VPNService") 
//                     }
//                 }
                
//                 if (isServiceRunning) {
//                     android.util.Log.d("SimplifiedMainActivity", "VPN service appears to be running")
//                     // If service is running, connect to it to get the current status
//                     connection.connect()
//                 } else {
//                     android.util.Log.d("SimplifiedMainActivity", "VPN service is not running")
//                     // If service is not running, update UI to Stopped
//                     vpnStatus.value = Status.Stopped
//                     isConnected.value = false
//                 }
//             } catch (e: Exception) {
//                 android.util.Log.e("SimplifiedMainActivity", "Error checking service status", e)
//                 // VPN service might not be running
//                 vpnStatus.value = Status.Stopped
//                 isConnected.value = false
//             }
//         }
//     }
    
//     private fun loadConfig() {
//         val savedConfig = SimpleConfigManager.getConfig()
//         if (savedConfig.isNotEmpty() && savedConfig != "{}") {
//             configText.value = savedConfig
//         }
//     }
    
//     @Composable
//     fun MainScreen() {
//         var config by remember { mutableStateOf(configText.value) }
//         var connected by remember { isConnected }
//         var status by remember { vpnStatus }
        
//         Column(
//             modifier = Modifier
//                 .fillMaxSize()
//                 .padding(16.dp)
//                 .verticalScroll(rememberScrollState()),
//             horizontalAlignment = Alignment.CenterHorizontally,
//             verticalArrangement = Arrangement.spacedBy(16.dp)
//         ) {
//             Text(
//                 text = "SingBox VPN Configuration",
//                 style = MaterialTheme.typography.headlineSmall,
//                 fontWeight = FontWeight.Bold
//             )
            
//             Spacer(modifier = Modifier.height(16.dp))
            
//             // Status card
//             Card(
//                 modifier = Modifier.fillMaxWidth(),
//                 elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//             ) {
//                 Column(
//                     modifier = Modifier
//                         .fillMaxWidth()
//                         .padding(16.dp),
//                     horizontalAlignment = Alignment.CenterHorizontally
//                 ) {
//                     val statusText = when (status) {
//                         Status.Stopped -> "Disconnected"
//                         Status.Starting -> "Connecting..."
//                         Status.Started -> "Connected"
//                         Status.Stopping -> "Disconnecting..."
//                         else -> "Unknown"
//                     }
                    
//                     val statusColor = when (status) {
//                         Status.Started -> MaterialTheme.colorScheme.primary
//                         Status.Stopped -> MaterialTheme.colorScheme.error
//                         else -> MaterialTheme.colorScheme.tertiary
//                     }
                    
//                     Text(
//                         text = "Status: $statusText",
//                         style = MaterialTheme.typography.bodyLarge,
//                         color = statusColor
//                     )
                    
//                     Spacer(modifier = Modifier.height(8.dp))
                    
//                     // Traffic stats
                    
//                     if (status == Status.Started) {
//                         // Traffic info
//                         Card(
//                             modifier = Modifier.fillMaxWidth(),
//                             colors = CardDefaults.cardColors(
//                                 containerColor = MaterialTheme.colorScheme.primaryContainer
//                             )
//                         ) {
//                             Column(
//                                 modifier = Modifier.padding(12.dp),
//                                 horizontalAlignment = Alignment.CenterHorizontally
//                             ) {
//                                 Text(
//                                     text = "Traffic Statistics",
//                                     style = MaterialTheme.typography.titleMedium,
//                                     fontWeight = FontWeight.Bold
//                                 )
                                
//                                 Spacer(modifier = Modifier.height(8.dp))
                                
//                                 // Current speed
//                                 val upSpeed by remember { uplinkSpeed }
//                                 val downSpeed by remember { downlinkSpeed }
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Upload Speed:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(upSpeed) + "/s")
//                                 }
                                
//                                 Spacer(modifier = Modifier.height(4.dp))
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Download Speed:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(downSpeed) + "/s")
//                                 }
                                
//                                 Divider(modifier = Modifier.padding(vertical = 8.dp))
                                
//                                 // Current session data usage
//                                 val sessionUpTotal by remember { sessionUplinkTotal }
//                                 val sessionDownTotal by remember { sessionDownlinkTotal }
//                                 val sessionTotalData = sessionUpTotal + sessionDownTotal
                                
//                                 // Session start time
//                                 val startTime by remember { sessionStartTime }
//                                 val sessionDuration = if (startTime > 0) {
//                                     val durationMs = System.currentTimeMillis() - startTime
//                                     val minutes = durationMs / 60000
//                                     val seconds = (durationMs % 60000) / 1000
//                                     String.format("%02d:%02d", minutes, seconds)
//                                 } else {
//                                     "00:00"
//                                 }
                                
//                                 // Session data card with border
//                                 Card(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     colors = CardDefaults.cardColors(
//                                         containerColor = MaterialTheme.colorScheme.secondaryContainer
//                                     )
//                                 ) {
//                                     Column(
//                                         modifier = Modifier.padding(8.dp)
//                                     ) {
//                                         Row(
//                                             modifier = Modifier.fillMaxWidth(),
//                                             horizontalArrangement = Arrangement.SpaceBetween
//                                         ) {
//                                             Text(
//                                                 text = "Current Session Data:",
//                                                 fontWeight = FontWeight.Bold
//                                             )
//                                             Text(
//                                                 text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(sessionTotalData),
//                                                 fontWeight = FontWeight.Bold
//                                             )
//                                         }
                                        
//                                         Spacer(modifier = Modifier.height(4.dp))
                                        
//                                         Row(
//                                             modifier = Modifier.fillMaxWidth(),
//                                             horizontalArrangement = Arrangement.SpaceBetween
//                                         ) {
//                                             Text(text = "Session Duration:", fontWeight = FontWeight.SemiBold)
//                                             Text(text = sessionDuration)
//                                         }
//                                     }
//                                 }
                                
//                                 Spacer(modifier = Modifier.height(12.dp))
                                
//                                 // Total transferred (lifetime)
//                                 val upTotal by remember { uplinkTotal }
//                                 val downTotal by remember { downlinkTotal }
//                                 val totalData = upTotal + downTotal
                                
//                                 Text(
//                                     text = "Lifetime Statistics",
//                                     style = MaterialTheme.typography.titleSmall,
//                                     fontWeight = FontWeight.Bold,
//                                     modifier = Modifier.padding(vertical = 4.dp)
//                                 )
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Total Data:", fontWeight = FontWeight.SemiBold)
//                                     Text(
//                                         text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(totalData),
//                                         fontWeight = FontWeight.SemiBold
//                                     )
//                                 }
                                
//                                 Spacer(modifier = Modifier.height(4.dp))
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Upload Total:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(upTotal))
//                                 }
                                
//                                 Spacer(modifier = Modifier.height(4.dp))
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Download Total:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = com.tecclub.flutter_singbox.constant.TrafficStats.formatBytes(downTotal))
//                                 }
                                
//                                 Divider(modifier = Modifier.padding(vertical = 8.dp))
                                
//                                 // Connections
//                                 val connIn by remember { connectionsIn }
//                                 val connOut by remember { connectionsOut }
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Connections In:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = "$connIn")
//                                 }
                                
//                                 Spacer(modifier = Modifier.height(4.dp))
                                
//                                 Row(
//                                     modifier = Modifier.fillMaxWidth(),
//                                     horizontalArrangement = Arrangement.SpaceBetween
//                                 ) {
//                                     Text(text = "Connections Out:", fontWeight = FontWeight.SemiBold)
//                                     Text(text = "$connOut")
//                                 }
//                             }
//                         }
//                     }
                    
//                     Spacer(modifier = Modifier.height(16.dp))
                    
//                     Button(
//                         onClick = {
//                             if (connected) {
//                                 stopVpn()
//                             } else {
//                                 requestVpnPermission()
//                             }
//                         },
//                         modifier = Modifier.fillMaxWidth(),
//                         enabled = status == Status.Started || status == Status.Stopped
//                     ) {
//                         Text(if (connected) "Disconnect" else "Connect")
//                     }
//                 }
//             }
            
//             // Config card
//             Card(
//                 modifier = Modifier.fillMaxWidth(),
//                 elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//             ) {
//                 Column(
//                     modifier = Modifier
//                         .fillMaxWidth()
//                         .padding(16.dp)
//                 ) {
//                     Text(
//                         text = "Configuration",
//                         style = MaterialTheme.typography.titleMedium,
//                         fontWeight = FontWeight.Bold
//                     )
                    
//                     Spacer(modifier = Modifier.height(8.dp))
                    
//                     TextField(
//                         value = config,
//                         onValueChange = { config = it },
//                         modifier = Modifier.fillMaxWidth(),
//                         label = { Text("JSON Configuration") },
//                         placeholder = { Text("Enter your sing-box JSON configuration here...") },
//                         minLines = 8
//                     )
                    
//                     Spacer(modifier = Modifier.height(16.dp))
                    
//                     Button(
//                         onClick = { saveConfig(config) },
//                         modifier = Modifier.fillMaxWidth()
//                     ) {
//                         Text("Save Configuration")
//                     }
//                 }
//             }
            
//             // Instructions
//             Card(
//                 modifier = Modifier.fillMaxWidth(),
//                 elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//             ) {
//                 Column(
//                     modifier = Modifier
//                         .fillMaxWidth()
//                         .padding(16.dp)
//                 ) {
//                     Text(
//                         text = "Usage Instructions",
//                         style = MaterialTheme.typography.titleMedium,
//                         fontWeight = FontWeight.Bold
//                     )
                    
//                     Spacer(modifier = Modifier.height(8.dp))
                    
//                     Text(
//                         "1. Paste your sing-box JSON configuration in the text field above.",
//                         style = MaterialTheme.typography.bodyMedium
//                     )
//                     Text(
//                         "2. Tap the 'Save Configuration' button.",
//                         style = MaterialTheme.typography.bodyMedium
//                     )
//                     Text(
//                         "3. Tap the 'Connect' button to connect to the VPN.",
//                         style = MaterialTheme.typography.bodyMedium
//                     )
//                     Text(
//                         "4. To disconnect, tap the 'Disconnect' button.",
//                         style = MaterialTheme.typography.bodyMedium
//                     )
//                 }
//             }
//         }
//     }
    
//     private fun saveConfig(config: String) {
//         lifecycleScope.launch {
//             try {
//                 val success = SimpleConfigManager.saveConfig(config)
//                 if (success) {
//                     configText.value = config
//                     Toast.makeText(this@SimplifiedMainActivity, "Configuration saved", Toast.LENGTH_SHORT).show()
//                 } else {
//                     Toast.makeText(this@SimplifiedMainActivity, "Failed to save configuration", Toast.LENGTH_SHORT).show()
//                 }
//             } catch (e: Exception) {
//                 Toast.makeText(this@SimplifiedMainActivity, "Error saving config: ${e.message}", Toast.LENGTH_SHORT).show()
//             }
//         }
//     }
    
//     private fun requestVpnPermission() {
//         val intent = VpnService.prepare(this)
//         if (intent != null) {
//             vpnPermissionLauncher.launch(intent)
//         } else {
//             startVpn()
//         }
//     }
    
//     private fun startVpn() {
//         try {
//             // Update local status to Starting immediately for UI responsiveness
//             vpnStatus.value = Status.Starting
//             isConnected.value = false
            
//             // Start the service
//             startService()
            
//             // Connect to the service to receive status updates
//             connection.connect()
            
//             // Update UI with toast
//             Toast.makeText(this, "Starting VPN service...", Toast.LENGTH_SHORT).show()
            
//             // Schedule a status check after a delay to catch any missed status updates
//             lifecycleScope.launch {
//                 kotlinx.coroutines.delay(2000) // Check after 2 seconds
//                 checkServiceStatus()
//             }
//         } catch (e: Exception) {
//             // Reset status if there was an error
//             vpnStatus.value = Status.Stopped
//             isConnected.value = false
//             Toast.makeText(this, "Failed to start VPN: ${e.message}", Toast.LENGTH_SHORT).show()
//         }
//     }

//     @SuppressLint("NewApi")
//     fun startService() {
// //        if (!ServiceNotification().) {
// //            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
// //            return
// //        }
//         startService0()
//     }

//     fun reconnect() {
//         connection.reconnect()
//     }

//     private fun startService0() {
//         lifecycleScope.launch(Dispatchers.IO) {
//             if (Settings.rebuildServiceMode()) {
//                 reconnect()
//             }
//             if (Settings.serviceMode == ServiceMode.VPN) {
//                 if (prepare()) {
//                     return@launch
//                 }
//             }
//             val intent = Intent(Application.application, Settings.serviceClass())
//             withContext(Dispatchers.Main) {
//                 ContextCompat.startForegroundService(Application.application, intent)
//             }
//         }
//     }

//     private suspend fun prepare() = withContext(Dispatchers.Main) {
//         try {
//             val intent = VpnService.prepare(this@SimplifiedMainActivity)
//             if (intent != null) {
//                 startVpn()
//                 true
//             } else {
//                 false
//             }
//         } catch (e: Exception) {
//             onServiceAlert(Alert.RequestVPNPermission, e.message)
//             false
//         }
//     }
// //    private val prepareLauncher = registerForActivityResult(PrepareService()) {
// //        if (it) {
// //            startService()
// //        } else {
// //            onServiceAlert(Alert.RequestVPNPermission, null)
// //        }
// //    }

//     private val notificationPermissionLauncher = registerForActivityResult(
//         ActivityResultContracts.RequestPermission()
//     ) {
//         if (Settings.dynamicNotification && !it) {
//             onServiceAlert(Alert.RequestNotificationPermission, null)
//         } else {
//             startService0()
//         }
//     }


    
//     private fun stopVpn() {
//         try {
//             // Update local status to Stopping immediately for UI responsiveness
//             vpnStatus.value = Status.Stopping
//             isConnected.value = false
            
//             // Send broadcast to stop the service
//             Application.application.sendBroadcast(
//                 Intent(Action.SERVICE_CLOSE).setPackage(
//                     Application.application.packageName
//                 )
//             )
            
//             // Disconnect from service
//             connection.disconnect()
            
//             // Update UI with toast
//             Toast.makeText(this, "Stopping VPN service...", Toast.LENGTH_SHORT).show()
            
//             // After a brief delay, update to Stopped if not already updated by the receiver
//             lifecycleScope.launch {
//                 kotlinx.coroutines.delay(1500) // Wait 1.5 seconds
//                 if (vpnStatus.value == Status.Stopping) {
//                     vpnStatus.value = Status.Stopped
//                 }
                
//                 // Schedule one more check after additional delay to ensure status is correct
//                 kotlinx.coroutines.delay(1000) // Wait another second
//                 checkServiceStatus()
//             }
//         } catch (e: Exception) {
//             Toast.makeText(this, "Failed to stop VPN: ${e.message}", Toast.LENGTH_SHORT).show()
//         }
//     }
// }

