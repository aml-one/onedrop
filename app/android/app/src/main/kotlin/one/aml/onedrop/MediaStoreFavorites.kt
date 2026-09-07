package one.aml.onedrop

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.MediaStore

/**
 * Loved media the same way Gallery reads Recents: Images + Video tables,
 * [MediaStore.MediaColumns.IS_FAVORITE] on Android 11+.
 */
object MediaStoreFavorites {
    private const val CAP = 400
    private val imageUri: Uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    private val videoUri: Uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI

    fun ids(context: Context): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val out = LinkedHashSet<String>()
        collect(context, imageUri, out)
        collect(context, videoUri, out)
        return out.take(CAP)
    }

    private fun collect(context: Context, uri: Uri, out: MutableSet<String>) {
        if (queryFavorite(context, uri, out, selection = true)) return
        queryFavorite(context, uri, out, selection = false)
    }

    private fun queryFavorite(
        context: Context,
        uri: Uri,
        out: MutableSet<String>,
        selection: Boolean,
    ): Boolean {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.IS_FAVORITE,
        )
        val sel = if (selection) "${MediaStore.MediaColumns.IS_FAVORITE}=1" else null
        return try {
            val cursor = context.contentResolver.query(
                uri,
                projection,
                sel,
                null,
                "${MediaStore.MediaColumns.DATE_ADDED} DESC",
            ) ?: return false
            cursor.use { drain(it, out) }
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun drain(cursor: Cursor, out: MutableSet<String>) {
        val idIdx = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
        val favIdx = cursor.getColumnIndex(MediaStore.MediaColumns.IS_FAVORITE)
        while (cursor.moveToNext() && out.size < CAP) {
            if (favIdx >= 0) {
                if (cursor.isNull(favIdx) || cursor.getInt(favIdx) != 1) continue
            }
            out.add(cursor.getLong(idIdx).toString())
        }
    }
}
