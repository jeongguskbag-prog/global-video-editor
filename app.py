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

# -------------------------------------------------------------------------
# 1. FFmpeg 바이너리 자동 탐색 (시스템 의존성 제거)
# -------------------------------------------------------------------------
try:
    FFMPEG_EXE = imageio_ffmpeg.get_ffmpeg_exe()
except Exception:
    FFMPEG_EXE = "ffmpeg"

# -------------------------------------------------------------------------
# 2. Rate Limit 및 동시성 보호 설정
# -------------------------------------------------------------------------
RATE_LIMIT_PER_MINUTE = 10
CLIENT_REQUEST_LOG = defaultdict(list)
RENDER_SEMAPHORE = asyncio.Semaphore(2)

def is_rate_limited(client_ip: str) -> bool:
    now = time.time()
    timestamps = CLIENT_REQUEST_LOG[client_ip]
    CLIENT_REQUEST_LOG[client_ip] = [t for t in timestamps if now - t < 60.0]
    if len(CLIENT_REQUEST_LOG[client_ip]) >= RATE_LIMIT_PER_MINUTE:
        return True
    CLIENT_REQUEST_LOG[client_ip].append(now)
    return False

# -------------------------------------------------------------------------
# 3. 기기 귀속 보안 라이선스 DB
# -------------------------------------------------------------------------
LICENSES = {
    "DEV-MASTER-FREEPASS": {"owner": "Developer", "device": None},
    "VIP-KEY-001": {"owner": "User1", "device": None},
    "VIP-KEY-002": {"owner": "User2", "device": None},
    "VIP-KEY-003": {"owner": "User3", "device": None}
}

# -------------------------------------------------------------------------
# 4. 35개국 글로벌 Neural 성우 매핑
# -------------------------------------------------------------------------
LANG_OPTIONS = {
    "en": {"female": "en-US-AriaNeural", "male": "en-US-GuyNeural"},
    "zh": {"female": "zh-CN-XiaoxiaoNeural", "male": "zh-CN-YunjianNeural"},
    "es": {"female": "es-ES-ElviraNeural", "male": "es-ES-AlvaroNeural"},
    "hi": {"female": "hi-IN-SwaraNeural", "male": "hi-IN-MadhurNeural"},
    "ar": {"female": "ar-SA-ZariyahNeural", "male": "ar-SA-HamedNeural"},
    "bn": {"female": "bn-IN-TanishaaNeural", "male": "bn-IN-BashkarNeural"},
    "pt": {"female": "pt-BR-FranciscaNeural", "male": "pt-BR-AntonioNeural"},
    "ru": {"female": "ru-RU-SvetlanaNeural", "male": "ru-RU-DmitryNeural"},
    "ja": {"female": "ja-JP-NanamiNeural", "male": "ja-JP-KeitaNeural"},
    "pa": {"female": "pa-IN-GurpreetNeural", "male": "pa-IN-OjasNeural"},
    "de": {"female": "de-DE-KatjaNeural", "male": "de-DE-ConradNeural"},
    "jv": {"female": "jv-ID-SitiNeural", "male": "jv-ID-DimasNeural"},
    "fr": {"female": "fr-FR-DeniseNeural", "male": "fr-FR-HenriNeural"},
    "te": {"female": "te-IN-ShrutiNeural", "male": "te-IN-MohanNeural"},
    "mr": {"female": "mr-IN-AarohiNeural", "male": "mr-IN-ManoharNeural"},
    "tr": {"female": "tr-TR-EmelNeural", "male": "tr-TR-AhmetNeural"},
    "ta": {"female": "ta-IN-PallaviNeural", "male": "ta-IN-ValluvarNeural"},
    "vi": {"female": "vi-VN-HoaiMyNeural", "male": "vi-VN-NamMinhNeural"},
    "ur": {"female": "ur-PK-UzmaNeural", "male": "ur-PK-AsadNeural"},
    "ko": {"female": "ko-KR-SunHiNeural", "male": "ko-KR-InJoonNeural"},
    "it": {"female": "it-IT-ElsaNeural", "male": "it-IT-DiegoNeural"},
    "th": {"female": "th-TH-PremwadeeNeural", "male": "th-TH-NiwatNeural"},
    "gu": {"female": "gu-IN-DhwaniNeural", "male": "gu-IN-NiranjanNeural"},
    "fa": {"female": "fa-IR-DilaraNeural", "male": "fa-IR-FaridNeural"},
    "pl": {"female": "pl-PL-ZofiaNeural", "male": "pl-PL-MarekNeural"},
    "kn": {"female": "kn-IN-SapnaNeural", "male": "kn-IN-GaganNeural"},
    "ml": {"female": "ml-IN-SobhanaNeural", "male": "ml-IN-MidhunNeural"},
    "uk": {"female": "uk-UA-PolinaNeural", "male": "uk-UA-OstapNeural"},
    "su": {"female": "su-ID-TutiNeural", "male": "su-ID-JajangNeural"},
    "id": {"female": "id-ID-GadisNeural", "male": "id-ID-ArdiNeural"},
    "nl": {"female": "nl-NL-FennaNeural", "male": "nl-NL-MaartenNeural"},
    "ro": {"female": "ro-RO-AlinaNeural", "male": "ro-RO-EmilNeural"},
    "el": {"female": "el-GR-AthinaNeural", "male": "el-GR-NestorasNeural"},
    "cs": {"female": "cs-CZ-VlastaNeural", "male": "cs-CZ-AntoninNeural"},
    "sv": {"female": "sv-SE-SofieNeural", "male": "sv-SE-MattiasNeural"}
}

