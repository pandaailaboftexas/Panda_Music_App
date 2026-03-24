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
