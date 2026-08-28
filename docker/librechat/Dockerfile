# syntax=docker/dockerfile:1
FROM node:24.16.0-alpine AS node

ARG NODE_MAX_OLD_SPACE_SIZE=6144

RUN apk upgrade --no-cache \
 && apk add --no-cache jemalloc python3 py3-pip uv curl
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

RUN mkdir -p /app && chown node:node /app
WORKDIR /app
USER node

COPY --chown=node:node . .

RUN chmod -R u+w /app

RUN npm ci --no-audit

RUN NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}" npm run frontend \
 && test -f /app/packages/data-schemas/dist/index.cjs \
 && test -d /app/client/dist

RUN npm prune --production && npm cache clean --force

RUN mkdir -p /app/client/public/images /app/logs /app/uploads /app/skill

ENV HOST=0.0.0.0
EXPOSE 3080

CMD ["npm", "run", "backend"]