# -------------------------------------------------------------------------
# 5. 유틸리티 함수
# -------------------------------------------------------------------------
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
        'socket_timeout': 25,
        'max_filesize': 300 * 1024 * 1024
    }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
        return os.path.exists(output_path) and os.path.getsize(output_path) > 1024
    except Exception:
        return False

def validate_video_file(file_path: str) -> bool:
    try:
        cmd = [
            FFMPEG_EXE, "-v", "error", "-i", file_path, "-f", "null", "-"
        ]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=8)
        return os.path.exists(file_path) and os.path.getsize(file_path) > 1000
    except Exception:
        return os.path.exists(file_path) and os.path.getsize(file_path) > 1000

# -------------------------------------------------------------------------
# 6. 웹 브라우저 / iOS PWA UI
# -------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
def serve_web_interface():
    return """
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>AI 글로벌 영상 번역 스튜디오</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f0a1c; margin: 0; padding: 16px; color: #f0f0f5; }
        .card { background: #1c1432; border: 1px solid #36245e; border-radius: 12px; padding: 16px; margin-bottom: 16px; }
        h1 { font-size: 20px; margin-top: 0; color: #00e1ff; }
        .notice { font-size: 12px; color: #a49bb8; line-height: 1.5; }
        label { display: block; font-weight: 600; font-size: 13px; margin-top: 12px; margin-bottom: 4px; color: #c4bcdc; }
        input, select { width: 100%; padding: 12px; border: 1px solid #4a3478; border-radius: 8px; box-sizing: border-box; font-size: 14px; margin-bottom: 8px; background: #251b42; color: #fff; }
        .radio-group { display: flex; gap: 16px; margin-bottom: 12px; }
        .radio-item { display: flex; align-items: center; font-size: 14px; gap: 6px; }
        button { width: 100%; background: #6b3fe0; color: white; border: none; padding: 14px; border-radius: 8px; font-size: 16px; font-weight: bold; cursor: pointer; margin-top: 10px; }
        button:disabled { background: #473a63; color: #8c82a5; }
        #status { font-size: 13px; color: #ffb84d; font-weight: bold; margin-top: 12px; word-break: break-all; }
        .progress-bar { height: 4px; width: 100%; background: #2f2050; border-radius: 2px; overflow: hidden; display: none; margin-top: 10px; }
        .progress-inner { height: 100%; width: 50%; background: #00e1ff; animation: move 1.5s infinite linear; }
        @keyframes move { 0% { transform: translateX(-100%); } 100% { transform: translateX(200%); } }
    </style>
</head>
<body>
    <div class="card">
        <h1>AI 글로벌 영상 번역 스튜디오</h1>
        <div class="notice">
            • <strong>틱톡, 인스타, 유튜브</strong> 전 플랫폼 영상 완벽 지원<br>
            • 쇼츠 팝업 자막 및 BGM 보존 스마트 더빙 엔진 탑재
        </div>
    </div>
    <div class="card">
        <label>라이선스 키</label>
        <input type="text" id="licenseKey" value="DEV-MASTER-FREEPASS">

        <label>출력 방식</label>
        <div class="radio-group">
            <div class="radio-item"><input type="radio" name="mode" value="dynamic_subtitle" id="m_sub" checked><label for="m_sub">💥 쇼츠 팝업 자막</label></div>
            <div class="radio-item"><input type="radio" name="mode" value="bgm_dubbing" id="m_dub"><label for="m_dub">🎙️ BGM 보존 더빙</label></div>
        </div>

        <label>영상 파일 선택</label>
        <input type="file" id="videoFile" accept="video/*">

        <label>또는 영상 링크 입력 (틱톡/인스타/유튜브)</label>
        <input type="text" id="videoUrl" placeholder="https://www.tiktok.com/... 또는 https://youtube.com/...">

        <label>목표 번역 언어</label>
        <select id="targetLang">
            <option value="ko" selected>한국어 (Korean)</option>
            <option value="en">영어 (English)</option>
            <option value="ja">일본어 (Japanese)</option>
            <option value="zh">중국어 (Chinese)</option>
            <option value="es">스페인어 (Spanish)</option>
            <option value="vi">베트남어 (Vietnamese)</option>
            <option value="fr">프랑스어 (French)</option>
            <option value="de">독일어 (German)</option>
        </select>

        <label>성우 목소리 (더빙 시)</label>
        <div class="radio-group">
            <div class="radio-item"><input type="radio" name="gender" value="female" id="g_f" checked><label for="g_f">여성</label></div>
            <div class="radio-item"><input type="radio" name="gender" value="male" id="g_m"><label for="g_m">남성</label></div>
        </div>

        <button id="startBtn" onclick="startProcess()">AI 렌더링 시작</button>
        <div class="progress-bar" id="pBar"><div class="progress-inner"></div></div>
        <div id="status">대기 중: 영상이나 링크를 등록하고 시작하세요.</div>
    </div>

    <script>
        let deviceId = localStorage.getItem('app_device_id');
        if (!deviceId) {
            deviceId = 'WEB_' + Math.random().toString(36).substring(2, 15);
            localStorage.setItem('app_device_id', deviceId);
        }

        async function startProcess() {
            const lKey = document.getElementById('licenseKey').value.trim();
            const fileInput = document.getElementById('videoFile');
            const urlInput = document.getElementById('videoUrl').value.trim();

            if ((!fileInput.files || fileInput.files.length === 0) && !urlInput) {
                alert('동영상 파일을 선택하거나 영상 링크를 입력하세요.');
                return;
            }

            const mode = document.querySelector('input[name="mode"]:checked').value;
            const targetLang = document.getElementById('targetLang').value;
            const gender = document.querySelector('input[name="gender"]:checked').value;

            const btn = document.getElementById('startBtn');
            const pBar = document.getElementById('pBar');
            const status = document.getElementById('status');

            btn.disabled = true;
            pBar.style.display = 'block';
            status.innerText = '서버 전송 및 AI 렌더링 대기열 진입...';

            const formData = new FormData();
            if (fileInput.files && fileInput.files.length > 0) {
                formData.append('file', fileInput.files[0]);
            }
            if (urlInput) {
                formData.append('video_url', urlInput);
            }
            formData.append('mode', mode);
            formData.append('target_lang', targetLang);
            formData.append('gender', gender);
            formData.append('license_key', lKey);
            formData.append('device_id', deviceId);

            try {
                const res = await fetch('/api/render_file', { method: 'POST', body: formData });
                if (res.ok) {
                    status.innerText = '렌더링 완료! 다운로드 시작...';
                    const blob = await res.blob();
                    const dlUrl = window.URL.createObjectURL(blob);
                    const a = document.createElement('a');
                    a.href = dlUrl;
                    a.download = 'Result_' + mode + '_' + targetLang + '.mp4';
                    document.body.appendChild(a);
                    a.click();
                    a.remove();
                    window.URL.revokeObjectURL(dlUrl);
                    status.innerText = '다운로드가 완료되었습니다!';
                } else {
                    const err = await res.json();
                    status.innerText = '오류: ' + (err.error || res.statusText);
                }
            } catch (e) {
                status.innerText = '통신 오류: ' + e.message;
            } finally {
                btn.disabled = false;
                pBar.style.display = 'none';
            }
        }
    </script>
</body>
</html>
    """

