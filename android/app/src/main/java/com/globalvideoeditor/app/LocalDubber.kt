package com.globalvideoeditor.app

import android.content.Context
import android.net.Uri
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.ReturnCode
import dev.ffmpegkit.whisper.Whisper
import dev.ffmpegkit.whisper.WhisperConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Fully on-device pipeline: audio extraction + subtitle burn-in / mixing via ffmpeg-kit,
 * speech recognition via whisper-android (ggml-base.bin, downloaded once), translation via
 * Google's free text endpoint, and dubbing voice via Android's built-in TextToSpeech engine.
 * Only the license check touches the network server; everything else runs on the phone.
 */
object LocalDubber {

    private const val MODEL_FILENAME = "ggml-base.bin"
    private const val MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"

    data class Segment(val startMs: Long, val endMs: Long, val sourceText: String, var translated: String = "")

    // Render's free tier spins down after inactivity and can take 30-60s to wake up,
    // so the license check needs a generous connect/read timeout, not OkHttp's 10s default.
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()

    class PipelineException(message: String) : Exception(message)

    suspend fun verifyLicenseAndRun(
        context: Context,
        serverUrl: String,
        licenseKey: String,
        deviceId: String,
        videoUri: Uri,
        videoName: String,
        langCode: String,
        genderCode: String,
        modeCode: String,
        log: (String) -> Unit
    ): File {
        log("라이선스 확인 중...")
        verifyLicense(serverUrl, licenseKey, deviceId)

        log("영상 불러오는 중...")
        val workDir = File(context.cacheDir, "gve_work").apply { mkdirs() }
        val inputFile = File(workDir, "input_${System.currentTimeMillis()}.mp4")
        copyUriToFile(context, videoUri, inputFile)

        val modelFile = ensureModel(context, log)

        log("오디오 추출 중...")
        val audioFile = File(workDir, "audio.wav")
        runFfmpeg(
            "-y -i \"${inputFile.absolutePath}\" -vn -acodec pcm_s16le -ar 16000 -ac 1 \"${audioFile.absolutePath}\""
        )

        val hasOriginalAudio = audioFile.exists() && audioFile.length() > 1000
        if (!hasOriginalAudio) {
            val duration = probeDurationSeconds(inputFile)
            runFfmpeg(
                "-y -f lavfi -i anullsrc=r=16000:cl=mono -t $duration -acodec pcm_s16le \"${audioFile.absolutePath}\""
            )
        }

        log("음성 인식 중 (온디바이스 Whisper)...")
        val segments = transcribe(context, modelFile, audioFile)
        log("인식된 문장 수: ${segments.size}")

        log("번역 중...")
        for (seg in segments) {
            seg.translated = translateText(seg.sourceText, langCode)
        }

        val outputFile = File(workDir, "output.mp4")

        if (modeCode == "subtitle" || modeCode == "dynamic_subtitle") {
            log("자막 생성 중...")
            val srtFile = File(workDir, "subtitles.srt")
            writeSrt(segments, srtFile)
            log("자막 인코딩 중...")
            val ok = runFfmpeg(
                "-y -i \"${inputFile.absolutePath}\" -vf subtitles='${srtFile.absolutePath.replace("'", "\\'")}' " +
                    "-c:v libx264 -preset veryfast -c:a copy \"${outputFile.absolutePath}\""
            )
            if (!ok || !outputFile.exists()) {
                runFfmpeg(
                    "-y -i \"${inputFile.absolutePath}\" -i \"${srtFile.absolutePath}\" " +
                        "-c copy -c:s mov_text \"${outputFile.absolutePath}\""
                )
            }
        } else {
            log("AI 음성 합성 중 (온디바이스 TTS)...")
            val fullText = segments.joinToString(" ") { it.translated }.ifBlank { "더빙이 완료되었습니다." }
            val ttsFile = File(workDir, "tts.wav")
            synthesizeSpeech(context, fullText, localeFor(langCode), ttsFile)

            log("영상과 더빙 음성 합성 중...")
            val mixOk = if (hasOriginalAudio) {
                runFfmpeg(
                    "-y -i \"${inputFile.absolutePath}\" -i \"${ttsFile.absolutePath}\" " +
                        "-filter_complex \"[0:a]volume=0.25[a0];[1:a]volume=1.3[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[aout]\" " +
                        "-map 0:v:0 -map \"[aout]\" -c:v copy -c:a aac -b:a 192k \"${outputFile.absolutePath}\""
                )
            } else {
                runFfmpeg(
                    "-y -i \"${inputFile.absolutePath}\" -i \"${ttsFile.absolutePath}\" " +
                        "-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac \"${outputFile.absolutePath}\""
                )
            }
            if (!mixOk || !outputFile.exists()) {
                runFfmpeg(
                    "-y -i \"${inputFile.absolutePath}\" -i \"${ttsFile.absolutePath}\" " +
                        "-map 0:v:0 -map 1:a:0 -c:v copy -c:a aac \"${outputFile.absolutePath}\""
                )
            }
        }

        if (!outputFile.exists() || outputFile.length() < 1000) {
            inputFile.copyTo(outputFile, overwrite = true)
        }

        val moviesDir = context.getExternalFilesDir("Movies") ?: context.filesDir
        if (!moviesDir.exists()) moviesDir.mkdirs()
        val finalFile = File(moviesDir, "result_${langCode}_${System.currentTimeMillis()}.mp4")
        outputFile.copyTo(finalFile, overwrite = true)

        workDir.deleteRecursively()
        return finalFile
    }

