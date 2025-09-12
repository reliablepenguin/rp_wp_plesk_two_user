#!/usr/bin/env bash
# Harden WordPress on Plesk with a two-user model (ACL REQUIRED)
# - Runtime user (site_runtime) runs PHP-FPM
# - Deploy user (site_owner) owns code and deploys
#
# REQUIREMENTS:
# - The Plesk subscription for <domain> is already created.
# - The subscription's system user (runtime) exists; pass it via -r (e.g., -r site_runtime).
# - ACL tools (setfacl/getfacl) are installed and the filesystem supports ACLs.
#
# Example:
#   sudo bash wp_two_user_setup.sh \
#     -p example.com \
#     -r site_runtime \
#     -o site_owner \
#     -w "wp-content/uploads wp-content/cache"
#
# A repair script is generated in the shared home:
#   /var/www/vhosts/<domain>/scripts/wp_two_user_repair_<domain-or-vhostbasename>.sh
#
# v1.8 (ACL REQUIRED; shared-home ACL = rx; ignore setfacl errors on NFS writable dirs)
#
# © 2025 Reliable Penguin, Inc.  All rights reserved.
# This script may be used and modified for your own hosting environments.
# Redistribution requires attribution to Reliable Penguin.

set -euo pipefail

# Defaults
WRITABLE_DIRS=("wp-content/uploads" "wp-content/cache")
VHOSTROOT=""
DOMAIN=""
RUNTIME_USER=""
DEPLOY_USER=""
PSA_GROUP="psacln"
DRY_RUN=0

# ---- helpers ---------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  sudo bash wp_two_user_setup.sh [OPTIONS]

Required:
  -r, --runtime-user USER     Plesk subscription system user (runs PHP-FPM)
  -o, --deploy-user  USER     Deploy user that will own the code

Target (choose one):
  -p, --domain DOMAIN         Domain (uses /var/www/vhosts/DOMAIN/httpdocs)
      OR
  -vhostroot PATH             Absolute path to vhost document root

Optional:
  -w, --writable "DIRS"       Space-separated list of writable dirs
                              (default: "wp-content/uploads wp-content/cache")
  --dry-run                   Print actions without making changes
  -h, --help                  Show this help and exit

Notes:
  • ACL REQUIRED: 'setfacl' and 'getfacl' must be installed and supported by the FS.
    Debian/Ubuntu:  apt-get update && apt-get install -y acl
    RHEL/Rocky/Alma: dnf install -y acl || yum install -y acl
    Amazon Linux:   dnf install -y acl || yum install -y acl
    SUSE/SLES:      zypper install -y acl
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

say() { echo "$@"; }
do_or_echo() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

get_home_dir() {
  local u="$1"
  getent passwd "$u" | awk -F: '{print $6}'
}

require_acl_tools() {
  if ! have_cmd setfacl || ! have_cmd getfacl; then
    die $'ACL tools not found. Install the \'acl\' package, e.g.:\n'\
        $'  Debian/Ubuntu:  apt-get update && apt-get install -y acl\n'\
        $'  RHEL/Rocky/Alma: dnf install -y acl || yum install -y acl\n'\
        $'  Amazon Linux:    dnf install -y acl || yum install -y acl\n'\
        $'  SUSE/SLES:       zypper install -y acl'
  fi
}

test_acl_on_path() {
  local path="$1"
  local user="$2"
  # Try applying rx ACL, then remove it
  setfacl -m "u:${user}:rx" "$path" 2>/dev/null || \
    die "ACL application failed on $path. Ensure the FS is mounted with ACL support (see blog instructions)."
  setfacl -x "u:${user}" "$path" 2>/dev/null || true
}

# ---- args -----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--domain) DOMAIN="${2:-}"; shift 2;;
    -r|--runtime-user) RUNTIME_USER="${2:-}"; shift 2;;
    -o|--owner-user|--deploy-user) DEPLOY_USER="${2:-}"; shift 2;;
    -w|--writable) IFS=' ' read -r -a WRITABLE_DIRS <<< "${2:-}"; shift 2;;
    -vhostroot|--vhost-root) VHOSTROOT="${2:-}"; shift 2;;
    --dry-run) DRY_RUN=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (use -h for help)";;
  esac
done

# ---- validate --------------------------------------------------------------
need_root
[[ -n "$RUNTIME_USER" ]] || die "Missing -r/--runtime-user"
[[ -n "$DEPLOY_USER"  ]] || die "Missing -o/--deploy-user"

