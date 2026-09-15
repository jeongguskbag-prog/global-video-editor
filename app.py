import os
import asyncio
import urllib.request
import urllib.parse
import json
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
import yt_dlp
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

# 메모리 절약을 위해 tiny 모델 또는 필요 시 지연 로드 (Render 512MB RAM 한도 대응)
_whisper_model = None

def get_whisper():
    global _whisper_model
    if _whisper_model is None:
        # 512MB 메모리 초과 방지를 위해 tiny 모델 사용 권장
        _whisper_model = WhisperModel("tiny", device="cpu", compute_type="int8")
    return _whisper_model

class VideoRequest(BaseModel):
    url: str
    target_lang: str = "ko"
    gender: str = "female"

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

@app.get("/health")
def health_check():
    return {"status": "healthy"}

@app.post("/api/render")
async def process_video(req: VideoRequest):
    target_info = LANG_OPTIONS.get(req.target_lang, LANG_OPTIONS["ko"])
    voice_name = target_info["female"] if req.gender == "female" else target_info["male"]
    
    task_id = str(abs(hash(req.url + req.target_lang)))
    task_dir = os.path.join(WORK_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    
    out_tmpl = os.path.join(task_dir, "input.%(ext)s")
    ydl_opts = {
        'format': 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
        'outtmpl': out_tmpl,
        'quiet': True,
        'overwrites': True,
        'user_agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(req.url, download=True)
        video_file = ydl.prepare_filename(info)
    
    audio_path = os.path.join(task_dir, "audio.wav")
    video_clip = VideoFileClip(video_file)
    total_dur = video_clip.duration
    video_clip.audio.write_audiofile(audio_path, fps=16000, nbytes=2, codec='pcm_s16le', logger=None)
    
    silent_video = video_clip.without_audio()
    model = get_whisper()
    segments, _ = model.transcribe(audio_path, beam_size=5, vad_filter=False)
    
    silent_base = AudioClip(lambda t: [0, 0], duration=total_dur, fps=44100)
    audio_clips = [silent_base]
    
    for idx, seg in enumerate(segments):
        t = seg.text.strip()
        if len(t) < 2:
            continue
        txt = translate_text(t, req.target_lang)
        if not txt:
            continue
        tts_file = os.path.join(task_dir, f"tts_{idx}.mp3")
        comm = edge_tts.Communicate(txt, voice_name)
        await comm.save(tts_file)
        
        audio_clips.append(AudioFileClip(tts_file).set_start(seg.start))
        
    final_audio = CompositeAudioClip(audio_clips)
    final_clip = silent_video.set_audio(final_audio)
    
    output_path = os.path.join(task_dir, "output.mp4")
    final_clip.write_videofile(output_path, codec="libx264", audio_codec="aac", fps=24, preset="ultrafast", logger=None)
    
    video_clip.close()
    silent_video.close()
    final_clip.close()
    
    return FileResponse(output_path, media_type="video/mp4", filename=f"translated_{req.target_lang}.mp4")
