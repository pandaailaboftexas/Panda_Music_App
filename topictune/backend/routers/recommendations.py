import os, json, asyncio
from fastapi import APIRouter, HTTPException, Depends
from schemas import AIRecRequest
from routers.auth import get_current_user
from models import User
import httpx

router = APIRouter()
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

@router.get("/youtube-search")
async def youtube_search(q: str, max_results: int = 10, user: User = Depends(get_current_user)):
    if not q.strip():
        return []
    try:
        return await asyncio.to_thread(_yt_dlp_search, q, max_results)
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"YouTube search error: {str(e)}")

def _yt_dlp_search(q: str, max_results: int):
    import yt_dlp
    with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True, "skip_download": True}) as ydl:
        info = ydl.extract_info(f"ytsearch{max_results}:{q}", download=False)
    results = []
    for entry in (info.get("entries") or []):
        vid = entry.get("id", "")
        if not vid or len(vid) != 11:
            continue
        results.append({
            "youtube_video_id": vid,
            "title":        entry.get("title", "Unknown"),
            "channelName":  entry.get("uploader") or entry.get("channel") or "Unknown",
            "thumbnail_url": f"https://img.youtube.com/vi/{vid}/mqdefault.jpg",
            "duration":     int(entry.get("duration") or 0),
        })
    return results

@router.post("/ai")
async def get_ai_recommendations(req: AIRecRequest, user: User = Depends(get_current_user)):
    if not ANTHROPIC_API_KEY:
        raise HTTPException(status_code=500, detail="ANTHROPIC_API_KEY not set in backend/.env")
    if req.mode == "pool":
        titles   = ", ".join(t.title for t in (req.all_tracks or [])[:30]) or "none"
        channels = ", ".join({t.channelName for t in (req.all_tracks or [])}) or "unknown"
        prompt = (
            f"You are a music recommendation assistant.\n"
            f"User library: {titles}. Favourite artists: {channels}.\n"
            f"Recommend exactly 10 fresh YouTube tracks they would enjoy. Do not repeat library tracks.\n"
            f"Reply ONLY with a JSON array — no markdown:\n"
            f'[{{"youtube_video_id":"ID","title":"T","channelName":"C","reason":"R","tags":["t"]}}]'
        )
    else:
        existing = ", ".join(t.title for t in (req.existing_tracks or [])) or "none"
        prompt = (
            f"Topic: \"{req.topic_name}\" — {req.topic_description or req.topic_name}.\n"
            f"Existing tracks: {existing}.\n"
            f"Recommend exactly 6 YouTube tracks that fit this topic. Do not repeat existing tracks.\n"
            f"Reply ONLY with a JSON array — no markdown:\n"
            f'[{{"youtube_video_id":"ID","title":"T","channelName":"C","reason":"R"}}]'
        )
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            "https://api.anthropic.com/v1/messages",
            headers={"x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"},
            json={"model": "claude-sonnet-4-6", "max_tokens": 1500, "messages": [{"role": "user", "content": prompt}]},
        )
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"Anthropic API error: {resp.text}")
    raw = resp.json()["content"][0]["text"].strip()
    if "```" in raw:
        parts = raw.split("```")
        raw = parts[1] if len(parts) > 1 else parts[0]
        if raw.startswith("json"): raw = raw[4:]
        raw = raw.strip()
    try:
        items = json.loads(raw)
    except Exception:
        raise HTTPException(status_code=502, detail="AI returned invalid JSON — try again")
    return [{"youtube_video_id": r.get("youtube_video_id",""), "title": r.get("title",""),
             "channelName": r.get("channelName",""),
             "thumbnail_url": f"https://img.youtube.com/vi/{r.get('youtube_video_id','')}/mqdefault.jpg",
             "reason": r.get("reason",""), "tags": r.get("tags",[])}
            for r in items if r.get("youtube_video_id")]
