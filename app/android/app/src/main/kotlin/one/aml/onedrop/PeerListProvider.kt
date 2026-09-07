package one.aml.onedrop

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/** Gallery queries nearby OneDrop peers so it can send without binding UDP 4071. */
class PeerListProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        if (callingPackage != MainActivity.GALLERY) return null
        val cursor = MatrixCursor(COLUMNS)
        for (row in DeviceBridge.cachedPeers()) {
            cursor.addRow(
                arrayOf(
                    row["id"],
                    row["name"],
                    row["host"],
                    row["port"],
                ),
            )
        }
        return cursor
    }

    override fun getType(uri: Uri): String = "vnd.android.cursor.dir/vnd.one.aml.onedrop.peer"

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        const val AUTHORITY = "one.aml.onedrop.peers"
        val CONTENT_URI: Uri = Uri.parse("content://$AUTHORITY/nearby")
        private val COLUMNS = arrayOf("id", "name", "host", "port")
    }
}
