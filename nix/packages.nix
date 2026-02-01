# Nyx server package configuration via Home Manager
# Manages all user-space packages declaratively with rollback capability
#
# Security packages (fail2ban, ufw, rkhunter, unattended-upgrades) remain on apt
# due to deep systemd/kernel integration requirements.
#
# Usage:
#   Apply: home-manager switch --flake ~/nix-config#fx
#   Update: nix flake update && home-manager switch --flake .#fx
#   Rollback: home-manager generations && home-manager switch --generation N

{ pkgs, ... }:
{
  home.username = "fx";
  home.homeDirectory = "/home/fx";
  home.stateVersion = "24.11";

  # Let Home Manager manage itself
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    # System utilities
    curl
    jq
    netcat
    rsync

    # Development tools
    git
    gh

    # Python package management
    uv

    # Encryption/secrets management
    age
    sops

    # Media and document processing
    ffmpeg
    pandoc
    yt-dlp

    # Calendar and email
    gcalcli
    himalaya

    # Backup tools
    rclone

    # Node.js runtime (for openclaw)
    nodejs_22
  ];

  # Add npm global bin to PATH for openclaw CLI
  home.sessionPath = [
    "$HOME/.local/share/npm-global/bin"
  ];

  # Configure npm to use user-local global directory
  home.file.".npmrc".text = ''
    prefix=~/.local/share/npm-global
  '';

  # Shell integration - ensure Nix is sourced
  home.sessionVariables = {
    # Prevent npm from prompting for sudo
    NPM_CONFIG_PREFIX = "$HOME/.local/share/npm-global";
  };
}
