#!/bin/bash
set -euo pipefail

# DinD wrapper: starts the Docker daemon as root, fixes socket permissions,
# then drops to the agent user to run the underlying container entrypoint.
#
# Usage: entrypoint-dind.sh <underlying-entrypoint> [cmd-args...]
#
# If overlay2 fails (nested overlayfs on some hosts), fall back to vfs:
#   docker info 2>&1 | grep "Storage Driver"
# If container networking hangs, switch iptables backend:
#   update-alternatives --set iptables /usr/sbin/iptables-legacy

UNDERLYING="$1"
shift

# On a container *restart* Docker reuses the writable layer, so a pidfile from
# the previous boot survives at /var/run/docker.pid. dockerd then refuses to
# start ("pid file found, ensure docker is not running or delete
# /var/run/docker.pid"), and because PIDs are reused after a restart it can even
# mistake its own fresh PID for a live daemon. This script only runs as the
# container's init at boot, so any prior daemon is already dead — clear stale
# runtime state before launching.
rm -f /var/run/docker.pid
rm -f /var/run/docker/containerd/containerd.pid 2>/dev/null || true

# Start dockerd in the background (--data-root lives on the VOLUME /var/lib/docker
# so overlay2 runs on a real filesystem, not the container's overlayfs root)
dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver=overlay2 \
    --log-level=warn \
    &
DOCKERD_PID=$!

echo "[dind] Waiting for Docker daemon (PID=$DOCKERD_PID)..."
for i in $(seq 1 30); do
    # If dockerd exited (e.g. stale pidfile, bad storage driver), fail fast and
    # loudly instead of silently waiting out the full 30s timeout.
    if ! kill -0 "$DOCKERD_PID" 2>/dev/null; then
        echo "[dind] ERROR: dockerd (PID=$DOCKERD_PID) exited during startup" >&2
        wait "$DOCKERD_PID" 2>/dev/null || true
        exit 1
    fi
    if docker info >/dev/null 2>&1; then
        echo "[dind] Docker daemon ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "[dind] ERROR: Docker daemon did not start within 30s" >&2
        kill "$DOCKERD_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

# Grant agent user socket access — agent is in the docker group
chown root:docker /var/run/docker.sock
chmod 660 /var/run/docker.sock

exec gosu agent "$UNDERLYING" "$@"
