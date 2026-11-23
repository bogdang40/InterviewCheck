# Hosted web workspace (Azure)

The web edition (`portable/`, see [WEB.md](../portable/WEB.md)) runs as one deployment on a small Azure VM.
It follows the "HTTPS deployment" section of WEB.md: Caddy terminates HTTPS and forwards to Next.js on
127.0.0.1:3000, which forwards `/api` and `/v1` to FastAPI on 127.0.0.1:8000. Both SQLite databases live on
the VM's own disk. Azure App Service and Container Apps were ruled out because their storage is a network
share, and the databases use SQLite WAL mode, which is not safe on network file systems.

```
GitHub main ──CI (Linux job passes)──▶ deploy.yml ──image──▶ Azure Container Registry
                                           │
                                           └─ az vm run-command ─▶ VM: docker compose (app + Caddy)
                                                                    /srv/interviewcheck/data/*.sqlite3
                                                                    nightly backup ─▶ Azure Storage (30 days)
```

## What deploys, and when

- Every push to `main` that touches `portable/`, `server/`, `scripts/`, `deploy/`, `package.json`, `.dockerignore`
  or `.github/workflows/portable.yml` runs **Portable interview workspace** (CI). A push that changes only other
  files (docs, or `deploy.yml` alone) runs neither CI nor a deploy. When the Linux job passes, **Deploy web
  workspace** builds `deploy/Dockerfile`, pushes it to the registry tagged with the commit (or reuses the image
  if that tag is already there), and runs `deploy/vm-rollout.sh` on the VM.
- Deploys go out in commit order. A deploy for an older commit skips itself (and succeeds) when a newer commit
  on `main` touches CI's paths, because that commit's own deploy follows.
- The Windows CI job does not gate deploys. Production is Linux, and that job has flaky upload tests.
- Before anything on the VM changes, a changed `deploy/Caddyfile` is validated in a throwaway container of the
  running Caddy image; an invalid file stops the rollout there. The rollout then backs up both databases, starts the new image, and waits for its health check (`/api/readyz`).
  Then, if `deploy/Caddyfile` changed, it validates the new file inside the Caddy container and reloads Caddy
  (the file before it stays in `/srv/interviewcheck/Caddyfile.previous`). Last, it checks HTTPS through Caddy on
  the VM itself. If any of these fails, it puts back the previous Caddyfile and the databases from that
  pre-deploy backup (the failed version may already have changed the schema), starts the exact image that was
  running before (by image ID, tagged `interviewcheck-web:previous` on the VM), and the workflow fails. The
  failed version's database files are kept in `/srv/interviewcheck/data/.failed-<UTC time>` for 30 days.
- After the rollout the workflow checks the site from outside Azure, then runs
  `scripts/verify_edge_security.py --edge` against it. A failure there marks the run failed but does not roll
  back: the VM already confirmed the new version serves HTTPS.
- After a successful rollout the VM keeps only the new image and the previous one (each is about 1.7 GB on a
  30 GB disk). Older images stay in the registry.
- Manual deploy of the current `main`: Actions → **Deploy web workspace** → **Run workflow**, or
  `gh workflow run deploy.yml -R bogdang40/InterviewCheck`.
- Only `main` can deploy. The `production` environment's branch rule and the Azure sign-in (OIDC, subject
  `repo:bogdang40/InterviewCheck:environment:production`) both enforce it.

CI runs on pull requests and on `main`. Pushes to other branches no longer run CI on their own; open a PR.

On pull requests, CI also builds the server image (`deploy/image-smoke.sh`): it starts `main`'s image on an
empty data folder and adds an interview, then starts the PR's image on that same folder, configured like
production. The PR fails if the image does not become healthy or the interview does not survive. The Linux test
job cannot catch this: it uses the CI machine's own Python and SQLite, not the image's. On Nov 19 2026, merged
code needed an SQLite feature the image did not have, and every deploy failed until the base image changed.
`deploy/edge-smoke.sh` then puts `deploy/Caddyfile`, under the Caddy image `compose.yml` pins, in front of the PR's
image over local HTTP: it validates the file, checks Caddy's defaults on an unlabelled response, checks that the
app's own CSP and Referrer-Policy get through, and runs `scripts/verify_edge_security.py --edge`.

## Files

| File | Purpose |
| --- | --- |
| `deploy/Dockerfile` | Python 3.13 + Node 22 image, built with `npm run build` and started with `npm start` (web-runtime.mjs) |
| `.dockerignore` | Only `package.json` and `portable/` (without tests, QA, local builds and data) go into the image |
| `deploy/compose.yml` | App + Caddy, host networking so the app's listeners stay on loopback |
| `deploy/Caddyfile` | HTTPS, security headers, 26 MB body limit, slow-request timeouts, client-IP header replacement |
| `deploy/vm-rollout.sh` | Runs on the VM for each deploy (pull, backup, start, health wait, Caddy reload, HTTPS check, rollback) |
| `deploy/backup.sh` | SQLite online backup of both databases, uploaded to Azure Storage; removes old local leftovers |
| `deploy/cloud-init.yaml` | First boot: Docker, Azure CLI, swap |
| `deploy/provision-azure.sh` | One-time creation of every Azure resource and the GitHub settings |

## Azure resources (resource group `interviewcheck-rg`, East US 2)

