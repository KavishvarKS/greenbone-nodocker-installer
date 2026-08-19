# greenbone - NO DOCKER - installer

One-shot bash script to build and install **Greenbone Community Edition (OpenVAS / GVM)** from source on **Ubuntu 24.04**, with no Docker involved. Every build issue hit while testing on a real VM (missing static libs, wrong systemd listen addresses, permission errors, stale locks, etc.) is already fixed in the script.

## What you get

A fully working local Greenbone stack:
- `gvmd` — the vulnerability manager daemon
- `gsad` — the web UI (GSA), served on port `9392`
- `ospd-openvas` + `openvas-scanner` — the actual scan engine
- `openvasd` — Rust-based scanner daemon (with statically linked krb5)
- PostgreSQL backend, Redis cache, admin user, and a full NVT/SCAP/CERT feed sync

All built from official Greenbone source tarballs/releases — not the Docker Compose distribution.

## Requirements

- Ubuntu 24.04 LTS (fresh VM recommended)
- A regular sudo-capable user (**not** root directly)
- `tmux` or `screen` — this is a **45–90+ minute** build (Rust + krb5 + feed sync are the slow parts)
- Decent disk space (feed data alone is several GB) and a stable internet connection

## Usage

```bash
chmod +x install-greenbone-source.sh
tmux new -s greenbone
./install-greenbone-source.sh
```

The script will interactively ask for:
1. **Admin account password** (used to log into the GSA web UI)
2. **GSA listen address** — `127.0.0.1` (local only, safer) or `0.0.0.0` (reachable on the VM's IP directly, plaintext HTTP — you'll be asked to confirm)

If you get disconnected from SSH, `tmux attach -t greenbone` to reconnect to the running build.

## After install

```
Log in at: http://<listen-address>:9392
Username: admin
Password: (the one you set)
```

First-time NVT database load can continue in the background after the script finishes — watch it with:
```bash
sudo tail -f /var/log/gvm/gvmd.log
```

To add another user later:
```bash
sudo -u gvm /usr/local/sbin/gvmd --create-user=USERNAME --password='PASSWORD' --role="Admin"
```

## Files

| File | Purpose |
|---|---|
| `install-greenbone-source.sh` | The installer itself — run this |
| `SCRIPT_EXPLAINED.md` | Step-by-step breakdown of what the script does and why, for reference/debugging |

## Notes

- Re-running the script is safe — it hard-resets build directories and skips steps that already succeeded (existing DB, existing admin user, etc.)
- Component versions are pinned as of **Aug 2026** inside the script. Before reusing this months later, check [Greenbone's GitHub releases](https://github.com/greenbone) — `gsa`/`gsad` minimum-version pairing is the thing most likely to drift.
- Scan configuration (adding targets, credentials, running scans) is a separate topic covered in your own scanning notes — this repo only covers getting the server itself running.
