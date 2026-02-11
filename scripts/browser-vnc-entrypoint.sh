#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"

# Use passed environment variables or defaults
CDP_PORT="${CDP_PORT:-9222}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
ENABLE_NOVNC="${ENABLE_NOVNC:-1}"
HEADLESS="${HEADLESS:-0}"
VNC_PASSWORD="${VNC_PASSWORD:-}"

# Debug: Check environment
echo "=== ENVIRONMENT DEBUG ==="
echo "HOME=$HOME"
echo "VNC_PASSWORD set: $([ -n "$VNC_PASSWORD" ] && echo 'YES' || echo 'NO')"
echo "VNC_PASSWORD length: ${#VNC_PASSWORD}"
echo "========================="

# Create necessary directories
mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

# Start virtual display
echo "🖥️  Starting Xvfb on display :1..."
Xvfb :1 -screen 0 1920x1080x24 -ac -nolisten tcp &

# Prepare Chrome arguments
if [[ "${HEADLESS}" == "1" ]]; then
  CHROME_ARGS=(
    "--headless=new"
    "--disable-gpu"
  )
else
  CHROME_ARGS=()
fi

# Calculate internal CDP port (Chrome needs different port than exposed)
if [[ "${CDP_PORT}" -ge 65535 ]]; then
  CHROME_CDP_PORT="$((CDP_PORT - 1))"
else
  CHROME_CDP_PORT="$((CDP_PORT + 1))"
fi

CHROME_ARGS+=(
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-dev-shm-usage"
  "--disable-background-networking"
  "--disable-features=TranslateUI"
  "--disable-breakpad"
  "--disable-crash-reporter"
  "--metrics-recording-only"
  "--no-sandbox"
  "--disable-setuid-sandbox"
)

echo "🌐 Starting Chromium..."
echo "   CDP Port: ${CDP_PORT} (internal: ${CHROME_CDP_PORT})"
echo "   Headless: ${HEADLESS}"
chromium "${CHROME_ARGS[@]}" about:blank &
CHROME_PID=$!

# Wait for Chrome CDP to be ready
echo "⏳ Waiting for Chrome DevTools Protocol..."
for i in $(seq 1 50); do
  if curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null 2>&1; then
    echo "✅ Chrome CDP is ready"
    break
  fi
  sleep 0.1
done

# Set up socat to forward CDP port
echo "🔗 Setting up CDP port forwarding..."
socat \
  TCP-LISTEN:"${CDP_PORT}",fork,reuseaddr,bind=0.0.0.0 \
  TCP:127.0.0.1:"${CHROME_CDP_PORT}" &

# Start VNC and noVNC if enabled and not headless
if [[ "${ENABLE_NOVNC}" == "1" && "${HEADLESS}" != "1" ]]; then
  echo "🔌 Starting VNC server on port ${VNC_PORT}..."
  
  # Configure VNC password if provided
  if [[ -n "${VNC_PASSWORD}" ]]; then
    echo "=== CONFIGURING VNC PASSWORD ==="
    echo "VNC_PASSWORD is set (length: ${#VNC_PASSWORD})"
    # Remove any existing password file to ensure fresh config
    rm -f ~/.vnc/passwd
    mkdir -p ~/.vnc
    # Use correct x11vnc -storepasswd syntax
    x11vnc -storepasswd "${VNC_PASSWORD}" ~/.vnc/passwd
    if [ -f ~/.vnc/passwd ]; then
      echo "=== VNC PASSWORD FILE CREATED SUCCESSFULLY ==="
      ls -la ~/.vnc/passwd
    else
      echo "=== ERROR: VNC PASSWORD FILE NOT CREATED ==="
    fi
    x11vnc -display :1 -rfbport "${VNC_PORT}" -shared -forever -rfbauth ~/.vnc/passwd &
  else
    echo "=== WARNING: NO VNC_PASSWORD SET - RUNNING WITHOUT AUTH ==="
    x11vnc -display :1 -rfbport "${VNC_PORT}" -shared -forever -nopw &
  fi
  
  echo "🌐 Starting noVNC on port ${NOVNC_PORT}..."
  websockify --web /usr/share/novnc/ "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
  
  echo ""
  echo "✅ Browser-VNC Service Started!"
  echo "   CDP: http://localhost:${CDP_PORT}"
  echo "   VNC: localhost:${VNC_PORT}"
  echo "   noVNC: http://localhost:${NOVNC_PORT}/vnc.html"
  if [[ -n "${VNC_PASSWORD}" ]]; then
    echo "   Password: ${VNC_PASSWORD}"
  fi
fi

echo ""

# Wait for Chrome to exit
wait ${CHROME_PID}
