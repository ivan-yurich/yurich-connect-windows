// package com.tecclub.flutter_singbox

// import android.app.Activity
// import android.content.Intent
// import android.net.VpnService
// import android.os.Bundle
// import android.util.Log
// import android.widget.Toast
// import androidx.compose.material3.Button
// import androidx.compose.material3.Card
// import androidx.compose.material3.CardDefaults
// import androidx.compose.material3.CircularProgressIndicator
// import androidx.compose.material3.Divider
// import androidx.compose.material3.MaterialTheme
// import androidx.compose.material3.Scaffold
// import androidx.compose.material3.Surface
// import androidx.compose.material3.Text
// import androidx.compose.material3.TextField
// import androidx.compose.runtime.Composable
// import androidx.compose.runtime.LaunchedEffect
// import androidx.compose.runtime.getValue
// import androidx.compose.runtime.livedata.observeAsState
// import androidx.compose.runtime.mutableStateOf
// import androidx.compose.runtime.remember
// import androidx.compose.runtime.rememberCoroutineScope
// import androidx.compose.runtime.setValue
// import androidx.compose.ui.Alignment
// import androidx.compose.ui.Modifier
// import androidx.compose.ui.platform.LocalContext
// import androidx.compose.ui.text.font.FontWeight
// import androidx.compose.ui.unit.dp
// import androidx.lifecycle.MutableLiveData
// import androidx.lifecycle.lifecycleScope
// import com.tecclub.flutter_singbox.bg.BoxService
// import com.tecclub.flutter_singbox.bg.ServiceConnection
// import com.tecclub.flutter_singbox.config.SimpleConfigManager
// import com.tecclub.flutter_singbox.constant.Alert
// import com.tecclub.flutter_singbox.constant.Status
// import com.tecclub.flutter_singbox.ui.theme.SingBoxAndroidTheme
// import kotlinx.coroutines.launch

// class MainActivity : ComponentActivity(), ServiceConnection.Callback {

//     private val connection = ServiceConnection(this, this, true)
//     val serviceStatus = MutableLiveData(Status.Stopped)
//     var configLoaded = MutableLiveData(false)
//     var configText = MutableLiveData("")
    
//     private val vpnPermissionLauncher = registerForActivityResult(
//         ActivityResultContracts.StartActivityForResult()
//     ) { result ->
//         if (result.resultCode == RESULT_OK) {
//             BoxService.start()
//         } else {
//             Toast.makeText(this, "VPN permission denied", Toast.LENGTH_SHORT).show()
//         }
//     }

//     override fun onCreate(savedInstanceState: Bundle?) {
//         super.onCreate(savedInstanceState)
//         enableEdgeToEdge()
        
//         // Load config
//         loadConfig()
        
//         setContent {
//             SingBoxAndroidTheme {
//                 Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
//                     MainScreen(
//                         serviceStatus = serviceStatus,
//                         configLoaded = configLoaded,
//                         configText = configText,
//                         onConfigSave = { config ->
//                             saveConfig(config)
//                         },
//                         modifier = Modifier.padding(innerPadding)
//                     )
//                 }
//             }
//         }
        
//         reconnect()
//     }
    
//     private fun loadConfig() {
//         lifecycleScope.launch {
//             try {
//                 val config = SimpleConfigManager.getConfig()
//                 configText.value = config
//                 configLoaded.value = true
//             } catch (e: Exception) {
//                 Toast.makeText(this@MainActivity, "Failed to load configuration: ${e.message}", Toast.LENGTH_SHORT).show()
//             }
//         }
//     }
    
//     private fun saveConfig(config: String) {
//         lifecycleScope.launch {
//             try {
//                 val success = SimpleConfigManager.saveConfig(config)
//                 if (success) {
//                     Toast.makeText(this@MainActivity, "Configuration saved successfully", Toast.LENGTH_SHORT).show()
//                     configText.value = config
//                 } else {
//                     Toast.makeText(this@MainActivity, "Failed to save configuration", Toast.LENGTH_SHORT).show()
//                 }
//             } catch (e: Exception) {
//                 Toast.makeText(this@MainActivity, "Error saving configuration: ${e.message}", Toast.LENGTH_SHORT).show()
//             }
//         }
//     }
    
