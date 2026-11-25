#!/bin/sh
set -eu

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "Symphony is stopped: set LINEAR_API_KEY in Dokploy." >&2
  exit 78
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "Symphony is stopped: set the repository-scoped GITHUB_TOKEN in Dokploy." >&2
  exit 78
fi

if ! codex login status >/dev/null 2>&1; then
  echo "Symphony is stopped: complete the Codex ChatGPT login in its persistent volume." >&2
  exit 78
fi

exec /app/bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails /app/WORKFLOW.md
