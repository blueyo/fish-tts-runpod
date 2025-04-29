"""
RunPod Serverless handler for Fish-Speech (Rust).
────────────────────────────────────────────────
• Spins up the Rust server **once** per worker.
• Guards single-concurrency with a semaphore (Fish = 1 req / GPU).
• Supports two formats:
    - WAV  → returns one base-64 blob in JSON.
    - OGG  → streams base-64 chunks with a generator.
"""

import os, asyncio, base64, time, subprocess, traceback
import runpod, aiohttp, httpx

# ───────────────────────── Bootstrap Rust server ─────────────────────────
FISH_PORT = int(os.getenv("FISH_PORT", 3000))
VOICE_DIR = os.getenv("VOICE_DIR", "/app/voices")

server = subprocess.Popen(
    ["fish-speech", "--port", str(FISH_PORT), "--voice-dir", VOICE_DIR]
)

# Wait for /health
client = httpx.Client(timeout=30)
for _ in range(60):
    try:
        if client.get(f"http://127.0.0.1:{FISH_PORT}/health").status_code == 200:
            break
    except Exception:
        time.sleep(1)
else:
    raise RuntimeError("fish-speech failed to start")

FISH_URL = f"http://127.0.0.1:{FISH_PORT}/v1/audio/speech"
GPU_SEMAPHORE = asyncio.Semaphore(1)

# ──────────────────────────  Handler function  ───────────────────────────
async def handler(job):
    """RunPod calls this for each inference request."""
    inp = job.get("input", {})
    text  = inp.get("text", "")
    voice = inp.get("voice", "default")
    fmt   = inp.get("response_format", "wav").lower()

    if not text:
        return {"error": "Input 'text' must be non-empty."}
    if fmt not in ("wav", "ogg"):
        return {"error": "response_format must be 'wav' or 'ogg'."}

    payload = {"text": text, "voice": voice, "response_format": fmt}

    async with GPU_SEMAPHORE:
        try:
            async with aiohttp.ClientSession() as sess:
                async with sess.post(FISH_URL, json=payload) as resp:
                    resp.raise_for_status()

                    if fmt == "wav":
                        wav = await resp.read()
                        return {
                            "audio_format": "wav",
                            "audio_base64": base64.b64encode(wav).decode()
                        }

                    # ---------- OGG streaming ----------
                    async def ogg_stream():
                        async for chunk in resp.content.iter_chunked(4096):
                            if chunk:
                                yield {
                                    "chunk_base64": base64.b64encode(chunk).decode()
                                }
                    return ogg_stream()

        except Exception as e:
            traceback.print_exc()
            return {"error": f"Handler exception: {str(e)}"}

# ───────────────────────── Start the worker loop ─────────────────────────
runpod.serverless.start({"handler": handler})