//     override fun onResume() {
//         super.onResume()
//         reconnect()
//     }
    
//     override fun onDestroy() {
//         super.onDestroy()
//         connection.disconnect()
//     }
    
//     private fun reconnect() {
//         connection.connect()
//     }
    
//     override fun onServiceStatusChanged(status: Status) {
//         // log status

//         serviceStatus.value = status
//     }
    
//     override fun onServiceAlert(type: Alert, message: String?) {
//         runOnUiThread {
//             when (type) {
//                 Alert.EmptyConfiguration -> Toast.makeText(this, "Empty configuration", Toast.LENGTH_SHORT).show()
//                 Alert.RequestLocationPermission -> Toast.makeText(this, "Location permission needed", Toast.LENGTH_SHORT).show()
//                 Alert.StartService -> Toast.makeText(this, "Failed to start service: $message", Toast.LENGTH_SHORT).show()
//                 Alert.CreateService -> Toast.makeText(this, "Failed to create service: $message", Toast.LENGTH_SHORT).show()
//                 Alert.RequestVPNPermission -> Toast.makeText(this, "VPN permission needed", Toast.LENGTH_SHORT).show()
//                 Alert.RequestNotificationPermission -> Toast.makeText(this, "Notification permission needed", Toast.LENGTH_SHORT).show()
//                 Alert.StartCommandServer -> Toast.makeText(this, "Failed to start command server: $message", Toast.LENGTH_SHORT).show()
//                 Alert.VpnNoAddress -> Toast.makeText(this, "VPN no address", Toast.LENGTH_SHORT).show()
//             }
//         }
//     }
    
//     fun toggleVPN() {
//         if (serviceStatus.value == Status.Started || serviceStatus.value == Status.Starting) {
//             // Stop VPN
//             BoxService.stop()
//         } else {
//             // Start VPN
//             val intent = VpnService.prepare(this)
//             if (intent != null) {
//                 vpnPermissionLauncher.launch(intent)
//             } else {
//                 BoxService.start()
//             }
//         }
//     }
// }

// @Composable
// fun MainScreen(
//     serviceStatus: MutableLiveData<Status>,
//     configLoaded: MutableLiveData<Boolean>,
//     configText: MutableLiveData<String>,
//     onConfigSave: (String) -> Unit,
//     modifier: Modifier = Modifier
// ) {
//     val context = LocalContext.current
//     val status by serviceStatus.observeAsState(Status.Stopped)
//     val isConfigLoaded by configLoaded.observeAsState(false)
//     val currentConfig by configText.observeAsState("")
    
//     var configInput by remember { mutableStateOf("") }
//     var statusText by remember { mutableStateOf("Stopped") }
//     var buttonText by remember { mutableStateOf("Start VPN") }
//     val scope = rememberCoroutineScope()
    
//     // Initialize config input with loaded config
//     LaunchedEffect(currentConfig) {
//         if (currentConfig.isNotEmpty() && configInput.isEmpty()) {
//             configInput = currentConfig
//         }
//     }
    
//     LaunchedEffect(status) {
//         statusText = when (status) {
//             Status.Stopped -> "Stopped"
//             Status.Starting -> "Starting..."
//             Status.Started -> "Connected"
//             Status.Stopping -> "Stopping..."
//         }
        
//         buttonText = if (status == Status.Started || status == Status.Starting) {
//             "Stop VPN"
//         } else {
//             "Start VPN"
//         }
//     }
    
