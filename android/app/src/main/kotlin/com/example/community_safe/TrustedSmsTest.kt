package com.example.community_safe

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.widget.Toast
import java.text.DateFormat
import java.util.Date
import android.content.Context
import android.os.Handler
import android.os.Looper

object TrustedSmsTest {

    fun show(
        activity: Activity,
        contacts: List<Map<String, String>>
    ) {
        if (contacts.isEmpty()) {
            notify(activity, "Add a trusted contact first.")
            return
        }

        val labels = contacts.map {
            "${it["name"].orEmpty()} — ${it["phone"].orEmpty()}"
        }.toTypedArray()

        AlertDialog.Builder(activity)
            .setTitle("Choose one test recipient")
            .setItems(labels) { _, index ->
                val contact = contacts[index]

                val number = normalizeNumber(
                    contact["phone"].orEmpty()
                )

                if (!Regex("^\\+[1-9][0-9]{7,14}$").matches(number)) {
                    notify(
                        activity,
                        "Edit this contact's number to international format."
                    )
                    return@setItems
                }

                AlertDialog.Builder(activity)
                    .setTitle("Prepare location SMS?")
                    .setMessage(
                        "Prepare a TEST message for " +
                        "${contact["name"]} ($number)?\n\n" +
                        "This requests your location and previews the " +
                        "message before sending."
                    )
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Prepare preview") { _, _ ->
                        preparePreview(activity, number)
                    }
                    .show()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

        private fun preparePreview(activity: Activity, number: String) {
        notify(activity, "Getting location for the preview...")

        Thread {
            val message = try {
                val location = SosLocation.read(
                    activity.applicationContext
                )

                if (location["status"] == "available") {
                    val latitude = location["latitude"]
                    val longitude = location["longitude"]

                    val accuracy =
                        (location["accuracyMeters"] as Number).toInt()

                    val capturedAt =
                        (location["capturedAtMillis"] as Number).toLong()

                    val time = DateFormat.getDateTimeInstance()
                        .format(Date(capturedAt))

                    "Community Safe TEST ONLY. No emergency.\n" +
                        "Location fix: $time\n" +
                        "Estimated accuracy: ${accuracy}m\n" +
                        "https://maps.google.com/?q=$latitude,$longitude"
                } else {
                   "Location unavailable " +
                        "(reason: ${location["status"]}). " +
                        "Please contact me urgently." 
                }
            } catch (_: Exception) {
                "Community Safe TEST ONLY. No emergency. " +
                    "Location unavailable for this test."
            }

            activity.runOnUiThread {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    confirmSend(activity, number, message)
                }
            }
        }.start()
    }

