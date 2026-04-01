#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  TopicTune — Complete Portable Electron Desktop App
#  • 完全便携：脚本放哪里，项目就装在旁边，无硬编码路径
#  • 所有功能正常：播放/暂停/下一首/上一首/速度/循环/随机/睡眠定时器
#  • Video / Audio / Hidden 三种模式
#  • Topics 管理、Track 管理、收藏、搜索、Idea Pool、AI 推荐
#  • 多用户登录 + Guest 模式
#  • YouTube BrowserView（Electron 内置，无嵌入限制）
#
#  用法:
#    chmod +x topictune_electron.sh
#    ./topictune_electron.sh
#    然后: cd topictune && ./start.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── 完全便携：ROOT 永远在脚本旁边 ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/topictune"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║     TopicTune Electron Desktop App Setup         ║"
echo "╚══════════════════════════════════════════════════╝"
echo "安装目录: $ROOT"
echo ""

# ── 检查依赖 ──────────────────────────────────────────────────────────────────
for cmd in python3 node npm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ 缺少 '$cmd'，请先安装: brew install node python@3.11"
    exit 1
  fi
done
echo "✅ Python $(python3 --version 2>&1 | awk '{print $2}')"
echo "✅ Node $(node --version)"
echo "✅ npm $(npm --version)"
echo ""

# ── 清除旧安装 ────────────────────────────────────────────────────────────────
if [ -d "$ROOT" ]; then
  echo "🗑  清除旧目录 $ROOT ..."
  rm -rf "$ROOT"
fi
mkdir -p "$ROOT"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: FASTAPI BACKEND
# ═══════════════════════════════════════════════════════════════════════════════
echo "── [1/4] FastAPI 后端 ──────────────────────────────────────────────────────"
mkdir -p "$ROOT/backend/routers"

python3 -m venv "$ROOT/backend/venv"
source "$ROOT/backend/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet \
  fastapi "uvicorn[standard]" sqlalchemy python-multipart \
  httpx python-dotenv "python-jose[cryptography]" bcrypt yt-dlp
deactivate
echo "✅ Python 包安装完成"

# ── .env ──────────────────────────────────────────────────────────────────────
cat > "$ROOT/backend/.env" << 'EOF'
ANTHROPIC_API_KEY=your_anthropic_api_key_here
SECRET_KEY=please_change_this_to_any_random_32char_string
ACCESS_TOKEN_EXPIRE_MINUTES=43200
EOF

# ── database.py ───────────────────────────────────────────────────────────────
cat > "$ROOT/backend/database.py" << 'EOF'
from pathlib import Path
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

DB_PATH = Path(__file__).parent / "topictune.db"
engine = create_engine(
    f"sqlite:///{DB_PATH}",
    connect_args={"check_same_thread": False},
    pool_size=10,
    max_overflow=20,
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

# ── models.py ─────────────────────────────────────────────────────────────────
cat > "$ROOT/backend/models.py" << 'EOF'
import uuid
from datetime import datetime
from sqlalchemy import Column, String, Boolean, Integer, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from database import Base

def nid(): return str(uuid.uuid4())[:12]

class User(Base):
    __tablename__ = "users"
    id              = Column(String, primary_key=True, default=nid)
    username        = Column(String, unique=True, nullable=False, index=True)
    email           = Column(String, nullable=True)
    hashed_password = Column(String, nullable=False)
    is_guest        = Column(Boolean, default=False)
    created_at      = Column(DateTime, default=datetime.utcnow)
    topics          = relationship("Topic",   back_populates="user", cascade="all, delete-orphan")
    tracks          = relationship("Track",   back_populates="user", cascade="all, delete-orphan")
    history         = relationship("History", back_populates="user", cascade="all, delete-orphan")

class Topic(Base):
    __tablename__ = "topics"
    id          = Column(String, primary_key=True, default=nid)
    user_id     = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    name        = Column(String, nullable=False)
    description = Column(String, default="")
    created_at  = Column(DateTime, default=datetime.utcnow)
    user        = relationship("User",  back_populates="topics")
    tracks      = relationship("Track", back_populates="topic", cascade="all, delete-orphan")

class Track(Base):
    __tablename__ = "tracks"
    id               = Column(String, primary_key=True, default=nid)
    user_id          = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    topic_id         = Column(String, ForeignKey("topics.id"), nullable=False, index=True)
    youtube_video_id = Column(String, nullable=False)
    title            = Column(String, nullable=False)
    channel_name     = Column(String, default="Unknown")
    thumbnail_url    = Column(String, default="")
    tags             = Column(Text, default="")
    is_favorite      = Column(Boolean, default=False)
    play_count       = Column(Integer, default=0)
    created_at       = Column(DateTime, default=datetime.utcnow)
    user             = relationship("User",  back_populates="tracks")
    topic            = relationship("Topic", back_populates="tracks")

class History(Base):
    __tablename__ = "history"
    id        = Column(String, primary_key=True, default=nid)
    user_id   = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    track_id  = Column(String, nullable=True)
    video_id  = Column(String, nullable=False)
    title     = Column(String, default="")
    played_at = Column(DateTime, default=datetime.utcnow)
    user      = relationship("User", back_populates="history")
EOF

# ── schemas.py ────────────────────────────────────────────────────────────────
cat > "$ROOT/backend/schemas.py" << 'EOF'
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
    model_config = {"from_attributes": True}

class Token(BaseModel):
    access_token: str
    token_type: str
    user: UserOut

class TopicCreate(BaseModel):
    name: str
    description: Optional[str] = ""

class TopicOut(BaseModel):
    id: str
    name: str
    description: str
    created_at: datetime
    model_config = {"from_attributes": True}

class TrackCreate(BaseModel):
    topic_id: str
    youtube_video_id: str
    title: str
    channel_name: Optional[str] = "Unknown"
    thumbnail_url: Optional[str] = ""
    tags: Optional[str] = ""

class TrackOut(BaseModel):
    id: str
    topic_id: str
    youtube_video_id: str
    title: str
    channel_name: str
    thumbnail_url: str
    tags: str
    is_favorite: bool
    play_count: int
    created_at: datetime
    model_config = {"from_attributes": True}

class TrackUpdate(BaseModel):
    title: Optional[str] = None
    channel_name: Optional[str] = None
    topic_id: Optional[str] = None
    is_favorite: Optional[bool] = None
    tags: Optional[str] = None
EOF

# ── routers/__init__.py ───────────────────────────────────────────────────────
touch "$ROOT/backend/routers/__init__.py"

# ── routers/auth.py ───────────────────────────────────────────────────────────
cat > "$ROOT/backend/routers/auth.py" << 'EOF'
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
SECRET_KEY = os.environ.get("SECRET_KEY", "fallback_dev_secret_32chars_xxxxx")
ALGORITHM  = "HS256"
EXPIRE_MIN = int(os.environ.get("ACCESS_TOKEN_EXPIRE_MINUTES", "43200"))
oauth2     = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)

def hash_pw(pw: str) -> str:
    return bcrypt.hashpw(pw.encode("utf-8")[:72], bcrypt.gensalt()).decode()

def verify_pw(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain.encode("utf-8")[:72], hashed.encode())

def make_token(uid: str) -> str:
    exp = datetime.utcnow() + timedelta(minutes=EXPIRE_MIN)
    return jwt.encode({"sub": uid, "exp": exp}, SECRET_KEY, algorithm=ALGORITHM)

def current_user(token: str = Depends(oauth2), db: Session = Depends(get_db)) -> User:
    if not token:
        raise HTTPException(401, "Not authenticated")
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        uid = payload.get("sub")
        if not uid:
            raise HTTPException(401, "Invalid token")
    except JWTError:
        raise HTTPException(401, "Invalid token")
    user = db.query(User).filter(User.id == uid).first()
    if not user:
        raise HTTPException(401, "User not found")
    return user

@router.post("/register", response_model=Token)
def register(data: UserRegister, db: Session = Depends(get_db)):
    if not data.username or len(data.username.strip()) < 3:
        raise HTTPException(400, "用户名至少3个字符")
    if not data.password or len(data.password) < 4:
        raise HTTPException(400, "密码至少4个字符")
    uname = data.username.strip().lower()
    if db.query(User).filter(User.username == uname).first():
        raise HTTPException(400, "用户名已被使用")
    user = User(id=str(uuid.uuid4())[:12], username=uname,
                email=data.email or None, hashed_password=hash_pw(data.password), is_guest=False)
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=make_token(user.id), token_type="bearer", user=UserOut.model_validate(user))

@router.post("/login", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    uname = form.username.strip().lower()
    user = db.query(User).filter(User.username == uname).first()
    if not user or not verify_pw(form.password, user.hashed_password):
        raise HTTPException(401, "用户名或密码错误")
    return Token(access_token=make_token(user.id), token_type="bearer", user=UserOut.model_validate(user))

@router.post("/guest", response_model=Token)
def guest_login(db: Session = Depends(get_db)):
    gid = str(uuid.uuid4())[:12]
    user = User(id=gid, username=f"guest_{gid}", hashed_password=hash_pw(gid), is_guest=True)
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=make_token(user.id), token_type="bearer", user=UserOut.model_validate(user))

@router.get("/me", response_model=UserOut)
def me(user: User = Depends(current_user)):
    return user
EOF

# ── routers/topics.py ─────────────────────────────────────────────────────────
cat > "$ROOT/backend/routers/topics.py" << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from database import get_db
from models import User, Topic
from schemas import TopicCreate, TopicOut
from routers.auth import current_user

router = APIRouter()

