import os
import gc
import time
import asyncio
import urllib.request
import urllib.parse
import json
import shutil
import subprocess
from collections import defaultdict
from fastapi import FastAPI, UploadFile, File, Form, Request
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse
import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
import yt_dlp
import imageio_ffmpeg

app = FastAPI(title="AI Global Video Editor Studio")

WORK_DIR = "/tmp/workspace"
os.makedirs(WORK_DIR, exist_ok=True)

# 1. FFmpeg 바이너리 경로 탐색
try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

# 2. 전역 Whisper 모델 1회만 경량 로드 (메모리 폭발 방지)
# cpu_threads=1, compute_type="int8"로 512MB RAM 환경 맞춤
GLOBAL_WHISPER = None

def get_whisper_model():
    global GLOBAL_WHISPER
    if GLOBAL_WHISPER is None:
        GLOBAL_WHISPER = WhisperModel("tiny", device="cpu", compute_type="int8", cpu_threads=1)
    return GLOBAL_WHISPER

# 3. 동시 처리 1개 제한 (Render 무료 플랜 메모리 보호)
RENDER_SEMAPHORE = asyncio.Semaphore(1)

# 4. 기기 귀속 보안 라이선스 DB
LICENSES = {
    "DEV-MASTER-FREEPASS": {"owner": "Developer", "device": None},
    "VIP-KEY-001": {"owner": "User1", "device": None},
    "VIP-KEY-002": {"owner": "User2", "device": None},
    "VIP-KEY-003": {"owner": "User3", "device": None}
}

LANG_OPTIONS = {
    "en": {"female": "en-US-AriaNeural", "male": "en-US-GuyNeural"},
    "zh": {"female": "zh-CN-XiaoxiaoNeural", "male": "zh-CN-YunjianNeural"},
    "es": {"female": "es-ES-ElviraNeural", "male": "es-ES-AlvaroNeural"},
    "ja": {"female": "ja-JP-NanamiNeural", "male": "ja-JP-KeitaNeural"},
    "de": {"female": "de-DE-KatjaNeural", "male": "de-DE-ConradNeural"},
    "fr": {"female": "fr-FR-DeniseNeural", "male": "fr-FR-HenriNeural"},
    "vi": {"female": "vi-VN-HoaiMyNeural", "male": "vi-VN-NamMinhNeural"},
    "ko": {"female": "ko-KR-SunHiNeural", "male": "ko-KR-InJoonNeural"}
}

