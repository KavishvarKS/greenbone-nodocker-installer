# Script Explained

A step-by-step walkthrough of `install-greenbone-source.sh` — what each part does and, more importantly, **why** it's written the way it is. Every workaround here exists because it fixed a real failure encountered while building on a live VM.

## Interactive prompts (top of script)

- Asks for the admin password twice and confirms they match — fails fast rather than creating an account with a typo'd password.
- Asks whether GSA (the web UI) should listen on `127.0.0.1` (local-only) or `0.0.0.0` (open on the VM's IP). Choosing global mode triggers a warning because GSA is started with `--http-only` (no TLS) — anyone who can reach port `9392` could sniff the login in plaintext, so you have to type `YES` to confirm.

## Version pinning

All component versions (`gvm-libs`, `gvmd`, `gsa`, `gsad`, `openvas-scanner`, etc.) are set as fixed variables near the top. This is a **mutually-compatible set as of Aug 2026** — GSA 28.x specifically needs `gsad >= 27.0.0`, which needs `gvm-libs >= 22.38`. Version mismatches here are the #1 cause of build failures with Greenbone from source, so don't bump one version without checking the others.

## Step -1: Stop existing services

Stops `gsad`, `gvmd`, `ospd-openvas`, `openvasd` before doing anything. Prevents "Text file busy" errors when overwriting binaries that are currently running.

## Step 0: gvm system user

Creates the `gvm` user/group (no login shell, no home dir needed for login) and adds your current user to the `gvm` group so you can interact with its files without `sudo` every time.

## Steps 2–10: Build each component in dependency order

Each component follows the same pattern:
1. `rm -rf` any previous source/build/install directory for that component — **critical**, because re-running `cmake --build` against a stale build directory silently rebuilds the *old* source and quietly ignores version bumps you made at the top of the script.
2. Download the official release tarball from GitHub
3. Extract, `cmake` configure, build, install to a staging `DESTDIR`, then `cp -rv` into the real system paths

Build order matters because each one links against the previous:
1. **gvm-libs** — the shared library everything else depends on. Verified with `pkg-config --modversion` right after install — if the version pkg-config sees doesn't match what was just built, the script dies immediately instead of letting a mismatch silently break later builds.
2. **gvmd** — the vulnerability manager daemon
3. **pg-gvm** — PostgreSQL extension gvmd needs
4. **GSA + gsad** — web UI static files + the daemon that serves them
5. **openvas-smb** *(optional)* — Windows/SMB scanning support
6. **openvas-scanner** (C/CMake part) — the actual scan engine; also writes `/etc/openvas/openvas.conf`
7. **ospd-openvas** — Python wrapper daemon that bridges `gvmd` and the scanner, installed via `pip install --root=... `into a staging dir first, then copied to `/`

## Step 11: Static krb5 + libpcap for the Rust build

This is the trickiest part of the whole script. `openvasd` (the Rust daemon) needs **krb5 statically linked**. Nothing outside Greenbone's own internal Docker build pipeline provides that, so the script builds static `krb5` and `libpcap` itself from their **official release tarballs** — specifically *not* GitHub's auto-generated tag archives, because those don't ship a pre-generated `./configure` script for autotools-based projects and fail immediately.

`libpcap` is built with `--disable-rdma`. Without that flag, `libpcap`'s build auto-detects `libibverbs` (InfiniBand/RDMA support) if present on the build host and links against it — which then fails at the final Rust link step with undefined `ibv_*` symbols. Greenbone's own Docker builder never hits this because their build image doesn't have `libibverbs` installed at all.

The resulting static libs and headers are cached in `$HOME/archives` — if that directory already exists, the script skips rebuilding it (delete the dir to force a rebuild).

## Step 11b: Rust build (openvasd, scannerctl)

- Detects and removes an apt-installed `rustup` if present (known to conflict) and installs the official version via `rustup.rs` instead.
- Builds `openvasd` and `scannerctl` with `cargo build --release`, pointing at the static krb5/libpcap archive from Step 11 via `OPENVAS_ARCHIVES` and `LIBPCAP_LIBDIR` env vars.
- Verifies the binary actually exists before continuing — no silent failures.

## Step 12: greenbone-feed-sync + gvm-tools

Installs the Python tools used for pulling vulnerability feed data (NVT/SCAP/CERT/GVMD_DATA) and for CLI/API interaction with gvmd.

## Step 13: Redis

OpenVAS scanner uses Redis as a fast key-value store during scans. Installed, configured with Greenbone's own `redis-openvas.conf`, and pointed at via a Unix socket in `openvas.conf`.

## Step 14: Permissions — done *before* any service starts

This step exists because of a real failure mode: if `gsad`/`gvmd` are started before their log/data directories are `chown`'d to the `gvm` user, they **silently die** with "Permission denied" trying to write their own logs, and give no obvious error in the terminal. Ownership and group read/write bits (`g+srw`) are set on all the relevant `/var/lib` and `/var/log` paths here, ahead of everything else.

## Step 15: Feed validation keyring

Imports Greenbone's GPG signing key into a dedicated keyring under `/etc/openvas/gnupg`, owned by `gvm`. Feed syncs are signature-verified against this — without it, `greenbone-feed-sync` can't confirm the downloaded feed data is authentic.

## Step 16: Sudoers entry

Allows the `gvm` group to run the `openvas` scanner binary as root without a password prompt — required because certain scan types (SYN scans, raw sockets) need elevated privileges, and the scan engine itself runs as the unprivileged `gvm` user.

## Step 17: PostgreSQL

- Detects an existing cluster or creates one.
- Waits (up to 30s, polling `pg_isready`) for PostgreSQL to actually accept connections before continuing — avoids a race condition where later steps try to connect before the DB is up.
- Creates the `gvm` role and `gvmd` database if they don't already exist (idempotent — safe to re-run).
- Grants a `dba` superuser role to `gvm` inside that database only (not superuser on the whole cluster).

## Step 17b: Stale semaphore cleanup

System V semaphores left behind by a previous crashed/killed run (owned by a different user) can block PostgreSQL or gvmd from starting cleanly. This step finds and removes any semaphores not owned by the `gvm` user before continuing.

## Step 18: Admin user

Checks if an `admin` user already exists (via `gvmd --get-users`) — if so, just resets its password instead of failing on a duplicate-user error. Verifies the user actually exists afterward rather than assuming the command succeeded.

## Step 19: Feed Import Owner

Sets the `admin` user as the owner of feed-imported objects (scan configs, port lists, etc.) via a fixed setting UUID (`78eceaec-...`) that gvmd uses internally for this setting. Without this, feed-synced objects can end up ownerless.

## Step 20: Custom systemd unit files

This is a subtle but important fix: `gvmd`/`gsad`'s own `make install` step drops **default** systemd unit files under `/usr/local/lib/systemd/system/`, which only listen on `127.0.0.1`. If you `systemctl enable` before this script writes its own units to `/etc/systemd/system/`, the default ones silently win due to systemd's path precedence — and your `0.0.0.0` choice from the interactive prompt would be ignored with no error. So the script writes its own versions directly to `/etc/systemd/system/` (which takes priority), wiring in the listen address you chose, correct socket paths, and service dependencies (`gsad` waits on `gvmd`, `gvmd` waits on `ospd-openvas`, etc.).

## Step 21: Feed sync

Runs `greenbone-feed-sync` to pull NVT, SCAP, CERT, and GVMD_DATA feeds. Before running, it clears any stale lock files (`feed-update.lock`) left behind by a previous interrupted run — but only if no sync process is actually still running, checked via `pgrep`. This step is the single longest part of the whole install; the comment in the script explicitly warns not to `Ctrl+C` it.

## Step 22: Start and enable services

Starts services in dependency order with short sleeps between each (`openvasd` → `ospd-openvas` → `gvmd` → `gsad`), then does a final pass checking `systemctl is-active` on all four and reports RUNNING/NOT RUNNING for each — so you get a clear pass/fail summary instead of having to check manually.

## Final output

Prints the login URL, admin username, a reminder that NVT data can still be loading into the database in the background, and the command to add additional users later.
