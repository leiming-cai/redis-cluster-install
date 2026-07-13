# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| < main  | :x:                |

Only the `main` branch receives security fixes. Please upgrade.

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please report it privately** — do **not** open a public GitHub issue.

Email: **boboclmomi@163.com** (see git log for current author)

Please include:

1. A clear description of the vulnerability
2. Steps to reproduce
3. The commit / version affected (`git log --oneline` on your checkout)
4. Your assessment of the impact (e.g., "any user with SSH access to the target nodes can read cluster auth.conf")

You should expect an initial response within 7 days. We will work with you
on a fix timeline and coordinate disclosure.

## Scope

This project is a **deployment automation tool** that runs as root (via
sudo) on the target hosts. The most likely security concerns are:

- **Credential exposure**: the script handles SSH passwords and the
  cluster `requirepass`. These are passed via stdin / scp / temp files
  with 0600 perms. If you find a path where they leak to a log or
  world-readable file, that's a real bug — please report it.
- **Remote code execution**: `install.sh` runs commands on the target
  nodes over SSH as the SSH user (with `sudo` for privileged ops). Any
  command injection via unsanitized input is a vulnerability.
- **Path traversal / file overwrite**: data + config are written to
  fixed paths under `/opt/software/redis/` and `/etc/redis/cluster/`.
  If a user can influence these paths, that's a vulnerability.
- **Dependency confusion**: the script compiles Redis 8.8.0 from a
  source tarball the user supplies. If the source tarball is replaced
  (MITM on the user's download, or a tampered copy), the compiled
  binary runs as root on the target. Use a verified download
  (e.g., SHA256-checked from redis.io).

## Out of Scope

- Vulnerabilities in the **Redis server itself** — please report
  those upstream at https://github.com/redis/redis/security
- Vulnerabilities in the **target host OS** (kernel, glibc, openssh)
  — report to your distro
