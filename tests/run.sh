#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/tests/agent.test.sh"

if command -v node >/dev/null 2>&1; then
    if [[ -d "$ROOT_DIR/node_modules" ]]; then
        node --test "$ROOT_DIR/tests/server.test.js"
    else
        echo "skip - Node API tests require dependencies; run: npm install"
    fi
else
    echo "skip - Node API tests require node"
fi
