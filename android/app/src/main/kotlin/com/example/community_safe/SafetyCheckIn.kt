package com.example.community_safe

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object SafetyCheckIn {

    private const val STORE = "safety_check_in"
    private const val KEY_ALIAS = "community_safe_check_in"
    private const val REQUEST_CODE = 7021

    private fun prefs(context: Context) =
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)

    private fun alarms(context: Context) =
        context.getSystemService(AlarmManager::class.java)

    private fun operation(
        context: Context,
        id: String
    ): PendingIntent {
        val intent = Intent(
            context,
            SafetyCheckInReceiver::class.java
        ).putExtra("id", id)

        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun encryptionKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
        }

        val existing = store.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        return KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        ).apply {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or
                        KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(
                        KeyProperties.ENCRYPTION_PADDING_NONE
                    )
                    .build()
            )
        }.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())

        val encrypted = cipher.doFinal(
            value.toByteArray(Charsets.UTF_8)
        )

        return Base64.encodeToString(
            cipher.iv,
            Base64.NO_WRAP
        ) + ":" + Base64.encodeToString(
            encrypted,
            Base64.NO_WRAP
        )
    }

    private fun decrypt(value: String): String {
        val parts = value.split(":", limit = 2)
        require(parts.size == 2)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            encryptionKey(),
            GCMParameterSpec(
                128,
                Base64.decode(parts[0], Base64.NO_WRAP)
            )
        )

        return String(
            cipher.doFinal(
                Base64.decode(parts[1], Base64.NO_WRAP)
            ),
            Charsets.UTF_8
        )
    }

    @Synchronized
    fun cancel(context: Context): Boolean {
        val saved = prefs(context)

        if (saved.getString("state", "") != "armed") {
            return false
        }

        val id = saved.getString("id", "").orEmpty()

        check(
            saved.edit()
                .putString("state", "cancelled")
                .remove("payload")
                .commit()
        ) {
            "Could not save cancellation. Try again."
        }

        alarms(context).cancel(operation(context, id))
        return true
    }

    @Suppress("DEPRECATION")
    @Synchronized
    private fun start(
        context: Context,
        contacts: List<Map<String, String>>,
        seconds: Long
    ) {
        require(seconds in 30L..3600L) {
            "Choose a valid check-in duration."
        }

        val saved = prefs(context)

        check(
            saved.getString("state", "") !in
                listOf("armed", "dispatching")
        ) {
            "A check-in is already active or submitting."
        }

        check(
            context.checkSelfPermission(
                Manifest.permission.SEND_SMS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            "Allow SMS permission before starting."
        }

        val alarmManager = alarms(context)

        check(
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager.canScheduleExactAlarms()
        ) {
            "Allow Alarms & reminders, then start again."
        }

        val numbers = contacts.map {
            val clean = it["phone"].orEmpty()
                .replace(Regex("[\\s()\\-]"), "")

            if (Regex("^0[0-9]{9}$").matches(clean)) {
                "+27" + clean.drop(1)
            } else {
                clean
            }
        }.distinct()

        require(
            numbers.isNotEmpty() &&
                numbers.all {
                    Regex("^\\+[1-9][0-9]{7,14}$").matches(it)
                }
        ) {
            "Add valid trusted-contact numbers first."
        }

        val subscriptionId =
            android.telephony.SmsManager
                .getDefaultSmsSubscriptionId()

        check(
            android.telephony.SubscriptionManager
                .isValidSubscriptionId(subscriptionId)
        ) {
            "Choose a default SMS SIM first."
        }

        val id = UUID.randomUUID().toString()

        val payload = encrypt(
            JSONObject()
                .put("numbers", JSONArray(numbers))
                .toString()
        )

        check(
            saved.edit()
                .clear()
                .putString("id", id)
                .putString("state", "armed")
                .putString("payload", payload)
                .putLong(
                    "dueAt",
                    System.currentTimeMillis() + seconds * 1000L
                )
                .commit()
        ) {
            "Could not save the check-in."
        }

        try {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + seconds * 1000L,
                operation(context, id)
            )
        } catch (error: Exception) {
            saved.edit()
                .putString("state", "schedule_failed")
                .remove("payload")
                .commit()

            throw error
        }
    }

    @Synchronized
    fun claim(
        context: Context,
        id: String
    ): List<Map<String, String>>? {
        val saved = prefs(context)

        if (
            saved.getString("state", "") != "armed" ||
            saved.getString("id", "") != id
        ) {
            return null
        }

        val payload = JSONObject(
            decrypt(
                saved.getString("payload", "").orEmpty()
            )
        )

        val array = payload.getJSONArray("numbers")

        val contacts = (0 until array.length()).map {
            mapOf("phone" to array.getString(it))
        }

        // Claim once to prevent duplicate alarm processing.
        check(
            saved.edit()
                .putString("state", "dispatching")
                .remove("payload")
                .commit()
        ) {
            "Could not record submission start."
        }

        return contacts
    }

    @Synchronized
    fun finish(
        context: Context,
        id: String,
        state: String
    ) {
        val saved = prefs(context)

        if (saved.getString("id", "") != id) return

        saved.edit()
            .putString("state", state)
            .remove("payload")
            .commit()
    }

    fun show(
        activity: Activity,
        contacts: List<Map<String, String>>
    ) {
        val saved = prefs(activity)
        val state = saved.getString("state", "").orEmpty()

        if (state == "armed") {
            val dueAt = DateFormat.getDateTimeInstance()
                .format(
                    Date(saved.getLong("dueAt", 0L))
                )

            AlertDialog.Builder(activity)
                .setTitle("Safety check-in active")
                .setMessage(
                    "Check in before $dueAt.\n\n" +
                        "If you do not cancel, the app will attempt " +
                        "an SMS to the contacts you approved.\n\n" +
                        "If the phone restarted, was force-stopped, " +
                        "or alarm access was removed, this check-in " +
                        "may no longer run. Cancel and start again."
                )
                .setNegativeButton("Close", null)
                .setPositiveButton("I'm safe — cancel") { _, _ ->
                    try {
                        val cancelled = cancel(activity)

                        toast(
                            activity,
                            if (cancelled) {
                                "Check-in cancelled. " +
                                    "No new SMS will be submitted."
                            } else {
                                "SMS submission has already started " +
                                    "or the check-in is no longer active."
                            }
                        )
                    } catch (_: Exception) {
                        toast(
                            activity,
                            "Cancellation failed. Reopen and try again."
                        )
                    }
                }
                .show()

            return
        }

        if (state == "dispatching") {
            AlertDialog.Builder(activity)
                .setTitle("Check-in submission")
                .setMessage(
                    "The deadline was reached and SMS submission " +
                        "started. A final result is not yet available.\n\n" +
                        "If this persists after restarting the app, " +
                        "the outcome is unknown. Check the receiving phones."
                )
                .setPositiveButton("Close", null)
                .show()

            return
        }

        val alarmManager = alarms(activity)

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager.canScheduleExactAlarms()
        ) {
            AlertDialog.Builder(activity)
                .setTitle("Allow timer access")
                .setMessage(
                    "Enable Alarms & reminders for Community Safe. " +
                        "Then return and start your check-in."
                )
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Open settings") { _, _ ->
                    try {
                        activity.startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                Uri.parse(
                                    "package:${activity.packageName}"
                                )
                            )
                        )
                    } catch (_: Exception) {
                        toast(
                            activity,
                            "Open Alarms & reminders in app settings."
                        )
                    }
                }
                .show()

            return
        }

        val options = arrayOf(
            "30 seconds — testing (real SMS)",
            "5 minutes",
            "15 minutes",
            "30 minutes",
            "1 hour"
        )

        val durations = longArrayOf(
            30L,
            300L,
            900L,
            1800L,
            3600L
        )

        val previous = when (state) {
            "submitted" ->
                "Previous: submitted to Android; " +
                    "delivery unconfirmed.\n\n"

            "partial" ->
                "Previous: some submissions failed; " +
                    "delivery unconfirmed.\n\n"

            "failed" ->
                "Previous: SMS submission failed.\n\n"

            "unknown" ->
                "Previous: outcome unknown; " +
                    "check receiving phones.\n\n"

            "cancelled" ->
                "Previous check-in cancelled.\n\n"

            "schedule_failed" ->
                "Previous timer could not be scheduled.\n\n"

            else -> ""
        }

        AlertDialog.Builder(activity)
            .setTitle("Safety check-in")
            .setItems(options) { _, index ->
                val recipients = contacts.joinToString("\n") {
                    "${it["name"].orEmpty()} — " +
                        it["phone"].orEmpty()
                }

                AlertDialog.Builder(activity)
                    .setTitle("Start ${options[index]}?")
                    .setMessage(
                        previous +
                            "Recipients:\n$recipients\n\n" +
                            "If you miss this check-in, a real SMS " +
                            "will be attempted automatically. " +
                            "Location is included only when available. " +
                            "SMS charges apply.\n\n" +
                            "Reopen Safety check-in and tap I'm safe " +
                            "to cancel before the deadline.\n\n" +
                            "The phone must remain on with cellular " +
                            "service. Restarting, force-stopping, or " +
                            "removing alarm access can prevent the alert. " +
                            "Delivery and emergency-service response " +
                            "are not guaranteed."
                    )
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Approve and start") { _, _ ->
                        try {
                            start(
                                activity,
                                contacts,
                                durations[index]
                            )

                            show(activity, contacts)
                        } catch (error: Exception) {
                            toast(
                                activity,
                                error.message
                                    ?: "Could not start check-in."
                            )
                        }
                    }
                    .show()
            }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun toast(
        context: Context,
        message: String
    ) {
        Toast.makeText(
            context,
            message,
            Toast.LENGTH_LONG
        ).show()
    }
}

