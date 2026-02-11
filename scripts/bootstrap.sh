#!/usr/bin/env bash
set -e

# Use environment variables or defaults
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"

# Browser configuration
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PASSWORD="${VNC_PASSWORD:-}"

echo "🔍 DEBUG: Starting bootstrap"
echo "   CONFIG_FILE=$CONFIG_FILE"
echo "   GATEWAY_PORT=$GATEWAY_PORT"
echo "   GATEWAY_TOKEN=${GATEWAY_TOKEN:0:10}..."
echo "   NOVNC_PORT=$NOVNC_PORT"

# Create directories
mkdir -p "$OPENCLAW_STATE" "$WORKSPACE_DIR"
chmod 700 "$OPENCLAW_STATE"

mkdir -p "$OPENCLAW_STATE/credentials"
chmod 700 "$OPENCLAW_STATE/credentials"

# Create symlinks for persistence
for dir in .ssh .config .local .cache .npm; do
    if [ ! -L "/root/$dir" ] && [ ! -e "/root/$dir" ]; then
        ln -sf "/data/$dir" "/root/$dir"
    fi
done

# Use token from environment or generate one
if [ -z "$GATEWAY_TOKEN" ]; then
    echo "⚠️  No OPENCLAW_GATEWAY_TOKEN provided, generating new token..."
    GATEWAY_TOKEN=$(openssl rand -hex 24 2>/dev/null || node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
fi

# Validate that at least one AI provider key is set
if [ -z "$OPENAI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$GEMINI_API_KEY" ] && \
   [ -z "$MINIMAX_API_KEY" ] && [ -z "$KIMI_API_KEY" ] && [ -z "$OPENCODE_API_KEY" ] && \
   [ -z "$MOONSHOT_API_KEY" ]; then
    echo "⚠️  Warning: No AI provider API key detected. OpenClaw will not be able to process AI requests."
    echo "    Set at least one of: OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, etc."
fi

# Function to validate JSON
validate_json() {
    local file="$1"
    if [ -f "$file" ]; then
        if node -e "JSON.parse(require('fs').readFileSync('$file', 'utf8'))" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

# Check if config exists and has required fields
NEED_GENERATE=false
if [ -f "$CONFIG_FILE" ]; then
    echo "🔍 DEBUG: Config file exists at $CONFIG_FILE"
    
    if validate_json "$CONFIG_FILE"; then
        # Check for required fields
        if ! grep -q '"mode"' "$CONFIG_FILE" 2>/dev/null; then
            echo "❌ DEBUG: Config missing gateway.mode - will regenerate"
            NEED_GENERATE=true
        elif ! grep -q '"channels"' "$CONFIG_FILE" 2>/dev/null; then
            echo "❌ DEBUG: Config missing channels section - will regenerate"
            NEED_GENERATE=true
        elif ! grep -q '"profiles"' "$CONFIG_FILE" 2>/dev/null; then
            echo "❌ DEBUG: Config missing browser profiles - will regenerate"
            NEED_GENERATE=true
        else
            echo "✅ DEBUG: Existing config is valid and complete"
        fi
    else
        echo "❌ DEBUG: Existing config is INVALID JSON - will regenerate"
        NEED_GENERATE=true
    fi
else
    echo "🔍 DEBUG: Config file does not exist - will generate"
    NEED_GENERATE=true
fi

# Generate config if needed
if [ "$NEED_GENERATE" = true ]; then
    echo "🏥 Generating openclaw.json with browser configuration..."
    
    # Determine primary model based on available API keys
    PRIMARY_MODEL="openai/gpt-4o"
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        PRIMARY_MODEL="anthropic/claude-sonnet-4-5"
    elif [ -n "$OPENAI_API_KEY" ]; then
        PRIMARY_MODEL="openai/gpt-5.2"
    elif [ -n "$GEMINI_API_KEY" ]; then
        PRIMARY_MODEL="google/gemini-2.5-pro"
    fi
    
    # Write JSON directly without heredoc to avoid any expansion issues
    echo '{' > "$CONFIG_FILE"
    echo '  "commands": {' >> "$CONFIG_FILE"
    echo '    "native": true,' >> "$CONFIG_FILE"
    echo '    "text": true,' >> "$CONFIG_FILE"
    echo '    "bash": true,' >> "$CONFIG_FILE"
    echo '    "config": true' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "channels": {' >> "$CONFIG_FILE"
    echo '    "telegram": {' >> "$CONFIG_FILE"
    echo '      "enabled": true' >> "$CONFIG_FILE"
    echo '    }' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "plugins": {' >> "$CONFIG_FILE"
    echo '    "enabled": true,' >> "$CONFIG_FILE"
    echo '    "entries": {' >> "$CONFIG_FILE"
    echo '      "telegram": {' >> "$CONFIG_FILE"
    echo '        "enabled": true' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    }' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "browser": {' >> "$CONFIG_FILE"
    echo '    "enabled": true,' >> "$CONFIG_FILE"
    echo '    "profiles": {' >> "$CONFIG_FILE"
    echo '      "vnc": {' >> "$CONFIG_FILE"
    echo '        "cdpUrl": "http://browser-vnc:9222",' >> "$CONFIG_FILE"
    echo '        "color": "#00AA00"' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    }' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "gateway": {' >> "$CONFIG_FILE"
    echo "    \"port\": $GATEWAY_PORT," >> "$CONFIG_FILE"
    echo '    "mode": "local",' >> "$CONFIG_FILE"
    echo "    \"bind\": \"${OPENCLAW_GATEWAY_BIND:-lan}\"," >> "$CONFIG_FILE"
    echo "    \"auth\": { \"mode\": \"token\", \"token\": \"${GATEWAY_TOKEN}\" }" >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "agents": {' >> "$CONFIG_FILE"
    echo '    "defaults": {' >> "$CONFIG_FILE"
    echo "      \"workspace\": \"${WORKSPACE_DIR}\"," >> "$CONFIG_FILE"
    echo "      \"model\": { \"primary\": \"${PRIMARY_MODEL}\" }," >> "$CONFIG_FILE"
    echo '      "maxConcurrent": 2,' >> "$CONFIG_FILE"
    echo '      "sandbox": {' >> "$CONFIG_FILE"
    echo '        "browser": {' >> "$CONFIG_FILE"
    echo '          "enabled": true' >> "$CONFIG_FILE"

    echo '        }' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    },' >> "$CONFIG_FILE"
    echo '    "list": [' >> "$CONFIG_FILE"
    echo "      { \"id\": \"main\", \"default\": true, \"workspace\": \"${WORKSPACE_DIR}\" }" >> "$CONFIG_FILE"
    echo '    ]' >> "$CONFIG_FILE"
    echo '  }' >> "$CONFIG_FILE"
    echo '}' >> "$CONFIG_FILE"
    
    echo "✅ Generated new config file with browser support"
fi

# Final validation
if validate_json "$CONFIG_FILE"; then
    echo "✅ Final config validation passed"
else
    echo "❌ FATAL: Config file is still invalid after generation!"
    echo "   Contents:"
    cat "$CONFIG_FILE"
    exit 1
fi

# Export state
export OPENCLAW_STATE_DIR="$OPENCLAW_STATE"

echo ""
echo "=================================================================="
echo "🦞 OpenClaw with Browser-VNC is ready!"
echo "=================================================================="
echo ""
echo "🔑 Access Token: $GATEWAY_TOKEN"
echo ""
echo "🌍 OpenClaw Gateway: http://localhost:$GATEWAY_PORT?token=$GATEWAY_TOKEN"
if [ -n "$CONTAINER_NAME" ]; then
    echo "📦 Container: $CONTAINER_NAME"
fi
echo ""
echo "🌐 Browser noVNC: http://localhost:$NOVNC_PORT/vnc.html"
if [ -n "$VNC_PASSWORD" ]; then
    echo "🔒 VNC Password: $VNC_PASSWORD"
fi
echo ""
echo "=================================================================="

# Run OpenClaw
exec openclaw gateway run
