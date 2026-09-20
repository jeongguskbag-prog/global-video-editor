package com.globalvideoeditor.app

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
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

class MainActivity : AppCompatActivity() {

    companion object {
        private const val SERVER_URL = "https://global-video-editor.onrender.com"
    }

    private lateinit var binding: ActivityMainBinding
    private val prefs by lazy { getSharedPreferences("gve_prefs", MODE_PRIVATE) }

    private var selectedVideoUri: Uri? = null
    private var selectedVideoName: String = "input.mp4"
    private var resultFile: File? = null
    private var elapsedTimerJob: Job? = null

    private val languageCodes = listOf("ko", "en", "zh", "es", "ja", "de", "fr", "vi")
    private val languageLabels = listOf(
        "한국어", "English", "中文", "Español", "日本語", "Deutsch", "Français", "Tiếng Việt"
    )
    private val modeCodes = listOf("dynamic_subtitle", "subtitle", "dubbing")
    private val modeLabels = listOf("다이나믹 자막", "일반 자막", "AI 더빙")
    private val genderCodes = listOf("female", "male")
    private val genderLabels = listOf("여성", "남성")

    private val pickVideoLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            selectedVideoUri = uri
            selectedVideoName = queryFileName(uri) ?: "input.mp4"
            val size = queryFileSize(uri)
            binding.textSelectedFile.text = if (size != null) {
                "$selectedVideoName (${formatFileSize(size)})"
            } else {
                selectedVideoName
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

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

    private fun queryFileSize(uri: Uri): Long? {
        var size: Long? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (idx >= 0 && cursor.moveToFirst() && !cursor.isNull(idx)) {
                size = cursor.getLong(idx)
            }
        }
        return size
    }

    private fun formatFileSize(bytes: Long): String {
        val mb = bytes / (1024.0 * 1024.0)
        return if (mb >= 1024) String.format("%.1fGB", mb / 1024.0) else String.format("%.1fMB", mb)
    }

    private fun startRender() {
        val licenseKey = binding.editLicenseKey.text?.toString()?.trim().orEmpty()

        if (licenseKey.isBlank()) {
            toast("라이선스 키를 입력해 주세요")
            return
        }
        val uri = selectedVideoUri
        if (uri == null) {
            toast("영상 파일을 선택해 주세요")
            return
        }

        prefs.edit().putString("license_key", licenseKey).apply()

        val langCode = languageCodes[binding.spinnerLanguage.selectedItemPosition]
        val modeCode = modeCodes[binding.spinnerMode.selectedItemPosition]
        val genderCode = genderCodes[binding.spinnerGender.selectedItemPosition]
        val deviceId = androidDeviceId()

        setLoading(true, "처리 중...")
        startElapsedTimer()

        lifecycleScope.launch {
            try {
                val outFile = LocalDubber.verifyLicenseAndRun(
                    context = applicationContext,
                    serverUrl = SERVER_URL,
                    licenseKey = licenseKey,
                    deviceId = deviceId,
                    videoUri = uri,
                    videoName = selectedVideoName,
                    langCode = langCode,
                    genderCode = genderCode,
                    modeCode = modeCode,
                    log = { message -> runOnUiThread { binding.textStatus.text = message } }
                )

                resultFile = outFile
                setLoading(false, "완료! 저장 위치: ${outFile.absolutePath}")
                binding.layoutResultActions.visibility = View.VISIBLE

            } catch (e: LocalDubber.PipelineException) {
                setLoading(false, "오류: ${e.message}")
            } catch (e: Exception) {
                Log.e("GVE", "pipeline error", e)
                setLoading(false, "알 수 없는 오류: ${e.message}")
            }
        }
    }

    private fun setLoading(loading: Boolean, statusText: String) {
        binding.progressBar.visibility = if (loading) View.VISIBLE else View.GONE
        binding.btnRender.isEnabled = !loading
        binding.textStatus.text = statusText
        if (!loading) {
            elapsedTimerJob?.cancel()
            elapsedTimerJob = null
        }
    }

    private fun startElapsedTimer() {
        elapsedTimerJob?.cancel()
        elapsedTimerJob = lifecycleScope.launch {
            var seconds = 0
            while (true) {
                delay(1000)
                seconds++
                val m = seconds / 60
                val s = seconds % 60
                val current = binding.textStatus.text?.toString().orEmpty()
                val stage = current.substringBefore(" (경과")
                binding.textStatus.text = String.format("%s (경과 %02d:%02d)", stage, m, s)
            }
        }
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
