@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat

enum class PermissionType {
    notifications, androidSharedStorage, iosAddToPhotoLibrary, iosChangePhotoLibrary
}

enum class PermissionStatus {
    undetermined, denied, granted, partial, requestError
}

class PermissionsService {
    companion object {
        private const val baseRequestCode = 373900
        private const val TAG = "PermissionsService"

        /**
         * Requests [PermissionStatus] for permission of [permissionType]
         *
         * Requests [PermissionStatus.granted] for unknown permissions
         */
        fun getPermissionStatus(
            context: Context,
            permissionType: PermissionType
        ): PermissionStatus {
            when (permissionType) {
                PermissionType.notifications -> {
                    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        // On Android 33+, check/ask for permission
                        val auth = ActivityCompat.checkSelfPermission(
                            context, Manifest.permission.POST_NOTIFICATIONS
                        )
                        if (auth == PackageManager.PERMISSION_GRANTED)
                            PermissionStatus.granted
                        else
                            PermissionStatus.denied
                    } else {
                        PermissionStatus.granted
                    }
                }

                PermissionType.androidSharedStorage -> {
                    return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q
                    ) {
                        // On Android before 29, check/ask for permission
                        val auth = ActivityCompat.checkSelfPermission(
                            context, Manifest.permission.WRITE_EXTERNAL_STORAGE
                        )
                        if (auth == PackageManager.PERMISSION_GRANTED)
                            PermissionStatus.granted
                        else
                            PermissionStatus.denied
                    } else {
                        PermissionStatus.granted
                    }
                }

                else -> {
                    return PermissionStatus.granted
                }
            }
        }

        /**
         * Requests permission for [permissionType] adn returns a Boolean
         * If true a request has been made that the flutter side should wait for
         * If false, no request has been made -> check permission status separately
         *
         * Does not wait for result. Once result is received via the
         * [onRequestPermissionsResult], a message is sent back to the
         * Flutter side with the permission result
         */
        fun requestPermission(permissionType: PermissionType) : Boolean {
            val requestCode = baseRequestCode + permissionType.ordinal
            when (permissionType) {
                PermissionType.notifications -> {
                    // On Android 33+, check/ask for permission
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (BDPlugin.activity == null) {
                            return false
                        }
                        ActivityCompat.requestPermissions(
                            BDPlugin.activity!!, arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            requestCode
                        )
                        return true
                    } else {
                        return false
                    }
                }

                PermissionType.androidSharedStorage -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        // On Android before 29, check/ask for permission
                        if (BDPlugin.activity == null) {
                            return false
                        }
                        ActivityCompat.requestPermissions(
                            BDPlugin.activity!!,
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            requestCode
                        )
                        // completer will be completed via [onRequestPermissionsResult]
                        return true

                    } else {
                        return false
                    }
                }

                else -> {
                   return false
                }
            }
        }

        /**
         * Returns true if Android shouldShowRequestPermissionRationale returns true for this
         * [permissionType]. Returns false for unrecognized [permissionType]
         */
        fun shouldShowRequestPermissionRationale(permissionType: PermissionType) : Boolean {
            return when (permissionType) {
                PermissionType.notifications -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                         ActivityCompat.shouldShowRequestPermissionRationale(BDPlugin.activity!!, Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        false
                    }
                }

                PermissionType.androidSharedStorage -> {
                    ActivityCompat.shouldShowRequestPermissionRationale(BDPlugin.activity!!, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                }

                else -> false
            }
        }

        /// Processes the onRequestPermissionsResult received by the Activity
        fun onRequestPermissionsResult(
            requestCode: Int, permissions: Array<out String>, grantResults: IntArray
        ): Boolean {
            val granted =
                (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            return when (requestCode) {
                baseRequestCode + PermissionType.notifications.ordinal,
                baseRequestCode + PermissionType.androidSharedStorage.ordinal-> {
                    sendPermissionResult(granted)
                    true
                }

                else -> {
                    false
                }
            }
        }

        /**
         * Send the [granted] result via the background channel to Flutter
         *
         * Only one request can be 'in flight' at any time
         */
        private fun sendPermissionResult(
            granted: Boolean
        ) {
            // send with dummy task ("")
            BDPlugin.backgroundChannel?.invokeMethod(
                "permissionRequestResult",
                listOf("", if (granted) PermissionStatus.granted.ordinal else PermissionStatus.denied.ordinal))

        }
    }
}
