#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# MHSeals RoboBoat simulator installer for Linux (any distribution).
#
#   curl -fsSL https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.sh | bash -s -- --dir ~/sim
#   bash install/install.sh --help
#
# Components (run in this order): base, vulkan, unity-hub, unity-editor, repo.
# Idempotent: tools already present are skipped, and an existing checkout is fast-forwarded.
# Nothing is sent anywhere except the downloads listed below; no telemetry.
#
# Sources for the URLs used here (checked 2026-11-19):
#   Unity Hub apt/rpm repos, signing key, Flatpak/AppImage: https://docs.unity.com/en-us/hub/install-hub-linux
#   Hub CLI (Hub 3 only; deprecated from 3.18, removed in Hub 4): https://docs.unity.com/en-us/hub/hub-cli
#   Unity CLI (`unity`, replaces the Hub CLI): https://docs.unity.com/en-us/unity-cli/use-unity-cli
#   Editor archive and md5: https://services.api.unity.com/unity/editor/release/v1/releases?version=6000.5.10f1
#   git-lfs static build: https://github.com/git-lfs/git-lfs/releases/latest
#   Flathub (community-maintained Hub): https://flathub.org/apps/com.unity.UnityHub
# Layout and helpers adapted from astro_dock's setup.linux.sh.

set -euo pipefail

# ---------------------------------------------------------------------------- constants
UNITY_VERSION="6000.5.10f1"
UNITY_CHANGESET="3bd4f66ad299"
UNITY_EDITOR_URL="https://download.unity3d.com/download_unity/${UNITY_CHANGESET}/LinuxEditorInstaller/Unity-${UNITY_VERSION}.tar.xz"
UNITY_EDITOR_MD5="5dc27aee857d6df98cbe17fd64ee445a"   # md5-XcJ67oV9bfmMvhf9ZO5EWg== from the releases API
UNITY_EDITOR_DOWNLOAD_GB=5                              # 4.35 GB archive
UNITY_EDITOR_INSTALLED_GB=13
UNITY_KEY_URL="https://hub.unity3d.com/linux/keys/public"
UNITY_DEB_URI="https://hub.unity3d.com/linux/repos/deb"
UNITY_RPM_BASEURL="https://hub.unity3d.com/linux/repos/rpm/stable"
UNITY_RPM_KEY="https://hub.unity3d.com/linux/repos/rpm/stable/repodata/repomd.xml.key"
UNITY_CLI_SCRIPT_URL="https://unity.com/install.sh"
FLATHUB_REPO="https://dl.flathub.org/repo/flathub.flatpakrepo"
FLATPAK_HUB_ID="com.unity.UnityHub"
GIT_LFS_RELEASE_API="https://api.github.com/repos/git-lfs/git-lfs/releases/latest"
ALL_COMPONENTS="base,vulkan,unity-hub,unity-editor,repo"
# The Unity CLI sends an anonymous usage count and crash reports by default; switch them (and its update
# check) off for the commands this script runs. https://docs.unity.com/en-us/unity-cli/data-collection-privacy-controls/turn-off-data-collection
export UNITY_NO_CLI_INVOKED_TELEMETRY=1 UNITY_NO_CRASH_REPORT=1 UNITY_NO_UPDATE_CHECK=1

# ---------------------------------------------------------------------------- settings (flags > env > defaults)
DIR="${MHSEALS_DIR:-$HOME/mhseals_sim}"
BRANCH="${MHSEALS_BRANCH:-main}"
REPO="${MHSEALS_REPO:-https://github.com/MHSeals/mhseals_sim.git}"
COMPONENTS="${MHSEALS_COMPONENTS:-$ALL_COMPONENTS}"
truthy() { [[ "${1:-}" =~ ^(1|true|yes|y|on)$ ]]; }
DRY_RUN=false; truthy "${MHSEALS_DRY_RUN:-}" && DRY_RUN=true
ASSUME_YES=false; truthy "${MHSEALS_YES:-}" && ASSUME_YES=true
WITH_WINDOWS_BUILD=false
OPEN_AFTER=false

# ---------------------------------------------------------------------------- state
OS_ID=unknown; OS_LIKE=""; OS_VERSION=""; OS_NAME="Linux"; ARCH="$(uname -m)"
IMMUTABLE=false
PM=none
HAVE_TTY=false
SUDO=()
ROOT_OK=unknown
APT_UPDATED=false
EDITOR_BIN=""
DONE=(); SKIPPED=(); FAILED=(); MANUAL=(); WARNINGS=()