class SafetyCheckInReceiver : BroadcastReceiver() {

    override fun onReceive(
        context: Context,
        intent: Intent
    ) {
        val id = intent.getStringExtra("id") ?: return
        val app = context.applicationContext
        val pending = goAsync()

        Thread {
            try {
                val contacts = SafetyCheckIn.claim(app, id)

                if (contacts == null) {
                    pending.finish()
                    return@Thread
                }

                TrustedSmsTest.sendSos(
                    app,
                    contacts,
                    object : MethodChannel.Result {

                        override fun success(result: Any?) {
                            try {
                                val data = result as? Map<*, *>

                                val submitted =
                                    (data?.get("submitted") as? Number)
                                        ?.toInt()

                                val failed =
                                    (data?.get("failed") as? Number)
                                        ?.toInt()

                                val state = when {
                                    submitted == null ||
                                        failed == null -> "unknown"

                                    submitted == 0 -> "failed"

                                    failed > 0 -> "partial"

                                    else -> "submitted"
                                }

                                SafetyCheckIn.finish(
                                    app,
                                    id,
                                    state
                                )
                            } finally {
                                pending.finish()
                            }
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?
                        ) {
                            try {
                                SafetyCheckIn.finish(
                                    app,
                                    id,
                                    "failed"
                                )
                            } finally {
                                pending.finish()
                            }
                        }

                        override fun notImplemented() {
                            try {
                                SafetyCheckIn.finish(
                                    app,
                                    id,
                                    "unknown"
                                )
                            } finally {
                                pending.finish()
                            }
                        }
                    },
                    checkIn = true
                )
            } catch (_: Exception) {
                try {
                    SafetyCheckIn.finish(
                        app,
                        id,
                        "unknown"
                    )
                } finally {
                    pending.finish()
                }
            }
        }.start()
    }
}