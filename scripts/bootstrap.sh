#!/usr/bin/env bash
set -e

# Use environment variables or defaults
OPENCLAW_STATE="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
CONFIG_FILE="$OPENCLAW_STATE/openclaw.json"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-/data/openclaw-workspace}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
GATEWAY_TAILSCALE_MODE="${OPENCLAW_GATEWAY_TAILSCALE_MODE:-serve}"
GATEWAY_ALLOW_TAILSCALE_AUTH="${OPENCLAW_GATEWAY_ALLOW_TAILSCALE_AUTH:-true}"
GATEWAY_ALLOW_INSECURE_AUTH="${OPENCLAW_GATEWAY_ALLOW_INSECURE_AUTH:-true}"
GATEWAY_ALLOWED_ORIGINS="${OPENCLAW_GATEWAY_ALLOWED_ORIGINS:-https://api.easyclaw.ai,http://localhost:3001}"
ROUTING_MODE="${OPENCLAW_MODEL_ROUTING_MODE:-byo}"
ROUTER_BASE_URL="${EASYCLAW_MODEL_ROUTER_BASE_URL:-}"
ROUTER_TOKEN="${EASYCLAW_MODEL_ROUTER_TOKEN:-}"
ROUTER_PROVIDER_ID="${EASYCLAW_ROUTER_PROVIDER_ID:-easyclaw-router}"
ROUTER_MODEL_ID="${EASYCLAW_ROUTER_MODEL_ID:-gpt-5.2}"
ROUTER_USER_ID="${EASYCLAW_BILLING_USER_ID:-}"
ROUTER_APPLICATION_ID="${EASYCLAW_BILLING_APPLICATION_ID:-}"
ROUTER_PROVIDER_MODEL_ID="${EASYCLAW_PROVIDER_MODEL_ID:-}"
ROUTER_PROVIDER_TYPE="${EASYCLAW_PROVIDER_TYPE:-openai}"

# Browser configuration
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PASSWORD="${VNC_PASSWORD:-}"

# browser-vnc container IP resolution for Chrome CDP compatibility
# Chrome requires Host header to be localhost or IP, rejecting hostnames
# We resolve browser-vnc's Docker DNS to get its internal IP
BROWSER_VNC_HOST="browser-vnc"
echo "🔍 Resolving browser-vnc container IP..."
BROWSER_VNC_IP=$(getent hosts "$BROWSER_VNC_HOST" 2>/dev/null | awk '{ print $1 }')
if [ -z "$BROWSER_VNC_IP" ]; then
    echo "⚠️  Could not resolve browser-vnc IP via DNS, trying alternative methods..."
    # Fallback: try to get IP from container's /etc/hosts
    BROWSER_VNC_IP=$(cat /etc/hosts 2>/dev/null | grep "$BROWSER_VNC_HOST" | awk '{ print $1 }')
fi
if [ -z "$BROWSER_VNC_IP" ]; then
    echo "⚠️  Warning: Could not resolve browser-vnc IP. Chrome CDP may reject connections."
    echo "    Using hostname as fallback (this may fail with Chrome's Host header validation)"
    BROWSER_VNC_IP="$BROWSER_VNC_HOST"
else
    echo "✅ Resolved browser-vnc IP: $BROWSER_VNC_IP"
fi

# Wait a moment for browser-vnc to fully start
echo "⏳ Waiting 5 seconds for browser-vnc Chrome to be ready..."
sleep 5

# Test if CDP is reachable via IP (more reliable than hostname)
echo "🔍 Testing CDP connection to http://${BROWSER_VNC_IP}:9222..."
if curl -sS --max-time 5 "http://${BROWSER_VNC_IP}:9222/json/version" >/dev/null 2>&1; then
    echo "✅ CDP is reachable at http://${BROWSER_VNC_IP}:9222"
    CDP_URL="http://${BROWSER_VNC_IP}:9222"
else
    echo "⚠️  CDP not yet reachable at ${BROWSER_VNC_IP}:9222 - OpenClaw may retry on first browser use"
    CDP_URL="http://${BROWSER_VNC_IP}:9222"
fi

echo "🔍 DEBUG: Starting bootstrap"
echo "   BROWSER_VNC_HOST=$BROWSER_VNC_HOST"
echo "   BROWSER_VNC_IP=$BROWSER_VNC_IP"
echo "   CDP_URL=$CDP_URL"
echo "   CONFIG_FILE=$CONFIG_FILE"
echo "   GATEWAY_PORT=$GATEWAY_PORT"
echo "   GATEWAY_BIND=$GATEWAY_BIND"
echo "   GATEWAY_TAILSCALE_MODE=$GATEWAY_TAILSCALE_MODE"
echo "   GATEWAY_ALLOW_TAILSCALE_AUTH=$GATEWAY_ALLOW_TAILSCALE_AUTH"
echo "   GATEWAY_ALLOW_INSECURE_AUTH=$GATEWAY_ALLOW_INSECURE_AUTH"
echo "   GATEWAY_ALLOWED_ORIGINS=$GATEWAY_ALLOWED_ORIGINS"
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