@router.get("/", response_model=List[TopicOut])
def list_topics(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return db.query(Topic).filter(Topic.user_id == user.id).order_by(Topic.created_at).all()

@router.post("/", response_model=TopicOut)
def create_topic(data: TopicCreate, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = Topic(user_id=user.id, name=data.name.strip(), description=data.description or "")
    db.add(t); db.commit(); db.refresh(t)
    return t

@router.patch("/{tid}", response_model=TopicOut)
def update_topic(tid: str, data: TopicCreate, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.query(Topic).filter(Topic.id == tid, Topic.user_id == user.id).first()
    if not t: raise HTTPException(404, "Topic not found")
    t.name = data.name.strip()
    t.description = data.description or t.description
    db.commit(); db.refresh(t)
    return t

@router.delete("/{tid}")
def delete_topic(tid: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.query(Topic).filter(Topic.id == tid, Topic.user_id == user.id).first()
    if not t: raise HTTPException(404, "Topic not found")
    db.delete(t); db.commit()
    return {"ok": True}
EOF

# ── routers/tracks.py ─────────────────────────────────────────────────────────
cat > "$ROOT/backend/routers/tracks.py" << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from database import get_db
from models import User, Track, History
from schemas import TrackCreate, TrackOut, TrackUpdate
from routers.auth import current_user

router = APIRouter()

@router.get("/", response_model=List[TrackOut])
def list_tracks(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return db.query(Track).filter(Track.user_id == user.id).order_by(Track.created_at).all()

@router.post("/", response_model=TrackOut)
def add_track(data: TrackCreate, user: User = Depends(current_user), db: Session = Depends(get_db)):
    existing = db.query(Track).filter(
        Track.user_id == user.id,
        Track.youtube_video_id == data.youtube_video_id,
        Track.topic_id == data.topic_id
    ).first()
    if existing:
        raise HTTPException(400, "Track already in this topic")
    thumb = data.thumbnail_url or f"https://img.youtube.com/vi/{data.youtube_video_id}/mqdefault.jpg"
    t = Track(user_id=user.id, topic_id=data.topic_id,
              youtube_video_id=data.youtube_video_id, title=data.title,
              channel_name=data.channel_name or "Unknown",
              thumbnail_url=thumb, tags=data.tags or "")
    db.add(t); db.commit(); db.refresh(t)
    return t

@router.patch("/{tid}", response_model=TrackOut)
def update_track(tid: str, data: TrackUpdate, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.query(Track).filter(Track.id == tid, Track.user_id == user.id).first()
    if not t: raise HTTPException(404, "Track not found")
    for k, v in data.model_dump(exclude_none=True).items():
        setattr(t, k, v)
    db.commit(); db.refresh(t)
    return t

@router.delete("/{tid}")
def delete_track(tid: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.query(Track).filter(Track.id == tid, Track.user_id == user.id).first()
    if not t: raise HTTPException(404, "Track not found")
    db.delete(t); db.commit()
    return {"ok": True}

@router.post("/{tid}/played")
def record_play(tid: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.query(Track).filter(Track.id == tid, Track.user_id == user.id).first()
    if t:
        t.play_count = (t.play_count or 0) + 1
        h = History(user_id=user.id, track_id=tid, video_id=t.youtube_video_id, title=t.title)
        db.add(h); db.commit()
    return {"ok": True}
EOF

# ── routers/recommendations.py ───────────────────────────────────────────────
cat > "$ROOT/backend/routers/recommendations.py" << 'EOF'
import os, asyncio, json
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from database import get_db
from models import User, Track
from routers.auth import current_user
import httpx, yt_dlp
from datetime import datetime

router = APIRouter()

@router.get("/search")
async def yt_search(q: str = Query(...), user: User = Depends(current_user)):
    if not q.strip():
        return []
    loop = asyncio.get_event_loop()

    def do_flat():
        opts = {"quiet": True, "no_warnings": True, "extract_flat": True,
                "default_search": "ytsearch10", "skip_download": True}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch10:{q}", download=False)
            return (info or {}).get("entries", [])

    entries = await loop.run_in_executor(None, do_flat)

    async def enrich(entry):
        vid = entry.get("id") or ""
        if not vid or len(vid) != 11:
            return None
        def fetch():
            with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True}) as ydl:
                try:
                    return ydl.extract_info(f"https://www.youtube.com/watch?v={vid}", download=False)
                except Exception:
                    return None
        meta = await loop.run_in_executor(None, fetch)
        if not meta:
            return {
                "youtube_video_id": vid,
                "title": entry.get("title", ""),
                "channelName": entry.get("uploader") or entry.get("channel") or "",
                "thumbnail_url": f"https://img.youtube.com/vi/{vid}/mqdefault.jpg",
                "views": "", "uploaded_ago": "", "embeddable": None,
            }
        vc = meta.get("view_count") or 0
        views = f"{vc/1e6:.1f}M" if vc>=1e6 else f"{vc//1000}K" if vc>=1000 else str(vc) if vc else ""
        if views: views += " views"
        ago = ""
        ud = meta.get("upload_date", "")
        if ud and len(ud) == 8:
            try:
                days = (datetime.utcnow() - datetime.strptime(ud, "%Y%m%d")).days
                ago = f"{days}d ago" if days<30 else f"{days//30}mo ago" if days<365 else f"{days//365}y ago"
            except Exception:
                pass
        return {
            "youtube_video_id": vid,
            "title": meta.get("title", entry.get("title", "")),
            "channelName": meta.get("uploader") or meta.get("channel") or "",
            "thumbnail_url": f"https://img.youtube.com/vi/{vid}/mqdefault.jpg",
            "views": views, "uploaded_ago": ago,
            "embeddable": meta.get("playable_in_embed"),
        }

    results = await asyncio.gather(*[enrich(e) for e in entries[:10]])
    return [r for r in results if r]

@router.post("/ai-recs")
async def ai_recs(payload: dict, user: User = Depends(current_user)):
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key or "your_" in api_key:
        return {"error": "ANTHROPIC_API_KEY not set"}
    prompt = (
        f'Music recommendation assistant. Topic: "{payload.get("topic_name")}" '
        f'({payload.get("topic_desc", "")}). '
        f'Existing: {", ".join(payload.get("track_titles", [])) or "none"}. '
        'Give exactly 6 real YouTube tracks that fit. '
        'Respond ONLY with JSON array, no markdown: '
        '[{"youtube_video_id":"ID","title":"T","channelName":"C","reason":"R"}]'
    )
    async with httpx.AsyncClient(timeout=30) as c:
        try:
            r = await c.post("https://api.anthropic.com/v1/messages",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01",
                         "Content-Type": "application/json"},
                json={"model": "claude-sonnet-4-20250514", "max_tokens": 1000,
                      "messages": [{"role": "user", "content": prompt}]})
            text = r.json().get("content", [{}])[0].get("text", "")
            recs = json.loads(text.replace("```json","").replace("```","").strip())
            return [{"youtube_video_id": x["youtube_video_id"], "title": x["title"],
                     "channelName": x["channelName"], "reason": x.get("reason",""),
                     "thumbnail_url": f"https://img.youtube.com/vi/{x['youtube_video_id']}/mqdefault.jpg"}
                    for x in recs]
        except Exception as e:
            return {"error": str(e)}

@router.post("/ai-pool")
async def ai_pool(user: User = Depends(current_user), db: Session = Depends(get_db)):
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key or "your_" in api_key:
        return {"error": "ANTHROPIC_API_KEY not set"}
    all_tracks = db.query(Track).filter(Track.user_id == user.id).all()
    titles = [t.title for t in all_tracks[:20]]
    topics_set = list({t.topic.name for t in all_tracks if t.topic})
    prompt = (
        f'Music recommender. User has tracks in topics: {", ".join(topics_set) or "none"}. '
        f'Sample tracks: {", ".join(titles) or "none"}. '
        'Recommend 10 fresh YouTube tracks the user would enjoy. '
        'ONLY JSON array, no markdown: '
        '[{"youtube_video_id":"ID","title":"T","channelName":"C","tags":["t1"],"reason":"R"}]'
    )
    async with httpx.AsyncClient(timeout=30) as c:
        try:
            r = await c.post("https://api.anthropic.com/v1/messages",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01",
                         "Content-Type": "application/json"},
                json={"model": "claude-sonnet-4-20250514", "max_tokens": 1500,
                      "messages": [{"role": "user", "content": prompt}]})
            text = r.json().get("content", [{}])[0].get("text", "")
            recs = json.loads(text.replace("```json","").replace("```","").strip())
            return [{"youtube_video_id": x["youtube_video_id"], "title": x["title"],
                     "channelName": x["channelName"], "tags": x.get("tags",[]),
                     "reason": x.get("reason",""),
                     "thumbnail_url": f"https://img.youtube.com/vi/{x['youtube_video_id']}/mqdefault.jpg"}
                    for x in recs]
        except Exception as e:
            return {"error": str(e)}
EOF

# ── main.py ───────────────────────────────────────────────────────────────────
cat > "$ROOT/backend/main.py" << 'EOF'
from pathlib import Path
from dotenv import load_dotenv
load_dotenv(Path(__file__).parent / ".env")

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from database import Base, engine
from routers import auth, topics, tracks, recommendations

Base.metadata.create_all(bind=engine)

app = FastAPI(title="TopicTune API")
app.add_middleware(CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"])

app.include_router(auth.router,            prefix="/api/auth",            tags=["auth"])
app.include_router(topics.router,          prefix="/api/topics",          tags=["topics"])
app.include_router(tracks.router,          prefix="/api/tracks",          tags=["tracks"])
app.include_router(recommendations.router, prefix="/api/recommendations", tags=["recs"])

@app.get("/")
def root(): return {"status": "TopicTune API running"}
EOF

echo "✅ 后端文件写入完成"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: REACT FRONTEND
# ═══════════════════════════════════════════════════════════════════════════════
echo "── [2/4] React 前端 ────────────────────────────────────────────────────────"

cd "$ROOT"
npx --yes create-react-app frontend --template cra-template 2>/dev/null || \
  npx create-react-app@latest frontend 2>/dev/null || true

mkdir -p "$ROOT/frontend/src/pages"
mkdir -p "$ROOT/frontend/src/components"

# REACT_APP_API_URL 留空，由 Electron preload 注入
cat > "$ROOT/frontend/.env" << 'EOF'
REACT_APP_API_URL=http://localhost:8000
EOF

# ── src/index.js ──────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/index.js" << 'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

const root = ReactDOM.createRoot(document.getElementById("root"));
root.render(<React.StrictMode><App /></React.StrictMode>);
EOF

# ── src/api.js ────────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/api.js" << 'EOF'
// BASE URL: Electron preload 可以覆盖 window.BACKEND_URL
const BASE = (typeof window !== "undefined" && window.BACKEND_URL)
  ? window.BACKEND_URL
  : (process.env.REACT_APP_API_URL || "http://localhost:8000");

function getToken() { return localStorage.getItem("tt_token") || ""; }

async function req(method, path, body) {
  const headers = { "Content-Type": "application/json" };
  const tok = getToken();
  if (tok) headers["Authorization"] = "Bearer " + tok;
  const opts = { method, headers };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const resp = await fetch(BASE + path, opts);
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error(err.detail || "Request failed (" + resp.status + ")");
  }
  return resp.json();
}

async function formReq(path, fd) {
  const headers = {};
  const tok = getToken();
  if (tok) headers["Authorization"] = "Bearer " + tok;
  const resp = await fetch(BASE + path, { method: "POST", headers, body: fd });
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({}));
    throw new Error(err.detail || "Request failed (" + resp.status + ")");
  }
  return resp.json();
}

export const api = {
  register:    (u, p, e)   => req("POST", "/api/auth/register", { username: u, password: p, email: e }),
  login:       (u, p)      => { const fd = new URLSearchParams(); fd.append("username", u); fd.append("password", p); return formReq("/api/auth/login", fd); },
  guest:       ()          => req("POST", "/api/auth/guest"),
  me:          ()          => req("GET",  "/api/auth/me"),
  getTopics:   ()          => req("GET",  "/api/topics/"),
  createTopic: (n, d)      => req("POST", "/api/topics/", { name: n, description: d || "" }),
  updateTopic: (id, n, d)  => req("PATCH","/api/topics/" + id, { name: n, description: d || "" }),
  deleteTopic: (id)        => req("DELETE","/api/topics/" + id),
  getTracks:   ()          => req("GET",  "/api/tracks/"),
  addTrack:    (data)      => req("POST", "/api/tracks/", data),
  updateTrack: (id, data)  => req("PATCH","/api/tracks/" + id, data),
  deleteTrack: (id)        => req("DELETE","/api/tracks/" + id),
  recordPlay:  (id)        => req("POST", "/api/tracks/" + id + "/played").catch(() => {}),
  searchYT:    (q)         => req("GET",  "/api/recommendations/search?q=" + encodeURIComponent(q)),
  aiRecs:      (tn, td, tt)=> req("POST", "/api/recommendations/ai-recs", { topic_name: tn, topic_desc: td, track_titles: tt }),
  aiPool:      ()          => req("POST", "/api/recommendations/ai-pool", {}),
};
EOF

# ── src/App.js ────────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/App.js" << 'EOF'
import React, { useState, useRef, useEffect, useCallback } from "react";
import { api } from "./api";

// ─── Pages (lazy inline imports) ─────────────────────────────────────────────
import LoginPage       from "./pages/Login";
import HomePage        from "./pages/Home";
import TopicsPage      from "./pages/Topics";
import TopicDetailPage from "./pages/TopicDetail";
import PlayerPage      from "./pages/Player";
import SearchPage      from "./pages/Search";
import PoolPage        from "./pages/Pool";
import FavoritesPage   from "./pages/Favorites";
import SettingsPage    from "./pages/Settings";

// Detect Electron
const isElectron = typeof window !== "undefined" && !!window.electronYT;

function uid() { return "id_" + Math.random().toString(36).slice(2, 9); }

function normalizeTrack(t) {
  return {
    id: t.id,
    youtube_video_id: t.youtube_video_id,
    title: t.title,
    channelName: t.channel_name || t.channelName || "Unknown",
    thumbnail_url: t.thumbnail_url || `https://img.youtube.com/vi/${t.youtube_video_id}/mqdefault.jpg`,
    topic_id: t.topic_id,
    tags: t.tags || "",
    is_favorite: t.is_favorite || false,
    play_count: t.play_count || 0,
  };
}

export default function App() {
  const [user,          setUser]          = useState(null);
  const [topics,        setTopics]        = useState([]);
  const [tracks,        setTracks]        = useState([]);
  const [page,          setPage]          = useState("home");
  const [activeTopicId, setActiveTopicId] = useState(null);
  const [currentTrack,  setCurrentTrack]  = useState(null);
  const [isPlaying,     setIsPlaying]     = useState(false);
  const [queue,         setQueue]         = useState([]);
  const [queueIdx,      setQueueIdx]      = useState(0);
  const [shuffle,       setShuffle]       = useState(false);
  const [loop,          setLoop]          = useState("none"); // none | all | one
  const [speed,         setSpeed]         = useState(1);
  const [audioMode,     setAudioMode]     = useState("audio"); // video | audio | hidden
  const [toast,         setToast]         = useState(null);
  const [sleepTimer,    setSleepTimer]    = useState(null);
  const [appLoading,    setAppLoading]    = useState(true);
  const sleepRef   = useRef(null);
  const queueRef   = useRef(queue);
  const idxRef     = useRef(queueIdx);
  const shuffleRef = useRef(shuffle);
  const loopRef    = useRef(loop);
  useEffect(() => { queueRef.current = queue; },   [queue]);
  useEffect(() => { idxRef.current   = queueIdx; },[queueIdx]);
  useEffect(() => { shuffleRef.current = shuffle; },[shuffle]);
  useEffect(() => { loopRef.current  = loop; },    [loop]);

  // ── Auth init ──────────────────────────────────────────────────────────────
  useEffect(() => {
    const tok = localStorage.getItem("tt_token");
    if (!tok) { setAppLoading(false); return; }
    api.me()
      .then(u => { setUser(u); return Promise.all([api.getTopics(), api.getTracks()]); })
      .then(([tps, trs]) => { setTopics(tps); setTracks(trs.map(normalizeTrack)); })
      .catch(() => localStorage.removeItem("tt_token"))
      .finally(() => setAppLoading(false));
  }, []);

  // ── Electron: listen for track-ended events ────────────────────────────────
  useEffect(() => {
    if (!isElectron) return;
    window.electronYT.onState(state => {
      if (state.type === "ended")   playNextRef.current();
      if (state.type === "playing") setIsPlaying(true);
      if (state.type === "paused")  setIsPlaying(false);
    });
    window.electronYT.startPoll();
    return () => window.electronYT.removeStateListeners();
  }, []);

  // ── Toast ──────────────────────────────────────────────────────────────────
  const showToast = useCallback((msg, type = "success") => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 2800);
  }, []);

  // ── Auth handlers ──────────────────────────────────────────────────────────
  const handleAuth = (token, u) => {
    localStorage.setItem("tt_token", token);
    setUser(u);
    setAppLoading(true);
    Promise.all([api.getTopics(), api.getTracks()])
      .then(([tps, trs]) => { setTopics(tps); setTracks(trs.map(normalizeTrack)); })
      .catch(() => {})
      .finally(() => setAppLoading(false));
  };

  const handleLogout = () => {
    if (isElectron) window.electronYT.stop();
    setCurrentTrack(null); setIsPlaying(false);
    setQueue([]); setTopics([]); setTracks([]);
    setUser(null); setPage("home");
    localStorage.removeItem("tt_token");
  };

  // ── Track helpers ──────────────────────────────────────────────────────────
  const topicTracks = useCallback(tid => tracks.filter(t => t.topic_id === tid), [tracks]);

  // Stable ref for playNext so Electron listener always has latest version
  const playNextRef = useRef(null);

  const playNext = useCallback(() => {
    const q = queueRef.current;
    const idx = idxRef.current;
    if (!q.length) return;
    let ni;
    if (loopRef.current === "one")         ni = idx;
    else if (shuffleRef.current)           ni = Math.floor(Math.random() * q.length);
    else if (idx + 1 >= q.length)          ni = loopRef.current === "all" ? 0 : -1;
    else                                   ni = idx + 1;
    if (ni < 0) { setIsPlaying(false); return; }
    const next = q[ni];
    setQueueIdx(ni);
    setCurrentTrack(next);
    setIsPlaying(true);
    api.recordPlay(next.id);
    if (isElectron) window.electronYT.load(next.youtube_video_id, audioMode);
  }, [audioMode]);
  useEffect(() => { playNextRef.current = playNext; }, [playNext]);

  const playPrev = useCallback(() => {
    const q = queueRef.current;
    const idx = idxRef.current;
    if (!q.length) return;
    const ni = Math.max(0, idx - 1);
    const prev = q[ni];
    setQueueIdx(ni);
    setCurrentTrack(prev);
    setIsPlaying(true);
    if (isElectron) window.electronYT.load(prev.youtube_video_id, audioMode);
  }, [audioMode]);

  const playTrack = useCallback((track, trackList = null) => {
    const list = trackList || topicTracks(track.topic_id);
    const ni   = list.findIndex(t => t.id === track.id);
    setCurrentTrack(track);
    setIsPlaying(true);
    setQueue(list);
    setQueueIdx(ni >= 0 ? ni : 0);
    setPage("player");
    api.recordPlay(track.id);
    if (isElectron) window.electronYT.load(track.youtube_video_id, audioMode);
  }, [topicTracks, audioMode]);

  // ── Sleep timer ────────────────────────────────────────────────────────────
  const startSleepTimer = (mins) => {
    if (sleepRef.current) clearTimeout(sleepRef.current);
    if (!mins) { setSleepTimer(null); return; }
    setSleepTimer(mins);
    sleepRef.current = setTimeout(() => {
      setIsPlaying(false); setSleepTimer(null);
      if (isElectron) window.electronYT.pause();
      showToast("⏱ Sleep timer ended — paused");
    }, mins * 60000);
  };

  // ── Track CRUD ─────────────────────────────────────────────────────────────
  const addTrack = (videoId, title, channel, topicId) => {
    if (tracks.find(t => t.youtube_video_id === videoId && t.topic_id === topicId)) {
      showToast("Already in this topic!", "warn"); return;
    }
    api.addTrack({
      youtube_video_id: videoId,
      title: title || `Video (${videoId})`,
      channel_name: channel || "Unknown",
      topic_id: topicId,
      thumbnail_url: `https://img.youtube.com/vi/${videoId}/mqdefault.jpg`,
    }).then(t => {
      setTracks(prev => [...prev, normalizeTrack(t)]);
      showToast("Added ✓");
    }).catch(e => showToast(e.message, "error"));
  };

  const deleteTrack = (id) => {
    api.deleteTrack(id).then(() => {
      setTracks(prev => prev.filter(t => t.id !== id));
      if (currentTrack?.id === id) { setCurrentTrack(null); setIsPlaying(false); }
      showToast("Removed");
    }).catch(e => showToast(e.message, "error"));
  };

  const toggleFav = (id) => {
    const t = tracks.find(t => t.id === id);
    if (!t) return;
    const next = !t.is_favorite;
    api.updateTrack(id, { is_favorite: next }).then(() =>
      setTracks(prev => prev.map(t => t.id === id ? { ...t, is_favorite: next } : t))
    );
  };

  const nav = (p, topicId = null) => {
    setPage(p);
    if (topicId) setActiveTopicId(topicId);
  };

  const activeTopic = topics.find(t => t.id === activeTopicId);

  // ── Loading / Login ────────────────────────────────────────────────────────
  if (appLoading) return (
    <div style={{ display:"flex", alignItems:"center", justifyContent:"center", height:"100vh", background:"#0f0f1a", color:"#818cf8", fontSize:18, fontFamily:"'Segoe UI',sans-serif" }}>
      🎵 Loading TopicTune…
    </div>
  );
  if (!user) return <LoginPage onAuth={handleAuth} />;

  // ── UI ─────────────────────────────────────────────────────────────────────
  return (
    <div style={{ display:"flex", flexDirection:"column", height:"100vh", background:"#0f0f1a", color:"#e0e0ff", fontFamily:"'Segoe UI',sans-serif", overflow:"hidden" }}>

      {/* Toast */}
      {toast && (
        <div style={{ position:"fixed", top:14, left:"50%", transform:"translateX(-50%)", zIndex:9999,
          background: toast.type==="warn" ? "#78350f" : toast.type==="error" ? "#7f1d1d" : "#1d5c3a",
          color:"#fff", padding:"8px 22px", borderRadius:8, fontSize:13, boxShadow:"0 4px 20px #0008", pointerEvents:"none" }}>
          {toast.msg}
        </div>
      )}

      {/* ── Header ── */}
      <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"10px 20px", background:"#151525", borderBottom:"1px solid #2a2a4a", flexShrink:0, WebkitAppRegion:"drag" }}>
        <div style={{ display:"flex", alignItems:"center", gap:8, cursor:"pointer", WebkitAppRegion:"no-drag" }} onClick={() => nav("home")}>
          <span style={{ fontSize:20 }}>🎵</span>
          <span style={{ fontWeight:700, fontSize:18, background:"linear-gradient(90deg,#818cf8,#c084fc)", WebkitBackgroundClip:"text", WebkitTextFillColor:"transparent" }}>TopicTune</span>
        </div>
        <div style={{ display:"flex", alignItems:"center", gap:10, WebkitAppRegion:"no-drag" }}>
          {sleepTimer && <span style={{ fontSize:12, background:"#312e81", padding:"3px 10px", borderRadius:20, color:"#a5b4fc" }}>⏱ {sleepTimer}m</span>}
          {currentTrack && page !== "player" && (
            <button onClick={() => setPage("player")} style={S.btn("#6366f1")}>▶ Now Playing</button>
          )}
          <span style={{ fontSize:12, color:"#6b7280" }}>{user.username}</span>
          <button onClick={handleLogout} style={S.btn("#2a2a4a")}>Logout</button>
        </div>
      </div>

      {/* ── Body ── */}
      <div style={{ display:"flex", flex:1, overflow:"hidden" }}>

        {/* Sidebar */}
        <div style={{ width:185, background:"#151525", borderRight:"1px solid #2a2a4a", display:"flex", flexDirection:"column", padding:"12px 0", flexShrink:0, overflowY:"auto" }}>
          {[
            { id:"home",      l:"Home",      e:"🏠" },
            { id:"topics",    l:"My Topics", e:"📁" },
            { id:"search",    l:"Search",    e:"🔍" },
            { id:"pool",      l:"Idea Pool", e:"💡" },
            { id:"favorites", l:"Favorites", e:"⭐" },
            { id:"settings",  l:"Settings",  e:"⚙️" },
          ].map(item => (
            <button key={item.id} onClick={() => nav(item.id)} style={{
              display:"flex", alignItems:"center", gap:10, padding:"9px 18px",
              background: page === item.id ? "#1e1e3a" : "transparent",
              border:"none", color: page === item.id ? "#818cf8" : "#9ca3af",
              cursor:"pointer", fontSize:13, textAlign:"left",
              borderLeft: page === item.id ? "3px solid #818cf8" : "3px solid transparent",
            }}>
              {item.e} {item.l}
            </button>
          ))}

          <div style={{ borderTop:"1px solid #2a2a4a", margin:"8px 0", padding:"6px 18px 2px", fontSize:10, color:"#6b7280", textTransform:"uppercase", letterSpacing:1 }}>Topics</div>

          {topics.map(tp => {
            const active = activeTopicId === tp.id && page === "topic";
            return (
              <button key={tp.id} onClick={() => nav("topic", tp.id)} style={{
                display:"flex", alignItems:"center", gap:8, padding:"7px 18px",
                background: active ? "#1e1e3a" : "transparent",
                border:"none", color: active ? "#a78bfa" : "#9ca3af",
                cursor:"pointer", fontSize:12.5, textAlign:"left", width:"100%",
                borderLeft: active ? "3px solid #a78bfa" : "3px solid transparent",
              }}>
                <span style={{ width:7, height:7, borderRadius:"50%", background:"#6366f1", flexShrink:0, display:"inline-block" }} />
                <span style={{ overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{tp.name}</span>
              </button>
            );
          })}
        </div>

        {/* Main content */}
        <div style={{ flex:1, overflow:"auto", padding:22 }}>
          {page === "home"      && <HomePage topics={topics} tracks={tracks} nav={nav} playTrack={playTrack} />}
          {page === "topics"    && <TopicsPage topics={topics} tracks={tracks} setTopics={setTopics} nav={nav} showToast={showToast} />}
          {page === "topic"     && activeTopic && (
            <TopicDetailPage
              topic={activeTopic} tracks={topicTracks(activeTopic.id)}
              allTopics={topics} playTrack={playTrack} deleteTrack={deleteTrack}
              toggleFav={toggleFav} setTracks={setTracks} addTrack={addTrack}
              currentTrack={currentTrack} showToast={showToast} nav={nav}
            />
          )}
          {page === "player" && (
            <PlayerPage
              track={currentTrack} topics={topics}
              isPlaying={isPlaying} setIsPlaying={setIsPlaying}
              loop={loop} setLoop={setLoop}
              shuffle={shuffle} setShuffle={setShuffle}
              speed={speed} setSpeed={setSpeed}
              audioMode={audioMode} setAudioMode={setAudioMode}
              playNext={playNext} playPrev={playPrev}
              toggleFav={toggleFav} nav={nav}
            />
          )}
          {page === "search"    && <SearchPage tracks={tracks} topics={topics} playTrack={playTrack} toggleFav={toggleFav} addTrack={addTrack} showToast={showToast} />}
          {page === "pool"      && <PoolPage topics={topics} tracks={tracks} addTrack={addTrack} showToast={showToast} />}
          {page === "favorites" && <FavoritesPage tracks={tracks.filter(t => t.is_favorite)} topics={topics} playTrack={playTrack} toggleFav={toggleFav} />}
          {page === "settings"  && <SettingsPage audioMode={audioMode} setAudioMode={setAudioMode} speed={speed} setSpeed={setSpeed} loop={loop} setLoop={setLoop} shuffle={shuffle} setShuffle={setShuffle} sleepTimer={sleepTimer} startSleepTimer={startSleepTimer} />}
        </div>
      </div>

      {/* ── Mini Player (shown on all pages except player) ── */}
      {currentTrack && page !== "player" && (
        <div style={{ background:"#151525", borderTop:"1px solid #2a2a4a", padding:"8px 20px", display:"flex", alignItems:"center", gap:12, flexShrink:0, cursor:"pointer" }}
             onClick={() => setPage("player")}>
          <img src={currentTrack.thumbnail_url} alt="" style={{ width:40, height:30, objectFit:"cover", borderRadius:4 }} />
          <div style={{ flex:1, overflow:"hidden" }}>
            <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{currentTrack.title}</div>
            <div style={{ fontSize:11, color:"#9ca3af" }}>{currentTrack.channelName}</div>
          </div>
          <button onClick={e => { e.stopPropagation(); playPrev(); }} style={S.ib}>⏮</button>
          <button onClick={e => {
            e.stopPropagation();
            const next = !isPlaying;
            setIsPlaying(next);
            if (isElectron) { next ? window.electronYT.play() : window.electronYT.pause(); }
          }} style={{ ...S.ib, background:"#6366f1", borderRadius:"50%", width:34, height:34, display:"flex", alignItems:"center", justifyContent:"center", fontSize:14 }}>
            {isPlaying ? "⏸" : "▶"}
          </button>
          <button onClick={e => { e.stopPropagation(); playNext(); }} style={S.ib}>⏭</button>
        </div>
      )}
    </div>
  );
}

