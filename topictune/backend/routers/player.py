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
