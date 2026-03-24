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
