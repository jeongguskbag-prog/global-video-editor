package com.globalvideoeditor.app

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import com.globalvideoeditor.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import okio.source
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private val prefs by lazy { getSharedPreferences("gve_prefs", MODE_PRIVATE) }

    private var selectedVideoUri: Uri? = null
    private var selectedVideoName: String = "input.mp4"
    private var resultFile: File? = null

    private val languageCodes = listOf("ko", "en", "zh", "es", "ja", "de", "fr", "vi")
    private val languageLabels = listOf(
        "한국어", "English", "中文", "Español", "日本語", "Deutsch", "Français", "Tiếng Việt"
    )
    private val modeCodes = listOf("dynamic_subtitle", "subtitle", "dubbing")
    private val modeLabels = listOf("다이나믹 자막", "일반 자막", "AI 더빙")
    private val genderCodes = listOf("female", "male")
    private val genderLabels = listOf("여성", "남성")

    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.MINUTES)
        .readTimeout(10, TimeUnit.MINUTES)
        .callTimeout(15, TimeUnit.MINUTES)
        .build()

    private val pickVideoLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            selectedVideoUri = uri
            selectedVideoName = queryFileName(uri) ?: "input.mp4"
            binding.textSelectedFile.text = selectedVideoName
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.editServerUrl.setText(prefs.getString("server_url", ""))
        binding.editLicenseKey.setText(prefs.getString("license_key", ""))

        binding.spinnerLanguage.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, languageLabels)
        binding.spinnerMode.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, modeLabels)
        binding.spinnerGender.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, genderLabels)

        binding.spinnerMode.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val isDubbing = modeCodes[position] == "dubbing"
                binding.spinnerGender.isEnabled = isDubbing
                binding.labelGender.alpha = if (isDubbing) 1f else 0.4f
                binding.spinnerGender.alpha = if (isDubbing) 1f else 0.4f
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }

        binding.btnPickVideo.setOnClickListener {
            pickVideoLauncher.launch(arrayOf("video/*"))
        }

        binding.btnRender.setOnClickListener { startRender() }

        binding.btnPlayResult.setOnClickListener { playResult() }
        binding.btnShareResult.setOnClickListener { shareResult() }
    }

    private fun queryFileName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(idx)
            }
        }
        return name
    }

    private fun startRender() {
        val serverUrl = binding.editServerUrl.text?.toString()?.trim()?.trimEnd('/') ?: ""
        val licenseKey = binding.editLicenseKey.text?.toString()?.trim().orEmpty()

        if (serverUrl.isBlank()) {
            toast("서버 주소를 입력해 주세요")
            return
        }
        if (licenseKey.isBlank()) {
            toast("라이선스 키를 입력해 주세요")
            return
        }
        if (selectedVideoUri == null) {
            toast("영상 파일을 선택해 주세요")
            return
        }

        prefs.edit().putString("server_url", serverUrl).putString("license_key", licenseKey).apply()

        val langCode = languageCodes[binding.spinnerLanguage.selectedItemPosition]
        val modeCode = modeCodes[binding.spinnerMode.selectedItemPosition]
        val genderCode = genderCodes[binding.spinnerGender.selectedItemPosition]
        val deviceId = androidDeviceId()

        setLoading(true, "서버에 업로드 중... (영상 길이에 따라 수 분 소요될 수 있어요)")

        lifecycleScope.launch {
            try {
                val bodyBuilder = MultipartBody.Builder().setType(MultipartBody.FORM)
                    .addFormDataPart("target_lang", langCode)
                    .addFormDataPart("gender", genderCode)
                    .addFormDataPart("mode", modeCode)
                    .addFormDataPart("license_key", licenseKey)
                    .addFormDataPart("device_id", deviceId)

                val uri = selectedVideoUri!!
                bodyBuilder.addFormDataPart(
                    "file", selectedVideoName,
                    ContentUriRequestBody(contentResolver, uri, "video/mp4".toMediaTypeOrNull())
                )

                val request = Request.Builder()
                    .url("$serverUrl/api/render_file")
                    .post(bodyBuilder.build())
                    .build()

                val outFile = withContext(Dispatchers.IO) {
                    executeAndSave(request, langCode)
                }

                resultFile = outFile
                setLoading(false, "완료! 저장 위치: ${outFile.absolutePath}")
                binding.layoutResultActions.visibility = View.VISIBLE

            } catch (e: ServerErrorException) {
                setLoading(false, "오류: ${e.message}")
            } catch (e: IOException) {
                Log.e("GVE", "network error", e)
                setLoading(false, "네트워크 오류: ${e.message}")
            } catch (e: Exception) {
                Log.e("GVE", "unexpected error", e)
                setLoading(false, "알 수 없는 오류: ${e.message}")
            }
        }
    }

    private class ServerErrorException(message: String) : Exception(message)

    private fun executeAndSave(request: Request, langCode: String): File {
        httpClient.newCall(request).execute().use { response: Response ->
            if (!response.isSuccessful) {
                val errBody = response.body?.string().orEmpty()
                val msg = try { JSONObject(errBody).optString("error", "서버 오류 (${response.code})") }
                          catch (e: Exception) { "서버 오류 (${response.code})" }
                throw ServerErrorException(msg)
            }
            val moviesDir = getExternalFilesDir("Movies") ?: filesDir
            if (!moviesDir.exists()) moviesDir.mkdirs()
            val outFile = File(moviesDir, "result_${langCode}_${System.currentTimeMillis()}.mp4")
            response.body?.byteStream()?.use { input ->
                outFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            } ?: throw IOException("빈 응답을 받았습니다")
            return outFile
        }
    }

    private fun setLoading(loading: Boolean, statusText: String) {
        binding.progressBar.visibility = if (loading) View.VISIBLE else View.GONE
        binding.btnRender.isEnabled = !loading
        binding.textStatus.text = statusText
    }

    private fun androidDeviceId(): String {
        return try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: "UNKNOWN_DEVICE"
        } catch (e: Exception) {
            "UNKNOWN_DEVICE"
        }
    }

    private fun playResult() {
        val file = resultFile ?: return
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/mp4")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            toast("영상을 재생할 앱을 찾을 수 없습니다")
        }
    }

    private fun shareResult() {
        val file = resultFile ?: return
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "공유하기"))
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}

private class ContentUriRequestBody(
    private val resolver: ContentResolver,
    private val uri: Uri,
    private val mediaType: okhttp3.MediaType?
) : RequestBody() {

    override fun contentType() = mediaType

    override fun contentLength(): Long {
        return try {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getLong(idx) else -1L
            } ?: -1L
        } catch (e: Exception) {
            -1L
        }
    }

    override fun writeTo(sink: BufferedSink) {
        val stream = resolver.openInputStream(uri) ?: throw IOException("파일을 열 수 없습니다")
        stream.use { input ->
            sink.writeAll(input.source())
        }
    }
}
