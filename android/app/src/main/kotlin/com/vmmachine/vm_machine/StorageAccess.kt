package com.vmmachine.vm_machine

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Build
import android.os.StatFs
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Storage Access Framework wrapper behind the `vm/files` channel.
 *
 * MainActivity (task 8.10) owns the activity-result plumbing:
 *  1. `startActivityForResult(storage.createPickMediaIntent(), PICK_MEDIA_REQUEST)`
 *  2. in `onActivityResult`, `storage.onPickResult(resultCode, data)` returns the map for Dart
 *     (or null when the user cancelled).
 *
 * Methods that may block (copy, descriptor resolution) must be called off the main thread.
 */
class StorageAccess(private val context: Context) {

    companion object {
        const val PICK_MEDIA_REQUEST = 4101

        /** Extensions accepted for media (Req 4.4). Lower case, without the dot. */
        val SUPPORTED_EXTENSIONS = listOf("iso", "img", "qcow2", "vhdx")

        private const val COPY_BUFFER = 1 shl 20
        private const val PROGRESS_INTERVAL_MS = 100L
        private const val MAX_SHARED_LOG_BYTES = 256 * 1024L
    }

    /** Cancel flags for in-flight copies, keyed by destination path. */
    private val cancelFlags = ConcurrentHashMap<String, AtomicBoolean>()

    // ---- Picker (Req 4.1) -------------------------------------------------------------------

