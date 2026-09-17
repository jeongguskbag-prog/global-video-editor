import os
import gc
import asyncio
import urllib.request
import urllib.parse
import json
import shutil
import subprocess
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse
import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
from moviepy.editor import VideoFileClip, AudioFileClip, CompositeAudioClip

app = FastAPI()

WORK_DIR = "/tmp/workspace"
os.makedirs(WORK_DIR, exist_ok=True)

# 서버 동시 인코딩 보호 (동시 최대 2건 처리, 초과 시 대기열 큐잉)
RENDER_SEMAPHORE = asyncio.Semaphore(2)

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
        with urllib.request.urlopen(req, timeout=5) as response:
            result = json.loads(response.read().decode('utf-8'))
            return "".join([part[0] for part in result[0] if part[0]])
    except Exception:
        return ""

@app.get("/", response_class=HTMLResponse)
def serve_iphone_web_app():
    return """
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>AI 영상 번역기 스튜디오</title>
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
            • <strong>쇼츠 다이내믹 팝업 자막</strong> & <strong>BGM 보존형 더빙</strong> 탑재<br>
            • Safari [공유] > [홈 화면에 추가]로 iOS 앱 설치 가능
        </div>
    </div>

    <div class="card">
        <label>0. 라이선스 키 (보안 인증)</label>
        <input type="text" id="licenseKey" value="DEV-MASTER-FREEPASS">

        <label>1. 모드 선택</label>
        <div class="radio-group">
            <div class="radio-item"><input type="radio" name="mode" value="dynamic_subtitle" id="m_sub" checked><label for="m_sub">💥 쇼츠 팝업 자막</label></div>
            <div class="radio-item"><input type="radio" name="mode" value="bgm_dubbing" id="m_dub"><label for="m_dub">🎙️ BGM 보존 더빙</label></div>
        </div>

        <label>2. 동영상 파일 선택</label>
        <input type="file" id="videoFile" accept="video/*">

        <label>3. 목표 번역 언어</label>
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

        <label>4. AI 성우 (더빙 모드)</label>
        <div class="radio-group">
            <div class="radio-item"><input type="radio" name="gender" value="female" id="g_f" checked><label for="g_f">여성</label></div>
            <div class="radio-item"><input type="radio" name="gender" value="male" id="g_m"><label for="g_m">남성</label></div>
        </div>

        <button id="startBtn" onclick="startProcess()">스마트 AI 렌더링 시작</button>

        <div class="progress-bar" id="pBar"><div class="progress-inner"></div></div>
        <div id="status">준비 완료: 옵션을 설정하고 버튼을 누르세요.</div>
    </div>

    <script>
        let deviceId = localStorage.getItem('app_device_id');
        if (!deviceId) {
            deviceId = 'IOS_' + Math.random().toString(36).substring(2, 15);
            localStorage.setItem('app_device_id', deviceId);
        }

        async function startProcess() {
            const lKey = document.getElementById('licenseKey').value.trim();
            const fileInput = document.getElementById('videoFile');
            if (!fileInput.files || fileInput.files.length === 0) {
                alert('동영상 파일을 선택해 주세요.');
                return;
            }

            const file = fileInput.files[0];
            const mode = document.querySelector('input[name="mode"]:checked').value;
            const targetLang = document.getElementById('targetLang').value;
            const gender = document.querySelector('input[name="gender"]:checked').value;

            const btn = document.getElementById('startBtn');
            const pBar = document.getElementById('pBar');
            const status = document.getElementById('status');

            btn.disabled = true;
            pBar.style.display = 'block';
            status.innerText = '서버 대기열 진입 및 렌더링 처리 중...';

            const formData = new FormData();
            formData.append('file', file);
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
                    const url = window.URL.createObjectURL(blob);
                    const a = document.createElement('a');
                    a.href = url;
                    a.download = 'AI_' + mode + '_' + targetLang + '_' + file.name;
                    document.body.appendChild(a);
                    a.click();
                    a.remove();
                    window.URL.revokeObjectURL(url);
                    status.innerText = '성공적으로 저장되었습니다!';
                } else {
                    const err = await res.json();
                    status.innerText = '오류: ' + (err.error || res.statusText);
                }
            } catch (e) {
                status.innerText = '통신 실패: ' + e.message;
            } finally {
                btn.disabled = false;
                pBar.style.display = 'none';
            }
        }
    </script>
</body>
</html>
    """

