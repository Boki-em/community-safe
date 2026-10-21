package com.example.community_safe

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Tasks
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import java.util.concurrent.TimeUnit

class SosUploadWorker(
    context: Context,
    parameters: WorkerParameters
) : Worker(context, parameters) {

    override fun doWork(): Result {
        val uid = inputData.getString("uid")
            ?: return Result.failure()

        val eventId = inputData.getString("eventId")
            ?: return Result.failure()

        try {
            FirebaseApp.initializeApp(applicationContext)

            // Never upload an old account's event as another user.
            if (FirebaseAuth.getInstance().currentUser?.uid != uid) {
                updateStatus(eventId, "Sign in to original account")
                return Result.retry()
            }

            updateStatus(eventId, "Saving demo")

            val database = FirebaseFirestore.getInstance()
            val reference = database
                .collection("users")
                .document(uid)
                .collection("events")
                .document(eventId)

            val sosLocation = SosLocation.read(applicationContext)

            val data = hashMapOf<String, Any>(
                "type" to "sos",
                "status" to "simulated",
                "isDemo" to true,
                "source" to "quick_settings_tile",
                "triggeredWhileLocked" to inputData.getBoolean(
                    "locked", false
                ),
                "triggeredAtDeviceMillis" to inputData.getLong(
                    "triggeredAt", 0L
                ),
                "createdAt" to FieldValue.serverTimestamp(),
                "location" to sosLocation
            )

            // A retry checks the SAME document.
            // If it already exists, no second event is created.
            val upload = database.runTransaction { transaction ->
                val existing = transaction.get(reference)

                if (!existing.exists()) {
                    transaction.set(reference, data)
                }

                true
            }

            Tasks.await(upload, 30, TimeUnit.SECONDS)

            updateStatus(eventId, "Demo saved online")
            return Result.success()

        } catch (error: Exception) {
            Log.e("CommunitySafeSOS", "Background save failed", error)

            var cause: Throwable? = error
            var firestoreError: FirebaseFirestoreException? = null

            while (cause != null) {
                if (cause is FirebaseFirestoreException) {
                    firestoreError = cause
                    break
                }
                cause = cause.cause
            }

            if (firestoreError?.code ==
                FirebaseFirestoreException.Code.PERMISSION_DENIED
            ) {
                updateStatus(eventId, "Save denied: check rules")
                return Result.failure()
            }

            updateStatus(eventId, "Waiting to retry")
            return Result.retry()
        }
    }

    private fun updateStatus(eventId: String, message: String) {
        val preferences = applicationContext.getSharedPreferences(
            "sos_firestore_test",
            Context.MODE_PRIVATE
        )

        if (preferences.getString("latest_event_id", null) == eventId) {
            preferences.edit()
                .putString("status", message)
                .commit()
        }
    }
}