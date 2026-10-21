package com.example.community_safe

import android.Manifest
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.text.InputType
import android.widget.EditText
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "community_safe/sms"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "showSmsTest" -> {
                    showSmsTest()
                    result.success(null)
                }

                "showTrustedSmsTest" -> {
                    val contacts =
                        call.argument<List<Map<String, String>>>("contacts")
                            ?: emptyList()

                    TrustedSmsTest.show(this, contacts)
                    result.success(null)
                }

                                "sendSos" -> {
                    val contacts =
                        call.argument<List<Map<String, String>>>("contacts")
                            ?: emptyList()

                    TrustedSmsTest.sendSos(this, contacts, result)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun showSmsTest() {
        if (
            checkSelfPermission(Manifest.permission.SEND_SMS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            showMessage("Allow SMS permission in app settings first.")
            return
        }

        val numberInput = EditText(this).apply {
            hint = "+27821234567"
            inputType = InputType.TYPE_CLASS_PHONE
            setSingleLine(true)
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle("Send one test SMS")
            .setMessage(
                "Enter a number you have permission to test with. " +
                "Use international format, such as +27821234567. " +
                "Normal SMS charges may apply."
            )
            .setView(numberInput)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Continue", null)
            .create()

        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener {
                    val number = numberInput.text.toString()
                        .replace(" ", "")
                        .replace("-", "")
                        .trim()

                    if (!Regex("^\\+[1-9][0-9]{7,14}$").matches(number)) {
                        numberInput.error =
                            "Use international format, for example +27821234567"
                    } else {
                        dialog.dismiss()
                        confirmTestSms(number)
                    }
                }
        }

        dialog.show()
    }

    private fun confirmTestSms(number: String) {
        val message =
            "Community Safe TEST ONLY. This is a test SMS. " +
            "No emergency assistance is requested."

        AlertDialog.Builder(this)
            .setTitle("Confirm test SMS")
            .setMessage(
                "To: $number\n\n$message\n\n" +
                "Send this text using your SIM?"
            )
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Send test SMS") { _, _ ->
                sendTestSms(number, message)
            }
            .show()
    }

    @Suppress("DEPRECATION")
    private fun sendTestSms(number: String, message: String) {
        try {
            val subscriptionId = SmsManager.getDefaultSmsSubscriptionId()

            if (!SubscriptionManager.isValidSubscriptionId(subscriptionId)) {
                showMessage(
                    "Choose a default SMS SIM in your phone's SIM manager."
                )
                return
            }

            val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(SmsManager::class.java)
                    .createForSubscriptionId(subscriptionId)
            } else {
                SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
            }

            manager.sendTextMessage(
                number,
                null,
                message,
                null,
                null
            )

            showMessage(
                "SMS submitted to Android. Check the receiving phone."
            )

        } catch (_: SecurityException) {
            showMessage("SMS permission is missing or restricted.")
        } catch (_: Exception) {
            showMessage("Could not submit SMS. Check your SIM and service.")
        }
    }

    private fun showMessage(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }
}