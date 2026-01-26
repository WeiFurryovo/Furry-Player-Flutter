package com.furry.furry_flutter_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val channelName = "furry.notifications"
  private val requestCode = 8731
  private var pendingResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "request" -> {
            requestNotificationPermission(result)
          }
          else -> result.notImplemented()
        }
      }
  }

  private fun requestNotificationPermission(result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < 33) {
      result.success(true)
      return
    }
    val granted = ContextCompat.checkSelfPermission(
      this,
      Manifest.permission.POST_NOTIFICATIONS
    ) == PackageManager.PERMISSION_GRANTED
    if (granted) {
      result.success(true)
      return
    }
    if (pendingResult != null) {
      pendingResult?.success(false)
      pendingResult = null
    }
    pendingResult = result
    ActivityCompat.requestPermissions(
      this,
      arrayOf(Manifest.permission.POST_NOTIFICATIONS),
      requestCode
    )
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode != this.requestCode) return
    val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
    pendingResult?.success(granted)
    pendingResult = null
  }
}

