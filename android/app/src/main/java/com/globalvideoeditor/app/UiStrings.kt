package com.globalvideoeditor.app

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * App UI text, translated into the same language list used for dubbing/subtitles.
 * Korean is the source of truth; other languages are translated once via
 * LocalDubber.translateText() (the same free Google Translate endpoint the
 * rest of the app already relies on) and cached to disk so switching back to
 * an already-used language is instant and works offline afterwards.
 */
object UiStrings {

    // languageCodes list in MainActivity: ko, en, zh, es, ja, de, fr, vi
    private val FIXED: Map<String, String> = linkedMapOf(
        "app_subtitle" to "AI 자막 / 더빙 자동 변환",
        "label_license" to "라이선스 키",
        "label_ui_lang" to "프로그램 언어",
        "label_source" to "영상 소스",
        "btn_pick_video" to "갤러리에서 영상 선택",
        "no_file_selected" to "선택된 파일 없음",
        "label_or_url" to "또는 URL (유튜브·틱톡 등)",
        "label_options" to "변환 옵션",
        "label_target_lang" to "대상 언어",
        "label_convert_mode" to "변환 방식 (복수 선택 가능)",
        "check_subtitle" to "자막",
        "check_dubbing" to "더빙",
        "label_gender" to "음성 성별 (더빙 모드)",
        "gender_female" to "여성",
        "gender_male" to "남성",
        "btn_render" to "렌더링 시작",
        "btn_play" to "재생",
        "btn_share" to "공유",
        "share_chooser_title" to "공유하기",
        "toast_need_license" to "라이선스 키를 입력해 주세요",
        "toast_need_source" to "영상 파일을 선택하거나 URL을 입력해 주세요",
        "toast_need_mode" to "자막 또는 더빙 중 최소 하나를 선택해 주세요",
        "toast_no_player" to "영상을 재생할 앱을 찾을 수 없습니다",
        "status_processing" to "처리 중...",
        "status_done_prefix" to "완료! 저장 위치: ",
        "status_error_prefix" to "오류: ",
        "status_unknown_error_prefix" to "알 수 없는 오류: ",
        "log_license_check" to "라이선스 확인 중...",
        "log_loading_video" to "영상 불러오는 중...",
        "log_downloading" to "영상 다운로드 중...",
        "log_download_done" to "다운로드 완료, 처리 시작...",
        "log_extract_audio" to "오디오 추출 중...",
        "log_whisper" to "음성 인식 중 (온디바이스 Whisper)...",
        "log_segments_prefix" to "인식된 문장 수: ",
        "log_translating" to "번역 중...",
        "log_tts" to "AI 음성 합성 중 (온디바이스 TTS)...",
        "log_mixing" to "영상과 더빙 음성 합성 중...",
        "log_subtitle_gen" to "자막 생성 중...",
        "log_subtitle_encode" to "자막 인코딩 중...",
        "log_model_download" to "음성 인식 모델 다운로드 중 (최초 1회, 약 140MB)...",
        "log_model_download_pct_prefix" to "모델 다운로드 중... ",
        "err_pipeline_mode" to "자막 또는 더빙 중 최소 하나를 선택해야 합니다",
        "err_pipeline_source" to "영상 파일을 선택하거나 URL을 입력해야 합니다",
        "err_tts_lang" to "이 언어의 음성 데이터가 폰에 설치되어 있지 않습니다 (설정 > 일반 > 언어 및 입력 > 텍스트 음성 변환에서 설치 필요)",
        "err_open_video" to "영상 파일을 열 수 없습니다",
        "err_download_fail_prefix" to "영상 다운로드 실패: ",
        "err_no_downloaded_file" to "다운로드된 영상 파일을 찾을 수 없습니다",
        "err_model_download_fail_prefix" to "모델 다운로드 실패 (HTTP ",
        "err_tts_init" to "TTS 엔진 초기화 실패",
        "err_tts_synth" to "TTS 합성 실패",
        "err_tts_request" to "TTS 요청 실패",
        "err_ytdl_init_prefix" to "다운로드 엔진 초기화 실패: ",
        "elapsed_open" to " (경과 ",
        // 대상(더빙) 언어 스피너 전용 (languageCodes, 8개) -- zh는 대상 언어에서만 쓰는 코드
        "lang_zh" to "中文",
        // 프로그램 UI 언어 선택지 (UI_LANGUAGE_CODES, 38개) -- 각 언어의 고유 표기명
        "lang_ko" to "한국어",
        "lang_en" to "English",
        "lang_en-GB" to "English (UK)",
        "lang_ja" to "日本語",
        "lang_zh-CN" to "简体中文",
        "lang_zh-TW" to "繁體中文",
        "lang_es" to "Español",
        "lang_es-MX" to "Español (México)",
        "lang_fr" to "Français",
        "lang_de" to "Deutsch",
        "lang_it" to "Italiano",
        "lang_pt" to "Português (Brasil)",
        "lang_pt-PT" to "Português (Portugal)",
        "lang_ru" to "Русский",
        "lang_ar" to "العربية",
        "lang_hi" to "हिन्दी",
        "lang_th" to "ไทย",
        "lang_vi" to "Tiếng Việt",
        "lang_id" to "Bahasa Indonesia",
        "lang_ms" to "Bahasa Melayu",
        "lang_tr" to "Türkçe",
        "lang_pl" to "Polski",
        "lang_nl" to "Nederlands",
        "lang_sv" to "Svenska",
        "lang_da" to "Dansk",
        "lang_no" to "Norsk",
        "lang_fi" to "Suomi",
        "lang_cs" to "Čeština",
        "lang_el" to "Ελληνικά",
        "lang_he" to "עברית",
        "lang_uk" to "Українська",
        "lang_ro" to "Română",
        "lang_hu" to "Magyar",
        "lang_bg" to "Български",
        "lang_sk" to "Slovenčina",
        "lang_ta" to "தமிழ்",
        "lang_bn" to "বাংলা",
        "lang_fa" to "فارسی",
    )

