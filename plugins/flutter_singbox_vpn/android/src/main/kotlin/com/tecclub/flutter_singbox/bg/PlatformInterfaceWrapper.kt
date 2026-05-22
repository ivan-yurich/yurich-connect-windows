package com.tecclub.flutter_singbox.bg

import android.content.pm.PackageManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Process
import android.system.OsConstants
import android.util.Log
import androidx.annotation.RequiresApi
import com.tecclub.flutter_singbox.Application
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.util.Enumeration
import io.nekohasekai.libbox.NetworkInterface as LibboxNetworkInterface

interface PlatformInterfaceWrapper : PlatformInterface {
    
    override fun localDNSTransport(): LocalDNSTransport? {
        return LocalResolver
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean {
        return true
    }

    override fun autoDetectInterfaceControl(fd: Int) {
    }

    override fun openTun(options: TunOptions): Int {
        error("invalid argument")
    }

    override fun useProcFS(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int
    ): ConnectionOwner {
        val uid = Application.connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort)
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = Application.packageManager.getPackagesForUid(uid)
        return ConnectionOwner().apply {
            userId = uid
            userName = packages?.firstOrNull().orEmpty()
            if (!packages.isNullOrEmpty()) {
                setAndroidPackageNames(StringArray(packages.iterator()))
            }
        }
    }

    fun usePlatformDefaultInterfaceMonitor(): Boolean {
        return true
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        DefaultNetworkMonitor.setListener(null)
    }

    fun usePlatformInterfaceGetter(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val networks = Application.connectivity.allNetworks
        val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
        val interfaces = mutableListOf<LibboxNetworkInterface>()
        for (network in networks) {
            val boxInterface = LibboxNetworkInterface()
            val linkProperties = Application.connectivity.getLinkProperties(network) ?: continue
            val networkCapabilities =
                Application.connectivity.getNetworkCapabilities(network) ?: continue
            boxInterface.name = linkProperties.interfaceName
            val networkInterface =
                networkInterfaces.find { it.name == boxInterface.name } ?: continue
            boxInterface.dnsServer =
                StringArray(linkProperties.dnsServers.mapNotNull { it.hostAddress }.iterator())
            boxInterface.type = when {
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            boxInterface.index = networkInterface.index
            runCatching {
                boxInterface.mtu = networkInterface.mtu
            }.onFailure {
                Log.e(
                    "PlatformInterface", "failed to get mtu for interface ${boxInterface.name}", it
                )
            }
            boxInterface.addresses =
                StringArray(networkInterface.interfaceAddresses.mapTo(mutableListOf()) { it.toPrefix() }
                    .iterator())
            var dumpFlags = 0
            if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                dumpFlags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (networkInterface.isLoopback) {
                dumpFlags = dumpFlags or OsConstants.IFF_LOOPBACK
            }
            if (networkInterface.isPointToPoint) {
                dumpFlags = dumpFlags or OsConstants.IFF_POINTOPOINT
            }
            if (networkInterface.supportsMulticast()) {
                dumpFlags = dumpFlags or OsConstants.IFF_MULTICAST
            }
            boxInterface.flags = dumpFlags
            boxInterface.metered =
                !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            interfaces.add(boxInterface)
        }
        return InterfaceListIterator(interfaces.iterator())
    }

    override fun underNetworkExtension(): Boolean {
        return false
    }

    override fun includeAllNetworks(): Boolean {
        return false
    }

    override fun clearDNSCache() {
    }

    override fun readWIFIState(): WIFIState? {
        return null
    }
    
    @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
    override fun systemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        val keyStore = java.security.KeyStore.getInstance("AndroidCAStore")
        if (keyStore != null) {
            keyStore.load(null, null)
            val aliases = keyStore.aliases()
            while (aliases.hasMoreElements()) {
                val cert = keyStore.getCertificate(aliases.nextElement())
                certificates.add(
                    "-----BEGIN CERTIFICATE-----\n" + kotlin.io.encoding.Base64.encode(cert.encoded) + "\n-----END CERTIFICATE-----"
                )
            }
        }
        return StringArray(certificates.iterator())
    }

    private class InterfaceListIterator(private val iterator: Iterator<LibboxNetworkInterface>) :
        NetworkInterfaceIterator {

        override fun hasNext(): Boolean {
            return iterator.hasNext()
        }

        override fun next(): LibboxNetworkInterface {
            return iterator.next()
        }
    }

    private class InterfaceArray(private val iterator: Enumeration<NetworkInterface>) :
        NetworkInterfaceIterator {

        override fun hasNext(): Boolean {
            return iterator.hasMoreElements()
        }

        override fun next(): LibboxNetworkInterface {
            val element = iterator.nextElement()
            return LibboxNetworkInterface().apply {
                name = element.name
                index = element.index
                runCatching {
                    mtu = element.mtu
                }
                addresses =
                    StringArray(
                        element.interfaceAddresses.mapTo(mutableListOf()) { it.toPrefix() }
                            .iterator()
                    )
            }
        }
    }

    private class StringArray(private val iterator: Iterator<String>) : StringIterator {

        override fun hasNext(): Boolean {
            return iterator.hasNext()
        }

        override fun next(): String {
            return iterator.next()
        }
        
        override fun len(): Int {
            return 0 // Iterator doesn't support len, return 0
        }
    }
}

private fun InterfaceAddress.toPrefix(): String {
    return if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/${networkPrefixLength}"
    } else {
        "${address.hostAddress}/${networkPrefixLength}"
    }
}
