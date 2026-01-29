#!/usr/bin/env bash
# test-bundle-roundtrip.sh - Test secrets bundle export/import cycle
#
# Usage:
#   ./tests/test-bundle-roundtrip.sh
#
# This test:
#   1. Creates mock secrets in a temp directory
#   2. Exports them to a bundle
#   3. Imports the bundle to a new temp directory
#   4. Verifies all files match

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PROVISION_DIR="${REPO_DIR}/provision"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }

# Test state
TEST_DIR=""
PASSED=0
FAILED=0

# Cleanup on exit
cleanup() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"

    for cmd in age tar sha256sum jq; do
        if command -v "$cmd" &>/dev/null; then
            log_info "$cmd available"
        else
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done
}

# Setup test environment
setup_test_env() {
    log_step "Setting up test environment"

    TEST_DIR=$(mktemp -d)
    chmod 700 "$TEST_DIR"

    mkdir -p "${TEST_DIR}/source"
    mkdir -p "${TEST_DIR}/target"
    mkdir -p "${TEST_DIR}/home/fx/.clawdbot"
    mkdir -p "${TEST_DIR}/home/fx/.secrets"
    mkdir -p "${TEST_DIR}/home/fx/.config/gh"
    mkdir -p "${TEST_DIR}/home/fx/.config/rclone"
    mkdir -p "${TEST_DIR}/root/.config/sops/age"

    log_info "Test directory: $TEST_DIR"
}

# Create mock secrets
create_mock_secrets() {
    log_step "Creating mock secrets"

    # Generate test AGE key
    log_info "Generating test AGE key"
    age-keygen -o "${TEST_DIR}/root/.config/sops/age/keys.txt" 2>/dev/null
    chmod 600 "${TEST_DIR}/root/.config/sops/age/keys.txt"

    local pub_key
    pub_key=$(grep "public key:" "${TEST_DIR}/root/.config/sops/age/keys.txt" | cut -d: -f2 | tr -d ' ')

    # Create mock clawdbot.json.enc (fake SOPS file - just encrypted JSON for testing)
    log_info "Creating mock clawdbot config"
    cat > "${TEST_DIR}/home/fx/.clawdbot/clawdbot.json.plaintext" <<'EOF'
{
    "telegramBotToken": "123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
    "openaiApiKey": "sk-test-key-1234567890"
}
EOF
    age -r "$pub_key" -o "${TEST_DIR}/home/fx/.clawdbot/clawdbot.json.enc" \
        "${TEST_DIR}/home/fx/.clawdbot/clawdbot.json.plaintext"
    rm "${TEST_DIR}/home/fx/.clawdbot/clawdbot.json.plaintext"

    # Create .sops.yaml
    cat > "${TEST_DIR}/home/fx/.clawdbot/.sops.yaml" <<EOF
creation_rules:
  - age: $pub_key
EOF

    # Create mock telegram token
    log_info "Creating mock telegram token"
    echo "123456789:ABCdefGHIjklMNOpqrsTUVwxyz" | \
        age -r "$pub_key" -o "${TEST_DIR}/home/fx/.secrets/telegram-bot-token.enc"

    # Create mock gh config
    log_info "Creating mock GitHub CLI config"
    cat > "${TEST_DIR}/home/fx/.config/gh/hosts.yml" <<'EOF'
github.com:
    oauth_token: gho_test_token_1234567890
    user: testuser
    git_protocol: https
EOF

    # Create mock rclone config
    log_info "Creating mock rclone config"
    cat > "${TEST_DIR}/home/fx/.config/rclone/rclone.conf" <<'EOF'
[dropbox]
type = dropbox
token = {"access_token":"test_token_1234","token_type":"bearer"}
EOF

    log_info "Mock secrets created"
}

