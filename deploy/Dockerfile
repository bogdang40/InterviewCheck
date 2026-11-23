# InterviewCheck web workspace: the Next.js server and FastAPI, started together by
# portable/web-runtime.mjs exactly as `npm start` does. Both listen on 127.0.0.1 only;
# Caddy (deploy/compose.yml) terminates HTTPS on the host and forwards to port 3000.
# Build from the repository root: docker build -f deploy/Dockerfile .
FROM node:22.23.5-trixie-slim AS node

FROM python:3.13-slim-trixie
ENV NEXT_TELEMETRY_DISABLED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    npm_config_update_notifier=false

# Node and npm from the official image. web-runtime.mjs needs node, and its setup check needs npm.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && useradd --create-home --uid 10001 app \
 && mkdir -p /app /data && chown app:app /app /data
USER app
WORKDIR /app

# Dependencies first, so a code-only change reuses these layers.
COPY --chown=app:app package.json ./
COPY --chown=app:app portable/run.py portable/requirements.txt portable/
COPY --chown=app:app portable/web/package.json portable/web/package-lock.json portable/web/
RUN cd portable && python run.py --prepare-web-runtime

COPY --chown=app:app portable/ portable/
# The API port is compiled into the Next.js rewrites, so build with the port used at start.
ENV INTERVIEWCHECK_WEB_PORT=3000 \
    INTERVIEWCHECK_API_PORT=8000 \
    INTERVIEWCHECK_DB=/data/review.sqlite3 \
    INTERVIEWCHECK_ACCESS_DB=/data/access.sqlite3
# The public origin goes into the home page's link-preview tags (portable/web/app/page.tsx).
ARG PUBLIC_ORIGIN=""
RUN if [ -n "$PUBLIC_ORIGIN" ]; then printf '{ "origin": "%s" }\n' "$PUBLIC_ORIGIN" > portable/web/lib/site.json; fi \
 && node portable/web-runtime.mjs build

ARG GIT_SHA=unknown
ENV INTERVIEWCHECK_VERSION=$GIT_SHA
LABEL org.opencontainers.image.source="https://github.com/bogdang40/InterviewCheck" \
      org.opencontainers.image.revision=$GIT_SHA

VOLUME ["/data"]
# readyz, not health: it also fails (503) when the model secret key file or the account schema is broken.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/api/readyz', timeout=4); u.urlopen('http://127.0.0.1:3000/', timeout=4)"
CMD ["node", "portable/web-runtime.mjs", "start"]
