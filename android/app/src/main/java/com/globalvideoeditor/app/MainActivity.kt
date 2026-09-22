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
import androidx.lifecycle.lifecycleScope
import com.globalvideoeditor.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {

    companion object {
        private const val SERVER_URL = "https://global-video-editor.onrender.com"
        // 개인용 빌드: 기기 잠금이 없는 마스터 라이선스 키를 내장해서 입력창을 숨긴다.
        private const val EMBEDDED_LICENSE_KEY = "9b5c575413a0f84b94a4a9f1e3af2de2"
    }

    private lateinit var binding: ActivityMainBinding
    private val prefs by lazy { getSharedPreferences("gve_prefs", MODE_PRIVATE) }

    private var selectedVideoUri: Uri? = null
    private var selectedVideoName: String = "input.mp4"
    private var resultUri: Uri? = null
    private var elapsedTimerJob: Job? = null

    private var strings: Map<String, String> = UiStrings.KO
    private var uiLang: String = "ko"

    private val languageCodes = listOf("ko", "en", "zh", "es", "ja", "de", "fr", "vi")
    private val genderCodes = listOf("female", "male")

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
            binding.editVideoUrl.setText("")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.editLicenseKey.setText(EMBEDDED_LICENSE_KEY)
        binding.layoutLicenseKey.visibility = View.GONE

        binding.spinnerGender.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, listOf("", ""))

        val updateGenderEnabled = {
            val isDubbing = binding.checkDubbing.isChecked
            binding.spinnerGender.isEnabled = isDubbing
            binding.labelGender.alpha = if (isDubbing) 1f else 0.4f
            binding.spinnerGender.alpha = if (isDubbing) 1f else 0.4f
        }
        binding.checkDubbing.setOnCheckedChangeListener { _, _ -> updateGenderEnabled() }
        updateGenderEnabled()

        binding.btnPickVideo.setOnClickListener {
            pickVideoLauncher.launch(arrayOf("video/*"))
        }

        binding.btnRender.setOnClickListener { startRender() }

        binding.btnPlayResult.setOnClickListener { playResult() }
        binding.btnShareResult.setOnClickListener { shareResult() }

        binding.spinnerUiLang.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, UiStrings.UI_LANGUAGE_CODES)
        binding.spinnerUiLang.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val code = UiStrings.UI_LANGUAGE_CODES[position]
                if (code != uiLang) applyUiLanguage(code, persist = true)
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }

        val savedUiLang = prefs.getString("ui_lang", "ko") ?: "ko"
        applyUiLanguage(savedUiLang, persist = false)
    }

    private fun applyUiLanguage(langCode: String, persist: Boolean) {
        lifecycleScope.launch {
            val loaded = UiStrings.get(applicationContext, langCode) { msg ->
                runOnUiThread { binding.textStatus.text = msg }
            }
            strings = loaded
            uiLang = langCode
            applyStrings()
            if (persist) {
                prefs.edit().putString("ui_lang", langCode).apply()
            }
        }
    }

    private fun applyStrings() {
        val s = strings
        binding.textAppSubtitle.text = s.getValue("app_subtitle")
        binding.labelUiLang.text = s.getValue("label_ui_lang")
        binding.labelSource.text = s.getValue("label_source")
        binding.btnPickVideo.text = s.getValue("btn_pick_video")
        if (selectedVideoUri == null) {
            binding.textSelectedFile.text = s.getValue("no_file_selected")
        }
        binding.layoutVideoUrl.hint = s.getValue("label_or_url")
        binding.labelOptions.text = s.getValue("label_options")
        binding.labelTargetLang.text = s.getValue("label_target_lang")
        binding.labelConvertMode.text = s.getValue("label_convert_mode")
        binding.checkSubtitle.text = s.getValue("check_subtitle")
        binding.checkDubbing.text = s.getValue("check_dubbing")
        binding.labelGender.text = s.getValue("label_gender")
        binding.btnRender.text = s.getValue("btn_render")
        binding.btnPlayResult.text = s.getValue("btn_play")
        binding.btnShareResult.text = s.getValue("btn_share")

        val targetLangDisplay = languageCodes.map { s.getValue("lang_$it") }
        val prevTargetPos = binding.spinnerLanguage.selectedItemPosition.let { if (it < 0) 0 else it }
        binding.spinnerLanguage.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, targetLangDisplay)
        binding.spinnerLanguage.setSelection(prevTargetPos)

        val genderDisplay = listOf(s.getValue("gender_female"), s.getValue("gender_male"))
        val prevGenderPos = binding.spinnerGender.selectedItemPosition.let { if (it < 0) 0 else it }
        binding.spinnerGender.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, genderDisplay)
        binding.spinnerGender.setSelection(prevGenderPos)

        // 프로그램 언어 스피너: 각 언어를 고유 표기명(자국어 이름)으로 표시, 번역하지 않음
        val uiLangDisplay = UiStrings.UI_LANGUAGE_CODES.map { code -> s.getValue("lang_$code") }
        binding.spinnerUiLang.adapter =
            ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, uiLangDisplay)
        binding.spinnerUiLang.setSelection(UiStrings.UI_LANGUAGE_CODES.indexOf(uiLang).coerceAtLeast(0))
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
        val s = strings
        val licenseKey = EMBEDDED_LICENSE_KEY

        val urlText = binding.editVideoUrl.text?.toString()?.trim().orEmpty()
        val uri = selectedVideoUri
        if (urlText.isBlank() && uri == null) {
            toast(s.getValue("toast_need_source"))
            return
        }
        val wantSubtitle = binding.checkSubtitle.isChecked
        val wantDubbing = binding.checkDubbing.isChecked
        if (!wantSubtitle && !wantDubbing) {
            toast(s.getValue("toast_need_mode"))
            return
        }

        val langCode = languageCodes[binding.spinnerLanguage.selectedItemPosition]
        val genderCode = genderCodes[binding.spinnerGender.selectedItemPosition]
        val deviceId = androidDeviceId()

        setLoading(true, s.getValue("status_processing"))
        startElapsedTimer()

        lifecycleScope.launch {
            try {
                val result = LocalDubber.verifyLicenseAndRun(
                    context = applicationContext,
                    serverUrl = SERVER_URL,
                    licenseKey = licenseKey,
                    deviceId = deviceId,
                    videoUri = if (urlText.isBlank()) uri else null,
                    videoUrl = urlText.ifBlank { null },
                    videoName = selectedVideoName,
                    langCode = langCode,
                    genderCode = genderCode,
                    wantSubtitle = wantSubtitle,
                    wantDubbing = wantDubbing,
                    strings = s,
                    log = { message -> runOnUiThread { binding.textStatus.text = message } }
                )

                resultUri = result.uri
                setLoading(
                    false,
                    s.getValue("status_done_prefix") + result.displayName + s.getValue("status_saved_hint")
                )
                binding.layoutResultActions.visibility = View.VISIBLE

            } catch (e: LocalDubber.PipelineException) {
                setLoading(false, s.getValue("status_error_prefix") + e.message)
            } catch (e: Exception) {
                Log.e("GVE", "pipeline error", e)
                setLoading(false, s.getValue("status_unknown_error_prefix") + e.message)
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
        val elapsedOpen = strings.getValue("elapsed_open")
        elapsedTimerJob = lifecycleScope.launch {
            var seconds = 0
            while (true) {
                delay(1000)
                seconds++
                val m = seconds / 60
                val s = seconds % 60
                val current = binding.textStatus.text?.toString().orEmpty()
                val stage = current.substringBefore(elapsedOpen)
                binding.textStatus.text = String.format("%s%s%02d:%02d)", stage, elapsedOpen, m, s)
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
        val uri = resultUri ?: return
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/mp4")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: Exception) {
            toast(strings.getValue("toast_no_player"))
        }
    }

    private fun shareResult() {
        val uri = resultUri ?: return
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, strings.getValue("share_chooser_title")))
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }
}