usage() {
    cat <<EOF
MHSeals RoboBoat simulator installer (Linux)

Usage:
  curl -fsSL https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- [options]
  bash install/install.sh [options]

Options:
  --components LIST      Comma-separated subset of: $ALL_COMPONENTS (default: all)
  --dir DIR              Where to clone the simulator (default: ~/mhseals_sim)       [MHSEALS_DIR]
  --branch NAME          Branch to check out (default: main)                          [MHSEALS_BRANCH]
  --repo URL|PATH        Git URL or local path (default: MHSeals/mhseals_sim on GitHub) [MHSEALS_REPO]
  --with-windows-build   Also install the Unity "Windows Build Support (Mono)" module
  --open                 Open the project in the Unity Editor when done
  --dry-run              Print the commands without running them                       [MHSEALS_DRY_RUN=1]
  -y, --yes              Do not ask for confirmation                                    [MHSEALS_YES=1]
  -h, --help             Show this help

Unity Editor $UNITY_VERSION ($UNITY_CHANGESET) is installed under ~/Unity/Hub/Editor.
Signing in to Unity Hub and activating a (free) Personal licence must be done by hand.
EOF
}

# ---------------------------------------------------------------------------- helpers
heading() { printf '\n== %s ==\n' "$1"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*" >&2; WARNINGS+=("$*"); }

quote_command() {
    printf '  $'
    printf ' %q' "$@"
    printf '\n'
}

run() {
    quote_command "$@"
    $DRY_RUN || "$@"
}

run_shell() {
    quote_command bash -c "$1"
    $DRY_RUN || bash -c "$1"
}

# approve PROMPT: yes under --yes/--dry-run; asks on the terminal (even when piped through curl); no terminal means yes.
approve() {
    $DRY_RUN && return 0
    $ASSUME_YES && return 0
    $HAVE_TTY || return 0
    local answer
    read -r -p "$1 [Y/n] " answer </dev/tty || return 1
    [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

done_() { DONE+=("$1${2:+ ($2)}"); }
skip_() { SKIPPED+=("$1${2:+ ($2)}"); }
fail_() { FAILED+=("$1${2:+ ($2)}"); printf '  FAILED: %s\n' "$1${2:+: $2}" >&2; }
manual_() { MANUAL+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1; }

has_component() { [[ ",$COMPONENTS," == *",$1,"* ]]; }

# ensure_root: set SUDO for package-manager commands; false (with the reason) when root is unavailable.
ensure_root() {
    [[ "$ROOT_OK" == yes ]] && return 0
    [[ "$ROOT_OK" == no ]] && return 1
    if [[ $EUID -eq 0 ]]; then
        SUDO=(); ROOT_OK=yes; return 0
    fi
    if ! have sudo; then
        info "sudo is not installed and this is not root: system packages cannot be installed."
        ROOT_OK=no; return 1
    fi
    SUDO=(sudo)
    if $DRY_RUN || sudo -n true 2>/dev/null; then
        ROOT_OK=yes; return 0
    fi
    if $HAVE_TTY; then
        info "Some steps need administrator rights; sudo will ask for your password."
        # shellcheck disable=SC2024  # the redirect is the prompt terminal, not a privileged file
        if sudo -v </dev/tty; then ROOT_OK=yes; return 0; fi
    else
        info "sudo needs a password but there is no terminal to ask on."
        info "Run 'sudo -v' first, or run the installer from a terminal: bash <(curl -fsSL URL)"
    fi
    ROOT_OK=no; return 1
}

as_root() { run "${SUDO[@]}" "$@"; }

# write_root_file PATH CONTENT: write a root-owned config file (shown, not written, in a dry run).
write_root_file() {
    printf '  $ write %s:\n' "$1"
    printf '%s\n' "$2" | sed 's/^/      /'
    $DRY_RUN && return 0
    printf '%s\n' "$2" | "${SUDO[@]}" tee "$1" >/dev/null && "${SUDO[@]}" chmod 0644 "$1"
}

detect_platform() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_LIKE="${ID_LIKE:-}"
        OS_VERSION="${VERSION_ID:-}"
        OS_NAME="${PRETTY_NAME:-$OS_ID}"
    fi
    # Image-based hosts (Silverblue/Kinoite/Bazzite/CoreOS, bootc, Ubuntu Core, SteamOS, NixOS): never touch the root fs.
    if have rpm-ostree || have bootc || [[ -e /run/ostree-booted ]] \
        || [[ "$OS_ID" =~ ^(coreos|fedora-coreos|fedora-iot|ubuntu-core|steamos|nixos)$ ]]; then
        IMMUTABLE=true
    fi
    if ! $IMMUTABLE; then
        if have apt-get; then PM=apt
        elif have dnf; then PM=dnf
        elif have pacman; then PM=pacman
        elif have zypper; then PM=zypper
        fi
    fi
    if [[ -t 0 ]]; then
        HAVE_TTY=true
    elif { : </dev/tty; } 2>/dev/null; then
        HAVE_TTY=true   # piped from curl, but a terminal is attached
    fi
    $HAVE_TTY || $ASSUME_YES || $DRY_RUN || info "No terminal attached: proceeding as if --yes was given."
}

# pm_install PKG...: install system packages with the detected package manager.
pm_install() {
    ensure_root || return 1
    case "$PM" in
        apt)
            if ! $APT_UPDATED; then as_root apt-get update || return 1; APT_UPDATED=true; fi
            as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) as_root dnf install -y --setopt=install_weak_deps=False "$@" ;;   # weak deps would pull in mesa drivers
        pacman)
            # Arch does not support partial upgrades, so -Sy is paired with -u.
            as_root pacman -Syu --needed --noconfirm "$@" ;;
        zypper) as_root zypper --non-interactive install --no-recommends "$@" ;;
        *) return 1 ;;
    esac
}

