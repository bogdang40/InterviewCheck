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

- Every push to `main` that touches `portable/`, `server/`, `deploy/` or the workflows runs **Portable interview
  workspace** (CI). When its Linux job passes, **Deploy web workspace** builds `deploy/Dockerfile`, pushes it to
  the registry tagged with the commit, and runs `deploy/vm-rollout.sh` on the VM.
- The Windows CI job does not gate deploys. Production is Linux, and that job has flaky upload tests.
- The rollout backs up both databases, starts the new image, and waits for its health check. If the new
  version is not healthy within about three minutes, it switches back to the previous image and the workflow
  fails.
- Manual deploy of the current `main`: Actions → **Deploy web workspace** → **Run workflow**, or
  `gh workflow run deploy.yml -R bogdang40/InterviewCheck`.
- Only `main` can deploy. The `production` environment's branch rule and the Azure sign-in (OIDC, subject
  `repo:bogdang40/InterviewCheck:environment:production`) both enforce it.

CI runs on pull requests and on `main`. Pushes to other branches no longer run CI on their own; open a PR.

## Files

| File | Purpose |
| --- | --- |
| `deploy/Dockerfile` | Python 3.13 + Node 22 image, built with `npm run build` and started with `npm start` (web-runtime.mjs) |
| `.dockerignore` | Only `package.json` and `portable/` (without tests, QA, local builds and data) go into the image |
| `deploy/compose.yml` | App + Caddy, host networking so the app's listeners stay on loopback |
| `deploy/Caddyfile` | HTTPS, security headers, 26 MB body limit, slow-request timeouts, client-IP header replacement |
| `deploy/vm-rollout.sh` | Runs on the VM for each deploy (pull, backup, start, health wait, rollback) |
| `deploy/backup.sh` | SQLite online backup of both databases, uploaded to Azure Storage |
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
`app.env` and restart:

```sh
az vm run-command invoke -g interviewcheck-rg -n interviewcheck-vm --command-id RunShellScript --scripts \
  "cd /srv/interviewcheck && echo 'OPENAI_API_KEY=...' >> app.env && docker compose --env-file deploy.env up -d --force-recreate app"
```

`docker compose` on the VM needs `IMAGE` and `SITE_ADDRESS` in its environment. For manual commands, use:
`cd /srv/interviewcheck && IMAGE=$(cat deployed-image) docker compose --env-file deploy.env ...`.

## Operations

- **Logs:** `az vm run-command invoke ... --scripts "docker logs --tail 100 interviewcheck-app-1"`.
- **Backups:** nightly at 07:30 UTC (`systemctl list-timers interviewcheck-backup.timer`) and before each deploy.
  Blobs are `backups/<UTC time>-<nightly|pre-deploy>.tar.gz`, containing `review.sqlite3` and `access.sqlite3`.
- **Restore:** stop all application writers. Extract the selected backup into a new empty directory and verify both database files with SQLite integrity checks. Move the current database files and their matching `-wal` and `-shm` sidecars together into a quarantine directory. Install only the verified backup files in `/srv/interviewcheck/data` with owner uid 10001, then start the compatible application image. Old WAL files can override a restored main database even when its integrity check passes.
- **Upgrade recovery:** an existing deployment must complete and upload both database backups before the new image starts. A failed predeployment backup stops the rollout. Automatic image rollback does not roll back database migrations. For an incompatible schema change, restore the verified pair and use the matching earlier image before resuming writes.
- **Rollback:** Actions → **Deploy web workspace** → **Run workflow** on an older commit is not possible (main
  only). Instead, revert the commit on `main`, or start an earlier image on the VM:
  `IMAGE=<acr>.azurecr.io/interviewcheck-web:<sha> docker compose --env-file deploy.env up -d`.
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