if [[ -z "$VHOSTROOT" ]]; then
  [[ -n "$DOMAIN" ]] || die "Provide either -p/--domain or -vhostroot"
  VHOSTROOT="/var/www/vhosts/${DOMAIN}/httpdocs"
fi
[[ -d "$VHOSTROOT" ]] || die "VHOSTROOT not found: $VHOSTROOT"

# Runtime user + home
id "$RUNTIME_USER" >/dev/null 2>&1 || die "Runtime user '$RUNTIME_USER' does not exist"
RUNTIME_HOME="$(get_home_dir "$RUNTIME_USER")"
[[ -n "$RUNTIME_HOME" && -d "$RUNTIME_HOME" ]] || die "Could not resolve runtime home for '$RUNTIME_USER'"

getent group "$PSA_GROUP" >/dev/null 2>&1 || die "Group '$PSA_GROUP' not found (is Plesk installed?)"

say "==> Plan
  Domain:        ${DOMAIN:-"(not set; using vhostroot)"} 
  Vhost root:    $VHOSTROOT
  Runtime user:  $RUNTIME_USER
  Runtime home:  $RUNTIME_HOME
  Deploy user:   $DEPLOY_USER
  Writable dirs: ${WRITABLE_DIRS[*]}
  Dry-run:       $DRY_RUN
"

# ---- ensure deploy user (home = runtime home; shell=/bin/bash) -------------
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  say "=> Creating deploy user: $DEPLOY_USER (home=$RUNTIME_HOME, shell=/bin/bash)"
  do_or_echo useradd -M -d "$RUNTIME_HOME" -s /bin/bash "$DEPLOY_USER"
else
  say "=> Deploy user exists: $DEPLOY_USER"
  CURRENT_HOME="$(get_home_dir "$DEPLOY_USER" || true)"
  if [[ "$CURRENT_HOME" != "$RUNTIME_HOME" ]]; then
    say "=> Adjusting $DEPLOY_USER home to $RUNTIME_HOME"
    do_or_echo usermod -d "$RUNTIME_HOME" "$DEPLOY_USER"
  fi
  CURRENT_SHELL="$(getent passwd "$DEPLOY_USER" | awk -F: '{print $7}')"
  if [[ "$CURRENT_SHELL" != "/bin/bash" ]]; then
    say "=> Setting $DEPLOY_USER shell to /bin/bash"
    do_or_echo usermod -s /bin/bash "$DEPLOY_USER"
  fi
fi

# add to psacln
if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qx "$PSA_GROUP"; then
  say "=> $DEPLOY_USER already in $PSA_GROUP"
else
  say "=> Adding $DEPLOY_USER to $PSA_GROUP"
  do_or_echo usermod -aG "$PSA_GROUP" "$DEPLOY_USER"
fi

# ---- ACL preflight (REQUIRED) ----------------------------------------------
require_acl_tools
if [[ $DRY_RUN -eq 0 ]]; then
  test_acl_on_path "$RUNTIME_HOME" "$DEPLOY_USER"
fi

# ---- shared home adjustments -----------------------------------------------
SCRIPTS_DIR="$RUNTIME_HOME/scripts"
say "=> Ensuring shared scripts directory: $SCRIPTS_DIR"
do_or_echo "install -d -m 0755 -o $DEPLOY_USER -g $PSA_GROUP \"$SCRIPTS_DIR\""

say "=> Granting $DEPLOY_USER read+traverse (rx) on $RUNTIME_HOME via ACL"
do_or_echo setfacl -m "u:${DEPLOY_USER}:rx" "$RUNTIME_HOME"
do_or_echo setfacl -m "d:u:${DEPLOY_USER}:rx" "$RUNTIME_HOME"

# Pre-create common dotdirs/files
for d in ".local" ".nodenv" ".phpenv"; do
  do_or_echo "install -d -m 0700 -o $DEPLOY_USER -g $PSA_GROUP \"$RUNTIME_HOME/$d\""
done
if [[ ! -f "$RUNTIME_HOME/.bash_profile" ]]; then
  do_or_echo "install -m 0644 -o $DEPLOY_USER -g $PSA_GROUP /dev/null \"$RUNTIME_HOME/.bash_profile\""
fi

# ---- assign code ownership & perms ----------------------------------------
say "=> Assigning code ownership to $DEPLOY_USER:$PSA_GROUP"
do_or_echo chown -R "$DEPLOY_USER:$PSA_GROUP" "$VHOSTROOT"

