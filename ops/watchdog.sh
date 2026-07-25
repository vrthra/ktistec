#!/bin/bash
# Watches for the Ktistec server process dying unexpectedly (e.g. OOM-killed)
# and restarts it via `make start-server` inside the tmux window named
# "server" (session 0), where the server normally runs in the foreground.
# Targeting by name, not index, matters: window indices shift whenever
# windows are opened/closed (e.g. a human attaching and closing panes), but
# the name survives.
#
# Safety valve: `touch ~/ktistec/watchdog.pause` (or `make watchdog-pause`)
# suspends restarts during manual maintenance/deploys; `rm` it (or `make
# watchdog-resume`) to resume.
#
# Crash-loop guard: if it has to restart MAX_RESTARTS times within
# WINDOW_SECONDS, it pauses itself and logs a CRITICAL line instead of
# restart-looping forever on a low-memory host.
#
# Runs forever in its own tmux window. Logs to ~/ktistec/watchdog.log.

set -u

APPDIR="$HOME/ktistec"
LOG="$APPDIR/watchdog.log"
PAUSE="$APPDIR/watchdog.pause"
STATE="$APPDIR/watchdog.restarts"
TMUX_TARGET="0:server"
CHECK_INTERVAL=15
MAX_RESTARTS=3
WINDOW_SECONDS=300

log() { echo "$(date -Is) $*" >> "$LOG"; }

touch "$STATE"
log "watchdog started (pid $$)"

while true; do
  sleep "$CHECK_INTERVAL"

  [ -f "$PAUSE" ] && continue
  pgrep -x server >/dev/null && continue

  now=$(date +%s)
  # drop restart timestamps outside the sliding window
  awk -v now="$now" -v w="$WINDOW_SECONDS" '(now - $1) <= w' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  count=$(wc -l < "$STATE")

  if [ "$count" -ge "$MAX_RESTARTS" ]; then
    log "CRITICAL: $count restarts in the last ${WINDOW_SECONDS}s — pausing watchdog, needs manual attention"
    touch "$PAUSE"
    continue
  fi

  log "server process not found — restarting (restart #$((count + 1)) in current window)"
  tmux send-keys -t "$TMUX_TARGET" 'cd ~/ktistec && make start-server' Enter
  echo "$now" >> "$STATE"
  sleep 20
done
