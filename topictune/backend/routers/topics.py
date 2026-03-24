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
