# syntax=docker/dockerfile:1
# Ours, not vendor/LibreChat/Dockerfile: upstream's `npm run frontend;` uses a
# semicolon, so a failed frontend build is swallowed and the image ships with
# empty packages/*/dist -- it crash-loops at runtime on a missing module with
# nothing in the build log to explain why. The image restores write permission
# before the build so rolldown can create dist/.
FROM node:24.16.0-alpine AS node

ARG NODE_MAX_OLD_SPACE_SIZE=6144

RUN apk upgrade --no-cache \
 && apk add --no-cache jemalloc python3 py3-pip uv curl
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

RUN mkdir -p /app && chown node:node /app
WORKDIR /app
USER node

COPY --chown=node:node . .

# Without this the workspace builds cannot write their own dist/.
RUN chmod -R u+w /app

RUN npm ci --no-audit

# `&&`, not `;` -- a failed build must fail here, not ship an empty dist/.
RUN NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}" npm run frontend \
 && test -f /app/packages/data-schemas/dist/index.cjs \
 && test -d /app/client/dist

RUN npm prune --production && npm cache clean --force

RUN mkdir -p /app/client/public/images /app/logs /app/uploads /app/skill

ENV HOST=0.0.0.0
EXPOSE 3080

CMD ["npm", "run", "backend"]
