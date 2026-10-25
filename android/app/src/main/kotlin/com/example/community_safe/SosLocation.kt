package com.example.community_safe

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit

object SosLocation {

    @SuppressLint("MissingPermission")
    fun read(
        context: Context,
        checkIn: Boolean = false
    ): Map<String, Any> {

        val fine = context.checkSelfPermission(
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val coarse = context.checkSelfPermission(
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fine && !coarse) {
            return mapOf("status" to "permission_denied")
        }

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.checkSelfPermission(
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return mapOf("status" to "background_permission_missing")
        }

        val client = LocationServices.getFusedLocationProviderClient(context)
        val cancellation = CancellationTokenSource()

        try {
            val request = CurrentLocationRequest.Builder()
                .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                .setMaxUpdateAgeMillis(30_000L)
                .setDurationMillis(if (checkIn) 2_000L else 10_000L)
                .build()

            var location = try {
                Tasks.await(
                    client.getCurrentLocation(
                        request,
                        cancellation.token
                    ),
                    if (checkIn) 3L else 12L,
                    TimeUnit.SECONDS
                )
            } catch (_: Exception) {
                null
            }

            var source = "current_request"

            if (location == null) {
                source = "cached"

                location = try {
                    Tasks.await(
                        client.lastLocation,
                        if (checkIn) 1L else 3L,
                        TimeUnit.SECONDS
                    )
                } catch (_: Exception) {
                    null
                }
            }

            val fix = location
                ?: return mapOf("status" to "unavailable")

            val ageMillis = (
                (SystemClock.elapsedRealtimeNanos() -
                    fix.elapsedRealtimeNanos) / 1_000_000L
                ).coerceAtLeast(0L)

            // Do not attach an old cached position.
            if (ageMillis > 120_000L) {
                return mapOf("status" to "stale")
            }

            if (!fix.hasAccuracy()) {
                return mapOf("status" to "unavailable")
            }

            return mapOf(
                "status" to "available",
                "latitude" to fix.latitude,
                "longitude" to fix.longitude,
                "accuracyMeters" to fix.accuracy.toDouble(),
                "capturedAtMillis" to fix.time,
                "ageAtReadMillis" to ageMillis,
                "source" to source
            )

        } catch (_: SecurityException) {
            return mapOf("status" to "permission_denied")
        } catch (_: Exception) {
            return mapOf("status" to "unavailable")
        } finally {
            cancellation.cancel()
        }
    }
}