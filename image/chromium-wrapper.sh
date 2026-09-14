#!/bin/sh
# Chromium needs --no-sandbox inside an unprivileged container (no user namespaces for its own sandbox).
# shellcheck disable=SC2086
exec /usr/bin/chromium ${CHROMIUM_FLAGS:-} "$@"
