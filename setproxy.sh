#!/usr/bin/env bash
# setproxy.sh - unified proxy configurator for Linux
# Usage examples:
#   sudo ./setproxy.sh                  # disable proxy (remove configs)
#   sudo ./setproxy.sh 127.0.0.1:7897   # mixed http+socks proxy
#   sudo ./setproxy.sh -http 127.0.0.1:7897 -socks 127.0.0.1:7897
# Options:
#   -noreload       do not reload/restart services
#   -y              assume yes for reload confirmation
#   -no-proxy LIST  override NO_PROXY list (comma separated)
set -euo pipefail

NO_PROXY_DEFAULT="localhost,127.0.0.1,::1"

log() { echo "$*"; }

usage() {
  cat <<'EOF'
Usage:
  setproxy.sh                         # remove proxy config (disable)
  setproxy.sh HOST:PORT               # mixed http/socks proxy
  setproxy.sh -http HOST:PORT -socks HOST:PORT
  setproxy.sh -http HOST:PORT         # only http/https proxy
  setproxy.sh -socks HOST:PORT        # only socks proxy
Options:
  -noreload        do not reload/restart services
  -y               skip confirmation for reload/restart
  -no-proxy LIST   set NO_PROXY list
EOF
}

# -------------------------
# Argument parsing
# -------------------------
HTTP_ADDR=""
SOCKS_ADDR=""
MIXED_ADDR=""
DO_RELOAD=1
ASSUME_YES=0
NO_PROXY="$NO_PROXY_DEFAULT"

if [[ $# -eq 0 ]]; then
  MODE="disable"
else
  MODE="set"
  if [[ $# -eq 1 && "$1" != -* ]]; then
    MIXED_ADDR="$1"
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -http) HTTP_ADDR="${2:-}"; shift 2;;
        -socks) SOCKS_ADDR="${2:-}"; shift 2;;
        -no-proxy) NO_PROXY="${2:-}"; shift 2;;
        -noreload) DO_RELOAD=0; shift;;
        -y) ASSUME_YES=1; shift;;
        -h|--help) usage; exit 0;;
        *)
          if [[ -z "$MIXED_ADDR" && "$1" != -* ]]; then
            MIXED_ADDR="$1"; shift
          else
            echo "Unknown argument: $1"; usage; exit 1
          fi
          ;;
      esac
    done
  fi
fi

if [[ -n "$MIXED_ADDR" ]]; then
  HTTP_ADDR="$MIXED_ADDR"
  SOCKS_ADDR="$MIXED_ADDR"
fi

HTTP_PROXY=""
SOCKS_PROXY=""
if [[ -n "$HTTP_ADDR" ]]; then
  HTTP_PROXY="http://${HTTP_ADDR}"
fi
if [[ -n "$SOCKS_ADDR" ]]; then
  SOCKS_PROXY="socks5://${SOCKS_ADDR}"
fi

# -------------------------
# Detect services/tools
# -------------------------
SERVICES=(apt dnf yum pacman zypper apk pip pip3 git npm yarn docker curl wget systemctl snap flatpak conda)
INSTALLED=()
MISSING=()

has_cmd() { command -v "$1" >/dev/null 2>&1; }

for s in "${SERVICES[@]}"; do
  if has_cmd "$s"; then
    INSTALLED+=("$s")
  else
    MISSING+=("$s")
  fi
done

# concise output
log "Installed: ${INSTALLED[*]:-none}"
log "Missing: ${MISSING[*]:-none}"

# -------------------------
# helpers
# -------------------------
backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak"
}

# environment
ENV_FILE="/etc/profile.d/00proxy.sh"
apply_env() {
  backup_file "$ENV_FILE"
  cat > "$ENV_FILE" <<EOF
export http_proxy="${HTTP_PROXY}"
export https_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export HTTPS_PROXY="${HTTP_PROXY}"
export all_proxy="${SOCKS_PROXY}"
export ALL_PROXY="${SOCKS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
EOF
  chmod 644 "$ENV_FILE"
}
remove_env() { [[ -f "$ENV_FILE" ]] && rm -f "$ENV_FILE"; }

