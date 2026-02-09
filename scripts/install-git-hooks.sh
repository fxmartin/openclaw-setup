#!/usr/bin/env bash
# install-git-hooks.sh - Configure version-controlled git hooks
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source logging utilities
source "$REPO_ROOT/provision/lib/logging.sh"

banner "Git Hooks Setup"

# Configure git to use .githooks directory
log_info "Setting git hooks path to .githooks/"
git -C "$REPO_ROOT" config core.hooksPath .githooks

# Ensure hooks are executable
log_info "Making hooks executable"
chmod +x "$REPO_ROOT"/.githooks/*

log_success "Git hooks configured"

# Check gitleaks availability
if command -v gitleaks &> /dev/null; then
    log_success "gitleaks found: $(gitleaks version 2>/dev/null || echo 'installed')"
else
    log_warn "gitleaks is not installed — pre-commit hook will block commits"
    log_warn "Install: brew install gitleaks"
fi

separator
log_info "Done. Pre-commit secret scanning is now active."
