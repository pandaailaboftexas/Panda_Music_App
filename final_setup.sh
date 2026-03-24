#!/bin/bash
# ================================================================
#  TopicTune — Complete Install Script
#
#  HOW TO USE:
#    1. Save this file anywhere, e.g. ~/Downloads/topictune_install.sh
#    2. Run:
#         chmod +x ~/Downloads/topictune_install.sh
#         ~/Downloads/topictune_install.sh
#    3. When done, edit the .env file it tells you to
#    4. Run ./start.sh from inside the project folder
#
#  The project installs to ~/topictune by default.
#  You can move the folder anywhere afterwards — it will still work.
# ================================================================
set -e

# ── Install location ─────────────────────────────────────────────
# The project installs in the SAME FOLDER as this script.
# So just put this script wherever you want the project to live.
# Example:
#   ~/Desktop/topictune_install.sh  → installs to ~/Desktop/topictune
#   ~/Projects/topictune_install.sh → installs to ~/Projects/topictune
#   /Volumes/USB/topictune_install.sh → installs to /Volumes/USB/topictune

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/topictune"
BACK=$ROOT/backend
FRONT=$ROOT/frontend

echo ""
echo "🎵  TopicTune — Installing to: $ROOT"
echo ""

# ── Kill any running servers ──────────────────────────────────────
echo "⛔  Stopping any running servers on ports 3000 / 8000..."
lsof -ti:8000 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
sleep 1

# ── Clean up previous install if it exists ───────────────────────
if [ -d "$ROOT" ]; then
  echo "🗑   Found existing install at $ROOT — removing it..."
  rm -rf $ROOT
fi
mkdir -p $BACK/routers $FRONT
echo "✅  Folders ready at: $ROOT"

# ================================================================
#  BACKEND
# ================================================================
echo ""
echo "📝  Writing backend files..."

# ── .env ─────────────────────────────────────────────────────────
cat > $BACK/.env << 'EOF'
ANTHROPIC_API_KEY=your_anthropic_api_key_here
SECRET_KEY=change_this_to_any_random_string_min_32_chars
ACCESS_TOKEN_EXPIRE_MINUTES=10080
EOF

# ── database.py ──────────────────────────────────────────────────
cat > $BACK/database.py << 'EOF'
from pathlib import Path
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

# DB lives next to this file — works from any directory
DB_PATH = Path(__file__).parent / "topictune.db"
SQLALCHEMY_DATABASE_URL = f"sqlite:///{DB_PATH}"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL,
    connect_args={"check_same_thread": False},
    pool_size=20,
    max_overflow=40,
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF

# ── models.py ────────────────────────────────────────────────────
cat > $BACK/models.py << 'EOF'
from sqlalchemy import Column, String, Integer, Boolean, Float, DateTime, Text, JSON, ForeignKey
from sqlalchemy.sql import func
from database import Base
import uuid

def gen_id():
    return str(uuid.uuid4())[:12]

class User(Base):
    __tablename__ = "users"
    id               = Column(String, primary_key=True, default=gen_id)
    username         = Column(String, unique=True, nullable=False, index=True)
    email            = Column(String, nullable=True)
    hashed_password  = Column(String, nullable=False)
    is_guest         = Column(Boolean, default=False)
    created_at       = Column(DateTime, server_default=func.now())

class Topic(Base):
    __tablename__ = "topics"
    id          = Column(String, primary_key=True, default=gen_id)
    user_id     = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    name        = Column(String, nullable=False)
    description = Column(Text, default="")
    sort_order  = Column(Integer, default=0)
    created_at  = Column(DateTime, server_default=func.now())
    updated_at  = Column(DateTime, server_default=func.now(), onupdate=func.now())

class Track(Base):
    __tablename__ = "tracks"
    id                = Column(String, primary_key=True, default=gen_id)
    user_id           = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    youtube_video_id  = Column(String, nullable=False)
    youtube_url       = Column(String, default="")
    title             = Column(String, nullable=False)
    channel_name      = Column(String, default="")
    thumbnail_url     = Column(String, default="")
    duration          = Column(Integer, default=0)
    topic_id          = Column(String, nullable=False)
    tags              = Column(JSON, default=list)
    notes             = Column(Text, default="")
    added_at          = Column(DateTime, server_default=func.now())
    last_played_at    = Column(DateTime, nullable=True)
    play_count        = Column(Integer, default=0)
    is_favorite       = Column(Boolean, default=False)
    is_blocked        = Column(Boolean, default=False)
    is_unavailable    = Column(Boolean, default=False)
    last_playback_pos = Column(Float, default=0.0)
    sort_order        = Column(Integer, default=0)

class PlaybackSession(Base):
    __tablename__ = "playback_sessions"
    id            = Column(String, primary_key=True, default=gen_id)
    user_id       = Column(String, ForeignKey("users.id"), nullable=False)
    track_id      = Column(String, nullable=False)
    topic_id      = Column(String, nullable=False)
    started_at    = Column(DateTime, server_default=func.now())
    ended_at      = Column(DateTime, nullable=True)
    last_position = Column(Float, default=0.0)
    completed     = Column(Boolean, default=False)
EOF

# ── schemas.py ───────────────────────────────────────────────────
cat > $BACK/schemas.py << 'EOF'
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime

class UserRegister(BaseModel):
    username: str
    password: str
    email: Optional[str] = None

class UserOut(BaseModel):
    id: str
    username: str
    is_guest: bool
    class Config:
        from_attributes = True

class Token(BaseModel):
    access_token: str
    token_type: str
    user: UserOut

class TopicCreate(BaseModel):
    name: str
    description: Optional[str] = ""
    sort_order: Optional[int] = 0

class TopicUpdate(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    sort_order: Optional[int] = None

class TopicOut(BaseModel):
    id: str
    name: str
    description: str
    sort_order: int
    created_at: Optional[datetime] = None
    track_count: Optional[int] = 0
    class Config:
        from_attributes = True

class TrackCreate(BaseModel):
    youtube_video_id: str
    title: str
    channel_name: Optional[str] = ""
    thumbnail_url: Optional[str] = ""
    duration: Optional[int] = 0
    topic_id: str
    tags: Optional[List[str]] = []
    notes: Optional[str] = ""

class TrackUpdate(BaseModel):
    title: Optional[str] = None
    topic_id: Optional[str] = None
    tags: Optional[List[str]] = None
    notes: Optional[str] = None
    is_favorite: Optional[bool] = None
    is_blocked: Optional[bool] = None
    last_playback_pos: Optional[float] = None
    sort_order: Optional[int] = None

class TrackOut(BaseModel):
    id: str
    youtube_video_id: str
    youtube_url: str
    title: str
    channel_name: str
    thumbnail_url: str
    duration: int
    topic_id: str
    tags: List[str]
    notes: str
    added_at: Optional[datetime] = None
    last_played_at: Optional[datetime] = None
    play_count: int
    is_favorite: bool
    is_blocked: bool
    is_unavailable: bool
    last_playback_pos: float
    sort_order: int
    class Config:
        from_attributes = True

class PlaybackCreate(BaseModel):
    track_id: str
    topic_id: str

class PlaybackUpdate(BaseModel):
    last_position: Optional[float] = None
    completed: Optional[bool] = None

class TrackInfo(BaseModel):
    title: str
    channelName: str

class AIRecRequest(BaseModel):
    topic_name: str
    topic_description: Optional[str] = ""
    existing_tracks: Optional[List[TrackInfo]] = []
    all_tracks: Optional[List[TrackInfo]] = []
    mode: Optional[str] = "topic"
EOF

# ── routers/__init__.py ──────────────────────────────────────────
touch $BACK/routers/__init__.py

# ── routers/auth.py ──────────────────────────────────────────────
cat > $BACK/routers/auth.py << 'EOF'
import os, uuid, bcrypt
from datetime import datetime, timedelta
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from jose import JWTError, jwt
from database import get_db
from models import User
from schemas import UserRegister, UserOut, Token

router = APIRouter()

SECRET_KEY = os.environ.get("SECRET_KEY", "fallback_dev_secret_change_in_prod")
ALGORITHM  = "HS256"
EXPIRE_MIN = int(os.environ.get("ACCESS_TOKEN_EXPIRE_MINUTES", "10080"))

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)

def hash_pw(pw: str) -> str:
    return bcrypt.hashpw(pw.encode("utf-8")[:72], bcrypt.gensalt()).decode("utf-8")

def verify_pw(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain.encode("utf-8")[:72], hashed.encode("utf-8"))

def create_token(user_id: str) -> str:
    expire = datetime.utcnow() + timedelta(minutes=EXPIRE_MIN)
    return jwt.encode({"sub": user_id, "exp": expire}, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db)
) -> User:
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id: str = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user