def format_ass_time(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    centis = int((seconds - int(seconds)) * 100)
    return f"{hours:d}:{minutes:02d}:{secs:02d}.{centis:02d}"

def translate_text(text: str, target_code: str) -> str:
    if not text or len(text.strip()) < 1:
        return ""
    try:
        res = GoogleTranslator(source='auto', target=target_code).translate(text)
        if res and res.strip():
            return res.strip()
    except Exception:
        pass
    try:
        url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl={target_code}&dt=t&q={urllib.parse.quote(text)}"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=4) as response:
            result = json.loads(response.read().decode('utf-8'))
            return "".join([part[0] for part in result[0] if part[0]])
    except Exception:
        return text

def download_video_stream(url: str, output_path: str) -> bool:
    ydl_opts = {
        'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'outtmpl': output_path,
        'quiet': True,
        'no_warnings': True,
        'overwrites': True,
        'socket_timeout': 20
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
        return os.path.exists(output_path) and os.path.getsize(output_path) > 1024
    except Exception:
        return False

@app.get("/")
def root():
    return {"status": "ok", "service": "AI Global Video Editor Running"}

@app.post("/api/render_file")
async def process_video_file(
    request: Request,
    file: UploadFile = File(None),
    video_url: str = Form(None),
    target_lang: str = Form("ko"),
    gender: str = Form("female"),
    mode: str = Form("dynamic_subtitle"),
    license_key: str = Form("DEV-MASTER-FREEPASS"),
    device_id: str = Form("UNKNOWN_DEVICE")
):
    # 라이선스 검증
    if license_key not in LICENSES:
        return JSONResponse(status_code=403, content={"error": "유효하지 않은 라이선스 키입니다."})

    task_id = str(os.urandom(6).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        if file and file.filename:
            with open(input_path, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)
        elif video_url and len(video_url.strip()) >= 5:
            if not download_video_stream(video_url.strip(), input_path):
                return JSONResponse(status_code=400, content={"error": "영상 다운로드에 실패했습니다."})
        else:
            return JSONResponse(status_code=400, content={"error": "파일이나 링크를 제공해 주세요."})

        async with RENDER_SEMAPHORE:
            audio_path = os.path.join(task_dir, "audio.wav")
            # FFmpeg 오디오 16kHz 모노 추출 (초경량)
            cmd_audio = [
                FFMPEG_EXE, "-y", "-i", input_path,
                "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
                audio_path
            ]
            subprocess.run(cmd_audio, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # 무음 비디오 대비
            if not os.path.exists(audio_path) or os.path.getsize(audio_path) < 100:
                cmd_silent = [
                    FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", "10", "-acodec", "pcm_s16le", audio_path
                ]
                subprocess.run(cmd_silent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # STT 실행 (단일 인스턴스)
            model = get_whisper_model()
            segments, _ = model.transcribe(audio_path, beam_size=1, vad_filter=False)
            segment_list = list(segments)

            output_path = os.path.join(task_dir, "output.mp4")

            if mode in ["subtitle", "dynamic_subtitle"]:
                # ASS 자막 생성
                ass_path = os.path.join(task_dir, "subtitles.ass")
                with open(ass_path, "w", encoding="utf-8") as f_ass:
                    f_ass.write("""[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Pop,Arial,64,&H0000FFFF,&H00000000,&H00000000,&H80000000,-1,0,0,0,100,100,2,0,1,5,0,2,30,30,220,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""")
                    for seg in segment_list:
                        t = seg.text.strip()
                        if not t:
                            continue
                        trans = translate_text(t, target_lang)
                        st = format_ass_time(seg.start)
                        et = format_ass_time(seg.end)
                        f_ass.write(f"Dialogue: 0,{st},{et},Pop,,0,0,0,,{trans}\n")

                # FFmpeg 자막 하드코딩 렌더링
                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path,
                    "-vf", f"ass={ass_path}",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy",
                    output_path
                ]
                res_burn = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res_burn.returncode != 0:
                    shutil.copy(input_path, output_path)

            else:
                # 더빙 모드
                target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
                voice_name = target_info["female"] if gender == "female" else target_info["male"]

                full_text = " ".join([translate_text(s.text.strip(), target_lang) for s in segment_list if s.text.strip()])
                if not full_text:
                    full_text = "대사가 감지되지 않았습니다."

                temp_mp3 = os.path.join(task_dir, "tts.mp3")
                communicate = edge_tts.Communicate(full_text, voice_name)
                await communicate.save(temp_mp3)

                # BGM 보존 믹싱
                filter_complex = "[0:a]volume=0.2[a0];[1:a]volume=1.2[a1];[a0][a1]amix=inputs=2:duration=first[aout]"
                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                    "-filter_complex", filter_complex,
                    "-map", "0:v", "-map", "[aout]",
                    "-c:v", "copy", "-c:a", "aac",
                    output_path
                ]
                res_mix = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res_mix.returncode != 0:
                    cmd_fallback = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                        "-map", "0:v", "-map", "1:a",
                        "-c:v", "copy", "-c:a", "aac",
                        output_path
                    ]
                    subprocess.run(cmd_fallback, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            if not os.path.exists(output_path) or os.path.getsize(output_path) < 1000:
                return JSONResponse(status_code=500, content={"error": "렌더링 파일 생성 실패"})

            return FileResponse(output_path, media_type="video/mp4", filename=f"result_{target_lang}.mp4")

    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"서버 상세 오류: {str(e)}"})

    finally:
        shutil.rmtree(task_dir, ignore_errors=True)
        gc.collect()
