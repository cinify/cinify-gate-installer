#!/bin/sh
# cinify Gate — one-command installer.
#
#   curl -fsSL https://cinify.github.io/cinify-gate-installer/install.sh \
#     | sudo bash -s -- --key "<API-KEY>;de"
#
# This file is published to the root of the repository site and is the line support hands to a
# customer. Everything it does is deliberately reversible and idempotent: it registers the cinify
# package repository, installs the cinify-gate package THROUGH THE PACKAGE MANAGER (so the binary
# is signature-checked no matter how this script arrived) and then configures the machine with
# cinify-gate-configure, which validates the key against the cloud before writing it.
#
# Written for /bin/sh rather than bash: a minimal image need not carry bash, and this script has to
# run before anything of ours is installed.
set -eu

BASE_URL=${CINIFY_BASE_URL:-https://cinify.github.io/cinify-gate-installer}
KEY=""
REGION=""
CHANNEL=stable
REPO_ONLY=0
NO_VALIDATE=0
UNINSTALL=0

usage() {
	cat <<'EOF'
cinify Gate installer.

  install.sh --key "<API-KEY>;<REGION>"   register the repository, install and configure
  install.sh --key <API-KEY> --region de  the same, as separate arguments
  install.sh                              ask interactively
  install.sh --channel prerelease         follow pre-releases instead of stable (test machines)
  install.sh ... --no-validate            skip the cloud check of the key (no outbound HTTPS yet)
  install.sh --repo-only                  only register the repository, install nothing
  install.sh --uninstall                  remove the package (keeps config and data)

Regions: de (app.cinify.io), ch (app.cinify.ch), dev (internal test system)
Channels: stable (default, what is rolled out), prerelease (every build of main, before rollout)

Re-running with another --channel switches the machine over. apt and dnf never downgrade, so going
from prerelease back to stable keeps the installed version until stable passes it.
EOF
}

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--key)      KEY=${2:-}; shift 2 ;;
		--key=*)    KEY=${1#--key=}; shift ;;
		--region)   REGION=${2:-}; shift 2 ;;
		--region=*) REGION=${1#--region=}; shift ;;
		--channel)   CHANNEL=${2:-}; shift 2 ;;
		--channel=*) CHANNEL=${1#--channel=}; shift ;;
		--repo-only) REPO_ONLY=1; shift ;;
		--no-validate) NO_VALIDATE=1; shift ;;
		--uninstall) UNINSTALL=1; shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          usage >&2; die "unknown argument: $1" ;;
	esac
done

case "$CHANNEL" in
	stable)     REPO_FILE=cinify.repo ;;
	prerelease) REPO_FILE=cinify-prerelease.repo ;;
	*)          usage >&2; die "unknown channel '$CHANNEL' — use stable or prerelease" ;;
esac

# ---------------------------------------------------------------------------------------------
# Pre-flight. Every check here is one the customer would otherwise hit as a confusing failure
# ten minutes later.
# ---------------------------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "please run this with sudo (it installs a system service)"

ARCH=$(uname -m)
case "$ARCH" in
	x86_64|amd64) : ;;
	*) die "unsupported architecture '$ARCH' — the cinify Gate packages are built for x86_64" ;;
esac

[ -r /etc/os-release ] || die "cannot read /etc/os-release — unsupported distribution"
# shellcheck disable=SC1091
. /etc/os-release
say "detected ${PRETTY_NAME:-$ID} ($ARCH)"

if command -v apt-get >/dev/null 2>&1; then
	FAMILY=deb
elif command -v dnf >/dev/null 2>&1; then
	FAMILY=rpm
else
	die "no supported package manager found (apt-get or dnf) — the cinify Gate packages are built
for Debian, Ubuntu, Fedora and RHEL-compatible distributions.
Install the Gate from the tarball instead — see ${BASE_URL}/README.md"
fi

