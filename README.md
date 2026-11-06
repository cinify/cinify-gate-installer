# cinify Gate on Linux

The Gate runs as a system service on Linux and is installed from the cinify package repository.
Configuration comes from environment variables (`CINIFY_GATE_ApiKey`, `CINIFY_GATE_ApiRegion`)
instead of the Windows registry; state lives in `/var/lib/cinify-gate`.

## Install — one command

Use the API key from the cinify HUB, in the same `<key>;<region>` form the Windows installer takes:

```bash
curl -fsSL https://cinify.github.io/cinify-gate-installer/install.sh \
  | sudo bash -s -- --key "YOUR-API-KEY;de"
```

That registers the signed cinify repository, installs the `cinify-gate` package through the
machine's own package manager, validates the key against the cloud and starts the service.
Supported: Debian 12+, Ubuntu 22.04+, Fedora, RHEL/Alma/Rocky 9+ (x86_64).

Run it without `--key` to be asked interactively, or with `--repo-only` to just register the
repository. `--no-validate` skips the cloud check of the key, for a machine without outbound HTTPS
yet.

## Channels: stable and prerelease

| Channel | Gets | For |
|---|---|---|
| `stable` (default) | versions that were promoted, the same that Windows Gates install | customer machines |
| `prerelease` | every build of `main`, before it is promoted | test machines |

```bash
curl -fsSL https://cinify.github.io/cinify-gate-installer/install.sh \
  | sudo bash -s -- --channel prerelease --key "YOUR-API-KEY;de"
```

Running it again with the other `--channel` (add `--repo-only` to leave the configuration alone)
switches the machine. **apt and dnf never downgrade**: going from prerelease back to stable, or a
rollback of a version the machine already took, leaves the installed version in place until a higher
one reaches the channel.

## Install — by package manager

<details>
<summary>Debian / Ubuntu</summary>

```bash
curl -fsSL https://cinify.github.io/cinify-gate-installer/cinify.gpg \
  | sudo tee /usr/share/keyrings/cinify.gpg >/dev/null
# "stable" — or "prerelease" for a test machine
echo "deb [signed-by=/usr/share/keyrings/cinify.gpg] https://cinify.github.io/cinify-gate-installer/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/cinify.list
sudo apt update && sudo apt install cinify-gate
sudo cinify-gate-configure --key "YOUR-API-KEY;de"
```
</details>

<details>
<summary>Fedora / RHEL / Alma / Rocky</summary>

```bash
# cinify.repo is the stable channel; cinify-prerelease.repo the prerelease one
sudo curl -fsSL -o /etc/yum.repos.d/cinify.repo \
  https://cinify.github.io/cinify-gate-installer/cinify.repo
sudo dnf install cinify-gate
sudo cinify-gate-configure --key "YOUR-API-KEY;de"
```
</details>

## Local keys (optional)

Columns can be protected with a customer-owned local key — a password cinify never receives (see
`docs/lokaler-schluessel.md`). On Linux each key is a file named `LocalKey_<key id>` in
`/etc/cinify-gate/local-keys` (or the directory in `CINIFY_GATE_LocalKeyDirectory`, e.g. `/run/secrets` in
a container). The Gate refuses a file that anyone but its owner can access:

```bash
sudo mkdir -p /etc/cinify-gate/local-keys
sudo tee /etc/cinify-gate/local-keys/LocalKey_11111111-2222-3333-4444-555555555555 >/dev/null <<'EOF'
{"v":1,"password":"<password>","check":"0ed4-499d-0a2e-9b23"}
EOF
sudo chown -R cinify-gate:cinify-gate /etc/cinify-gate/local-keys
sudo chmod 700 /etc/cinify-gate/local-keys
sudo chmod 600 /etc/cinify-gate/local-keys/*
```

The key id and the check value are shown by cinify when the key is created. As a Docker secret, mount it
with `mode: 0400`; the default `0444` is rejected.

## Everyday commands

| | |
|---|---|
| Status | `systemctl status cinify-gate` |
| Logs | `journalctl -u cinify-gate -f` |
| Show configuration | `sudo cinify-gate-configure --show` |
| Change key / region | `sudo cinify-gate-configure --key "NEW-KEY;ch" --force` |
| Re-check the stored key | `sudo cinify-gate-configure --test` |
| Update now | `sudo cinify-gate-update` |
| Uninstall (keeps data) | `sudo apt remove cinify-gate` / `sudo dnf remove cinify-gate` |
| Follow a self-uninstall | `journalctl -u cinify-gate-uninstall` |

## Updates

Three paths, all ending in the same package transaction:

1. **Nightly, by default** — `cinify-gate-update.timer` runs at 03:00 (randomised by up to an
   hour) and installs whatever the repository offers.
2. **Cloud-triggered** — the `ForceUpdate` command from the cinify HUB. The Gate itself is
   unprivileged, so it touches `/run/cinify-gate/update-requested`; `cinify-gate-update.path` then
   runs the root-owned `cinify-gate-update.service`.
3. **The distro's own mechanism** — `unattended-upgrades` (the package ships a matching origin
   rule at `/etc/apt/apt.conf.d/51cinify-gate-updates`, scoped to the cinify repository only) or
   `dnf-automatic`, where the admin already relies on it.

If an update was requested but the service is still on the old version after a few minutes, the Gate
reports that to the HUB once and points at `journalctl -u cinify-gate-update`, where the package
manager's own output is. There is no second installer path on Linux to fall back to.

Because the package manager is a separate process from the service, it replaces the binaries of a
running Gate and its post-install step puts the service back — there is no self-replace dance.

When the HUB pauses updates, the Gate writes `updates-paused` into its data directory
(`/var/lib/cinify-gate/updates-paused` unless `CINIFY_GATE_DataDir` says otherwise), and
`cinify-gate-update` does nothing until it is resumed — the nightly timer, the cloud-triggered
path and a manual `sudo cinify-gate-update` alike.

Path 3 is the exception: it runs on the distro's schedule and never looks at the flag, so a paused
Gate can still be upgraded through it. On Linux the admin owns the machine's update policy, so that
is the intended trade — delete `/etc/apt/apt.conf.d/51cinify-gate-updates` on a machine where the
HUB's pause should be the last word.

## In a container