# Resolve effective Tailscale mode with runtime guardrails.
EFFECTIVE_GATEWAY_TAILSCALE_MODE="$GATEWAY_TAILSCALE_MODE"
if [ "$GATEWAY_TAILSCALE_MODE" = "serve" ] || [ "$GATEWAY_TAILSCALE_MODE" = "funnel" ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "⚠️  tailscale CLI not found in container; falling back to gateway.tailscale.mode=off"
        EFFECTIVE_GATEWAY_TAILSCALE_MODE="off"
    elif ! tailscale status >/dev/null 2>&1; then
        echo "⚠️  tailscaled is not reachable; falling back to gateway.tailscale.mode=off"
        EFFECTIVE_GATEWAY_TAILSCALE_MODE="off"
    fi
fi

if [ "$EFFECTIVE_GATEWAY_TAILSCALE_MODE" != "off" ] && [ "$GATEWAY_BIND" != "loopback" ]; then
    echo "ℹ️  For tailscale mode '$EFFECTIVE_GATEWAY_TAILSCALE_MODE', forcing gateway bind to loopback"
    GATEWAY_BIND="loopback"
fi

# Validate that at least one AI provider key is set
if [ "$ROUTING_MODE" = "platform" ]; then
    if [ -z "$ROUTER_BASE_URL" ] || [ -z "$ROUTER_TOKEN" ]; then
        echo "❌ platform routing mode requires EASYCLAW_MODEL_ROUTER_BASE_URL and EASYCLAW_MODEL_ROUTER_TOKEN"
        exit 1
    fi
else
    if [ -z "$OPENAI_API_KEY" ] && [ -z "$ANTHROPIC_API_KEY" ] && [ -z "$GEMINI_API_KEY" ] && \
       [ -z "$MINIMAX_API_KEY" ] && [ -z "$KIMI_API_KEY" ] && [ -z "$OPENCODE_API_KEY" ] && \
       [ -z "$MOONSHOT_API_KEY" ]; then
        echo "⚠️  Warning: No AI provider API key detected. OpenClaw will not be able to process AI requests."
        echo "    Set at least one of: OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, etc."
    fi
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

# Always regenerate config to ensure fresh IP resolution
# (Commented out config checking to force regeneration every time)
echo "🔍 DEBUG: Force regenerating config file..."
NEED_GENERATE=true

# Generate config if needed
if [ "$NEED_GENERATE" = true ]; then
    echo "🏥 Generating openclaw.json with browser configuration..."
    
    # Determine primary model based on available API keys
    PRIMARY_MODEL="openai/gpt-5.2"
    if [ "$ROUTING_MODE" = "platform" ]; then
        PRIMARY_MODEL="${ROUTER_PROVIDER_ID}/${ROUTER_MODEL_ID}"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
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
    echo '    "defaultProfile": "vnc",' >> "$CONFIG_FILE"
    echo '    "attachOnly": true,' >> "$CONFIG_FILE"
    echo '    "profiles": {' >> "$CONFIG_FILE"
    echo '      "vnc": {' >> "$CONFIG_FILE"
    echo "        \"cdpUrl\": \"http://${BROWSER_VNC_IP}:9222\"," >> "$CONFIG_FILE"
    echo '        "color": "#00AA00"' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    }' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "gateway": {' >> "$CONFIG_FILE"
    echo "    \"port\": $GATEWAY_PORT," >> "$CONFIG_FILE"
    echo '    "mode": "local",' >> "$CONFIG_FILE"
    echo "    \"bind\": \"${GATEWAY_BIND}\"," >> "$CONFIG_FILE"
    echo "    \"tailscale\": { \"mode\": \"${EFFECTIVE_GATEWAY_TAILSCALE_MODE}\" }," >> "$CONFIG_FILE"
    ALLOWED_ORIGINS_JSON=$(printf '%s' "$GATEWAY_ALLOWED_ORIGINS" | awk -F',' '{
      printf "[";
      for (i = 1; i <= NF; i++) {
        gsub(/^ +| +$/, "", $i);
        if ($i != "") {
          if (count > 0) printf ",";
          printf "\"%s\"", $i;
          count++;
        }
      }
      printf "]";
    }')
    echo "    \"controlUi\": { \"allowInsecureAuth\": ${GATEWAY_ALLOW_INSECURE_AUTH}, \"allowedOrigins\": ${ALLOWED_ORIGINS_JSON} }," >> "$CONFIG_FILE"
    echo "    \"auth\": { \"mode\": \"token\", \"token\": \"${GATEWAY_TOKEN}\", \"allowTailscale\": ${GATEWAY_ALLOW_TAILSCALE_AUTH} }" >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    if [ "$ROUTING_MODE" = "platform" ]; then
        echo '  "models": {' >> "$CONFIG_FILE"
        echo '    "mode": "merge",' >> "$CONFIG_FILE"
        echo '    "providers": {' >> "$CONFIG_FILE"
        echo "      \"${ROUTER_PROVIDER_ID}\": {" >> "$CONFIG_FILE"
        echo "        \"baseUrl\": \"${ROUTER_BASE_URL}\"," >> "$CONFIG_FILE"
        echo '        "api": "openai-completions",' >> "$CONFIG_FILE"
        echo "        \"apiKey\": \"${ROUTER_TOKEN}\"," >> "$CONFIG_FILE"
        # Identity/auth comes from bearer token; x-easyclaw-* headers are observability metadata only.
        echo '        "headers": {' >> "$CONFIG_FILE"
        echo "          \"authorization\": \"Bearer ${ROUTER_TOKEN}\"," >> "$CONFIG_FILE"
        echo "          \"x-easyclaw-provider-type\": \"${ROUTER_PROVIDER_TYPE}\"," >> "$CONFIG_FILE"
        echo "          \"x-easyclaw-user-id\": \"${ROUTER_USER_ID}\"," >> "$CONFIG_FILE"
        echo "          \"x-easyclaw-application-id\": \"${ROUTER_APPLICATION_ID}\"," >> "$CONFIG_FILE"
        echo "          \"x-easyclaw-provider-model-id\": \"${ROUTER_PROVIDER_MODEL_ID}\"" >> "$CONFIG_FILE"
        echo '        },' >> "$CONFIG_FILE"
        echo '        "models": [' >> "$CONFIG_FILE"
        echo "          { \"id\": \"${ROUTER_MODEL_ID}\", \"name\": \"${ROUTER_MODEL_ID}\" }" >> "$CONFIG_FILE"
        echo '        ]' >> "$CONFIG_FILE"
        echo '      }' >> "$CONFIG_FILE"
        echo '    }' >> "$CONFIG_FILE"
        echo '  },' >> "$CONFIG_FILE"
    fi
    echo '  "agents": {' >> "$CONFIG_FILE"
    echo '    "defaults": {' >> "$CONFIG_FILE"
    echo "      \"workspace\": \"${WORKSPACE_DIR}\"," >> "$CONFIG_FILE"
    echo "      \"model\": { \"primary\": \"${PRIMARY_MODEL}\" }," >> "$CONFIG_FILE"
    echo '      "maxConcurrent": 2,' >> "$CONFIG_FILE"
    echo '      "sandbox": {' >> "$CONFIG_FILE"
    echo '        "mode": "off",' >> "$CONFIG_FILE"
    echo '        "browser": {' >> "$CONFIG_FILE"
    echo '          "enabled": false,' >> "$CONFIG_FILE"
    echo '          "allowHostControl": true' >> "$CONFIG_FILE"
    echo '        },' >> "$CONFIG_FILE"
    echo '        "docker": {' >> "$CONFIG_FILE"
    echo '          "network": "bridge"' >> "$CONFIG_FILE"
    echo '        }' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    },' >> "$CONFIG_FILE"
    echo '    "list": [' >> "$CONFIG_FILE"
    echo "      { \"id\": \"main\", \"default\": true, \"workspace\": \"${WORKSPACE_DIR}\" }" >> "$CONFIG_FILE"
    echo '    ]' >> "$CONFIG_FILE"
    echo '  },' >> "$CONFIG_FILE"
    echo '  "tools": {' >> "$CONFIG_FILE"
    echo '    "sandbox": {' >> "$CONFIG_FILE"
    echo '      "tools": {' >> "$CONFIG_FILE"
    echo '        "deny": ["browser", "canvas", "nodes", "cron", "discord", "gateway"]' >> "$CONFIG_FILE"
    echo '      }' >> "$CONFIG_FILE"
    echo '    }' >> "$CONFIG_FILE"
    echo '  }' >> "$CONFIG_FILE"
    echo '}' >> "$CONFIG_FILE"  
    
    echo "✅ Generated new config file with browser support"
fi

# Final validation
if validate_json "$CONFIG_FILE"; then
    echo "✅ Final config validation passed"
    echo ""
    echo "🔍 DEBUG: Generated config:"
    cat "$CONFIG_FILE"
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
echo "🌐 Browser CDP: http://${BROWSER_VNC_IP}:9222 (internal Docker network, IP-based for Chrome Host header)"
echo "🌐 Browser noVNC: http://localhost:$NOVNC_PORT/vnc.html"
if [ -n "$VNC_PASSWORD" ]; then
    echo "🔒 VNC Password: $VNC_PASSWORD"
fi
echo ""
echo "=================================================================="

# Run OpenClaw
exec openclaw gateway run
