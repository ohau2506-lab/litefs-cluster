#!/bin/bash
# entrypoint.sh — Điểm vào chính của container
# Thứ tự: tailscaled → tailscale up → bootstrap.sh (consul) → litefs mount
set -euo pipefail

LOG_P="[ENTRY]"
log() { echo "$LOG_P [$(date '+%H:%M:%S')] $*"; }

# ── Graceful shutdown ─────────────────────────────────────────────────────────
# Pitfall: Nếu không consul leave trước khi stop, cluster mất quorum lâu hơn
# (Consul health check timeout ~10s thay vì leave ngay)
CLEANING=false
cleanup() {
    $CLEANING && return
    CLEANING=true
    log "═══ GRACEFUL SHUTDOWN ═══"

    # Leave Consul trước → cluster tự re-elect ngay, không cần chờ timeout
    if consul members &>/dev/null 2>&1; then
        log "Leaving Consul cluster..."
        consul leave 2>/dev/null || true
        sleep 2
    fi

    # Kill background jobs (tailscaled, etc.)
    local pids
    pids=$(jobs -p 2>/dev/null || true)
    [ -n "$pids" ] && echo "$pids" | xargs -r kill 2>/dev/null || true

    log "═══ SHUTDOWN DONE ═══"
}
trap cleanup SIGTERM SIGINT EXIT

# ── 1. Tạo /dev/net/tun nếu chưa có ─────────────────────────────────────────
# Pitfall: Trong một số Docker setup, /dev/net/tun không tự có dù có --privileged
log "Setting up TUN device..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 0666 /dev/net/tun
    log "  Created /dev/net/tun"
else
    log "  /dev/net/tun already exists"
fi

# ── 2. Start tailscaled ───────────────────────────────────────────────────────
log "Starting tailscaled..."
mkdir -p /var/lib/tailscale

tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    >> /var/log/tailscaled.log 2>&1 &

TAILSCALED_PID=$!
log "tailscaled PID: $TAILSCALED_PID"

# Chờ tailscaled socket sẵn sàng
mkdir -p /var/run/tailscale
sock_wait=0
while [ $sock_wait -lt 15 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
    sleep 1
    sock_wait=$((sock_wait + 1))
done

# ── 3. Authenticate Tailscale ─────────────────────────────────────────────────
# Pitfall: --accept-dns=false quan trọng! Không dùng Tailscale DNS trong container
# vì có thể gây conflict với container DNS
log "Authenticating Tailscale (hostname: ${NODE_NAME:-litefs-$(hostname | cut -c1-8)})..."
tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --advertise-tags="${TS_TAGS:-tag:litefs-node}" \
    --hostname="${NODE_NAME:-litefs-$(hostname | cut -c1-8)}" \
    --accept-routes \
    --accept-dns=false \
    2>&1 | tee -a /var/log/tailscaled.log

log "✓ Tailscale authenticated"
tailscale status 2>/dev/null | head -5 || true

# ── 4. Bootstrap Consul ───────────────────────────────────────────────────────
/usr/local/bin/bootstrap.sh

# ── 5. Set advertise URL cho LiteFS ──────────────────────────────────────────
# Pitfall: Phải export TRƯỚC khi gọi litefs, vì litefs.yml đọc ${LITEFS_ADVERTISE_URL}
MY_IP=$(tailscale ip -4 2>/dev/null) || { log "ERROR: No Tailscale IP"; exit 1; }
export LITEFS_ADVERTISE_URL="$MY_IP"
log "LiteFS will advertise at: http://$MY_IP:20202"

# ── 6. Start LiteFS ───────────────────────────────────────────────────────────
# Pitfall: litefs mount BLOCKS cho đến khi exec command (run-app.sh) exit
# → Đây là main process, không chạy background
log "Starting LiteFS (this will block until run-app.sh exits)..."
log "═══════════════════════════════════════════"

# exec litefs mount -config /etc/litefs.yml
# Thay dòng exec litefs mount bằng:
envsubst < /etc/litefs.yml > /tmp/litefs-rendered.yml
exec litefs mount -config /tmp/litefs-rendered.yml
