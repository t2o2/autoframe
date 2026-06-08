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
