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
