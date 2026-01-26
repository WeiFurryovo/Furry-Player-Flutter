package com.furry.furry_flutter_app

import androidx.annotation.NonNull
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
  private val channelName = "furry/native"
  private var inited = false
  private val executor = Executors.newFixedThreadPool(2)

  private fun <T> runAsync(result: MethodChannel.Result, block: () -> T) {
    executor.execute {
      try {
        val v = block()
        runOnUiThread { result.success(v) }
      } catch (t: Throwable) {
        runOnUiThread { result.error("native_error", t.toString(), null) }
      }
    }
  }

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
        runAsync(result) { NativeLib.packToFurry(inputPath, outputPath, paddingKb) }
      }

      "isValidFurryFile" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        runAsync(result) { NativeLib.isValidFurryFile(filePath) }
      }

      "getOriginalFormat" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        runAsync(result) { NativeLib.getOriginalFormat(filePath) }
      }

      "unpackFromFurryToBytes" -> {
        ensureInit()
        val inputPath = call.argument<String>("inputPath") ?: ""
        runAsync(result) { NativeLib.unpackFromFurryToBytes(inputPath) }
      }

      "unpackToFile" -> {
        ensureInit()
        val inputPath = call.argument<String>("inputPath") ?: ""
        val outputPath = call.argument<String>("outputPath") ?: ""
        runAsync(result) { NativeLib.unpackToFile(inputPath, outputPath) }
      }

      "getTagsJson" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        runAsync(result) { NativeLib.getTagsJson(filePath) }
      }

      "getCoverArt" -> {
        ensureInit()
        val filePath = call.argument<String>("filePath") ?: ""
        runAsync(result) { NativeLib.getCoverArt(filePath) }
      }

      else -> result.notImplemented()
    }
  }

  override fun onDestroy() {
    super.onDestroy()
    executor.shutdown()
  }
}