# apt
APT_CONF="/etc/apt/apt.conf.d/95proxies"
apply_apt() {
  [[ -n "$HTTP_PROXY" ]] || return 0
  backup_file "$APT_CONF"
  cat > "$APT_CONF" <<EOF
Acquire::http::Proxy "${HTTP_PROXY}/";
Acquire::https::Proxy "${HTTP_PROXY}/";
EOF
}
remove_apt() { [[ -f "$APT_CONF" ]] && rm -f "$APT_CONF"; }

# yum/dnf
apply_yum_dnf() {
  local conf="/etc/yum.conf"
  [[ -f "$conf" ]] || return 0
  backup_file "$conf"
  sed -i '/^proxy=/d;/^proxy_username=/d;/^proxy_password=/d' "$conf"
  if [[ -n "$HTTP_PROXY" ]]; then
    echo "proxy=${HTTP_PROXY}" >> "$conf"
  fi
}
remove_yum_dnf() {
  local conf="/etc/yum.conf"
  [[ -f "$conf" ]] || return 0
  backup_file "$conf"
  sed -i '/^proxy=/d;/^proxy_username=/d;/^proxy_password=/d' "$conf"
}

# pacman
PAC_CONF="/etc/pacman.conf"
apply_pacman() {
  [[ -f "$PAC_CONF" ]] || return 0
  backup_file "$PAC_CONF"
  if grep -q "^XferCommand" "$PAC_CONF"; then
    sed -i "s|^XferCommand.*|XferCommand = /usr/bin/curl -x ${HTTP_PROXY} -L -C - -f -o %o %u|" "$PAC_CONF"
  else
    printf '\nXferCommand = /usr/bin/curl -x %s -L -C - -f -o %%o %%u\n' "${HTTP_PROXY}" >> "$PAC_CONF"
  fi
}
remove_pacman() {
  [[ -f "$PAC_CONF" ]] || return 0
  backup_file "$PAC_CONF"
  sed -i '/^XferCommand = \/usr\/bin\/curl -x /d' "$PAC_CONF"
}

# zypper
ZYPP_CONF="/etc/zypp/zypp.conf"
apply_zypper() {
  [[ -f "$ZYPP_CONF" ]] || return 0
  backup_file "$ZYPP_CONF"
  sed -i '/^proxy=/d;/^proxy_http=/d;/^proxy_https=/d' "$ZYPP_CONF"
  [[ -n "$HTTP_PROXY" ]] && echo "proxy=${HTTP_PROXY}" >> "$ZYPP_CONF"
}
remove_zypper() { [[ -f "$ZYPP_CONF" ]] || return 0; backup_file "$ZYPP_CONF"; sed -i '/^proxy=/d;/^proxy_http=/d;/^proxy_https=/d' "$ZYPP_CONF"; }

# git
apply_git() {
  [[ -n "$HTTP_PROXY" ]] || return 0
  git config --global http.proxy "$HTTP_PROXY" || true
  git config --global https.proxy "$HTTP_PROXY" || true
}
remove_git() {
  git config --global --unset http.proxy || true
  git config --global --unset https.proxy || true
}

# npm/yarn
apply_npm() { [[ -n "$HTTP_PROXY" ]] || return 0; npm config set proxy "$HTTP_PROXY" || true; npm config set https-proxy "$HTTP_PROXY" || true; }
remove_npm() { has_cmd npm && npm config delete proxy >/dev/null 2>&1 || true; has_cmd npm && npm config delete https-proxy >/dev/null 2>&1 || true; }
apply_yarn() { [[ -n "$HTTP_PROXY" ]] || return 0; yarn config set proxy "$HTTP_PROXY" || true; yarn config set https-proxy "$HTTP_PROXY" || true; }
remove_yarn() { has_cmd yarn && yarn config delete proxy >/dev/null 2>&1 || true; has_cmd yarn && yarn config delete https-proxy >/dev/null 2>&1 || true; }

