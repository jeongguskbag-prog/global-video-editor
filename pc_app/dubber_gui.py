"""
Global Video Dubber - PC용 독립 실행 프로그램

내 PC에 있는 영상 파일을 선택하면 음성 인식 -> 번역 -> AI 더빙을 거쳐
지정한 언어로 더빙된 영상을 만들어 준다. 서버나 API 키 없이 전부 이 PC에서 처리된다.
프로그램 화면 자체도 같은 언어 목록으로 번역해서 보여준다 (최초 1회 번역 후 로컬 캐싱).

실행: python dubber_gui.py
필요 패키지: pip install -r requirements.txt
"""

import os
import re
import sys
import json
import queue
import shutil
import asyncio
import tempfile
import subprocess
import threading
import urllib.request
import urllib.parse
from datetime import datetime

import tkinter as tk
from tkinter import ttk, filedialog, messagebox

import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
import imageio_ffmpeg
import yt_dlp

# ---------------------------------------------------------------------------
# 언어 / 보이스 테이블 (번역 코드, 화면 표시명(한국어), 여성 보이스, 남성 보이스)
# ---------------------------------------------------------------------------
LANGUAGES = [
    ("ko", "한국어", "ko-KR-SunHiNeural", "ko-KR-InJoonNeural"),
    ("en", "영어 (미국)", "en-US-AriaNeural", "en-US-GuyNeural"),
    ("en-GB", "영어 (영국)", "en-GB-SoniaNeural", "en-GB-RyanNeural"),
    ("ja", "일본어", "ja-JP-NanamiNeural", "ja-JP-KeitaNeural"),
    ("zh-CN", "중국어 (간체)", "zh-CN-XiaoxiaoNeural", "zh-CN-YunxiNeural"),
    ("zh-TW", "중국어 (번체)", "zh-TW-HsiaoChenNeural", "zh-TW-YunJheNeural"),
    ("es", "스페인어 (스페인)", "es-ES-ElviraNeural", "es-ES-AlvaroNeural"),
    ("es-MX", "스페인어 (멕시코)", "es-MX-DaliaNeural", "es-MX-JorgeNeural"),
    ("fr", "프랑스어", "fr-FR-DeniseNeural", "fr-FR-HenriNeural"),
    ("de", "독일어", "de-DE-KatjaNeural", "de-DE-ConradNeural"),
    ("it", "이탈리아어", "it-IT-ElsaNeural", "it-IT-DiegoNeural"),
    ("pt", "포르투갈어 (브라질)", "pt-BR-FranciscaNeural", "pt-BR-AntonioNeural"),
    ("pt-PT", "포르투갈어 (포르투갈)", "pt-PT-RaquelNeural", "pt-PT-DuarteNeural"),
    ("ru", "러시아어", "ru-RU-SvetlanaNeural", "ru-RU-DmitryNeural"),
    ("ar", "아랍어", "ar-SA-ZariyahNeural", "ar-SA-HamedNeural"),
    ("hi", "힌디어", "hi-IN-SwaraNeural", "hi-IN-MadhurNeural"),
    ("th", "태국어", "th-TH-PremwadeeNeural", "th-TH-NiwatNeural"),
    ("vi", "베트남어", "vi-VN-HoaiMyNeural", "vi-VN-NamMinhNeural"),
    ("id", "인도네시아어", "id-ID-GadisNeural", "id-ID-ArdiNeural"),
    ("ms", "말레이어", "ms-MY-YasminNeural", "ms-MY-OsmanNeural"),
    ("tr", "터키어", "tr-TR-EmelNeural", "tr-TR-AhmetNeural"),
    ("pl", "폴란드어", "pl-PL-ZofiaNeural", "pl-PL-MarekNeural"),
    ("nl", "네덜란드어", "nl-NL-ColetteNeural", "nl-NL-MaartenNeural"),
    ("sv", "스웨덴어", "sv-SE-SofieNeural", "sv-SE-MattiasNeural"),
    ("da", "덴마크어", "da-DK-ChristelNeural", "da-DK-JeppeNeural"),
    ("no", "노르웨이어", "nb-NO-PernilleNeural", "nb-NO-FinnNeural"),
    ("fi", "핀란드어", "fi-FI-SelmaNeural", "fi-FI-HarriNeural"),
    ("cs", "체코어", "cs-CZ-VlastaNeural", "cs-CZ-AntoninNeural"),
    ("el", "그리스어", "el-GR-AthinaNeural", "el-GR-NestorasNeural"),
    ("he", "히브리어", "he-IL-HilaNeural", "he-IL-AvriNeural"),
    ("uk", "우크라이나어", "uk-UA-PolinaNeural", "uk-UA-OstapNeural"),
    ("ro", "루마니아어", "ro-RO-AlinaNeural", "ro-RO-EmilNeural"),
    ("hu", "헝가리어", "hu-HU-NoemiNeural", "hu-HU-TamasNeural"),
    ("bg", "불가리아어", "bg-BG-KalinaNeural", "bg-BG-BorislavNeural"),
    ("sk", "슬로바키아어", "sk-SK-ViktoriaNeural", "sk-SK-LukasNeural"),
    ("ta", "타밀어", "ta-IN-PallaviNeural", "ta-IN-ValluvarNeural"),
    ("bn", "벵골어", "bn-IN-TanishaaNeural", "bn-IN-BashkarNeural"),
    ("fa", "페르시아어", "fa-IR-DilaraNeural", "fa-IR-FaridNeural"),
]

