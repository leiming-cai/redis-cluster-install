# Redis Cluster Install Scripts

One-shot Bash suite to deploy a 6-node Redis 8.8.0 cluster (3 master + 3 replica)
across two Linux machines over SSH password authentication, compiled from a local
source tarball.

## Prerequisites

On the **control machine** (where you run the scripts):

- Bash 4+
- `sshpass`
- `openssh-client`
- The local file `redis-8.8.0.tar.gz` in this repo's root

On each **target node** (A and B):

- Linux with `gcc >= 11`, `make`, `g++`, `tar`
- `ulimit -n >= 10001` (cluster bus needs it)
- SSH server running, port reachable
- Firewall open: 6379-6384 (Redis) and 16379-16384 (cluster bus)

## Quick start

```bash
# 1. Run the installer (interactive)
bash install.sh

# You will be prompted for:
#   - A and B node IP / SSH user / SSH port / SSH password
# The script will:
#   - compile Redis on both nodes
#   - create a 'redis' system user
#   - render and push 6 instance configs
#   - render and push 6 systemd units
#   - start all instances
#   - create the cluster (3 master + 3 replica)

# 2. Check status
bash status.sh

# 3. Tear it down
bash uninstall.sh --dry-run   # preview
bash uninstall.sh --force     # actually delete
```

## Layout

| Path | Purpose |
|---|---|
| `install.sh` | Main installer (interactive) |
| `status.sh` | Cluster health, role table, slot distribution |
| `uninstall.sh` | Stop services, backup data, remove configs |
| `add-node.sh` | Add a new instance to an existing cluster |
| `lib/` | Helpers: `common.sh`, `password.sh`, `prompt.sh`, `ssh.sh`, `config_gen.sh`, `systemd.sh`, `cluster.sh` |
| `config/` | `redis.conf.template`, `redis-cluster.service.template` |
| `secrets/cluster_password.txt` | Generated `requirepass` / `masterauth` (0600) |
| `tests/` | bats unit tests |
| `scripts/smoke-test.sh` | Docker-based end-to-end |
| `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md` | Design |

## Tests

```bash
# Unit tests (bats required)
bats tests/

# End-to-end (docker required)
bash scripts/smoke-test.sh
```

## Architecture

- 6 instances total: A (6379, 6380, 6381), B (6382, 6383, 6384)
- Roles auto-assigned by `redis-cli --cluster create --cluster-replicas 1`
- All 6 instances share the same `requirepass` (auto-generated, 32 chars)
- Persistence: RDB (default savepoints) + AOF (`appendfsync everysec`)

## Known limitations

- No Sentinel (Redis cluster handles failover natively)
- No TLS / ACL
- No monitoring / alerting
- Not Windows-native; use WSL on Windows
- Requires SSH password; for SSH keys, edit `lib/ssh.sh` to drop the `sshpass -e` wrapping

## Spec

See `docs/superpowers/specs/2026-07-07-redis-cluster-install-design.md`.
