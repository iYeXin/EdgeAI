package com.edgeai.edge_ai

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var launchPrompt: String? = null
    private var launchBackend: String? = null
    private var launchImage: String? = null
    private lateinit var channel: MethodChannel

    override fun onCreate(savedInstanceState: Bundle?) {
        launchPrompt = intent?.getStringExtra("prompt")
        launchBackend = intent?.getStringExtra("backend")
        launchImage = intent?.getStringExtra("image")
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "edge_ai/paths")
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getModelDir" -> {
                        val dir = File(getExternalFilesDir(null), "models")
                        dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "getExternalFilesDir" -> result.success(getExternalFilesDir(null)?.absolutePath)
                    "getLaunchPrompt" -> {
                        result.success(launchPrompt)
                        launchPrompt = null
                    }
                    "getLaunchBackend" -> {
                        result.success(launchBackend)
                        launchBackend = null
                    }
                    "getLaunchImage" -> {
                        result.success(launchImage)
                        launchImage = null
                    }
                    "getPowerSnapshot" -> result.success(powerSnapshot())
                    "getMemoryInfo" -> result.success(memoryInfo())
                    "getFreeBytes" -> result.success(freeBytes())
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (::channel.isInitialized) {
            channel.invokeMethod("onTrimMemory", level)
        }
    }

    @Suppress("DEPRECATION")
    private fun freeBytes(): Long {
        val dir = getExternalFilesDir(null) ?: filesDir
        return StatFs(dir.absolutePath).availableBytes
    }

    @Suppress("DEPRECATION")
    private fun memoryInfo(): Map<String, Any> {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        return mapOf(
            "totalBytes" to info.totalMem,
            "availBytes" to info.availMem,
            "thresholdBytes" to info.threshold,
            "lowMemory" to info.lowMemory,
            "maxHeapBytes" to Runtime.getRuntime().maxMemory(),
        )
    }

    @Suppress("DEPRECATION")
    private fun powerSnapshot(): Map<String, Any> {
        val manager = getSystemService(BATTERY_SERVICE) as BatteryManager
        val currentUa = try {
            manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        } catch (_: Exception) {
            Int.MIN_VALUE
        }
        val charging = try {
            manager.isCharging
        } catch (_: Exception) {
            false
        }

        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val battery = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(null, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(null, filter)
        }

        val voltageMv = battery?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1
        val tempTenths = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val chargeCounterUah = try {
            manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        } catch (_: Exception) {
            Int.MIN_VALUE
        }
        val levelPercent = if (level >= 0 && scale > 0) level * 100.0 / scale else 0.0
        val capacityUah = if (levelPercent > 0 && chargeCounterUah > 0) {
            chargeCounterUah * 100.0 / levelPercent
        } else {
            0.0
        }

        return mapOf(
            "currentUa" to currentUa,
            "voltageMv" to voltageMv,
            "tempC" to if (tempTenths >= 0) tempTenths / 10.0 else 0.0,
            "status" to status,
            "plugged" to plugged,
            "isCharging" to charging,
            "levelPercent" to levelPercent,
            "chargeCounterUah" to chargeCounterUah,
            "capacityUah" to capacityUah,
        )
    }
}
