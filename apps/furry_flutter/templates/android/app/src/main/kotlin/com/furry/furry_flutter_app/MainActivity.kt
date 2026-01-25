package com.furry.furry_flutter_app

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val channelName = "furry/native"
  private var inited = false

  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        try {
          handleCall(call, result)
        } catch (t: Throwable) {
          result.error("native_error", t.toString(), null)
        }
      }
  }

  private fun ensureInit() {
    if (inited) return
    NativeLib.init()
    inited = true
  }

  private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "init" -> {
        ensureInit()
        result.success(null)
      }

      "packToFurry" -> {
        ensureInit()
        val inputPath = call.argument<String>("inputPath") ?: ""
        val outputPath = call.argument<String>("outputPath") ?: ""
        val paddingKb = call.argument<Number>("paddingKb")?.toLong() ?: 0L
        result.success(NativeLib.packToFurry(inputPath, outputPath, paddingKb))
      }

      "isValidFurryFile" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        result.success(NativeLib.isValidFurryFile(filePath))
      }

      "getOriginalFormat" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        result.success(NativeLib.getOriginalFormat(filePath))
      }

      "unpackFromFurryToBytes" -> {
        ensureInit()
        val inputPath = call.argument<String>("inputPath") ?: ""
        result.success(NativeLib.unpackFromFurryToBytes(inputPath))
      }

      else -> result.notImplemented()
    }
  }
}
