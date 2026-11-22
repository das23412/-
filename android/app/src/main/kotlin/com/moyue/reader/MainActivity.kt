package com.moyue.reader

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * MainActivity：负责接收「用墨阅打开」的 VIEW intent、「分享到墨阅」的 SEND intent，
 * 以及拉起应用内更新的安装器。
 *
 * content:// URI 会被拷贝到应用私有缓存目录后把真实路径传给 Flutter，
 * 因此导入其他 App 的文件不需要任何存储权限。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "moyue/intent"
    private val installerChannelName = "moyue/installer"
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /** 待导入路径队列：拷贝完成即入队，Dart 冷启动 drain 一次取走；运行中靠推送加速。 */
    private val pendingPaths = ArrayDeque<String>()

    /** pendingPaths 的锁：UI 线程（入队/drain）与 IO 线程（清理时取快照）之间安全访问 */
    private val queueLock = Any()

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialFilePath" -> {
                    // 旧接口（Dart 侧保留未动）：逐个取，取走即清
                    val p: String? = synchronized(queueLock) { pendingPaths.removeFirstOrNull() }
                    result.success(p)
                }
                "initialFilePaths" -> {
                    // 一次性取走全部待处理路径（drain）：推送丢失时靠这里兜底；
                    // 取走即清，Activity 重建不会重复导入同一批路径
                    val list: ArrayList<String> = synchronized(queueLock) {
                        val snapshot = ArrayList(pendingPaths)
                        pendingPaths.clear()
                        snapshot
                    }
                    result.success(list)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.arguments as? String
                        if (path == null) {
                            result.error("bad_args", "缺少 APK 路径", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(true)
                            } catch (e: Exception) {
                                Log.e(TAG, "installApk 失败", e)
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        handleIntent(intent)
    }

    /** 通过 FileProvider 拉起系统包安装器。 */
    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("安装包不存在")
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            )
        startActivity(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action: String? = intent.action
        // VIEW：文件管理器/浏览器「用墨阅打开」；SEND：其他 App 分享单个文件到墨阅
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return
        val uri: Uri? = when (action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> try {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) as? Uri
            } catch (e: Exception) {
                Log.w(TAG, "读取 SEND 附件失败", e)
                null
            }
            else -> null
        }
        if (uri == null) {
            // SEND 但没带文件（如纯文本分享）：忽略
            if (action == Intent.ACTION_SEND) {
                Log.w(TAG, "ACTION_SEND 未携带 EXTRA_STREAM 文件，忽略")
            }
            return
        }
        // 大文件拷贝在后台线程执行：主线程 IO 会阻塞引擎启动乃至 ANR
        ioExecutor.execute {
            val path = copyUriToCache(uri, intent.type)
            runOnUiThread {
                if (path == null) {
                    Log.e(TAG, "导入失败：无法拷贝 $uri（磁盘满、文件不可读或无权限）")
                    return@runOnUiThread
                }
                // 入队（同路径去重）后推送；推送丢失也不丢文件——路径仍在队列里，
                // 下次冷启动 drain 兜底
                synchronized(queueLock) {
                    if (!pendingPaths.contains(path)) pendingPaths.addLast(path)
                }
                channel?.invokeMethod("onNewFilePath", path)
            }
        }
    }

    private fun copyUriToCache(uri: Uri, mimeType: String?): String? {
        return try {
            var name: String? = queryDisplayName(uri)
            if (name == null) {
                // 文件名查不到：用时间戳兜底名，按 mimeType 推断扩展名（与下方同一套规则），
                // 不再直接放弃这次导入
                val ext = extensionForMimeType(mimeType)
                if (ext == null) {
                    Log.e(TAG, "导入失败：无法确定文件名与类型 $uri（$mimeType）")
                    return null
                }
                name = "import_${System.currentTimeMillis()}$ext"
            }
            var safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fa5]"), "_")
            // 无扩展名但 mimeType 可识别：按类型补扩展名，而不是丢弃
            if (!safe.contains('.')) {
                val ext = extensionForMimeType(mimeType)
                if (ext == null) {
                    Log.e(TAG, "导入失败：无法识别的文件类型 $uri（$mimeType）")
                    return null
                }
                safe += ext
            }
            val dir = File(cacheDir, "moyue_import")
            if (!dir.exists()) dir.mkdirs()
            cleanImportCache(dir)
            val dest = File(dir, "${System.currentTimeMillis()}_$safe")
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            dest.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "copyUriToCache 失败", e)
            null
        }
    }

    /** 按 mimeType 推断扩展名，识别不了返回 null（与原有 when 分支一致）。 */
    private fun extensionForMimeType(mimeType: String?): String? {
        return when {
            mimeType?.contains("epub") == true -> ".epub"
            mimeType?.contains("mobipocket") == true -> ".mobi"
            mimeType?.startsWith("text/") == true -> ".txt"
            else -> null
        }
    }

    /**
     * 缓存目录清理：删除 lastModified 超过 24 小时的过期文件；
     * 剩余总数仍超过 [CACHE_MAX_FILES] 时再从最旧的开始删。
     * 正在排队等待导入的文件（pendingPaths 里）一律跳过：批量打开时排队中的
     * 文件按时间往往最旧，绝不能被上限清理误删。
     */
    private fun cleanImportCache(dir: File) {
        val files: List<File> = dir.listFiles()?.sortedBy { it.lastModified() } ?: return
        if (files.isEmpty()) return
        val now: Long = System.currentTimeMillis()
        val queued: Set<String> = synchronized(queueLock) { HashSet<String>(pendingPaths) }
        val kept: MutableList<File> = ArrayList()
        for (f in files) {
            val expired: Boolean = now - f.lastModified() > CACHE_MAX_AGE_MS
            if (expired && !queued.contains(f.absolutePath)) {
                try { f.delete() } catch (_: Exception) {}
            } else {
                kept.add(f)
            }
        }
        var over: Int = kept.size - CACHE_MAX_FILES
        if (over > 0) {
            for (f in kept) { // 已按 lastModified 升序：从最旧的开始删
                if (over <= 0) break
                if (queued.contains(f.absolutePath)) continue
                try { f.delete() } catch (_: Exception) {}
                over--
            }
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
            Log.e(TAG, "queryDisplayName 失败", e)
            null
        }
    }

    companion object {
        private const val TAG = "MoyueMainActivity"

        /** 缓存清理：文件最长保留 24 小时 */
        private const val CACHE_MAX_AGE_MS: Long = 24 * 60 * 60 * 1000L

        /** 缓存清理：缓存目录文件总数上限，超过后从最旧的开始删 */
        private const val CACHE_MAX_FILES: Int = 50
    }
}
