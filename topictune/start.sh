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
