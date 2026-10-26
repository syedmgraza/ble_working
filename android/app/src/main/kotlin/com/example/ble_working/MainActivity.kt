package com.example.ble_working

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

private const val CHANNEL = "com.example.ble_working/payment_crypto"
private const val RSA_KEY_BYTES = 256
private const val GCM_IV_BYTES = 12
private const val GCM_TAG_BITS = 128

/** Android implementation kept byte-for-byte compatible with HybridCryptoService. */
class MainActivity : FlutterActivity() {
    private data class SeenPacket(val payloadJson: String, val claimedAt: Long)
    private val seenCiphertexts = ConcurrentHashMap<String, SeenPacket>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "encryptPayment" -> {
                            val json = call.argument<String>("instructionJson")
                                ?: error("instructionJson is required")
                            val key = call.argument<String>("serverPublicKeyBase64")
                                ?: error("serverPublicKeyBase64 is required")
                            result.success(encryptPayment(json.toByteArray(Charsets.UTF_8), key))
                        }
                        "claimCiphertext" -> {
                            val ciphertext = call.argument<String>("ciphertext")
                                ?: error("ciphertext is required")
                            val payloadJson = call.argument<String>("packetJson") ?: ciphertext
                            val hash = sha256(ciphertext.toByteArray(Charsets.UTF_8))
                            pruneSeenHashes()
                            val fresh = seenCiphertexts.putIfAbsent(
                                hash, SeenPacket(payloadJson, System.currentTimeMillis())
                            ) == null
                            result.success(mapOf("hash" to hash, "fresh" to fresh))
                        }
                        "releaseCiphertext" -> {
                            val ciphertext = call.argument<String>("ciphertext")
                                ?: error("ciphertext is required")
                            seenCiphertexts.remove(sha256(ciphertext.toByteArray(Charsets.UTF_8)))
                            result.success(null)
                        }
                        "getServerPublicKey" -> {
                            result.success(
                                getSharedPreferences("bluepay_demo", MODE_PRIVATE)
                                    .getString("server_public_key", null)
                            )
                        }
                        "saveServerPublicKey" -> {
                            val key = call.argument<String>("publicKey")
                                ?: error("publicKey is required")
                            val publicKey = parseRsaPublicKey(key)
                            require((publicKey as java.security.interfaces.RSAPublicKey)
                                .modulus.bitLength() == 2048) {
                                "Expected a 2048-bit RSA public key"
                            }
                            getSharedPreferences("bluepay_demo", MODE_PRIVATE)
                                .edit()
                                .putString("server_public_key", key.filterNot { it.isWhitespace() })
                                .apply()
                            result.success(null)
                        }
                        "appendAuditRecord" -> {
                            val record = JSONObject().apply {
                                put("direction", call.argument<String>("direction") ?: "UNKNOWN")
                                put("packetJson", call.argument<String>("packetJson") ?: "")
                                put("deviceId", call.argument<String>("deviceId") ?: "unknown")
                                put("status", call.argument<String>("status") ?: "")
                                put("timestamp", System.currentTimeMillis())
                            }
                            appendAuditRecord(record)
                            result.success(null)
                        }
                        "readAuditRecords" -> result.success(readAuditRecords())
                        "clearAuditRecords" -> {
                            File(filesDir, "bluepay_mesh_audit.json").delete()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("PAYMENT_CRYPTO_ERROR", error.message, null)
                }
            }
    }

    private fun encryptPayment(plaintext: ByteArray, publicKeyBase64: String): String {
        val publicKey = parseRsaPublicKey(publicKeyBase64)
        val keyGenerator = KeyGenerator.getInstance("AES").apply { init(256) }
        val aesKey = keyGenerator.generateKey()
        val iv = ByteArray(GCM_IV_BYTES).also { SecureRandom().nextBytes(it) }

        val aes = Cipher.getInstance("AES/GCM/NoPadding")
        aes.init(Cipher.ENCRYPT_MODE, aesKey, GCMParameterSpec(GCM_TAG_BITS, iv))
        val encryptedPayload = aes.doFinal(plaintext)

        val rsa = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        rsa.init(
            Cipher.ENCRYPT_MODE,
            publicKey,
            OAEPParameterSpec(
                "SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT
            )
        )
        val encryptedAesKey = rsa.doFinal(aesKey.encoded)
        require(encryptedAesKey.size == RSA_KEY_BYTES) {
            "Expected a 2048-bit RSA public key"
        }
        val packed = ByteBuffer.allocate(encryptedAesKey.size + iv.size + encryptedPayload.size)
            .put(encryptedAesKey)
            .put(iv)
            .put(encryptedPayload)
            .array()
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    private fun parseRsaPublicKey(encoded: String): PublicKey {
        val cleaned = encoded
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .filterNot { it.isWhitespace() }
        val bytes = Base64.decode(cleaned, Base64.DEFAULT)
        return KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(bytes))
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest
        .getInstance("SHA-256")
        .digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun pruneSeenHashes() {
        if (seenCiphertexts.size < 256) return
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        seenCiphertexts.forEach { (hash, packet) ->
            if (packet.claimedAt < cutoff) seenCiphertexts.remove(hash)
        }
    }

    private fun appendAuditRecord(record: JSONObject) {
        synchronized(this) {
            val file = File(filesDir, "bluepay_mesh_audit.json")
            val records = if (file.exists()) {
                try { JSONArray(file.readText()) } catch (_: Exception) { JSONArray() }
            } else {
                JSONArray()
            }
            records.put(record)
            val firstToKeep = (records.length() - 2000).coerceAtLeast(0)
            val bounded = JSONArray()
            for (index in firstToKeep until records.length()) {
                bounded.put(records.getJSONObject(index))
            }
            file.writeText(bounded.toString())
        }
    }

    private fun readAuditRecords(): List<Map<String, Any>> = synchronized(this) {
        val file = File(filesDir, "bluepay_mesh_audit.json")
        if (!file.exists()) return@synchronized emptyList()
        val records = try { JSONArray(file.readText()) } catch (_: Exception) { JSONArray() }
        (0 until records.length()).map { index ->
            val item = records.getJSONObject(index)
            mapOf(
                "direction" to item.optString("direction"),
                "packetJson" to item.optString("packetJson"),
                "deviceId" to item.optString("deviceId"),
                "status" to item.optString("status"),
                "timestamp" to item.optLong("timestamp"),
            )
        }.reversed()
    }
}
