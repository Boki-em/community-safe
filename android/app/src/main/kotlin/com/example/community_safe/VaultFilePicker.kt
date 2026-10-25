package com.example.community_safe

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class VaultFilePicker(private val activity: Activity) {

    private val requestCode = 8142
    private val maxBytes = 10 * 1024 * 1024
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingResult: MethodChannel.Result? = null
    private var selectedUri: Uri? = null

    fun handle(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        when (call.method) {
            "pick" -> {
                if (pendingResult != null) {
                    result.error(
                        "BUSY",
                        "A file picker is already open.",
                        null
                    )
                    return
                }

                selectedUri = null
                pendingResult = result

                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "image/jpeg",
                            "image/png",
                            "application/pdf",
                            "text/plain",
                            "video/mp4",
                            "video/3gpp",
                            "video/webm",
                            "video/quicktime"
                        )
                    )
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }

                try {
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(intent, requestCode)
                } catch (_: Exception) {
                    pendingResult = null
                    result.error(
                        "PICK_FAILED",
                        "Could not open the document picker.",
                        null
                    )
                }
            }

            "read" -> {
                val uri = selectedUri
                selectedUri = null

                if (uri == null) {
                    result.error(
                        "NO_SELECTION",
                        "Select the file again.",
                        null
                    )
                    return
                }

                Thread {
                    try {
                        val bytes = activity.contentResolver
                            .openInputStream(uri)?.use { input ->
                                val output = ByteArrayOutputStream()
                                val buffer = ByteArray(8192)
                                var total = 0

                                while (true) {
                                    val count = input.read(buffer)
                                    if (count < 0) break

                                    total += count
                                    require(total <= maxBytes) {
                                        "Choose a file no larger than 10 MB."
                                    }

                                    output.write(buffer, 0, count)
                                }

                                output.toByteArray()
                            } ?: throw IllegalStateException(
                                "Could not read the selected file."
                            )

                        mainHandler.post {
                            result.success(bytes)
                        }
                    } catch (error: Exception) {
                        mainHandler.post {
                            result.error(
                                "READ_FAILED",
                                error.message ?: "Could not read the file.",
                                null
                            )
                        }
                    }
                }.start()
            }

            "clear" -> {
                selectedUri = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    fun onActivityResult(
        receivedCode: Int,
        resultCode: Int,
        data: Intent?
    ): Boolean {
        if (receivedCode != requestCode) return false

        val result = pendingResult ?: return true
        pendingResult = null

        val uri = data?.data

        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }

        try {
            var name = "Imported document"
            var size: Long? = null

            activity.contentResolver.query(
                uri,
                arrayOf(
                    OpenableColumns.DISPLAY_NAME,
                    OpenableColumns.SIZE
                ),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(
                        OpenableColumns.DISPLAY_NAME
                    )
                    val sizeIndex = cursor.getColumnIndex(
                        OpenableColumns.SIZE
                    )

                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex)
                    }

                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }

            val extension = name.substringAfterLast(
                ".",
                ""
            ).lowercase()

            require(
                extension in setOf("jpg", "jpeg", "png", "pdf", "txt", "mp4", "m4v", "3gp", "webm", "mov")
            ) {
                "Choose an image, PDF, text file or supported video."
            }

            require(size == null || size!! <= maxBytes) {
                "Choose a file no larger than 10 MB."
            }

            selectedUri = uri

            result.success(
                mapOf(
                    "name" to name,
                    "size" to size
                )
            )
        } catch (error: Exception) {
            selectedUri = null
            result.error(
                "PICK_FAILED",
                error.message ?: "Could not select this file.",
                null
            )
        }

        return true
    }

    fun dispose() {
        selectedUri = null
        pendingResult?.error(
            "CLOSED",
            "The file picker closed. Select the file again.",
            null
        )
        pendingResult = null
    }
}