    private fun confirmSend(
        activity: Activity,
        number: String,
        message: String
    ) {
        AlertDialog.Builder(activity)
            .setTitle("Send test SMS?")
            .setMessage(
                "To: $number\n\n$message\n\n" +
                "This sends a real SMS through your SIM. " +
                "The message may use multiple SMS segments. " +
                "Normal charges apply."
            )
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Send test SMS") { _, _ ->
                send(activity, number, message)
            }
            .show()
    }

    @Suppress("DEPRECATION")
    private fun send(
        activity: Activity,
        number: String,
        message: String
    ) {
        if (
            activity.checkSelfPermission(Manifest.permission.SEND_SMS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notify(activity, "Allow SMS permission in app settings.")
            return
        }

        try {
            val subscriptionId = SmsManager.getDefaultSmsSubscriptionId()

            if (!SubscriptionManager.isValidSubscriptionId(subscriptionId)) {
                notify(activity, "Choose a default SMS SIM in SIM manager.")
                return
            }

            val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                activity.getSystemService(SmsManager::class.java)
                    .createForSubscriptionId(subscriptionId)
            } else {
                SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            }

            val parts = manager.divideMessage(message)

            if (parts.size == 1) {
                manager.sendTextMessage(
                    number, null, message, null, null
                )
            } else {
                manager.sendMultipartTextMessage(
                    number, null, parts, null, null
                )
            }

            notify(
                activity,
                "Submitted to Android. Check the receiving phone."
            )
        } catch (_: Exception) {
            notify(activity, "Could not submit SMS. Check permission and SIM.")
        }
    }

            @Suppress("DEPRECATION")
            fun sendSos(
                context: Context,
                contacts: List<Map<String, String>>,
                result: io.flutter.plugin.common.MethodChannel.Result,
                senderName: String = "",
                checkIn: Boolean = false
            ) {
            if (
                context.checkSelfPermission(Manifest.permission.SEND_SMS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                result.error(
                    "SMS_PERMISSION",
                    "Allow SMS permission in app settings, then try again.",
                    null
                )
                return
            }

            // Normalize and deduplicate recipients before sending.
            val numbers = contacts.map {
                normalizeNumber(it["phone"].orEmpty())
            }.distinct()

            if (numbers.isEmpty()) {
                result.error(
                    "NO_CONTACTS",
                    "Add a trusted contact first.",
                    null
                )
                return
            }

            if (numbers.any {
                    !Regex("^\\+[1-9][0-9]{7,14}$").matches(it)
                }) {
                result.error(
                    "INVALID_NUMBER",
                    "Check your contacts. Use a South African local number " +
                        "or international format such as +27821234567.",
                    null
                )
                return
            }

            val manager = try {
                val subscriptionId = SmsManager.getDefaultSmsSubscriptionId()

                if (!SubscriptionManager.isValidSubscriptionId(subscriptionId)) {
                    result.error(
                        "NO_DEFAULT_SIM",
                        "Choose a default SMS SIM in your phone's SIM manager.",
                        null
                    )
                    return
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    context.getSystemService(SmsManager::class.java)
                        .createForSubscriptionId(subscriptionId)
                } else {
                    SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
                }
            } catch (_: Exception) {
                result.error(
                    "SMS_UNAVAILABLE",
                    "Could not access SMS. Check your SIM and SMS permission.",
                    null
                )
                return
            }

            Thread {
                var locationAvailable = false

                val locationDetails = try {
                    val location = SosLocation.read(
                        context.applicationContext,
                        checkIn = checkIn
)

                    if (location["status"] == "available") {
                        val latitude = location["latitude"]
                        val longitude = location["longitude"]
                        val accuracy =
                            (location["accuracyMeters"] as Number).toInt()
                        val capturedAt =
                            (location["capturedAtMillis"] as Number).toLong()
                        val time = DateFormat.getDateTimeInstance()
                            .format(Date(capturedAt))

                        locationAvailable = true

                        "Location fix: $time\n" +
                            "Estimated accuracy: ${accuracy}m\n" +
                            "https://maps.google.com/?q=$latitude,$longitude"
                    } else {
                        "Location unavailable. Please contact me urgently."
                    }
                } catch (_: Exception) {
                    "Location unavailable. Please contact me urgently."
                }

                val safeName = senderName
                    .replace(Regex("[\\r\\n]+"), " ")
                    .trim()
                    .take(121)

                val identityLine = if (safeName.isNotEmpty()) {
                    "From: $safeName\n"
                } else {
                    ""
                }

                val heading = if (checkIn) {
                    "COMMUNITY SAFE MISSED CHECK-IN\n"
                } else {
                    "COMMUNITY SAFE SOS\n"
                }

                val request = if (checkIn) {
                    "I missed my safety check-in. Please contact me " +
                        "and check that I'm safe.\n"
                } else {
                    "I need urgent help. Please call me and help " +
                        "arrange assistance.\n"
                }

                val message =
                    heading + identityLine + request + locationDetails

                var submitted = 0
                var failed = 0

                for (number in numbers) {
                    try {
                        val parts = manager.divideMessage(message)

                        if (parts.size == 1) {
                            manager.sendTextMessage(
                                number, null, message, null, null
                            )
                        } else {
                            manager.sendMultipartTextMessage(
                                number, null, parts, null, null
                            )
                        }

                        submitted++
                    } catch (_: Exception) {
                        failed++
                    }
                }

                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "submitted" to submitted,
                            "failed" to failed,
                            "locationAvailable" to locationAvailable
                        )
                    )
                }
            }.start()
        }

    private fun normalizeNumber(value: String): String {
        val clean = value.replace(Regex("[\\s()\\-]"), "")

        // Convert South African local numbers to +27 format.
        return if (Regex("^0[0-9]{9}$").matches(clean)) {
            "+27" + clean.drop(1)
        } else {
            clean
        }
    }

    private fun notify(activity: Activity, message: String) {
        Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
    }
}