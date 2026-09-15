import os
import gc
import asyncio
import urllib.request
import urllib.parse
import json
import traceback
import shutil
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import FileResponse, JSONResponse
import edge_tts
from deep_translator import GoogleTranslator
from faster_whisper import WhisperModel
from moviepy.editor import VideoFileClip, AudioFileClip, CompositeAudioClip
from moviepy.audio.AudioClip import AudioClip

app = FastAPI()

WORK_DIR = "/tmp/workspace"
os.makedirs(WORK_DIR, exist_ok=True)

LANG_OPTIONS = {
    "ko": {"female": "ko-KR-SunHiNeural", "male": "ko-KR-InJoonNeural"},
    "en": {"female": "en-US-AriaNeural", "male": "en-US-GuyNeural"},
    "ja": {"female": "ja-JP-NanamiNeural", "male": "ja-JP-KeitaNeural"},
    "zh": {"female": "zh-CN-XiaoxiaoNeural", "male": "zh-CN-YunjianNeural"},
    "es": {"female": "es-ES-ElviraNeural", "male": "es-ES-AlvaroNeural"},
    "fr": {"female": "fr-FR-DeniseNeural", "male": "fr-FR-HenriNeural"},
    "de": {"female": "de-DE-KatjaNeural", "male": "de-DE-ConradNeural"},
    "ru": {"female": "ru-RU-SvetlanaNeural", "male": "ru-RU-DmitryNeural"},
    "pt": {"female": "pt-BR-FranciscaNeural", "male": "pt-BR-AntonioNeural"},
    "vi": {"female": "vi-VN-HoaiMyNeural", "male": "vi-VN-NamMinhNeural"}
}

def translate_text(text, target_code):
    if not text or len(text.strip()) < 2:
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

@app.get("/")
def read_root():
    return {"status": "ok"}

@app.post("/api/render_file")
async def process_video_file(
    file: UploadFile = File(...),
    target_lang: str = Form("ko"),
    gender: str = Form("female")
):
    target_info = LANG_OPTIONS.get(target_lang, LANG_OPTIONS["ko"])
    voice_name = target_info["female"] if gender == "female" else target_info["male"]

    task_id = str(os.urandom(8).hex())
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)

    input_path = os.path.join(task_dir, "input.mp4")
    with open(input_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    stage = "시작"
    video_clip = None
    silent_video = None
    final_clip = None
    audio_clips = []

    try:
        # 1. 오디오 분리
        stage = "1단계: 오디오 추출"
        audio_path = os.path.join(task_dir, "audio.wav")
        video_clip = VideoFileClip(input_path)
        total_dur = video_clip.duration
        video_clip.audio.write_audiofile(audio_path, fps=16000, nbytes=2, codec='pcm_s16le', logger=None)

        silent_video = video_clip.without_audio()

        # 2. Whisper STT (초경량 모델)
        stage = "2단계: 음성인식(Whisper)"
        whisper_model = WhisperModel("tiny", device="cpu", compute_type="int8")
        segments, _ = whisper_model.transcribe(audio_path, beam_size=1, vad_filter=False)
        segment_list = list(segments)
        del whisper_model
        gc.collect()

        # 3. 더빙 음성 생성
        stage = "3단계: 번역 및 TTS 합성"
        silent_base = AudioClip(lambda t: [0, 0], duration=total_dur, fps=44100)
        audio_clips.append(silent_base)

        for idx, seg in enumerate(segment_list):
            t = seg.text.strip()
            if len(t) < 2:
                continue
            txt = translate_text(t, target_lang)
            if not txt:
                continue
            tts_file = os.path.join(task_dir, f"tts_{idx}.mp3")
            comm = edge_tts.Communicate(txt, voice_name)
            await comm.save(tts_file)
            audio_clips.append(AudioFileClip(tts_file).set_start(seg.start))

        final_audio = CompositeAudioClip(audio_clips)
        final_clip = silent_video.set_audio(final_audio)

        # 4. 최종 인코딩
        stage = "4단계: 클라우드 영상 인코딩"
        output_path = os.path.join(task_dir, "output.mp4")
        final_clip.write_videofile(
            output_path,
            codec="libx264",
            audio_codec="aac",
            fps=20,
            preset="ultrafast",
            threads=1,
            logger=None
        )

        return FileResponse(output_path, media_type="video/mp4", filename=f"translated_{target_lang}.mp4")

    except Exception as e:
        error_detail = f"[{stage}] 에러: {str(e)}"
        print(error_detail)
        return JSONResponse(status_code=500, content={"error": error_detail})

    finally:
        try:
            if video_clip: video_clip.close()
            if silent_video: silent_video.close()
            if final_clip: final_clip.close()
            for c in audio_clips:
                try: c.close()
                except Exception: pass
        except Exception:
            pass
        gc.collect()
