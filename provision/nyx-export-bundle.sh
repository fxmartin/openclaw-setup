#!/usr/bin/env bash
# nyx-export-bundle.sh - Export secrets bundle from Nyx server (run from local machine)
#
# This script SSHs to Nyx, collects all secrets, and creates an encrypted bundle locally.
#
# Usage:
#   ./provision/nyx-export-bundle.sh
#   ./provision/nyx-export-bundle.sh --output ~/nyx-backup.tar.gz.age
#   ./provision/nyx-export-bundle.sh --passphrase "my-secret-passphrase"
#   ./provision/nyx-export-bundle.sh --dry-run
#
# Requirements:
#   - SSH access to Nyx (via Tailscale or direct)
#   - age and expect (will use nix-shell if not installed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging
log_step() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }

# Default values
NYX_HOST="fx@100.64.138.99"
SSH_KEY="$HOME/.ssh/id_nyx"
OUTPUT_FILE="${REPO_DIR}/nyx-secrets-bundle.tar.gz.age"
PASSPHRASE=""
DRY_RUN=0
GENERATE_PASSPHRASE=1
TARGET_USER="fx"
TARGET_HOME="/home/fx"

# SSH options (built in check_prerequisites)
SSH_OPTS=""

# Temp files to clean up
TEMP_FILES=()

cleanup() {
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # Clean up on remote
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$NYX_HOST" "sudo rm -f /tmp/nyx-secrets-export-*.tar.gz" 2>/dev/null || true
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export secrets bundle from Nyx server.

OPTIONS:
    -H, --host HOST         SSH host (default: fx@100.64.138.99)
    -i, --identity FILE     SSH identity file (default: ~/.ssh/id_nyx)
    -o, --output FILE       Output file (default: ./nyx-secrets-bundle.tar.gz.age)
    -p, --passphrase PASS   Use specific passphrase (default: generate random)
    -n, --dry-run           Show what would be exported without creating bundle
    -h, --help              Show this help

EXAMPLES:
    # Export with auto-generated passphrase
    ./provision/nyx-export-bundle.sh

    # Export to specific file
    ./provision/nyx-export-bundle.sh --output ~/backup/nyx-secrets.tar.gz.age

    # Use specific passphrase
    ./provision/nyx-export-bundle.sh --passphrase "my-secure-passphrase"

    # Dry run to see what would be exported
    ./provision/nyx-export-bundle.sh --dry-run

OUTPUT:
    Creates an AGE-encrypted tarball containing:
    - AGE private key (master encryption key)
    - SOPS-encrypted openclaw config
    - All encrypted secrets from ~/.secrets/
    - GitHub CLI and rclone configs (freshly encrypted)
    - Manifest with SHA256 checksums

STORAGE:
    Store the bundle and passphrase in 1Password for disaster recovery.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)
                NYX_HOST="$2"
                shift 2
                ;;
            -i|--identity)
                SSH_KEY="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -p|--passphrase)
                PASSPHRASE="$2"
                GENERATE_PASSPHRASE=0
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

check_prerequisites() {
    log_step "Checking prerequisites"

    # Build SSH options
    SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if [[ -f "$SSH_KEY" ]]; then
        SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
        log_info "Using SSH key: $SSH_KEY"
    fi

    # Check SSH connectivity
    # shellcheck disable=SC2086
    if ! ssh $SSH_OPTS "$NYX_HOST" "echo ok" &>/dev/null; then
        log_error "Cannot connect to $NYX_HOST via SSH"
        log_error "Make sure Tailscale is connected or SSH is configured"
        exit 1
    fi
    log_success "SSH connection to $NYX_HOST"

    # Check if age is available (locally or via nix)
    if command -v age &>/dev/null; then
        AGE_CMD="age"
        EXPECT_CMD="expect"
        log_success "age installed locally"
    elif command -v nix-shell &>/dev/null; then
        AGE_CMD="nix-shell -p age expect --run"
        log_success "age available via nix-shell"
    else
        log_error "age not found. Install age or nix."
        exit 1
    fi

    # Check remote prerequisites
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$NYX_HOST" "sudo test -f /root/.config/sops/age/keys.txt" || {
        log_error "AGE key not found on $NYX_HOST"
        exit 1
    }
    log_success "AGE key exists on $NYX_HOST"
}

