#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  TopicTune — 單機版桌面應用
#
#  核心：Node.js 後端直接嵌入 Electron，即時啟動，無需等待
#  修復：Topic 創建問題（純 SQLite，無 Python 依賴）
#
#  使用方法：
#    chmod +x topictune_build.sh && ./topictune_build.sh
#  輸出：
#    dist/TopicTune-AppleSilicon.dmg  → M1/M2/M3 Mac
#    dist/TopicTune-Intel.dmg         → Intel Mac
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/topictune_src"
DIST_DIR="$SCRIPT_DIR/dist"
PORT=8765

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      TopicTune — 打包單機版 .dmg                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

for cmd in node npm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ 缺少 $cmd，請安裝: brew install node"
    exit 1
  fi
done
echo "✅ Node $(node --version)  npm $(npm --version)"
echo ""

rm -rf "$ROOT" "$DIST_DIR"
mkdir -p "$ROOT"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: ELECTRON + NODE.JS 後端
# ═══════════════════════════════════════════════════════════════════════════════
echo "── [1/3] 寫入 Electron + Node.js 後端 ─────────────────────────────────────"
mkdir -p "$ROOT/electron"

cat > "$ROOT/electron/package.json" << PKGJSON
{
  "name": "topictune",
  "version": "1.0.0",
  "description": "TopicTune",
  "main": "main.js",
  "scripts": {
    "start":       "electron .",
    "build-arm64": "electron-builder --mac --arm64",
    "build-x64":   "electron-builder --mac --x64"
  },
  "build": {
    "appId": "com.topictune.app",
    "productName": "TopicTune",
    "artifactName": "TopicTune-\${arch}.\${ext}",
    "mac": {
      "category": "public.app-category.music",
      "darkModeSupport": true,
      "target": [
        { "target": "dmg", "arch": ["arm64"] },
        { "target": "dmg", "arch": ["x64"]   }
      ]
    },
    "dmg": {
      "title": "TopicTune",
      "contents": [
        { "x": 150, "y": 200 },
        { "x": 390, "y": 200, "type": "link", "path": "/Applications" }
      ]
    },
    "extraResources": [
      { "from": "../frontend/build", "to": "frontend" }
    ],
    "files": [
      "main.js",
      "preload.js",
      "server.js",
      "node_modules/**/*"
    ],
    "asar": false
  },
  "dependencies": {
    "better-sqlite3": "^9.4.3",
    "express": "^4.18.2",
    "cors": "^2.8.5"
  },
  "devDependencies": {
    "electron": "^28.0.0",
    "electron-builder": "^24.0.0"
  }
}
PKGJSON

# ── server.js ─────────────────────────────────────────────────────────────────
cat > "$ROOT/electron/server.js" << 'EOF'
"use strict";
const express  = require("express");
const cors     = require("cors");
const path     = require("path");
const fs       = require("fs");
const Database = require("better-sqlite3");

let db = null;

function nid() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

