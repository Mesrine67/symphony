# Local Dokploy deployment

This fork targets the single local Dokploy instance running in WSL. The stack has one replica, no
published ports, and no Docker socket mount. The container health check and startup output are
available in Dokploy; rotated runtime logs persist under `/app/log` in the `symphony-logs` volume.
The dashboard binds only to the container's loopback interface.

## Storage

- Issue workspaces use `D:\SymphonyData\workspaces`, mounted in the container at `/workspaces`.
- The Codex ChatGPT login lives in the named `symphony-codex-home` volume on Dokploy's WSL disk.
- The pnpm/Corepack package cache lives in `symphony-package-cache` on the same WSL disk.
- Rotated application logs live in the `symphony-logs` volume mounted at `/app/log`.
- Docker image layers and named volumes are stored with Dokploy's WSL data. Keep the external
  `INATECK_STORAGE_1` drive connected while Docker is running.

## Dokploy setup

Create a Compose Stack from this repository with these values:

- Repository: `https://github.com/Mesrine67/symphony.git`
- Branch: `codex/dokploy-symphony-service` until that branch is merged; then use `main`.
- Compose file: `deploy/docker-compose.yml`
- Do not create a public domain or publish port 4000.
- Keep exactly one replica; orchestrator state is in memory.

Before the service can run, set these variables in Dokploy's Compose environment editor:

- `LINEAR_API_KEY`: a Linear API key that can read and update issues in the MIK team.
- `GITHUB_TOKEN`: a fine-grained token scoped only to `Mesrine67/hebergtonserv-desktop`, with
  Contents read/write and Pull requests read/write. Repository metadata access is required by GitHub
  and is read-only. The target repository is public, so Symphony reads CI checks anonymously and the
  token does not need the Checks permission.

The entrypoint exits with a short message when either value is missing. It also refuses to start
until `codex login status` succeeds for the persistent CODEX_HOME volume.

## One-time ChatGPT login

After Dokploy has built `symphony-elixir:codex-0.172.0` and created the named volume, run this in
the Dokploy WSL terminal. Enable device-code login in ChatGPT security settings if it is not
already available. Complete the device login in the browser; the one-time code should not be posted
in Linear, GitHub, or chat.

```sh
docker run --rm -it \
  -e CODEX_HOME=/var/lib/codex \
  -v symphony-codex-home:/var/lib/codex \
  --entrypoint codex symphony-elixir:codex-0.172.0 login --device-auth
```

Then confirm authentication without printing the credential file:

```sh
docker run --rm \
  -e CODEX_HOME=/var/lib/codex \
  -v symphony-codex-home:/var/lib/codex \
  --entrypoint codex symphony-elixir:codex-0.172.0 login status
```

The Codex app-server version is pinned to `0.172.0`. Dynamic tools and named permission profiles
are experimental App Server APIs in that release. The service opts into `experimentalApi`; startup
fails closed if Codex cannot load the configured `symphony-workspace` profile.

## Workflow

- Linear project: `Symphony` (`symphony-5a4574e2a90e`), team MIK.
- Eligible states: `Todo`, `In Progress`; handoff: `In Review`; terminal: `Done`, `Canceled`,
  `Duplicate`; `Backlog` is ignored.
- The publisher creates `symphony/<issue-id>` and opens/updates a PR against `main`. It cannot
  merge, target another repository, force-update a branch, or publish more than 50 text files / 512
  KiB in one call.
- PR checks must pass before the issue moves to `In Review`. Rework starts when a person moves the
  issue back to `In Progress`.
- Codex runs with a named `:workspace`-derived permission profile. It cannot read the Codex auth
  volume or secret files in its workspace. Tracker credentials are removed from the app-server and
  shell environment. The sandbox network proxy allows only GitHub, npm, Node.js, and crates.io
  domains.
- The service drops all Linux capabilities. Its container uses `seccomp=unconfined` so Codex's
  Bubblewrap sandbox can create unprivileged user namespaces; this setting applies only to Symphony.
- The target repository's Windows Rust/Tauri check remains on its existing self-hosted runner. The
  Symphony service does not restart or administer that runner.