# pkg_name GENERIC: the package for a tool on this distribution.
pkg_name() {
    case "$1:$PM" in
        xz:apt) echo xz-utils ;;
        vulkan-loader:apt|vulkan-loader:zypper) echo libvulkan1 ;;
        vulkan-loader:pacman) echo vulkan-icd-loader ;;
        vulkan-loader:dnf) echo vulkan-loader ;;
        gpg:apt|gpg:dnf|gpg:pacman) echo gnupg ;;
        gpg:zypper) echo gpg2 ;;
        *) echo "$1" ;;
    esac
}

path_add_local_bin() {
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
}

# ---------------------------------------------------------------------------- component: base
install_git_lfs_static() {
    local arch tag url tmp want got
    case "$ARCH" in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) info "No static git-lfs build for $ARCH."; return 1 ;;
    esac
    tag="$(curl -fsSL "$GIT_LFS_RELEASE_API" | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' | head -1)" || true
    [[ -n "$tag" ]] || { info "Could not read the latest git-lfs release from the GitHub API."; return 1; }
    url="https://github.com/git-lfs/git-lfs/releases/download/${tag}/git-lfs-linux-${arch}-${tag}.tar.gz"
    info "Installing the static git-lfs $tag into ~/.local/bin (no root needed)."
    $DRY_RUN && { quote_command curl -fsSL "$url"; quote_command install -m 0755 git-lfs "$HOME/.local/bin/git-lfs"; return 0; }
    tmp="$(mktemp -d)"
    if curl -fsSL "$url" -o "$tmp/lfs.tar.gz" \
        && curl -fsSL "https://github.com/git-lfs/git-lfs/releases/download/${tag}/sha256sums.asc" -o "$tmp/sums" \
        && want="$(grep -E "[ *]git-lfs-linux-${arch}-${tag}\.tar\.gz\$" "$tmp/sums" | grep -oE '^[0-9a-f]{64}')" \
        && got="$(sha256sum "$tmp/lfs.tar.gz")" && [[ -n "$want" && "${got%% *}" == "$want" ]] \
        && tar -xzf "$tmp/lfs.tar.gz" -C "$tmp" \
        && mkdir -p "$HOME/.local/bin" \
        && install -m 0755 "$(compgen -G "$tmp/git-lfs*/git-lfs" | head -1)" "$HOME/.local/bin/git-lfs"; then
        rm -rf "$tmp"; path_add_local_bin
        manual_ "git-lfs is in ~/.local/bin: make sure that directory is on your PATH (most distributions add it at login)."
        return 0
    fi
    rm -rf "$tmp"; return 1
}

