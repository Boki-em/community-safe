package com.example.community_safe

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import java.util.UUID
import java.util.concurrent.TimeUnit

class SosTileService : TileService() {

    private val preferences by lazy {
        getSharedPreferences("sos_firestore_test", MODE_PRIVATE)
    }

    override fun onStartListening() {
        super.onStartListening()
        refreshTile()
    }

    override fun onClick() {
        super.onClick()

        try {
            FirebaseApp.initializeApp(this)

            val user = FirebaseAuth.getInstance().currentUser

            if (user == null) {
                showStatus("Sign in first")
                return
            }

            val eventId = UUID.randomUUID().toString()

            val input = Data.Builder()
                .putString("uid", user.uid)
                .putString("eventId", eventId)
                .putBoolean("locked", isLocked)
                .putLong("triggeredAt", System.currentTimeMillis())
                .build()

            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<SosUploadWorker>()
                .setInputData(input)
                .setConstraints(constraints)
                .setBackoffCriteria(
                    BackoffPolicy.EXPONENTIAL,
                    10,
                    TimeUnit.SECONDS
                )
                .build()

            preferences.edit()
                .putString("latest_event_id", eventId)
                .putString("status", "Queueing demo")
                .commit()

            refreshTile()

                        val operation = WorkManager.getInstance(applicationContext)
                .enqueueUniqueWork(
                    "sos-$eventId",
                    ExistingWorkPolicy.KEEP,
                    request
                )

            operation.result.addListener(
                {
                    try {
                        operation.result.get()

                        if (
                            preferences.getString("latest_event_id", null) ==
                            eventId &&
                            preferences.getString("status", "") ==
                            "Queueing demo"
                        ) {
                            showStatus("Queued for upload")
                        }
                    } catch (_: Exception) {
                        if (
                            preferences.getString("latest_event_id", null) ==
                            eventId
                        ) {
                            showStatus("Could not queue demo")
                        }
                    }
                },
                mainExecutor
            )

        } catch (_: Exception) {
            showStatus("Could not queue demo")
        }
    }

    private fun showStatus(message: String) {
        preferences.edit()
            .putString("status", message)
            .apply()

        refreshTile()

        Toast.makeText(
            this,
            message,
            Toast.LENGTH_SHORT
        ).show()
    }

    private fun refreshTile() {
        val tile = qsTile ?: return
        val status = preferences.getString(
            "status", "Ready for demo"
        ) ?: "Ready for demo"

        tile.label = "SOS Test"
        tile.state = Tile.STATE_INACTIVE
        tile.contentDescription = "SOS demo: $status. No messages sent."

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = status
        }

        tile.updateTile()
    }
}