generate_passphrase() {
    if [[ $GENERATE_PASSPHRASE -eq 1 ]]; then
        PASSPHRASE=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        log_info "Generated passphrase: ${BOLD}${PASSPHRASE}${NC}"
    fi
}

collect_secrets_on_remote() {
    # Use a fixed name with timestamp to avoid $$ expansion issues
    local timestamp
    timestamp=$(date +%s)
    local remote_tarball="/tmp/nyx-secrets-export-${timestamp}.tar.gz"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$NYX_HOST" "sudo bash -s '$remote_tarball' '$TARGET_HOME'" << 'REMOTE_SCRIPT'
set -euo pipefail

OUTPUT_FILE="$1"
USER_HOME="$2"
AGE_KEY_FILE="/root/.config/sops/age/keys.txt"

# Create staging directory
STAGING=$(mktemp -d)
chmod 700 "$STAGING"
mkdir -p "${STAGING}"/{age,sops,secrets,credentials,sops-config}

echo "Collecting secrets..." >&2

# 1. AGE private key
cp "$AGE_KEY_FILE" "${STAGING}/age/keys.txt"
chmod 600 "${STAGING}/age/keys.txt"
echo "  [+] AGE private key" >&2

# Get public key for encryption
pub_key=$(grep "public key:" "$AGE_KEY_FILE" | cut -d: -f2 | tr -d ' ')

# 2. Openclaw config
if [[ -f "${USER_HOME}/.openclaw/openclaw.json.enc" ]]; then
    cp "${USER_HOME}/.openclaw/openclaw.json.enc" "${STAGING}/sops/"
    echo "  [+] openclaw.json.enc" >&2
fi

# 3. SOPS config
if [[ -f "${USER_HOME}/.openclaw/.sops.yaml" ]]; then
    cp "${USER_HOME}/.openclaw/.sops.yaml" "${STAGING}/sops-config/"
    echo "  [+] .sops.yaml" >&2
fi

# 4. Encrypted secrets
shopt -s nullglob
secret_count=0
for enc_file in "${USER_HOME}/.secrets"/*.enc; do
    cp "$enc_file" "${STAGING}/secrets/"
    echo "  [+] $(basename "$enc_file")" >&2
    ((secret_count++)) || true
done
shopt -u nullglob
echo "  Total: $secret_count secret files" >&2

# 5. GitHub CLI (encrypt if plaintext)
if [[ -f "${USER_HOME}/.config/gh/hosts.yml" ]]; then
    age -r "$pub_key" -o "${STAGING}/credentials/gh-hosts.yml.enc" "${USER_HOME}/.config/gh/hosts.yml"
    echo "  [+] gh-hosts.yml.enc (encrypted)" >&2
fi

# 6. rclone config (encrypt if plaintext)
if [[ -f "${USER_HOME}/.config/rclone/rclone.conf" ]]; then
    age -r "$pub_key" -o "${STAGING}/credentials/rclone.conf.enc" "${USER_HOME}/.config/rclone/rclone.conf"
    echo "  [+] rclone.conf.enc (encrypted)" >&2
fi

# 7. NAS rsync password (encrypt if exists)
if [[ -f "${USER_HOME}/.rsync-nas-password" ]]; then
    age -r "$pub_key" -o "${STAGING}/credentials/rsync-nas-password.enc" "${USER_HOME}/.rsync-nas-password"
    echo "  [+] rsync-nas-password.enc (encrypted)" >&2
fi

# 8. Additional credentials from openclaw
shopt -s nullglob
for cred_file in "${USER_HOME}/.openclaw/credentials"/*.enc; do
    if [[ -f "$cred_file" ]]; then
        cp "$cred_file" "${STAGING}/secrets/"
        echo "  [+] $(basename "$cred_file")" >&2
    fi
done
shopt -u nullglob

echo "" >&2
echo "Generating manifest..." >&2

# Generate checksums and manifest
cat > "${STAGING}/manifest.json" << EOF
{
  "version": "1.0",
  "created_at": "$(date -Iseconds)",
  "created_by": "$(whoami)@$(hostname)",
  "source_server": "$(hostname)",
  "files": [
$(find "${STAGING}" -type f ! -name "manifest.json" | sort | while read f; do
    rel="${f#${STAGING}/}"
    sum=$(sha256sum "$f" | cut -d" " -f1)
    echo "    {\"path\": \"$rel\", \"sha256\": \"$sum\"},"
done | sed '$ s/,$//')
  ]
}
EOF

echo "Creating tarball..." >&2

# Create tarball
tar -czf "$OUTPUT_FILE" -C "$STAGING" .

# Cleanup staging
rm -rf "$STAGING"

# Make readable for scp
chmod 644 "$OUTPUT_FILE"

echo "" >&2
ls -lh "$OUTPUT_FILE" >&2

# Output ONLY the path to stdout
echo "$OUTPUT_FILE"
REMOTE_SCRIPT
}

copy_and_encrypt() {
    local remote_tarball="$1"
    local local_tarball
    local_tarball=$(mktemp)
    TEMP_FILES+=("$local_tarball")

    log_step "Copying tarball from $NYX_HOST"

    # Build scp options from SSH_OPTS
    local scp_opts=""
    if [[ -f "$SSH_KEY" ]]; then
        scp_opts="-i $SSH_KEY"
    fi

    # shellcheck disable=SC2086
    scp $scp_opts "$NYX_HOST:$remote_tarball" "$local_tarball"
    log_success "Copied $(du -h "$local_tarball" | cut -f1) tarball"

    # Clean up remote immediately
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$NYX_HOST" "sudo rm -f $remote_tarball"

    log_step "Encrypting bundle with AGE"

    # Encrypt using expect to handle passphrase prompt
    if command -v age &>/dev/null && command -v expect &>/dev/null; then
        expect -c "
            set timeout 30
            spawn age -p -o \"$OUTPUT_FILE\" \"$local_tarball\"
            expect \"Enter passphrase\"
            send \"$PASSPHRASE\r\"
            expect \"Confirm passphrase\"
            send \"$PASSPHRASE\r\"
            expect eof
        " > /dev/null
    else
        # Use nix-shell
        nix-shell -p expect age --run "
            expect -c '
                set timeout 30
                spawn age -p -o \"$OUTPUT_FILE\" \"$local_tarball\"
                expect \"Enter passphrase\"
                send \"$PASSPHRASE\r\"
                expect \"Confirm passphrase\"
                send \"$PASSPHRASE\r\"
                expect eof
            '
        " > /dev/null
    fi

    if [[ -f "$OUTPUT_FILE" ]]; then
        log_success "Bundle encrypted: $OUTPUT_FILE"
    else
        log_error "Failed to create encrypted bundle"
        exit 1
    fi
}

verify_bundle() {
    log_step "Verifying bundle"

    local test_tar
    test_tar=$(mktemp)
    TEMP_FILES+=("$test_tar")

    # Decrypt and verify
    if command -v age &>/dev/null && command -v expect &>/dev/null; then
        expect -c "
            set timeout 30
            spawn age -d -o \"$test_tar\" \"$OUTPUT_FILE\"
            expect \"Enter passphrase\"
            send \"$PASSPHRASE\r\"
            expect eof
        " > /dev/null
    else
        nix-shell -p expect age --run "
            expect -c '
                set timeout 30
                spawn age -d -o \"$test_tar\" \"$OUTPUT_FILE\"
                expect \"Enter passphrase\"
                send \"$PASSPHRASE\r\"
                expect eof
            '
        " > /dev/null
    fi

    # Count files
    local file_count
    file_count=$(tar -tzf "$test_tar" | wc -l)

    # Check for key files
    local has_age_key has_openclaw has_manifest
    has_age_key=$(tar -tzf "$test_tar" | grep -c "age/keys.txt" || true)
    has_openclaw=$(tar -tzf "$test_tar" | grep -c "openclaw.json.enc" || true)
    has_manifest=$(tar -tzf "$test_tar" | grep -c "manifest.json" || true)

    if [[ $has_age_key -gt 0 ]] && [[ $has_openclaw -gt 0 ]] && [[ $has_manifest -gt 0 ]]; then
        log_success "Bundle verified: $file_count files"
        log_success "  - AGE key: present"
        log_success "  - Openclaw config: present"
        log_success "  - Manifest: present"
    else
        log_error "Bundle verification failed"
        exit 1
    fi
}

dry_run() {
    log_step "Dry run - showing what would be exported"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$NYX_HOST" "sudo bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail

USER_HOME="/home/fx"
AGE_KEY_FILE="/root/.config/sops/age/keys.txt"

echo ""
echo "Files that would be included:"
echo ""

# AGE key
if [[ -f "$AGE_KEY_FILE" ]]; then
    echo "  age/keys.txt (AGE private key)"
fi

# Openclaw config
if [[ -f "${USER_HOME}/.openclaw/openclaw.json.enc" ]]; then
    echo "  sops/openclaw.json.enc"
fi

# SOPS config
if [[ -f "${USER_HOME}/.openclaw/.sops.yaml" ]]; then
    echo "  sops-config/.sops.yaml"
fi

# Encrypted secrets
shopt -s nullglob
for enc_file in "${USER_HOME}/.secrets"/*.enc; do
    echo "  secrets/$(basename "$enc_file")"
done
shopt -u nullglob

# GitHub CLI
if [[ -f "${USER_HOME}/.config/gh/hosts.yml" ]]; then
    echo "  credentials/gh-hosts.yml.enc (will be encrypted)"
fi

# rclone config
if [[ -f "${USER_HOME}/.config/rclone/rclone.conf" ]]; then
    echo "  credentials/rclone.conf.enc (will be encrypted)"
fi

# NAS rsync password
if [[ -f "${USER_HOME}/.rsync-nas-password" ]]; then
    echo "  credentials/rsync-nas-password.enc (will be encrypted)"
fi

# Additional credentials
shopt -s nullglob
for cred_file in "${USER_HOME}/.openclaw/credentials"/*.enc; do
    echo "  secrets/$(basename "$cred_file")"
done
shopt -u nullglob

echo ""
echo "  manifest.json (checksums + metadata)"
echo ""
REMOTE_SCRIPT

    log_success "Dry run complete"
}

print_summary() {
    local size
    size=$(du -h "$OUTPUT_FILE" | cut -f1)

    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}                    Export Complete                          ${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Bundle:${NC}     $OUTPUT_FILE"
    echo -e "${BOLD}Size:${NC}       $size"
    echo -e "${BOLD}Encryption:${NC} AGE passphrase (AES256)"
    echo ""
    echo -e "${BOLD}${YELLOW}Passphrase:${NC} ${BOLD}$PASSPHRASE${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Store both the bundle and passphrase in 1Password!${NC}"
    echo ""
    echo "To test decryption:"
    echo "  age -d -o /tmp/test.tar.gz $OUTPUT_FILE"
    echo "  tar -tzf /tmp/test.tar.gz"
    echo ""
    echo "For disaster recovery:"
    echo "  ./provision/nyx-provision.sh --secrets-bundle $OUTPUT_FILE"
    echo ""
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}              Nyx Secrets Bundle Export                      ${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""

    check_prerequisites

    if [[ $DRY_RUN -eq 1 ]]; then
        dry_run
        exit 0
    fi

    generate_passphrase

    log_step "Collecting secrets on $NYX_HOST"

    # Collect secrets - function outputs path on last line, rest goes to stderr
    local remote_tarball
    remote_tarball=$(collect_secrets_on_remote)

    if [[ -z "$remote_tarball" ]] || [[ "$remote_tarball" != /tmp/* ]]; then
        log_error "Failed to get remote tarball path"
        log_error "Got: $remote_tarball"
        exit 1
    fi

    copy_and_encrypt "$remote_tarball"

    verify_bundle

    print_summary
}

main "$@"
