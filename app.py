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
from fastapi.responses import FileResponse, JSONResponse
import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
import yt_dlp
import imageio_ffmpeg

app = FastAPI(title="AI Global Video Editor Studio")

WORK_DIR = "/tmp/workspace"
os.makedirs(WORK_DIR, exist_ok=True)

# -------------------------------------------------------------------------
# 1. FFmpeg 실행 파일 경로 탐색
# -------------------------------------------------------------------------
try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

# -------------------------------------------------------------------------
# 2. 전역 Whisper 인스턴스 (512MB RAM 초경량 메모리 최적화)
# -------------------------------------------------------------------------
GLOBAL_WHISPER = None

def get_whisper_model():
    global GLOBAL_WHISPER
    if GLOBAL_WHISPER is None:
        GLOBAL_WHISPER = WhisperModel("tiny", device="cpu", compute_type="int8", cpu_threads=1)
    return GLOBAL_WHISPER

# -------------------------------------------------------------------------
# 3. Rate Limit 및 동시성 제어 (Render 무료 티어 OOM 방지)
# -------------------------------------------------------------------------
RATE_LIMIT_PER_MINUTE = 10
CLIENT_REQUEST_LOG = defaultdict(list)
RENDER_SEMAPHORE = asyncio.Semaphore(1)

def is_rate_limited(client_ip: str) -> bool:
    now = time.time()
    timestamps = CLIENT_REQUEST_LOG[client_ip]
    CLIENT_REQUEST_LOG[client_ip] = [t for t in timestamps if now - t < 60.0]
    if len(CLIENT_REQUEST_LOG[client_ip]) >= RATE_LIMIT_PER_MINUTE:
        return True
    CLIENT_REQUEST_LOG[client_ip].append(now)
    return False

# -------------------------------------------------------------------------
# 4. 정품 라이선스 DB
# -------------------------------------------------------------------------
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

# -------------------------------------------------------------------------
# 5. 유튜브/쇼츠/릴스/틱톡 봇 차단 우회 다운로더
# -------------------------------------------------------------------------
def download_video_stream(url: str, output_path: str) -> bool:
    ydl_opts = {
        'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'outtmpl': output_path,
        'quiet': True,
        'no_warnings': True,
        'overwrites': True,
        'nocheckcertificate': True,
        'socket_timeout': 30,
        'max_filesize': 250 * 1024 * 1024,
        'http_headers': {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
            'Accept-Language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
            'Sec-Fetch-Mode': 'navigate'
        },
        'extractor_args': {
            'youtube': {
                'player_client': ['android', 'web']
            }
        }
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
        return os.path.exists(output_path) and os.path.getsize(output_path) > 1024
    except Exception as e:
        print(f"다운로드 실패 예외: {e}")
        return False

# -------------------------------------------------------------------------
# 6. 헬스 체크
# -------------------------------------------------------------------------
@app.get("/")
def root():
    return {"status": "ok", "service": "AI Global Video Editor Running"}

# -------------------------------------------------------------------------
# 7. 메인 렌더링 엔드포인트
# -------------------------------------------------------------------------
@app.post("/api/render_file")
@app.post("/api/render_file/")
@app.post("/render_file")
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
    # Rate Limit
    client_ip = request.client.host if request.client else "127.0.0.1"
    if is_rate_limited(client_ip):
        return JSONResponse(status_code=429, content={"error": "요청이 너무 많습니다. 1분 후 다시 시도해 주세요."})

    # 라이선스 검증
    if license_key not in LICENSES:
        return JSONResponse(status_code=403, content={"error": "유효하지 않은 라이선스 키입니다."})

    lic = LICENSES[license_key]
    if license_key != "DEV-MASTER-FREEPASS":
        if lic["device"] is None:
            lic["device"] = device_id
        elif lic["device"] != device_id:
            return JSONResponse(status_code=403, content={"error": "이미 다른 기기에 등록된 라이선스입니다."})

    task_id = str(os.urandom(6).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        # 파일 또는 웹 링크 다운로드
        if file and file.filename:
            with open(input_path, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)
        elif video_url and len(video_url.strip()) >= 5:
            if not download_video_stream(video_url.strip(), input_path):
                return JSONResponse(status_code=400, content={"error": "영상 다운로드에 실패했습니다. 링크를 확인하세요."})
        else:
            return JSONResponse(status_code=400, content={"error": "영상 파일이나 링크 중 하나를 입력해 주세요."})

        # Render 메모리 보호를 위한 큐 제어
        async with RENDER_SEMAPHORE:
            audio_path = os.path.join(task_dir, "audio.wav")
            
            # 오디오 추출 (16kHz mono)
            cmd_audio = [
                FFMPEG_EXE, "-y", "-i", input_path,
                "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
                audio_path
            ]
            subprocess.run(cmd_audio, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # 무음 비디오 대비 가상 오디오 폴백
            if not os.path.exists(audio_path) or os.path.getsize(audio_path) < 100:
                cmd_silent = [
                    FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", "10", "-acodec", "pcm_s16le", audio_path
                ]
                subprocess.run(cmd_silent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # STT 음성 인식 실행
            segment_list = []
            try:
                model = get_whisper_model()
                segments, _ = model.transcribe(audio_path, beam_size=1, vad_filter=False)
                segment_list = list(segments)
            except Exception as e:
                print(f"Whisper 예외: {e}")

            output_path = os.path.join(task_dir, "output.mp4")

            if mode in ["subtitle", "dynamic_subtitle"]:
                # ASS 자막 파일 생성
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
                # 더빙 모드 (Edge-TTS + BGM 감쇠 믹싱)
                target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
                voice_name = target_info["female"] if gender == "female" else target_info["male"]

                full_text = " ".join([translate_text(s.text.strip(), target_lang) for s in segment_list if s.text.strip()])
                if not full_text:
                    full_text = "대사가 감지되지 않았습니다."

                temp_mp3 = os.path.join(task_dir, "tts.mp3")
                communicate = edge_tts.Communicate(full_text, voice_name)
                await communicate.save(temp_mp3)

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
                return JSONResponse(status_code=500, content={"error": "렌더링 파일 생성에 실패했습니다."})

            return FileResponse(output_path, media_type="video/mp4", filename=f"result_{target_lang}.mp4")

    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"서버 처리 오류: {str(e)}"})

    finally:
        shutil.rmtree(task_dir, ignore_errors=True)
        gc.collect()
