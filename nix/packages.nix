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
let
  # Himalaya 1.1.0 - pinned version (nixpkgs has outdated beta.4)
  # Config format changed significantly between versions
  himalaya-bin = pkgs.stdenv.mkDerivation rec {
    pname = "himalaya";
    version = "1.1.0";
    
    src = pkgs.fetchurl {
      url = "https://github.com/pimalaya/himalaya/releases/download/v${version}/himalaya.x86_64-linux.tgz";
      sha256 = "0qs0qncmx741w4c26kc13782sdb4lhz998dygs2027515mnpj64v";
    };
    
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    
    sourceRoot = ".";
    
    installPhase = ''
      mkdir -p $out/bin
      cp himalaya $out/bin/
      chmod +x $out/bin/himalaya
    '';
    
    meta = with pkgs.lib; {
      description = "CLI to manage emails";
      homepage = "https://github.com/pimalaya/himalaya";
      license = licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
  };
in
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
    himalaya-bin  # Pinned to 1.1.0 (see let block above)

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
