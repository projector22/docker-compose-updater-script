#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu 24.04: migrate APT-installed docker-compose
# to the official Docker Compose v2 plugin.

BACKUP_DIR="/var/backups/docker-compose-migration-$(date +%Y%m%d-%H%M%S)"

log() {
    printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Run with sudo."
[[ -r /etc/os-release ]] || die "Cannot identify operating system."

# shellcheck disable=SC1091
source /etc/os-release

[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] \
    || die "This script is for Ubuntu 24.04 only."

command -v docker >/dev/null 2>&1 \
    || die "Docker CLI is not installed."

docker info >/dev/null 2>&1 \
    || die "Docker daemon is unavailable."

# Already migrated?
if docker compose version >/dev/null 2>&1; then
    log "Docker Compose v2 is already working:"
    docker compose version

    if dpkg-query -W -f='${db:Status-Status}' docker-compose \
        2>/dev/null | grep -qx installed; then
        log "Legacy APT package is still installed."
        log "Remove it separately after checking for dependencies:"
        printf '  sudo apt remove docker-compose\n'
    fi

    exit 0
fi

# Confirm the expected legacy package is installed.
dpkg-query -W -f='${db:Status-Status}' docker-compose \
    2>/dev/null | grep -qx installed \
    || die "APT package docker-compose is not installed."

log "Creating migration backup: $BACKUP_DIR"
install -d -m 0700 "$BACKUP_DIR"

dpkg-query -W -f='${binary:Package}\t${Version}\n' \
    > "$BACKUP_DIR/packages-before.tsv"

docker --version > "$BACKUP_DIR/docker-version.txt"

apt-cache show docker-compose-plugin >/dev/null 2>&1 || {
    log "Compose plugin unavailable in current APT indexes."
    log "Adding Docker's official Ubuntu repository."

    apt-get update
    apt-get install -y --no-upgrade ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH="$(dpkg --print-architecture)"

    printf '%s\n' \
        "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
}

apt-cache show docker-compose-plugin >/dev/null 2>&1 \
    || die "docker-compose-plugin is unavailable from configured APT sources."

log "Installing Docker Compose v2."
apt-get install -y --no-upgrade docker-compose-plugin

log "Verifying the new Compose command."
docker compose version \
    || die "Compose v2 verification failed. Legacy package retained."

log "Removing legacy APT package."
apt-get remove -y docker-compose

log "Verifying final installation."
docker compose version

if command -v docker-compose >/dev/null 2>&1; then
    log "WARNING: A docker-compose executable remains in PATH:"
    command -v docker-compose
else
    log "Legacy docker-compose command is no longer in PATH."
fi

printf '\nMigration complete.\n'
printf 'Backup directory: %s\n' "$BACKUP_DIR"
printf '\nCheck each project before redeploying:\n'
printf '  docker compose config\n'
printf '  docker compose ps\n'