@app.post("/api/render_file")
async def process_video_file(
    file: UploadFile = File(...),
    target_lang: str = Form("ko"),
    gender: str = Form("female"),
    mode: str = Form("dynamic_subtitle"), # dynamic_subtitle 또는 bgm_dubbing
    license_key: str = Form(...),
    device_id: str = Form(...)
):
    if license_key not in LICENSES:
        return JSONResponse(status_code=403, content={"error": "유효하지 않은 라이선스 키입니다."})

    lic = LICENSES[license_key]
    if license_key != "DEV-MASTER-FREEPASS":
        if lic["device"] is None:
            lic["device"] = device_id
        elif lic["device"] != device_id:
            return JSONResponse(status_code=403, content={"error": "이미 다른 기기에 등록된 라이선스 키입니다."})

    target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
    voice_name = target_info["female"] if gender == "female" else target_info["male"]

    task_id = str(os.urandom(8).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)

    input_path = os.path.join(task_dir, "input.mp4")
    with open(input_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    # 동시 실행 세마포어로 서버 과부하 보호
    async with RENDER_SEMAPHORE:
        video_clip = None
        final_clip = None
        audio_clips = []
        try:
            audio_path = os.path.join(task_dir, "audio.wav")
            video_clip = VideoFileClip(input_path)
            total_dur = video_clip.duration
            video_clip.audio.write_audiofile(audio_path, fps=16000, nbytes=2, codec='pcm_s16le', logger=None)

            # Whisper STT 실행
            whisper_model = WhisperModel("tiny", device="cpu", compute_type="int8")
            segments, _ = whisper_model.transcribe(audio_path, beam_size=1, vad_filter=False)
            segment_list = list(segments)
            del whisper_model
            gc.collect()

            output_path = os.path.join(task_dir, "output.mp4")

            if mode in ["subtitle", "dynamic_subtitle"]:
                # MrBeast 스타일 다이내믹 팝업 ASS 자막 생성
                ass_path = os.path.join(task_dir, "subtitles.ass")
                with open(ass_path, "w", encoding="utf-8") as f_ass:
                    f_ass.write("""[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: DynamicPop,Arial,72,&H0000FFFF,&H00000000,&H00000000,&H80000000,-1,0,0,0,100,100,2,0,1,6,0,2,40,40,280,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
""")
                    for seg in segment_list:
                        t = seg.text.strip()
                        if len(t) < 1:
                            continue
                        trans = translate_text(t, target_lang) or t
                        st = format_ass_time(seg.start)
                        et = format_ass_time(seg.end)
                        # ASS 팝업 애니메이션 태그 삽입
                        f_ass.write(f"Dialogue: 0,{st},{et},DynamicPop,,0,0,0,,{{\\t(0,100,\\fscx115\\fscy115)\\t(100,200,\\fscx100\\fscy100)}}{trans}\n")

                video_clip.close()
                cmd = [
                    "ffmpeg", "-y", "-i", input_path,
                    "-vf", f"ass={ass_path}",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy",
                    output_path
                ]
                subprocess.run(cmd, check=True)

            else:
                # BGM 보존 스마트 오디오 덕킹 더빙 모드
                # 1) 원본 오디오 볼륨을 15%로 낮춰 배경 음악 유지
                background_audio = video_clip.audio.volumex(0.15)
                audio_clips.append(background_audio)

                # 2) AI 번역 음성을 합성하여 레이어드
                for idx, seg in enumerate(segment_list):
                    t = seg.text.strip()
                    if len(t) < 2:
                        continue
                    trans = translate_text(t, target_lang)
                    if not trans:
                        continue
                    tts_file = os.path.join(task_dir, f"tts_{idx}.mp3")
                    comm = edge_tts.Communicate(trans, voice_name)
                    await comm.save(tts_file)
                    # 성우 음성은 120% 볼륨으로 또렷하게 전달
                    dub_clip = AudioFileClip(tts_file).volumex(1.2).set_start(seg.start)
                    audio_clips.append(dub_clip)

                composite_audio = CompositeAudioClip(audio_clips).set_duration(total_dur)
                final_clip = video_clip.set_audio(composite_audio)

                final_clip.write_videofile(
                    output_path,
                    codec="libx264",
                    audio_codec="aac",
                    fps=20,
                    preset="ultrafast",
                    threads=1,
                    logger=None
                )

            return FileResponse(output_path, media_type="video/mp4", filename=f"result_{mode}_{target_lang}.mp4")

        except Exception as e:
            err = f"렌더링 처리 실패: {str(e)}"
            return JSONResponse(status_code=500, content={"error": err})

        finally:
            try:
                if video_clip: video_clip.close()
                if final_clip: final_clip.close()
                for c in audio_clips:
                    try: c.close()
                    except Exception: pass
                shutil.rmtree(task_dir, ignore_errors=True)
            except Exception:
                pass
            gc.collect()
