package com.furry.furry_flutter_app

/**
 * Rust JNI 动态库接口（来自本仓库 apps/furry_android 的导出）
 *
 * 注意：需要把 libfurry_android.so 放入：
 * android/app/src/main/jniLibs/<abi>/libfurry_android.so
 */
object NativeLib {
  init {
    System.loadLibrary("furry_android")
  }

  external fun init()
  external fun packToFurry(inputPath: String, outputPath: String, paddingKb: Long): Int
  external fun isValidFurryFile(filePath: String): Boolean
  external fun getOriginalFormat(filePath: String): String
  external fun unpackFromFurryToBytes(inputPath: String): ByteArray?
  external fun getTagsJson(filePath: String): String
  external fun getCoverArt(filePath: String): ByteArray?
}
