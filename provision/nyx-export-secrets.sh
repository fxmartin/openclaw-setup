#!/usr/bin/env bash
# nyx-export-secrets.sh - Export secrets bundle from running Nyx server
# Creates a single AGE-encrypted tarball for disaster recovery
#
# Usage: sudo ./nyx-export-secrets.sh --output /path/to/bundle.tar.gz.age
#
# Output: AGE-encrypted tarball containing all secrets needed to rebuild Nyx

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# Default values
OUTPUT_FILE=""
DRY_RUN=0
VERBOSE=0
USER_HOME="/home/fx"
AGE_KEY_FILE="/root/.config/sops/age/keys.txt"

# Display usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export secrets bundle from running Nyx server.

OPTIONS:
    -o, --output FILE    Output file path (required)
    -n, --dry-run        Show what would be exported without creating bundle
    -v, --verbose        Verbose output
    -h, --help           Show this help message

EXAMPLE:
    sudo ./nyx-export-secrets.sh --output ~/nyx-secrets-bundle.tar.gz.age

The output file should be stored in 1Password along with the passphrase.
EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                OUTPUT_FILE="$2"
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

    if [[ -z "$OUTPUT_FILE" ]] && [[ $DRY_RUN -eq 0 ]]; then
        log_error "Output file is required (use --output)"
        usage
        exit 1
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"

    require_root

    require_commands age tar sha256sum jq

    # Check AGE key exists
    require_file "$AGE_KEY_FILE" "AGE private key"

    # Check user home exists
    require_dir "$USER_HOME" "User home directory"

    log_success "All prerequisites met"
}