The image `ghcr.io/cinify/cinify-gate` (`:latest` is the promoted release, `:prerelease` every build
of `main`) runs the same binaries as the packages, without systemd. Its data lives in the `/data`
volume, it needs a restart policy, and *Update erzwingen* restarts it onto a newer image instead of
running a package manager — through `imagePullPolicy: Always` in Kubernetes, or through an update hook
(`CINIFY_GATE_ContainerUpdateUrl`) for Docker and Podman. Details:
[`docker/README-build-your-own.md`](https://github.com/cinify/cinify-gate/blob/main/docker/README-build-your-own.md).

## Working directory set from the cinify HUB

The HUB can point a Gate's working (temp) directory elsewhere. Off Windows `TempDir` is the environment
variable `CINIFY_GATE_TempDir`, which the Gate cannot change for its next start, so the Gate keeps the HUB's
choice in `TempDir.cloud` in the data root and uses it from the next restart on. While that file exists it
**outranks** `CINIFY_GATE_TempDir` — changing the variable has no effect until the file is deleted. In a
container the file lies in the `/data` volume; without a volume it is lost with the container, and the Gate
falls back to the variable.

## Self-uninstall from the cinify HUB

The HUB's `SelfUninstall` command removes the Gate a week after it was sent; until then
`SelfUninstallCancel` takes it back. At the deadline the Gate tells the cloud, stops its tasks and
— being unprivileged — touches `/run/cinify-gate/uninstall-requested`. `cinify-gate-uninstall.path`
then starts the root-owned `cinify-gate-uninstall.service`, which takes the marker as its
acknowledgement and

1. stops the Gate and its update units,
2. purges the package (`apt-get purge` / `dnf remove`),
3. deletes `/etc/cinify-gate` (API key, env file, local keys), `/var/lib/cinify-gate` and
   `/usr/lib/cinify-gate`,
4. in a `DataDir`, `TempDir` or `LogDir` pointed elsewhere, deletes only the Gate's own files and the
   directory only if that left it empty — never `/`, `/etc`, `/home`, `/var`, `/var/lib` or another
   system directory,
5. removes the package source (`cinify.list`, `cinify.gpg`, `cinify.repo`) and the `cinify-gate` user.

The unit trusts nothing but the marker's existence and the root-owned `/etc/cinify-gate/env`. If the
package transaction fails, it switches the Gate back on — the update timer and path only if they were
enabled and running before, so an admin's choice survives — and leaves `uninstall-failed` in the data
directory; the Gate reports that once and tries again an hour later. If nothing takes the marker
within 30 s — an installation upgraded but never restarted, so the watcher is not running yet — the
Gate keeps its key, stays suspended and also retries hourly. Everything the unit did is in
`journalctl -u cinify-gate-uninstall`.

Two things to know before it runs:

- **The local keys go with it.** `/etc/cinify-gate/local-keys` is deleted, and the cloud knows only each
  key's id and name. Columns pseudonymised with those keys will not match values hashed with a key of a
  reinstalled Gate; keep a copy of the keys if the data must still join.
- **The marker is the only trigger.** The `cinify-gate` user can create it, so code running as that user
  can start the removal without waiting for the deadline (it can already delete the Gate's data). The
  update path has the same shape. Closing it needs a cloud-signed request that root can verify.

## Requirements

- x86_64. No .NET runtime needed: the payload is published `--self-contained` as a single file,
  so the runtime sits inside `/usr/lib/cinify-gate/Service`. An installed `dotnet` is neither
  used nor in the way.
- **ICU and OpenSSL** stay the host's: `libicu` and `libssl` come from the distribution, not from
  the bundle. The packages depend on both (`libicu`, `libssl3` on deb, the `libssl.so.3` soname on rpm), so a missing
  library is an install-time error rather than a startup crash or a failing TLS handshake. A hand-built minimal container image may have neither, and the service
  then exits at startup naming the missing library.
- **ODBC tasks** need `unixODBC` plus the driver for the customer's database, registered in
  `/etc/odbcinst.ini`. The driver name in the cloud's connection string must match what is
  installed locally. The Gate only *recommends* `unixodbc`, so nothing database-specific is pulled
  onto a machine that does not need it.
- Outbound HTTPS to the region host (`app.cinify.io`, `app.cinify.ch`) and to
  `cinify.github.io` for updates.

## Files

| Path | |
|---|---|
| `/usr/lib/cinify-gate/` | binaries (self-contained) |
| `/etc/cinify-gate/env` | API key, region, data directory — created on first install from `/usr/share/cinify-gate/env.template` and never touched again, not by an upgrade and not by a removal |
| `/var/lib/cinify-gate/` | SQLite database, pending uploads, and the daily log files in `Logs/` |
| `/usr/lib/systemd/system/cinify-gate*.{service,timer,path}` | service, update and self-uninstall units |
| `/usr/lib/cinify-gate/cinify-gate-uninstall` | the root script the cloud's self-uninstall runs |

**Changed: log folder.** The daily log files are now written to `<data directory>/Logs` (by default
`/var/lib/cinify-gate/Logs`, in the container `/data/Logs`). Earlier versions wrote them to `Logs`
next to the binaries, where the service user has no write access — so on those versions the daily
files never appeared (the log in `journalctl` was unaffected). Files left in the old folder are not
moved; the Gate's log download in the HUB looks in both.

## Manual installation without the repository

For air-gapped machines: download `cinifyGate_<version>_linux-x64.tar.gz` or the `.deb`/`.rpm`
from the [releases](https://github.com/cinify/cinify-gate-installer/releases) — every version stays
there, while the repository itself carries only the newest three — then either
`sudo apt install ./cinify-gate_<version>_amd64.deb` (recommended — the maintainer scripts still
run) or extract the tarball to `/usr/lib/cinify-gate` — the bundled `cinify-gate.service` starts the
Gate from there — install that unit to `/usr/lib/systemd/system/`, create the `cinify-gate` system user
and write `/etc/cinify-gate/env` by hand, then run
`systemctl daemon-reload && systemctl enable --now cinify-gate`. The tarball route gets no automatic updates.

## Moving a tarball installation to the package

Gates set up from the tarball before the packages existed run from `/opt/cinify-gate`, through a
unit the admin copied to `/etc/systemd/system/cinify-gate.service`. Installing the package (one
command or package manager, as above) takes that machine over:

- The package recognises exactly that unit by its `ExecStart=/opt/cinify-gate/Service`, stops the
  old Gate, disables the unit and renames it to `cinify-gate.service.pre-package`. A unit in
  `/etc/systemd/system` would otherwise shadow the packaged one, and the machine would keep running
  the old binary and never receive an update.
- The packaged Gate then starts with the existing `/etc/cinify-gate/env` and the existing
  `/var/lib/cinify-gate` — same key, same database, same upload watermarks, so nothing is uploaded
  again. An env file without a `CINIFY_GATE_DataDir` line keeps working: the packaged unit defaults it
  to `/var/lib/cinify-gate`.
- `/opt/cinify-gate` is not touched. Once `systemctl status cinify-gate` shows
  `/usr/lib/cinify-gate/Service`, remove it with `sudo rm -rf /opt/cinify-gate`.

A unit in `/etc/systemd/system` that does **not** start `/opt/cinify-gate/Service` is left exactly as
it is; the install only prints a warning. Remove it yourself
(`sudo rm /etc/systemd/system/cinify-gate.service && sudo systemctl daemon-reload`) to run the packaged
Gate.
