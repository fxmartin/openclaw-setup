#!/usr/bin/env bash
# nyx-import-secrets.sh - Import secrets bundle to new server
# Extracts and installs secrets from AGE-encrypted tarball
#
# Usage: sudo ./nyx-import-secrets.sh --bundle /path/to/bundle.tar.gz.age
#
# Prerequisites: age, tar, jq must be installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# Default values
BUNDLE_FILE=""
DRY_RUN=0
VERBOSE=0
TARGET_USER="fx"
TARGET_HOME="/home/fx"
AGE_KEY_DIR="/root/.config/sops/age"

# Display usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Import secrets bundle to new Nyx server.

OPTIONS:
    -b, --bundle FILE    Bundle file path (required)
    -u, --user USER      Target user (default: fx)
    -n, --dry-run        Verify bundle without installing
    -v, --verbose        Verbose output
    -h, --help           Show this help message

EXAMPLE:
    sudo ./nyx-import-secrets.sh --bundle /tmp/nyx-secrets-bundle.tar.gz.age
    sudo ./nyx-import-secrets.sh --bundle /tmp/bundle.tar.gz.age --dry-run

The script will prompt for the passphrase to decrypt the bundle.
EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -b|--bundle)
                BUNDLE_FILE="$2"
                shift 2
                ;;
            -u|--user)
                TARGET_USER="$2"
                TARGET_HOME="/home/$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                DEBUG=1
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

    if [[ -z "$BUNDLE_FILE" ]]; then
        log_error "Bundle file is required (use --bundle)"
        usage
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"

    require_root

    require_commands age tar jq sha256sum

    require_file "$BUNDLE_FILE" "Bundle file"

    # Check target user exists (skip for dry-run)
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! id "$TARGET_USER" &>/dev/null; then
            log_fatal "Target user does not exist: $TARGET_USER"
        fi
    fi

    log_success "All prerequisites met"
}

# Decrypt and extract bundle
extract_bundle() {
    local bundle="$1"
    local staging_dir="$2"

    log_step "Decrypting bundle"

    echo ""
    echo -e "${YELLOW}Enter the passphrase for the bundle:${NC}"
    echo ""

    # Decrypt bundle
    local temp_tar
    temp_tar=$(mktemp)

    if ! age -d -o "$temp_tar" "$bundle"; then
        rm -f "$temp_tar"
        log_fatal "Failed to decrypt bundle (wrong passphrase?)"
    fi

    log_success "Bundle decrypted"

    # Extract tarball
    log_step "Extracting files"
    tar -xzf "$temp_tar" -C "$staging_dir"
    rm -f "$temp_tar"

    log_success "Bundle extracted"
}

# Verify manifest checksums
verify_manifest() {
    local staging_dir="$1"

    log_step "Verifying checksums"

    local manifest="${staging_dir}/manifest.json"

    if [[ ! -f "$manifest" ]]; then
        log_fatal "Manifest not found in bundle"
    fi

    # Read manifest metadata
    local created_at source_server
    created_at=$(jq -r '.created_at' "$manifest")
    source_server=$(jq -r '.source_server' "$manifest")

    log_info "Bundle created: $created_at"
    log_info "Source server: $source_server"

    # Verify each file
    local failed=0
    local verified=0

    while IFS= read -r entry; do
        local path checksum
        path=$(echo "$entry" | jq -r '.path')
        checksum=$(echo "$entry" | jq -r '.sha256')

        local file_path="${staging_dir}/${path}"

        if [[ ! -f "$file_path" ]]; then
            log_error "Missing file: $path"
            ((failed++))
            continue
        fi

        local actual_checksum
        actual_checksum=$(sha256sum "$file_path" | cut -d' ' -f1)

        if [[ "$checksum" != "$actual_checksum" ]]; then
            log_error "Checksum mismatch: $path"
            ((failed++))
        else
            log_debug "Verified: $path"
            ((verified++))
        fi
    done < <(jq -c '.files[]' "$manifest")

    if [[ $failed -gt 0 ]]; then
        log_fatal "Verification failed: $failed files have issues"
    fi

    log_success "All $verified files verified"
}

# Show bundle contents
show_contents() {
    local staging_dir="$1"

    log_step "Bundle contents"

    echo ""
    find "$staging_dir" -type f | while read -r file; do
        local rel_path="${file#${staging_dir}/}"
        local size
        size=$(du -h "$file" | cut -f1)
        echo "  $rel_path ($size)"
    done
    echo ""
}

