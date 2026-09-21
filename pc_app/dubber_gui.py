"""
Global Video Dubber - PC용 독립 실행 프로그램

내 PC에 있는 영상 파일을 선택하면 음성 인식 -> 번역 -> AI 더빙을 거쳐
지정한 언어로 더빙된 영상을 만들어 준다. 서버나 API 키 없이 전부 이 PC에서 처리된다.

실행: python dubber_gui.py
필요 패키지: pip install -r requirements.txt
"""

import os
import sys
import json
import queue
import shutil
import asyncio
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

# ---------------------------------------------------------------------------
# 언어 / 보이스 테이블 (번역 코드, 화면 표시명, 여성 보이스, 남성 보이스)
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

WORK_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_work")
OUTPUT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")

try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

_WHISPER_CACHE = {}


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


def ffmpeg_filter_path(path: str) -> str:
    """Escape a filesystem path for use inside an ffmpeg filtergraph argument.
    On Windows, drive-letter colons (C:\\...) and backslashes otherwise break
    the subtitles= filter's own option-parsing syntax."""
    escaped = os.path.abspath(path).replace("\\", "/").replace(":", "\\:")
    return escaped


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


def run_pipeline(source: str, lang_code: str, voice_name: str,
                  model_size: str, mode: str, log) -> str:
    os.makedirs(WORK_ROOT, exist_ok=True)
    os.makedirs(OUTPUT_ROOT, exist_ok=True)

    task_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    task_dir = os.path.join(WORK_ROOT, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        shutil.copy(source, input_path)

        log("오디오 추출 중...")
        audio_path = os.path.join(task_dir, "audio.wav")
        subprocess.run(
            [FFMPEG_EXE, "-y", "-i", input_path, "-vn", "-acodec", "pcm_s16le",
             "-ar", "16000", "-ac", "1", audio_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        has_original_audio = os.path.exists(audio_path) and os.path.getsize(audio_path) > 1000
        if not has_original_audio:
            duration = probe_duration_seconds(input_path)
            log("원본 음성이 없어 무음 트랙을 생성합니다...")
            subprocess.run(
                [FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                 "-t", str(duration), "-acodec", "pcm_s16le", audio_path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )

        log(f"음성 인식 중 (Whisper {model_size})...")
        model = get_whisper_model(model_size)
        segments, _ = model.transcribe(audio_path, beam_size=1, vad_filter=True)
        segment_list = list(segments)
        log(f"인식된 문장 수: {len(segment_list)}")

        output_path = os.path.join(task_dir, "output.mp4")

        if mode == "subtitle":
            log("번역 및 자막 생성 중...")
            srt_path = os.path.join(task_dir, "subtitles.srt")
            with open(srt_path, "w", encoding="utf-8") as f_srt:
                idx = 1
                for seg in segment_list:
                    t = seg.text.strip()
                    if not t:
                        continue
                    trans = translate_text(t, lang_code)
                    s_h, s_m, s_s = int(seg.start // 3600), int((seg.start % 3600) // 60), seg.start % 60
                    e_h, e_m, e_s = int(seg.end // 3600), int((seg.end % 3600) // 60), seg.end % 60
                    f_srt.write(
                        f"{idx}\n{s_h:02d}:{s_m:02d}:{s_s:06.3f}".replace(".", ",")
                        + f" --> {e_h:02d}:{e_m:02d}:{e_s:06.3f}".replace(".", ",")
                        + f"\n{trans}\n\n"
                    )
                    idx += 1

            log("자막 인코딩 중...")
            res = subprocess.run(
                [FFMPEG_EXE, "-y", "-i", input_path, "-vf", f"subtitles={ffmpeg_filter_path(srt_path)}",
                 "-c:v", "libx264", "-preset", "veryfast", "-c:a", "copy", output_path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if res.returncode != 0 or not os.path.exists(output_path):
                log("자막 굽기 실패, 화면에 안 보이는 소프트 자막으로 대체합니다 (플레이어에서 자막 트랙을 직접 켜야 합니다)...")
                subprocess.run(
                    [FFMPEG_EXE, "-y", "-i", input_path, "-i", srt_path,
                     "-c", "copy", "-c:s", "mov_text", output_path],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )

        else:  # dubbing
            log("번역 중...")
            spoken_lines = [translate_text(s.text.strip(), lang_code) for s in segment_list if s.text.strip()]
            full_text = " ".join(spoken_lines).strip()
            if not full_text:
                full_text = "Dubbing complete."

            log("AI 음성 합성 중 (edge-tts)...")
            temp_mp3 = os.path.join(task_dir, "tts.mp3")
            asyncio.run(edge_tts.Communicate(full_text, voice_name).save(temp_mp3))

            log("영상과 더빙 음성 합성 중...")
            if has_original_audio:
                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                    "-filter_complex",
                    "[0:a]volume=0.25[a0];[1:a]volume=1.3[a1];"
                    "[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[aout]",
                    "-map", "0:v:0", "-map", "[aout]",
                    "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", output_path,
                ]
            else:
                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c:v", "copy", "-c:a", "aac", output_path,
                ]
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if res.returncode != 0 or not os.path.exists(output_path):
                log("믹싱 실패, TTS 음성으로 대체합니다...")
                cmd_fallback = [
                    FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                    "-map", "0:v:0", "-map", "1:a:0",
                    "-c:v", "copy", "-c:a", "aac", output_path,
                ]
                subprocess.run(cmd_fallback, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        if not os.path.exists(output_path) or os.path.getsize(output_path) < 1000:
            raise RuntimeError("결과 영상을 생성하지 못했습니다.")

        final_name = f"result_{lang_code}_{task_id}.mp4"
        final_path = os.path.join(OUTPUT_ROOT, final_name)
        shutil.move(output_path, final_path)
        return final_path

    finally:
        shutil.rmtree(task_dir, ignore_errors=True)


class DubberApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("Global Video Dubber")
        root.geometry("560x560")
        root.resizable(False, False)

        self.log_queue: "queue.Queue[str]" = queue.Queue()
        self.selected_file = tk.StringVar(value="")
        self.mode_var = tk.StringVar(value="더빙")
        self.gender_var = tk.StringVar(value="여성")
        self.model_var = tk.StringVar(value="base")
        self.lang_display_to_row = {row[1]: row for row in LANGUAGES}

        pad = {"padx": 12, "pady": 6}

        ttk.Label(root, text="Global Video Dubber", font=("", 16, "bold")).pack(anchor="w", **pad)
        ttk.Label(root, text="내 PC의 영상 파일을 35개 언어로 더빙/자막 변환합니다 (전부 로컬 처리)",
                  wraplength=520).pack(anchor="w", padx=12)

        file_frame = ttk.LabelFrame(root, text="영상 소스")
        file_frame.pack(fill="x", **pad)
        ttk.Button(file_frame, text="영상 파일 선택", command=self.pick_file).pack(side="left", padx=8, pady=8)
        ttk.Label(file_frame, textvariable=self.selected_file, wraplength=380).pack(side="left", padx=4)

        opt_frame = ttk.LabelFrame(root, text="변환 옵션")
        opt_frame.pack(fill="x", **pad)

        row1 = ttk.Frame(opt_frame)
        row1.pack(fill="x", padx=8, pady=6)
        ttk.Label(row1, text="대상 언어").pack(side="left")
        self.lang_combo = ttk.Combobox(
            row1, values=[row[1] for row in LANGUAGES], state="readonly", width=20
        )
        self.lang_combo.set("한국어")
        self.lang_combo.pack(side="left", padx=8)

        ttk.Label(row1, text="모드").pack(side="left", padx=(16, 0))
        ttk.Combobox(row1, textvariable=self.mode_var, values=["더빙", "자막"],
                     state="readonly", width=8).pack(side="left", padx=8)

        row2 = ttk.Frame(opt_frame)
        row2.pack(fill="x", padx=8, pady=6)
        ttk.Label(row2, text="음성 성별 (더빙)").pack(side="left")
        ttk.Combobox(row2, textvariable=self.gender_var, values=["여성", "남성"],
                     state="readonly", width=8).pack(side="left", padx=8)

        ttk.Label(row2, text="인식 정확도").pack(side="left", padx=(16, 0))
        ttk.Combobox(row2, textvariable=self.model_var, values=WHISPER_MODELS,
                     state="readonly", width=8).pack(side="left", padx=8)

        self.start_btn = ttk.Button(root, text="변환 시작", command=self.start)
        self.start_btn.pack(pady=10)

        self.log_box = tk.Text(root, height=14, width=68, state="disabled")
        self.log_box.pack(padx=12, pady=6)

        self.open_btn = ttk.Button(root, text="결과 폴더 열기", command=self.open_output, state="disabled")
        self.open_btn.pack(pady=4)

        self.root.after(200, self.poll_log)

    def pick_file(self):
        path = filedialog.askopenfilename(
            title="영상 파일 선택",
            filetypes=[("Video files", "*.mp4 *.mov *.mkv *.avi *.webm"), ("All files", "*.*")],
        )
        if path:
            self.selected_file.set(path)

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
        file_path = self.selected_file.get().strip()
        if not file_path:
            messagebox.showwarning("입력 필요", "영상 파일을 선택해 주세요.")
            return

        lang_display = self.lang_combo.get()
        if lang_display not in self.lang_display_to_row:
            messagebox.showwarning("입력 필요", "대상 언어를 선택해 주세요.")
            return
        lang_code, _, voice_female, voice_male = self.lang_display_to_row[lang_display]
        voice_name = voice_female if self.gender_var.get() == "여성" else voice_male
        mode = "dubbing" if self.mode_var.get() == "더빙" else "subtitle"
        model_size = self.model_var.get()

        self.start_btn.configure(state="disabled")
        self.open_btn.configure(state="disabled")
        self.log_box.configure(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.configure(state="disabled")

        def worker():
            try:
                result_path = run_pipeline(file_path, lang_code, voice_name, model_size, mode, self.log)
                self.log(f"완료! 저장 위치: {result_path}")
                self.last_output_dir = os.path.dirname(result_path)
                self.root.after(0, lambda: self.open_btn.configure(state="normal"))
            except Exception as e:
                self.log(f"오류: {e}")
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
            messagebox.showinfo("결과 폴더", path)


if __name__ == "__main__":
    root = tk.Tk()
    app = DubberApp(root)
    root.mainloop()
