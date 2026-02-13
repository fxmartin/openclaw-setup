#!/bin/bash
# Re-index workspace files into Mission Control search
curl -s -X POST http://localhost:3333/api/reindex | jq .
