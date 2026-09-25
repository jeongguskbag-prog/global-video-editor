package com.globalvideoeditor.app

import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/**
 * Minimal Kotlin client for Microsoft Edge's "Read Aloud" cloud text-to-speech
 * WebSocket API -- the same engine the `edge-tts` Python package (and this
 * app's PC build) uses -- reverse-engineered from
 * https://github.com/rany2/edge-tts. Replaces Android's on-device
 * TextToSpeech engine, whose voice quality/pacing varies wildly across
 * phones and manufacturers, with the one proven-natural-sounding engine the
 * PC app already relies on.
 */
object EdgeTts {

    private const val TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private const val CHROMIUM_FULL_VERSION = "143.0.3650.75"
    private const val CHROMIUM_MAJOR_VERSION = "143"
    private const val SEC_MS_GEC_VERSION = "1-$CHROMIUM_FULL_VERSION"
    private const val WSS_BASE_URL =
        "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1" +
            "?TrustedClientToken=$TRUSTED_CLIENT_TOKEN"
    private const val WIN_EPOCH_SECONDS = 11644473600.0
    private val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" +
        " (KHTML, like Gecko) Chrome/$CHROMIUM_MAJOR_VERSION.0.0.0 Safari/537.36" +
        " Edg/$CHROMIUM_MAJOR_VERSION.0.0.0"

    // langCode -> (female voice, male voice). Mirrors pc_app/dubber_gui.py's LANGUAGES
    // table so PC and Android pick the same voice for the same language/gender.
    private val VOICES: Map<String, Pair<String, String>> = mapOf(
        "ko" to ("ko-KR-SunHiNeural" to "ko-KR-InJoonNeural"),
        "en" to ("en-US-AriaNeural" to "en-US-GuyNeural"),
        "zh" to ("zh-CN-XiaoxiaoNeural" to "zh-CN-YunxiNeural"),
        "es" to ("es-ES-ElviraNeural" to "es-ES-AlvaroNeural"),
        "ja" to ("ja-JP-NanamiNeural" to "ja-JP-KeitaNeural"),
        "de" to ("de-DE-KatjaNeural" to "de-DE-ConradNeural"),
        "fr" to ("fr-FR-DeniseNeural" to "fr-FR-HenriNeural"),
        "vi" to ("vi-VN-HoaiMyNeural" to "vi-VN-NamMinhNeural"),
    )

    fun voiceFor(langCode: String, genderCode: String): String {
        val pair = VOICES[langCode] ?: VOICES.getValue("en")
        return if (genderCode == "male") pair.second else pair.first
    }

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    class EdgeTtsException(message: String) : Exception(message)

    /** Synthesizes [text] with [voiceName] and writes the raw MP3 bytes to [outFile]. */
    suspend fun synthesize(text: String, voiceName: String, outFile: File) {
        suspendCancellableCoroutine<Unit> { cont ->
            val url = "$WSS_BASE_URL&ConnectionId=${uuidNoDashes()}" +
                "&Sec-MS-GEC=${generateSecMsGec()}&Sec-MS-GEC-Version=$SEC_MS_GEC_VERSION"

            val request = Request.Builder()
                .url(url)
                .header("User-Agent", USER_AGENT)
                .header("Accept-Encoding", "gzip, deflate, br, zstd")
                .header("Accept-Language", "en-US,en;q=0.9")
                .header("Pragma", "no-cache")
                .header("Cache-Control", "no-cache")
                .header("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
                .header("Cookie", "muid=${generateMuid()};")
                .build()

            val audioBytes = ByteArrayOutputStream()

            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send(
                        "X-Timestamp:${dateToString()}\r\n" +
                            "Content-Type:application/json; charset=utf-8\r\n" +
                            "Path:speech.config\r\n\r\n" +
                            "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{" +
                            "\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"}," +
                            "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
                    )
                    val ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>" +
                        "<voice name='$voiceName'>" +
                        "<prosody pitch='+0Hz' rate='+0%' volume='+0%'>" +
                        escapeSsml(text) +
                        "</prosody></voice></speak>"
                    webSocket.send(
                        "X-RequestId:${uuidNoDashes()}\r\n" +
                            "Content-Type:application/ssml+xml\r\n" +
                            "X-Timestamp:${dateToString()}Z\r\n" +
                            "Path:ssml\r\n\r\n" +
                            ssml
                    )
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text.contains("Path:turn.end")) {
                        webSocket.close(1000, null)
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    val data = bytes.toByteArray()
                    if (data.size < 2) return
                    val headerLen = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)
                    if (headerLen + 2 > data.size) return
                    val headerText = String(data, 2, headerLen, Charsets.UTF_8)
                    val isAudio = headerText.lineSequence().any { line ->
                        line.trim().equals("Path:audio", ignoreCase = true)
                    }
                    if (isAudio) {
                        audioBytes.write(data, 2 + headerLen, data.size - 2 - headerLen)
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    finishUp()
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (cont.isActive) {
                        cont.resumeWithException(EdgeTtsException("EdgeTTS 연결 실패: ${t.message}"))
                    }
                }

                private fun finishUp() {
                    if (!cont.isActive) return
                    if (audioBytes.size() == 0) {
                        cont.resumeWithException(EdgeTtsException("EdgeTTS로부터 오디오를 받지 못했습니다"))
                        return
                    }
                    try {
                        outFile.writeBytes(audioBytes.toByteArray())
                        cont.resume(Unit)
                    } catch (e: Exception) {
                        cont.resumeWithException(e)
                    }
                }
            }

            val ws = httpClient.newWebSocket(request, listener)
            cont.invokeOnCancellation { ws.cancel() }
        }
    }

    private fun uuidNoDashes(): String = UUID.randomUUID().toString().replace("-", "")

    private fun escapeSsml(text: String): String {
        val cleaned = text.map { c ->
            val code = c.code
            if ((code in 0..8) || (code in 11..12) || (code in 14..31)) ' ' else c
        }.joinToString("")
        return cleaned
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
    }

    private fun dateToString(): String {
        val sdf = SimpleDateFormat("EEE MMM dd yyyy HH:mm:ss", Locale.US)
        sdf.timeZone = TimeZone.getTimeZone("UTC")
        return "${sdf.format(Date())} GMT+0000 (Coordinated Universal Time)"
    }

    // Sec-MS-GEC DRM token: SHA256 of (Windows-epoch ticks, rounded down to a 5-minute
    // boundary, in 100ns units) concatenated with the trusted client token. See
    // https://github.com/rany2/edge-tts/issues/290#issuecomment-2464956570
    private fun generateSecMsGec(): String {
        var ticks = System.currentTimeMillis() / 1000.0
        ticks += WIN_EPOCH_SECONDS
        ticks -= ticks % 300.0
        ticks *= 1.0e9 / 100.0
        val roundedTicks = Math.round(ticks)
        val toHash = "$roundedTicks$TRUSTED_CLIENT_TOKEN"
        val digest = MessageDigest.getInstance("SHA-256").digest(toHash.toByteArray(Charsets.US_ASCII))
        return digest.joinToString("") { "%02X".format(it.toInt() and 0xFF) }
    }

    private fun generateMuid(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02X".format(it.toInt() and 0xFF) }
    }
}
