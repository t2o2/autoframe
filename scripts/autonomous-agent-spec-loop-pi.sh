#!/usr/bin/env bash
# Thin wrapper for the pi container variant — the spec-loop daemon is
# runtime-agnostic (the target repo's scripts/spec-loop.sh auto-detects
# claude vs pi in PATH), so both compose services share one implementation.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/autonomous-agent-spec-loop.sh" "$@"
