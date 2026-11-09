#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

case "${1:-}" in
    "") xcrun swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests ;;
    --check) xcrun swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests ;;
    *) echo "Usage: bash scripts/format.sh [--check]" >&2; exit 1 ;;
esac
