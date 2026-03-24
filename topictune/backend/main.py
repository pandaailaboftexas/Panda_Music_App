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
    allow_origins=["http://localhost:3000", "http://127.0.0.1:3000", "http://192.168.0.159:3000"],
    allow_credentials=True, allow_methods=["*"], allow_headers=["*"])
app.include_router(auth.router,            prefix="/api/auth")
app.include_router(topics.router,          prefix="/api/topics")
app.include_router(tracks.router,          prefix="/api/tracks")
app.include_router(player.router,          prefix="/api/player")
app.include_router(recommendations.router, prefix="/api/recommendations")

@app.get("/")
def root():
    return {"status": "TopicTune API v2 running"}