if [ "$UNINSTALL" = "1" ]; then
	say "removing the cinify-gate package (configuration and data are kept)"
	case "$FAMILY" in
		deb) apt-get remove -y cinify-gate ;;
		rpm) dnf remove -y cinify-gate ;;
	esac
	echo "Removed. /etc/cinify-gate/env and /var/lib/cinify-gate were left in place."
	exit 0
fi

# A Gate that cannot reach its region is installable but useless, and the failure looks like a
# broken install rather than a blocked network. Say so now.
if command -v curl >/dev/null 2>&1; then
	curl -fsS --max-time 10 -o /dev/null "$BASE_URL/cinify.gpg" 2>/dev/null || \
		warn "cannot reach $BASE_URL — check the proxy or firewall on this machine"
fi

# ---------------------------------------------------------------------------------------------
# Register the repository. Idempotent: re-running overwrites the same files, which is also how a
# machine changes channel. The package itself comes THROUGH the package manager, so apt/dnf check
# its signature against the key registered here, however this script reached the machine.
# ---------------------------------------------------------------------------------------------
case "$FAMILY" in
deb)
	say "registering the cinify apt repository (channel: $CHANNEL)"
	command -v curl >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y --no-install-recommends curl ca-certificates; }
	install -d -m 0755 /usr/share/keyrings
	curl -fsSL "$BASE_URL/cinify.gpg" -o /usr/share/keyrings/cinify.gpg
	chmod 0644 /usr/share/keyrings/cinify.gpg
	printf 'deb [signed-by=/usr/share/keyrings/cinify.gpg] %s/deb %s main\n' "$BASE_URL" "$CHANNEL" \
		> /etc/apt/sources.list.d/cinify.list
	;;
rpm)
	say "registering the cinify dnf repository (channel: $CHANNEL)"
	command -v curl >/dev/null 2>&1 || dnf install -y curl
	# Both channel files carry the repo id [cinify-gate], so writing one replaces the other.
	curl -fsSL "$BASE_URL/$REPO_FILE" -o /etc/yum.repos.d/cinify.repo
	chmod 0644 /etc/yum.repos.d/cinify.repo
	# Fetched with curl rather than handed to rpm as a URL: rpm's own fetcher ignores the proxy
	# settings curl honours, and does not do file:// at all.
	KEYFILE=$(mktemp)
	curl -fsSL "$BASE_URL/cinify.asc" -o "$KEYFILE"
	rpm --import "$KEYFILE"
	rm -f "$KEYFILE"
	# dnf5 keeps repository keys apart from the rpm keyring: on the first refresh it reports
	# "repomd.xml GPG signature verification error: Signing key not found", imports the key from
	# gpgkey= and verifies again. That one line is expected; a failed install is not.
	;;
esac

if [ "$REPO_ONLY" = "1" ]; then
	echo "Repository registered. Install with your package manager when ready: cinify-gate"
	exit 0
fi

say "installing cinify-gate"
case "$FAMILY" in
deb)
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y cinify-gate
	;;
rpm)
	dnf install -y --refresh cinify-gate
	;;
esac

# ---------------------------------------------------------------------------------------------
# Configure. Delegated to the packaged command so there is exactly one implementation of the key
# validation and of the env-file rewrite.
# ---------------------------------------------------------------------------------------------
say "configuring this machine"
set -- --key "$KEY"
[ -n "$REGION" ] && set -- "$@" --region "$REGION"
[ -n "$KEY" ] || set --      # no key given: let cinify-gate-configure ask interactively
[ "$NO_VALIDATE" = "1" ] && set -- "$@" --no-validate
cinify-gate-configure "$@"

cat <<EOF

cinify Gate is installed.

  Status         : systemctl status cinify-gate
  Logs           : journalctl -u cinify-gate -f
  Reconfigure    : sudo cinify-gate-configure --key "<API-KEY>;<REGION>" --force
  Update now     : sudo cinify-gate-update
  Automatic      : nightly, via cinify-gate-update.timer
  Channel        : $CHANNEL

EOF
