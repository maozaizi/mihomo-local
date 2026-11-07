# Security policy

Please report vulnerabilities privately through this repository's GitHub
Security Advisories (Report a vulnerability). If private reporting is not
available, open an issue asking for a private reporting channel, without
including exploit details, subscriptions, node credentials, logs or private keys.

This project manages credentials on the installed machine. Do not commit
`/etc/mihomo-local/config.yaml`, `/var/lib/mihomo-local/state`, providers,
Shell environment dumps, or operational logs. The repository includes only
synthetic test fixtures and public upstream rule/WebUI assets.

- Proxy and controller listen on loopback only. Never expose them publicly.
- The controller key is independently generated during initialization.
- Subscription updates do not accept remote routing/DNS/listener configuration.
- Downloads require HTTPS and certificate validation; release binaries are
  verified against GitHub asset digests. The self-contained checksum manifest
  detects corruption, not a malicious replacement of both files and manifest.
- The core uses an unprivileged service UID with no network-management capabilities.
- The core may write only its selection cache. Config, provider and rule parents
  are root-owned; privileged updaters do not trust daemon-writable directories.
- Shell proxy toggles affect applications that honor the proxy variables.
  Other users' shells, existing processes, system services and containers are
  not transparently intercepted.

Only the latest release receives fixes. A source audit is a point-in-time
review, not a guarantee that no vulnerabilities exist. See SECURITY_AUDIT.md
and VALIDATION.md for coverage and outstanding deployment validation.