component_base() {
    heading "base: git, git-lfs, curl, tar, xz"
    local missing=() tool
    for tool in git curl tar xz; do have "$tool" || missing+=("$tool"); done
    local need_lfs=false
    git lfs version >/dev/null 2>&1 || need_lfs=true
    if [[ ${#missing[@]} -eq 0 ]] && ! $need_lfs; then
        info "$(git --version), $(git lfs version), curl, tar and xz are installed."
        skip_ base "already installed"; return 0
    fi
    $need_lfs && missing+=(git-lfs)
    info "Missing: ${missing[*]}"
    approve "Install ${missing[*]}?" || { skip_ base "declined"; return 0; }

    if [[ "$PM" != none ]] && ensure_root; then
        local pkgs=() m
        for m in "${missing[@]}"; do pkgs+=("$(pkg_name "$m")"); done
        [[ "$PM" == apt ]] && pkgs+=(ca-certificates)
        if pm_install "${pkgs[@]}"; then done_ base "installed ${missing[*]}"; return 0; fi
        info "The package manager could not install everything; trying user-level fallbacks."
    fi
    # User-level fallbacks (immutable host, unknown distribution, or no root).
    local still=()
    for tool in "${missing[@]}"; do
        if [[ "$tool" == git-lfs ]]; then
            if have git && install_git_lfs_static; then continue; fi
        elif ! $DRY_RUN && have "$tool"; then continue
        fi
        still+=("$tool")
    done
    if [[ ${#still[@]} -eq 0 ]]; then done_ base "installed ${missing[*]} (user level)"; return 0; fi
    fail_ base "could not install ${still[*]}"
    if $IMMUTABLE; then
        manual_ "Install ${still[*]} through your image (rpm-ostree install / a toolbox or distrobox container), then re-run."
    else
        manual_ "Install ${still[*]} with your package manager, then re-run."
    fi
    return 1
}

# ---------------------------------------------------------------------------- component: vulkan
vulkan_loader_present() {
    { have ldconfig && ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1'; } \
        || compgen -G '/usr/lib*/libvulkan.so.1' >/dev/null || compgen -G '/usr/lib/*/libvulkan.so.1' >/dev/null
}

component_vulkan() {
    heading "vulkan: loader and vulkaninfo (GPU drivers are never installed)"
    local want=()
    vulkan_loader_present || want+=(vulkan-loader)
    have vulkaninfo || want+=(vulkan-tools)
    if [[ ${#want[@]} -gt 0 ]]; then
        if $IMMUTABLE || [[ "$PM" == none ]]; then
            info "Not installing ${want[*]} on this host (immutable or unknown package manager)."
        elif approve "Install the Vulkan loader/tools (${want[*]})?"; then
            local pkgs=() w
            for w in "${want[@]}"; do pkgs+=("$(pkg_name "$w")"); done
            pm_install "${pkgs[@]}" || warn "Could not install ${pkgs[*]}."
        fi
    fi
    if $DRY_RUN && ! have vulkaninfo; then
        quote_command vulkaninfo --summary
        done_ vulkan "planned"; return 0
    fi
    if ! have vulkaninfo; then
        warn "vulkaninfo is not available, so the Vulkan device could not be checked."
        skip_ vulkan "vulkaninfo missing"; return 0
    fi
    local out devices
    out="$(vulkaninfo --summary 2>&1)" || true
    devices="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*deviceName[[:space:]]*=[[:space:]]*//p')"
    if [[ -z "$devices" ]]; then
        warn "No Vulkan device found. Install your GPU's Vulkan driver (Mesa: mesa-vulkan-drivers / vulkan-radeon / vulkan-intel; NVIDIA: the proprietary driver), or start Unity with -force-glcore."
        done_ vulkan "no device"
        return 0
    fi
    while IFS= read -r d; do info "Vulkan device: $d"; done <<<"$devices"
    if ! grep -qvi 'llvmpipe' <<<"$devices"; then
        warn "Only a software Vulkan device (llvmpipe) is available: the simulator will render on the CPU and be very slow."
    fi
    done_ vulkan "$(head -1 <<<"$devices")"
}

# ---------------------------------------------------------------------------- component: unity-hub
# hub_cmd: print the Hub command (one word per line) or fail when no Hub is installed.
hub_cmd() {
    if have unityhub; then echo unityhub
    elif [[ -x /opt/unityhub/unityhub ]]; then echo /opt/unityhub/unityhub
    elif have flatpak && flatpak info "$FLATPAK_HUB_ID" >/dev/null 2>&1; then printf '%s\n' flatpak run "$FLATPAK_HUB_ID"
    else return 1
    fi
}

install_hub_apt() {
    ensure_root || return 1
    have gpg || pm_install "$(pkg_name gpg)" || return 1
    have curl || $DRY_RUN || return 1
    # Per https://docs.unity.com/en-us/hub/install-hub-linux (DEB822 sources file).
    as_root install -d -m 0755 /etc/apt/keyrings || return 1
    run_shell "curl -fsSL $UNITY_KEY_URL | ${SUDO[*]:-} gpg --dearmor --yes -o /etc/apt/keyrings/unityhub.gpg" || return 1
    as_root chmod a+r /etc/apt/keyrings/unityhub.gpg || return 1
    write_root_file /etc/apt/sources.list.d/unityhub.sources "$(printf '%s\n' 'Types: deb' "URIs: $UNITY_DEB_URI" \
        'Suites: stable' 'Components: main' 'Signed-By: /etc/apt/keyrings/unityhub.gpg')" || return 1
    APT_UPDATED=false
    pm_install unityhub
}

rpm_repo_text() {
    printf '%s\n' '[unityhub]' 'name=Unity Hub' "baseurl=$UNITY_RPM_BASEURL" 'enabled=1' 'gpgcheck=1' \
        "gpgkey=$UNITY_RPM_KEY" 'repo_gpgcheck=1'
}

install_hub_dnf() {
    ensure_root || return 1
    write_root_file /etc/yum.repos.d/unityhub.repo "$(rpm_repo_text)" || return 1
    pm_install unityhub
}

install_hub_zypper() {
    ensure_root || return 1
    # The docs only cover dnf; zypper reads the same rpm-md repository.
    if ! zypper lr unityhub >/dev/null 2>&1; then
        as_root zypper --non-interactive addrepo --refresh "$UNITY_RPM_BASEURL" unityhub || return 1
    fi
    if as_root zypper --non-interactive --gpg-auto-import-keys refresh unityhub && pm_install unityhub; then
        return 0
    fi
    # Hub 4.0.1's rpm requires 'vulkan-loader', which openSUSE calls libvulkan1, so this can fail;
    # drop the repository again rather than leave a broken one behind.
    info "zypper could not install unityhub; removing the repository again."
    as_root zypper --non-interactive removerepo unityhub || true
    return 1
}

install_hub_aur() {
    [[ $EUID -ne 0 ]] || { info "AUR helpers do not run as root."; return 1; }
    local helper
    if have yay; then helper=yay; elif have paru; then helper=paru; else return 1; fi
    run "$helper" -S --needed --noconfirm unityhub
}

install_hub_flatpak() {
    if ! have flatpak; then
        if $IMMUTABLE || [[ "$PM" == none ]]; then info "flatpak is not installed and cannot be installed here."; return 1; fi
        pm_install flatpak || return 1
    fi
    run flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO" || return 1
    run flatpak install --user -y --noninteractive flathub "$FLATPAK_HUB_ID" || return 1
    info "The Flathub Unity Hub is community-maintained (not by Unity)."
}

component_unity_hub() {
    heading "unity-hub: Unity Hub"
    local existing
    if existing="$(hub_cmd)"; then
        info "Unity Hub is installed: $(paste -sd' ' <<<"$existing")"
        skip_ unity-hub "already installed"; return 0
    fi
    approve "Install Unity Hub?" || { skip_ unity-hub "declined"; return 0; }
    local method="" native=true
    if [[ "$PM" =~ ^(apt|dnf|zypper)$ ]] && ! glibc_at_least 2.39; then
        # Unity's Hub 4.0.1 deb/rpm binary needs GLIBC_2.39 (it fails to start on Debian 12 / Ubuntu 22.04 / RHEL 9);
        # the Flatpak brings its own runtime.
        info "glibc is older than 2.39, which Unity's current Hub package needs; using the Flatpak Hub instead."
        native=false
    fi
    if ! $IMMUTABLE && $native; then
        case "$PM" in
            apt) install_hub_apt && method="Unity apt repository" ;;
            dnf) install_hub_dnf && method="Unity rpm repository" ;;
            zypper) install_hub_zypper && method="Unity rpm repository via zypper" ;;
            pacman) install_hub_aur && method="AUR" ;;
        esac
    fi
    if [[ -z "$method" ]]; then
        [[ "$PM" == none ]] || $IMMUTABLE || info "Falling back to the Flatpak Unity Hub."
        install_hub_flatpak && method="Flatpak (Flathub, user)"
    fi
    if [[ -n "$method" ]]; then done_ unity-hub "$method"; return 0; fi
    fail_ unity-hub "no install method worked"
    manual_ "Install Unity Hub by hand: https://docs.unity.com/en-us/hub/install-hub-linux (the AppImage works on any distribution)."
    return 1
}

# ---------------------------------------------------------------------------- component: unity-editor
unity_cli() {
    if have unity && unity --version >/dev/null 2>&1; then echo unity
    elif [[ -x "$HOME/.local/bin/unity" ]]; then echo "$HOME/.local/bin/unity"
    else return 1
    fi
}

hub_install_root() {
    local f="$HOME/.config/UnityHub/secondaryInstallPath.json" p=""
    [[ -r "$f" ]] && p="$(sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$f" | head -1)"
    echo "${p:-$HOME/Unity/Hub/Editor}"
}

# find_editor: set EDITOR_BIN when Unity $UNITY_VERSION is installed.
find_editor() {
    local c root cli loc=""
    for root in "$HOME/Unity/Hub/Editor" "$(hub_install_root)"; do
        c="$root/$UNITY_VERSION/Editor/Unity"
        [[ -x "$c" ]] && { EDITOR_BIN="$c"; return 0; }
    done
    if cli="$(unity_cli)"; then   # a custom install path set in the Hub or with `unity install-path --set`
        loc="$("$cli" install-path --no-banner --non-interactive 2>/dev/null | tail -1)" || true
        c="$loc/$UNITY_VERSION/Editor/Unity"
        [[ -n "$loc" && -x "$c" ]] && { EDITOR_BIN="$c"; return 0; }
    fi
    return 1
}

windows_module_present() {
    [[ -n "$EDITOR_BIN" && -d "$(dirname "$EDITOR_BIN")/Data/PlaybackEngines/WindowsStandaloneSupport" ]]
}

# glibc_at_least VERSION: the host's glibc is VERSION or newer.
glibc_at_least() {
    local v
    v="$(getconf GNU_LIBC_VERSION 2>/dev/null)" || true   # "glibc 2.39"
    v="${v##* }"
    [[ -n "$v" ]] || v="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')" || true
    [[ -n "$v" ]] || return 1
    printf '%s\n%s\n' "$v" "$1" | sort -V -C -r
}

# ensure_unity_cli: install the standalone Unity CLI (`unity`), the supported replacement for the Hub CLI.
ensure_unity_cli() {
    unity_cli >/dev/null && return 0
    if [[ "$PM" == apt && -e /etc/apt/sources.list.d/unityhub.sources ]] || [[ "$PM" == dnf && -e /etc/yum.repos.d/unityhub.repo ]]; then
        info "Installing the Unity CLI package (unity-cli) from Unity's repository."
        pm_install unity-cli && { $DRY_RUN || unity_cli >/dev/null; } && return 0
    fi
    glibc_at_least 2.34 || { info "The Unity CLI needs glibc 2.34+; skipping it."; return 1; }
    info "Installing the Unity CLI into ~/.local/bin with Unity's installer ($UNITY_CLI_SCRIPT_URL)."
    if $DRY_RUN; then quote_command bash -c "curl -fsSL $UNITY_CLI_SCRIPT_URL | bash"; return 0; fi
    local tmp; tmp="$(mktemp)"
    if curl -fsSL "$UNITY_CLI_SCRIPT_URL" -o "$tmp" && bash "$tmp"; then
        rm -f "$tmp"; path_add_local_bin; unity_cli >/dev/null && return 0
    fi
    rm -f "$tmp"; return 1
}

editor_via_unity_cli() {
    ensure_unity_cli || return 1
    local cli; cli="$(unity_cli 2>/dev/null || echo unity)"
    local args=(install "$UNITY_VERSION" --changeset "$UNITY_CHANGESET" --yes --accept-eula --non-interactive --no-banner)
    $WITH_WINDOWS_BUILD && args+=(--module windows-mono)
    run "$cli" "${args[@]}"
}

editor_via_hub_cli() {
    local hub; mapfile -t hub < <(hub_cmd) || true
    [[ ${#hub[@]} -gt 0 ]] || return 1
    # Hub 3 only: Hub 4 prints the Unity CLI replacement and exits non-zero.
    local args=(--headless install --version "$UNITY_VERSION" --changeset "$UNITY_CHANGESET")
    $WITH_WINDOWS_BUILD && args+=(--module windows-mono)
    run "${hub[@]}" "${args[@]}"
}

editor_via_archive() {
    local root="$HOME/Unity/Hub/Editor"
    local dest="$root/$UNITY_VERSION" part="$root/.Unity-$UNITY_VERSION.tar.xz.part"
    run mkdir -p "$root" || return 1
    if ! $DRY_RUN; then
        local avail=0 free_gb
        { read -r _; read -r _ _ _ avail _; } < <(df -Pk "$root") || true
        free_gb=$(( ${avail:-0} / 1048576 ))
        if (( free_gb < UNITY_EDITOR_DOWNLOAD_GB + UNITY_EDITOR_INSTALLED_GB )); then
            info "Only ${free_gb} GB free in $root; about $((UNITY_EDITOR_DOWNLOAD_GB + UNITY_EDITOR_INSTALLED_GB)) GB is needed."
            return 1
        fi
    fi
    info "Downloading the editor archive (4.3 GB, resumable)."
    run curl -fL --retry 5 --retry-delay 5 -C - -o "$part" "$UNITY_EDITOR_URL" || return 1
    if ! $DRY_RUN; then
        info "Checking the archive's md5."
        local sum; sum="$(md5sum "$part")"
        [[ "${sum%% *}" == "$UNITY_EDITOR_MD5" ]] || { info "md5 mismatch; deleting the download."; rm -f "$part"; return 1; }
    fi
    run rm -rf "$dest.partial" || return 1
    run mkdir -p "$dest.partial" || return 1
    run tar -xJf "$part" -C "$dest.partial" || return 1
    run mv "$dest.partial" "$dest" || return 1
    run rm -f "$part"
}

component_unity_editor() {
    heading "unity-editor: Unity $UNITY_VERSION ($UNITY_CHANGESET)"
    if find_editor; then
        info "Unity $UNITY_VERSION is installed: $EDITOR_BIN"
        if $WITH_WINDOWS_BUILD && ! windows_module_present; then
            local cli
            if cli="$(unity_cli)"; then
                if run "$cli" install-modules --editor-version "$UNITY_VERSION" --module windows-mono --yes --accept-eula --non-interactive --no-banner; then
                    done_ unity-editor "added windows-mono"; return 0
                fi
            fi
            manual_ "Add 'Windows Build Support (Mono)' in Unity Hub > Installs > $UNITY_VERSION > Add modules."
            skip_ unity-editor "installed; windows-mono module left manual"; return 0
        fi
        skip_ unity-editor "already installed"; return 0
    fi
    approve "Download and install Unity $UNITY_VERSION (about 4.3 GB download, 13 GB on disk)?" \
        || { skip_ unity-editor "declined"; return 0; }
    local method=""
    if editor_via_unity_cli && { $DRY_RUN || find_editor; }; then method="Unity CLI"
    else
        info "The Unity CLI route did not work; trying the Hub 3 command line."
        if editor_via_hub_cli && { $DRY_RUN || find_editor; }; then method="Unity Hub CLI"
        else
            info "The Hub command line did not work; downloading the editor archive directly."
            if editor_via_archive && { $DRY_RUN || find_editor; }; then
                method="direct archive"
                $WITH_WINDOWS_BUILD && manual_ "Add 'Windows Build Support (Mono)' in Unity Hub > Installs > $UNITY_VERSION > Add modules (the archive route has no modules)."
                if ! $DRY_RUN && have unityhub; then
                    info "Unity Hub finds editors under ~/Unity/Hub/Editor; if it does not, use Installs > Locate."
                fi
            fi
        fi
    fi
    if [[ -n "$method" ]]; then done_ unity-editor "$method"; return 0; fi
    fail_ unity-editor "every install route failed"
    manual_ "Install Unity $UNITY_VERSION from the Unity Hub (Installs > Install Editor > Archive, changeset $UNITY_CHANGESET)."
    return 1
}

# ---------------------------------------------------------------------------- component: repo
resolve_repo_url() {
    if [[ "$REPO" != *://* && "$REPO" != *@*:* && -d "$REPO" ]]; then
        # A local path: file:// keeps git-lfs (file transfer adapter) and --filter working.
        printf 'file://%s\n' "$(cd "$REPO" && pwd -P)"
    else
        printf '%s\n' "$REPO"
    fi
}

component_repo() {
    heading "repo: $DIR ($BRANCH)"
    if ! $DRY_RUN && { ! have git || ! git lfs version >/dev/null 2>&1; }; then
        fail_ repo "git and git-lfs are required (run the base component)"; return 1
    fi
    local url; url="$(resolve_repo_url)"
    export GIT_TERMINAL_PROMPT=0
    run git lfs install || { fail_ repo "git lfs install failed"; return 1; }

    if [[ -e "$DIR/.git" ]]; then
        info "Existing checkout found; updating it in place."
        local dirty current
        dirty="$(git -C "$DIR" status --porcelain --untracked-files=no 2>/dev/null)"
        if [[ -n "$dirty" ]]; then
            printf '%s\n' "$dirty" | head -10 | sed 's/^/    /'
            info "Local changes found in $DIR; not touching it. Commit or stash them (git stash), then re-run."
            fail_ repo "local changes in $DIR, left untouched"; return 1
        fi
        current="$(git -C "$DIR" symbolic-ref --short -q HEAD || echo DETACHED)"
        if [[ "$current" != "$BRANCH" ]]; then
            info "$DIR is on '$current', not '$BRANCH'; not switching branches. Run: git -C $DIR switch $BRANCH"
            fail_ repo "on branch $current, expected $BRANCH"; return 1
        fi
        local remote; remote="$(git -C "$DIR" remote get-url origin 2>/dev/null || echo)"
        [[ "$remote" == "$url" || "$remote" == "$REPO" ]] || info "Note: origin is $remote (not $url); updating from $url."
        run git -C "$DIR" fetch --filter=blob:none "$url" "$BRANCH" || { fail_ repo "git fetch failed"; return 1; }
        local before after
        before="$(git -C "$DIR" rev-parse HEAD)"
        if ! run git -C "$DIR" merge --ff-only FETCH_HEAD; then
            info "Your branch and $url $BRANCH have diverged; not merging. Rebase or reset it yourself."
            fail_ repo "cannot fast-forward"; return 1
        fi
        run git -C "$DIR" lfs pull "$url" || { fail_ repo "git lfs pull failed (see LFS quota in install/README.md)"; return 1; }
        after="$(git -C "$DIR" rev-parse HEAD)"
        if [[ "$before" == "$after" ]]; then done_ repo "up to date at ${after:0:10}"
        else done_ repo "updated ${before:0:10}..${after:0:10}"
        fi
        return 0
    fi
    if [[ -e "$DIR" ]] && [[ -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then
        fail_ repo "$DIR exists, is not empty and is not a git checkout; choose another --dir"; return 1
    fi
    # Partial clone: history holds large non-LFS blobs that a full clone would download.
    # LFS smudge is skipped during the clone, then fetched in one batch (resumable on re-run).
    run env GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none --branch "$BRANCH" "$url" "$DIR" \
        || { fail_ repo "git clone failed"; return 1; }
    run git -C "$DIR" lfs pull || { fail_ repo "git lfs pull failed (see LFS quota in install/README.md)"; return 1; }
    done_ repo "cloned into $DIR"
}

# ---------------------------------------------------------------------------- open
open_project() {
    heading "open"
    [[ -n "$EDITOR_BIN" ]] || find_editor || { info "Unity $UNITY_VERSION is not installed; cannot open."; return 0; }
    [[ -d "$DIR" ]] || $DRY_RUN || { info "$DIR does not exist; cannot open."; return 0; }
    info "Starting Unity in the background (the first import takes a while)."
    if $DRY_RUN; then quote_command "$EDITOR_BIN" -projectPath "$DIR"; return 0; fi
    nohup "$EDITOR_BIN" -projectPath "$DIR" >/dev/null 2>&1 &
    disown || true
}

# ---------------------------------------------------------------------------- main
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --components) COMPONENTS="${2:?--components needs a value}"; shift 2 ;;
            --components=*) COMPONENTS="${1#*=}"; shift ;;
            --dir) DIR="${2:?--dir needs a value}"; shift 2 ;;
            --dir=*) DIR="${1#*=}"; shift ;;
            --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
            --branch=*) BRANCH="${1#*=}"; shift ;;
            --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
            --repo=*) REPO="${1#*=}"; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -y|--yes) ASSUME_YES=true; shift ;;
            --with-windows-build) WITH_WINDOWS_BUILD=true; shift ;;
            --with-linux-build) echo "Note: --with-linux-build applies to Windows; Linux build support ships with the Linux editor." >&2; shift ;;
            --open) OPEN_AFTER=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
        esac
    done
    DIR="${DIR/#\~/$HOME}"
    REPO="${REPO/#\~/$HOME}"
    COMPONENTS="${COMPONENTS// /}"
    [[ "$COMPONENTS" == all ]] && COMPONENTS="$ALL_COMPONENTS"
    local c
    IFS=',' read -r -a _comps <<<"$COMPONENTS"
    for c in "${_comps[@]}"; do
        [[ ",$ALL_COMPONENTS," == *",$c,"* ]] || { echo "Unknown component: $c (choose from $ALL_COMPONENTS)" >&2; exit 2; }
    done
    [[ "$DIR" == /* ]] || DIR="$PWD/$DIR"
}

print_summary() {
    heading "Summary"
    local label=Done item
    $DRY_RUN && label="Planned (dry run)"
    printf '%s:\n' "$label"; for item in "${DONE[@]+"${DONE[@]}"}"; do printf '  - %s\n' "$item"; done; [[ ${#DONE[@]} -gt 0 ]] || echo "  - none"
    printf 'Skipped:\n'; for item in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do printf '  - %s\n' "$item"; done; [[ ${#SKIPPED[@]} -gt 0 ]] || echo "  - none"
    printf 'Failed:\n'; for item in "${FAILED[@]+"${FAILED[@]}"}"; do printf '  - %s\n' "$item"; done; [[ ${#FAILED[@]} -gt 0 ]] || echo "  - none"
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf 'Warnings:\n'; for item in "${WARNINGS[@]}"; do printf '  - %s\n' "$item"; done
    fi
    printf 'Manual steps:\n'
    for item in "${MANUAL[@]+"${MANUAL[@]}"}"; do printf '  - %s\n' "$item"; done
    printf '  - Open Unity Hub, sign in with a Unity ID, and activate a free Personal licence\n'
    printf '    (Hub > Preferences > Licenses > Add > Get a free personal license). This cannot be scripted.\n'
    printf '  - Open the project: Unity Hub > Projects > Add > %s, or run:\n' "$DIR"
    printf '      %q -projectPath %q\n' "${EDITOR_BIN:-$HOME/Unity/Hub/Editor/$UNITY_VERSION/Editor/Unity}" "$DIR"
    printf '    The first import takes several minutes. Re-run this installer any time to update.\n'
}

main() {
    parse_args "$@"
    path_add_local_bin
    detect_platform

    heading "MHSeals RoboBoat simulator installer"
    printf '  Host:        %s (%s %s%s), %s\n' "$OS_NAME" "$OS_ID" "$OS_VERSION" "${OS_LIKE:+, like $OS_LIKE}" "$ARCH"
    printf '  Packages:    %s%s\n' "$PM" "$($IMMUTABLE && echo ' (immutable host: user-level installs only)')"
    printf '  Components:  %s\n' "$COMPONENTS"
    printf '  Checkout:    %s (branch %s from %s)\n' "$DIR" "$BRANCH" "$REPO"
    printf '  Unity:       %s (%s)%s\n' "$UNITY_VERSION" "$UNITY_CHANGESET" "$($WITH_WINDOWS_BUILD && echo ' + windows-mono')"
    $DRY_RUN && printf '  Dry run:     commands are printed, not run\n'
    approve "Continue?" || { echo "Cancelled."; exit 0; }

    local c
    for c in base vulkan unity-hub unity-editor repo; do
        has_component "$c" || continue
        "component_${c//-/_}" || true   # each component records its own failure; carry on with the rest
    done
    $OPEN_AFTER && open_project
    print_summary
    [[ ${#FAILED[@]} -eq 0 ]]
}

# Everything above only defines functions, so a truncated download runs nothing.
main "$@"
