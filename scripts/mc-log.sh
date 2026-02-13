#!/bin/bash
# Usage: mc-log.sh <action_type> <description> [status] [duration_ms] [details_json]
# Example: mc-log.sh "web_search" "Searched for Bitcoin price" "success" 1200 '{"query":"btc"}'
curl -s -X POST http://localhost:3333/api/activity \
  -H 'Content-Type: application/json' \
  -d "{\"action_type\":\"$1\",\"description\":\"$2\",\"status\":\"${3:-success}\",\"duration_ms\":${4:-0},\"details\":${5:-null}}"
