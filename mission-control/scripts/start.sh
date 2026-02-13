#!/bin/bash
cd "$(dirname "$0")/.."
mkdir -p data
exec pnpm dev -p 3333
