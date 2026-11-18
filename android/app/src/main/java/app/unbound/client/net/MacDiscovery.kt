package app.unbound.client.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address
import java.util.ArrayDeque

/** Finds Macs advertising `_unbound._tcp` on the local network (Bonjour / DNS-SD). */
class MacDiscovery(context: Context, private val onChanged: (List<Mac>) -> Unit) {
    data class Mac(val name: String, val host: String, val port: Int)

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())
    private val found = LinkedHashMap<String, Mac>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discovery failed: $errorCode")
                main.post { listener = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = main.post { enqueue(info) }.let {}
            override fun onServiceLost(info: NsdServiceInfo) = main.post {
                if (found.remove(info.serviceName) != null) publish()
            }.let {}
        }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        resolveQueue.clear()
        found.clear()
        publish()
    }

    // Pre-Android 14 NsdManager can only resolve one service at a time, so resolve serially.
    private fun enqueue(info: NsdServiceInfo) {
        resolveQueue.add(info)
        resolveNext()
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving) return
        val next = resolveQueue.poll() ?: return
        resolving = true
        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = main.post {
                resolving = false
                resolveNext()
            }.let {}

            override fun onServiceResolved(info: NsdServiceInfo) = main.post {
                resolving = false
                val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    info.hostAddresses.firstOrNull { it is Inet4Address } ?: info.hostAddresses.firstOrNull()
                } else {
                    info.host
                }
                address?.hostAddress?.let { host ->
                    found[info.serviceName] = Mac(info.serviceName, host, info.port)
                    publish()
                }
                resolveNext()
            }.let {}
        })
    }

    private fun publish() = onChanged(found.values.toList())

    companion object {
        const val SERVICE_TYPE = "_unbound._tcp."
        private const val TAG = "UnboundDiscovery"
    }
}