// Shared minimal style helpers
const S = {
  btn: (bg) => ({ background:bg, border:"none", borderRadius:8, padding:"6px 14px", color:"#fff", cursor:"pointer", fontSize:12, fontWeight:500 }),
  ib:  { background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:5, borderRadius:6, fontSize:16 },
};
EOF

# ── src/pages/Login.js ────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Login.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";

export default function LoginPage({ onAuth }) {
  const [mode, setMode]       = useState("login");
  const [user, setUser]       = useState("");
  const [pass, setPass]       = useState("");
  const [email, setEmail]     = useState("");
  const [err,  setErr]        = useState("");
  const [busy, setBusy]       = useState(false);

  const submit = () => {
    if (!user.trim() || !pass.trim()) { setErr("请填写用户名和密码"); return; }
    setErr(""); setBusy(true);
    const p = mode === "login" ? api.login(user.trim(), pass) : api.register(user.trim(), pass, email.trim());
    p.then(d => onAuth(d.access_token, d.user))
     .catch(e => setErr(e.message))
     .finally(() => setBusy(false));
  };

  const guest = () => {
    setBusy(true);
    api.guest().then(d => onAuth(d.access_token, d.user)).catch(e => setErr(e.message)).finally(() => setBusy(false));
  };

  const inp = { display:"block", width:"100%", boxSizing:"border-box", background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, padding:"9px 12px", color:"#e0e0ff", fontSize:13, outline:"none", marginBottom:10 };

  return (
    <div style={{ display:"flex", alignItems:"center", justifyContent:"center", height:"100vh", background:"#0f0f1a" }}>
      <div style={{ background:"#151525", border:"1px solid #2a2a4a", borderRadius:16, padding:36, width:340 }}>
        <div style={{ textAlign:"center", marginBottom:26 }}>
          <div style={{ fontSize:38 }}>🎵</div>
          <div style={{ fontWeight:700, fontSize:22, background:"linear-gradient(90deg,#818cf8,#c084fc)", WebkitBackgroundClip:"text", WebkitTextFillColor:"transparent", marginTop:4 }}>TopicTune</div>
          <div style={{ fontSize:12, color:"#6b7280", marginTop:4 }}>Your personal YouTube audio player</div>
        </div>

        {/* Tab */}
        <div style={{ display:"flex", marginBottom:18, background:"#1a1a2e", borderRadius:8, padding:3 }}>
          {["login","register"].map(m => (
            <button key={m} onClick={() => { setMode(m); setErr(""); }} style={{
              flex:1, padding:"7px 0", border:"none", borderRadius:6, cursor:"pointer", fontSize:13,
              background: mode===m ? "#6366f1" : "transparent",
              color: mode===m ? "#fff" : "#9ca3af", fontWeight: mode===m ? 600 : 400,
            }}>{m === "login" ? "Login" : "Register"}</button>
          ))}
        </div>

        <input value={user} onChange={e => setUser(e.target.value)} placeholder="Username" style={inp} onKeyDown={e => e.key==="Enter" && submit()} />
        <input type="password" value={pass} onChange={e => setPass(e.target.value)} placeholder="Password" style={inp} onKeyDown={e => e.key==="Enter" && submit()} />
        {mode === "register" && <input value={email} onChange={e => setEmail(e.target.value)} placeholder="Email (optional)" style={inp} />}
        {err && <div style={{ color:"#f87171", fontSize:12, marginBottom:10 }}>{err}</div>}

        <button onClick={submit} disabled={busy} style={{ width:"100%", padding:"10px 0", background:"#6366f1", border:"none", borderRadius:8, color:"#fff", fontWeight:600, cursor:"pointer", fontSize:14, marginBottom:10 }}>
          {busy ? "..." : mode === "login" ? "Login" : "Create Account"}
        </button>
        <button onClick={guest} disabled={busy} style={{ width:"100%", padding:"8px 0", background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, color:"#9ca3af", cursor:"pointer", fontSize:13 }}>
          Continue as Guest
        </button>
      </div>
    </div>
  );
}
EOF

