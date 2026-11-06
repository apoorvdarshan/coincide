#!/bin/sh
# Immutable executable: per-test protocol bodies are data, never exec targets.
exec /bin/sh "${0}.body" "$@"