    /**
     * Builds an `ACTION_OPEN_DOCUMENT` intent. SAF has no extension filter, so the picker is
     * opened for any file and [onPickResult] rejects unsupported extensions.
     */
    fun createPickMediaIntent(): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }

    /**
     * Handles the picker result. Returns `{uri, name, size, supported}` or null if cancelled.
     * A persistable read permission is taken only for supported files, so it survives restarts
     * (Req 4.2, in-place attach).
     */
    fun onPickResult(resultCode: Int, data: Intent?): Map<String, Any?>? {
        if (resultCode != Activity.RESULT_OK) return null
        val uri = data?.data ?: return null
        val name = displayName(uri)
        val supported = hasSupportedExtension(name)
        if (supported) {
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: SecurityException) {
                // Provider does not offer persistable grants; the grant lasts for this session.
            }
        }
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size(uri),
            "supported" to supported,
        )
    }

    fun hasSupportedExtension(name: String?): Boolean {
        val ext = name?.substringAfterLast('.', "")?.lowercase() ?: return false
        return ext in SUPPORTED_EXTENSIONS
    }

    // ---- All-files access and real paths (Req 4.2) ------------------------------------------

    /**
     * Whether the app may read arbitrary files by path. QEMU runs as a child process, so it can
     * only open real filesystem paths, not descriptors that belong to this process.
     */
    fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager() else true

    /** Opens the system screen where the user grants All-files access. Returns false if none opens. */
    fun requestAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val pkg = Uri.parse("package:${context.packageName}")
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkg),
            Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
        )
        for (i in intents) {
            try {
                context.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
                // Try the next screen.
            }
        }
        return false
    }

    /**
     * Resolves a picked `content://` URI to a real, readable filesystem path, or null when it
     * cannot be mapped (cloud providers, no All-files access, file gone). A plain absolute path
     * is returned unchanged when readable.
     */
    fun resolveRealPath(uriString: String): String? {
        if (uriString.startsWith("/")) return uriString.takeIf { File(it).canRead() }
        val uri = try { Uri.parse(uriString) } catch (_: Exception) { return null }
        val path = try {
            when (uri.scheme) {
                "file" -> uri.path
                "content" -> contentToPath(uri)
                else -> null
            }
        } catch (_: Exception) {
            null
        } ?: return null
        return path.takeIf { File(it).let { f -> f.isFile && f.canRead() } }
    }

    private fun contentToPath(uri: Uri): String? {
        if (DocumentsContract.isDocumentUri(context, uri)) {
            val docId = DocumentsContract.getDocumentId(uri)
            when (uri.authority) {
                "com.android.externalstorage.documents" -> {
                    val parts = docId.split(":", limit = 2)
                    val rel = parts.getOrNull(1) ?: return null
                    val root = if (parts[0].equals("primary", ignoreCase = true)) {
                        Environment.getExternalStorageDirectory().absolutePath
                    } else {
                        "/storage/${parts[0]}"
                    }
                    return "$root/$rel"
                }
                "com.android.providers.downloads.documents" -> {
                    if (docId.startsWith("raw:")) return docId.removePrefix("raw:")
                    // "msf:123" and plain numeric ids both point at a MediaStore/Downloads row.
                    val id = docId.substringAfter(':').toLongOrNull() ?: docId.toLongOrNull()
                    if (id != null) {
                        dataColumn(
                            ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), id)
                        )?.let { return it }
                        dataColumn(
                            ContentUris.withAppendedId(
                                Uri.parse("content://downloads/public_downloads"), id
                            )
                        )?.let { return it }
                    }
                    return null
                }
                "com.android.providers.media.documents" -> {
                    val id = docId.substringAfter(':').toLongOrNull() ?: return null
                    return dataColumn(
                        ContentUris.withAppendedId(MediaStore.Files.getContentUri("external"), id)
                    )
                }
            }
        }
        return dataColumn(uri)
    }

    /** Reads the legacy `_data` column; null when the provider does not expose it. */
    private fun dataColumn(uri: Uri): String? = query(uri, MediaStore.MediaColumns.DATA) {
        if (it.isNull(0)) null else it.getString(0)
    }

    // ---- Copy with progress (Req 4.3, 4.6) --------------------------------------------------

    /**
     * Copies [uriString] to [destPath], calling [onProgress] with (copiedBytes, totalBytes);
     * total is -1 when unknown. Returns a result map:
     *  - `{ok: true, path, bytes}` on success,
     *  - `{ok: false, error: "no_space" | "cancelled" | "io", required, available, message}`.
     * On any failure the partial file is deleted.
     */
    fun copyMedia(
        uriString: String,
        destPath: String,
        onProgress: (copied: Long, total: Long) -> Unit,
    ): Map<String, Any?> {
        val uri = Uri.parse(uriString)
        val dest = File(destPath)
        val total = size(uri) ?: -1L
        val flag = AtomicBoolean(false)
        cancelFlags[destPath] = flag

        try {
            dest.parentFile?.mkdirs()
            val available = freeSpace(dest.parentFile?.absolutePath ?: destPath)
            if (total >= 0 && available != null && total > available) {
                return failure("no_space", total, available)
            }

            val input = context.contentResolver.openInputStream(uri)
                ?: return failure("io", total, available, "Cannot open source file")

            var copied = 0L
            var lastReport = 0L
            try {
                input.use { src ->
                    dest.outputStream().use { out ->
                        val buf = ByteArray(COPY_BUFFER)
                        onProgress(0L, total)
                        while (true) {
                            if (flag.get()) {
                                dest.delete()
                                return failure("cancelled", total, available)
                            }
                            val n = src.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            copied += n
                            val now = System.currentTimeMillis()
                            if (now - lastReport >= PROGRESS_INTERVAL_MS) {
                                lastReport = now
                                onProgress(copied, total)
                            }
                        }
                        out.flush()
                        out.fd.sync()
                    }
                }
            } catch (e: IOException) {
                dest.delete()
                val nowAvailable = freeSpace(dest.parentFile?.absolutePath ?: destPath)
                // A full disk surfaces as an IOException; report the amounts (Req 4.6).
                val outOfSpace = e.message?.contains("ENOSPC", ignoreCase = true) == true ||
                    e.message?.contains("No space", ignoreCase = true) == true
                return if (outOfSpace) {
                    failure("no_space", total, nowAvailable, e.message)
                } else {
                    failure("io", total, nowAvailable, e.message)
                }
            }
            onProgress(copied, if (total >= 0) total else copied)
            return mapOf("ok" to true, "path" to destPath, "bytes" to copied)
        } catch (e: Exception) {
            dest.delete()
            return failure("io", total, null, e.message)
        } finally {
            cancelFlags.remove(destPath)
        }
    }

    /** Requests cancellation of an in-flight [copyMedia] to [destPath]. */
    fun cancelCopy(destPath: String) {
        cancelFlags[destPath]?.set(true)
    }

    private fun failure(
        error: String,
        required: Long,
        available: Long?,
        message: String? = null,
    ): Map<String, Any?> = mapOf(
        "ok" to false,
        "error" to error,
        "required" to (if (required >= 0) required else null),
        "available" to available,
        "message" to message,
    )

    // ---- Free space and removable volumes (Req 4.6, 8.5) -----------------------------------

    /** Free bytes on the volume holding [path], or null if unreadable. */
    fun freeSpace(path: String): Long? {
        return try {
            // Walk up to the nearest existing directory so unborn paths can be queried.
            var f: File? = File(path)
            while (f != null && !f.exists()) f = f.parentFile
            val bytes = StatFs((f ?: context.filesDir).absolutePath).availableBytes
            if (bytes >= 0) bytes else null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Mounted removable volumes that have an app-specific directory.
     * Each entry: `{description, path, freeBytes}`; `path` is the app-specific files dir.
     */
    fun removableVolumes(): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        try {
            val sm = context.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            val dirs = context.getExternalFilesDirs(null)
            for (dir in dirs) {
                if (dir == null) continue
                if (!Environment.isExternalStorageRemovable(dir)) continue
                if (Environment.getExternalStorageState(dir) != Environment.MEDIA_MOUNTED) continue
                val description = sm?.getStorageVolume(dir)?.getDescription(context)
                    ?: "Removable storage"
                result.add(
                    mapOf(
                        "description" to description,
                        "path" to dir.absolutePath,
                        "freeBytes" to freeSpace(dir.absolutePath),
                    )
                )
            }
        } catch (_: Exception) {
            // Return whatever was collected; an empty list hides the removable option in the UI.
        }
        return result
    }

    // ---- Share and view (Req 12.4, 2.6) -----------------------------------------------------

    /**
     * Opens the share sheet with the tail of the log at [logPath] as text. Sending text avoids
     * needing a FileProvider declaration. Returns false if the log is unreadable or no app can
     * handle the share.
     */
    fun shareLogs(logPath: String): Boolean {
        return try {
            val file = File(logPath)
            if (!file.isFile) return false
            val text = readTail(file, MAX_SHARED_LOG_BYTES)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, file.name)
                putExtra(Intent.EXTRA_TEXT, text)
            }
            val chooser = Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Opens an official `https` distribution page in the browser. Other schemes are refused. */
    fun openUrl(url: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (_: Exception) {
            return false
        }
        if (uri.scheme != "https" || uri.host.isNullOrEmpty()) return false
        return try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    // ---- Helpers ----------------------------------------------------------------------------

    private fun readTail(file: File, maxBytes: Long): String {
        RandomAccessFile(file, "r").use { raf ->
            val len = raf.length()
            val start = maxOf(0L, len - maxBytes)
            raf.seek(start)
            val bytes = ByteArray((len - start).toInt())
            raf.readFully(bytes)
            return String(bytes, Charsets.UTF_8)
        }
    }

    private fun displayName(uri: Uri): String? = query(uri, OpenableColumns.DISPLAY_NAME) { it.getString(0) }
        ?: uri.lastPathSegment

    private fun size(uri: Uri): Long? = query(uri, OpenableColumns.SIZE) {
        if (it.isNull(0)) null else it.getLong(0)
    }

    private inline fun <T> query(
        uri: Uri,
        column: String,
        read: (android.database.Cursor) -> T?,
    ): T? = try {
        context.contentResolver.query(uri, arrayOf(column), null, null, null)?.use {
            if (it.moveToFirst()) read(it) else null
        }
    } catch (_: Exception) {
        null
    }
}
