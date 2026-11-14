#!/bin/sh
# Keeps the Logseq desktop app running with the sync graph open, so the MCP server has a graph.
# Runs under xvfb-run. See bootstrap-graph.js for the sign-in and download step, which uses the
# app's MCP /api route and then quits the app so this loop restarts it with the graph open.
set -u

LOG=/tmp/logseq.log
touch "$LOG"
tail -F "$LOG" &

# Start the virtual display directly. xvfb-run waits on a USR1 signal from Xvfb that never arrives here.
# Clear leftovers from a previous run, otherwise the socket check below passes before Xvfb is up.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp >>/tmp/xvfb.log 2>&1 &
export DISPLAY=:99
while [ ! -e /tmp/.X11-unix/X99 ]; do sleep 0.5; done

: "${LOGSEQ_GRAPH_NAME:?set LOGSEQ_GRAPH_NAME in .env}"
export LOGSEQ_DATA_DIR=/data
# The app keeps graphs and lifecycle state under $HOME/logseq, so point HOME at the persistent volume.
export HOME=/data/home
mkdir -p "$HOME"
export SYNC_SERVER_URL="${SYNC_SERVER_URL:-http://sync:8787}"

while :; do
  ELECTRON_RUN_AS_NODE=1 /opt/logseq/logseq /opt/harbor/bootstrap-graph.js >>"$LOG" 2>&1 &
  if [ -f "$LOGSEQ_DATA_DIR/.downloaded-$LOGSEQ_GRAPH_NAME" ]; then
    GRAPH_ARGS="logseq://graph/$LOGSEQ_GRAPH_NAME"
  else
    GRAPH_ARGS=""
  fi
  dbus-run-session -- /opt/logseq/logseq --no-sandbox --disable-gpu --ozone-platform=headless --proxy-server=direct:// \
    --user-data-dir=/data/electron \
    $GRAPH_ARGS >>"$LOG" 2>&1
  sleep 3
done