| Resource | Notes |
| --- | --- |
| VM `interviewcheck-vm` | Ubuntu 24.04, Standard_B1ms (1 vCPU, 2 GB, plus 2 GB swap), 32 GB Standard SSD. Inbound 80/443 only; SSH is closed |
| Public IP with DNS name | The site address, `interviewcheck-<suffix>.eastus2.cloudapp.azure.com` |
| Container registry `interviewcheck<suffix>` | Basic tier. The VM pulls with its managed identity (AcrPull) |
| Storage account `icbackup<suffix>` | Container `backups`, blobs deleted after 30 days. The VM writes with its managed identity |
| Entra app "InterviewCheck GitHub deploy" | GitHub Actions signs in with OIDC; AcrPush on the registry, Virtual Machine Contributor on the VM only |

The exact names are in the repository's `production` environment variables (`ACR_NAME`, `RESOURCE_GROUP`,
`VM_NAME`, `SITE_ADDRESS`, `BACKUP_ACCOUNT`).

Approximate cost: VM ~$15/month, registry ~$5, public IP ~$4, disk ~$2.50, storage pennies.

## App settings

`/srv/interviewcheck/app.env` on the VM (mode 600, written once by `provision-azure.sh`, never by deploys):

- `INTERVIEWCHECK_PUBLIC_ORIGIN`, `INTERVIEWCHECK_ACCESS_MODE=embedded` and `INTERVIEWCHECK_OPERATOR_EMAIL`.
  One deployment = one operator account (WEB.md).
- `INTERVIEWCHECK_SIGNUP_SECRET` (invitation code) and `ADMIN_EMAILS` + `ADMIN_BOOTSTRAP_SECRET`, generated on
  the VM.
- `INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1`. This is safe only because Caddy replaces `X-InterviewCheck-Client-IP`
  and ports 3000/8000 are never published.

To add provider keys (OpenAI, Deepgram, Stripe, calendars; see `portable/CONNECTIONS.md`), append them to
`app.env` and restart the app. Run this in bash: `read -s` keeps the key out of the terminal and the shell
history, and the key reaches Azure only inside a file readable by you alone (edit the line by hand instead if
the variable is already in `app.env`):

```sh
read -rs -p 'OPENAI_API_KEY: ' key; echo
script=$(mktemp)
{
  printf 'KEY_LINE=%q\n' "OPENAI_API_KEY=$key"
  cat <<'EOF'
cd /srv/interviewcheck && printf '%s\n' "$KEY_LINE" >> app.env
IMAGE=$(cat deployed-image) docker compose --env-file deploy.env up -d --force-recreate app
EOF
} > "$script"
unset key
az vm run-command invoke -g interviewcheck-rg -n interviewcheck-vm --command-id RunShellScript \
  --scripts "@$script" --query "value[0].message" -o tsv
rm -f "$script"
```

`docker compose` on the VM needs `IMAGE` and `SITE_ADDRESS` in its environment. For manual commands, use:
`cd /srv/interviewcheck && IMAGE=$(cat deployed-image) docker compose --env-file deploy.env ...`.

## Operations

- **Logs:** `az vm run-command invoke ... --scripts "docker logs --tail 100 interviewcheck-app-1"`.
- **Backups:** nightly at 07:30 UTC (`systemctl list-timers interviewcheck-backup.timer`) and before each deploy.
  Blobs are `backups/<UTC time>-<nightly|pre-deploy>.tar.gz`, containing `review.sqlite3` and `access.sqlite3`.
- **Restore:** stop all application writers. Extract the selected backup into a new empty directory and verify both database files with SQLite integrity checks. Move the current database files and their matching `-wal` and `-shm` sidecars together into a quarantine directory. Install only the verified backup files in `/srv/interviewcheck/data` with owner uid 10001, then start the compatible application image. Old WAL files can override a restored main database even when its integrity check passes.
- **Upgrade recovery:** an existing deployment must complete and upload both database backups before the new image starts. A failed predeployment backup stops the rollout. An automatic rollback also puts back both databases from that predeployment backup, so writes made in the minutes the new version ran are only in `data/.failed-<UTC time>`. A rollback started by hand (below) does not restore databases: for an incompatible schema change, restore the verified pair and use the matching earlier image before resuming writes.
- **Rollback:** Actions → **Deploy web workspace** → **Run workflow** on an older commit is not possible (main
  only). Instead, revert the commit on `main`, or start an earlier image on the VM (run `az login --identity`
  and `az acr login --name <acr>` first if it has to be pulled again):
  `IMAGE=<acr>.azurecr.io/interviewcheck-web:<sha> docker compose --env-file deploy.env up -d`.
  If the newer version changed the database schema, restore the pre-deploy backup first (see **Restore**).
- **SSH (emergencies only):** the key is in `~/.interviewcheck-web/vm_ed25519` on the machine that ran
  provisioning. Open port 22 to your own IP temporarily in the VM's network security group, then remove the rule.

## Not covered yet

- Stripe billing is not configured. The operator account was created with the administrator secret, and an
  administrator counts as active access (entitlement source `admin`), so no payment is needed.
- One deployment serves one operator. Selling to several companies means one deployment per company, or
  making the workspace multi-tenant.
- Hardening the app itself (from the Nov 18 review): sign-in limits per IPv6 /64 and per account, checking the
  session before reading large request bodies, an identical response for a wrong operator email, and hiding
  `/api/integrations/status` details before sign-in.