//     Column(
//         modifier = modifier
//             .fillMaxSize()
//             .padding(16.dp)
//             .verticalScroll(rememberScrollState()),
//         horizontalAlignment = Alignment.CenterHorizontally,
//         verticalArrangement = Arrangement.spacedBy(16.dp)
//     ) {
//         // Status Card
//         Card(
//             modifier = Modifier.fillMaxWidth(),
//             elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//         ) {
//             Column(
//                 modifier = Modifier
//                     .fillMaxWidth()
//                     .padding(16.dp),
//                 horizontalAlignment = Alignment.CenterHorizontally
//             ) {
//                 Text(
//                     text = "VPN Status",
//                     style = MaterialTheme.typography.titleMedium,
//                     fontWeight = FontWeight.Bold
//                 )
                
//                 Spacer(modifier = Modifier.height(8.dp))
                
//                 Text(
//                     text = statusText,
//                     style = MaterialTheme.typography.bodyLarge,
//                     color = when (status) {
//                         Status.Started -> MaterialTheme.colorScheme.primary
//                         Status.Stopped -> MaterialTheme.colorScheme.error
//                         else -> MaterialTheme.colorScheme.onSurface
//                     }
//                 )
                
//                 Spacer(modifier = Modifier.height(16.dp))
                
//                 Button(
//                     onClick = {
//                         (context as? MainActivity)?.toggleVPN()
//                     },
//                     modifier = Modifier.fillMaxWidth()
//                 ) {
//                     Text(buttonText)
//                 }
//             }
//         }
        
//         // Config Card
//         Card(
//             modifier = Modifier.fillMaxWidth(),
//             elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//         ) {
//             Column(
//                 modifier = Modifier
//                     .fillMaxWidth()
//                     .padding(16.dp)
//             ) {
//                 Text(
//                     text = "Configuration",
//                     style = MaterialTheme.typography.titleMedium,
//                     fontWeight = FontWeight.Bold
//                 )
                
//                 Spacer(modifier = Modifier.height(8.dp))
                
//                 if (!isConfigLoaded) {
//                     Row(
//                         modifier = Modifier.fillMaxWidth(),
//                         horizontalArrangement = Arrangement.Center,
//                         verticalAlignment = Alignment.CenterVertically
//                     ) {
//                         CircularProgressIndicator(modifier = Modifier.padding(8.dp))
//                         Text("Loading configuration...")
//                     }
//                 } else {
//                     TextField(
//                         value = configInput,
//                         onValueChange = { configInput = it },
//                         modifier = Modifier.fillMaxWidth(),
//                         label = { Text("JSON Configuration") },
//                         placeholder = { Text("Enter your sing-box JSON configuration here...") },
//                         minLines = 8
//                     )
                    
//                     Spacer(modifier = Modifier.height(16.dp))
                    
//                     Button(
//                         onClick = {
//                             onConfigSave(configInput)
//                         },
//                         modifier = Modifier.fillMaxWidth()
//                     ) {
//                         Text("Save Configuration")
//                     }
//                 }
//             }
//         }
        
//         // Info Card
//         Card(
//             modifier = Modifier.fillMaxWidth(),
//             elevation = CardDefaults.cardElevation(defaultElevation = 4.dp)
//         ) {
//             Column(
//                 modifier = Modifier
//                     .fillMaxWidth()
//                     .padding(16.dp)
//             ) {
//                 Text(
//                     text = "Usage Instructions",
//                     style = MaterialTheme.typography.titleMedium,
//                     fontWeight = FontWeight.Bold
//                 )
                
//                 Spacer(modifier = Modifier.height(8.dp))
                
//                 Text(
//                     "1. Paste your sing-box JSON configuration in the text field above.",
//                     style = MaterialTheme.typography.bodyMedium
//                 )
//                 Text(
//                     "2. Tap the 'Save Configuration' button.",
//                     style = MaterialTheme.typography.bodyMedium
//                 )
//                 Text(
//                     "3. Tap the 'Start VPN' button to connect.",
//                     style = MaterialTheme.typography.bodyMedium
//                 )
//                 Text(
//                     "4. To disconnect, tap the 'Stop VPN' button.",
//                     style = MaterialTheme.typography.bodyMedium
//                 )
//             }
//         }
//     }
// }