function getDataDir(electronApp) {
  const dir = path.join(electronApp.getPath("userData"), "TopicTune");
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function initDB(dbPath) {
  db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(`
    CREATE TABLE IF NOT EXISTS topics (
      id          TEXT PRIMARY KEY,
      name        TEXT NOT NULL,
      description TEXT DEFAULT '',
      created_at  TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS tracks (
      id               TEXT PRIMARY KEY,
      topic_id         TEXT NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
      youtube_video_id TEXT NOT NULL,
      title            TEXT NOT NULL,
      channel_name     TEXT DEFAULT 'Unknown',
      thumbnail_url    TEXT DEFAULT '',
      tags             TEXT DEFAULT '',
      is_favorite      INTEGER DEFAULT 0,
      play_count       INTEGER DEFAULT 0,
      created_at       TEXT DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS history (
      id        TEXT PRIMARY KEY,
      track_id  TEXT,
      video_id  TEXT NOT NULL,
      title     TEXT DEFAULT '',
      played_at TEXT DEFAULT (datetime('now'))
    );
  `);
}

const fmt = t => t ? { ...t, is_favorite: t.is_favorite === 1 } : null;

function startServer(electronApp, port) {
  const dataDir = getDataDir(electronApp);
  initDB(path.join(dataDir, "topictune.db"));

  // 讀取 .env（AI key）
  const envPath = path.join(dataDir, ".env");
  if (fs.existsSync(envPath)) {
    fs.readFileSync(envPath, "utf8").split("\n").forEach(line => {
      const m = line.match(/^([A-Z_]+)\s*=\s*(.+)$/);
      if (m) process.env[m[1]] = m[2].trim();
    });
  }

  const app = express();
  app.use(cors());
  app.use(express.json());

  // 健康檢查
  app.get("/", (_, res) => res.json({ status: "ok" }));

  // ── Topics ─────────────────────────────────────────────────────────────────
  app.get("/api/topics", (_, res) => {
    try {
      res.json(db.prepare("SELECT * FROM topics ORDER BY created_at ASC").all());
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.post("/api/topics", (req, res) => {
    try {
      const name = (req.body.name || "").trim();
      if (!name) return res.status(400).json({ error: "Name is required" });
      const id = nid();
      const desc = (req.body.description || "").trim();
      db.prepare("INSERT INTO topics (id, name, description) VALUES (?, ?, ?)").run(id, name, desc);
      res.json(db.prepare("SELECT * FROM topics WHERE id = ?").get(id));
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.patch("/api/topics/:id", (req, res) => {
    try {
      const t = db.prepare("SELECT * FROM topics WHERE id = ?").get(req.params.id);
      if (!t) return res.status(404).json({ error: "Not found" });
      const name = (req.body.name || t.name).trim();
      const desc = req.body.description !== undefined ? req.body.description : t.description;
      db.prepare("UPDATE topics SET name=?, description=? WHERE id=?").run(name, desc, req.params.id);
      res.json(db.prepare("SELECT * FROM topics WHERE id=?").get(req.params.id));
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.delete("/api/topics/:id", (req, res) => {
    try {
      db.prepare("DELETE FROM topics WHERE id=?").run(req.params.id);
      res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  // ── Tracks ─────────────────────────────────────────────────────────────────
  app.get("/api/tracks", (_, res) => {
    try {
      res.json(db.prepare("SELECT * FROM tracks ORDER BY created_at ASC").all().map(fmt));
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.post("/api/tracks", (req, res) => {
    try {
      const { topic_id, youtube_video_id, title, channel_name = "Unknown", thumbnail_url, tags = "" } = req.body;
      if (!topic_id || !youtube_video_id || !title)
        return res.status(400).json({ error: "Missing required fields" });
      const ex = db.prepare("SELECT id FROM tracks WHERE topic_id=? AND youtube_video_id=?").get(topic_id, youtube_video_id);
      if (ex) return res.status(400).json({ error: "在此Topics中" });
      const id    = nid();
      const thumb = thumbnail_url || `https://img.youtube.com/vi/${youtube_video_id}/mqdefault.jpg`;
      db.prepare("INSERT INTO tracks (id,topic_id,youtube_video_id,title,channel_name,thumbnail_url,tags) VALUES (?,?,?,?,?,?,?)")
        .run(id, topic_id, youtube_video_id, title, channel_name, thumb, tags);
      res.json(fmt(db.prepare("SELECT * FROM tracks WHERE id=?").get(id)));
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.patch("/api/tracks/:id", (req, res) => {
    try {
      const t = db.prepare("SELECT * FROM tracks WHERE id=?").get(req.params.id);
      if (!t) return res.status(404).json({ error: "Not found" });
      const sets = [], vals = [];
      for (const f of ["title", "channel_name", "topic_id", "tags"]) {
        if (req.body[f] !== undefined) { sets.push(`${f}=?`); vals.push(req.body[f]); }
      }
      if (req.body.is_favorite !== undefined) {
        sets.push("is_favorite=?"); vals.push(req.body.is_favorite ? 1 : 0);
      }
      if (sets.length) { vals.push(req.params.id); db.prepare(`UPDATE tracks SET ${sets.join(",")} WHERE id=?`).run(...vals); }
      res.json(fmt(db.prepare("SELECT * FROM tracks WHERE id=?").get(req.params.id)));
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.delete("/api/tracks/:id", (req, res) => {
    try {
      db.prepare("DELETE FROM tracks WHERE id=?").run(req.params.id);
      res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  app.post("/api/tracks/:id/played", (req, res) => {
    try {
      const t = db.prepare("SELECT * FROM tracks WHERE id=?").get(req.params.id);
      if (t) {
        db.prepare("UPDATE tracks SET play_count=play_count+1 WHERE id=?").run(req.params.id);
        db.prepare("INSERT INTO history (id,track_id,video_id,title) VALUES (?,?,?,?)").run(nid(), req.params.id, t.youtube_video_id, t.title);
      }
      res.json({ ok: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  // ── YouTube Search ───────────────────────────────────────────────────────────
  app.get("/api/recommendations/search", (req, res) => {
    const q = (req.query.q || "").trim();
    if (!q) return res.json([]);
    const { spawnSync } = require("child_process");
    const candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "yt-dlp"];
    const ytdlp = candidates.find(c => { try { return fs.existsSync(c); } catch (_) { return false; } }) || "yt-dlp";
    const result = spawnSync(ytdlp, [
      "--dump-json", "--flat-playlist", "--no-warnings",
      "--default-search", "ytsearch10", `ytsearch10:${q}`,
    ], { timeout: 20000, encoding: "utf8" });
    if (result.error || result.status !== 0) {
      return res.json({ error: "yt-dlp not installed. Run: brew install yt-dlp" });
    }
    try {
      const items = result.stdout.trim().split("\n").filter(Boolean)
        .map(line => { try { return JSON.parse(line); } catch (_) { return null; } })
        .filter(Boolean)
        .map(r => {
          const vid = r.id || "";
          const vc  = r.view_count || 0;
          const views = vc >= 1e6 ? `${(vc/1e6).toFixed(1)}M` : vc >= 1000 ? `${Math.floor(vc/1000)}K` : "";
          return { youtube_video_id: vid, title: r.title || "", channelName: r.uploader || r.channel || "", thumbnail_url: `https://img.youtube.com/vi/${vid}/mqdefault.jpg`, views, uploaded_ago: "", embeddable: null };
        }).filter(r => r.youtube_video_id);
      res.json(items);
    } catch (e) { res.status(500).json({ error: e.message }); }
  });

  // ── AI Recommendations ────────────────────────────────────────────────────────────────
  app.post("/api/recommendations/ai-recs", async (req, res) => {
    const apiKey = process.env.ANTHROPIC_API_KEY || "";
    if (!apiKey || apiKey.startsWith("your_")) return res.json({ error: "Please set ANTHROPIC_API_KEY in your .env file" });
    try {
      const { topic_name, topic_desc, track_titles = [] } = req.body;
      const prompt = `推薦6tracksYouTube音樂給Topics"${topic_name}"。現有：${track_titles.join(",")||"無"}。僅返回JSON數組：[{"youtube_video_id":"ID","title":"T","channelName":"C","reason":"R"}]`;
      const text = await callAnthropic(apiKey, prompt, 1000);
      const recs = JSON.parse(text.replace(/```json|```/g, "").trim());
      res.json(recs.map(x => ({ ...x, thumbnail_url: `https://img.youtube.com/vi/${x.youtube_video_id}/mqdefault.jpg` })));
    } catch (e) { res.json({ error: e.message }); }
  });

  app.post("/api/recommendations/ai-pool", async (req, res) => {
    const apiKey = process.env.ANTHROPIC_API_KEY || "";
    if (!apiKey || apiKey.startsWith("your_")) return res.json({ error: "Please set ANTHROPIC_API_KEY in your .env file" });
    try {
      const titles = db.prepare("SELECT title FROM tracks ORDER BY play_count DESC LIMIT 20").all().map(t => t.title).join(", ") || "無";
      const prompt = `根據用戶收藏（${titles}），推薦10tracksYouTube音樂。僅返回JSON：[{"youtube_video_id":"ID","title":"T","channelName":"C","tags":["t"],"reason":"R"}]`;
      const text = await callAnthropic(apiKey, prompt, 1500);
      const recs = JSON.parse(text.replace(/```json|```/g, "").trim());
      res.json(recs.map(x => ({ ...x, thumbnail_url: `https://img.youtube.com/vi/${x.youtube_video_id}/mqdefault.jpg` })));
    } catch (e) { res.json({ error: e.message }); }
  });

  return new Promise(resolve => {
    app.listen(port, "127.0.0.1", () => {
      console.log(`[server] running on http://127.0.0.1:${port}`);
      resolve();
    });
  });
}

function callAnthropic(apiKey, prompt, maxTokens) {
  return new Promise((resolve, reject) => {
    const https = require("https");
    const body  = JSON.stringify({ model: "claude-sonnet-4-20250514", max_tokens: maxTokens, messages: [{ role: "user", content: prompt }] });
    const r = https.request({
      hostname: "api.anthropic.com", path: "/v1/messages", method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, resp => {
      let d = ""; resp.on("data", c => d += c);
      resp.on("end", () => {
        try { resolve(JSON.parse(d).content?.[0]?.text || "[]"); } catch (e) { reject(e); }
      });
    });
    r.on("error", reject); r.write(body); r.end();
  });
}

module.exports = { startServer };
EOF

# ── main.js ───────────────────────────────────────────────────────────────────
cat > "$ROOT/electron/main.js" << MAINEOF
"use strict";
const { app, BrowserWindow, BrowserView, ipcMain } = require("electron");
const path   = require("path");
const fs     = require("fs");
const { startServer } = require("./server");

const PORT = ${PORT};
let win = null, ytv = null, poll = null;

function getFrontendURL() {
  if (!app.isPackaged) return "http://localhost:3000";
  return "file://" + path.join(process.resourcesPath, "frontend", "index.html");
}

const HDR = 52, SIDE = 185;
function posYT(m) {
  if (!win || !ytv) return;
  ytv._m = m;
  const [W] = win.getContentSize();
  const cW  = W - SIDE;
  if      (m === "hidden") ytv.setBounds({ x:-9999, y:-9999, width:1, height:1 });
  else if (m === "audio")  ytv.setBounds({ x:W-260-16, y:HDR+60, width:260, height:146 });
  else {
    const mW = Math.min(660, cW-40);
    ytv.setBounds({ x:SIDE+Math.round((cW-mW)/2), y:HDR+80, width:mW, height:Math.round(mW*9/16) });
  }
}

function createWindow() {
  win = new BrowserWindow({
    width:1200, height:800, minWidth:900, minHeight:600,
    backgroundColor:"#0d0d1a", titleBarStyle:"hiddenInset",
    webPreferences:{
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true, nodeIntegration: false, webSecurity: false,
    },
  });
  ytv = new BrowserView({ webPreferences:{
    contextIsolation:false, nodeIntegration:false, webSecurity:false,
    userAgent:"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  }});
  win.addBrowserView(ytv);
  ytv._m = "hidden"; posYT("hidden");
  win.loadURL(getFrontendURL());
  win.on("resize", () => posYT(ytv._m));
  win.on("closed", () => { win = null; });
}

// IPC — YouTube 控制
ipcMain.on("yt-load", (_, {videoId, mode}) => {
  if (!ytv) return;
  ytv.webContents.loadURL(\`https://www.youtube.com/watch?v=\${videoId}&autoplay=1\`);
  posYT(mode || "audio");
  ytv.webContents.once("did-finish-load", () => {
    setTimeout(() => { ytv.webContents.executeJavaScript("(()=>{const v=document.querySelector('video');if(v&&v.paused)v.play()})()").catch(()=>{}); }, 1500);
  });
});
ipcMain.on("yt-play",  () => ytv?.webContents.executeJavaScript("document.querySelector('video')?.play()").catch(()=>{}));
ipcMain.on("yt-pause", () => ytv?.webContents.executeJavaScript("document.querySelector('video')?.pause()").catch(()=>{}));
ipcMain.on("yt-stop",  () => { ytv?.webContents.executeJavaScript("document.querySelector('video')?.pause()").catch(()=>{}); setTimeout(()=>{ ytv?.webContents.loadURL("about:blank"); posYT("hidden"); },300); });
ipcMain.on("yt-speed", (_, {speed}) => ytv?.webContents.executeJavaScript(\`var v=document.querySelector('video');if(v)v.playbackRate=\${speed};\`).catch(()=>{}));
ipcMain.on("yt-mode",  (_, {mode})  => posYT(mode));

function startPoll() {
  if (poll) return;
  poll = setInterval(() => {
    if (!ytv || !win) return;
    ytv.webContents.executeJavaScript("(()=>{const v=document.querySelector('video');if(!v)return null;return{ended:v.ended,paused:v.paused,ct:v.currentTime}})()")
      .then(s => {
        if (!s || !win) return;
        if (s.ended)                  win.webContents.send("yt-state", {type:"ended"});
        else if (!s.paused && s.ct>0) win.webContents.send("yt-state", {type:"playing"});
        else if (s.paused  && s.ct>0) win.webContents.send("yt-state", {type:"paused"});
      }).catch(()=>{});
  }, 1200);
}
ipcMain.on("yt-start-poll", () => startPoll());

// 啟動順序：先啟動 Node.js 後端（毫秒級），再開窗口
app.whenReady().then(async () => {
  await startServer(app, PORT);  // Node.js in-process — starts in milliseconds
  createWindow();                // Backend ready, open window immediately
  startPoll();
});

app.on("window-all-closed", () => {
  if (poll) { clearInterval(poll); poll = null; }
  app.quit();
});
app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
MAINEOF

# ── preload.js ────────────────────────────────────────────────────────────────
cat > "$ROOT/electron/preload.js" << PREEOF
"use strict";
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("BACKEND_URL", "http://127.0.0.1:${PORT}");

contextBridge.exposeInMainWorld("electronYT", {
  load:                 (v,m) => ipcRenderer.send("yt-load", {videoId:v, mode:m||"audio"}),
  play:                 ()    => ipcRenderer.send("yt-play"),
  pause:                ()    => ipcRenderer.send("yt-pause"),
  stop:                 ()    => ipcRenderer.send("yt-stop"),
  setSpeed:             (s)   => ipcRenderer.send("yt-speed", {speed:s}),
  setMode:              (m)   => ipcRenderer.send("yt-mode", {mode:m}),
  startPoll:            ()    => ipcRenderer.send("yt-start-poll"),
  onState:              (cb)  => ipcRenderer.on("yt-state", (_,d) => cb(d)),
  removeStateListeners: ()    => ipcRenderer.removeAllListeners("yt-state"),
});
PREEOF

cd "$ROOT/electron"
echo "  安裝依賴..."
npm install --silent
echo "✅ Electron + Node.js 後端完成"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: REACT 前端
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [2/3] 寫入並打包 React 前端 ────────────────────────────────────────────"
# 清除舊目錄，確保 create-react-app 正常運行
rm -rf "$ROOT/frontend"

cd "$ROOT"
npx --yes create-react-app frontend --template cra-template 2>/dev/null || true
mkdir -p "$ROOT/frontend/src/pages"

# ── api.js ────────────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/api.js" << APIEOF
function getBase() {
  if (typeof window !== "undefined" && window.BACKEND_URL) return window.BACKEND_URL;
  return process.env.REACT_APP_API_URL || "http://127.0.0.1:${PORT}";
}
async function req(method, path, body) {
  const opts = { method, headers: { "Content-Type": "application/json" } };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const r = await fetch(getBase() + path, opts);
  if (!r.ok) {
    const e = await r.json().catch(() => ({}));
    throw new Error(e.error || e.detail || "Request failed (" + r.status + ")");
  }
  return r.json();
}
export const api = {
  getTopics:   ()         => req("GET",    "/api/topics"),
  createTopic: (n, d)     => req("POST",   "/api/topics",      { name: n, description: d || "" }),
  updateTopic: (id, n, d) => req("PATCH",  "/api/topics/" + id, { name: n, description: d || "" }),
  deleteTopic: (id)       => req("DELETE", "/api/topics/" + id),
  getTracks:   ()         => req("GET",    "/api/tracks"),
  addTrack:    (data)     => req("POST",   "/api/tracks",       data),
  updateTrack: (id, data) => req("PATCH",  "/api/tracks/" + id, data),
  deleteTrack: (id)       => req("DELETE", "/api/tracks/" + id),
  recordPlay:  (id)       => req("POST",   "/api/tracks/" + id + "/played").catch(() => {}),
  searchYT:    (q)        => req("GET",    "/api/recommendations/search?q=" + encodeURIComponent(q)),
  aiRecs:      (n, d, tt) => req("POST",   "/api/recommendations/ai-recs",  { topic_name: n, topic_desc: d, track_titles: tt }),
  aiPool:      ()         => req("POST",   "/api/recommendations/ai-pool",  {}),
};
APIEOF

cat > "$ROOT/frontend/src/index.js" << 'EOF'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
ReactDOM.createRoot(document.getElementById("root")).render(<React.StrictMode><App/></React.StrictMode>);
EOF

cat > "$ROOT/frontend/src/index.css" << 'EOF'
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:#0d0d1a;color:#e2e2f0;font-family:-apple-system,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
::-webkit-scrollbar{width:5px}::-webkit-scrollbar-track{background:#1a1a2e}
::-webkit-scrollbar-thumb{background:#3a3a6a;border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:#6366f1}
input,button,select{font-family:inherit}
EOF

# ── App.js ────────────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/App.js" << 'APPEOF'
import React, { useState, useRef, useEffect, useCallback } from "react";
import { api } from "./api";
import "./index.css";
import Home        from "./pages/Home";
import Topics      from "./pages/Topics";
import TopicDetail from "./pages/TopicDetail";
import Player      from "./pages/Player";
import Search      from "./pages/Search";
import Pool        from "./pages/Pool";
import Favorites   from "./pages/Favorites";
import Settings    from "./pages/Settings";

const isElectron = typeof window !== "undefined" && !!window.electronYT;

function norm(t) {
  return {
    id: t.id, youtube_video_id: t.youtube_video_id, title: t.title,
    channelName: t.channel_name || t.channelName || "Unknown",
    thumbnail_url: t.thumbnail_url || `https://img.youtube.com/vi/${t.youtube_video_id}/mqdefault.jpg`,
    topic_id: t.topic_id, tags: t.tags || "",
    is_favorite: !!t.is_favorite, play_count: t.play_count || 0,
  };
}

export default function App() {
  const [topics,  setTopics]  = useState([]);
  const [tracks,  setTracks]  = useState([]);
  const [page,    setPage]    = useState("home");
  const [topicId, setTopicId] = useState(null);
  const [track,   setTrack]   = useState(null);
  const [playing, setPlaying] = useState(false);
  const [queue,   setQueue]   = useState([]);
  const [qIdx,    setQIdx]    = useState(0);
  const [shuffle, setShuffle] = useState(false);
  const [loop,    setLoop]    = useState("none");
  const [speed,   setSpeed]   = useState(1);
  const [mode,    setMode]    = useState("audio");
  const [toast,   setToast]   = useState(null);
  const [sleep,   setSleep]   = useState(null);
  const [loading, setLoading] = useState(true);

  const qRef = useRef(queue), iRef = useRef(qIdx);
  const shRef = useRef(shuffle), lRef = useRef(loop);
  const nextFn = useRef(null), sleepT = useRef(null);
  useEffect(() => { qRef.current  = queue;   }, [queue]);
  useEffect(() => { iRef.current  = qIdx;    }, [qIdx]);
  useEffect(() => { shRef.current = shuffle; }, [shuffle]);
  useEffect(() => { lRef.current  = loop;    }, [loop]);

  // Backend is Node.js in-process — ready before window opens
  // Direct load, no retry needed
  useEffect(() => {
    Promise.all([api.getTopics(), api.getTracks()])
      .then(([ts, trs]) => { setTopics(ts); setTracks(trs.map(norm)); })
      .catch(e => console.error("Load failed:", e))
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    if (!isElectron) return;
    window.electronYT.removeStateListeners();
    window.electronYT.onState(s => {
      if (s.type === "ended")   nextFn.current?.();
      if (s.type === "playing") setPlaying(true);
      if (s.type === "paused")  setPlaying(false);
    });
    window.electronYT.startPoll();
    return () => window.electronYT.removeStateListeners();
  }, []);

  const toast$ = useCallback((msg, type = "ok") => {
    setToast({ msg, type });
    setTimeout(() => setToast(null), 2800);
  }, []);

  const topicTracks = useCallback(tid => tracks.filter(t => t.topic_id === tid), [tracks]);

  const playNext = useCallback(() => {
    const q = qRef.current, i = iRef.current;
    if (!q.length) return;
    let ni;
    if (lRef.current === "one")    ni = i;
    else if (shRef.current)        ni = Math.floor(Math.random() * q.length);
    else if (i + 1 >= q.length)    ni = lRef.current === "all" ? 0 : -1;
    else                           ni = i + 1;
    if (ni < 0) { setPlaying(false); return; }
    const next = q[ni];
    setQIdx(ni); setTrack(next); setPlaying(true);
    api.recordPlay(next.id);
    if (isElectron) window.electronYT.load(next.youtube_video_id, mode);
  }, [mode]);
  useEffect(() => { nextFn.current = playNext; }, [playNext]);

  const playPrev = useCallback(() => {
    const q = qRef.current, i = iRef.current;
    if (!q.length) return;
    const prev = q[Math.max(0, i - 1)];
    setQIdx(Math.max(0, i - 1)); setTrack(prev); setPlaying(true);
    if (isElectron) window.electronYT.load(prev.youtube_video_id, mode);
  }, [mode]);

  const play$ = useCallback((t, list = null) => {
    const lst = list || topicTracks(t.topic_id);
    const ni  = lst.findIndex(x => x.id === t.id);
    setTrack(t); setPlaying(true); setQueue(lst); setQIdx(ni >= 0 ? ni : 0); setPage("player");
    api.recordPlay(t.id);
    if (isElectron) window.electronYT.load(t.youtube_video_id, mode);
  }, [topicTracks, mode]);

  const sleep$ = mins => {
    if (sleepT.current) clearTimeout(sleepT.current);
    if (!mins) { setSleep(null); return; }
    setSleep(mins);
    sleepT.current = setTimeout(() => {
      setPlaying(false); setSleep(null);
      if (isElectron) window.electronYT.pause();
      toast$("⏱ Sleep timer ended");
    }, mins * 60000);
  };

  const addTrack$ = (vid, title, channel, topicId) => {
    if (tracks.find(t => t.youtube_video_id === vid && t.topic_id === topicId)) {
      toast$("在此Topics中", "warn"); return;
    }
    api.addTrack({ youtube_video_id: vid, title: title || `Video (${vid})`, channel_name: channel || "Unknown", topic_id: topicId, thumbnail_url: `https://img.youtube.com/vi/${vid}/mqdefault.jpg` })
      .then(t => { setTracks(p => [...p, norm(t)]); toast$("Added ✓"); })
      .catch(e => toast$(e.message, "err"));
  };

  const delTrack$ = id => {
    api.deleteTrack(id).then(() => {
      setTracks(p => p.filter(t => t.id !== id));
      if (track?.id === id) { setTrack(null); setPlaying(false); }
      toast$("Deleted");
    }).catch(e => toast$(e.message, "err"));
  };

  const fav$ = id => {
    const t = tracks.find(t => t.id === id); if (!t) return;
    const next = !t.is_favorite;
    api.updateTrack(id, { is_favorite: next })
      .then(() => setTracks(p => p.map(t => t.id === id ? { ...t, is_favorite: next } : t)));
  };

  const nav$ = (p, tid = null) => { setPage(p); if (tid) setTopicId(tid); };
  const activeTopic = topics.find(t => t.id === topicId);

  if (loading) return (
    <div style={{ display:"flex", flexDirection:"column", alignItems:"center", justifyContent:"center", height:"100vh", background:"#0d0d1a" }}>
      <div style={{ fontSize:52, marginBottom:16 }}>🎵</div>
      <div style={{ color:"#818cf8", fontSize:20, fontWeight:700 }}>TopicTune</div>
    </div>
  );

  const miniPP = e => {
    e.stopPropagation();
    const next = !playing; setPlaying(next);
    if (isElectron) { next ? window.electronYT.play() : window.electronYT.pause(); }
  };

  return (
    <div style={{ display:"flex", flexDirection:"column", height:"100vh", background:"#0d0d1a", color:"#e2e2f0", overflow:"hidden" }}>
      {toast && (
        <div style={{ position:"fixed", top:14, left:"50%", transform:"translateX(-50%)", zIndex:9999,
          background: toast.type==="err"?"#7f1d1d":toast.type==="warn"?"#78350f":"#14532d",
          color:"#fff", padding:"8px 22px", borderRadius:10, fontSize:13, fontWeight:500, boxShadow:"0 4px 24px #0009", pointerEvents:"none" }}>
          {toast.msg}
        </div>
      )}

      {/* Header */}
      <div style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"0 20px", height:52, background:"#141428", borderBottom:"1px solid #252545", flexShrink:0, WebkitAppRegion:"drag" }}>
        <div style={{ display:"flex", alignItems:"center", gap:8, cursor:"pointer", WebkitAppRegion:"no-drag" }} onClick={() => nav$("home")}>
          <span style={{ fontSize:20 }}>🎵</span>
          <span style={{ fontWeight:700, fontSize:17, background:"linear-gradient(135deg,#818cf8,#c084fc)", WebkitBackgroundClip:"text", WebkitTextFillColor:"transparent" }}>TopicTune</span>
        </div>
        <div style={{ display:"flex", alignItems:"center", gap:10, WebkitAppRegion:"no-drag" }}>
          {sleep && <span style={{ fontSize:11, background:"#312e81", padding:"2px 10px", borderRadius:20, color:"#a5b4fc" }}>⏱ {sleep}m</span>}
          {track && page !== "player" && (
            <button onClick={() => setPage("player")} style={{ background:"#6366f1", border:"none", borderRadius:8, padding:"5px 12px", color:"#fff", cursor:"pointer", fontSize:11, fontWeight:600 }}>▶ Now Playing</button>
          )}
        </div>
      </div>

      <div style={{ display:"flex", flex:1, overflow:"hidden" }}>
        {/* Sidebar */}
        <nav style={{ width:185, background:"#141428", borderRight:"1px solid #252545", display:"flex", flexDirection:"column", padding:"10px 0", flexShrink:0, overflowY:"auto" }}>
          {[
            { id:"home",      label:"Home",   icon:"🏠" },
            { id:"topics",    label:"Topics",   icon:"📁" },
            { id:"search",    label:"Search",   icon:"🔍" },
            { id:"pool",      label:"Idea Pool", icon:"💡" },
            { id:"favorites", label:"Favorites",   icon:"⭐" },
            { id:"settings",  label:"Settings",   icon:"⚙️" },
          ].map(item => (
            <button key={item.id} onClick={() => nav$(item.id)} style={{
              display:"flex", alignItems:"center", gap:9, padding:"8px 16px",
              background: page === item.id ? "#1e1e3d" : "transparent",
              border:"none", borderLeft: page === item.id ? "3px solid #6366f1" : "3px solid transparent",
              color: page === item.id ? "#818cf8" : "#9ca3af",
              cursor:"pointer", fontSize:13, textAlign:"left", width:"100%",
            }}>
              <span style={{ fontSize:15 }}>{item.icon}</span> {item.label}
            </button>
          ))}
          {topics.length > 0 && <>
            <div style={{ padding:"10px 16px 4px", fontSize:10, color:"#6b7280", textTransform:"uppercase", letterSpacing:1, borderTop:"1px solid #252545", marginTop:6 }}>Topics</div>
            {topics.map(tp => {
              const active = topicId === tp.id && page === "topic";
              return (
                <button key={tp.id} onClick={() => nav$("topic", tp.id)} style={{
                  display:"flex", alignItems:"center", gap:8, padding:"6px 16px",
                  background: active ? "#1e1e3d" : "transparent", border:"none",
                  borderLeft: active ? "3px solid #a78bfa" : "3px solid transparent",
                  color: active ? "#a78bfa" : "#9ca3af", cursor:"pointer", fontSize:12.5, textAlign:"left", width:"100%",
                }}>
                  <span style={{ width:6, height:6, borderRadius:"50%", background:"#6366f1", flexShrink:0, display:"inline-block" }}/>
                  <span style={{ overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{tp.name}</span>
                </button>
              );
            })}
          </>}
        </nav>

        {/* Main */}
        <main style={{ flex:1, overflow:"auto", padding:24 }}>
          {page === "home"      && <Home topics={topics} tracks={tracks} nav={nav$} playTrack={play$}/>}
          {page === "topics"    && <Topics topics={topics} tracks={tracks} setTopics={setTopics} nav={nav$} toast={toast$}/>}
          {page === "topic"     && activeTopic && <TopicDetail topic={activeTopic} tracks={topicTracks(activeTopic.id)} allTopics={topics} playTrack={play$} deleteTrack={delTrack$} toggleFav={fav$} setTracks={setTracks} addTrack={addTrack$} currentTrack={track} toast={toast$} nav={nav$}/>}
          {page === "player"    && <Player track={track} topics={topics} playing={playing} setPlaying={setPlaying} loop={loop} setLoop={setLoop} shuffle={shuffle} setShuffle={setShuffle} speed={speed} setSpeed={setSpeed} mode={mode} setMode={setMode} playNext={playNext} playPrev={playPrev} toggleFav={fav$} nav={nav$}/>}
          {page === "search"    && <Search tracks={tracks} topics={topics} playTrack={play$} toggleFav={fav$} addTrack={addTrack$} toast={toast$}/>}
          {page === "pool"      && <Pool topics={topics} tracks={tracks} addTrack={addTrack$} toast={toast$}/>}
          {page === "favorites" && <Favorites tracks={tracks.filter(t => t.is_favorite)} topics={topics} playTrack={play$} toggleFav={fav$}/>}
          {page === "settings"  && <Settings mode={mode} setMode={setMode} speed={speed} setSpeed={setSpeed} loop={loop} setLoop={setLoop} shuffle={shuffle} setShuffle={setShuffle} sleep={sleep} setSleep={sleep$}/>}
        </main>
      </div>

      {/* Mini Player */}
      {track && page !== "player" && (
        <div style={{ background:"#141428", borderTop:"1px solid #252545", padding:"8px 20px", display:"flex", alignItems:"center", gap:12, flexShrink:0, cursor:"pointer" }} onClick={() => setPage("player")}>
          <img src={track.thumbnail_url} alt="" style={{ width:40, height:30, objectFit:"cover", borderRadius:5 }}/>
          <div style={{ flex:1, overflow:"hidden" }}>
            <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{track.title}</div>
            <div style={{ fontSize:11, color:"#9ca3af" }}>{track.channelName}</div>
          </div>
          <button onClick={e=>{e.stopPropagation();playPrev();}} style={IB}>⏮</button>
          <button onClick={miniPP} style={{ ...IB, background:"#6366f1", borderRadius:"50%", width:32, height:32, display:"flex", alignItems:"center", justifyContent:"center", fontSize:13 }}>{playing?"⏸":"▶"}</button>
          <button onClick={e=>{e.stopPropagation();playNext();}} style={IB}>⏭</button>
        </div>
      )}
    </div>
  );
}

const IB = { background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:5, borderRadius:6, fontSize:16 };

export function Btn({ onClick, children, color="#6366f1", small, disabled, style }) {
  return (
    <button onClick={onClick} disabled={disabled} style={{ background:disabled?"#2a2a4a":color, border:"none", borderRadius:9, padding:small?"3px 11px":"7px 16px", color:"#fff", cursor:disabled?"not-allowed":"pointer", fontSize:small?11:13, fontWeight:500, opacity:disabled?.6:1, ...style }}>
      {children}
    </button>
  );
}
export function Input({ value, onChange, placeholder, onKeyDown, autoFocus, style }) {
  return <input value={value} onChange={onChange} placeholder={placeholder} onKeyDown={onKeyDown} autoFocus={autoFocus} style={{ background:"#1e1e38", border:"1px solid #303060", borderRadius:9, padding:"8px 12px", color:"#e2e2f0", fontSize:13, outline:"none", ...style }}/>;
}
export function TrackRow({ t, i, active, onClick, right }) {
  const [h, setH] = useState(false);
  return (
    <div onClick={onClick} onMouseOver={()=>setH(true)} onMouseOut={()=>setH(false)}
      style={{ display:"flex", alignItems:"center", gap:10, padding:"9px 14px", background:active?"#1e1e45":h?"#1e1e3a":"#1a1a30", border:`1px solid ${active?"#6366f1":"#252545"}`, borderRadius:11, cursor:"pointer", transition:"background .12s" }}>
      {i!==undefined && <span style={{ color:"#6b7280", fontSize:12, width:20, textAlign:"center", flexShrink:0 }}>{i+1}</span>}
      <img src={t.thumbnail_url} alt="" style={{ width:52, height:38, objectFit:"cover", borderRadius:6, flexShrink:0 }}/>
      <div style={{ flex:1, overflow:"hidden" }}>
        <div style={{ fontSize:13, fontWeight:600, overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap", color:"#e2e2f0" }}>{t.title}</div>
        <div style={{ fontSize:11, color:"#9ca3af" }}>{t.channelName}</div>
      </div>
      {right}
    </div>
  );
}
APPEOF

# ── pages/Home.js ─────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Home.js" << 'EOF'
import React from "react";
import { TrackRow } from "../App";
export default function Home({ topics, tracks, nav, playTrack }) {
  const favs = tracks.filter(t => t.is_favorite).slice(0, 6);
  return (
    <div>
      <h2 style={H2}>tracks頁</h2>
      <Sec title="我的Topics">
        {topics.length === 0
          ? <div style={{ color:"#6b7280", fontSize:13 }}>📁 No Topics，前往Topics頁面創建</div>
          : <div style={{ display:"flex", gap:12, flexWrap:"wrap" }}>
              {topics.map(tp => {
                const cnt = tracks.filter(t => t.topic_id === tp.id).length;
                const img = tracks.find(t => t.topic_id === tp.id)?.thumbnail_url;
                return (
                  <div key={tp.id} onClick={() => nav("topic", tp.id)}
                    style={{ width:140, cursor:"pointer", borderRadius:12, overflow:"hidden", background:"#1a1a30", border:"1px solid #252545", transition:"transform .15s,box-shadow .15s" }}
                    onMouseOver={e => { e.currentTarget.style.transform="translateY(-3px)"; e.currentTarget.style.boxShadow="0 8px 24px #0006"; }}
                    onMouseOut={e  => { e.currentTarget.style.transform="none"; e.currentTarget.style.boxShadow="none"; }}>
                    <div style={{ height:80, background:"#252545", display:"flex", alignItems:"center", justifyContent:"center", overflow:"hidden" }}>
                      {img ? <img src={img} alt="" style={{ width:"100%", height:"100%", objectFit:"cover" }}/> : <span style={{ fontSize:28 }}>🎵</span>}
                    </div>
                    <div style={{ padding:"9px 12px" }}>
                      <div style={{ fontSize:13, fontWeight:600, color:"#e2e2f0", overflow:"hidden", textOverflow:"ellipsis", whiteSpace:"nowrap" }}>{tp.name}</div>
                      <div style={{ fontSize:11, color:"#9ca3af", marginTop:2 }}>{cnt} tracks</div>
                    </div>
                  </div>
                );
              })}
            </div>
        }
      </Sec>
      {favs.length > 0 && <Sec title="Favorites"><div style={{ display:"flex", flexDirection:"column", gap:7 }}>{favs.map(t => <TrackRow key={t.id} t={t} onClick={() => playTrack(t)} right={<span style={{ color:"#f59e0b" }}>★</span>}/>)}</div></Sec>}
    </div>
  );
}
function Sec({ title, children }) {
  return <div style={{ marginBottom:28 }}><div style={{ fontSize:11, color:"#a78bfa", fontWeight:600, textTransform:"uppercase", letterSpacing:.8, marginBottom:12 }}>{title}</div>{children}</div>;
}
const H2 = { fontSize:22, fontWeight:700, marginBottom:22, color:"#e2e2f0" };
EOF

# ── pages/Topics.js ───────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Topics.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";
import { Btn, Input } from "../App";
export default function Topics({ topics, tracks, setTopics, nav, toast }) {
  const [name, setName] = useState("");
  const [edit, setEdit] = useState(null);
  const [editName, setEditName] = useState("");
  const create = () => {
    if (!name.trim()) return;
    api.createTopic(name.trim(), "")
      .then(t => { setTopics(p => [...p, t]); setName(""); toast("Topics創建 ✓"); })
      .catch(e => toast(e.message, "err"));
  };
  const del = id => api.deleteTopic(id).then(() => { setTopics(p => p.filter(t => t.id !== id)); toast("Deleted"); }).catch(e => toast(e.message, "err"));
  const save = id => {
    if (!editName.trim()) return;
    api.updateTopic(id, editName.trim(), "")
      .then(u => { setTopics(p => p.map(t => t.id === id ? u : t)); setEdit(null); })
      .catch(e => toast(e.message, "err"));
  };
  const IB = { background:"transparent", border:"none", color:"#9ca3af", cursor:"pointer", padding:"4px 6px", borderRadius:6, fontSize:15 };
  return (
    <div>
      <h2 style={{ fontSize:22, fontWeight:700, marginBottom:22, color:"#e2e2f0" }}>我的Topics</h2>
      <div style={{ display:"flex", gap:8, marginBottom:20 }}>
        <Input value={name} onChange={e => setName(e.target.value)} placeholder="新Topics名稱…" onKeyDown={e => e.key==="Enter"&&create()} style={{ flex:1 }}/>
        <Btn onClick={create}>+ Create</Btn>
      </div>
      <div style={{ display:"flex", flexDirection:"column", gap:9 }}>
        {topics.map(tp => {
          const cnt = tracks.filter(t => t.topic_id === tp.id).length;
          return (
            <div key={tp.id} style={{ display:"flex", alignItems:"center", gap:12, padding:"13px 16px", background:"#1a1a30", borderRadius:12, border:"1px solid #252545" }}>
              {edit === tp.id
                ? <Input value={editName} onChange={e=>setEditName(e.target.value)} autoFocus onKeyDown={e=>e.key==="Enter"&&save(tp.id)} onBlur={()=>save(tp.id)} style={{ flex:1 }}/>
                : <div style={{ flex:1, cursor:"pointer" }} onClick={() => nav("topic", tp.id)}>
                    <div style={{ fontWeight:600, color:"#e2e2f0" }}>{tp.name}</div>
                    <div style={{ fontSize:12, color:"#9ca3af", marginTop:2 }}>{cnt} tracks</div>
                  </div>
              }
              <button onClick={() => { setEdit(tp.id); setEditName(tp.name); }} style={IB}>✏️</button>
              <button onClick={() => del(tp.id)} style={{ ...IB, color:"#ef4444" }}>🗑</button>
            </div>
          );
        })}
        {topics.length === 0 && <div style={{ color:"#6b7280", fontSize:13, padding:"20px 0" }}>No Topics，在上方創建第一個！</div>}
      </div>
    </div>
  );
}
EOF

# ── pages/TopicDetail.js ──────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/TopicDetail.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";
import { Btn, Input, TrackRow } from "../App";
export default function TopicDetail({ topic, tracks, allTopics, playTrack, deleteTrack, toggleFav, setTracks, addTrack, currentTrack, toast, nav }) {
  const [showAdd,setShowAdd]=useState(false);
  const [url,setUrl]=useState(""); const [title,setTitle]=useState(""); const [ch,setCh]=useState("");
  const [move,setMove]=useState(null);
  const [recs,setRecs]=useState([]); const [recBusy,setRecBusy]=useState(false); const [recErr,setRecErr]=useState("");
  const extractId = u => { const m=u.match(/(?:v=|youtu\.be\/)([^&\s?#]+)/); return m?m[1]:null; };
  const submitAdd = () => {
    const vid=extractId(url);
    if (!vid) { toast("Invalid YouTube URL","err"); return; }
    addTrack(vid, title||`Video (${vid})`, ch, topic.id);
    setUrl(""); setTitle(""); setCh(""); setShowAdd(false);
  };
  const moveTrack = (t,newTid) => {
    api.updateTrack(t.id,{topic_id:newTid}).then(()=>{ setTracks(p=>p.map(x=>x.id===t.id?{...x,topic_id:newTid}:x)); setMove(null); toast("Moved ✓"); }).catch(e=>toast(e.message,"err"));
  };
  const getAIRecs = async () => {
    setRecBusy(true); setRecErr(""); setRecs([]);
    try { const d=await api.aiRecs(topic.name,topic.description||topic.name,tracks.map(t=>t.title)); if(d.error)setRecErr("AI: "+d.error); else setRecs(d); }
    catch(e) { setRecErr(e.message); }
    setRecBusy(false);
  };
  const IB={background:"transparent",border:"none",color:"#9ca3af",cursor:"pointer",padding:"3px 5px",borderRadius:6,fontSize:15};
  return (
    <div>
      <Btn onClick={()=>nav("topics")} color="#252545" style={{marginBottom:16,fontSize:12}}>← 返回Topics列表</Btn>
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",marginBottom:20}}>
        <div>
          <h2 style={{fontSize:22,fontWeight:700,color:"#e2e2f0",marginBottom:4}}>{topic.name}</h2>
          {topic.description&&<div style={{fontSize:13,color:"#9ca3af",marginBottom:4}}>{topic.description}</div>}
          <span style={{fontSize:12,color:"#6b7280"}}>{tracks.length} tracks</span>
        </div>
        <div style={{display:"flex",gap:8,flexShrink:0}}>
          {tracks.length>0&&<Btn onClick={()=>playTrack(tracks[0],tracks)}>▶ Play All</Btn>}
          <Btn onClick={()=>setShowAdd(!showAdd)} color="#4f46e5">+ Add</Btn>
        </div>
      </div>
      {showAdd&&(
        <div style={{background:"#0f0f26",border:"1px solid #303060",borderRadius:12,padding:18,marginBottom:18}}>
          <div style={{fontWeight:600,color:"#a78bfa",marginBottom:12}}>Add YouTube Track</div>
          <Input value={url} onChange={e=>setUrl(e.target.value)} placeholder="YouTube URL *" style={{width:"100%",marginBottom:8}}/>
          <Input value={title} onChange={e=>setTitle(e.target.value)} placeholder="Title (optional)" style={{width:"100%",marginBottom:8}}/>
          <Input value={ch} onChange={e=>setCh(e.target.value)} placeholder="Channel (optional)" style={{width:"100%",marginBottom:14}}/>
          <div style={{display:"flex",gap:8}}><Btn onClick={submitAdd}>Add</Btn><Btn onClick={()=>setShowAdd(false)} color="#252545">Cancel</Btn></div>
        </div>
      )}
      {tracks.length===0&&!showAdd&&(
        <div style={{textAlign:"center",padding:"50px 0",color:"#6b7280"}}>
          <div style={{fontSize:40,marginBottom:10}}>🎵</div>
          <div>No tracks yet — click「+ Add」開始</div>
        </div>
      )}
      <div style={{display:"flex",flexDirection:"column",gap:8,marginBottom:26}}>
        {tracks.map((t,i)=>(
          <TrackRow key={t.id} t={t} i={i} active={currentTrack?.id===t.id} onClick={()=>playTrack(t,tracks)}
            right={
              <div style={{display:"flex",alignItems:"center",gap:2}} onClick={e=>e.stopPropagation()}>
                <button onClick={()=>toggleFav(t.id)} style={{...IB,color:t.is_favorite?"#f59e0b":"#6b7280",fontSize:17}}>{t.is_favorite?"★":"☆"}</button>
                <div style={{position:"relative"}}>
                  <button onClick={()=>setMove(move===t.id?null:t.id)} style={IB} title="Move">⇄</button>
                  {move===t.id&&(
                    <div style={{position:"absolute",right:0,top:30,background:"#1e1e38",border:"1px solid #303060",borderRadius:10,zIndex:200,minWidth:160,boxShadow:"0 8px 30px #0008"}}>
                      <div style={{padding:"6px 14px",fontSize:11,color:"#9ca3af",borderBottom:"1px solid #303060"}}>Move to…</div>
                      {allTopics.filter(tp=>tp.id!==topic.id).map(tp=>(
                        <button key={tp.id} onClick={()=>moveTrack(t,tp.id)} style={{display:"block",width:"100%",padding:"8px 14px",background:"transparent",border:"none",color:"#e2e2f0",cursor:"pointer",textAlign:"left",fontSize:13}}>{tp.name}</button>
                      ))}
                      {allTopics.filter(tp=>tp.id!==topic.id).length===0&&<div style={{padding:"8px 14px",fontSize:12,color:"#6b7280"}}>沒有其他Topics</div>}
                    </div>
                  )}
                </div>
                <button onClick={()=>deleteTrack(t.id)} style={{...IB,color:"#ef4444"}}>🗑</button>
              </div>
            }/>
        ))}
      </div>
      <div style={{borderTop:"1px solid #252545",paddingTop:22}}>
        <div style={{display:"flex",alignItems:"center",justifyContent:"space-between",marginBottom:14}}>
          <h3 style={{margin:0,fontSize:15,color:"#a78bfa"}}>✨ AI Recommendations</h3>
          <Btn onClick={getAIRecs} disabled={recBusy} small>{recBusy?"🤔 Thinking…":"🤖 Get Recs"}</Btn>
        </div>
        {recErr&&<div style={{color:"#f87171",fontSize:13,marginBottom:10}}>{recErr}</div>}
        {!recBusy&&!recErr&&recs.length===0&&<div style={{color:"#6b7280",fontSize:13}}>Click above to get AI recommendations for "{topic.name}"</div>}
        <div style={{display:"flex",flexDirection:"column",gap:8}}>
          {recs.map(r=>(
            <div key={r.youtube_video_id} style={{display:"flex",alignItems:"center",gap:10,padding:"10px 14px",background:"#0f0f26",borderRadius:11,border:"1px solid #252545"}}>
              <img src={r.thumbnail_url} alt="" style={{width:52,height:38,objectFit:"cover",borderRadius:6,flexShrink:0}} onError={e=>e.target.style.display="none"}/>
              <div style={{flex:1,overflow:"hidden"}}>
                <div style={{fontSize:13,fontWeight:600,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",color:"#e2e2f0"}}>{r.title}</div>
                <div style={{fontSize:11,color:"#9ca3af"}}>{r.channelName}·<span style={{color:"#818cf8"}}>{r.reason}</span></div>
              </div>
              <Btn small onClick={()=>{addTrack(r.youtube_video_id,r.title,r.channelName,topic.id);setRecs(p=>p.filter(x=>x.youtube_video_id!==r.youtube_video_id));}}>+ Add</Btn>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
EOF

# ── pages/Player.js ───────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Player.js" << 'EOF'
import React, { useEffect, useRef, useState } from "react";
import { Btn } from "../App";
const isElectron = typeof window !== "undefined" && !!window.electronYT;
export default function Player({ track, topics, playing, setPlaying, loop, setLoop, shuffle, setShuffle, speed, setSpeed, mode, setMode, playNext, playPrev, toggleFav, nav }) {
  const ytRef=useRef(null),divRef=useRef(null),loadedRef=useRef(null);
  const [ytOk,setYtOk]=useState(false);
  const speedRef=useRef(speed),nextRef=useRef(playNext);
  useEffect(()=>{speedRef.current=speed;},[speed]);
  useEffect(()=>{nextRef.current=playNext;},[playNext]);
  const topic=track?topics.find(t=>t.id===track.topic_id):null;
  const NLOOP={none:"all",all:"one",one:"none"};
  useEffect(()=>{
    if(isElectron)return;
    if(window.YT?.Player){setYtOk(true);return;}
    const s=document.createElement("script");s.src="https://www.youtube.com/iframe_api";document.head.appendChild(s);
    window.onYouTubeIframeAPIReady=()=>setYtOk(true);
  },[]);
  useEffect(()=>{
    if(isElectron||!ytOk||!track||!divRef.current)return;
    if(loadedRef.current===track.youtube_video_id&&ytRef.current){try{playing?ytRef.current.playVideo():ytRef.current.pauseVideo();}catch(_){}return;}
    loadedRef.current=track.youtube_video_id;
    if(ytRef.current){try{ytRef.current.destroy();}catch(_){}ytRef.current=null;}
    ytRef.current=new window.YT.Player(divRef.current,{
      videoId:track.youtube_video_id,playerVars:{autoplay:1,rel:0,modestbranding:1,playsinline:1},
      events:{
        onReady:e=>{try{e.target.setPlaybackRate(speedRef.current);}catch(_){}},
        onStateChange:e=>{
          if(e.data===window.YT.PlayerState.PLAYING)setPlaying(true);
          if(e.data===window.YT.PlayerState.PAUSED)setPlaying(false);
          if(e.data===window.YT.PlayerState.ENDED)nextRef.current();
        },
      },
    });
  },[track?.youtube_video_id,ytOk]);
  useEffect(()=>{if(isElectron||!ytRef.current)return;try{playing?ytRef.current.playVideo():ytRef.current.pauseVideo();}catch(_){}},[playing]);
  useEffect(()=>{if(isElectron||!ytRef.current)return;try{ytRef.current.setPlaybackRate(speed);}catch(_){}},[speed]);
  useEffect(()=>{if(!isElectron||!track)return;if(loadedRef.current!==track.youtube_video_id){loadedRef.current=track.youtube_video_id;window.electronYT.load(track.youtube_video_id,mode);}},[track?.youtube_video_id]);
  useEffect(()=>{if(!isElectron)return;playing?window.electronYT.play():window.electronYT.pause();},[playing]);
  useEffect(()=>{if(!isElectron)return;window.electronYT.setSpeed(speed);},[speed]);
  useEffect(()=>{if(!isElectron)return;window.electronYT.setMode(mode);},[mode]);
  if(!track)return(
    <div style={{display:"flex",flexDirection:"column",alignItems:"center",justifyContent:"center",padding:"80px 0",color:"#6b7280"}}>
      <div style={{fontSize:64,marginBottom:16}}>🎵</div>
      <div style={{fontSize:18,fontWeight:600,color:"#e2e2f0",marginBottom:8}}>No track selected</div>
      <div style={{fontSize:14}}>Select一個Topics開始播放</div>
    </div>
  );
  const vWrap=mode==="video"?{position:"relative",paddingTop:"56.25%",borderRadius:14,overflow:"hidden",background:"#000",marginBottom:18,boxShadow:"0 8px 32px #0006"}
    :mode==="audio"?{width:240,height:135,borderRadius:10,overflow:"hidden",background:"#000",border:"2px solid #6366f1",marginBottom:18}
    :{position:"fixed",left:"-9999px",width:1,height:1};
  const vInner=mode==="video"?{position:"absolute",top:0,left:0,width:"100%",height:"100%",border:"none"}:{width:"100%",height:"100%",border:"none"};
  return(
    <div style={{maxWidth:660,margin:"0 auto"}}>
      {topic&&<Btn onClick={()=>nav("topic",topic.id)} color="#252545" style={{marginBottom:16,fontSize:12}}>← Back to {topic.name}</Btn>}
      <h2 style={{fontSize:22,fontWeight:700,marginBottom:16,color:"#e2e2f0"}}>Now Playing</h2>
      <div style={{display:"flex",gap:8,marginBottom:18}}>
        {[["video","🎬 Video"],["audio","🎵 Audio"],["hidden","🙈 Hidden"]].map(([m,l])=>(
          <button key={m} onClick={()=>setMode(m)} style={{flex:1,padding:"8px 0",borderRadius:10,cursor:"pointer",fontSize:13,background:mode===m?"linear-gradient(135deg,#6366f1,#8b5cf6)":"transparent",border:`1px solid ${mode===m?"#6366f1":"#252545"}`,color:mode===m?"#fff":"#9ca3af",fontWeight:mode===m?600:400}}>{l}</button>
        ))}
      </div>
      {!isElectron&&<div style={vWrap}><div ref={divRef} style={vInner}/></div>}
      {isElectron&&mode==="video"&&<div style={{width:"100%",paddingTop:"56.25%",background:"#0a0a1a",borderRadius:14,marginBottom:18,position:"relative",border:"1px solid #252545"}}><div style={{position:"absolute",top:"50%",left:"50%",transform:"translate(-50%,-50%)",color:"#4a4a6a",fontSize:13}}>🎬 Videoplaying above</div></div>}
      {mode!=="video"&&(
        <div style={{display:"flex",gap:16,alignItems:"center",background:"linear-gradient(135deg,#1a1a30,#1e1e3a)",border:"1px solid #252545",borderRadius:16,padding:18,marginBottom:18,boxShadow:"0 4px 20px #0004"}}>
          <img src={track.thumbnail_url} alt="" style={{width:96,height:96,objectFit:"cover",borderRadius:12,flexShrink:0,boxShadow:"0 4px 16px #0006"}}/>
          <div style={{flex:1,overflow:"hidden"}}>
            <div style={{fontWeight:700,fontSize:17,color:"#e2e2f0",overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",marginBottom:4}}>{track.title}</div>
            <div style={{color:"#9ca3af",fontSize:14,marginBottom:4}}>{track.channelName}</div>
            {topic&&<div style={{color:"#6366f1",fontSize:12,marginBottom:4}}>📁 {topic.name}</div>}
            <div style={{fontSize:11,color:"#6b7280"}}>{mode==="hidden"?"🙈 Video hidden — audio playing":"🎵 Audio優先模式"}</div>
          </div>
        </div>
      )}
      <div style={{background:"linear-gradient(135deg,#1a1a30,#1e1e3a)",border:"1px solid #252545",borderRadius:16,padding:"18px 20px",marginBottom:16,boxShadow:"0 4px 20px #0004"}}>
        <div style={{display:"flex",alignItems:"center",gap:12,marginBottom:16}}>
          <div style={{flex:1,overflow:"hidden"}}>
            <div style={{fontWeight:700,fontSize:16,color:"#e2e2f0",overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{track.title}</div>
            <div style={{color:"#9ca3af",fontSize:12,marginTop:2}}>{track.channelName}{topic?" · "+topic.name:""}</div>
          </div>
          <button onClick={()=>toggleFav(track.id)} style={{background:"transparent",border:"none",color:track.is_favorite?"#f59e0b":"#4a4a6a",cursor:"pointer",padding:5,fontSize:24}}>{track.is_favorite?"★":"☆"}</button>
        </div>
        <div style={{display:"flex",alignItems:"center",justifyContent:"center",gap:16,marginBottom:16}}>
          <button onClick={()=>setShuffle(!shuffle)} style={{...CB,color:shuffle?"#818cf8":"#4a4a6a",fontSize:20}}>⇀</button>
          <button onClick={playPrev} style={{...CB,fontSize:26,color:"#9ca3af"}}>⏮</button>
          <button onClick={()=>setPlaying(!playing)} style={{background:"linear-gradient(135deg,#6366f1,#8b5cf6)",border:"none",borderRadius:"50%",width:58,height:58,fontSize:22,cursor:"pointer",color:"#fff",display:"flex",alignItems:"center",justifyContent:"center",flexShrink:0,boxShadow:"0 4px 20px #6366f150"}}>{playing?"⏸":"▶"}</button>
          <button onClick={playNext} style={{...CB,fontSize:26,color:"#9ca3af"}}>⏭</button>
          <button onClick={()=>setLoop(NLOOP[loop])} style={{...CB,color:loop!=="none"?"#818cf8":"#4a4a6a",fontSize:13,minWidth:52,fontWeight:600}}>{loop==="none"?"↩ Off":loop==="all"?"🔁 All":"🔂 One"}</button>
        </div>
        <div style={{display:"flex",alignItems:"center",gap:6,flexWrap:"wrap"}}>
          <span style={{fontSize:12,color:"#6b7280",marginRight:2}}>Speed</span>
          {[0.75,1,1.25,1.5,2].map(s=>(
            <button key={s} onClick={()=>setSpeed(s)} style={{flex:1,padding:"4px 0",borderRadius:8,cursor:"pointer",fontSize:11,background:speed===s?"linear-gradient(135deg,#6366f1,#8b5cf6)":"#1a1a30",border:`1px solid ${speed===s?"#6366f1":"#252545"}`,color:speed===s?"#fff":"#9ca3af",fontWeight:speed===s?700:400}}>{s}x</button>
          ))}
        </div>
      </div>
      <div style={{textAlign:"center"}}>
        <a href={`https://www.youtube.com/watch?v=${track.youtube_video_id}`} target="_blank" rel="noreferrer" style={{color:"#4a4a6a",fontSize:12,textDecoration:"none"}}>↗ Open in YouTube</a>
      </div>
    </div>
  );
}
const CB={background:"transparent",border:"none",cursor:"pointer",padding:"6px 8px",borderRadius:8};
EOF

# ── pages/Search.js ───────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Search.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";
import { Btn, Input, TrackRow } from "../App";
export default function Search({ tracks, topics, playTrack, toggleFav, addTrack, toast }) {
  const [q,setQ]=useState(""); const [tab,setTab]=useState("youtube");
  const [res,setRes]=useState([]); const [busy,setBusy]=useState(false); const [err,setErr]=useState("");
  const [sel,setSel]=useState((topics[0]||{}).id||"");
  const libRes=q.length>1?tracks.filter(t=>t.title.toLowerCase().includes(q.toLowerCase())||t.channelName.toLowerCase().includes(q.toLowerCase())):[];
  const search=()=>{
    if(!q.trim())return;
    setBusy(true);setErr("");setRes([]);
    api.searchYT(q).then(d=>{if(d.error)setErr(d.error);else setRes(d);}).catch(e=>setErr(e.message)).finally(()=>setBusy(false));
  };
  return(
    <div>
      <h2 style={{fontSize:22,fontWeight:700,marginBottom:22,color:"#e2e2f0"}}>Search</h2>
      <div style={{display:"flex",gap:8,marginBottom:18}}>
        <div style={{position:"relative",flex:1}}>
          <Input value={q} onChange={e=>setQ(e.target.value)} onKeyDown={e=>e.key==="Enter"&&search()} placeholder="Search音樂…" style={{width:"100%",paddingLeft:36}}/>
          <span style={{position:"absolute",left:11,top:"50%",transform:"translateY(-50%)",color:"#9ca3af"}}>🔍</span>
        </div>
        <Btn onClick={search}>Search</Btn>
      </div>
      <div style={{display:"flex",marginBottom:18,background:"#1a1a30",borderRadius:10,padding:3,gap:3,width:"fit-content"}}>
        {[["youtube","▶ YouTube"],["library","📚 My Library"]].map(([id,label])=>(
          <button key={id} onClick={()=>setTab(id)} style={{padding:"6px 18px",border:"none",borderRadius:8,cursor:"pointer",fontSize:13,background:tab===id?"#6366f1":"transparent",color:tab===id?"#fff":"#9ca3af",fontWeight:tab===id?600:400}}>{label}</button>
        ))}
      </div>
      {tab==="youtube"&&(
        <div>
          {topics.length>0&&<div style={{display:"flex",alignItems:"center",gap:8,marginBottom:16}}>
            <span style={{fontSize:13,color:"#9ca3af"}}>Add到：</span>
            <select value={sel} onChange={e=>setSel(e.target.value)} style={{background:"#1e1e38",border:"1px solid #303060",borderRadius:9,padding:"6px 10px",color:"#e2e2f0",fontSize:13,outline:"none"}}>
              {topics.map(tp=><option key={tp.id} value={tp.id}>{tp.name}</option>)}
            </select>
          </div>}
          {busy&&<div style={{color:"#818cf8",padding:20}}>🔍 Search中…</div>}
          {err&&<div style={{color:"#f87171",padding:20,fontSize:13}}>{err}</div>}
          {!busy&&!err&&res.length===0&&q&&<div style={{color:"#6b7280",padding:20}}>No results.</div>}
          <div style={{display:"flex",flexDirection:"column",gap:9}}>
            {res.map(r=>(
              <div key={r.youtube_video_id} style={{display:"flex",alignItems:"center",gap:10,padding:"10px 14px",background:"#1a1a30",borderRadius:11,border:"1px solid #252545"}}>
                <img src={r.thumbnail_url} alt="" style={{width:52,height:38,objectFit:"cover",borderRadius:6,flexShrink:0}} onError={e=>e.target.style.display="none"}/>
                <div style={{flex:1,overflow:"hidden"}}>
                  <div style={{fontSize:13,fontWeight:600,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",color:"#e2e2f0"}}>{r.title}</div>
                  <div style={{fontSize:11,color:"#9ca3af"}}>{r.channelName}{r.views?` · 👁 ${r.views}`:""}</div>
                </div>
                <Btn small onClick={()=>{if(!sel){toast("請先SelectTopics","warn");return;}addTrack(r.youtube_video_id,r.title,r.channelName,sel);toast(`Add到 ${topics.find(t=>t.id===sel)?.name||"Topics"} ✓`);}}>+ Add</Btn>
              </div>
            ))}
          </div>
        </div>
      )}
      {tab==="library"&&(
        <div>
          {q.length<=1&&<div style={{color:"#6b7280",fontSize:13,padding:"12px 0"}}>輸入關鍵詞Search…</div>}
          {q.length>1&&libRes.length===0&&<div style={{color:"#6b7280",padding:20}}>No results.</div>}
          <div style={{display:"flex",flexDirection:"column",gap:8}}>
            {libRes.map(t=>{
              const topic=topics.find(tp=>tp.id===t.topic_id);
              return <TrackRow key={t.id} t={t} onClick={()=>playTrack(t)} right={
                <div style={{display:"flex",alignItems:"center",gap:6,fontSize:11,color:"#6b7280"}}>
                  {t.play_count>0&&<span>▶{t.play_count}</span>}
                  {topic&&<span style={{color:"#6366f1"}}>·{topic.name}</span>}
                  <button onClick={e=>{e.stopPropagation();toggleFav(t.id);}} style={{background:"transparent",border:"none",color:t.is_favorite?"#f59e0b":"#6b7280",cursor:"pointer",fontSize:16}}>{t.is_favorite?"★":"☆"}</button>
                </div>
              }/>;
            })}
          </div>
        </div>
      )}
    </div>
  );
}
EOF

# ── pages/Pool.js ─────────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Pool.js" << 'EOF'
import React, { useState } from "react";
import { api } from "../api";
import { Btn } from "../App";
const DEFAULT=[
  {youtube_video_id:"JGwWNGJdvx8",title:"Shape of You",channelName:"Ed Sheeran",tags:"pop"},
  {youtube_video_id:"OPf0YbXqDm0",title:"Happy",channelName:"Pharrell Williams",tags:"happy"},
  {youtube_video_id:"hT_nvWreIhg",title:"Counting Stars",channelName:"OneRepublic",tags:"pop"},
  {youtube_video_id:"nfWlot6h_JM",title:"Shake It Off",channelName:"Taylor Swift",tags:"pop"},
  {youtube_video_id:"60ItHLz5WEA",title:"Rain Sounds",channelName:"Relaxing Sounds",tags:"ambient"},
  {youtube_video_id:"lFcSrYw2ARY",title:"Lo-fi Study Mix",channelName:"ChilledCow",tags:"lofi"},
  {youtube_video_id:"9bZkp7q19f0",title:"Gangnam Style",channelName:"PSY",tags:"kpop"},
  {youtube_video_id:"kXYiU_JCYtU",title:"Numb",channelName:"Linkin Park",tags:"rock"},
];
export default function Pool({ topics, tracks, addTrack, toast }) {
  const [sel,setSel]=useState((topics[0]||{}).id||"");
  const [pool,setPool]=useState(DEFAULT);
  const [busy,setBusy]=useState(false);
  const [err,setErr]=useState("");
  const refresh=()=>{
    setBusy(true);setErr("");
    api.aiPool().then(d=>{if(d.error)setErr("AI: "+d.error);else setPool(d);}).catch(e=>setErr(e.message)).finally(()=>setBusy(false));
  };
  return(
    <div>
      <h2 style={{fontSize:22,fontWeight:700,marginBottom:22,color:"#e2e2f0"}}>💡 Idea Pool</h2>
      <p style={{fontSize:13,color:"#9ca3af",marginBottom:20}}>精選推薦，SelectTopics後Add到收藏</p>
      <div style={{display:"flex",alignItems:"center",justifyContent:"space-between",marginBottom:20,flexWrap:"wrap",gap:10}}>
        <div style={{display:"flex",alignItems:"center",gap:8}}>
          <span style={{fontSize:13,color:"#9ca3af"}}>Add到：</span>
          <select value={sel} onChange={e=>setSel(e.target.value)} style={{background:"#1e1e38",border:"1px solid #303060",borderRadius:9,padding:"6px 10px",color:"#e2e2f0",fontSize:13,outline:"none"}}>
            {topics.map(tp=><option key={tp.id} value={tp.id}>{tp.name}</option>)}
          </select>
        </div>
        <Btn onClick={refresh} disabled={busy}>{busy?"🤔 Thinking…":"🤖 AI Refresh"}</Btn>
      </div>
      {err&&<div style={{color:"#f87171",fontSize:13,marginBottom:12}}>{err}</div>}
      <div style={{display:"flex",flexDirection:"column",gap:9}}>
        {pool.map(r=>{
          const vid=r.youtube_video_id;
          const thumb=r.thumbnail_url||`https://img.youtube.com/vi/${vid}/mqdefault.jpg`;
          const tags=Array.isArray(r.tags)?r.tags.join(" · "):(r.tags||"");
          return(
            <div key={vid} style={{display:"flex",alignItems:"center",gap:10,padding:"10px 14px",background:"#1a1a30",borderRadius:11,border:"1px solid #252545"}}>
              <img src={thumb} alt="" style={{width:52,height:38,objectFit:"cover",borderRadius:6,flexShrink:0}} onError={e=>e.target.style.display="none"}/>
              <div style={{flex:1,overflow:"hidden"}}>
                <div style={{fontSize:13,fontWeight:600,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",color:"#e2e2f0"}}>{r.title}</div>
                <div style={{fontSize:11,color:"#9ca3af"}}>{r.channelName}</div>
                {tags&&<div style={{fontSize:11,color:"#6366f1",marginTop:2}}>{tags}</div>}
                {r.reason&&<div style={{fontSize:11,color:"#818cf8",marginTop:1}}>{r.reason}</div>}
              </div>
              <Btn small onClick={()=>{if(!sel){toast("請先SelectTopics","warn");return;}addTrack(vid,r.title,r.channelName,sel);toast(`Added ✓`);}}>+ Add</Btn>
            </div>
          );
        })}
      </div>
    </div>
  );
}
EOF

# ── pages/Favorites.js ────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Favorites.js" << 'EOF'
import React from "react";
import { TrackRow } from "../App";
export default function Favorites({ tracks, topics, playTrack, toggleFav }) {
  return(
    <div>
      <h2 style={{fontSize:22,fontWeight:700,marginBottom:22,color:"#e2e2f0"}}>⭐ Favorites</h2>
      {tracks.length===0&&<div style={{color:"#6b7280",fontSize:13,padding:"20px 0"}}>No favorites yet — star a track to save it here</div>}
      <div style={{display:"flex",flexDirection:"column",gap:8}}>
        {tracks.map(t=>{
          const topic=topics.find(tp=>tp.id===t.topic_id);
          return <TrackRow key={t.id} t={t} onClick={()=>playTrack(t)} right={
            <div style={{display:"flex",alignItems:"center",gap:6,fontSize:11,color:"#6b7280"}}>
              {t.play_count>0&&<span>▶{t.play_count}</span>}
              {topic&&<span style={{color:"#6366f1"}}>·{topic.name}</span>}
              <button onClick={e=>{e.stopPropagation();toggleFav(t.id);}} style={{background:"transparent",border:"none",color:"#f59e0b",cursor:"pointer",fontSize:18}}>★</button>
            </div>
          }/>;
        })}
      </div>
    </div>
  );
}
EOF

# ── pages/Settings.js ─────────────────────────────────────────────────────────
cat > "$ROOT/frontend/src/pages/Settings.js" << 'EOF'
import React from "react";
export default function Settings({ mode, setMode, speed, setSpeed, loop, setLoop, shuffle, setShuffle, sleep, setSleep }) {
  const G=({title,children})=>(<div style={{marginBottom:24}}><div style={{fontSize:11,color:"#a78bfa",fontWeight:600,textTransform:"uppercase",letterSpacing:.8,marginBottom:10}}>{title}</div><div style={{background:"#1a1a30",border:"1px solid #252545",borderRadius:12,overflow:"hidden"}}>{children}</div></div>);
  const R=({label,children})=>(<div style={{display:"flex",alignItems:"center",justifyContent:"space-between",padding:"12px 16px",borderBottom:"1px solid #252545"}}><span style={{fontSize:13,color:"#d1d5db"}}>{label}</span><div style={{display:"flex",gap:5,flexWrap:"wrap",justifyContent:"flex-end"}}>{children}</div></div>);
  const B=a=>({background:a?"#6366f1":"#1e1e38",border:`1px solid ${a?"#6366f1":"#303060"}`,borderRadius:8,padding:"3px 12px",color:"#fff",cursor:"pointer",fontSize:11,fontWeight:a?600:400});
  return(
    <div style={{maxWidth:480}}>
      <h2 style={{fontSize:22,fontWeight:700,marginBottom:22,color:"#e2e2f0"}}>⚙️ Settings</h2>
      <G title="Playback">
        <R label="Default Mode">{[["video","🎬 Video"],["audio","🎵 Audio"],["hidden","🙈 Hidden"]].map(([m,l])=><button key={m} onClick={()=>setMode(m)} style={B(mode===m)}>{l}</button>)}</R>
        <R label="播放Speed">{[0.75,1,1.25,1.5,2].map(s=><button key={s} onClick={()=>setSpeed(s)} style={B(speed===s)}>{s}x</button>)}</R>
        <R label="Loop Mode">{[["none","Off"],["all","All"],["one","One"]].map(([v,l])=><button key={v} onClick={()=>setLoop(v)} style={B(loop===v)}>{l}</button>)}</R>
        <R label="Shuffle"><button onClick={()=>setShuffle(!shuffle)} style={B(shuffle)}>{shuffle?"On ✓":"Off"}</button></R>
      </G>
      <G title="Sleep Timer">
        <R label="Auto-pause after">{[null,15,30,45,60].map(m=><button key={m??0} onClick={()=>setSleep(m)} style={B(sleep===m)}>{m?`${m} min`:"Off"}</button>)}</R>
      </G>
      <G title="About">
        <R label="Version"><span style={{fontSize:12,color:"#6b7280"}}>TopicTune 1.0</span></R>
        <R label="Data Location"><span style={{fontSize:11,color:"#6b7280"}}>~/Library/Application Support/TopicTune/</span></R>
        <R label="AI Recommendations"><span style={{fontSize:11,color:"#6b7280"}}>Set ANTHROPIC_API_KEY in your .env file</span></R>
      </G>
    </div>
  );
}
EOF

# 打包前端
cd "$ROOT/frontend"
echo "REACT_APP_API_URL=http://127.0.0.1:${PORT}" > .env
npm install --silent
npm pkg set homepage="./"
echo "  打包 React..."
npm run build --silent
cd "$SCRIPT_DIR"
echo "✅ 前端完成"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 3: 打包 .dmg
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── [3/3] 打包 .dmg ─────────────────────────────────────────────────────────"
cd "$ROOT/electron"

echo "  打包 Apple Silicon (arm64)..."
npx electron-builder --mac --arm64 --publish never 2>&1 | grep -E "(•|✓|error|Error|packaging|built)" | head -15 || true

echo "  打包 Intel (x64)..."
npx electron-builder --mac --x64 --publish never 2>&1 | grep -E "(•|✓|error|Error|packaging|built)" | head -15 || true

mkdir -p "$DIST_DIR"
DMG_ARM=$(find "$ROOT/electron/dist" -name "*arm64*.dmg" 2>/dev/null | head -1)
DMG_X64=$(find "$ROOT/electron/dist" -name "*x64*.dmg"   2>/dev/null | head -1)

if [ -z "$DMG_ARM" ] && [ -z "$DMG_X64" ]; then
  echo "❌ 沒有找到 .dmg，請查看上方錯誤"
  exit 1
fi

[ -n "$DMG_ARM" ] && cp "$DMG_ARM" "$DIST_DIR/TopicTune-AppleSilicon.dmg"
[ -n "$DMG_X64" ] && cp "$DMG_X64" "$DIST_DIR/TopicTune-Intel.dmg"
cd "$SCRIPT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                      ✅ 打包完成！                                      ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
[ -n "$DMG_ARM" ] && echo "║  📦 Apple Silicon: dist/TopicTune-AppleSilicon.dmg  ($(du -sh "$DIST_DIR/TopicTune-AppleSilicon.dmg" | cut -f1))"
[ -n "$DMG_X64" ] && echo "║  📦 Intel Mac:     dist/TopicTune-Intel.dmg         ($(du -sh "$DIST_DIR/TopicTune-Intel.dmg" | cut -f1))"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  啟動時間：< 1 秒（Node.js 後端，直接嵌入 Electron）                   ║"
echo "║  創建 Topic：直接寫入 SQLite，即時生效，不依賴任何外部服務              ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  安裝方式（完全免安裝）：                                               ║"
echo "║    1. 雙擊 .dmg  2. 拖入 Applications  3. 雙擊運行 ✅                  ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  AI 功能配置（可選）：                                                  ║"
echo "║    nano ~/Library/Application\ Support/TopicTune/.env                  ║"
echo "║    填入：ANTHROPIC_API_KEY=sk-ant-xxxxxxxx                              ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
