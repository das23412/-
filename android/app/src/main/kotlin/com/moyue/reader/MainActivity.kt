package com.moyue.reader

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * MainActivity：负责接收“用墨阅打开”的 VIEW intent。
 *
 * content:// URI 会被拷贝到应用私有缓存目录后把真实路径传给 Flutter，
 * 因此导入其他 App 的文件不需要任何存储权限。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "moyue/intent"
    private var pendingPath: String? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialFilePath" -> result.success(pendingPath)
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        val path = copyUriToCache(uri) ?: return
        pendingPath = path
        channel?.invokeMethod("onNewFilePath", path)
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val name = queryDisplayName(uri)
                ?: return null
            val safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_")
            if (!safe.contains('.')) return null // 不是可识别的文件名
            val dir = File(cacheDir, "moyue_import")
            if (!dir.exists()) dir.mkdirs()
            val dest = File(dir, "${System.currentTimeMillis()}_$safe")
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }
}