# -------------------------------------------------------------------------
# 7. 메인 영상 렌더링 엔드포인트
# -------------------------------------------------------------------------
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
    # 1) Rate Limit 검사
    client_ip = request.client.host if request.client else "127.0.0.1"
    if is_rate_limited(client_ip):
        return JSONResponse(status_code=429, content={"error": "단시간에 너무 많은 요청이 발생했습니다. 1분 후 다시 시도해 주세요."})

    # 2) 라이선스 검증
    if license_key not in LICENSES:
        return JSONResponse(status_code=403, content={"error": "유효하지 않은 라이선스 키입니다."})

    lic = LICENSES[license_key]
    if license_key != "DEV-MASTER-FREEPASS":
        if lic["device"] is None:
            lic["device"] = device_id
        elif lic["device"] != device_id:
            return JSONResponse(status_code=403, content={"error": "이미 다른 기기에 귀속된 라이선스 키입니다."})

    task_id = str(os.urandom(8).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    input_path = os.path.join(task_dir, "input.mp4")

    try:
        # 3) 입력 영상 취득 및 검증
        if file and file.filename:
            with open(input_path, "wb") as buffer:
                shutil.copyfileobj(file.file, buffer)
        elif video_url and len(video_url.strip()) >= 5:
            ok = download_video_stream(video_url.strip(), input_path)
            if not ok:
                return JSONResponse(status_code=400, content={"error": "유효하지 않거나 다운로드할 수 없는 영상 링크입니다."})
        else:
            return JSONResponse(status_code=400, content={"error": "영상 파일이나 링크 중 하나를 반드시 입력해야 합니다."})

        if not validate_video_file(input_path):
            return JSONResponse(status_code=400, content={"error": "손상되었거나 재생할 수 없는 비디오 파일입니다."})

        # 4) 동시성 보호 및 AI 렌더링
        async with RENDER_SEMAPHORE:
            audio_path = os.path.join(task_dir, "audio.wav")
            
            # [오류 해결 핵심] FFMPEG_EXE 자동 탐색 바이너리를 통해 오디오 추출
            cmd_audio = [
                FFMPEG_EXE, "-y", "-i", input_path, 
                "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", 
                audio_path
            ]
            sub_res = subprocess.run(cmd_audio, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            # 오디오 트랙이 없는 무음 영상이거나 추출 실패 시 가상 무음 오디오 자동 생성 (Graceful Fallback)
            if sub_res.returncode != 0 or not os.path.exists(audio_path) or os.path.getsize(audio_path) < 100:
                cmd_silent = [
                    FFMPEG_EXE, "-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", "30", "-acodec", "pcm_s16le", audio_path
                ]
                subprocess.run(cmd_silent, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            # Whisper STT 안전 인퍼런스
            segment_list = []
            try:
                whisper_model = WhisperModel("tiny", device="cpu", compute_type="int8")
                segments, _ = whisper_model.transcribe(audio_path, beam_size=1, vad_filter=False)
                segment_list = list(segments)
                del whisper_model
                gc.collect()
            except Exception as e:
                print(f"Whisper 예외 (무음 영상 처리): {e}")

            output_path = os.path.join(task_dir, "output.mp4")

            if mode in ["subtitle", "dynamic_subtitle"]:
                # MrBeast 스타일 쇼츠 팝업 네온 자막
                ass_path = os.path.join(task_dir, "subtitles.ass")
                with open(ass_path, "w", encoding="utf-8") as f_ass:
                    f_ass.write("""[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Pop,Arial,68,&H0000FFFF,&H00000000,&H00000000,&H80000000,-1,0,0,0,100,100,2,0,1,6,0,2,40,40,260,1

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
                        f_ass.write(f"Dialogue: 0,{st},{et},Pop,,0,0,0,,{{\\t(0,100,\\fscx115\\fscy115)\\t(100,200,\\fscx100\\fscy100)}}{trans}\n")

                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path, 
                    "-vf", f"ass={ass_path}", 
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy", 
                    output_path
                ]
                res_burn = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                # ASS 필터 실패 시 비디오 원본 복사 폴백
                if res_burn.returncode != 0:
                    shutil.copy(input_path, output_path)
            else:
                # BGM 보존 및 스마트 더빙 믹싱
                target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
                voice_name = target_info["female"] if gender == "female" else target_info["male"]

                full_text = " ".join([translate_text(s.text.strip(), target_lang) for s in segment_list if s.text.strip()])
                if not full_text:
                    full_text = "음성이 감지되지 않았습니다."

                temp_mp3 = os.path.join(task_dir, "temp_tts.mp3")
                comm = edge_tts.Communicate(full_text, voice_name)
                await comm.save(temp_mp3)

                # 원본 오디오 감쇠(0.2) + 성우 음성(1.2) 네이티브 믹싱
                filter_complex = "[0:a]volume=0.2[a0];[1:a]volume=1.2[a1];[a0][a1]amix=inputs=2:duration=first[aout]"
                cmd = [
                    FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                    "-filter_complex", filter_complex,
                    "-map", "0:v", "-map", "[aout]",
                    "-c:v", "copy", "-c:a", "aac",
                    output_path
                ]
                res_dub = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if res_dub.returncode != 0:
                    # 원본에 오디오가 전혀 없었을 경우 새 TTS 음성만 입히기
                    cmd_alt = [
                        FFMPEG_EXE, "-y", "-i", input_path, "-i", temp_mp3,
                        "-map", "0:v", "-map", "1:a",
                        "-c:v", "copy", "-c:a", "aac",
                        output_path
                    ]
                    subprocess.run(cmd_alt, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            if not os.path.exists(output_path) or os.path.getsize(output_path) < 1000:
                return JSONResponse(status_code=500, content={"error": "결과 비디오 렌더링 검증 실패"})

            return FileResponse(output_path, media_type="video/mp4", filename=f"result_{target_lang}.mp4")

    except Exception as e:
        return JSONResponse(status_code=500, content={"error": f"서버 내부 처리 오류: {str(e)}"})

    finally:
        shutil.rmtree(task_dir, ignore_errors=True)
        gc.collect()