# ── src/pages/Player.js ───────────────────────────────────────────────────────
# 这是最关键的页面：正确处理 Electron BrowserView 和浏览器内 YT IFrame API
cat > "$ROOT/frontend/src/pages/Player.js" << 'EOF'
import React, { useEffect, useRef, useState } from "react";

const isElectron = typeof window !== "undefined" && !!window.electronYT;

export default function PlayerPage({
  track, topics, isPlaying, setIsPlaying,
  loop, setLoop, shuffle, setShuffle,
  speed, setSpeed, audioMode, setAudioMode,
  playNext, playPrev, toggleFav, nav,
}) {
  const ytPlayerRef  = useRef(null);  // YT.Player instance (browser only)
  const divRef       = useRef(null);  // div that YT.Player injects into
  const loadedIdRef  = useRef(null);  // currently loaded video id
  const speedRef     = useRef(speed);
  const playNextRef  = useRef(playNext);
  const [ytReady,    setYtReady]  = useState(false); // YT API loaded?

  useEffect(() => { speedRef.current  = speed; },    [speed]);
  useEffect(() => { playNextRef.current = playNext; },[playNext]);

  const topic = track ? topics.find(t => t.id === track.topic_id) : null;
  const NEXT_LOOP = { none:"all", all:"one", one:"none" };
  const LOOP_LABEL = { none:"↩ Off", all:"🔁 All", one:"🔂 One" };

  // ── Load YouTube IFrame API (browser mode only) ───────────────────────────
  useEffect(() => {
    if (isElectron) return;
    if (window.YT && window.YT.Player) { setYtReady(true); return; }
    const tag = document.createElement("script");
    tag.src = "https://www.youtube.com/iframe_api";
    document.head.appendChild(tag);
    window.onYouTubeIframeAPIReady = () => setYtReady(true);
    return () => { window.onYouTubeIframeAPIReady = null; };
  }, []);

  // ── Browser: create/reload player when track changes ─────────────────────
  useEffect(() => {
    if (isElectron || !ytReady || !track || !divRef.current) return;
    if (loadedIdRef.current === track.youtube_video_id && ytPlayerRef.current) {
      // Same video — sync play state
      isPlaying ? ytPlayerRef.current.playVideo() : ytPlayerRef.current.pauseVideo();
      return;
    }
    loadedIdRef.current = track.youtube_video_id;
    if (ytPlayerRef.current) {
      try { ytPlayerRef.current.destroy(); } catch (_) {}
      ytPlayerRef.current = null;
    }
    ytPlayerRef.current = new window.YT.Player(divRef.current, {
      videoId: track.youtube_video_id,
      playerVars: { autoplay: 1, rel: 0, modestbranding: 1 },
      events: {
        onReady: e => { try { e.target.setPlaybackRate(speedRef.current); } catch(_) {} },
        onStateChange: e => {
          if (e.data === window.YT.PlayerState.PLAYING) setIsPlaying(true);
          if (e.data === window.YT.PlayerState.PAUSED)  setIsPlaying(false);
          if (e.data === window.YT.PlayerState.ENDED)   playNextRef.current();
        },
      },
    });
  }, [track?.youtube_video_id, ytReady]);

  // ── Browser: sync play/pause ──────────────────────────────────────────────
  useEffect(() => {
    if (isElectron || !ytPlayerRef.current) return;
    try { isPlaying ? ytPlayerRef.current.playVideo() : ytPlayerRef.current.pauseVideo(); } catch(_) {}
  }, [isPlaying]);

  // ── Browser: sync speed ───────────────────────────────────────────────────
  useEffect(() => {
    if (isElectron || !ytPlayerRef.current) return;
    try { ytPlayerRef.current.setPlaybackRate(speed); } catch(_) {}
  }, [speed]);

  // ── Electron: load new track ──────────────────────────────────────────────
  useEffect(() => {
    if (!isElectron || !track) return;
    if (loadedIdRef.current !== track.youtube_video_id) {
      loadedIdRef.current = track.youtube_video_id;
      window.electronYT.load(track.youtube_video_id, audioMode);
    }
  }, [track?.youtube_video_id]);

  // ── Electron: sync play/pause ─────────────────────────────────────────────
  useEffect(() => {
    if (!isElectron) return;
    isPlaying ? window.electronYT.play() : window.electronYT.pause();
  }, [isPlaying]);

  // ── Electron: sync speed ──────────────────────────────────────────────────
  useEffect(() => {
    if (!isElectron) return;
    window.electronYT.setSpeed(speed);
  }, [speed]);

  // ── Electron: sync mode ───────────────────────────────────────────────────
  useEffect(() => {
    if (!isElectron) return;
    window.electronYT.setMode(audioMode);
  }, [audioMode]);

  // ── Empty state ───────────────────────────────────────────────────────────
  if (!track) return (
    <div style={{ textAlign:"center", padding:80, color:"#6b7280" }}>
      <div style={{ fontSize:56, marginBottom:12 }}>🎵</div>
      <div style={{ fontSize:15 }}>No track selected — pick something to play!</div>
    </div>
  );

  // ── Player wrapper styles (browser iframe) ────────────────────────────────
  const wrapStyle = audioMode === "video"
    ? { position:"relative", paddingTop:"56.25%", borderRadius:12, overflow:"hidden", background:"#000", marginBottom:16 }
    : audioMode === "audio"
    ? { width:240, height:135, borderRadius:8, overflow:"hidden", background:"#000", border:"2px solid #6366f1", marginBottom:16 }
    : { position:"fixed", left:"-9999px", width:1, height:1 };  // hidden but kept alive

  const innerStyle = audioMode === "video"
    ? { position:"absolute", top:0, left:0, width:"100%", height:"100%", border:"none" }
    : { width:"100%", height:"100%", border:"none" };

  return (
    <div style={{ maxWidth:660, margin:"0 auto" }}>
      {topic && (
        <button onClick={() => nav("topic", topic.id)}
          style={{ background:"#252545", border:"none", borderRadius:8, padding:"6px 14px", color:"#fff", cursor:"pointer", fontSize:12, marginBottom:14, display:"flex", alignItems:"center", gap:6 }}>
          ← Back to {topic.name}
        </button>
      )}

      <h2 style={{ fontSize:20, fontWeight:700, marginBottom:14, color:"#e0e0ff" }}>Now Playing</h2>

      {/* Mode toggle */}
      <div style={{ display:"flex", gap:6, marginBottom:14 }}>
        {[["video","🎬 Video"],["audio","🎵 Audio"],["hidden","🙈 Hidden"]].map(([m, l]) => (
          <button key={m} onClick={() => setAudioMode(m)} style={{
            background: audioMode===m ? "#6366f1" : "#252545",
            border:"none", borderRadius:8, padding:"4px 14px", color:"#fff", cursor:"pointer", fontSize:12,
          }}>{l}</button>
        ))}
      </div>

      {/* ── Browser iframe player (always in DOM when not Electron) ── */}
      {!isElectron && (
        <div style={wrapStyle}>
          <div ref={divRef} style={innerStyle} />
        </div>
      )}

      {/* ── Electron: placeholder box in video mode ── */}
      {isElectron && audioMode === "video" && (
        <div style={{ width:"100%", paddingTop:"56.25%", background:"#0a0a1a", borderRadius:12, marginBottom:16, position:"relative", border:"1px solid #2a2a4a" }}>
          <div style={{ position:"absolute", top:"50%", left:"50%", transform:"translate(-50%,-50%)", color:"#4a4a6a", fontSize:13 }}>
            🎬 Video playing above
          </div>
        </div>
      )}

      {/* Album art (audio / hidden modes) */}
      {audioMode !== "video" && (
        <div style={{ display:"flex", gap:14, alignItems:"center", background:"#1a1a2e", border:"1px solid #2a2a4a", borderRadius:12, padding:14, marginBottom:16 }}>
          <img src={track.thumbnail_url} alt="" style={{ width:88, height:62, objectFit:"cover", borderRadius:8, flexShrink:0 }} />
          <div>
            <div style={{ fontWeight:700, fontSize:15, marginBottom:3, color:"#e0e0ff" }}>{track.title}</div>
            <div style={{ color:"#9ca3af", fontSize:13 }}>{track.channelName}</div>
            {topic && <div style={{ color:"#6366f1", fontSize:12, marginTop:3 }}>📁 {topic.name}</div>}
            <div style={{ fontSize:11, color:"#6b7280", marginTop:3 }}>
              {audioMode === "hidden" ? "🙈 Video hidden — audio playing" : "🎵 Audio-first mode"}
            </div>
          </div>
        </div>
      )}

      {/* ── Playback controls ── */}
      <div style={{ background:"#1a1a2e", border:"1px solid #2a2a4a", borderRadius:12, padding:"14px 18px", marginBottom:14 }}>
        <div style={{ marginBottom:12 }}>
          <div style={{ fontWeight:700, fontSize:15, color:"#e0e0ff" }}>{track.title}</div>
          <div style={{ color:"#9ca3af", fontSize:12 }}>{track.channelName}{topic ? " · " + topic.name : ""}</div>
        </div>

        {/* Main controls */}
        <div style={{ display:"flex", alignItems:"center", justifyContent:"center", gap:16, marginBottom:14 }}>
          <button title="Shuffle" onClick={() => setShuffle(!shuffle)}
            style={{ background:"transparent", border:"none", color: shuffle ? "#818cf8" : "#6b7280", cursor:"pointer", padding:6, fontSize:18, borderRadius:6 }}>⇀</button>
          <button title="Previous" onClick={playPrev}
            style={{ background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:6, fontSize:22, borderRadius:6 }}>⏮</button>
          <button title={isPlaying ? "Pause" : "Play"} onClick={() => setIsPlaying(!isPlaying)}
            style={{ background:"#6366f1", border:"none", borderRadius:"50%", width:50, height:50, fontSize:20, cursor:"pointer", color:"#fff", display:"flex", alignItems:"center", justifyContent:"center", flexShrink:0 }}>
            {isPlaying ? "⏸" : "▶"}
          </button>
          <button title="Next" onClick={playNext}
            style={{ background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:6, fontSize:22, borderRadius:6 }}>⏭</button>
          <button title="Loop" onClick={() => setLoop(NEXT_LOOP[loop])}
            style={{ background:"transparent", border:"none", color: loop!=="none" ? "#818cf8" : "#6b7280", cursor:"pointer", padding:6, fontSize:12, borderRadius:6, minWidth:48 }}>
            {LOOP_LABEL[loop]}
          </button>
        </div>

        {/* Speed + Favorite */}
        <div style={{ display:"flex", alignItems:"center", gap:5, flexWrap:"wrap" }}>
          <span style={{ fontSize:12, color:"#9ca3af", marginRight:2 }}>Speed:</span>
          {[0.75, 1, 1.25, 1.5, 2].map(s => (
            <button key={s} onClick={() => setSpeed(s)} style={{
              background: speed===s ? "#6366f1" : "#252545",
              border:"none", borderRadius:7, padding:"2px 9px", color:"#fff", cursor:"pointer", fontSize:11,
            }}>{s}x</button>
          ))}
          <button onClick={() => toggleFav(track.id)}
            style={{ background:"transparent", border:"none", marginLeft:"auto", color: track.is_favorite ? "#f59e0b" : "#6b7280", cursor:"pointer", padding:5, fontSize:20 }}>
            {track.is_favorite ? "★" : "☆"}
          </button>
        </div>
      </div>

      {/* Open in YouTube */}
      <div style={{ textAlign:"center" }}>
        <a href={"https://www.youtube.com/watch?v=" + track.youtube_video_id}
          target="_blank" rel="noreferrer" style={{ color:"#6b7280", fontSize:12 }}>
          ↗ Open in YouTube
        </a>
      </div>
    </div>
  );
}
EOF