WHISPER_MODELS = ["tiny", "base", "small"]

# When frozen by PyInstaller (--onefile), __file__ resolves inside the
# temp extraction folder (%TEMP%\_MEIxxxxx on Windows), which gets wiped
# the moment the exe process exits -- anything saved there disappears when
# the program closes. sys.executable points at the actual, persistent exe
# file instead, so results survive after the app quits.
if getattr(sys, "frozen", False):
    BASE_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

WORK_ROOT = os.path.join(tempfile.gettempdir(), "GlobalVideoDubber_work")
OUTPUT_ROOT = os.path.join(BASE_DIR, "output")
LOCALE_CACHE_DIR = os.path.join(BASE_DIR, "locales")
PREFS_PATH = os.path.join(BASE_DIR, "prefs.json")

try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

_WHISPER_CACHE = {}


# ---------------------------------------------------------------------------
# 프로그램 화면 문구 (한국어 원문). 대상 언어 목록과 동일한 38개 언어로
# 번역해서 보여준다 -- 최초 1회만 번역하고 결과는 locales/<code>.json에 캐싱한다.
# ---------------------------------------------------------------------------
UI_STRINGS_KO = {
    "app_title": "Global Video Dubber",
    "app_subtitle": "내 PC의 영상 파일을 다양한 언어로 더빙/자막 변환합니다 (전부 로컬 처리)",
    "label_ui_lang": "프로그램 언어",
    "frame_source": "영상 소스",
    "btn_pick_file": "영상 파일 선택",
    "no_file_selected": "선택된 파일 없음",
    "label_or_url": "또는 URL (유튜브·틱톡 등)",
    "ctx_cut": "잘라내기",
    "ctx_copy": "복사",
    "ctx_paste": "붙여넣기",
    "ctx_select_all": "전체 선택",
    "frame_options": "변환 옵션",
    "label_target_lang": "대상 언어",
    "label_convert_mode": "변환 방식",
    "check_subtitle": "자막",
    "check_dubbing": "더빙",
    "label_gender": "음성 성별 (더빙)",
    "gender_female": "여성",
    "gender_male": "남성",
    "label_accuracy": "인식 정확도",
    "btn_start": "변환 시작",
    "btn_open_output": "결과 폴더 열기",
    "dlg_title_warning": "입력 필요",
    "msg_need_source": "영상 파일을 선택하거나 URL을 입력해 주세요.",
    "msg_need_lang": "대상 언어를 선택해 주세요.",
    "msg_need_mode": "자막 또는 더빙 중 최소 하나를 선택해 주세요.",
    "dlg_title_pick_file": "영상 파일 선택",
    "dlg_title_output_folder": "결과 폴더",
    "log_translating_ui": "프로그램 언어 번역 중... (최초 1회만, 이후엔 저장된 결과를 바로 씁니다)",
    "log_downloading": "영상 다운로드 중...",
    "log_download_done": "다운로드 완료, 처리 시작...",
    "log_extract_audio": "오디오 추출 중...",
    "log_silent_track": "원본 음성이 없어 무음 트랙을 생성합니다...",
    "log_whisper": "음성 인식 중 (Whisper {model})...",
    "log_segments": "인식된 문장 수: {count}",
    "log_translating": "번역 중...",
    "log_tts": "AI 음성 합성 중 (edge-tts)...",
    "log_mixing": "영상과 더빙 음성 합성 중...",
    "log_mix_fail": "믹싱 실패, TTS 음성으로 대체합니다...",
    "log_subtitle_gen": "자막 생성 중...",
    "log_subtitle_encode": "자막 인코딩 중...",
    "log_subtitle_fail": "자막 굽기 실패, 화면에 안 보이는 소프트 자막으로 대체합니다 (플레이어에서 자막 트랙을 직접 켜야 합니다)...",
    "log_done": "완료! 저장 위치: {path}",
    "log_error": "오류: {error}",
    "err_no_mode": "자막 또는 더빙 중 최소 하나를 선택해야 합니다.",
    "err_download_fail": "영상 다운로드 실패: {error}",
    "err_no_downloaded_file": "다운로드된 영상 파일을 찾을 수 없습니다.",
    "err_no_output": "결과 영상을 생성하지 못했습니다.",
}
for _code, _ko_name, _f, _m in LANGUAGES:
    UI_STRINGS_KO[f"lang_{_code}"] = _ko_name

