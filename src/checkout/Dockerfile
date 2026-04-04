# Build Stage
FROM node:22-alpine AS build-env

WORKDIR /app

# Cache dependencies before copying source
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn/releases .yarn/releases
RUN yarn install --frozen-lockfile

# Build TypeScript to dist/
COPY . .
RUN yarn build

# Run Stage
FROM node:22-alpine

# 'node' user already exists in the official node image
USER node

WORKDIR /app

# Copy only what's needed to run
COPY --chown=node:node --from=build-env /app/node_modules ./node_modules
COPY --chown=node:node --from=build-env /app/dist ./dist

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=20s \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENTRYPOINT ["node", "dist/main"]
