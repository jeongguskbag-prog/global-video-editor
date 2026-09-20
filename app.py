import os
import gc
import time
import asyncio
import urllib.request
import urllib.parse
import json
import shutil
import subprocess
import traceback
from collections import defaultdict
from fastapi import FastAPI, UploadFile, File, Form, Request
from fastapi.responses import FileResponse, JSONResponse
from starlette.background import BackgroundTask
import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
import imageio_ffmpeg

app = FastAPI(title="AI Global Video Editor Studio")

WORK_DIR = "/tmp/workspace"
os.makedirs(WORK_DIR, exist_ok=True)

try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

GLOBAL_WHISPER = None

def get_whisper_model():
    global GLOBAL_WHISPER
    if GLOBAL_WHISPER is None:
        GLOBAL_WHISPER = WhisperModel("tiny", device="cpu", compute_type="int8", cpu_threads=1, download_root="/tmp/whisper_model")
    return GLOBAL_WHISPER

def probe_duration_seconds(path: str) -> float:
    try:
        out = subprocess.run([FFMPEG_EXE, "-i", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for line in out.stderr.splitlines():
            line = line.strip()
            if line.startswith("Duration:"):
                ts = line.split("Duration:")[1].split(",")[0].strip()
                h, m, s = ts.split(":")
                return int(h) * 3600 + int(m) * 60 + float(s)
    except Exception:
        pass
    return 5.0

MAX_UPLOAD_BYTES = 300 * 1024 * 1024  # 300MB

RATE_LIMIT_PER_MINUTE = 15
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

MASTER_LICENSE_KEY = os.environ.get("MASTER_LICENSE_KEY", "")

LICENSES = {
    "VIP-KEY-001": {"owner": "User1", "device": None},
    "VIP-KEY-002": {"owner": "User2", "device": None},
    "VIP-KEY-003": {"owner": "User3", "device": None}
}
if MASTER_LICENSE_KEY:
    LICENSES[MASTER_LICENSE_KEY] = {"owner": "Developer", "device": None}

LANG_OPTIONS = {
    "ko": {"female": "ko-KR-SunHiNeural", "male": "ko-KR-InJoonNeural"},
    "en": {"female": "en-US-AriaNeural", "male": "en-US-GuyNeural"},
    "zh": {"female": "zh-CN-XiaoxiaoNeural", "male": "zh-CN-YunjianNeural"},
    "es": {"female": "es-ES-ElviraNeural", "male": "es-ES-AlvaroNeural"},
    "ja": {"female": "ja-JP-NanamiNeural", "male": "ja-JP-KeitaNeural"},
    "de": {"female": "de-DE-KatjaNeural", "male": "de-DE-ConradNeural"},
    "fr": {"female": "fr-FR-DeniseNeural", "male": "fr-FR-HenriNeural"},
    "vi": {"female": "vi-VN-HoaiMyNeural", "male": "vi-VN-NamMinhNeural"}
}

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

@app.get("/")
def root():
    return {"status": "ok", "service": "AI Global Video Editor Running"}

@app.post("/api/render_file")
@app.post("/api/render_file/")
@app.post("/render_file")
async def process_video_file(
    request: Request,
    file: UploadFile = File(None),
    target_lang: str = Form("ko"),
    gender: str = Form("female"),
    mode: str = Form("dynamic_subtitle"),
    license_key: str = Form(""),
    device_id: str = Form("UNKNOWN_DEVICE")
):
    client_ip = request.client.host if request.client else "127.0.0.1"
    if is_rate_limited(client_ip):
        return JSONResponse(status_code=429, content={"error": "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요."})

    if license_key not in LICENSES:
        return JSONResponse(status_code=403, content={"error": "유효하지 않은 라이선스 키입니다."})

    lic = LICENSES[license_key]
    if not (MASTER_LICENSE_KEY and license_key == MASTER_LICENSE_KEY):
        if lic["device"] is None:
            lic["device"] = device_id
        elif lic["device"] != device_id:
            return JSONResponse(status_code=403, content={"error": "이미 다른 기기에 등록된 라이선스입니다."})

    task_id = str(os.urandom(6).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        if file and file.filename:
            total = 0
            with open(input_path, "wb") as buffer:
                while True:
                    chunk = await file.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > MAX_UPLOAD_BYTES:
                        return JSONResponse(status_code=413, content={"error": "파일이 너무 큽니다 (최대 300MB)."})
                    buffer.write(chunk)
        else:
            return JSONResponse(status_code=400, content={"error": "동영상 파일을 선택해 주세요."})

        async with RENDER_SEMAPHORE:
            audio_path = os.path.join(task_dir, "audio.wav")

            # 1. 오디오 추출
            cmd_audio = [
                FFMPEG_EXE, "-y", "-i", input_path,
                "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
                audio_path
            ]
            await asyncio.to_thread(subprocess.run, cmd_audio, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            has_original_audio = os.path.exists(audio_path) and os.path.getsize(audio_path) > 1000
            if not has_original_audio:
                duration = await asyncio.to_thread(probe_duration_seconds, input_path)
                cmd_silent = [
                    FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", str(duration), "-acodec", "pcm_s16le", audio_path
                ]
                await asyncio.to_thread(subprocess.run, cmd_silent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # 2. 음성 인식 (STT)
            segment_list = []
            try:
                model = await asyncio.to_thread(get_whisper_model)
                segments, _ = await asyncio.to_thread(model.transcribe, audio_path, beam_size=1, vad_filter=False)
                segment_list = list(segments)
            except Exception as e:
                print(f"STT 에러 (무시): {e}")

            output_path = os.path.join(task_dir, "output.mp4")

            # 3-A. 자막 모드
            if mode in ["subtitle", "dynamic_subtitle"]:
                srt_path = os.path.join(task_dir, "subtitles.srt")
                with open(srt_path, "w", encoding="utf-8") as f_srt:
                    idx = 1
                    for seg in segment_list:
                        t = seg.text.strip()
                        if not t:
                            continue
                        trans = translate_text(t, target_lang)
                        s_h, s_m, s_s = int(seg.start // 3600), int((seg.start % 3600) // 60), seg.start % 60
                        e_h, e_m, e_s = int(seg.end // 3600), int((seg.end % 3600) // 60), seg.end % 60
                        f_srt.write(f"{idx}\n{s_h:02d}:{s_m:02d}:{s_s:06.3f}".replace('.', ',') + f" --> {e_h:02d}:{e_m:02d}:{e_s:06.3f}".replace('.', ',') + f"\n{trans}\n\n")
                        idx += 1

                # 자막 인코딩 시도
                cmd_sub = [
                    FFMPEG_EXE, "-y", "-i", input_path,
                    "-vf", f"subtitles={srt_path}",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy",
                    output_path
                ]
                res_sub = await asyncio.to_thread(subprocess.run, cmd_sub, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

                # 실패 시 소프트 자막으로 스트림 결합
                if res_sub.returncode != 0 or not os.path.exists(output_path):
                    cmd_soft = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", srt_path,
                        "-c", "copy", "-c:s", "mov_text",
                        output_path
                    ]
                    await asyncio.to_thread(subprocess.run, cmd_soft, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # 3-B. 더빙 모드 (Edge-TTS + 안전 믹싱)
            else:
                target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
                voice_name = target_info.get(gender, target_info["female"])

                spoken_lines = [translate_text(s.text.strip(), target_lang) for s in segment_list if s.text.strip()]
                full_text = " ".join(spoken_lines)
                if not full_text.strip():
                    full_text = "안녕하세요. 영상 번역이 완료되었습니다."

                temp_mp3 = os.path.join(task_dir, "tts.mp3")
                
                # 비동기 TTS 실행 방어
                communicate = edge_tts.Communicate(full_text, voice_name)
                await communicate.save(temp_mp3)

                # 오디오 믹싱: 원본 음성이 있으면 믹싱, 없으면 TTS 단독 대체
                if has_original_audio:
                    cmd_dub = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                        "-filter_complex", "[0:a]volume=0.25[a0];[1:a]volume=1.3[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[aout]",
                        "-map", "0:v:0", "-map", "[aout]",
                        "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                        output_path
                    ]
                else:
                    cmd_dub = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                        "-map", "0:v:0", "-map", "1:a:0",
                        "-c:v", "copy", "-c:a", "aac",
                        output_path
                    ]

                res_dub = await asyncio.to_thread(subprocess.run, cmd_dub, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

                # 믹싱 실패 시 TTS 오디오로 단순 교체 폴백
                if res_dub.returncode != 0 or not os.path.exists(output_path):
                    cmd_fallback = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                        "-map", "0:v:0", "-map", "1:a:0",
                        "-c:v", "copy", "-c:a", "aac",
                        output_path
                    ]
                    await asyncio.to_thread(subprocess.run, cmd_fallback, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # 4. 최종 방어 (원본 파일 보존 반환)
            if not os.path.exists(output_path) or os.path.getsize(output_path) < 1000:
                shutil.copy(input_path, output_path)

            def cleanup():
                shutil.rmtree(task_dir, ignore_errors=True)
                gc.collect()

            return FileResponse(
                output_path,
                media_type="video/mp4",
                filename=f"result_{target_lang}.mp4",
                background=BackgroundTask(cleanup)
            )

    except Exception as e:
        err_detail = traceback.format_exc()
        print(f"서버 에러 상세:\n{err_detail}")
        shutil.rmtree(task_dir, ignore_errors=True)
        gc.collect()
        return JSONResponse(status_code=500, content={"error": f"렌더링 실패: {str(e)}"})
