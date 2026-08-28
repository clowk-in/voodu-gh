# voodu-gh

Deploy to a [Voodu](https://voodu.clowk.in/) server from GitHub Actions. It
installs the `voodu` CLI, wires up SSH, and runs `vd apply` — the same thing
you would run from your laptop.

```yaml
name: deploy

on:
  push:
    branches: [main]
    tags: ['v*']

env:
  VOODU_HOST:        ${{ secrets.VOODU_HOST }}
  VOODU_SSH_KEY:     ${{ secrets.VOODU_SSH_KEY }}
  VOODU_KNOWN_HOSTS: ${{ secrets.VOODU_KNOWN_HOSTS }}
  VOODU_VERSION:     v0.9.3

concurrency:
  group: voodu-deploy-production
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4

      - uses: clowk-in/voodu-gh@v1
        with:
          manifests: |
            infra/web.voodu
            infra/pwa.voodu
```

## Shared configuration

Every input falls back to an environment variable. Declare the values that do
not change once at the workflow (or job) level, and each step keeps only what
is actually different:

```yaml
env:
  VOODU_HOST:        ${{ secrets.VOODU_HOST }}
  VOODU_SSH_KEY:     ${{ secrets.VOODU_SSH_KEY }}
  VOODU_KNOWN_HOSTS: ${{ secrets.VOODU_KNOWN_HOSTS }}

jobs:
  deploy:
    steps:
      - uses: actions/checkout@v4
      - uses: clowk-in/voodu-gh@v1
        with: { manifests: infra/web.voodu }
      - uses: clowk-in/voodu-gh@v1
        with: { manifests: infra/pwa.voodu }
```

An explicit `with:` always wins over the environment, so a single step can
point at a different server without disturbing the rest:

```yaml
      - uses: clowk-in/voodu-gh@v1
        with:
          host: ${{ secrets.VOODU_HOST_EU }}
          known-hosts: ${{ secrets.VOODU_KNOWN_HOSTS_EU }}
          manifests: infra/eu.voodu
```

## The SSH target

`host` takes the full `user@hostname`, or just the hostname with `user`
supplied separately — which keeps the user readable in the workflow and
leaves only the address as a secret:

```yaml
env:
  VOODU_USER: ubuntu
  VOODU_HOST: ${{ secrets.VOODU_HOST }}
```

A `host` that already names a user wins, and the `user` input is ignored with
a warning. The port never belongs in `host` — voodu reads everything after
`:` as a path to a key — so use `port:` instead.

## Inputs

| Input | Env fallback | Default | Description |
|---|---|---|---|
| `manifests` | `VOODU_MANIFESTS` | — | Paths, one per line (commas work too). Files, directories, or globs. |
| `host` | `VOODU_HOST` | — | SSH target: `user@hostname`, or just the hostname when `user` is set. |
| `user` | `VOODU_USER` | — | SSH user, when `host` carries only a hostname. |
| `ssh-key` | `VOODU_SSH_KEY` | — | Private key with access to the host. |
| `known-hosts` | `VOODU_KNOWN_HOSTS` | — | Pinned host key from `ssh-keyscan`. Strongly recommended. |
| `port` | `VOODU_PORT` | `22` | SSH port. |
| `version` | `VOODU_VERSION` | latest | CLI version, e.g. `v0.9.3`. |
| `working-directory` | `VOODU_WORKDIR` | `.` | Directory to run from. |
| `remote-name` | `VOODU_REMOTE_NAME` | `voodu` | Git remote name used to carry the SSH target. |
| `dry-run` | `VOODU_DRY_RUN` | `false` | Run `vd diff` instead of `vd apply`. |
| `cache` | `VOODU_CACHE` | `true` | Cache the CLI binary between runs. |
| `github-token` | — | `github.token` | Used only to resolve the latest release. Rarely worth setting. |

Output: `version` — the CLI version that ran.

## Manifests

`-f` is repeatable in the CLI, so every path in `manifests` goes into **one**
invocation: one plan, one apply, one set of SSH round-trips, and resources
across files are reconciled together instead of in independent passes.

```yaml
manifests: |
  infra/web.voodu        # a file — the extension is optional
  infra/jobs/            # a directory, walked recursively
  infra/regions/*.voodu  # a glob
```

Deploying several manifests to the **same** host is better done in one step
than in several. Reach for several steps when the targets differ.

## Passing values into a manifest

Manifests interpolate `${VAR}` from the environment, which is how a build gets
pinned to the commit that triggered it:

```yaml
      - uses: clowk-in/voodu-gh@v1
        env:
          IMAGE_TAG: ${{ github.sha }}
        with:
          manifests: infra/web.voodu
```

Pinning the tag also sidesteps a real footgun: `apply` does not re-pull
`:latest` from a registry, so a moving tag can silently deploy nothing.

## Plan on pull requests

`dry-run` runs `vd diff` and changes nothing, so a reviewer sees the plan
before the merge applies it:

```yaml
on: [pull_request]

concurrency:
  group: voodu-plan-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: clowk-in/voodu-gh@v1
        with:
          manifests: infra/web.voodu
          dry-run: true
```

The plan is computed against the pull request's **merge commit**, which is
what `actions/checkout` gives you by default on a `pull_request` event — the
state after merging, not the branch head.

## Concurrency

Two pushes in quick succession start two runs, and nothing orders them — the
older apply can reach the server last and win. Give every workflow that
applies a concurrency group:

```yaml
concurrency:
  group: voodu-deploy-production
  cancel-in-progress: false
```

**Leave `cancel-in-progress` at `false`.** The controller reconciles
asynchronously to the apply, so cancelling a run mid-flight kills the runner
and drops the SSH connection while the server carries on with work it has
already accepted. You would be left with a half-applied older release racing
a newer one, and no clear way to tell what finished.

Queueing behaves exactly the way a deploy wants. GitHub keeps at most one
pending run per group and cancels the previously pending one, so three rapid
pushes collapse to: finish the run in progress, then apply the newest commit,
and skip the one in the middle.

Group by **target**, not by branch — the point is to serialise everything
aimed at the same server:

```yaml
concurrency:
  group: voodu-deploy-${{ github.ref_name }}-eu   # one group per server
```

Deploys to different servers keep separate groups and run in parallel.

A plan job is the opposite case. `vd diff` changes nothing, and a superseded
plan is pure waste, so cancel those and scope the group to the pull request:

```yaml
concurrency:
  group: voodu-plan-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

## How the CLI gets installed

On a workstation you install voodu with the one-liner from
[voodu.clowk.in](https://voodu.clowk.in/), which picks the right build for
your machine:

```bash
curl -fsSL voodu.clowk.in/install | bash
```

This action does **not** pipe that script. It fetches the release archive for
the runner's OS and architecture directly, for three reasons that matter in
CI and not on a laptop: the download is verified against the release
`checksums.txt`, nothing needs `sudo`, and the binary lands in a
version-keyed directory that can be cached between runs.

Releases are pulled from `thadeu/clowk-voodu`. Point the action at a
different source with `VOODU_INSTALL_REPO`, which is also the escape hatch
while the CLI moves to `clowk-in/voodu-cli`:

```yaml
env:
  VOODU_INSTALL_REPO: clowk-in/voodu-cli
```

## Caching

The CLI is cached per exact release. When `version` is not pinned, the action
resolves the real tag from the GitHub API *before* the cache step, so the key
always names an immutable release. That is why there is no expiry to
configure: a new release produces a new key, and GitHub evicts caches that
stop being touched (7 days idle, or when the repo passes its 10 GB limit).

Within a single job, the second and later steps find the binary already in
place and skip both the cache and the download.

Set `cache: 'false'` to bypass it entirely.

Downloads are verified against the release `checksums.txt`. A missing or
mismatched checksum fails the step rather than installing the binary.

## When something fails

The step fails with the CLI's exit code and the server's full output stays in
the job log. The failure is also raised as a GitHub annotation, so it appears
at the top of the run instead of only inside the step, and every run writes a
short summary (version, manifest count, result) to the job summary page.

## Security

The credential this action carries is an **SSH key with shell access to your
server** — and because the deploy user is in the `docker` group, that is root
in practice. Treat it accordingly.

**Pin the host key.** Without `known-hosts` the action falls back to
trust-on-first-use, and on an ephemeral runner "first use" is every run — it
accepts whatever key answers. Generate the value once:

```bash
ssh-keyscan -H your-server.example.com
```

**Use a dedicated key.** One key per repository, never your personal one, so
it can be rotated without disturbing anything else.

**Restrict what the key can do.** In the server's `~/.ssh/authorized_keys`,
a forced command keeps the key from opening a shell:

```
command="voodu $SSH_ORIGINAL_COMMAND",no-agent-forwarding,no-port-forwarding,no-pty,no-X11-forwarding ssh-ed25519 AAAA...
```

Verify your own deploy still works after adding it — build-mode pushes a
source tarball over the same connection.

**Add a human gate.** A GitHub Environment with required reviewers pauses the
job until someone approves it. Approval is always implied at the CLI level
here (there is no terminal to prompt on), so this is where the gate belongs.

**Do not pass `--prune`.** It is opt-in by default, which is the right setting
for CI. Deleting resources should stay a deliberate act at a keyboard.

### Runner hygiene

The private key is written under `$RUNNER_TEMP`, which the runner wipes
between jobs. Composite actions cannot register a cleanup step, so on a
**self-hosted** runner the `~/.ssh/config` entry this action writes persists
after the job. Remove it yourself if that matters:

```yaml
      - if: always()
        run: sed -i '/# >>> voodu-gh /,/# <<< voodu-gh /d' ~/.ssh/config
```

Hosted runners need nothing — the whole machine is destroyed.

## Requirements

- `actions/checkout` before this action, when the manifests come from the repo.
- Linux or macOS runners. The CLI ships `amd64` and `arm64` builds for both.

## Versioning

Releases follow semantic versioning. Every release is published under its
exact tag, and the major tag moves to the newest compatible release — so you
choose how much movement you want:

| Reference | What you get |
|---|---|
| `clowk-in/voodu-gh@v1.0.0` | immutable; you bump it yourself |
| `clowk-in/voodu-gh@v1` | minor and patch releases arrive on their own |
| `clowk-in/voodu-gh@<full sha>` | immutable and unforgeable |

A tag can be moved by whoever owns the repository, so `@v1` is a statement of
trust, not a guarantee. This action holds a key with shell access to your
server — if that matters where you work, pin the full commit SHA, which is
also what Dependabot and the OpenSSF guidance recommend for actions. It keeps
updating the pin for you.

Prereleases (`v1.2.0-rc.1`) are published, but never move `v1`. Anyone
tracking the major tag only ever lands on a finished release.

## Links

- [voodu.clowk.in](https://voodu.clowk.in/) — docs and install
- [thadeu/clowk-voodu](https://github.com/thadeu/clowk-voodu) — the CLI and controller, where the releases this action downloads are published

## License

MIT