# Install secrets
install_secrets() {
    local staging_dir="$1"

    log_step "Installing secrets"

    local target_uid target_gid
    target_uid=$(id -u "$TARGET_USER")
    target_gid=$(id -g "$TARGET_USER")

    # 1. Install AGE private key (root only)
    log_substep "AGE private key"
    if [[ -f "${staging_dir}/age/keys.txt" ]]; then
        mkdir -p "$AGE_KEY_DIR"
        cp "${staging_dir}/age/keys.txt" "${AGE_KEY_DIR}/keys.txt"
        chmod 600 "${AGE_KEY_DIR}/keys.txt"
        chown root:root "${AGE_KEY_DIR}/keys.txt"
        log_success "  Installed: AGE private key -> $AGE_KEY_DIR/keys.txt"
    else
        log_fatal "AGE private key not found in bundle"
    fi

    # 2. Install SOPS-encrypted clawdbot config
    log_substep "Clawdbot config"
    local clawdbot_dir="${TARGET_HOME}/.clawdbot"
    mkdir -p "$clawdbot_dir"
    chown "${target_uid}:${target_gid}" "$clawdbot_dir"

    if [[ -f "${staging_dir}/sops/clawdbot.json.enc" ]]; then
        cp "${staging_dir}/sops/clawdbot.json.enc" "${clawdbot_dir}/"
        chown "${target_uid}:${target_gid}" "${clawdbot_dir}/clawdbot.json.enc"
        chmod 644 "${clawdbot_dir}/clawdbot.json.enc"
        log_success "  Installed: clawdbot.json.enc"
    else
        log_warn "  Not found in bundle: clawdbot.json.enc"
    fi

    # 3. Install SOPS config
    log_substep "SOPS config"
    if [[ -f "${staging_dir}/sops-config/.sops.yaml" ]]; then
        cp "${staging_dir}/sops-config/.sops.yaml" "${clawdbot_dir}/"
        chown "${target_uid}:${target_gid}" "${clawdbot_dir}/.sops.yaml"
        chmod 644 "${clawdbot_dir}/.sops.yaml"
        log_success "  Installed: .sops.yaml"
    fi

    # 4. Install encrypted secrets
    log_substep "Encrypted secrets"
    local secrets_dir="${TARGET_HOME}/.secrets"
    mkdir -p "$secrets_dir"
    chown "${target_uid}:${target_gid}" "$secrets_dir"

    local secret_count=0
    for enc_file in "${staging_dir}/secrets/"*.enc 2>/dev/null; do
        if [[ -f "$enc_file" ]]; then
            local filename
            filename=$(basename "$enc_file")
            cp "$enc_file" "${secrets_dir}/"
            chown "${target_uid}:${target_gid}" "${secrets_dir}/${filename}"
            chmod 644 "${secrets_dir}/${filename}"
            log_debug "  Installed: $filename"
            ((secret_count++))
        fi
    done
    log_success "  Installed: $secret_count secret files"

    # 5. Install GitHub CLI credentials
    log_substep "GitHub CLI config"
    local gh_dir="${TARGET_HOME}/.config/gh"
    mkdir -p "$gh_dir"
    chown "${target_uid}:${target_gid}" "$gh_dir"

    if [[ -f "${staging_dir}/credentials/gh-hosts.yml.enc" ]]; then
        # Decrypt with AGE and install
        local pub_key
        if age -d -i "${AGE_KEY_DIR}/keys.txt" \
            -o "${gh_dir}/hosts.yml" \
            "${staging_dir}/credentials/gh-hosts.yml.enc" 2>/dev/null; then
            chown "${target_uid}:${target_gid}" "${gh_dir}/hosts.yml"
            chmod 600 "${gh_dir}/hosts.yml"
            log_success "  Installed: GitHub CLI config (decrypted)"
        else
            # Keep encrypted if decryption fails
            cp "${staging_dir}/credentials/gh-hosts.yml.enc" "${gh_dir}/"
            chown "${target_uid}:${target_gid}" "${gh_dir}/gh-hosts.yml.enc"
            log_warn "  Installed encrypted: gh-hosts.yml.enc (decrypt manually)"
        fi
    fi

    # 6. Install rclone config
    log_substep "rclone config"
    local rclone_dir="${TARGET_HOME}/.config/rclone"
    mkdir -p "$rclone_dir"
    chown "${target_uid}:${target_gid}" "$rclone_dir"

    if [[ -f "${staging_dir}/credentials/rclone.conf.enc" ]]; then
        # Decrypt with AGE and install
        if age -d -i "${AGE_KEY_DIR}/keys.txt" \
            -o "${rclone_dir}/rclone.conf" \
            "${staging_dir}/credentials/rclone.conf.enc" 2>/dev/null; then
            chown "${target_uid}:${target_gid}" "${rclone_dir}/rclone.conf"
            chmod 600 "${rclone_dir}/rclone.conf"
            log_success "  Installed: rclone config (decrypted)"
        else
            # Keep encrypted if decryption fails
            cp "${staging_dir}/credentials/rclone.conf.enc" "${rclone_dir}/"
            chown "${target_uid}:${target_gid}" "${rclone_dir}/rclone.conf.enc"
            log_warn "  Installed encrypted: rclone.conf.enc (decrypt manually)"
        fi
    fi

    log_success "Secrets installation complete"
}

# Cleanup staging directory
cleanup() {
    local staging_dir="$1"

    if [[ -d "$staging_dir" ]]; then
        log_debug "Cleaning up staging directory"
        # Secure delete - overwrite before remove
        find "$staging_dir" -type f -exec shred -u {} \; 2>/dev/null || rm -rf "$staging_dir"
    fi
}

# Main function
main() {
    parse_args "$@"

    banner "Nyx Secrets Import"

    check_prerequisites

    # Create secure staging directory
    local staging_dir
    staging_dir=$(mktemp -d)
    chmod 700 "$staging_dir"

    # Ensure cleanup on exit
    trap "cleanup '$staging_dir'" EXIT

    # Extract bundle
    extract_bundle "$BUNDLE_FILE" "$staging_dir"

    # Verify checksums
    verify_manifest "$staging_dir"

    # Show contents
    show_contents "$staging_dir"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_success "Dry-run complete - bundle verified successfully"
        echo ""
        echo "Run without --dry-run to install secrets"
        exit 0
    fi

    # Confirm installation
    echo ""
    if ! confirm "Install secrets to $TARGET_HOME?"; then
        log_info "Installation cancelled"
        exit 0
    fi

    # Install secrets
    install_secrets "$staging_dir"

    separator
    echo ""
    log_success "Import complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Run verification: ./nyx-verify.sh"
    echo "  2. Start clawdbot service"
    echo ""
}

main "$@"