    // 프로그램 언어(UI) 선택지 -- PC 앱의 LANGUAGES 목록과 동일한 38개 코드/순서
    val UI_LANGUAGE_CODES: List<String> = listOf(
        "ko", "en", "en-GB", "ja", "zh-CN", "zh-TW", "es", "es-MX", "fr", "de",
        "it", "pt", "pt-PT", "ru", "ar", "hi", "th", "vi", "id", "ms",
        "tr", "pl", "nl", "sv", "da", "no", "fi", "cs", "el", "he",
        "uk", "ro", "hu", "bg", "sk", "ta", "bn", "fa",
    )

    val KO: Map<String, String> = FIXED

    private val cache = mutableMapOf<String, Map<String, String>>()

    suspend fun get(context: Context, langCode: String, log: ((String) -> Unit)? = null): Map<String, String> {
        if (langCode == "ko") return KO
        cache[langCode]?.let { return it }

        val cacheFile = File(File(context.filesDir, "locales").apply { mkdirs() }, "$langCode.json")
        if (cacheFile.exists()) {
            try {
                val obj = JSONObject(cacheFile.readText())
                if (KO.keys.all { obj.has(it) }) {
                    val map = KO.keys.associateWith { obj.getString(it) }
                    cache[langCode] = map
                    return map
                }
            } catch (e: Exception) {
                // fall through and re-translate
            }
        }

        log?.invoke(KO.getValue("log_translating"))
        val translated = LinkedHashMap<String, String>()
        for ((key, ko) in KO) {
            // lang_* entries are each language's own native name (e.g. "Español", "日本語")
            // and are shown as-is in language pickers, never translated into the current UI language.
            translated[key] = if (key.startsWith("lang_")) ko else LocalDubber.translateText(ko, langCode).ifBlank { ko }
        }
        try {
            val obj = JSONObject()
            for ((k, v) in translated) obj.put(k, v)
            cacheFile.writeText(obj.toString())
        } catch (e: Exception) {
            // cache write failure is non-fatal; just re-translates next time
        }
        cache[langCode] = translated
        return translated
    }
}
