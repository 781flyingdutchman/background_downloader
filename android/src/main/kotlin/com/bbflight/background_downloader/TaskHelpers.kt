package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.util.Log
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Installs a custom X509 TrustManager that accepts all certificates. Future
 * HTTPS calls will therefore not check the validity of the TLS certificate.
 *
 * DO NOT CONFIGURE THE DOWNLOADER TO BYPASS CERTIFICATE VALIDATION IN RELEASE
 */
fun acceptUntrustedCertificates() {
    try {
        // Create a trust manager that does not validate certificate chains
        val trustAllCerts = arrayOf<TrustManager>(
            @SuppressLint("CustomX509TrustManager")
            object : X509TrustManager {
                @SuppressLint("TrustAllX509TrustManager")
                override fun checkClientTrusted(
                    chain: Array<java.security.cert.X509Certificate>,
                    authType: String
                ) {
                }

                @SuppressLint("TrustAllX509TrustManager")
                override fun checkServerTrusted(
                    chain: Array<java.security.cert.X509Certificate>,
                    authType: String
                ) {
                }

                override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> {
                    return arrayOf()
                }
            })

        // Install the all-trusting trust manager
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, trustAllCerts, java.security.SecureRandom())
        // Create an ssl socket factory with our all-trusting manager
        val sslSocketFactory = sslContext.socketFactory
        HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
        Log.w(
            BackgroundDownloaderPlugin.TAG, "Bypassing TLS certificate validation\n" +
                    "HTTPS calls will NOT check the validity of the TLS certificate."
        )
    } catch (e: Exception) {
        throw RuntimeException(e)
    }
}