# 프로그램 언어 선택 목록에는 "한국어"를 맨 앞에 고정으로 추가 (항상 원문 그대로, 캐싱/번역 불필요)
UI_LANGUAGES = LANGUAGES

_PLACEHOLDER_RE = re.compile(r"\{[^{}]+\}")


def get_whisper_model(model_size: str) -> WhisperModel:
    if model_size not in _WHISPER_CACHE:
        _WHISPER_CACHE[model_size] = WhisperModel(model_size, device="cpu", compute_type="int8")
    return _WHISPER_CACHE[model_size]


def translate_text(text: str, target_code: str) -> str:
    if not text or len(text.strip()) < 1:
        return ""
    try:
        res = GoogleTranslator(source="auto", target=target_code).translate(text)
        if res and res.strip():
            return res.strip()
    except Exception:
        pass
    try:
        url = (
            "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto"
            f"&tl={target_code}&dt=t&q={urllib.parse.quote(text)}"
        )
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=8) as response:
            result = json.loads(response.read().decode("utf-8"))
            return "".join(part[0] for part in result[0] if part[0])
    except Exception:
        return text


def translate_preserving_placeholders(text: str, target_code: str) -> str:
    """Translate UI text that may contain {placeholder} tokens without
    letting the translator mangle the braces/content inside them."""
    placeholders = _PLACEHOLDER_RE.findall(text)
    if not placeholders:
        return translate_text(text, target_code)
    temp = text
    tokens = []
    for i, p in enumerate(placeholders):
        token = f"XPLACEHOLDER{i}X"
        tokens.append((token, p))
        temp = temp.replace(p, token, 1)
    translated = translate_text(temp, target_code)
    for token, original in tokens:
        translated = translated.replace(token, original)
    return translated