# ── src/pages/Home.js ─────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Home.js" << 'EOF'
import React from "react";

export default function HomePage({ topics, tracks, nav, playTrack }) {
  const favs = tracks.filter(t => t.is_favorite).slice(0, 6);
  return (
    <div>
      <h2 style={H2}>Home</h2>
      <Sec title="My Topics">
        <div style={{ display:"flex", gap:12, flexWrap:"wrap" }}>
          {topics.map(tp => {
            const cnt   = tracks.filter(t => t.topic_id === tp.id).length;
            const thumb = tracks.find(t => t.topic_id === tp.id);
            return (
              <div key={tp.id} onClick={() => nav("topic", tp.id)}
                style={{ width:138, cursor:"pointer", borderRadius:10, overflow:"hidden", background:"#1a1a2e", border:"1px solid #2a2a4a" }}
                onMouseOver={e => e.currentTarget.style.transform="scale(1.03)"}
                onMouseOut={e  => e.currentTarget.style.transform="scale(1)"}>
                <div style={{ height:78, background:"#252545", overflow:"hidden", display:"flex", alignItems:"center", justifyContent:"center" }}>
                  {thumb ? <img src={thumb.thumbnail_url} alt="" style={{ width:"100%", objectFit:"cover" }} /> : <span style={{ fontSize:28 }}>🎵</span>}
                </div>
                <div style={{ padding:"8px 10px" }}>
                  <div style={{ fontSize:13, fontWeight:600, color:"#e0e0ff" }}>{tp.name}</div>
                  <div style={{ fontSize:11, color:"#9ca3af" }}>{cnt} tracks</div>
                </div>
              </div>
            );
          })}
          {topics.length === 0 && (
            <div style={{ color:"#6b7280", padding:20, fontSize:14 }}>
              No topics yet. Go to <strong>My Topics</strong> to create one!
            </div>
          )}
        </div>
      </Sec>
      {favs.length > 0 && (
        <Sec title="Favorites">
          <TrackList tracks={favs} playTrack={playTrack} compact />
        </Sec>
      )}
    </div>
  );
}
function Sec({ title, children }) {
  return (
    <div style={{ marginBottom:26 }}>
      <div style={{ fontSize:12, color:"#a78bfa", textTransform:"uppercase", letterSpacing:.5, marginBottom:10, fontWeight:600 }}>{title}</div>
      {children}
    </div>
  );
}
export function TrackList({ tracks, playTrack, topics, showTopic, compact }) {
  if (!tracks.length) return null;
  return (
    <div style={{ display:"flex", flexDirection:"column", gap: compact ? 6 : 8 }}>
      {tracks.map(t => (
        <div key={t.id} onClick={() => playTrack(t)}
          style={{ display:"flex", alignItems:"center", gap:10, padding: compact ? "7px 12px" : "9px 14px", background:"#1a1a2e", borderRadius:10, border:"1px solid #2a2a4a", cursor:"pointer" }}
          onMouseOver={e => e.currentTarget.style.background="#1e1e3a"}
          onMouseOut={e  => e.currentTarget.style.background="#1a1a2e"}>
          <img src={t.thumbnail_url} alt="" style={{ width: compact?44:52, height: compact?32:38, objectFit:"cover", borderRadius:4 }} />
          <div style={{ flex:1, overflow:"hidden" }}>
            <div style={{ fontSize: compact?12:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{t.title}</div>
            <div style={{ fontSize:11, color:"#9ca3af" }}>
              {t.channelName}{showTopic && topics ? " · " + (topics.find(tp => tp.id === t.topic_id)?.name || "") : ""}
            </div>
          </div>
          {t.is_favorite && <span style={{ color:"#f59e0b", fontSize:13 }}>★</span>}
        </div>
      ))}
    </div>
  );
}
const H2 = { fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" };
EOF

# ── src/pages/Topics.js ───────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Topics.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";

export default function TopicsPage({ topics, tracks, setTopics, nav, showToast }) {
  const [newName, setNewName] = useState("");
  const [editing, setEditing] = useState(null);

  const create = () => {
    if (!newName.trim()) return;
    api.createTopic(newName.trim(), "")
      .then(t => { setTopics(p => [...p, t]); setNewName(""); showToast("Topic created ✓"); })
      .catch(e => showToast(e.message, "error"));
  };
  const del = id => {
    api.deleteTopic(id)
      .then(() => { setTopics(p => p.filter(t => t.id !== id)); showToast("Deleted"); })
      .catch(e => showToast(e.message, "error"));
  };
  const save = (id, name) => {
    if (!name.trim()) return;
    api.updateTopic(id, name.trim(), "")
      .then(upd => { setTopics(p => p.map(t => t.id === id ? upd : t)); setEditing(null); })
      .catch(e => showToast(e.message, "error"));
  };

  return (
    <div>
      <h2 style={H2}>My Topics</h2>
      <div style={{ display:"flex", gap:8, marginBottom:18 }}>
        <input value={newName} onChange={e => setNewName(e.target.value)}
          onKeyDown={e => e.key==="Enter" && create()} placeholder="New topic name…" style={INP} />
        <button onClick={create} style={BTN("#6366f1")}>+ Create</button>
      </div>
      <div style={{ display:"flex", flexDirection:"column", gap:9 }}>
        {topics.map(tp => {
          const cnt = tracks.filter(t => t.topic_id === tp.id).length;
          return (
            <div key={tp.id} style={{ display:"flex", alignItems:"center", gap:12, padding:"12px 16px", background:"#1a1a2e", borderRadius:10, border:"1px solid #2a2a4a" }}>
              {editing === tp.id
                ? <input autoFocus defaultValue={tp.name}
                    onBlur={e => save(tp.id, e.target.value)}
                    onKeyDown={e => e.key==="Enter" && save(tp.id, e.target.value)}
                    style={{ ...INP, flex:1 }} />
                : <div style={{ flex:1, cursor:"pointer" }} onClick={() => nav("topic", tp.id)}>
                    <div style={{ fontWeight:600, color:"#e0e0ff" }}>{tp.name}</div>
                    <div style={{ fontSize:12, color:"#9ca3af" }}>{cnt} tracks</div>
                  </div>
              }
              <button onClick={() => setEditing(tp.id)} style={IB} title="Rename">✏️</button>
              <button onClick={() => del(tp.id)} style={{ ...IB, color:"#ef4444" }} title="Delete">🗑</button>
            </div>
          );
        })}
        {topics.length === 0 && <div style={{ color:"#6b7280", padding:"20px 0" }}>No topics yet. Create your first one above!</div>}
      </div>
    </div>
  );
}
const H2  = { fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" };
const INP = { background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, padding:"8px 12px", color:"#e0e0ff", fontSize:13, outline:"none" };
const BTN = bg => ({ background:bg, border:"none", borderRadius:8, padding:"7px 14px", color:"#fff", cursor:"pointer", fontSize:13, fontWeight:500 });
const IB  = { background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:5, borderRadius:6, fontSize:15 };
EOF

# ── src/pages/TopicDetail.js ──────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/TopicDetail.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";

export default function TopicDetailPage({
  topic, tracks, allTopics, playTrack, deleteTrack, toggleFav,
  setTracks, addTrack, currentTrack, showToast, nav,
}) {
  const [showAdd,    setShowAdd]    = useState(false);
  const [addUrl,     setAddUrl]     = useState("");
  const [addTitle,   setAddTitle]   = useState("");
  const [addCh,      setAddCh]      = useState("");
  const [moveMenu,   setMoveMenu]   = useState(null);
  const [recs,       setRecs]       = useState([]);
  const [recLoading, setRecLoading] = useState(false);
  const [recError,   setRecError]   = useState("");

  const extractId = url => {
    const m = url.match(/(?:v=|youtu\.be\/)([^&\s?#]+)/);
    return m ? m[1] : null;
  };

  const submitAdd = () => {
    const vid = extractId(addUrl);
    if (!vid) { showToast("Invalid YouTube URL", "error"); return; }
    addTrack(vid, addTitle || `Video (${vid})`, addCh, topic.id);
    setAddUrl(""); setAddTitle(""); setAddCh(""); setShowAdd(false);
  };

  const moveTrack = (track, newTopicId) => {
    api.updateTrack(track.id, { topic_id: newTopicId })
      .then(() => {
        setTracks(p => p.map(t => t.id === track.id ? { ...t, topic_id: newTopicId } : t));
        setMoveMenu(null); showToast("Moved ✓");
      }).catch(e => showToast(e.message, "error"));
  };

  const getAIRecs = () => {
    setRecLoading(true); setRecError(""); setRecs([]);
    api.aiRecs(topic.name, topic.description || topic.name, tracks.map(t => t.title))
      .then(data => {
        if (data.error) setRecError("AI recs: " + data.error);
        else setRecs(data);
      })
      .catch(e => setRecError(e.message))
      .finally(() => setRecLoading(false));
  };

  return (
    <div>
      <button onClick={() => nav("topics")} style={{ ...BTN("#252545"), marginBottom:14, fontSize:12, display:"flex", alignItems:"center", gap:6 }}>
        ← Back to Topics
      </button>

      <div style={{ display:"flex", justifyContent:"space-between", alignItems:"flex-start", marginBottom:18 }}>
        <div>
          <h2 style={{ fontSize:20, fontWeight:700, marginBottom:4, color:"#e0e0ff" }}>{topic.name}</h2>
          {topic.description && <div style={{ fontSize:13, color:"#9ca3af", marginBottom:2 }}>{topic.description}</div>}
          <span style={{ fontSize:12, color:"#6b7280" }}>{tracks.length} tracks</span>
        </div>
        <div style={{ display:"flex", gap:8, flexShrink:0 }}>
          {tracks.length > 0 && <button onClick={() => playTrack(tracks[0], tracks)} style={BTN("#6366f1")}>▶ Play All</button>}
          <button onClick={() => setShowAdd(!showAdd)} style={BTN("#4f46e5")}>+ Add</button>
        </div>
      </div>

      {/* Add track form */}
      {showAdd && (
        <div style={{ background:"#12122a", border:"1px solid #3a3a6a", borderRadius:10, padding:16, marginBottom:16 }}>
          <div style={{ fontWeight:600, marginBottom:10, color:"#a78bfa" }}>Add YouTube Track</div>
          <input value={addUrl}   onChange={e => setAddUrl(e.target.value)}   placeholder="YouTube URL *" style={{ ...INP, width:"100%", marginBottom:7 }} />
          <input value={addTitle} onChange={e => setAddTitle(e.target.value)} placeholder="Title (optional)" style={{ ...INP, width:"100%", marginBottom:7 }} />
          <input value={addCh}    onChange={e => setAddCh(e.target.value)}    placeholder="Channel (optional)" style={{ ...INP, width:"100%", marginBottom:12 }} />
          <div style={{ display:"flex", gap:8 }}>
            <button onClick={submitAdd} style={BTN("#6366f1")}>Add</button>
            <button onClick={() => setShowAdd(false)} style={BTN("#252545")}>Cancel</button>
          </div>
        </div>
      )}

      {tracks.length === 0 && !showAdd && (
        <div style={{ textAlign:"center", padding:40, color:"#6b7280" }}>
          <div style={{ fontSize:36, marginBottom:8 }}>🎵</div>
          <div>No tracks yet. Click "+ Add" to get started.</div>
        </div>
      )}

      {/* Track list */}
      <div style={{ display:"flex", flexDirection:"column", gap:8, marginBottom:24 }}>
        {tracks.map((t, i) => {
          const active = currentTrack?.id === t.id;
          return (
            <div key={t.id} onClick={() => playTrack(t, tracks)}
              style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 14px", borderRadius:10, cursor:"pointer",
                background: active ? "#1e1e45" : "#1a1a2e",
                border: "1px solid " + (active ? "#6366f1" : "#2a2a4a") }}>
              <span style={{ color:"#6b7280", fontSize:12, width:18, textAlign:"center", flexShrink:0 }}>{i + 1}</span>
              <img src={t.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5, flexShrink:0 }} />
              <div style={{ flex:1, overflow:"hidden" }}>
                <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{t.title}</div>
                <div style={{ fontSize:11, color:"#9ca3af" }}>{t.channelName}</div>
              </div>
              {/* Favorite */}
              <button onClick={e => { e.stopPropagation(); toggleFav(t.id); }}
                style={{ background:"transparent", border:"none", color: t.is_favorite?"#f59e0b":"#6b7280", cursor:"pointer", padding:5, fontSize:16 }}>
                {t.is_favorite ? "★" : "☆"}
              </button>
              {/* Move */}
              <div style={{ position:"relative" }} onClick={e => e.stopPropagation()}>
                <button onClick={() => setMoveMenu(moveMenu === t.id ? null : t.id)}
                  style={{ background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:5, fontSize:16 }}>⇄</button>
                {moveMenu === t.id && (
                  <div style={{ position:"absolute", right:0, top:28, background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, zIndex:200, minWidth:148, boxShadow:"0 4px 20px #0008" }}>
                    <div style={{ padding:"5px 12px", fontSize:11, color:"#9ca3af", borderBottom:"1px solid #3a3a6a" }}>Move to…</div>
                    {allTopics.filter(tp => tp.id !== topic.id).map(tp => (
                      <button key={tp.id} onClick={() => moveTrack(t, tp.id)}
                        style={{ display:"block", width:"100%", padding:"7px 14px", background:"transparent", border:"none", color:"#e0e0ff", cursor:"pointer", textAlign:"left", fontSize:13 }}>
                        {tp.name}
                      </button>
                    ))}
                    {allTopics.filter(tp => tp.id !== topic.id).length === 0 &&
                      <div style={{ padding:"7px 14px", fontSize:12, color:"#6b7280" }}>No other topics</div>}
                  </div>
                )}
              </div>
              {/* Delete */}
              <button onClick={e => { e.stopPropagation(); deleteTrack(t.id); }}
                style={{ background:"transparent", border:"none", color:"#ef4444", cursor:"pointer", padding:5, fontSize:16 }}>🗑</button>
            </div>
          );
        })}
      </div>

      {/* AI Recommendations */}
      <div style={{ borderTop:"1px solid #2a2a4a", paddingTop:20 }}>
        <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:12 }}>
          <h3 style={{ margin:0, fontSize:15, color:"#a78bfa" }}>✨ AI Recommendations</h3>
          <button onClick={getAIRecs} disabled={recLoading}
            style={{ background:"#6366f1", border:"none", borderRadius:8, padding:"5px 13px", color:"#fff", cursor:"pointer", fontSize:12 }}>
            {recLoading ? "🤔 Thinking…" : "🤖 Get Recs"}
          </button>
        </div>
        {recError && <div style={{ color:"#f87171", fontSize:13, marginBottom:10 }}>{recError}</div>}
        {!recLoading && !recError && recs.length === 0 && (
          <div style={{ fontSize:13, color:"#6b7280", padding:"12px 0" }}>
            Click above to get AI-powered recommendations for "{topic.name}".
          </div>
        )}
        <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
          {recs.map(rec => (
            <div key={rec.youtube_video_id} style={{ display:"flex", alignItems:"center", gap:10, padding:"10px 14px", background:"#12122a", borderRadius:10, border:"1px solid #2a2a4a" }}>
              <img src={rec.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5, flexShrink:0 }}
                onError={e => { e.target.style.display="none"; }} />
              <div style={{ flex:1, overflow:"hidden" }}>
                <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{rec.title}</div>
                <div style={{ fontSize:11, color:"#9ca3af" }}>{rec.channelName} · <span style={{ color:"#818cf8" }}>{rec.reason}</span></div>
              </div>
              <button onClick={() => {
                addTrack(rec.youtube_video_id, rec.title, rec.channelName, topic.id);
                setRecs(p => p.filter(r => r.youtube_video_id !== rec.youtube_video_id));
              }} style={{ background:"#4f46e5", border:"none", borderRadius:8, padding:"3px 11px", color:"#fff", cursor:"pointer", fontSize:11 }}>
                + Add
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
const INP = { background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, padding:"8px 12px", color:"#e0e0ff", fontSize:13, outline:"none" };
const BTN = bg => ({ background:bg, border:"none", borderRadius:8, padding:"7px 14px", color:"#fff", cursor:"pointer", fontSize:13, fontWeight:500 });
EOF

# ── src/pages/Search.js ───────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Search.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";

export default function SearchPage({ tracks, topics, playTrack, toggleFav, addTrack, showToast }) {
  const [q,         setQ]         = useState("");
  const [tab,       setTab]       = useState("youtube");
  const [ytRes,     setYtRes]     = useState([]);
  const [ytBusy,    setYtBusy]    = useState(false);
  const [ytErr,     setYtErr]     = useState("");
  const [selTopic,  setSelTopic]  = useState((topics[0] || {}).id || "");

  const libRes = q.length > 1
    ? tracks.filter(t => t.title.toLowerCase().includes(q.toLowerCase()) || t.channelName.toLowerCase().includes(q.toLowerCase()))
    : [];

  const searchYT = () => {
    if (!q.trim()) return;
    setYtBusy(true); setYtErr(""); setYtRes([]);
    api.searchYT(q)
      .then(data => { if (data.error) setYtErr(data.error); else setYtRes(data); })
      .catch(e => setYtErr(e.message))
      .finally(() => setYtBusy(false));
  };

  return (
    <div>
      <h2 style={H2}>Search</h2>

      {/* Search bar */}
      <div style={{ display:"flex", gap:8, marginBottom:16 }}>
        <div style={{ position:"relative", flex:1 }}>
          <input value={q} onChange={e => setQ(e.target.value)}
            onKeyDown={e => e.key==="Enter" && searchYT()}
            placeholder="Search music…"
            style={{ ...INP, width:"100%", paddingLeft:36, boxSizing:"border-box" }} />
          <span style={{ position:"absolute", left:11, top:"50%", transform:"translateY(-50%)", color:"#9ca3af" }}>🔍</span>
        </div>
        <button onClick={searchYT} style={BTN("#6366f1")}>Search</button>
      </div>

      {/* Tabs */}
      <div style={{ display:"flex", gap:0, marginBottom:16, background:"#1a1a2e", borderRadius:8, padding:3, width:"fit-content" }}>
        {[["youtube","▶ YouTube"],["library","📚 My Library"]].map(([id, label]) => (
          <button key={id} onClick={() => setTab(id)} style={{
            padding:"6px 18px", border:"none", borderRadius:6, cursor:"pointer", fontSize:13,
            background: tab===id ? "#6366f1" : "transparent",
            color: tab===id ? "#fff" : "#9ca3af",
          }}>{label}</button>
        ))}
      </div>

      {/* YouTube tab */}
      {tab === "youtube" && (
        <div>
          <div style={{ display:"flex", alignItems:"center", gap:8, marginBottom:14 }}>
            <span style={{ fontSize:13, color:"#9ca3af" }}>Add to:</span>
            <select value={selTopic} onChange={e => setSelTopic(e.target.value)} style={{ ...INP, padding:"5px 10px" }}>
              {topics.map(tp => <option key={tp.id} value={tp.id}>{tp.name}</option>)}
            </select>
          </div>
          {ytBusy && <div style={{ color:"#818cf8", padding:20 }}>🔍 Searching YouTube…</div>}
          {ytErr  && <div style={{ color:"#f87171", padding:20 }}>{ytErr}</div>}
          {!ytBusy && !ytErr && ytRes.length === 0 && q && <div style={{ color:"#6b7280", padding:20 }}>No results. Try a different search.</div>}
          <div style={{ display:"flex", flexDirection:"column", gap:9 }}>
            {ytRes.map(r => {
              const blocked = r.embeddable === false;
              return (
                <div key={r.youtube_video_id} style={{ display:"flex", alignItems:"center", gap:10, padding:"10px 14px", background: blocked?"#1c0a0a":"#1a1a2e", borderRadius:10, border:"1px solid " + (blocked?"#7f1d1d":"#2a2a4a") }}>
                  <div style={{ position:"relative", flexShrink:0 }}>
                    <img src={r.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5, opacity: blocked?0.5:1 }}
                      onError={e => { e.target.style.display="none"; }} />
                    {blocked && <span style={{ position:"absolute", top:"50%", left:"50%", transform:"translate(-50%,-50%)", fontSize:14 }}>🚫</span>}
                  </div>
                  <div style={{ flex:1, overflow:"hidden" }}>
                    <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color: blocked?"#f87171":"#e0e0ff" }}>{r.title}</div>
                    <div style={{ fontSize:11, color:"#9ca3af" }}>{r.channelName}</div>
                    <div style={{ fontSize:10, color:"#6b7280", marginTop:2, display:"flex", gap:8 }}>
                      {r.views && <span>👁 {r.views}</span>}
                      {r.uploaded_ago && <span>🕐 {r.uploaded_ago}</span>}
                      {blocked ? <span style={{ color:"#f87171" }}>🚫 Embed blocked</span>
                                : r.embeddable === true && <span style={{ color:"#34d399" }}>✓ Plays in app</span>}
                    </div>
                  </div>
                  <button onClick={() => {
                    if (!selTopic) { showToast("Please select a topic first", "warn"); return; }
                    addTrack(r.youtube_video_id, r.title, r.channelName, selTopic);
                    showToast(`Added to ${topics.find(t => t.id === selTopic)?.name || "topic"} ✓`);
                  }} style={{ background:"#4f46e5", border:"none", borderRadius:8, padding:"3px 11px", color:"#fff", cursor:"pointer", fontSize:11, flexShrink:0 }}>
                    + Add
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}

      {/* Library tab */}
      {tab === "library" && (
        <div>
          {q.length > 1 && libRes.length === 0 && <div style={{ color:"#6b7280", textAlign:"center", padding:40 }}>No results in your library.</div>}
          {q.length <= 1 && <div style={{ color:"#6b7280", padding:"12px 0", fontSize:13 }}>Type something to search your library.</div>}
          <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
            {libRes.map(t => {
              const topic = topics.find(tp => tp.id === t.topic_id);
              return (
                <div key={t.id} onClick={() => playTrack(t)}
                  style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 14px", background:"#1a1a2e", borderRadius:10, border:"1px solid #2a2a4a", cursor:"pointer" }}
                  onMouseOver={e => e.currentTarget.style.background="#1e1e3a"}
                  onMouseOut={e  => e.currentTarget.style.background="#1a1a2e"}>
                  <img src={t.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5 }} />
                  <div style={{ flex:1, overflow:"hidden" }}>
                    <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{t.title}</div>
                    <div style={{ fontSize:11, color:"#9ca3af" }}>{t.channelName}{topic ? " · " + topic.name : ""}</div>
                    {t.play_count > 0 && <div style={{ fontSize:10, color:"#6b7280" }}>▶ {t.play_count} plays</div>}
                  </div>
                  <button onClick={e => { e.stopPropagation(); toggleFav(t.id); }}
                    style={{ background:"transparent", border:"none", color: t.is_favorite?"#f59e0b":"#6b7280", cursor:"pointer", padding:5, fontSize:15 }}>
                    {t.is_favorite ? "★" : "☆"}
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
const H2  = { fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" };
const INP = { background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, padding:"8px 12px", color:"#e0e0ff", fontSize:13, outline:"none" };
const BTN = bg => ({ background:bg, border:"none", borderRadius:8, padding:"7px 14px", color:"#fff", cursor:"pointer", fontSize:13, fontWeight:500 });
EOF

# ── src/pages/Pool.js ─────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Pool.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";

const DEFAULT_POOL = [
  { youtube_video_id:"JGwWNGJdvx8", title:"Shape of You",    channelName:"Ed Sheeran",         tags:["pop","upbeat"] },
  { youtube_video_id:"OPf0YbXqDm0", title:"Happy",           channelName:"Pharrell Williams",   tags:["pop","happy"] },
  { youtube_video_id:"hT_nvWreIhg", title:"Counting Stars",  channelName:"OneRepublic",         tags:["pop","inspirational"] },
  { youtube_video_id:"nfWlot6h_JM", title:"Shake It Off",    channelName:"Taylor Swift",        tags:["pop","dance"] },
  { youtube_video_id:"60ItHLz5WEA", title:"Waterfall",       channelName:"Relaxing White Noise",tags:["sleep","ambient"] },
  { youtube_video_id:"lFcSrYw2ARY", title:"Study Lo-fi Mix", channelName:"ChilledCow",          tags:["lofi","focus","study"] },
  { youtube_video_id:"9bZkp7q19f0", title:"Gangnam Style",   channelName:"PSY",                 tags:["kpop","fun","kids"] },
  { youtube_video_id:"kXYiU_JCYtU", title:"Numb",            channelName:"Linkin Park",         tags:["rock","emotional"] },
];

export default function PoolPage({ topics, tracks, addTrack, showToast }) {
  const [selTopic,  setSelTopic]  = useState((topics[0] || {}).id || "");
  const [pool,      setPool]      = useState(DEFAULT_POOL);
  const [aiLoading, setAiLoading] = useState(false);
  const [aiErr,     setAiErr]     = useState("");

  const refreshAI = () => {
    setAiLoading(true); setAiErr("");
    api.aiPool()
      .then(data => { if (data.error) setAiErr("AI: " + data.error); else setPool(data); })
      .catch(e => setAiErr(e.message))
      .finally(() => setAiLoading(false));
  };

  return (
    <div>
      <h2 style={H2}>💡 Idea Pool</h2>
      <p style={{ fontSize:13, color:"#9ca3af", marginBottom:18 }}>
        A curated list to inspire you. Pick a topic, then add any track. These are never auto-added anywhere.
      </p>

      <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", marginBottom:18, flexWrap:"wrap", gap:10 }}>
        <div style={{ display:"flex", alignItems:"center", gap:8 }}>
          <span style={{ fontSize:13, color:"#9ca3af" }}>Add to:</span>
          <select value={selTopic} onChange={e => setSelTopic(e.target.value)} style={{ ...INP, padding:"6px 10px" }}>
            {topics.map(tp => <option key={tp.id} value={tp.id}>{tp.name}</option>)}
          </select>
        </div>
        <button onClick={refreshAI} disabled={aiLoading} style={{ background:"#6366f1", border:"none", borderRadius:8, padding:"7px 14px", color:"#fff", cursor:"pointer", fontSize:12 }}>
          {aiLoading ? "🤔 Thinking…" : "🤖 AI Refresh"}
        </button>
      </div>

      {aiErr && <div style={{ color:"#f87171", fontSize:13, marginBottom:12 }}>{aiErr}</div>}

      <div style={{ display:"flex", flexDirection:"column", gap:9 }}>
        {pool.map(rec => {
          const vid   = rec.youtube_video_id;
          const thumb = rec.thumbnail_url || `https://img.youtube.com/vi/${vid}/mqdefault.jpg`;
          const tags  = Array.isArray(rec.tags) ? rec.tags.join(" · ") : (rec.tags || "");
          return (
            <div key={vid} style={{ display:"flex", alignItems:"center", gap:10, padding:"10px 14px", background:"#1a1a2e", borderRadius:10, border:"1px solid #2a2a4a" }}>
              <img src={thumb} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5, flexShrink:0 }}
                onError={e => { e.target.style.display="none"; }} />
              <div style={{ flex:1, overflow:"hidden" }}>
                <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{rec.title}</div>
                <div style={{ fontSize:11, color:"#9ca3af" }}>{rec.channelName}</div>
                {tags && <div style={{ fontSize:11, color:"#6366f1", marginTop:2 }}>{tags}</div>}
                {rec.reason && <div style={{ fontSize:11, color:"#818cf8", marginTop:1 }}>{rec.reason}</div>}
              </div>
              <button onClick={() => {
                if (!selTopic) { showToast("Please select a topic first", "warn"); return; }
                addTrack(vid, rec.title, rec.channelName, selTopic);
                showToast(`Added to ${topics.find(t => t.id === selTopic)?.name || "topic"} ✓`);
              }} style={{ background:"#4f46e5", border:"none", borderRadius:8, padding:"3px 11px", color:"#fff", cursor:"pointer", fontSize:11, flexShrink:0 }}>
                + Add
              </button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
const H2  = { fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" };
const INP = { background:"#252545", border:"1px solid #3a3a6a", borderRadius:8, padding:"8px 12px", color:"#e0e0ff", fontSize:13, outline:"none" };
EOF

# ── src/pages/Favorites.js ────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Favorites.js" << 'EOF'
import React from "react";

export default function FavoritesPage({ tracks, topics, playTrack, toggleFav }) {
  return (
    <div>
      <h2 style={{ fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" }}>⭐ Favorites</h2>
      {tracks.length === 0 && (
        <div style={{ color:"#6b7280", textAlign:"center", padding:40 }}>
          No favorites yet. Star a track to save it here.
        </div>
      )}
      <div style={{ display:"flex", flexDirection:"column", gap:8 }}>
        {tracks.map(t => {
          const topic = topics.find(tp => tp.id === t.topic_id);
          return (
            <div key={t.id} onClick={() => playTrack(t)}
              style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 14px", background:"#1a1a2e", borderRadius:10, border:"1px solid #2a2a4a", cursor:"pointer" }}
              onMouseOver={e => e.currentTarget.style.background="#1e1e3a"}
              onMouseOut={e  => e.currentTarget.style.background="#1a1a2e"}>
              <img src={t.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:5 }} />
              <div style={{ flex:1, overflow:"hidden" }}>
                <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e0e0ff" }}>{t.title}</div>
                <div style={{ fontSize:11, color:"#9ca3af" }}>{t.channelName}{topic ? " · " + topic.name : ""}</div>
                {t.play_count > 0 && <div style={{ fontSize:10, color:"#6b7280" }}>▶ {t.play_count} plays</div>}
              </div>
              <button onClick={e => { e.stopPropagation(); toggleFav(t.id); }}
                style={{ background:"transparent", border:"none", color:"#f59e0b", cursor:"pointer", padding:5, fontSize:18 }}>★</button>
            </div>
          );
        })}
      </div>
    </div>
  );
}
EOF

# ── src/pages/Settings.js ─────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Settings.js" << 'EOF'
import React from "react";

export default function SettingsPage({ audioMode, setAudioMode, speed, setSpeed, loop, setLoop, shuffle, setShuffle, sleepTimer, startSleepTimer }) {
  const Row = ({ label, children }) => (
    <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"12px 16px", borderBottom:"1px solid #2a2a4a" }}>
      <span style={{ fontSize:13, color:"#d1d5db" }}>{label}</span>
      <div style={{ display:"flex", gap:5, flexWrap:"wrap", justifyContent:"flex-end" }}>{children}</div>
    </div>
  );
  const Grp = ({ title, children }) => (
    <div style={{ marginBottom:22 }}>
      <div style={{ fontSize:11, color:"#a78bfa", fontWeight:600, marginBottom:8, textTransform:"uppercase", letterSpacing:.5 }}>{title}</div>
      <div style={{ background:"#1a1a2e", border:"1px solid #2a2a4a", borderRadius:10, overflow:"hidden" }}>{children}</div>
    </div>
  );
  const B = (active) => ({ background: active?"#6366f1":"#252545", border:"none", borderRadius:7, padding:"3px 11px", color:"#fff", cursor:"pointer", fontSize:11 });

  return (
    <div style={{ maxWidth:500 }}>
      <h2 style={{ fontSize:20, fontWeight:700, marginBottom:18, color:"#e0e0ff" }}>⚙️ Settings</h2>
      <Grp title="Playback">
        <Row label="Default Mode">
          {[["video","🎬 Video"],["audio","🎵 Audio"],["hidden","🙈 Hidden"]].map(([m, l]) => (
            <button key={m} onClick={() => setAudioMode(m)} style={B(audioMode===m)}>{l}</button>
          ))}
        </Row>
        <Row label="Playback Speed">
          {[0.75, 1, 1.25, 1.5, 2].map(s => (
            <button key={s} onClick={() => setSpeed(s)} style={B(speed===s)}>{s}x</button>
          ))}
        </Row>
        <Row label="Loop Mode">
          {[["none","Off"],["all","All"],["one","One"]].map(([v, l]) => (
            <button key={v} onClick={() => setLoop(v)} style={B(loop===v)}>{l}</button>
          ))}
        </Row>
        <Row label="Shuffle">
          <button onClick={() => setShuffle(!shuffle)} style={B(shuffle)}>{shuffle ? "On ✓" : "Off"}</button>
        </Row>
      </Grp>
      <Grp title="Sleep Timer">
        <Row label="Auto-pause after">
          {[null, 15, 30, 45, 60].map(m => (
            <button key={m ?? 0} onClick={() => startSleepTimer(m)} style={B(sleepTimer===m)}>
              {m ? `${m}m` : "Off"}
            </button>
          ))}
        </Row>
      </Grp>
      <Grp title="About">
        <Row label="Version"><span style={{ fontSize:12, color:"#6b7280" }}>TopicTune 1.0</span></Row>
        <Row label="Data"><span style={{ fontSize:12, color:"#6b7280" }}>Stored in SQLite (local)</span></Row>
      </Grp>
    </div>
  );
}
EOF

echo "✅ React 前端文件写入完成"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 3: ELECTRON
# ═══════════════════════════════════════════════════════════════════════════════
echo "── [3/4] Electron ──────────────────────────────────────────────────────────"
mkdir -p "$ROOT/electron"

# ── electron/package.json ─────────────────────────────────────────────────────
cat > "$ROOT/electron/package.json" << 'EOF'
{
  "name": "topictune",
  "version": "1.0.0",
  "description": "TopicTune — YouTube Audio Player",
  "main": "main.js",
  "scripts": {
    "start": "electron .",
    "build": "electron-builder --mac --universal",
    "build-x64": "electron-builder --mac --x64",
    "build-arm": "electron-builder --mac --arm64"
  },
  "build": {
    "appId": "com.topictune.app",
    "productName": "TopicTune",
    "mac": {
      "category": "public.app-category.music",
      "target": [{ "target": "dmg", "arch": ["universal"] }]
    },
    "extraResources": [
      { "from": "../backend",        "to": "backend",        "filter": ["**/*", "!venv/**", "!__pycache__/**", "!*.pyc"] },
      { "from": "../frontend/build", "to": "frontend/build" }
    ],
    "files": ["main.js", "preload.js"]
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-builder": "^24.0.0"
  }
}
EOF

# ── electron/main.js ──────────────────────────────────────────────────────────
cat > "$ROOT/electron/main.js" << 'EOF'
"use strict";
const { app, BrowserWindow, BrowserView, ipcMain } = require("electron");
const path   = require("path");
const { spawn } = require("child_process");
const fs     = require("fs");
const http   = require("http");

// ── Dev mode: run with --dev flag ─────────────────────────────────────────────
const isDev = process.argv.includes("--dev");

// ── Fully portable: all paths relative to this file / resources ───────────────
function getRoot() {
  // In dev:  __dirname = topictune/electron/
  // Packaged: process.resourcesPath = .../TopicTune.app/Contents/Resources/
  return isDev ? path.join(__dirname, "..") : process.resourcesPath;
}

let mainWindow = null;
let ytView     = null;
let backendProc= null;
const BACKEND_PORT = 8000;

// ── Start FastAPI ─────────────────────────────────────────────────────────────
function startBackend() {
  const root       = getRoot();
  const backendDir = path.join(root, "backend");
  const venvPython = path.join(backendDir, "venv", "bin", "python3");
  const python     = fs.existsSync(venvPython) ? venvPython : "python3";

  console.log("[main] Backend dir:", backendDir);
  console.log("[main] Python:", python);

  backendProc = spawn(python, [
    "-m", "uvicorn", "main:app",
    "--host", "127.0.0.1",
    "--port", String(BACKEND_PORT),
    "--workers", "1",
  ], {
    cwd: backendDir,
    env: { ...process.env, PYTHONPATH: backendDir },
    stdio: ["ignore", "pipe", "pipe"],
  });

  backendProc.stdout.on("data", d => process.stdout.write("[backend] " + d));
  backendProc.stderr.on("data", d => process.stderr.write("[backend] " + d));
  backendProc.on("exit", code => console.log("[backend] exited:", code));
}

// ── Wait until /  responds ────────────────────────────────────────────────────
function waitForBackend(cb, attempts = 0) {
  if (attempts > 60) { console.log("[main] Backend timeout"); cb(); return; }
  const req = http.get(`http://127.0.0.1:${BACKEND_PORT}/`, res => {
    if (res.statusCode === 200) { console.log("[main] Backend ready"); cb(); }
    else retry();
  });
  req.on("error", retry);
  req.end();
  function retry() { setTimeout(() => waitForBackend(cb, attempts + 1), 500); }
}

// ── Frontend URL ──────────────────────────────────────────────────────────────
function getFrontendURL() {
  if (isDev) return `http://localhost:3000`;
  const idx = path.join(getRoot(), "frontend", "build", "index.html");
  return fs.existsSync(idx) ? "file://" + idx : `http://localhost:3000`;
}

// ── Create window ─────────────────────────────────────────────────────────────
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200, height: 800,
    minWidth: 900, minHeight: 600,
    backgroundColor: "#0f0f1a",
    titleBarStyle: "hiddenInset",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: false,
    },
  });

  // ── YouTube BrowserView ───────────────────────────────────────────────────
  ytView = new BrowserView({
    webPreferences: {
      contextIsolation: false,
      nodeIntegration: false,
      webSecurity: false,
    },
  });
  mainWindow.addBrowserView(ytView);
  ytView._mode = "hidden";
  positionYTView("hidden");

  // Inject backend URL into window so api.js can use it without hardcoding
  mainWindow.webContents.on("did-finish-load", () => {
    mainWindow.webContents.executeJavaScript(
      `window.BACKEND_URL = "http://127.0.0.1:${BACKEND_PORT}";`
    ).catch(() => {});
  });

  mainWindow.loadURL(getFrontendURL());
  if (isDev) mainWindow.webContents.openDevTools({ mode: "detach" });

  mainWindow.on("resize", () => positionYTView(ytView._mode));
  mainWindow.on("closed", () => { mainWindow = null; });
}

// ── Position BrowserView ──────────────────────────────────────────────────────
// Layout constants (must match React CSS)
const HDR  = 52;   // header height
const SIDE = 185;  // sidebar width
const MINI = 56;   // mini-player height

function positionYTView(mode) {
  if (!mainWindow || !ytView) return;
  ytView._mode = mode;
  const [W, H] = mainWindow.getContentSize();
  const cW = W - SIDE;
  const cH = H - HDR - MINI;

  if (mode === "hidden") {
    ytView.setBounds({ x: -9999, y: -9999, width: 1, height: 1 });
  } else if (mode === "audio") {
    // Small 240×135 video strip pinned top-right of content area
    ytView.setBounds({ x: W - 240 - 20, y: HDR + 70, width: 240, height: 135 });
  } else {
    // "video" — centered 16:9 box in content area
    const mxW = Math.min(640, cW - 44);
    const vidH = Math.round(mxW * 9 / 16);
    ytView.setBounds({
      x: SIDE + Math.round((cW - mxW) / 2),
      y: HDR + 90,
      width: mxW, height: vidH,
    });
  }
}

// ── IPC: load video ───────────────────────────────────────────────────────────
ipcMain.on("yt-load", (_, { videoId, mode }) => {
  if (!ytView) return;
  const url = `https://www.youtube.com/embed/${videoId}?autoplay=1&rel=0&enablejsapi=1`;
  ytView.webContents.loadURL(url);
  positionYTView(mode || "audio");
});

// ── IPC: play/pause via direct video element control ─────────────────────────
ipcMain.on("yt-play", () => {
  ytView?.webContents.executeJavaScript(
    "document.querySelector('video')?.play()"
  ).catch(() => {});
});
ipcMain.on("yt-pause", () => {
  ytView?.webContents.executeJavaScript(
    "document.querySelector('video')?.pause()"
  ).catch(() => {});
});
ipcMain.on("yt-stop", () => {
  if (!ytView) return;
  ytView.webContents.executeJavaScript("document.querySelector('video')?.pause()").catch(() => {});
  ytView.webContents.loadURL("about:blank");
  positionYTView("hidden");
});
ipcMain.on("yt-speed", (_, { speed }) => {
  ytView?.webContents.executeJavaScript(
    `var v=document.querySelector('video');if(v)v.playbackRate=${speed};`
  ).catch(() => {});
});
ipcMain.on("yt-mode", (_, { mode }) => {
  positionYTView(mode);
});

// ── Poll video state (ended / playing / paused) ───────────────────────────────
let pollInterval = null;
function startStatePoll() {
  if (pollInterval) return;
  pollInterval = setInterval(() => {
    if (!ytView || !mainWindow) return;
    ytView.webContents.executeJavaScript(
      "(()=>{const v=document.querySelector('video');if(!v)return null;return{ended:v.ended,paused:v.paused,ct:v.currentTime,dur:v.duration};})()"
    ).then(s => {
      if (!s || !mainWindow) return;
      if (s.ended)                           mainWindow.webContents.send("yt-state", { type:"ended" });
      else if (!s.paused && s.ct > 0)        mainWindow.webContents.send("yt-state", { type:"playing" });
      else if (s.paused && s.ct > 0)         mainWindow.webContents.send("yt-state", { type:"paused" });
    }).catch(() => {});
  }, 1000);
}
ipcMain.on("yt-start-poll", () => startStatePoll());

// ── App lifecycle ─────────────────────────────────────────────────────────────
app.whenReady().then(() => {
  startBackend();
  waitForBackend(() => { createWindow(); startStatePoll(); });
});
app.on("window-all-closed", () => {
  if (backendProc) { try { backendProc.kill("SIGTERM"); } catch(_) {} backendProc = null; }
  if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
  app.quit();
});
app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
EOF

# ── electron/preload.js ───────────────────────────────────────────────────────
cat > "$ROOT/electron/preload.js" << 'EOF'
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("electronYT", {
  load:                (videoId, mode) => ipcRenderer.send("yt-load",  { videoId, mode: mode || "audio" }),
  play:                ()              => ipcRenderer.send("yt-play"),
  pause:               ()              => ipcRenderer.send("yt-pause"),
  stop:                ()              => ipcRenderer.send("yt-stop"),
  setSpeed:            (speed)         => ipcRenderer.send("yt-speed", { speed }),
  setMode:             (mode)          => ipcRenderer.send("yt-mode",  { mode }),
  startPoll:           ()              => ipcRenderer.send("yt-start-poll"),
  onState:             (cb)            => ipcRenderer.on("yt-state", (_, data) => cb(data)),
  removeStateListeners:()              => ipcRenderer.removeAllListeners("yt-state"),
});
EOF

cd "$ROOT/electron"
npm install --silent
echo "✅ Electron 安装完成"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 4: PORTABLE SCRIPTS
# ═══════════════════════════════════════════════════════════════════════════════
echo "── [4/4] 生成启动脚本 ──────────────────────────────────────────────────────"

# ── start.sh (dev mode) ───────────────────────────────────────────────────────
cat > "$ROOT/start.sh" << 'SHEOF'
#!/usr/bin/env bash
# ── Fully portable: works from any directory ──────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       TopicTune — Starting Desktop App           ║"
echo "╚══════════════════════════════════════════════════╝"
echo "Project: $DIR"
echo ""

# Kill old processes on our ports
lsof -ti:8000 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
sleep 1

# ── Start FastAPI backend ──────────────────────────────────────────────────────
echo "▶ Starting backend (FastAPI)..."
VENV_PYTHON="$DIR/backend/venv/bin/python3"
if [ ! -f "$VENV_PYTHON" ]; then
  echo "❌ venv not found. Run: $DIR/rebuild_venv.sh"
  exit 1
fi

cd "$DIR/backend"
"$VENV_PYTHON" -m uvicorn main:app --host 127.0.0.1 --port 8000 --workers 1 &
BACKEND_PID=$!
cd "$DIR"

echo "  Waiting for backend..."
for i in $(seq 1 40); do
  if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1; then
    echo "  ✅ Backend ready (http://127.0.0.1:8000)"
    break
  fi
  sleep 1
done

# ── Start React dev server ─────────────────────────────────────────────────────
echo "▶ Starting frontend (React dev server)..."
cd "$DIR/frontend"
BROWSER=none npm start &
FRONTEND_PID=$!
cd "$DIR"

echo "  Waiting for React dev server..."
for i in $(seq 1 90); do
  if curl -s http://localhost:3000/ > /dev/null 2>&1; then
    echo "  ✅ Frontend ready (http://localhost:3000)"
    break
  fi
  sleep 1
done

# ── Launch Electron ────────────────────────────────────────────────────────────
echo "▶ Launching Electron desktop app..."
cd "$DIR/electron"
npx electron . --dev
EXIT_CODE=$?

# ── Cleanup ───────────────────────────────────────────────────────────────────
echo "Shutting down..."
kill $BACKEND_PID  2>/dev/null || true
kill $FRONTEND_PID 2>/dev/null || true
lsof -ti:8000 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
echo "Done."
exit $EXIT_CODE
SHEOF
chmod +x "$ROOT/start.sh"

# ── build.sh ──────────────────────────────────────────────────────────────────
cat > "$ROOT/build.sh" << 'SHEOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════╗"
echo "║     TopicTune — Building .app + .dmg             ║"
echo "╚══════════════════════════════════════════════════╝"

echo "▶ Building React production bundle..."
cd "$DIR/frontend"
npm run build
echo "✅ React built"

echo "▶ Building Electron .app..."
cd "$DIR/electron"
npx electron-builder --mac --universal
echo ""
echo "✅ Done! Output: $DIR/electron/dist/"
echo "   Double-click TopicTune.dmg to install."
SHEOF
chmod +x "$ROOT/build.sh"

# ── rebuild_venv.sh ───────────────────────────────────────────────────────────
cat > "$ROOT/rebuild_venv.sh" << 'SHEOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "▶ Rebuilding Python venv at $DIR/backend/venv..."
rm -rf "$DIR/backend/venv"
python3 -m venv "$DIR/backend/venv"
source "$DIR/backend/venv/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet \
  fastapi "uvicorn[standard]" sqlalchemy python-multipart \
  httpx python-dotenv "python-jose[cryptography]" bcrypt yt-dlp
deactivate
echo "✅ venv rebuilt. Now run: ./start.sh"
SHEOF
chmod +x "$ROOT/rebuild_venv.sh"

# ── web_only.sh — run without Electron (pure browser, for other devices) ─────
cat > "$ROOT/web_only.sh" << 'SHEOF'
#!/usr/bin/env bash
# Run TopicTune as a web app (no Electron) — accessible from any device on LAN
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get local IP
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

lsof -ti:8000 | xargs kill -9 2>/dev/null || true
lsof -ti:3000 | xargs kill -9 2>/dev/null || true
sleep 1

echo "▶ Starting backend..."
source "$DIR/backend/venv/bin/activate"
cd "$DIR/backend"
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 &
BPID=$!
deactivate
cd "$DIR"

echo "▶ Starting frontend..."
# Set API URL to local IP for LAN access
echo "REACT_APP_API_URL=http://${LOCAL_IP}:8000" > "$DIR/frontend/.env.local"
cd "$DIR/frontend"
BROWSER=none npm start &
FPID=$!
cd "$DIR"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  TopicTune Web Mode                              ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  This device:  http://localhost:3000             ║"
echo "║  Other devices: http://${LOCAL_IP}:3000          ║"
echo "╚══════════════════════════════════════════════════╝"
echo "Press Ctrl+C to stop."

trap "kill $BPID $FPID 2>/dev/null; lsof -ti:8000,3000 | xargs kill -9 2>/dev/null; exit 0" INT
wait
SHEOF
chmod +x "$ROOT/web_only.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                     ✅ 安装完成！                                       ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  项目位置: $ROOT"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║                                                                          ║"
echo "║  第一步 — 填写 API Key:                                                  ║"
echo "║    nano $ROOT/backend/.env               ║"
echo "║    设置: ANTHROPIC_API_KEY=sk-ant-xxx     (AI功能需要)                   ║"
echo "║    设置: SECRET_KEY=任意32位以上随机字符串                               ║"
echo "║                                                                          ║"
echo "║  第二步 — 启动桌面 App (Electron):                                       ║"
echo "║    $ROOT/start.sh                                        ║"
echo "║                                                                          ║"
echo "║  第三步 — 构建 .app/.dmg (可选):                                         ║"
echo "║    $ROOT/build.sh                                        ║"
echo "║                                                                          ║"
echo "║  仅网页模式 (可从局域网其他设备访问):                                    ║"
echo "║    $ROOT/web_only.sh                                     ║"
echo "║                                                                          ║"
echo "║  移动项目后重建 venv:                                                    ║"
echo "║    cd /新位置/topictune && ./rebuild_venv.sh                             ║"
echo "║                                                                          ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  功能清单:                                                               ║"
echo "║  ✅ 完全便携（无硬编码路径）                                             ║"
echo "║  ✅ Electron BrowserView 播放 YouTube（无嵌入限制）                      ║"
echo "║  ✅ Video / Audio / Hidden 三种模式（正常切换）                          ║"
echo "║  ✅ Play/Pause/Next/Prev/Speed/Loop/Shuffle 全部正常                    ║"
echo "║  ✅ Sleep Timer 睡眠定时器                                               ║"
echo "║  ✅ Mini Player 迷你播放器（所有页面可见）                               ║"
echo "║  ✅ Topics 主题管理（创建/重命名/删除）                                  ║"
echo "║  ✅ Tracks 曲目管理（添加/删除/移动/收藏）                               ║"
echo "║  ✅ YouTube 搜索（无需API Key，含播放量/上传时间/嵌入状态）              ║"
echo "║  ✅ Idea Pool（默认推荐 + AI刷新）                                       ║"
echo "║  ✅ AI 推荐（每个Topic专属推荐，需Anthropic Key）                        ║"
echo "║  ✅ 多用户登录 + Guest 模式                                              ║"
echo "║  ✅ SQLite 持久化存储（收藏/历史/播放次数）                              ║"
echo "║  ✅ 局域网 Web 模式（web_only.sh）                                       ║"
echo "║  ✅ 支持 Intel + Apple Silicon (universal build)                         ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
