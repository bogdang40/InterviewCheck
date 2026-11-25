# Next.js and FastAPI

Run these commands from the repository root. Install Node.js 22.13 or newer, npm and Python 3.11 or newer. Windows uses the Python launcher. Linux uses python3 and the system venv package. The startup command prepares the Python environment in `portable/.venv` and installs the locked frontend dependencies. First setup needs internet access.

## Development

```sh
npm run dev
```

Open [InterviewCheck](http://localhost:3000). Next.js serves the application with hot reload. FastAPI serves [interactive API documentation](http://127.0.0.1:8000/docs) and reloads changes under `portable/api`. Ctrl+C stops both processes and their workers. Run `npm run setup` for dependency installation alone.

## Production

```sh
npm run build
npm start
```

This starts the compiled Next.js server on port 3000 and FastAPI on port 8000. It uses the same interview database as the packaged workstation launcher. Set `INTERVIEWCHECK_DB` to an absolute path for another workspace. The server build is under `portable/web/.next-server`. Keep the installed frontend dependencies, Python environment, build and source together.

Requests to `/api` and `/v1` travel through Next.js to FastAPI, including the live capture WebSocket. The browser stays on its original origin for authentication, audio and exports. The embedded Python account service owns `/v1` when enabled.

Set `INTERVIEWCHECK_WEB_PORT` and `INTERVIEWCHECK_API_PORT` to change ports. Build and start with the same API port because Next.js compiles rewrite destinations into its route manifest. Both listeners bind to IPv4 loopback. The frontend accepts browser URLs using localhost or 127.0.0.1. For independent processes, run `npm run dev` or `npm start` inside `portable/web` and start `python -m uvicorn api.main:app --host 127.0.0.1 --port 8000 --no-proxy-headers` from `portable` using its virtual environment.

## HTTPS deployment

The production workspace supports one assigned operator per deployment. Set `INTERVIEWCHECK_PUBLIC_ORIGIN` to the exact external HTTPS origin and `INTERVIEWCHECK_OPERATOR_EMAIL` to the assigned account. For embedded accounts, set `INTERVIEWCHECK_ACCESS_MODE=embedded` and configure the operator invitation as described in the connection guide. For a remote access service, provision the operator there first, set `INTERVIEWCHECK_ACCESS_URL`, and set `INTERVIEWCHECK_OPERATOR_ID` to the operator's `user.id` from the authenticated `/v1/me` response. Public remote workspaces accept sign in for this account only. Startup rejects a public origin when account binding is incomplete.

Terminate TLS with an HTTPS reverse proxy on the same host. Forward the original Host and WebSocket upgrades to port 3000. Send all browser paths through that listener. Keep port 8000 on loopback. The backend checks the original authority supplied by Next.js against the configured origin. Provider webhooks need the matching `/v1` path and their provider signature. Use your registered public name, certificate and account settings before exposing a listener. A Caddy configuration for a domain you control looks like this.

```caddyfile
interviews.example.com {
    reverse_proxy 127.0.0.1:3000 {
        header_up X-InterviewCheck-Client-IP {http.request.remote.host}
    }
}
```

For public embedded accounts, set `INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1` only after the HTTPS proxy replaces `X-InterviewCheck-Client-IP` with the address it observed. The workspace accepts this header on loopback requests through the configured public origin and uses it for the sign in rate limit. Keep both application listeners on loopback.

## Admin usage and AI keys

Administrators add provider keys under **Admin > Models > Connect model**. The server encrypts each key with the master key in `INTERVIEWCHECK_MODEL_SECRET_KEY` or, without it, the `.model_secret.key` file beside the review database. Keep a copy of that file in a safe place apart from the database backups: a restored database cannot decrypt its keys without it, and anyone holding both can read them.

**Admin > Usage** shows signed-out visitors, sign-ins, accounts, interviews, answers, reviews and AI requests per UTC day. The home, sample and sign-in pages report one view each through `POST /api/usage/visit`. The server stores a visitor only as a hash of the client address and browser with a random salt it replaces every day, so it keeps no address and cannot link visits across days. Crawlers, link previews and scripted browsers are not counted. Counters older than 400 days are removed.

## Static package

```sh
npm run export
python portable/package_release.py build/InterviewCheck-portable.zip
```

The workstation package contains a static Next.js export and FastAPI. The distribution runs without Node.js and uses port 8765 by default. From a source checkout, `python portable/run.py --build-only` builds that same export. The source based server and the static package have separate build outputs.

## Verification

From the root, run the following after installing the portable development requirements. Use the virtual environment's Python executable for the Python checks. The runtime smoke uses an isolated database and the selected local ports.

```sh
python portable/qa/smoke_next.py
npm run export
npm run typecheck --prefix portable/web
python portable/package_release.py build/InterviewCheck-portable.zip
python portable/qa/smoke_archive.py build/InterviewCheck-portable.zip
```

The runtime smoke submits a real interview to FastAPI through each Next server, checks an actual local WebSocket upgrade, rejects a foreign browser origin, and checks both child listeners stop. The audio transfer is cancelled before a provider request can be made. The ZIP smoke extracts a fresh distribution and saves an interview with Node removed from its executable path. The HTTPS origin tests exercise the configuration and authentication boundary locally. A public DNS name, certificate, TLS proxy and vendor accounts require deployment specific verification.