# pip
apply_pip() {
  [[ -n "$HTTP_PROXY" ]] || return 0
  local home="${SUDO_USER:-$(whoami)}"
  local pdir
  pdir=$(eval echo "~$home")/.config/pip
  mkdir -p "$pdir"
  local pconf="$pdir/pip.conf"
  backup_file "$pconf"
  cat > "$pconf" <<EOF
[global]
proxy = ${HTTP_PROXY}
EOF
  chown -R "$home":"$home" "$pdir" 2>/dev/null || true
}
remove_pip() {
  local home="${SUDO_USER:-$(whoami)}"
  local pconf
  pconf=$(eval echo "~$home")/.config/pip/pip.conf
  [[ -f "$pconf" ]] && rm -f "$pconf"
}

# curl/wget
apply_curl() {
  [[ -n "$HTTP_PROXY" ]] || return 0
  local home="${SUDO_USER:-$(whoami)}"
  local curlrc
  curlrc=$(eval echo "~$home")/.curlrc
  backup_file "$curlrc"
  echo "proxy = \"${HTTP_PROXY}\"" > "$curlrc"
  chown "$home":"$home" "$curlrc" 2>/dev/null || true
}
remove_curl() { local home="${SUDO_USER:-$(whoami)}"; local curlrc; curlrc=$(eval echo "~$home")/.curlrc; [[ -f "$curlrc" ]] && rm -f "$curlrc"; }

apply_wget() {
  [[ -n "$HTTP_PROXY" ]] || return 0
  local wgetrc="/etc/wgetrc"
  backup_file "$wgetrc"
  cat > "$wgetrc" <<EOF
use_proxy = on
http_proxy = ${HTTP_PROXY}
https_proxy = ${HTTP_PROXY}
EOF
}
remove_wget() { local wgetrc="/etc/wgetrc"; [[ -f "$wgetrc" ]] && rm -f "$wgetrc"; }

# docker (systemd)
apply_docker() {
  [[ -d /etc/systemd ]] || return 0
  [[ -n "$HTTP_PROXY" ]] || return 0
  local dir="/etc/systemd/system/docker.service.d"
  local conf="$dir/http-proxy.conf"
  mkdir -p "$dir"
  backup_file "$conf"
  cat > "$conf" <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}" "HTTPS_PROXY=${HTTP_PROXY}" "NO_PROXY=${NO_PROXY}"
EOF
}
remove_docker() {
  local conf="/etc/systemd/system/docker.service.d/http-proxy.conf"
  [[ -f "$conf" ]] && rm -f "$conf"
}

# -------------------------
# Apply or remove
# -------------------------
if [[ "$MODE" == "disable" ]]; then
  remove_env
  has_cmd apt && remove_apt
  (has_cmd yum || has_cmd dnf) && remove_yum_dnf
  has_cmd pacman && remove_pacman
  has_cmd zypper && remove_zypper
  has_cmd git && remove_git
  has_cmd npm && remove_npm
  has_cmd yarn && remove_yarn
  (has_cmd pip || has_cmd pip3) && remove_pip
  has_cmd curl && remove_curl
  has_cmd wget && remove_wget
  has_cmd docker && remove_docker
  log "Proxy configs removed (backups *.bak created where applicable)."
  exit 0
else
  apply_env
  has_cmd apt && apply_apt
  (has_cmd yum || has_cmd dnf) && apply_yum_dnf
  has_cmd pacman && apply_pacman
  has_cmd zypper && apply_zypper
  has_cmd git && apply_git
  has_cmd npm && apply_npm
  has_cmd yarn && apply_yarn
  (has_cmd pip || has_cmd pip3) && apply_pip
  has_cmd curl && apply_curl
  has_cmd wget && apply_wget
  has_cmd docker && apply_docker
  log "Proxy configs applied (backups *.bak created where applicable)."
fi

# -------------------------
# Reload / restart
# -------------------------
if [[ "$DO_RELOAD" -eq 1 ]]; then
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "Apply reload/restart for affected services? (Y/n): " ans
    ans="${ans:-Y}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
      log "Skip reload/restart."
      exit 0
    fi
  fi

  if has_cmd systemctl; then
    has_cmd docker && systemctl daemon-reload >/dev/null 2>&1 || true
    has_cmd docker && systemctl restart docker >/dev/null 2>&1 || true
  fi
  log "Reload/restart done (if applicable)."
else
  log "Reload/restart skipped by -noreload."
fi

log "Done."