# Collect files to export
collect_files() {
    local staging_dir="$1"

    log_step "Collecting secrets"

    # Create staging structure
    mkdir -p "${staging_dir}"/{age,sops,secrets,credentials,sops-config}

    # 1. AGE private key (most critical)
    log_substep "AGE private key"
    if [[ -f "$AGE_KEY_FILE" ]]; then
        cp "$AGE_KEY_FILE" "${staging_dir}/age/keys.txt"
        chmod 600 "${staging_dir}/age/keys.txt"
        log_success "  Collected: AGE private key"
    else
        log_fatal "AGE private key not found at $AGE_KEY_FILE"
    fi

    # 2. SOPS-encrypted clawdbot config
    log_substep "Clawdbot config"
    local clawdbot_dir="${USER_HOME}/.clawdbot"
    if [[ -f "${clawdbot_dir}/clawdbot.json.enc" ]]; then
        cp "${clawdbot_dir}/clawdbot.json.enc" "${staging_dir}/sops/"
        log_success "  Collected: clawdbot.json.enc"
    else
        log_warn "  Not found: clawdbot.json.enc"
    fi

    # 3. SOPS configuration
    log_substep "SOPS config"
    if [[ -f "${clawdbot_dir}/.sops.yaml" ]]; then
        cp "${clawdbot_dir}/.sops.yaml" "${staging_dir}/sops-config/"
        log_success "  Collected: .sops.yaml"
    else
        log_warn "  Not found: .sops.yaml"
    fi

    # 4. Encrypted secrets from ~/.secrets/
    log_substep "Encrypted secrets"
    local secrets_dir="${USER_HOME}/.secrets"
    if [[ -d "$secrets_dir" ]]; then
        local count=0
        for enc_file in "${secrets_dir}"/*.enc; do
            if [[ -f "$enc_file" ]]; then
                cp "$enc_file" "${staging_dir}/secrets/"
                log_debug "  Collected: $(basename "$enc_file")"
                ((count++)) || true
            fi
        done
        log_success "  Collected: $count encrypted secret files"
    else
        log_warn "  Secrets directory not found: $secrets_dir"
    fi

    # 5. GitHub CLI credentials
    log_substep "GitHub CLI config"
    local gh_hosts="${USER_HOME}/.config/gh/hosts.yml"
    if [[ -f "$gh_hosts" ]]; then
        # Check if already encrypted
        if [[ "$gh_hosts" == *.enc ]]; then
            cp "$gh_hosts" "${staging_dir}/credentials/"
        else
            # Encrypt with AGE
            log_substep "  Encrypting gh hosts.yml"
            local pub_key
            pub_key=$(grep "public key:" "$AGE_KEY_FILE" | cut -d: -f2 | tr -d ' ')
            age -r "$pub_key" -o "${staging_dir}/credentials/gh-hosts.yml.enc" "$gh_hosts"
        fi
        log_success "  Collected: GitHub CLI config"
    else
        log_warn "  Not found: GitHub CLI config"
    fi

    # 6. rclone config (Dropbox)
    log_substep "rclone config"
    local rclone_conf="${USER_HOME}/.config/rclone/rclone.conf"
    if [[ -f "$rclone_conf" ]]; then
        # Check if already encrypted
        if [[ "$rclone_conf" == *.enc ]]; then
            cp "$rclone_conf" "${staging_dir}/credentials/"
        else
            # Encrypt with AGE
            log_substep "  Encrypting rclone.conf"
            local pub_key
            pub_key=$(grep "public key:" "$AGE_KEY_FILE" | cut -d: -f2 | tr -d ' ')
            age -r "$pub_key" -o "${staging_dir}/credentials/rclone.conf.enc" "$rclone_conf"
        fi
        log_success "  Collected: rclone config"
    else
        log_warn "  Not found: rclone config"
    fi

    # 7. rsync NAS password
    log_substep "rsync NAS password"
    local rsync_password="${USER_HOME}/.rsync-nas-password"
    if [[ -f "$rsync_password" ]]; then
        # Encrypt with AGE
        log_substep "  Encrypting rsync-nas-password"
        local pub_key
        pub_key=$(grep "public key:" "$AGE_KEY_FILE" | cut -d: -f2 | tr -d ' ')
        age -r "$pub_key" -o "${staging_dir}/credentials/rsync-nas-password.enc" "$rsync_password"
        log_success "  Collected: rsync NAS password"
    else
        log_warn "  Not found: rsync NAS password"
    fi

    # 8. Additional email configs if present
    log_substep "Email configs"
    local email_count=0
    shopt -s nullglob
    for email_conf in "${USER_HOME}/.config/himalaya"/*.enc "${clawdbot_dir}/credentials"/*.enc; do
        if [[ -f "$email_conf" ]]; then
            cp "$email_conf" "${staging_dir}/secrets/"
            log_debug "  Collected: $(basename "$email_conf")"
            ((email_count++)) || true
        fi
    done
    shopt -u nullglob
    if [[ $email_count -gt 0 ]]; then
        log_success "  Collected: $email_count email config files"
    fi
}

# Generate manifest
generate_manifest() {
    local staging_dir="$1"

    log_step "Generating manifest"

    local manifest="${staging_dir}/manifest.json"

    # Generate checksums for all files
    local checksums=()
    while IFS= read -r -d '' file; do
        local rel_path="${file#${staging_dir}/}"
        local checksum
        checksum=$(sha256sum "$file" | cut -d' ' -f1)
        checksums+=("{\"path\": \"$rel_path\", \"sha256\": \"$checksum\"}")
    done < <(find "${staging_dir}" -type f ! -name "manifest.json" -print0)

    # Join checksums array
    local checksums_json
    checksums_json=$(printf '%s\n' "${checksums[@]}" | paste -sd',' -)

    # Create manifest
    cat > "$manifest" <<EOF
{
  "version": "1.0",
  "created_at": "$(date -Iseconds)",
  "created_by": "$(whoami)@$(hostname)",
  "source_server": "$(hostname)",
  "files": [
    ${checksums_json}
  ]
}
EOF

    log_success "Manifest created with $(echo "${checksums[@]}" | wc -w) files"
}

# Create encrypted bundle
create_bundle() {
    local staging_dir="$1"
    local output_file="$2"

    log_step "Creating encrypted bundle"

    # Create unencrypted tarball first
    local temp_tar
    temp_tar=$(mktemp)

    log_substep "Creating tarball"
    tar -czf "$temp_tar" -C "$staging_dir" .

    local size_mb
    size_mb=$(du -h "$temp_tar" | cut -f1)
    log_info "Tarball size: $size_mb"

    # Prompt for passphrase
    log_substep "Encrypting with passphrase"
    echo ""
    echo -e "${YELLOW}Enter a passphrase to encrypt the bundle.${NC}"
    echo -e "${YELLOW}Store this passphrase in 1Password along with the bundle file.${NC}"
    echo ""

    # Use age with passphrase
    if ! age -p -o "$output_file" "$temp_tar"; then
        rm -f "$temp_tar"
        log_fatal "Failed to encrypt bundle"
    fi

    # Cleanup
    rm -f "$temp_tar"

    local final_size
    final_size=$(du -h "$output_file" | cut -f1)
    log_success "Bundle created: $output_file ($final_size)"
}

# Display dry-run summary
show_dry_run() {
    local staging_dir="$1"

    log_step "Dry-run summary"

    echo ""
    echo "Files that would be included in bundle:"
    echo ""

    find "$staging_dir" -type f | while read -r file; do
        local rel_path="${file#${staging_dir}/}"
        local size
        size=$(du -h "$file" | cut -f1)
        echo "  $rel_path ($size)"
    done

    echo ""
    local total_size
    total_size=$(du -sh "$staging_dir" | cut -f1)
    echo "Total uncompressed size: $total_size"
    echo ""
}

# Cleanup staging directory
cleanup() {
    local staging_dir="$1"

    if [[ -d "$staging_dir" ]]; then
        log_debug "Cleaning up staging directory"
        rm -rf "$staging_dir"
    fi
}

# Main function
main() {
    parse_args "$@"

    banner "Nyx Secrets Export"

    check_prerequisites

    # Create secure staging directory
    local staging_dir
    staging_dir=$(mktemp -d)
    chmod 700 "$staging_dir"

    # Ensure cleanup on exit
    trap "cleanup '$staging_dir'" EXIT

    # Collect all files
    collect_files "$staging_dir"

    # Generate manifest
    generate_manifest "$staging_dir"

    if [[ $DRY_RUN -eq 1 ]]; then
        show_dry_run "$staging_dir"
        log_success "Dry-run complete"
        exit 0
    fi

    # Create encrypted bundle
    create_bundle "$staging_dir" "$OUTPUT_FILE"

    separator
    echo ""
    log_success "Export complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Upload to 1Password: $OUTPUT_FILE"
    echo "  2. Store the passphrase in the same 1Password item"
    echo "  3. Test: ./nyx-import-secrets.sh --bundle $OUTPUT_FILE --dry-run"
    echo ""
}

main "$@"