say "=> Setting read-only perms for code (dirs 755, files 644)"
do_or_echo "find \"$VHOSTROOT\" -type d -exec chmod 755 {} \\;"
do_or_echo "find \"$VHOSTROOT\" -type f -exec chmod 644 {} \\;"

# ---- writable dirs (ACLs for runtime user) --------------------------------
say "=> Preparing writable dirs for runtime user ($RUNTIME_USER)"
for rel in "${WRITABLE_DIRS[@]}"; do
  path="$VHOSTROOT/$rel"
  do_or_echo mkdir -p "$path"
  do_or_echo chown -R "$DEPLOY_USER:$PSA_GROUP" "$path"
  do_or_echo chmod -R 2775 "$path"
  # Allow ACLs; if NFS blocks them, continue with group perms
  do_or_echo "setfacl -R -m u:${RUNTIME_USER}:rwX -m d:u:${RUNTIME_USER}:rwX \"$path\" || echo 'NOTE: setfacl failed on $path (likely NFS). Continuing with 2775 + group ownership.'"
done

# ---- generate repair script (in shared home/scripts) -----------------------
REPAIR="$SCRIPTS_DIR/wp_two_user_repair_${DOMAIN:-$(basename "$VHOSTROOT")}.sh"
say "=> Installing repair script: $REPAIR"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] create $REPAIR (contents omitted)"
else
  cat >"$REPAIR" <<'REPAIR_EOF'
#!/usr/bin/env bash
set -euo pipefail
# © 2025 Reliable Penguin, Inc.  All rights reserved.

VHOSTROOT="__VHOSTROOT__"
DEPLOYUSER="__DEPLOYUSER__"
RUNTIMEUSER="__RUNTIMEUSER__"
PSAGRP="psacln"
WRITABLE_DIRS=(__WRITABLE_DIRS__)
RUNTIME_HOME="__RUNTIME_HOME__"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
require setfacl
require getfacl

echo ">> Restoring ownership to $DEPLOYUSER:$PSAGRP"
chown -R "$DEPLOYUSER:$PSAGRP" "$VHOSTROOT"
find "$VHOSTROOT" -type d -exec chmod 755 {} \;
find "$VHOSTROOT" -type f -exec chmod 644 {} \;

echo ">> Ensuring shared home ACLs and scripts dir"
setfacl -m "u:$DEPLOYUSER:rx" "$RUNTIME_HOME"
setfacl -m "d:u:$DEPLOYUSER:rx" "$RUNTIME_HOME"
install -d -m 0755 -o "$DEPLOYUSER" -g "$PSAGRP" "$RUNTIME_HOME/scripts"

# Pre-create dotdirs/files
for d in ".local" ".nodenv" ".phpenv"; do
  install -d -m 0700 -o "$DEPLOYUSER" -g "$PSAGRP" "$RUNTIME_HOME/$d"
done
[ -f "$RUNTIME_HOME/.bash_profile" ] || install -m 0644 -o "$DEPLOYUSER" -g "$PSAGRP" /dev/null "$RUNTIME_HOME/.bash_profile"

echo ">> Re-applying writable perms & ACLs"
for rel in "${WRITABLE_DIRS[@]}"; do
  path="$VHOSTROOT/$rel"
  mkdir -p "$path"
  chown -R "$DEPLOYUSER:$PSAGRP" "$path"
  chmod -R 2775 "$path"
  setfacl -R -m "u:$RUNTIMEUSER:rwX" -m "d:u:$RUNTIMEUSER:rwX" "$path" \
    || echo "NOTE: setfacl failed on $path (likely NFS). Continuing with 2775 + group ownership."
done
echo ">> Done."
REPAIR_EOF

  # Fill in variables in the heredoc template
  sed -i \
    -e "s|__VHOSTROOT__|$VHOSTROOT|g" \
    -e "s|__DEPLOYUSER__|$DEPLOY_USER|g" \
    -e "s|__RUNTIMEUSER__|$RUNTIME_USER|g" \
    -e "s|__RUNTIME_HOME__|$RUNTIME_HOME|g" \
    -e "s|WRITABLE_DIRS=\(.*\)|WRITABLE_DIRS=(${WRITABLE_DIRS[*]})|" \
    "$REPAIR"

  chown "$DEPLOY_USER:$PSA_GROUP" "$REPAIR"
  chmod 0755 "$REPAIR"
fi

say ""
say "✅ Completed."
say "Repair script: $REPAIR"
say "Tip: Run as the deploy user (or sudo -u $DEPLOY_USER):"
say "     sudo -u $DEPLOY_USER bash \"$REPAIR\""

