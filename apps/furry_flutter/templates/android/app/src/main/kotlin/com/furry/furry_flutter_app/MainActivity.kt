package com.furry.furry_flutter_app

import android.os.Bundle
import androidx.annotation.NonNull
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.os.Process
import java.io.File
import java.io.FileWriter
import java.lang.Thread.UncaughtExceptionHandler
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
  private val channelName = "furry/native"
  private var inited = false
  private val executor = Executors.newFixedThreadPool(2)

  private fun appendDiagnostics(line: String) {
    try {
      val f = File(applicationContext.filesDir, "diagnostics.log")
      FileWriter(f, true).use { it.appendLine("${System.currentTimeMillis()}  $line") }
    } catch (_: Throwable) {}
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    appendDiagnostics("Activity: onCreate pid=${Process.myPid()} uid=${Process.myUid()}")

    val prev: UncaughtExceptionHandler? = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { t, e ->
      appendDiagnostics("UncaughtException thread=${t.name}: ${e.javaClass.simpleName}: $e")
      for (el in e.stackTrace.take(40)) {
        appendDiagnostics("  at $el")
      }
      prev?.uncaughtException(t, e)
    }
  }

  override fun onStart() {
    super.onStart()
    appendDiagnostics("Activity: onStart")
  }

  override fun onResume() {
    super.onResume()
    appendDiagnostics("Activity: onResume")
  }

  override fun onPause() {
    appendDiagnostics("Activity: onPause")
    super.onPause()
  }

  override fun onStop() {
    appendDiagnostics("Activity: onStop")
    super.onStop()
  }

  private fun <T> runAsync(result: MethodChannel.Result, block: () -> T) {
    executor.execute {
      try {
        val v = block()
        runOnUiThread { result.success(v) }
      } catch (t: Throwable) {
        appendDiagnostics("JNI call failed: ${t.javaClass.simpleName}: $t")
        runOnUiThread { result.error("native_error", t.toString(), null) }
      }
    }
  }

  override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    appendDiagnostics("Activity: configureFlutterEngine pid=${Process.myPid()} uid=${Process.myUid()}")
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        try {
          handleCall(call, result)
        } catch (t: Throwable) {
          appendDiagnostics("MethodChannel handler failed: ${t.javaClass.simpleName}: $t")
          result.error("native_error", t.toString(), null)
        }
      }
  }

  private fun ensureInit() {
    if (inited) return
    NativeLib.init()
    inited = true
    appendDiagnostics("NativeLib.init ok")
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

  override fun onLowMemory() {
    super.onLowMemory()
    appendDiagnostics("Activity: onLowMemory")
  }

  override fun onTrimMemory(level: Int) {
    super.onTrimMemory(level)
    appendDiagnostics("Activity: onTrimMemory level=$level")
  }

  override fun onDestroy() {
    appendDiagnostics("Activity: onDestroy finishing=$isFinishing changingConfig=$isChangingConfigurations")
    super.onDestroy()
    executor.shutdown()
  }
}