    private suspend fun verifyLicense(serverUrl: String, licenseKey: String, deviceId: String) {
        withContext(Dispatchers.IO) {
            val body = okhttp3.FormBody.Builder()
                .add("license_key", licenseKey)
                .add("device_id", deviceId)
                .build()
            val request = Request.Builder().url("$serverUrl/api/verify_license").post(body).build()
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    val errBody = response.body?.string().orEmpty()
                    val msg = try {
                        org.json.JSONObject(errBody).optString("error", "라이선스 확인 실패 (${response.code})")
                    } catch (e: Exception) {
                        "라이선스 확인 실패 (${response.code})"
                    }
                    throw PipelineException(msg)
                }
            }
        }
    }

    private suspend fun ensureModel(context: Context, log: (String) -> Unit): File {
        val modelDir = File(context.getExternalFilesDir(null), "models").apply { mkdirs() }
        val modelFile = File(modelDir, MODEL_FILENAME)
        if (modelFile.exists() && modelFile.length() > 50_000_000) return modelFile

        log("음성 인식 모델 다운로드 중 (최초 1회, 약 140MB)...")
        withContext(Dispatchers.IO) {
            val tempFile = File(modelDir, "$MODEL_FILENAME.part")
            val connection = URL(MODEL_URL).openConnection() as HttpURLConnection
            connection.connect()
            if (connection.responseCode !in 200..299) {
                throw PipelineException("모델 다운로드 실패 (HTTP ${connection.responseCode})")
            }
            val total = connection.contentLengthLong
            var downloaded = 0L
            var lastReportedPct = -1
            connection.inputStream.use { input ->
                tempFile.outputStream().use { output ->
                    val buffer = ByteArray(1024 * 256)
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        downloaded += read
                        if (total > 0) {
                            val pct = ((downloaded * 100) / total).toInt()
                            if (pct != lastReportedPct && pct % 10 == 0) {
                                lastReportedPct = pct
                                log("모델 다운로드 중... $pct%")
                            }
                        }
                    }
                }
            }
            connection.disconnect()
            tempFile.renameTo(modelFile)
        }
        return modelFile
    }

    private fun copyUriToFile(context: Context, uri: Uri, destFile: File) {
        context.contentResolver.openInputStream(uri)?.use { input ->
            destFile.outputStream().use { output -> input.copyTo(output) }
        } ?: throw PipelineException("영상 파일을 열 수 없습니다")
    }

    private suspend fun runFfmpeg(command: String): Boolean = withContext(Dispatchers.IO) {
        val session = FFmpegKit.execute(command)
        ReturnCode.isSuccess(session.returnCode)
    }

    private fun probeDurationSeconds(file: File): Double {
        return try {
            val session = FFmpegKit.execute("-i \"${file.absolutePath}\"")
            val log = session.allLogsAsString
            val line = log.lineSequence().firstOrNull { it.trim().startsWith("Duration:") }
            if (line != null) {
                val ts = line.trim().removePrefix("Duration:").trim().split(",")[0].trim()
                val parts = ts.split(":")
                val h = parts[0].toDouble()
                val m = parts[1].toDouble()
                val s = parts[2].toDouble()
                h * 3600 + m * 60 + s
            } else {
                10.0
            }
        } catch (e: Exception) {
            10.0
        }
    }

    private suspend fun transcribe(context: Context, modelFile: File, audioFile: File): List<Segment> {
        val model = Whisper.loadModel(context, modelFile.absolutePath)
        try {
            val result = Whisper.transcribe(model, audioFile.absolutePath, WhisperConfig())
            return result.segments.map {
                Segment(startMs = it.startMs, endMs = it.endMs, sourceText = it.text.trim())
            }.filter { it.sourceText.isNotEmpty() }
        } finally {
            Whisper.releaseModel(model)
        }
    }

    private suspend fun translateText(text: String, targetCode: String): String {
        if (text.isBlank()) return ""
        return withContext(Dispatchers.IO) {
            try {
                val url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=" +
                    "$targetCode&dt=t&q=${java.net.URLEncoder.encode(text, "UTF-8")}"
                val request = Request.Builder().url(url).header("User-Agent", "Mozilla/5.0").build()
                httpClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use text
                    val body = response.body?.string() ?: return@use text
                    val outer = JSONArray(body)
                    val firstArray = outer.getJSONArray(0)
                    val sb = StringBuilder()
                    for (i in 0 until firstArray.length()) {
                        val part = firstArray.getJSONArray(i)
                        sb.append(part.optString(0, ""))
                    }
                    sb.toString().ifBlank { text }
                }
            } catch (e: Exception) {
                text
            }
        }
    }

    private fun writeSrt(segments: List<Segment>, outFile: File) {
        outFile.bufferedWriter().use { writer ->
            segments.forEachIndexed { idx, seg ->
                writer.write("${idx + 1}\n")
                writer.write("${formatSrtTime(seg.startMs)} --> ${formatSrtTime(seg.endMs)}\n")
                writer.write("${seg.translated}\n\n")
            }
        }
    }

    private fun formatSrtTime(ms: Long): String {
        val h = ms / 3_600_000
        val m = (ms % 3_600_000) / 60_000
        val s = (ms % 60_000) / 1000
        val msRemainder = ms % 1000
        return String.format(Locale.US, "%02d:%02d:%02d,%03d", h, m, s, msRemainder)
    }

    private fun localeFor(langCode: String): Locale = when (langCode) {
        "ko" -> Locale.KOREAN
        "en" -> Locale.US
        "zh" -> Locale.SIMPLIFIED_CHINESE
        "es" -> Locale("es", "ES")
        "ja" -> Locale.JAPANESE
        "de" -> Locale.GERMAN
        "fr" -> Locale.FRENCH
        "vi" -> Locale("vi", "VN")
        else -> Locale.US
    }

    private suspend fun synthesizeSpeech(context: Context, text: String, locale: Locale, outFile: File) {
        val tts = createTts(context)
        try {
            val result = tts.setLanguage(locale)
            if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
                throw PipelineException("이 언어의 음성 데이터가 폰에 설치되어 있지 않습니다 (설정 > 일반 > 언어 및 입력 > 텍스트 음성 변환에서 설치 필요)")
            }
            val utteranceId = UUID.randomUUID().toString()
            suspendCancellableCoroutine<Unit> { cont ->
                tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {
                        if (cont.isActive) cont.resume(Unit)
                    }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        if (cont.isActive) cont.resumeWithException(PipelineException("TTS 합성 실패"))
                    }
                    override fun onError(utteranceId: String?, errorCode: Int) {
                        if (cont.isActive) cont.resumeWithException(PipelineException("TTS 합성 실패 (code $errorCode)"))
                    }
                })
                val params = android.os.Bundle()
                val res = tts.synthesizeToFile(text, params, outFile, utteranceId)
                if (res != TextToSpeech.SUCCESS && cont.isActive) {
                    cont.resumeWithException(PipelineException("TTS 요청 실패"))
                }
            }
        } finally {
            tts.stop()
            tts.shutdown()
        }
    }

    private suspend fun createTts(context: Context): TextToSpeech = suspendCancellableCoroutine { cont ->
        var ttsRef: TextToSpeech? = null
        ttsRef = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) {
                cont.resume(ttsRef!!)
            } else {
                cont.resumeWithException(PipelineException("TTS 엔진 초기화 실패"))
            }
        }
    }
}