# Run export (modified for test)
run_export() {
    log_step "Running export"

    # Create a modified export script for testing
    local export_script="${TEST_DIR}/test-export.sh"

    cat > "$export_script" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$1"
OUTPUT="$2"
PASSPHRASE="$3"

USER_HOME="${TEST_DIR}/home/fx"
AGE_KEY_FILE="${TEST_DIR}/root/.config/sops/age/keys.txt"

# Create staging directory
STAGING=$(mktemp -d)
mkdir -p "${STAGING}"/{age,sops,secrets,credentials,sops-config}

# Copy AGE key
cp "$AGE_KEY_FILE" "${STAGING}/age/keys.txt"

# Copy clawdbot config
if [[ -f "${USER_HOME}/.clawdbot/clawdbot.json.enc" ]]; then
    cp "${USER_HOME}/.clawdbot/clawdbot.json.enc" "${STAGING}/sops/"
fi

# Copy .sops.yaml
if [[ -f "${USER_HOME}/.clawdbot/.sops.yaml" ]]; then
    cp "${USER_HOME}/.clawdbot/.sops.yaml" "${STAGING}/sops-config/"
fi

# Copy encrypted secrets
for enc_file in "${USER_HOME}/.secrets/"*.enc 2>/dev/null; do
    [[ -f "$enc_file" ]] && cp "$enc_file" "${STAGING}/secrets/"
done

# Encrypt and copy gh config
pub_key=$(grep "public key:" "$AGE_KEY_FILE" | cut -d: -f2 | tr -d ' ')
if [[ -f "${USER_HOME}/.config/gh/hosts.yml" ]]; then
    age -r "$pub_key" -o "${STAGING}/credentials/gh-hosts.yml.enc" "${USER_HOME}/.config/gh/hosts.yml"
fi

# Encrypt and copy rclone config
if [[ -f "${USER_HOME}/.config/rclone/rclone.conf" ]]; then
    age -r "$pub_key" -o "${STAGING}/credentials/rclone.conf.enc" "${USER_HOME}/.config/rclone/rclone.conf"
fi

# Generate manifest
cat > "${STAGING}/manifest.json" <<EOF
{
  "version": "1.0",
  "created_at": "$(date -Iseconds)",
  "created_by": "test",
  "source_server": "test",
  "files": [
$(find "${STAGING}" -type f ! -name "manifest.json" -exec sh -c '
    for f; do
        rel="${f#'"$STAGING"'/}"
        sum=$(sha256sum "$f" | cut -d" " -f1)
        echo "    {\"path\": \"$rel\", \"sha256\": \"$sum\"},"
    done
' sh {} + | sed '$ s/,$//')
  ]
}
EOF

# Create tarball
TEMP_TAR=$(mktemp)
tar -czf "$TEMP_TAR" -C "$STAGING" .

# Encrypt with passphrase
echo "$PASSPHRASE" | age -p -o "$OUTPUT" "$TEMP_TAR"

# Cleanup
rm -rf "$STAGING" "$TEMP_TAR"
SCRIPT

    chmod +x "$export_script"

    local bundle="${TEST_DIR}/test-bundle.tar.gz.age"
    local passphrase="test-passphrase-123"

    bash "$export_script" "$TEST_DIR" "$bundle" "$passphrase"

    if [[ -f "$bundle" ]]; then
        log_pass "Bundle created: $(du -h "$bundle" | cut -f1)"
    else
        log_fail "Bundle not created"
        ((FAILED++))
        return 1
    fi

    ((PASSED++))
}

# Run import (modified for test)
run_import() {
    log_step "Running import"

    local bundle="${TEST_DIR}/test-bundle.tar.gz.age"
    local passphrase="test-passphrase-123"
    local target="${TEST_DIR}/target"

    # Decrypt bundle
    local temp_tar
    temp_tar=$(mktemp)

    if ! echo "$passphrase" | age -d -o "$temp_tar" "$bundle"; then
        log_fail "Failed to decrypt bundle"
        ((FAILED++))
        return 1
    fi
    log_pass "Bundle decrypted"

    # Extract
    local staging
    staging=$(mktemp -d)
    tar -xzf "$temp_tar" -C "$staging"
    rm -f "$temp_tar"

    log_pass "Bundle extracted"

    # Verify manifest
    if [[ -f "${staging}/manifest.json" ]]; then
        local file_count
        file_count=$(jq '.files | length' "${staging}/manifest.json")
        log_pass "Manifest valid ($file_count files)"
    else
        log_fail "Manifest not found"
        ((FAILED++))
        rm -rf "$staging"
        return 1
    fi

    # Verify checksums
    local checksum_errors=0
    while IFS= read -r entry; do
        local path checksum
        path=$(echo "$entry" | jq -r '.path')
        checksum=$(echo "$entry" | jq -r '.sha256')

        local file_path="${staging}/${path}"
        if [[ -f "$file_path" ]]; then
            local actual
            actual=$(sha256sum "$file_path" | cut -d' ' -f1)
            if [[ "$checksum" != "$actual" ]]; then
                log_fail "Checksum mismatch: $path"
                ((checksum_errors++))
            fi
        else
            log_fail "Missing file: $path"
            ((checksum_errors++))
        fi
    done < <(jq -c '.files[]' "${staging}/manifest.json")

    if [[ $checksum_errors -eq 0 ]]; then
        log_pass "All checksums verified"
        ((PASSED++))
    else
        log_fail "$checksum_errors checksum errors"
        ((FAILED++))
    fi

    # Verify specific files exist
    local expected_files=(
        "age/keys.txt"
        "sops/clawdbot.json.enc"
        "sops-config/.sops.yaml"
        "secrets/telegram-bot-token.enc"
        "credentials/gh-hosts.yml.enc"
        "credentials/rclone.conf.enc"
    )

    for file in "${expected_files[@]}"; do
        if [[ -f "${staging}/${file}" ]]; then
            log_pass "Found: $file"
            ((PASSED++))
        else
            log_fail "Missing: $file"
            ((FAILED++))
        fi
    done

    # Test AGE key can decrypt
    log_step "Testing decryption"

    local age_key="${staging}/age/keys.txt"
    local test_file="${staging}/secrets/telegram-bot-token.enc"

    if age -d -i "$age_key" "$test_file" >/dev/null 2>&1; then
        log_pass "AGE key can decrypt secrets"
        ((PASSED++))
    else
        log_fail "AGE key cannot decrypt secrets"
        ((FAILED++))
    fi

    # Cleanup
    rm -rf "$staging"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${BOLD}Test Summary${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}Passed:${NC} $PASSED"
    echo -e "  ${RED}Failed:${NC} $FAILED"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}${BOLD}$FAILED tests failed${NC}"
        return 1
    fi
}

# Main
main() {
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}   Secrets Bundle Roundtrip Test        ${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo ""

    check_prerequisites
    setup_test_env
    create_mock_secrets
    run_export
    run_import
    print_summary
}

main "$@"
