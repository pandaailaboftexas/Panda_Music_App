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
