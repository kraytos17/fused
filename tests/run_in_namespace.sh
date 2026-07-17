#!/usr/bin/env bash
# tests/run_in_namespace.sh — Run a command inside an isolated mount namespace.
# Usage:  tests/run_in_namespace.sh <timeout> <command> [args...]
#
# Thin wrapper around `unshare -rUm` that bash can do but Python can't.
# Everything else lives in Python.
set -euo pipefail

TIMEOUT="${1:-60}"; shift
exec unshare -rUm timeout -k 5 "$TIMEOUT" "$@"
