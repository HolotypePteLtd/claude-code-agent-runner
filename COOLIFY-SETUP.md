# Coolify Deployment Guide

Deploy one or more GitHub Actions self-hosted runners with Claude Code, each configured entirely through Coolify's UI.

## Prerequisites

- A Coolify instance with a connected server
- A GitHub repo or org where you have admin access (to generate runner tokens)
- An Anthropic API key
- A GitHub App for org-wide repo access (recommended), **or** an SSH key pair for single-repo push access

## Steps

### 1. Create a new resource

In your Coolify project, click **+ New** > **Docker Compose**.

### 2. Connect this repository

Point the resource to this Git repo (or your fork). Coolify will detect `docker-compose.runner.yml` — select it as the compose file if prompted.

### 3. Set environment variables

Go to the **Environment Variables** tab and add the following. Use `.env.example` in this repo as a reference.

**Required:**

| Variable | Description |
|---|---|
| `GITHUB_RUNNER_TOKEN` | Runner registration token from Settings > Actions > Runners > New self-hosted runner |
| `GITHUB_REPO_URL` | Repo URL, e.g. `https://github.com/your-org/your-repo` (for a repo-level runner) |
| `GITHUB_OWNER_URL` | **OR** org URL, e.g. `https://github.com/your-org` (for an org-level runner) |

Set either `GITHUB_REPO_URL` or `GITHUB_OWNER_URL`, not both.

**Claude / Anthropic:**

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Your Anthropic API key (`sk-ant-...`) |

Or, if using a proxy:

| Variable | Description |
|---|---|
| `ANTHROPIC_BASE_URL` | Proxy base URL |
| `ANTHROPIC_AUTH_TOKEN` | Proxy auth token |

**GitHub App (recommended — gives access to all org repos):**

| Variable | Description |
|---|---|
| `GITHUB_APP_ID` | Numeric App ID from the GitHub App settings page |
| `GITHUB_APP_PRIVATE_KEY_BASE64` | Base64-encoded PEM private key (see below) |
| `GITHUB_APP_INSTALLATION_ID` | Numeric installation ID for the org |

All three must be set to enable GitHub App auth. If any are missing, SSH is used instead.

To set up a GitHub App:

1. Go to your org's **Settings > Developer settings > GitHub Apps > New GitHub App**
2. Give it a name (e.g. `claude-runner`), set the Homepage URL to anything
3. Under **Repository permissions**, grant **Contents: Read & write** (and any other permissions your workflows need)
4. Create the app and note the **App ID** from the settings page
5. Generate a **private key** — a `.pem` file will download
6. Install the app on your org (Settings > Developer settings > GitHub Apps > your app > Install App)
7. Note the **Installation ID** from the URL: `https://github.com/organizations/{org}/settings/installations/{id}`
8. Base64-encode the private key:

```bash
cat your-app.private-key.pem | base64 -w0
```

On macOS, use `base64` without `-w0` (it doesn't wrap by default).

Mark `GITHUB_APP_PRIVATE_KEY_BASE64` as a **Secret** in Coolify.

**SSH (fallback — for single-repo git push):**

| Variable | Description |
|---|---|
| `SSH_PRIVATE_KEY_BASE64` | Base64-encoded private key (see below) |

Generate the value:

```bash
cat ~/.ssh/id_ed25519 | base64 -w0
```

On macOS, use `base64` without `-w0` (it doesn't wrap by default).

Mark this variable as a **Secret** in Coolify so it isn't exposed in logs.

**Optional:**

| Variable | Default | Description |
|---|---|---|
| `GITHUB_RUNNER_NAME` | `claude-docker-runner` | Name shown in GitHub's runner list |
| `GITHUB_RUNNER_LABELS` | `docker,ubuntu,flutter` | Comma-separated labels for job targeting |
| `GITHUB_RUNNER_GROUP` | `default` | Runner group |
| `GIT_AUTHOR_NAME` | `Claude Code Planning Agent` | Git commit author name |
| `GIT_AUTHOR_EMAIL` | `claude-planning@github-actions.local` | Git commit author email |

### 4. First deploy — authenticate Claude Code

On first deploy, you need to interactively log in to Claude Code so credentials are cached in the persistent volume.

1. Set `SETUP_MODE=true` in the environment variables
2. Deploy — the container will start but pause instead of launching the runner
3. Open a **Terminal** to the container in Coolify's UI
4. Run `claude` and complete the interactive authentication
5. Exit the terminal
6. Remove the `SETUP_MODE` variable (or set it to `false`)
7. Redeploy — the runner will start normally, using the cached credentials

The credentials persist in the `claude-config` volume, so you only need to do this once per instance (unless the volume is deleted).

### 5. Deploy

Click **Deploy**. Coolify will build the Docker image and start the container. The first build takes a few minutes (Flutter SDK download).

### 6. Verify

- Check container logs in Coolify for `"Runner configured successfully!"`
- If using GitHub App auth, look for `"GitHub App installation token generated successfully!"`
- If using SSH, look for `"SSH connection to GitHub successful!"`
- In GitHub, go to Settings > Actions > Runners — your runner should appear as **Idle**

## Running multiple instances

Each Coolify Docker Compose resource is fully isolated (separate container, volumes, and env vars). To run multiple runners:

1. Create another **Docker Compose** resource pointing to the same repo
2. Set different env vars (different `GITHUB_RUNNER_TOKEN`, `GITHUB_RUNNER_NAME`, and optionally a different `GITHUB_REPO_URL`)
3. Deploy

There is no conflict between instances — Coolify scopes named volumes per resource.

## Troubleshooting

**Runner fails to register:**
- Runner tokens expire quickly. Generate a fresh one and redeploy.
- Make sure you set exactly one of `GITHUB_REPO_URL` or `GITHUB_OWNER_URL`.

**SSH key not working:**
- Check logs for `"Injecting SSH key from SSH_PRIVATE_KEY_BASE64 env var..."`. If missing, the env var isn't reaching the container.
- Verify the base64 value is correct: `echo "$SSH_PRIVATE_KEY_BASE64" | base64 -d` should output your private key.
- Ensure the corresponding public key is added to your GitHub account or repo deploy keys.

**Container restarts in a loop:**
- If the runner was previously registered with a now-expired token, the persisted `.runner` config in the `runner-data` volume may be stale. Delete the volume in Coolify and redeploy.
