package com.furry.player

/**
 * Furry Player 原生库接口
 *
 * 使用方法:
 * 1. 将编译好的 libfurry_android.so 放入 app/src/main/jniLibs/<abi>/
 * 2. 在 Application 或 Activity 中调用 NativeLib.init()
 * 3. 使用 packToFurry 进行打包，使用 unpackFromFurryToBytes 用于播放等内存场景
 */
object NativeLib {

    init {
        System.loadLibrary("furry_android")
    }

    /**
     * 初始化原生库
     * 应在应用启动时调用一次
     */
    external fun init()

    /**
     * 将音频文件打包为 .furry 格式
     *
     * @param inputPath 输入文件路径（支持 mp3, wav, ogg, flac）
     * @param outputPath 输出 .furry 文件路径
     * @param paddingKb 填充大小（KB），用于混淆文件大小
     * @return 0 成功，负数表示错误码
     *         -1: 输入路径无效
     *         -2: 输出路径无效
     *         -3: 无法打开输入文件
     *         -4: 无法创建输出文件
     *         -5: 打包失败
     */
    external fun packToFurry(inputPath: String, outputPath: String, paddingKb: Long): Int

    /**
     * 检查文件是否为有效的 .furry 格式
     *
     * @param filePath 文件路径
     * @return true 如果是有效的 .furry 文件
     */
    external fun isValidFurryFile(filePath: String): Boolean

    /**
     * 获取 .furry 内部记录的原始音频格式扩展名（不带点）
     *
     * @param filePath .furry 文件路径（必须是可读的真实路径）
     * @return "mp3"/"wav"/"ogg"/"flac"，未知则返回空字符串
     */
    external fun getOriginalFormat(filePath: String): String

    /**
     * 将 .furry 解密为原始音频字节流（仅驻留内存，用于播放等场景）
     *
     * 注意：数据量可能很大，建议在后台线程调用。
     *
     * @param inputPath 输入 .furry 文件路径（必须是可读的真实路径）
     * @return 解密后的原始音频字节数组，失败返回 null
     */
    external fun unpackFromFurryToBytes(inputPath: String): ByteArray?
}

/**
 * 使用示例
 */
class FurryPlayerExample {

    fun convertToFurry(inputPath: String, outputPath: String): Boolean {
        NativeLib.init()

        val result = NativeLib.packToFurry(inputPath, outputPath, paddingKb = 50)
        return result == 0
    }

    fun checkFile(path: String): Boolean {
        return NativeLib.isValidFurryFile(path)
    }
}