def get_ui_strings(lang_code: str, log=None) -> dict:
    """UI 문구를 lang_code로 번역해서 돌려준다. 캐시가 있으면 그대로 쓰고,
    없으면 번역 후 locales/<lang_code>.json에 저장해서 다음부터는 즉시 로드한다."""
    if lang_code == "ko":
        return UI_STRINGS_KO

    os.makedirs(LOCALE_CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(LOCALE_CACHE_DIR, f"{lang_code}.json")
    if os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                cached = json.load(f)
            if all(k in cached for k in UI_STRINGS_KO):
                return cached
        except Exception:
            pass

    if log:
        log(UI_STRINGS_KO["log_translating_ui"])

    translated = {}
    for key, ko_text in UI_STRINGS_KO.items():
        translated[key] = translate_preserving_placeholders(ko_text, lang_code) or ko_text

    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(translated, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
    return translated


def load_prefs() -> dict:
    try:
        with open(PREFS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_prefs(prefs: dict):
    try:
        with open(PREFS_PATH, "w", encoding="utf-8") as f:
            json.dump(prefs, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def probe_duration_seconds(path: str) -> float:
    try:
        out = subprocess.run(
            [FFMPEG_EXE, "-i", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for line in out.stderr.splitlines():
            line = line.strip()
            if line.startswith("Duration:"):
                ts = line.split("Duration:")[1].split(",")[0].strip()
                h, m, s = ts.split(":")
                return int(h) * 3600 + int(m) * 60 + float(s)
    except Exception:
        pass
    return 10.0


def download_video_url(url: str, task_dir: str, input_path: str, strings: dict, log):
    last_pct = {"value": -1}

    def progress_hook(d):
        if d.get("status") == "downloading":
            pct_str = d.get("_percent_str", "").strip().replace("%", "")
            try:
                pct = int(float(pct_str))
            except ValueError:
                return
            if pct != last_pct["value"] and pct % 10 == 0:
                last_pct["value"] = pct
                log(f"{strings['log_downloading']} {pct}%")
        elif d.get("status") == "finished":
            log(strings["log_download_done"])

    ydl_opts = {
        "outtmpl": os.path.join(task_dir, "downloaded.%(ext)s"),
        "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
        "merge_output_format": "mp4",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "ffmpeg_location": FFMPEG_EXE,
        "progress_hooks": [progress_hook],
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
    except Exception as e:
        raise RuntimeError(strings["err_download_fail"].format(error=e))

    downloaded = next(
        (f for f in os.listdir(task_dir) if f.startswith("downloaded.")), None
    )
    if not downloaded:
        raise RuntimeError(strings["err_no_downloaded_file"])
    shutil.move(os.path.join(task_dir, downloaded), input_path)


def run_pipeline(source: str, is_url: bool, lang_code: str, voice_name: str, model_size: str,
                  want_subtitle: bool, want_dubbing: bool, strings: dict, log) -> str:
    if not want_subtitle and not want_dubbing:
        raise RuntimeError(strings["err_no_mode"])

    os.makedirs(WORK_ROOT, exist_ok=True)
    os.makedirs(OUTPUT_ROOT, exist_ok=True)

    task_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    task_dir = os.path.join(WORK_ROOT, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        if is_url:
            log(strings["log_downloading"])
            download_video_url(source, task_dir, input_path, strings, log)
        else:
            shutil.copy(source, input_path)

        log(strings["log_extract_audio"])
        audio_path = os.path.join(task_dir, "audio.wav")
        subprocess.run(
            [FFMPEG_EXE, "-y", "-i", input_path, "-vn", "-acodec", "pcm_s16le",
             "-ar", "16000", "-ac", "1", audio_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        has_original_audio = os.path.exists(audio_path) and os.path.getsize(audio_path) > 1000
        if not has_original_audio:
            duration = probe_duration_seconds(input_path)
            log(strings["log_silent_track"])
            subprocess.run(
                [FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                 "-t", str(duration), "-acodec", "pcm_s16le", audio_path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )

        log(strings["log_whisper"].format(model=model_size))
        model = get_whisper_model(model_size)
        segments, _ = model.transcribe(audio_path, beam_size=1, vad_filter=True)
        segment_list = list(segments)
        log(strings["log_segments"].format(count=len(segment_list)))

        log(strings["log_translating"])
        translated = []  # (start, end, translated_text)
        for seg in segment_list:
            t = seg.text.strip()
            if not t:
                continue
            translated.append((seg.start, seg.end, translate_text(t, lang_code)))

        video_path = input_path

        if want_dubbing:
            full_text = " ".join(t for _, _, t in translated).strip() or "Dubbing complete."

            log(strings["log_tts"])
            temp_mp3 = os.path.join(task_dir, "tts.mp3")
            asyncio.run(edge_tts.Communicate(full_text, voice_name).save(temp_mp3))

            log(strings["log_mixing"])
            dubbed_path = os.path.join(task_dir, "dubbed.mp4")
            if has_original_audio:
                cmd = [
                    FFMPEG_EXE, "-y", "-i", video_path, "-i", temp_mp3,
                    "-filter_complex",
                    "[0:a]volume=0.25[a0];[1:a]volume=1.3[a1];"
                    "[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[aout]",
                    "-map", "0:v:0", "-map", "[aout]",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", dubbed_path,
                ]
            else:
                cmd = [
                    FFMPEG_EXE, "-y", "-i", video_path, "-i", temp_mp3,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c:v", "copy", "-c:a", "aac", dubbed_path,
                ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if res.returncode != 0 or not os.path.exists(dubbed_path):
                log(strings["log_mix_fail"])
                cmd_fallback = [
                    FFMPEG_EXE, "-y", "-i", video_path, "-i", temp_mp3,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c:v", "copy", "-c:a", "aac", dubbed_path,
                ]
                subprocess.run(cmd_fallback, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            video_path = dubbed_path

        if want_subtitle:
            log(strings["log_subtitle_gen"])
            srt_path = os.path.join(task_dir, "subtitles.srt")
            with open(srt_path, "w", encoding="utf-8") as f_srt:
                for idx, (start, end, trans) in enumerate(translated, start=1):
                    s_h, s_m, s_s = int(start // 3600), int((start % 3600) // 60), start % 60
                    e_h, e_m, e_s = int(end // 3600), int((end % 3600) // 60), end % 60
                    f_srt.write(
                        f"{idx}\n{s_h:02d}:{s_m:02d}:{s_s:06.3f}".replace(".", ",")
                        + f" --> {e_h:02d}:{e_m:02d}:{e_s:06.3f}".replace(".", ",")
                        + f"\n{trans}\n\n"
                    )

            log(strings["log_subtitle_encode"])
            srt_dir = os.path.dirname(srt_path)
            srt_name = os.path.basename(srt_path)
            output_path = os.path.join(task_dir, "output.mp4")
            res = subprocess.run(
                [FFMPEG_EXE, "-y", "-i", video_path, "-vf", f"subtitles={srt_name}",
                 "-c:v", "libx264", "-preset", "veryfast", "-c:a", "copy", output_path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=srt_dir,
            )
            if res.returncode != 0 or not os.path.exists(output_path):
                log(strings["log_subtitle_fail"])
                subprocess.run(
                    [FFMPEG_EXE, "-y", "-i", video_path, "-i", srt_path,
                     "-c", "copy", "-c:s", "mov_text", output_path],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
        else:
            output_path = video_path

        if not os.path.exists(output_path) or os.path.getsize(output_path) < 1000:
            raise RuntimeError(strings["err_no_output"])

        final_name = f"result_{lang_code}_{task_id}.mp4"
        final_path = os.path.join(OUTPUT_ROOT, final_name)
        shutil.move(output_path, final_path)
        return final_path

    finally:
        shutil.rmtree(task_dir, ignore_errors=True)


class DubberApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.geometry("560x640")
        root.resizable(False, False)

        self.log_queue: "queue.Queue[str]" = queue.Queue()
        self.file_path = ""
        self.selected_file = tk.StringVar(value="")
        self.url_var = tk.StringVar(value="")
        self.subtitle_var = tk.BooleanVar(value=False)
        self.dubbing_var = tk.BooleanVar(value=True)
        self.gender_var = tk.StringVar(value="")
        self.model_var = tk.StringVar(value="base")
        self.lang_display_to_row = {}

        self.prefs = load_prefs()
        self.ui_lang = self.prefs.get("ui_lang", "ko")
        self.strings = UI_STRINGS_KO  # 위젯 생성 전까지 임시로 한국어 사용

        self._build_widgets()
        self.apply_language(self.ui_lang, persist=False, show_translating_log=False)

        self.root.after(200, self.poll_log)

    def _build_widgets(self):
        pad = {"padx": 12, "pady": 6}

        self.title_label = ttk.Label(self.root, font=("", 16, "bold"))
        self.title_label.pack(anchor="w", **pad)
        self.subtitle_label = ttk.Label(self.root, wraplength=520)
        self.subtitle_label.pack(anchor="w", padx=12)

        ui_lang_row = ttk.Frame(self.root)
        ui_lang_row.pack(fill="x", padx=12, pady=(6, 0))
        self.ui_lang_label = ttk.Label(ui_lang_row)
        self.ui_lang_label.pack(side="left")
        self.ui_lang_combo = ttk.Combobox(
            ui_lang_row, values=[row[1] for row in UI_LANGUAGES], state="readonly", width=22
        )
        self.ui_lang_combo.pack(side="left", padx=8)
        self.ui_lang_combo.bind("<<ComboboxSelected>>", self.on_ui_lang_selected)

        self.file_frame = ttk.LabelFrame(self.root)
        self.file_frame.pack(fill="x", **pad)

        file_row = ttk.Frame(self.file_frame)
        file_row.pack(fill="x", padx=8, pady=(8, 2))
        self.pick_file_btn = ttk.Button(file_row, command=self.pick_file)
        self.pick_file_btn.pack(side="left")
        self.selected_file_label = ttk.Label(file_row, textvariable=self.selected_file, wraplength=380)
        self.selected_file_label.pack(side="left", padx=4)

        url_row = ttk.Frame(self.file_frame)
        url_row.pack(fill="x", padx=8, pady=(2, 8))
        self.url_label = ttk.Label(url_row)
        self.url_label.pack(side="left")
        self.url_entry = ttk.Entry(url_row, textvariable=self.url_var, width=42)
        self.url_entry.pack(side="left", padx=6)
        self.url_entry.bind("<Button-3>", lambda e: self.show_entry_context_menu(e, self.url_entry))

        self.opt_frame = ttk.LabelFrame(self.root)
        self.opt_frame.pack(fill="x", **pad)

        row1 = ttk.Frame(self.opt_frame)
        row1.pack(fill="x", padx=8, pady=6)
        self.target_lang_label = ttk.Label(row1)
        self.target_lang_label.pack(side="left")
        self.lang_combo = ttk.Combobox(row1, state="readonly", width=20)
        self.lang_combo.pack(side="left", padx=8)

        self.convert_mode_label = ttk.Label(row1)
        self.convert_mode_label.pack(side="left", padx=(16, 0))
        self.subtitle_check = ttk.Checkbutton(row1, variable=self.subtitle_var)
        self.subtitle_check.pack(side="left", padx=(8, 0))
        self.dubbing_check = ttk.Checkbutton(row1, variable=self.dubbing_var)
        self.dubbing_check.pack(side="left", padx=(4, 0))

        row2 = ttk.Frame(self.opt_frame)
        row2.pack(fill="x", padx=8, pady=6)
        self.gender_label = ttk.Label(row2)
        self.gender_label.pack(side="left")
        self.gender_combo = ttk.Combobox(row2, textvariable=self.gender_var, state="readonly", width=8)
        self.gender_combo.pack(side="left", padx=8)

        self.accuracy_label = ttk.Label(row2)
        self.accuracy_label.pack(side="left", padx=(16, 0))
        ttk.Combobox(row2, textvariable=self.model_var, values=WHISPER_MODELS,
                     state="readonly", width=8).pack(side="left", padx=8)

        self.start_btn = ttk.Button(self.root, command=self.start)
        self.start_btn.pack(pady=10)

        self.log_box = tk.Text(self.root, height=14, width=68, state="disabled")
        self.log_box.pack(padx=12, pady=6)

        self.open_btn = ttk.Button(self.root, command=self.open_output, state="disabled")
        self.open_btn.pack(pady=4)

    def on_ui_lang_selected(self, _event=None):
        display = self.ui_lang_combo.get()
        row = next((r for r in UI_LANGUAGES if r[1] == display or
                    self.strings.get(f"lang_{r[0]}") == display), None)
        if row:
            self.apply_language(row[0])

    def apply_language(self, lang_code: str, persist: bool = True, show_translating_log: bool = True):
        if show_translating_log and lang_code != "ko":
            # 캐시가 없으면 번역에 시간이 좀 걸릴 수 있어 로그창에 진행 상황을 띄운다.
            self.log_box.configure(state="normal")
            self.log_box.delete("1.0", "end")
            self.log_box.configure(state="disabled")

        strings = get_ui_strings(lang_code, log=self.log if show_translating_log else None)
        self.strings = strings
        self.ui_lang = lang_code

        self.root.title(strings["app_title"])
        self.title_label.configure(text=strings["app_title"])
        self.subtitle_label.configure(text=strings["app_subtitle"])
        self.ui_lang_label.configure(text=strings["label_ui_lang"])
        self.file_frame.configure(text=strings["frame_source"])
        self.pick_file_btn.configure(text=strings["btn_pick_file"])
        if not self.file_path:
            self.selected_file.set(strings["no_file_selected"])
        self.url_label.configure(text=strings["label_or_url"])
        self.opt_frame.configure(text=strings["frame_options"])
        self.target_lang_label.configure(text=strings["label_target_lang"])
        self.convert_mode_label.configure(text=strings["label_convert_mode"])
        self.subtitle_check.configure(text=strings["check_subtitle"])
        self.dubbing_check.configure(text=strings["check_dubbing"])
        self.gender_label.configure(text=strings["label_gender"])
        self.accuracy_label.configure(text=strings["label_accuracy"])
        self.start_btn.configure(text=strings["btn_start"])
        self.open_btn.configure(text=strings["btn_open_output"])

        # 대상 언어 콤보박스 표시명 갱신 (선택값 유지)
        prev_code = None
        if self.lang_display_to_row:
            prev_display = self.lang_combo.get()
            prev_row = self.lang_display_to_row.get(prev_display)
            prev_code = prev_row[0] if prev_row else None
        display_names = [strings.get(f"lang_{code}", name) for code, name, _f, _m in LANGUAGES]
        self.lang_display_to_row = {
            strings.get(f"lang_{code}", name): (code, name, f, m)
            for code, name, f, m in LANGUAGES
        }
        self.lang_combo.configure(values=display_names)
        target_code = prev_code or "ko"
        target_display = next(
            (d for d, row in self.lang_display_to_row.items() if row[0] == target_code),
            display_names[0],
        )
        self.lang_combo.set(target_display)

        # 성별 콤보박스 표시명 갱신 (선택값 유지)
        prev_gender_is_male = self.gender_var.get() == UI_STRINGS_KO["gender_male"]
        self.gender_combo.configure(values=[strings["gender_female"], strings["gender_male"]])
        self.gender_var.set(strings["gender_male"] if prev_gender_is_male else strings["gender_female"])

        # 프로그램 언어 콤보박스 표시명 갱신 (한국어는 항상 "한국어" 그대로 표기)
        ui_lang_names = [
            strings.get(f"lang_{code}", name) if code != "ko" else "한국어"
            for code, name, _f, _m in UI_LANGUAGES
        ]
        self.ui_lang_combo.configure(values=ui_lang_names)
        current_ui_display = next(
            (n for n, (code, *_r) in zip(ui_lang_names, UI_LANGUAGES) if code == lang_code),
            ui_lang_names[0],
        )
        self.ui_lang_combo.set(current_ui_display)

        if persist:
            self.prefs["ui_lang"] = lang_code
            save_prefs(self.prefs)

    def show_entry_context_menu(self, event, widget):
        strings = self.strings
        menu = tk.Menu(widget, tearoff=0)
        menu.add_command(label=strings["ctx_cut"], command=lambda: widget.event_generate("<<Cut>>"))
        menu.add_command(label=strings["ctx_copy"], command=lambda: widget.event_generate("<<Copy>>"))
        menu.add_command(label=strings["ctx_paste"], command=lambda: widget.event_generate("<<Paste>>"))
        menu.add_separator()
        menu.add_command(label=strings["ctx_select_all"], command=lambda: widget.select_range(0, tk.END))
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def pick_file(self):
        path = filedialog.askopenfilename(
            title=self.strings["dlg_title_pick_file"],
            filetypes=[("Video files", "*.mp4 *.mov *.mkv *.avi *.webm"), ("All files", "*.*")],
        )
        if path:
            self.file_path = path
            self.selected_file.set(path)
            self.url_var.set("")

    def log(self, message: str):
        self.log_queue.put(message)

    def poll_log(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                self.log_box.configure(state="normal")
                self.log_box.insert("end", msg + "\n")
                self.log_box.see("end")
                self.log_box.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(200, self.poll_log)

    def start(self):
        strings = self.strings
        url = self.url_var.get().strip()
        file_path = self.file_path
        if url:
            source = url
            is_url = True
        elif file_path:
            source = file_path
            is_url = False
        else:
            messagebox.showwarning(strings["dlg_title_warning"], strings["msg_need_source"])
            return

        lang_display = self.lang_combo.get()
        if lang_display not in self.lang_display_to_row:
            messagebox.showwarning(strings["dlg_title_warning"], strings["msg_need_lang"])
            return
        lang_code, _, voice_female, voice_male = self.lang_display_to_row[lang_display]
        voice_name = voice_female if self.gender_var.get() == strings["gender_female"] else voice_male
        want_subtitle = self.subtitle_var.get()
        want_dubbing = self.dubbing_var.get()
        if not want_subtitle and not want_dubbing:
            messagebox.showwarning(strings["dlg_title_warning"], strings["msg_need_mode"])
            return
        model_size = self.model_var.get()

        self.start_btn.configure(state="disabled")
        self.open_btn.configure(state="disabled")
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.configure(state="disabled")

        def worker():
            try:
                result_path = run_pipeline(
                    source, is_url, lang_code, voice_name, model_size,
                    want_subtitle, want_dubbing, strings, self.log,
                )
                self.log(strings["log_done"].format(path=result_path))
                self.last_output_dir = os.path.dirname(result_path)
                self.root.after(0, lambda: self.open_btn.configure(state="normal"))
            except Exception as e:
                self.log(strings["log_error"].format(error=e))
            finally:
                self.root.after(0, lambda: self.start_btn.configure(state="normal"))

        threading.Thread(target=worker, daemon=True).start()

    def open_output(self):
        path = getattr(self, "last_output_dir", OUTPUT_ROOT)
        try:
            if sys.platform.startswith("win"):
                os.startfile(path)  # noqa: F821 (Windows only)
            elif sys.platform == "darwin":
                subprocess.Popen(["open", path])
            else:
                subprocess.Popen(["xdg-open", path])
        except Exception:
            messagebox.showinfo(self.strings["dlg_title_output_folder"], path)


if __name__ == "__main__":
    root = tk.Tk()
    app = DubberApp(root)
    root.mainloop()
