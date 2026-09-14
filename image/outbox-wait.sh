#!/bin/sh
# Streams the name of every new publish request (<seq>.meta) in the outbox, one per line,
# until the container stops. The host wrapper runs this via `docker exec` and reacts to each line.
outbox=/run/orca-docker/outbox
mkdir -p "$outbox"
seen=" "
while :; do
  for m in "$outbox"/*.meta; do
    [ -e "$m" ] || continue
    case "$seen" in *" $m "*) continue ;; esac
    seen="$seen$m "
    echo "$(basename "$m")"
  done
  sleep 0.5
done