@router.post("/register", response_model=Token)
def register(data: UserRegister, db: Session = Depends(get_db)):
    if not data.username or len(data.username.strip()) < 3:
        raise HTTPException(status_code=400, detail="Username must be at least 3 characters")
    if not data.password or len(data.password) < 4:
        raise HTTPException(status_code=400, detail="Password must be at least 4 characters")
    username = data.username.strip().lower()
    if db.query(User).filter(User.username == username).first():
        raise HTTPException(status_code=400, detail="Username already taken")
    user = User(
        id=str(uuid.uuid4())[:12],
        username=username,
        email=data.email or None,
        hashed_password=hash_pw(data.password),
        is_guest=False,
    )
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.post("/login", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    username = form.username.strip().lower()
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_pw(form.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Incorrect username or password")
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.post("/guest", response_model=Token)
def guest_login(db: Session = Depends(get_db)):
    guest_id = str(uuid.uuid4())[:12]
    user = User(
        id=guest_id,
        username=f"guest_{guest_id}",
        hashed_password=hash_pw(guest_id),
        is_guest=True,
    )
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.get("/me", response_model=UserOut)
def me(user: User = Depends(get_current_user)):
    return user
EOF

# ── routers/topics.py ────────────────────────────────────────────
cat > $BACK/routers/topics.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from models import Topic, Track, User
from schemas import TopicCreate, TopicUpdate, TopicOut
from routers.auth import get_current_user
from typing import List
import uuid

router = APIRouter()

@router.get("/", response_model=List[TopicOut])
def get_topics(db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    topics = db.query(Topic).filter(Topic.user_id == user.id).order_by(Topic.sort_order).all()
    result = []
    for t in topics:
        count = db.query(Track).filter(Track.topic_id == t.id, Track.is_blocked == False).count()
        out = TopicOut.from_orm(t)
        out.track_count = count
        result.append(out)
    return result

@router.post("/", response_model=TopicOut)
def create_topic(data: TopicCreate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    topic = Topic(id=str(uuid.uuid4())[:12], user_id=user.id, **data.dict())
    db.add(topic); db.commit(); db.refresh(topic)
    out = TopicOut.from_orm(topic)
    out.track_count = 0
    return out

@router.put("/{topic_id}", response_model=TopicOut)
def update_topic(topic_id: str, data: TopicUpdate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    topic = db.query(Topic).filter(Topic.id == topic_id, Topic.user_id == user.id).first()
    if not topic:
        raise HTTPException(status_code=404, detail="Topic not found")
    for k, v in data.dict(exclude_none=True).items():
        setattr(topic, k, v)
    db.commit(); db.refresh(topic)
    count = db.query(Track).filter(Track.topic_id == topic_id).count()
    out = TopicOut.from_orm(topic)
    out.track_count = count
    return out

@router.delete("/{topic_id}")
def delete_topic(topic_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    topic = db.query(Topic).filter(Topic.id == topic_id, Topic.user_id == user.id).first()
    if not topic:
        raise HTTPException(status_code=404, detail="Topic not found")
    db.query(Track).filter(Track.topic_id == topic_id, Track.user_id == user.id).delete()
    db.delete(topic); db.commit()
    return {"ok": True}
EOF

# ── routers/tracks.py ────────────────────────────────────────────
cat > $BACK/routers/tracks.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from sqlalchemy import func
from database import get_db
from models import Track, User
from schemas import TrackCreate, TrackUpdate, TrackOut
from routers.auth import get_current_user
from typing import List, Optional
from datetime import datetime
import uuid

router = APIRouter()

@router.get("/history/recent", response_model=List[TrackOut])
def recent_history(limit: int = 20, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    return (db.query(Track)
              .filter(Track.user_id == user.id, Track.last_played_at != None)
              .order_by(Track.last_played_at.desc())
              .limit(limit).all())

@router.get("/", response_model=List[TrackOut])
def get_tracks(
    topic_id: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    favorites_only: bool = False,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    q = db.query(Track).filter(Track.user_id == user.id, Track.is_blocked == False)
    if topic_id:
        q = q.filter(Track.topic_id == topic_id)
    if favorites_only:
        q = q.filter(Track.is_favorite == True)
    if search:
        term = f"%{search.lower()}%"
        q = q.filter(func.lower(Track.title).like(term) | func.lower(Track.channel_name).like(term))
    return q.order_by(Track.sort_order, Track.added_at).all()

@router.post("/", response_model=TrackOut)
def add_track(data: TrackCreate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    dup = db.query(Track).filter(
        Track.user_id == user.id,
        Track.youtube_video_id == data.youtube_video_id,
        Track.topic_id == data.topic_id,
    ).first()
    if dup:
        raise HTTPException(status_code=409, detail="Track already exists in this topic")
    thumb = data.thumbnail_url or f"https://img.youtube.com/vi/{data.youtube_video_id}/mqdefault.jpg"
    count = db.query(Track).filter(Track.user_id == user.id, Track.topic_id == data.topic_id).count()
    track = Track(
        id=str(uuid.uuid4())[:12], user_id=user.id,
        youtube_video_id=data.youtube_video_id,
        youtube_url=f"https://www.youtube.com/watch?v={data.youtube_video_id}",
        title=data.title, channel_name=data.channel_name,
        thumbnail_url=thumb, duration=data.duration,
        topic_id=data.topic_id, tags=data.tags, notes=data.notes, sort_order=count,
    )
    db.add(track); db.commit(); db.refresh(track)
    return track

@router.put("/{track_id}", response_model=TrackOut)
def update_track(track_id: str, data: TrackUpdate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    track = db.query(Track).filter(Track.id == track_id, Track.user_id == user.id).first()
    if not track:
        raise HTTPException(status_code=404, detail="Track not found")
    for k, v in data.dict(exclude_none=True).items():
        setattr(track, k, v)
    db.commit(); db.refresh(track)
    return track

@router.delete("/{track_id}")
def delete_track(track_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    track = db.query(Track).filter(Track.id == track_id, Track.user_id == user.id).first()
    if not track:
        raise HTTPException(status_code=404, detail="Track not found")
    db.delete(track); db.commit()
    return {"ok": True}

@router.post("/{track_id}/play")
def record_play(track_id: str, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    track = db.query(Track).filter(Track.id == track_id, Track.user_id == user.id).first()
    if not track:
        raise HTTPException(status_code=404, detail="Track not found")
    track.play_count += 1
    track.last_played_at = datetime.utcnow()
    db.commit()
    return {"ok": True}
EOF

# ── routers/player.py ────────────────────────────────────────────
cat > $BACK/routers/player.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from models import PlaybackSession, Track, User
from schemas import PlaybackCreate, PlaybackUpdate
from routers.auth import get_current_user
from datetime import datetime
import uuid

router = APIRouter()

@router.post("/session/start")
def start_session(data: PlaybackCreate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    s = PlaybackSession(
        id=str(uuid.uuid4())[:12], user_id=user.id,
        track_id=data.track_id, topic_id=data.topic_id,
    )
    db.add(s); db.commit(); db.refresh(s)
    return {"session_id": s.id}

@router.put("/session/{session_id}")
def update_session(session_id: str, data: PlaybackUpdate, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    s = db.query(PlaybackSession).filter(
        PlaybackSession.id == session_id, PlaybackSession.user_id == user.id).first()
    if not s:
        raise HTTPException(status_code=404, detail="Session not found")
    if data.last_position is not None:
        s.last_position = data.last_position
        t = db.query(Track).filter(Track.id == s.track_id).first()
        if t: t.last_playback_pos = data.last_position
    if data.completed is not None:
        s.completed = data.completed
        s.ended_at = datetime.utcnow()
    db.commit()
    return {"ok": True}

@router.get("/state")
def get_state(db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    last = (db.query(PlaybackSession)
              .filter(PlaybackSession.user_id == user.id)
              .order_by(PlaybackSession.started_at.desc()).first())
    if not last:
        return {"last_track_id": None, "last_position": 0}
    return {"last_track_id": last.track_id, "last_position": last.last_position, "topic_id": last.topic_id}
EOF

# ── routers/recommendations.py ───────────────────────────────────
cat > $BACK/routers/recommendations.py << 'EOF'
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
EOF

# ── main.py ──────────────────────────────────────────────────────
cat > $BACK/main.py << 'EOF'
from pathlib import Path
from dotenv import load_dotenv
# Always loads .env from same folder as this file
load_dotenv(Path(__file__).parent / ".env")

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from database import engine, Base
from routers import auth, topics, tracks, player, recommendations

Base.metadata.create_all(bind=engine)
app = FastAPI(title="TopicTune API", version="2.0.0")
app.add_middleware(CORSMiddleware,
    allow_origins=["http://localhost:3000","http://127.0.0.1:3000"],
    allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.include_router(auth.router,            prefix="/api/auth")
app.include_router(topics.router,          prefix="/api/topics")
app.include_router(tracks.router,          prefix="/api/tracks")
app.include_router(player.router,          prefix="/api/player")
app.include_router(recommendations.router, prefix="/api/recommendations")

@app.get("/")
def root():
    return {"status": "TopicTune API v2 running"}
EOF

# ================================================================
#  PYTHON DEPENDENCIES
# ================================================================
echo ""
echo "📦  Setting up Python virtual environment..."
cd $BACK
python3 -m venv venv
source venv/bin/activate
pip install -q \
  fastapi "uvicorn[standard]" sqlalchemy pydantic \
  python-multipart httpx python-dotenv \
  "python-jose[cryptography]" bcrypt yt-dlp
echo "✅  Python dependencies installed."

# ================================================================
#  FRONTEND: Create React App
# ================================================================
echo ""
echo "⚛️   Creating React app (takes ~2 min)..."
cd $ROOT
npx create-react-app@latest frontend 2>/dev/null || true
cd $FRONT
npm install axios --legacy-peer-deps --silent
echo "✅  React app created."

# ================================================================
#  FRONTEND SOURCE FILES
# ================================================================
echo "📝  Writing frontend source files..."
mkdir -p $FRONT/src/pages $FRONT/src/components

# ── src/index.js ─────────────────────────────────────────────────
cat > $FRONT/src/index.js << 'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<React.StrictMode><App /></React.StrictMode>);
EOF

# ── src/App.css ──────────────────────────────────────────────────
cat > $FRONT/src/App.css << 'EOF'
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0f0f1a;--bg2:#151525;--bg3:#1a1a2e;--bg4:#252545;
  --border:#2a2a4a;--border2:#3a3a6a;
  --text:#e0e0ff;--muted:#9ca3af;
  --accent:#6366f1;--accent2:#a78bfa;
  --gold:#f59e0b;--danger:#ef4444;
}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;overflow:hidden;height:100vh}
.app{display:grid;grid-template-columns:190px 1fr;grid-template-rows:1fr auto;height:100vh}
.sidebar{grid-row:1/3;background:var(--bg2);border-right:1px solid var(--border);overflow-y:auto;padding:12px 0;display:flex;flex-direction:column}
.main{overflow-y:auto;padding:24px}
.logo{font-size:17px;font-weight:800;padding:10px 18px 18px;background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;-webkit-text-fill-color:transparent;cursor:pointer}
.nav-btn{display:flex;align-items:center;gap:10px;padding:9px 18px;background:transparent;border:none;color:var(--muted);cursor:pointer;font-size:13.5px;text-align:left;width:100%;border-left:3px solid transparent;transition:all .15s}
.nav-btn:hover{background:var(--bg3);color:var(--text)}
.nav-btn.active{background:var(--bg3);color:var(--accent2);border-left-color:var(--accent2)}
.topic-btn{font-size:12.5px;padding:7px 18px}
.dot{width:7px;height:7px;border-radius:50%;background:var(--accent);flex-shrink:0;display:inline-block}
.sidebar-divider{border-top:1px solid var(--border);margin:10px 0}
.sidebar-label{padding:4px 18px;font-size:10px;color:#6b7280;text-transform:uppercase;letter-spacing:1px}
.sidebar-footer{margin-top:auto;padding:12px 18px;border-top:1px solid var(--border)}
.toast{position:fixed;top:16px;left:50%;transform:translateX(-50%);padding:9px 22px;border-radius:8px;font-size:13px;font-weight:500;z-index:9999;box-shadow:0 4px 20px #0009;white-space:nowrap}
.toast-success{background:#1d5c3a;color:#6ee7b7}
.toast-error{background:#7f1d1d;color:#fca5a5}
.toast-warn{background:#78350f;color:#fcd34d}
.card{background:var(--bg3);border:1px solid var(--border);border-radius:10px}
.btn{border:none;border-radius:8px;cursor:pointer;font-weight:500;transition:opacity .15s;color:#fff;white-space:nowrap}
.btn:hover{opacity:.85}
.btn:disabled{opacity:.5;cursor:not-allowed}
.btn-primary{background:var(--accent);padding:7px 16px;font-size:13px}
.btn-secondary{background:var(--bg4);padding:7px 16px;font-size:13px}
.btn-danger{background:var(--danger);padding:7px 16px;font-size:13px}
.btn-xs{padding:3px 10px;font-size:11px}
.btn-icon{background:transparent;border:none;cursor:pointer;color:var(--muted);padding:5px;border-radius:6px;display:inline-flex;align-items:center;justify-content:center;transition:color .15s;font-size:16px}
.btn-icon:hover{color:var(--text)}
input,select,textarea{background:var(--bg4);border:1px solid var(--border2);border-radius:8px;padding:8px 12px;color:var(--text);font-size:13px;outline:none;transition:border-color .15s;font-family:inherit}
input:focus,select:focus{border-color:var(--accent)}
input::placeholder{color:#6b7280}
select option{background:var(--bg4)}
.track-item{display:flex;align-items:center;gap:10px;padding:9px 14px;background:var(--bg3);border:1px solid var(--border);border-radius:10px;cursor:pointer;transition:background .15s,border-color .15s}
.track-item:hover{background:#1e1e3a}
.track-item.active{background:#1e1e45;border-color:var(--accent)}
.track-thumb{width:52px;height:38px;object-fit:cover;border-radius:5px;flex-shrink:0;background:var(--bg4)}
.track-info{flex:1;min-width:0}
.track-title{font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.track-sub{font-size:11px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.section-title{font-size:12px;color:var(--accent2);text-transform:uppercase;letter-spacing:.5px;margin-bottom:12px;margin-top:24px;font-weight:600}
.mini-player{grid-column:2;background:var(--bg2);border-top:1px solid var(--border);padding:8px 20px;display:flex;align-items:center;gap:12px}
.page-title{font-size:20px;font-weight:700;margin-bottom:20px;color:var(--text)}
::-webkit-scrollbar{width:5px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--border2);border-radius:3px}
EOF

# ── src/api.js ───────────────────────────────────────────────────
cat > $FRONT/src/api.js << 'EOF'
import axios from "axios";

const BACKEND = process.env.REACT_APP_API_URL || "http://localhost:8000";
const api = axios.create({ baseURL: `${BACKEND}/api` });

api.interceptors.request.use(cfg => {
  const token = localStorage.getItem("tt_token");
  if (token) cfg.headers.Authorization = `Bearer ${token}`;
  return cfg;
});

export const register   = ({ username, password, email }) =>
  api.post("/auth/register", { username, password, email: email || null });
export const login      = ({ username, password }) =>
  api.post("/auth/login",
    new URLSearchParams({ username: username.trim().toLowerCase(), password }),
    { headers: { "Content-Type": "application/x-www-form-urlencoded" } });
export const guestLogin = () => api.post("/auth/guest");
export const getMe      = () => api.get("/auth/me");

export const getTopics   = ()      => api.get("/topics/");
export const createTopic = (d)     => api.post("/topics/", d);
export const updateTopic = (id, d) => api.put(`/topics/${id}`, d);
export const deleteTopic = (id)    => api.delete(`/topics/${id}`);

export const getTracks   = (p)     => api.get("/tracks/", { params: p });
export const addTrack    = (d)     => api.post("/tracks/", d);
export const updateTrack = (id, d) => api.put(`/tracks/${id}`, d);
export const deleteTrack = (id)    => api.delete(`/tracks/${id}`);
export const recordPlay  = (id)    => api.post(`/tracks/${id}/play`);
export const getHistory  = (l=20)  => api.get("/tracks/history/recent", { params: { limit: l } });

export const getAIRecs     = (d)       => api.post("/recommendations/ai", d);
export const youtubeSearch = (q, n=10) => api.get("/recommendations/youtube-search", { params: { q, max_results: n } });

export const startSession   = (d)      => api.post("/player/session/start", d);
export const updateSession  = (id, d)  => api.put(`/player/session/${id}`, d);
export const getPlayerState = ()       => api.get("/player/state");
EOF

# ── src/pages/Login.js ───────────────────────────────────────────
cat > $FRONT/src/pages/Login.js << 'EOF'
import React, { useState } from "react";
import * as api from "../api";

export default function Login({ onLogin }) {
  const [tab,      setTab]      = useState("login");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [email,    setEmail]    = useState("");
  const [error,    setError]    = useState("");
  const [loading,  setLoading]  = useState(false);

  const validate = () => {
    if (!username.trim())           { setError("Username is required"); return false; }
    if (username.trim().length < 3) { setError("Username must be at least 3 characters"); return false; }
    if (!password)                  { setError("Password is required"); return false; }
    if (password.length < 4)        { setError("Password must be at least 4 characters"); return false; }
    return true;
  };

  const submit = async () => {
    if (!validate()) return;
    setLoading(true); setError("");
    try {
      const res = tab === "login"
        ? await api.login({ username: username.trim(), password })
        : await api.register({ username: username.trim(), password, email: email.trim() || null });
      localStorage.setItem("tt_token", res.data.access_token);
      localStorage.setItem("tt_user",  JSON.stringify(res.data.user));
      onLogin(res.data.user);
    } catch (e) {
      const d = e.response?.data?.detail;
      setError(Array.isArray(d) ? d.map(x => x.msg).join(", ") : d || "Cannot connect to server — is the backend running?");
    }
    setLoading(false);
  };

  const guestLogin = async () => {
    setLoading(true); setError("");
    try {
      const res = await api.guestLogin();
      localStorage.setItem("tt_token", res.data.access_token);
      localStorage.setItem("tt_user",  JSON.stringify(res.data.user));
      onLogin(res.data.user);
    } catch (e) {
      setError(e.response?.data?.detail || "Cannot connect to server — is the backend running?");
    }
    setLoading(false);
  };

  const F = { width:"100%", padding:"10px 12px", background:"#252545", border:"1px solid #3a3a6a",
    borderRadius:8, color:"#e0e0ff", fontSize:13, outline:"none", boxSizing:"border-box", fontFamily:"inherit" };

  return (
    <div style={{minHeight:"100vh",background:"#0f0f1a",display:"flex",alignItems:"center",justifyContent:"center"}}>
      <div style={{width:360,background:"#151525",borderRadius:16,padding:32,border:"1px solid #2a2a4a"}}>
        <div style={{textAlign:"center",marginBottom:24}}>
          <div style={{fontSize:40,marginBottom:8}}>🎵</div>
          <div style={{fontSize:22,fontWeight:800,background:"linear-gradient(90deg,#818cf8,#c084fc)",
            WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent"}}>TopicTune</div>
          <div style={{fontSize:13,color:"#6b7280",marginTop:4}}>Your personal YouTube music organizer</div>
        </div>
        <div style={{display:"flex",gap:6,marginBottom:20}}>
          {[["login","Login"],["register","Register"]].map(([id,l])=>(
            <button key={id} onClick={()=>{setTab(id);setError("");}}
              style={{flex:1,padding:"8px 0",border:"none",borderRadius:8,cursor:"pointer",
                fontWeight:600,fontSize:13,background:tab===id?"#6366f1":"#252545",color:"#fff"}}>{l}</button>
          ))}
        </div>
        <div style={{display:"flex",flexDirection:"column",gap:10,marginBottom:16}}>
          <input value={username} onChange={e=>setUsername(e.target.value)}
            onKeyDown={e=>e.key==="Enter"&&submit()}
            placeholder="Username (min 3 chars)" autoComplete="username" style={F} />
          {tab==="register"&&(
            <input value={email} onChange={e=>setEmail(e.target.value)}
              placeholder="Email (optional)" autoComplete="email" style={F} />
          )}
          <input value={password} onChange={e=>setPassword(e.target.value)}
            onKeyDown={e=>e.key==="Enter"&&submit()}
            type="password" placeholder="Password (min 4 chars)"
            autoComplete={tab==="login"?"current-password":"new-password"} style={F} />
        </div>
        {error&&(
          <div style={{color:"#f87171",fontSize:13,marginBottom:12,background:"#2d1010",
            padding:"8px 12px",borderRadius:8,textAlign:"center"}}>{error}</div>
        )}
        <button onClick={submit} disabled={loading}
          style={{width:"100%",padding:"11px 0",background:"#6366f1",border:"none",borderRadius:8,
            color:"#fff",fontWeight:700,fontSize:14,cursor:"pointer",marginBottom:10,opacity:loading?0.7:1}}>
          {loading?"Please wait…":tab==="login"?"Login":"Create Account"}
        </button>
        <div style={{textAlign:"center",color:"#6b7280",fontSize:12,marginBottom:10}}>— or —</div>
        <button onClick={guestLogin} disabled={loading}
          style={{width:"100%",padding:"10px 0",background:"#252545",border:"1px solid #3a3a6a",
            borderRadius:8,color:"#9ca3af",fontWeight:600,fontSize:13,cursor:"pointer",opacity:loading?0.7:1}}>
          👤 Continue as Guest
        </button>
        <div style={{fontSize:11,color:"#4b5563",textAlign:"center",marginTop:8}}>
          Guest data is saved but tied to this browser only.
        </div>
      </div>
    </div>
  );
}
EOF

# ── src/App.js ───────────────────────────────────────────────────
cat > $FRONT/src/App.js << 'EOF'
import React, { useState, useEffect, useCallback, useRef } from "react";
import * as api from "./api";
import Login       from "./pages/Login";
import Home        from "./pages/Home";
import TopicList   from "./pages/TopicList";
import TopicDetail from "./pages/TopicDetail";
import Player      from "./pages/Player";
import Search      from "./pages/Search";
import Favorites   from "./pages/Favorites";
import Settings    from "./pages/Settings";
import MiniPlayer  from "./components/MiniPlayer";
import "./App.css";

export default function App() {
  const [user, setUser] = useState(() => {
    try { return JSON.parse(localStorage.getItem("tt_user")); } catch { return null; }
  });
  const [topics,        setTopics]        = useState([]);
  const [page,          setPage]          = useState("home");
  const [activeTopicId, setActiveTopicId] = useState(null);
  const [currentTrack,  setCurrentTrack]  = useState(null);
  const [isPlaying,     setIsPlaying]     = useState(false);
  const [queue,         setQueue]         = useState([]);
  const [queueIdx,      setQueueIdx]      = useState(0);
  const [shuffle,       setShuffle]       = useState(false);
  const [loop,          setLoop]          = useState("none");
  const [speed,         setSpeed]         = useState(1);
  const [audioMode,     setAudioMode]     = useState("audio");
  const [toast,         setToast]         = useState(null);
  const [sleepTimer,    setSleepTimer]    = useState(null);
  const sleepRef = useRef(null);

  useEffect(() => { if (user) loadTopics(); }, [user]);

  const loadTopics = async () => {
    try { const r = await api.getTopics(); setTopics(r.data); }
    catch (e) {
      if (e.response?.status === 401) handleLogout();
      else showToast("Cannot reach backend — is it running?", "error");
    }
  };

  const showToast = (msg, type="success") => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 2800);
  };

  const handleLogin  = (u) => { setUser(u); setPage("home"); };
  const handleLogout = () => {
    localStorage.removeItem("tt_token");
    localStorage.removeItem("tt_user");
    setUser(null); setTopics([]); setCurrentTrack(null); setQueue([]);
  };

  const playTrack = useCallback(async (track, trackList=null) => {
    setCurrentTrack(track);
    setIsPlaying(true);
    if (trackList && trackList.length > 0) {
      setQueue(trackList);
      setQueueIdx(trackList.findIndex(t => t.id === track.id));
    }
    try { await api.recordPlay(track.id); } catch (_) {}
    try { await api.startSession({ track_id: track.id, topic_id: track.topic_id }); } catch (_) {}
    setPage("player");
  }, []);

  const playNext = useCallback(() => {
    if (!queue.length) return;
    let idx;
    if (loop === "one")                    idx = queueIdx;
    else if (shuffle)                      idx = Math.floor(Math.random() * queue.length);
    else if (queueIdx + 1 >= queue.length) idx = loop === "all" ? 0 : -1;
    else                                   idx = queueIdx + 1;
    if (idx < 0) { setIsPlaying(false); return; }
    setQueueIdx(idx);
    playTrack(queue[idx], queue);
  }, [queue, queueIdx, shuffle, loop, playTrack]);

  const playPrev = useCallback(() => {
    if (!queue.length) return;
    const idx = Math.max(0, queueIdx - 1);
    setQueueIdx(idx);
    playTrack(queue[idx], queue);
  }, [queue, queueIdx, playTrack]);

  const startSleepTimer = (mins) => {
    if (sleepRef.current) clearTimeout(sleepRef.current);
    if (!mins) { setSleepTimer(null); return; }
    setSleepTimer(mins);
    sleepRef.current = setTimeout(() => {
      setIsPlaying(false); setSleepTimer(null);
      showToast("Sleep timer ended — playback paused");
    }, mins * 60000);
  };

  const nav = (p, topicId=null) => { setPage(p); if (topicId !== null) setActiveTopicId(topicId); };

  if (!user) return <Login onLogin={handleLogin} />;

  const activeTopic = topics.find(t => t.id === activeTopicId);
  const shared = { topics, loadTopics, nav, showToast, playTrack };

  return (
    <div className="app">
      {toast && <div className={`toast toast-${toast.type}`}>{toast.msg}</div>}
      <nav className="sidebar">
        <div className="logo" onClick={() => nav("home")}>🎵 TopicTune</div>
        {[{id:"home",label:"Home",icon:"🏠"},{id:"topics",label:"My Topics",icon:"📁"},
          {id:"search",label:"Search",icon:"🔍"},{id:"favorites",label:"Favorites",icon:"⭐"},
          {id:"settings",label:"Settings",icon:"⚙️"}].map(item => (
          <button key={item.id} className={`nav-btn ${page===item.id?"active":""}`} onClick={() => nav(item.id)}>
            <span>{item.icon}</span> {item.label}
          </button>
        ))}
        <div className="sidebar-divider" />
        <div className="sidebar-label">Topics</div>
        {topics.map(tp => (
          <button key={tp.id}
            className={`nav-btn topic-btn ${activeTopicId===tp.id&&page==="topic"?"active":""}`}
            onClick={() => nav("topic", tp.id)}>
            <span className="dot" /> {tp.name}
          </button>
        ))}
        <div className="sidebar-footer">
          <div style={{fontSize:12,color:"#6b7280",marginBottom:6}}>
            {user.is_guest?"👤 Guest":`👤 ${user.username}`}
          </div>
          <button onClick={handleLogout}
            style={{fontSize:11,color:"#ef4444",background:"transparent",border:"none",cursor:"pointer",padding:0}}>
            Logout
          </button>
        </div>
      </nav>
      <main className="main">
        {page==="home"      && <Home      {...shared} currentTrack={currentTrack} />}
        {page==="topics"    && <TopicList {...shared} />}
        {page==="topic"     && activeTopic && <TopicDetail {...shared} topicId={activeTopicId} currentTrack={currentTrack} />}
        {page==="player"    && <Player track={currentTrack} topics={topics}
            isPlaying={isPlaying} setIsPlaying={setIsPlaying}
            loop={loop} setLoop={setLoop} shuffle={shuffle} setShuffle={setShuffle}
            speed={speed} setSpeed={setSpeed} audioMode={audioMode} setAudioMode={setAudioMode}
            playNext={playNext} playPrev={playPrev} nav={nav} />}
        {page==="search"    && <Search    {...shared} />}
        {page==="favorites" && <Favorites {...shared} />}
        {page==="settings"  && <Settings audioMode={audioMode} setAudioMode={setAudioMode}
            speed={speed} setSpeed={setSpeed} loop={loop} setLoop={setLoop}
            shuffle={shuffle} setShuffle={setShuffle} sleepTimer={sleepTimer}
            startSleepTimer={startSleepTimer} user={user} onLogout={handleLogout} />}
      </main>
      {currentTrack && page !== "player" && (
        <MiniPlayer track={currentTrack} isPlaying={isPlaying} setIsPlaying={setIsPlaying}
          playNext={playNext} playPrev={playPrev} onClick={() => nav("player")} />
      )}
    </div>
  );
}
EOF

# ── src/pages/Home.js ────────────────────────────────────────────
cat > $FRONT/src/pages/Home.js << 'EOF'
import React, { useEffect, useState } from "react";
import * as api from "../api";

export default function Home({ topics, nav, playTrack }) {
  const [history, setHistory] = useState([]);
  useEffect(() => { api.getHistory(10).then(r=>setHistory(r.data)).catch(()=>{}); }, []);
  return (
    <div>
      <h2 className="page-title">Home</h2>
      <div className="section-title">My Topics</div>
      <div style={{display:"flex",gap:12,flexWrap:"wrap",marginBottom:8}}>
        {topics.length===0 && <p style={{color:"#6b7280",fontSize:13}}>No topics yet — go to My Topics to create one!</p>}
        {topics.map(tp=>(
          <div key={tp.id} onClick={()=>nav("topic",tp.id)}
            style={{width:140,cursor:"pointer",borderRadius:10,overflow:"hidden",
              background:"#1a1a2e",border:"1px solid #2a2a4a",transition:"transform .15s"}}
            onMouseOver={e=>e.currentTarget.style.transform="scale(1.03)"}
            onMouseOut={e=>e.currentTarget.style.transform="scale(1)"}>
            <div style={{height:76,background:"#252545",display:"flex",alignItems:"center",justifyContent:"center",fontSize:28}}>🎵</div>
            <div style={{padding:"8px 10px"}}>
              <div style={{fontSize:13,fontWeight:600}}>{tp.name}</div>
              <div style={{fontSize:11,color:"#9ca3af"}}>{tp.track_count??0} tracks</div>
            </div>
          </div>
        ))}
      </div>
      {history.length>0&&<>
        <div className="section-title" style={{marginTop:24}}>Recently Played</div>
        <div style={{display:"flex",flexDirection:"column",gap:7}}>
          {history.slice(0,6).map(t=>(
            <div key={t.id} className="track-item" onClick={()=>playTrack(t)}>
              <img className="track-thumb" src={t.thumbnail_url} alt="" />
              <div className="track-info">
                <div className="track-title">{t.title}</div>
                <div className="track-sub">{t.channel_name}</div>
              </div>
              {t.is_favorite&&<span style={{color:"#f59e0b"}}>★</span>}
            </div>
          ))}
        </div>
      </>}
    </div>
  );
}
EOF

# ── src/pages/TopicList.js ───────────────────────────────────────
cat > $FRONT/src/pages/TopicList.js << 'EOF'
import React, { useState } from "react";
import * as api from "../api";

export default function TopicList({ topics, loadTopics, nav, showToast }) {
  const [newName, setNewName] = useState("");
  const [editing, setEditing] = useState(null);
  const [editVal, setEditVal] = useState("");

  const create = async () => {
    if (!newName.trim()) return;
    try { await api.createTopic({name:newName.trim(),sort_order:topics.length}); setNewName(""); loadTopics(); showToast("Topic created ✓"); }
    catch { showToast("Failed to create topic","error"); }
  };
  const save = async (id) => {
    if (!editVal.trim()) { setEditing(null); return; }
    try { await api.updateTopic(id,{name:editVal.trim()}); setEditing(null); loadTopics(); }
    catch { showToast("Failed to rename","error"); }
  };
  const remove = async (id) => {
    if (!window.confirm("Delete this topic and all its tracks?")) return;
    try { await api.deleteTopic(id); loadTopics(); showToast("Topic deleted"); }
    catch { showToast("Failed to delete","error"); }
  };

  return (
    <div>
      <h2 className="page-title">My Topics</h2>
      <div style={{display:"flex",gap:8,marginBottom:20}}>
        <input value={newName} onChange={e=>setNewName(e.target.value)}
          onKeyDown={e=>e.key==="Enter"&&create()} placeholder="New topic name…"
          style={{flex:1,padding:"8px 12px",background:"#252545",border:"1px solid #3a3a6a",
            borderRadius:8,color:"#e0e0ff",fontSize:13,outline:"none"}} />
        <button className="btn btn-primary" onClick={create}>+ Create</button>
      </div>
      <div style={{display:"flex",flexDirection:"column",gap:10}}>
        {topics.map(tp=>(
          <div key={tp.id} className="card" style={{display:"flex",alignItems:"center",gap:12,padding:"12px 16px"}}>
            {editing===tp.id
              ? <input autoFocus value={editVal} onChange={e=>setEditVal(e.target.value)}
                  onBlur={()=>save(tp.id)} onKeyDown={e=>{if(e.key==="Enter")save(tp.id);if(e.key==="Escape")setEditing(null);}}
                  style={{flex:1,padding:"6px 10px",background:"#252545",border:"1px solid #6366f1",
                    borderRadius:6,color:"#e0e0ff",fontSize:13,outline:"none"}} />
              : <div style={{flex:1,cursor:"pointer"}} onClick={()=>nav("topic",tp.id)}>
                  <div style={{fontWeight:600}}>{tp.name}</div>
                  <div style={{fontSize:12,color:"#9ca3af"}}>{tp.track_count??0} tracks</div>
                </div>}
            <button className="btn-icon" onClick={()=>{setEditing(tp.id);setEditVal(tp.name);}}>✏️</button>
            <button className="btn-icon" style={{color:"#ef4444"}} onClick={()=>remove(tp.id)}>🗑</button>
          </div>
        ))}
      </div>
    </div>
  );
}
EOF

# ── src/pages/TopicDetail.js ─────────────────────────────────────
cat > $FRONT/src/pages/TopicDetail.js << 'EOF'
import React, { useEffect, useState, useCallback } from "react";
import * as api from "../api";

export default function TopicDetail({ topicId, topics, playTrack, currentTrack, showToast, loadTopics, nav }) {
  const [tracks,     setTracks]     = useState([]);
  const [recs,       setRecs]       = useState([]);
  const [recLoading, setRecLoading] = useState(false);
  const [recError,   setRecError]   = useState("");
  const [showAdd,    setShowAdd]    = useState(false);
  const [addUrl,     setAddUrl]     = useState("");
  const [addTitle,   setAddTitle]   = useState("");
  const [addCh,      setAddCh]      = useState("");
  const [moveMenu,   setMoveMenu]   = useState(null);
  const topic = topics.find(t=>t.id===topicId);

  const loadTracks = useCallback(()=>{
    if (!topicId) return;
    api.getTracks({topic_id:topicId}).then(r=>setTracks(r.data)).catch(()=>{});
  },[topicId]);

  useEffect(()=>{ loadTracks(); },[loadTracks]);

  const extractId = (url) => { const m=url.match(/(?:v=|youtu\.be\/)([A-Za-z0-9_-]{11})/); return m?m[1]:null; };

  const submitAdd = async () => {
    const vid=extractId(addUrl.trim());
    if (!vid) { showToast("Invalid YouTube URL","error"); return; }
    try {
      await api.addTrack({youtube_video_id:vid,title:addTitle.trim()||`Video (${vid})`,channel_name:addCh.trim()||"Unknown",topic_id:topicId});
      setAddUrl(""); setAddTitle(""); setAddCh(""); setShowAdd(false);
      loadTracks(); loadTopics(); showToast("Track added ✓");
    } catch(e) { showToast(e.response?.data?.detail||"Failed to add track","error"); }
  };

  const getAIRecs = async () => {
    setRecLoading(true); setRecError(""); setRecs([]);
    try {
      const r=await api.getAIRecs({topic_name:topic.name,topic_description:topic.description||"",
        existing_tracks:tracks.map(t=>({title:t.title,channelName:t.channel_name})),mode:"topic"});
      setRecs(r.data);
    } catch(e) { setRecError(e.response?.data?.detail||"Could not load AI recs. Check ANTHROPIC_API_KEY in backend/.env"); }
    setRecLoading(false);
  };

  const addRec = async (rec) => {
    try {
      await api.addTrack({youtube_video_id:rec.youtube_video_id,title:rec.title,
        channel_name:rec.channelName,thumbnail_url:rec.thumbnail_url,topic_id:topicId});
      setRecs(prev=>prev.filter(r=>r.youtube_video_id!==rec.youtube_video_id));
      loadTracks(); loadTopics(); showToast(`"${rec.title}" added ✓`);
    } catch(e) { showToast(e.response?.data?.detail||"Already added","warn"); }
  };

  const toggleFav  = async (t) => { await api.updateTrack(t.id,{is_favorite:!t.is_favorite}); loadTracks(); };
  const remove     = async (id) => { await api.deleteTrack(id); loadTracks(); loadTopics(); showToast("Track removed"); };
  const moveTrack  = async (t,tid) => { await api.updateTrack(t.id,{topic_id:tid}); loadTracks(); loadTopics(); setMoveMenu(null); showToast("Moved ✓"); };

  const INP={width:"100%",marginBottom:8,padding:"8px 12px",background:"#252545",
    border:"1px solid #3a3a6a",borderRadius:8,color:"#e0e0ff",fontSize:13,outline:"none",boxSizing:"border-box"};

  if (!topic) return <div style={{color:"#6b7280",padding:20}}>Topic not found.</div>;

  return (
    <div>
      <button onClick={()=>nav("topics")}
        style={{display:"flex",alignItems:"center",gap:6,background:"#252545",border:"none",
          borderRadius:8,padding:"6px 14px",color:"#9ca3af",cursor:"pointer",fontSize:12,marginBottom:16}}>
        ← Back to Topics
      </button>
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",marginBottom:20}}>
        <div>
          <h2 className="page-title" style={{marginBottom:4}}>{topic.name}</h2>
          {topic.description&&<div style={{fontSize:13,color:"#9ca3af",marginBottom:4}}>{topic.description}</div>}
          <span style={{fontSize:12,color:"#6b7280"}}>{tracks.length} tracks</span>
        </div>
        <div style={{display:"flex",gap:8,flexShrink:0}}>
          {tracks.length>0&&<button className="btn btn-primary" onClick={()=>playTrack(tracks[0],tracks)}>▶ Play All</button>}
          <button className="btn btn-secondary" onClick={()=>setShowAdd(!showAdd)}>+ Add Track</button>
        </div>
      </div>
      {showAdd&&(
        <div className="card" style={{padding:16,marginBottom:16}}>
          <div style={{fontWeight:600,marginBottom:12,color:"#a78bfa"}}>Add YouTube Track</div>
          <input value={addUrl} onChange={e=>setAddUrl(e.target.value)} placeholder="YouTube URL *" style={INP} />
          <input value={addTitle} onChange={e=>setAddTitle(e.target.value)} placeholder="Title (optional)" style={INP} />
          <input value={addCh} onChange={e=>setAddCh(e.target.value)} placeholder="Channel (optional)" style={{...INP,marginBottom:12}} />
          <div style={{display:"flex",gap:8}}>
            <button className="btn btn-primary" onClick={submitAdd}>Add</button>
            <button className="btn btn-secondary" onClick={()=>setShowAdd(false)}>Cancel</button>
          </div>
        </div>
      )}
      {tracks.length===0&&!showAdd&&(
        <div style={{textAlign:"center",padding:40,color:"#6b7280"}}>
          <div style={{fontSize:36,marginBottom:8}}>🎵</div>
          <div>No tracks yet. Click "+ Add Track" to get started.</div>
        </div>
      )}
      <div style={{display:"flex",flexDirection:"column",gap:8,marginBottom:24}}>
        {tracks.map((t,i)=>(
          <div key={t.id} className={`track-item ${currentTrack?.id===t.id?"active":""}`} onClick={()=>playTrack(t,tracks)}>
            <span style={{color:"#6b7280",fontSize:12,width:18,textAlign:"center",flexShrink:0}}>{i+1}</span>
            <img className="track-thumb" src={t.thumbnail_url} alt=""
              onError={e=>e.target.src=`https://img.youtube.com/vi/${t.youtube_video_id}/mqdefault.jpg`} />
            <div className="track-info">
              <div className="track-title">{t.title}</div>
              <div className="track-sub">{t.channel_name}</div>
            </div>
            <button className="btn-icon" style={{color:t.is_favorite?"#f59e0b":"#6b7280"}}
              onClick={e=>{e.stopPropagation();toggleFav(t);}}>{t.is_favorite?"★":"☆"}</button>
            <div style={{position:"relative"}} onClick={e=>e.stopPropagation()}>
              <button className="btn-icon" onClick={()=>setMoveMenu(moveMenu===t.id?null:t.id)}>⇄</button>
              {moveMenu===t.id&&(
                <div style={{position:"absolute",right:0,top:30,background:"#252545",
                  border:"1px solid #3a3a6a",borderRadius:8,zIndex:100,minWidth:160}}>
                  <div style={{padding:"6px 12px",fontSize:11,color:"#9ca3af",borderBottom:"1px solid #3a3a6a"}}>Move to…</div>
                  {topics.filter(tp=>tp.id!==topicId).map(tp=>(
                    <button key={tp.id} onClick={()=>moveTrack(t,tp.id)}
                      style={{display:"block",width:"100%",padding:"8px 14px",background:"transparent",
                        border:"none",color:"#e0e0ff",cursor:"pointer",textAlign:"left",fontSize:13}}>{tp.name}</button>
                  ))}
                  {topics.filter(tp=>tp.id!==topicId).length===0&&(
                    <div style={{padding:"8px 14px",fontSize:12,color:"#6b7280"}}>No other topics</div>
                  )}
                </div>
              )}
            </div>
            <button className="btn-icon" style={{color:"#ef4444"}} onClick={e=>{e.stopPropagation();remove(t.id);}}>🗑</button>
          </div>
        ))}
      </div>
      <div style={{borderTop:"1px solid #2a2a4a",paddingTop:20}}>
        <div style={{display:"flex",alignItems:"center",justifyContent:"space-between",marginBottom:12}}>
          <h3 style={{margin:0,fontSize:15,color:"#a78bfa"}}>✨ AI Recommendations</h3>
          <button className="btn btn-primary btn-xs" onClick={getAIRecs} disabled={recLoading} style={{fontSize:12}}>
            {recLoading?"🤔 Thinking…":"🤖 Get AI Recs"}
          </button>
        </div>
        {recError&&<div style={{color:"#f87171",fontSize:13,marginBottom:10,background:"#2d1010",padding:"8px 12px",borderRadius:8}}>{recError}</div>}
        {recs.length===0&&!recLoading&&!recError&&(
          <div style={{fontSize:13,color:"#6b7280"}}>Click "Get AI Recs" for recommendations based on "{topic.name}".</div>
        )}
        <div style={{display:"flex",flexDirection:"column",gap:8}}>
          {recs.map(rec=>(
            <div key={rec.youtube_video_id} style={{display:"flex",alignItems:"center",gap:10,padding:"10px 14px",
              background:"#12122a",borderRadius:10,border:"1px solid #2a2a4a"}}>
              <img src={rec.thumbnail_url} alt="" style={{width:52,height:38,objectFit:"cover",borderRadius:5,flexShrink:0}}
                onError={e=>e.target.style.display="none"} />
              <div className="track-info">
                <div className="track-title">{rec.title}</div>
                <div className="track-sub">{rec.channelName} · <span style={{color:"#818cf8"}}>{rec.reason}</span></div>
              </div>
              <button className="btn btn-primary btn-xs" onClick={()=>addRec(rec)}>+ Add</button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
EOF

# ── src/pages/Player.js ──────────────────────────────────────────
cat > $FRONT/src/pages/Player.js << 'EOF'
import React, { useEffect, useRef } from "react";

export default function Player({ track, topics, isPlaying, setIsPlaying, loop, setLoop,
  shuffle, setShuffle, speed, setSpeed, audioMode, setAudioMode, playNext, playPrev, nav }) {

  const topic    = topics.find(t=>t?.id===track?.topic_id);
  const divRef   = useRef(null);
  const playerRef= useRef(null);
  const loadedId = useRef(null);
  const nextLoop = {none:"all",all:"one",one:"none"};
  const loopLabel= loop==="none"?"↩ Off":loop==="all"?"🔁 All":"🔂 One";

  useEffect(()=>{
    if (document.getElementById("yt-iframe-api")) return;
    const tag=document.createElement("script");
    tag.id="yt-iframe-api"; tag.src="https://www.youtube.com/iframe_api";
    document.head.appendChild(tag);
  },[]);

  useEffect(()=>{
    if (!track?.youtube_video_id) return;
    if (loadedId.current===track.youtube_video_id) return;
    loadedId.current=track.youtube_video_id;
    const init=()=>{
      if (!divRef.current) return;
      if (playerRef.current) { try{playerRef.current.destroy();}catch(_){} playerRef.current=null; }
      playerRef.current=new window.YT.Player(divRef.current,{
        videoId:track.youtube_video_id,
        playerVars:{autoplay:1,rel:0,modestbranding:1},
        events:{
          onReady:(e)=>{e.target.playVideo();setIsPlaying(true);},
          onStateChange:(e)=>{
            if(e.data===0)playNext();
            if(e.data===1)setIsPlaying(true);
            if(e.data===2)setIsPlaying(false);
          },
        },
      });
    };
    if (window.YT&&window.YT.Player) init();
    else { const p=window.onYouTubeIframeAPIReady; window.onYouTubeIframeAPIReady=()=>{if(p)p();init();}; }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  },[track?.youtube_video_id]);

  const handlePlayPause=()=>{
    if (!playerRef.current) return;
    if (isPlaying) playerRef.current.pauseVideo(); else playerRef.current.playVideo();
  };

  if (!track) return (
    <div style={{textAlign:"center",padding:80,color:"#6b7280"}}>
      <div style={{fontSize:56,marginBottom:16}}>🎵</div>
      <div style={{fontSize:16}}>No track selected — pick something to play!</div>
    </div>
  );

  return (
    <div style={{maxWidth:640,margin:"0 auto"}}>
      {topic&&(
        <button onClick={()=>nav("topic",topic.id)}
          style={{display:"flex",alignItems:"center",gap:6,background:"#252545",border:"none",
            borderRadius:8,padding:"6px 14px",color:"#9ca3af",cursor:"pointer",fontSize:12,marginBottom:16}}>
          ← Back to {topic.name}
        </button>
      )}
      <h2 className="page-title">Now Playing</h2>
      <div style={{display:"flex",gap:6,marginBottom:16}}>
        {[["video","🎬 Video"],["audio","🎵 Audio"],["hidden","🙈 Hidden"]].map(([m,l])=>(
          <button key={m} onClick={()=>setAudioMode(m)}
            style={{background:audioMode===m?"#6366f1":"#252545",border:"none",borderRadius:8,
              padding:"5px 12px",color:"#fff",cursor:"pointer",fontSize:12,fontWeight:500}}>{l}</button>
        ))}
      </div>
      {audioMode==="video"&&(
        <div style={{position:"relative",paddingTop:"56.25%",borderRadius:12,overflow:"hidden",marginBottom:16,background:"#000"}}>
          <div ref={divRef} style={{position:"absolute",top:0,left:0,width:"100%",height:"100%"}} />
        </div>
      )}
      {audioMode==="audio"&&(
        <div style={{display:"flex",gap:14,alignItems:"flex-start",marginBottom:16}}>
          <div style={{width:240,height:135,borderRadius:10,overflow:"hidden",background:"#000",flexShrink:0,border:"2px solid #6366f1"}}>
            <div ref={divRef} style={{width:"100%",height:"100%"}} />
          </div>
          <div style={{paddingTop:4,minWidth:0}}>
            <div style={{fontWeight:700,fontSize:15,marginBottom:4,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{track.title}</div>
            <div style={{color:"#9ca3af",fontSize:13,marginBottom:4}}>{track.channel_name}</div>
            {topic&&<div style={{color:"#6366f1",fontSize:12}}>📁 {topic.name}</div>}
            <div style={{fontSize:11,color:"#6b7280",marginTop:6}}>🎵 Mini video playing</div>
          </div>
        </div>
      )}
      {audioMode==="hidden"&&(
        <div style={{position:"fixed",left:"-9999px",top:0,width:1,height:1,overflow:"hidden"}}>
          <div ref={divRef} style={{width:1,height:1}} />
        </div>
      )}
      {audioMode==="hidden"&&(
        <div className="card" style={{display:"flex",gap:16,alignItems:"center",padding:16,marginBottom:16}}>
          <img src={track.thumbnail_url} alt="" style={{width:90,height:64,objectFit:"cover",borderRadius:8}} />
          <div>
            <div style={{fontWeight:700,fontSize:16}}>{track.title}</div>
            <div style={{color:"#9ca3af",fontSize:13}}>{track.channel_name}</div>
            {topic&&<div style={{color:"#6366f1",fontSize:12,marginTop:4}}>📁 {topic.name}</div>}
            <div style={{fontSize:11,color:"#6b7280",marginTop:4}}>🙈 Video hidden — audio playing</div>
          </div>
        </div>
      )}
      <div className="card" style={{padding:"16px 20px",marginBottom:16}}>
        <div style={{marginBottom:12}}>
          <div style={{fontWeight:700,fontSize:15,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{track.title}</div>
          <div style={{color:"#9ca3af",fontSize:13}}>{track.channel_name}{topic?` · ${topic.name}`:""}</div>
        </div>
        <div style={{display:"flex",alignItems:"center",justifyContent:"center",gap:18,marginBottom:14}}>
          <button className="btn-icon" style={{color:shuffle?"#818cf8":"#6b7280",fontSize:18}}
            onClick={()=>setShuffle(!shuffle)}>⇀</button>
          <button className="btn-icon" style={{fontSize:22}} onClick={playPrev}>⏮</button>
          <button onClick={handlePlayPause}
            style={{background:"#6366f1",border:"none",borderRadius:"50%",width:48,height:48,
              fontSize:20,cursor:"pointer",color:"#fff",display:"flex",alignItems:"center",justifyContent:"center"}}>
            {isPlaying?"⏸":"▶"}
          </button>
          <button className="btn-icon" style={{fontSize:22}} onClick={playNext}>⏭</button>
          <button className="btn-icon" style={{color:loop!=="none"?"#818cf8":"#6b7280",fontSize:13}}
            onClick={()=>setLoop(nextLoop[loop])}>{loopLabel}</button>
        </div>
        <div style={{display:"flex",alignItems:"center",gap:6,flexWrap:"wrap"}}>
          <span style={{fontSize:12,color:"#9ca3af",marginRight:4}}>Speed:</span>
          {[0.75,1,1.25,1.5,2].map(s=>(
            <button key={s} onClick={()=>setSpeed(s)}
              style={{background:speed===s?"#6366f1":"#252545",border:"none",borderRadius:6,
                padding:"2px 9px",color:"#fff",cursor:"pointer",fontSize:11,fontWeight:500}}>{s}x</button>
          ))}
        </div>
      </div>
    </div>
  );
}
EOF

# ── src/pages/Search.js ──────────────────────────────────────────
cat > $FRONT/src/pages/Search.js << 'EOF'
import React, { useState } from "react";
import * as api from "../api";

export default function Search({ topics, playTrack, showToast }) {
  const [q,        setQ]        = useState("");
  const [tab,      setTab]      = useState("library");
  const [libRes,   setLibRes]   = useState([]);
  const [ytRes,    setYtRes]    = useState([]);
  const [loading,  setLoading]  = useState(false);
  const [searched, setSearched] = useState(false);
  const [selTopic, setSelTopic] = useState(topics[0]?.id||"");

  const doSearch = async () => {
    if (!q.trim()) return;
    setSearched(true);
    if (tab==="library") {
      try { const r=await api.getTracks({search:q.trim()}); setLibRes(r.data); }
      catch { showToast("Library search failed","error"); }
    } else {
      setLoading(true); setYtRes([]);
      try { const r=await api.youtubeSearch(q.trim(),12); setYtRes(r.data); }
      catch(e) { showToast(e.response?.data?.detail||"YouTube search failed","error"); }
      setLoading(false);
    }
  };

  const addYt = async (item) => {
    const topicId=selTopic||topics[0]?.id;
    if (!topicId) { showToast("Create a topic first","warn"); return; }
    try {
      await api.addTrack({youtube_video_id:item.youtube_video_id,title:item.title,
        channel_name:item.channelName,thumbnail_url:item.thumbnail_url,
        duration:item.duration||0,topic_id:topicId});
      showToast(`"${item.title}" added ✓`);
    } catch(e) { showToast(e.response?.data?.detail||"Already in this topic","warn"); }
  };

  const results=tab==="library"?libRes:ytRes;

  return (
    <div>
      <h2 className="page-title">Search</h2>
      <div style={{display:"flex",gap:8,marginBottom:14}}>
        {[["library","📚 My Library"],["youtube","▶️ YouTube"]].map(([id,l])=>(
          <button key={id} onClick={()=>{setTab(id);setSearched(false);}}
            style={{background:tab===id?"#6366f1":"#252545",border:"none",borderRadius:8,
              padding:"7px 16px",color:"#fff",cursor:"pointer",fontSize:13,fontWeight:500}}>{l}</button>
        ))}
      </div>
      <div style={{display:"flex",gap:8,marginBottom:16}}>
        <input value={q} onChange={e=>setQ(e.target.value)} onKeyDown={e=>e.key==="Enter"&&doSearch()}
          placeholder={tab==="library"?"Search your saved tracks…":"Search YouTube for music…"}
          style={{flex:1,padding:"8px 12px",background:"#252545",border:"1px solid #3a3a6a",
            borderRadius:8,color:"#e0e0ff",fontSize:13,outline:"none"}} />
        <button onClick={doSearch} disabled={loading}
          style={{background:"#6366f1",border:"none",borderRadius:8,padding:"7px 16px",
            color:"#fff",cursor:"pointer",fontSize:13,fontWeight:500,opacity:loading?0.6:1}}>
          {loading?"Searching…":"Search"}
        </button>
      </div>
      {tab==="youtube"&&topics.length>0&&(
        <div style={{display:"flex",alignItems:"center",gap:8,marginBottom:16}}>
          <span style={{fontSize:13,color:"#9ca3af"}}>Add results to:</span>
          <select value={selTopic} onChange={e=>setSelTopic(e.target.value)}
            style={{padding:"6px 10px",background:"#252545",border:"1px solid #3a3a6a",
              borderRadius:8,color:"#e0e0ff",fontSize:13,outline:"none"}}>
            {topics.map(tp=><option key={tp.id} value={tp.id}>{tp.name}</option>)}
          </select>
        </div>
      )}
      {searched&&results.length===0&&!loading&&(
        <div style={{color:"#6b7280",textAlign:"center",padding:40}}>
          {tab==="youtube"?"No results. Try different keywords.":"No tracks found in your library."}
        </div>
      )}
      <div style={{display:"flex",flexDirection:"column",gap:8}}>
        {results.map(item=>{
          const key=item.youtube_video_id||item.id;
          const topicName=topics.find(tp=>tp.id===item.topic_id)?.name;
          const dur=item.duration>0?`${Math.floor(item.duration/60)}:${String(item.duration%60).padStart(2,"0")}`:null;
          return (
            <div key={key} style={{display:"flex",alignItems:"center",gap:10,padding:"9px 14px",
              background:"#1a1a2e",borderRadius:10,border:"1px solid #2a2a4a"}}>
              <img src={item.thumbnail_url||`https://img.youtube.com/vi/${item.youtube_video_id}/mqdefault.jpg`}
                alt="" style={{width:52,height:38,objectFit:"cover",borderRadius:5,flexShrink:0}} />
              <div className="track-info">
                <div className="track-title">{item.title}</div>
                <div className="track-sub">
                  {item.channelName||item.channel_name}
                  {topicName&&` · ${topicName}`}
                  {dur&&` · ${dur}`}
                </div>
              </div>
              {tab==="library"
                ? <button onClick={()=>playTrack(item)} style={{background:"#6366f1",border:"none",borderRadius:8,
                    padding:"3px 10px",color:"#fff",cursor:"pointer",fontSize:11,fontWeight:500,flexShrink:0}}>▶ Play</button>
                : <button onClick={()=>addYt(item)} style={{background:"#4f46e5",border:"none",borderRadius:8,
                    padding:"3px 10px",color:"#fff",cursor:"pointer",fontSize:11,fontWeight:500,flexShrink:0}}>+ Add</button>}
            </div>
          );
        })}
      </div>
    </div>
  );
}
EOF

# ── src/pages/Favorites.js ───────────────────────────────────────
cat > $FRONT/src/pages/Favorites.js << 'EOF'
import React, { useEffect, useState } from "react";
import * as api from "../api";

export default function Favorites({ topics, playTrack }) {
  const [tab,  setTab]  = useState("favs");
  const [favs, setFavs] = useState([]);
  const [hist, setHist] = useState([]);
  useEffect(()=>{
    api.getTracks({favorites_only:true}).then(r=>setFavs(r.data)).catch(()=>{});
    api.getHistory(30).then(r=>setHist(r.data)).catch(()=>{});
  },[]);
  const list=tab==="favs"?favs:hist;
  return (
    <div>
      <h2 className="page-title">{tab==="favs"?"Favorites":"Recently Played"}</h2>
      <div style={{display:"flex",gap:8,marginBottom:16}}>
        {[["favs","⭐ Favorites"],["history","🕐 History"]].map(([id,l])=>(
          <button key={id}
            style={{background:tab===id?"#6366f1":"#252545",border:"none",borderRadius:8,
              padding:"7px 16px",color:"#fff",cursor:"pointer",fontSize:13,fontWeight:500}}
            onClick={()=>setTab(id)}>{l}</button>
        ))}
      </div>
      {list.length===0&&<div style={{color:"#6b7280",textAlign:"center",padding:40}}>Nothing here yet.</div>}
      <div style={{display:"flex",flexDirection:"column",gap:8}}>
        {list.map(t=>{
          const topic=topics.find(tp=>tp.id===t.topic_id);
          return (
            <div key={t.id} className="track-item" onClick={()=>playTrack(t)}>
              <img className="track-thumb" src={t.thumbnail_url} alt="" />
              <div className="track-info">
                <div className="track-title">{t.title}</div>
                <div className="track-sub">{t.channel_name}{topic?` · ${topic.name}`:""}</div>
              </div>
              {t.is_favorite&&<span style={{color:"#f59e0b"}}>★</span>}
            </div>
          );
        })}
      </div>
    </div>
  );
}
EOF

# ── src/pages/Settings.js ────────────────────────────────────────
cat > $FRONT/src/pages/Settings.js << 'EOF'
import React from "react";
const Row=({label,children})=>(
  <div style={{display:"flex",alignItems:"center",justifyContent:"space-between",
    padding:"12px 16px",borderBottom:"1px solid #2a2a4a"}}>
    <span style={{fontSize:13,color:"#d1d5db"}}>{label}</span>
    <div style={{display:"flex",gap:4,flexWrap:"wrap",justifyContent:"flex-end"}}>{children}</div>
  </div>
);
const Group=({title,children})=>(
  <div style={{marginBottom:24}}>
    <div style={{fontSize:11,color:"#a78bfa",fontWeight:600,marginBottom:8,textTransform:"uppercase",letterSpacing:.5}}>{title}</div>
    <div className="card">{children}</div>
  </div>
);
export default function Settings({audioMode,setAudioMode,speed,setSpeed,loop,setLoop,
  shuffle,setShuffle,sleepTimer,startSleepTimer,user,onLogout}) {
  return (
    <div style={{maxWidth:520}}>
      <h2 className="page-title">Settings</h2>
      <Group title="Playback">
        <Row label="Default Mode">
          {[["video","Video"],["audio","Audio"],["hidden","Hidden"]].map(([m,l])=>(
            <button key={m} className={`btn btn-xs ${audioMode===m?"btn-primary":"btn-secondary"}`}
              onClick={()=>setAudioMode(m)}>{l}</button>
          ))}
        </Row>
        <Row label="Speed">
          {[0.75,1,1.25,1.5,2].map(s=>(
            <button key={s} className={`btn btn-xs ${speed===s?"btn-primary":"btn-secondary"}`}
              onClick={()=>setSpeed(s)}>{s}x</button>
          ))}
        </Row>
        <Row label="Loop">
          {[["none","Off"],["all","All"],["one","One"]].map(([v,l])=>(
            <button key={v} className={`btn btn-xs ${loop===v?"btn-primary":"btn-secondary"}`}
              onClick={()=>setLoop(v)}>{l}</button>
          ))}
        </Row>
        <Row label="Shuffle">
          <button className={`btn btn-xs ${shuffle?"btn-primary":"btn-secondary"}`}
            onClick={()=>setShuffle(!shuffle)}>{shuffle?"On":"Off"}</button>
        </Row>
      </Group>
      <Group title="Sleep Timer">
        <Row label="Stop after">
          {[null,15,30,45,60].map(m=>(
            <button key={m??0} className={`btn btn-xs ${sleepTimer===m?"btn-primary":"btn-secondary"}`}
              onClick={()=>startSleepTimer(m)}>{m?`${m}m`:"Off"}</button>
          ))}
        </Row>
      </Group>
      <Group title="Account">
        <Row label="Logged in as">
          <span style={{color:"#9ca3af",fontSize:13}}>{user?.is_guest?"👤 Guest":`👤 ${user?.username}`}</span>
        </Row>
        <Row label="Sign out">
          <button className="btn btn-xs btn-danger" onClick={onLogout}>Logout</button>
        </Row>
      </Group>
      <Group title="About">
        <Row label="Version"><span style={{color:"#6b7280",fontSize:13}}>TopicTune v2.0</span></Row>
        <Row label="Backend"><span style={{color:"#6b7280",fontSize:13}}>http://localhost:8000</span></Row>
        <Row label="API Docs"><span style={{color:"#6366f1",fontSize:13}}>http://localhost:8000/docs</span></Row>
      </Group>
    </div>
  );
}
EOF

# ── src/components/MiniPlayer.js ─────────────────────────────────
cat > $FRONT/src/components/MiniPlayer.js << 'EOF'
import React from "react";
export default function MiniPlayer({track,isPlaying,setIsPlaying,playNext,playPrev,onClick}) {
  if (!track) return null;
  return (
    <div className="mini-player" onClick={onClick} style={{cursor:"pointer"}}>
      <img src={track.thumbnail_url} alt="" style={{width:42,height:30,objectFit:"cover",borderRadius:4,flexShrink:0}} />
      <div style={{flex:1,minWidth:0}}>
        <div style={{fontSize:13,fontWeight:600,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{track.title}</div>
        <div style={{fontSize:11,color:"#9ca3af"}}>{track.channel_name}</div>
      </div>
      <button className="btn-icon" style={{fontSize:18}} onClick={e=>{e.stopPropagation();playPrev();}}>⏮</button>
      <button onClick={e=>{e.stopPropagation();setIsPlaying(!isPlaying);}}
        style={{background:"#6366f1",border:"none",borderRadius:"50%",width:36,height:36,
          fontSize:16,cursor:"pointer",color:"#fff",display:"flex",alignItems:"center",justifyContent:"center",flexShrink:0}}>
        {isPlaying?"⏸":"▶"}
      </button>
      <button className="btn-icon" style={{fontSize:18}} onClick={e=>{e.stopPropagation();playNext();}}>⏭</button>
    </div>
  );
}
EOF

# ================================================================
#  start.sh — fully portable, no hardcoded paths
# ================================================================
cat > $ROOT/start.sh << 'EOF'
#!/bin/bash
# ================================================================
#  TopicTune start script — works from any directory
#  Just run: ./start.sh  (from inside the project folder)
# ================================================================

# Resolve project root from wherever this script lives
ROOT="$(cd "$(dirname "$0")" && pwd)"
BACK="$ROOT/backend"
FRONT="$ROOT/frontend"

echo ""
echo "🎵  Starting TopicTune from: $ROOT"
echo ""

# Kill anything on ports 3000/8000
lsof -ti:8000 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
sleep 1

# ── Backend ───────────────────────────────────────────────────────
cd "$BACK"
source "$BACK/venv/bin/activate"
uvicorn main:app --host 0.0.0.0 --port 8000 &
BACK_PID=$!
echo "✅  Backend  → http://localhost:8000"
echo "📖  API Docs → http://localhost:8000/docs"

# ── Frontend ──────────────────────────────────────────────────────
cd "$FRONT"
BROWSER=none npm start &
FRONT_PID=$!
echo "✅  Frontend → http://localhost:3000 (starting...)"
echo ""

sleep 8 && open http://localhost:3000 &

echo "Press Ctrl+C to stop."
trap "echo 'Stopping...'; kill $BACK_PID $FRONT_PID 2>/dev/null; exit" INT TERM
wait
EOF
chmod +x $ROOT/start.sh

# ================================================================
#  rebuild_venv.sh — run this if you move the project folder
# ================================================================
cat > $ROOT/rebuild_venv.sh << 'EOF'
#!/bin/bash
# Run this any time you move the project to a new folder.
# It rebuilds the Python venv with correct paths for the new location.

ROOT="$(cd "$(dirname "$0")" && pwd)"
BACK="$ROOT/backend"

echo "🔧 Rebuilding Python venv at: $BACK"
cd "$BACK"
rm -rf venv
python3 -m venv venv
source venv/bin/activate
pip install -q \
  fastapi "uvicorn[standard]" sqlalchemy pydantic \
  python-multipart httpx python-dotenv \
  "python-jose[cryptography]" bcrypt yt-dlp
echo "✅  Done. Run ./start.sh to launch the app."
EOF
chmod +x $ROOT/rebuild_venv.sh

echo ""
echo "✅ =================================================="
echo "   TopicTune installed at: $ROOT"
echo ""
echo "   ⚠️  REQUIRED — edit your API keys:"
echo "   nano $BACK/.env"
echo ""
echo "   Set these two lines:"
echo "   ANTHROPIC_API_KEY=sk-ant-your-real-key"
echo "   SECRET_KEY=any_random_32+_char_string"
echo ""
echo "   Then start the app:"
echo "   $ROOT/start.sh"
echo ""
echo "   If you MOVE the project folder later:"
echo "   cd /new/path/topictune"
echo "   ./rebuild_venv.sh"
echo "   ./start.sh"
echo "=================================================="
