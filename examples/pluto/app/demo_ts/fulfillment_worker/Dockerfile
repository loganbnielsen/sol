# Build context is the Sol workspace root -- examples/pluto, the directory that
# holds sol.yml -- not the enclosing Sol repository, and not this service's own
# directory. app/demo_ts owns its own package.json/package-lock.json and resolves
# @sol-fab/kafka and @sol-fab/obs from npm, so nothing outside this workspace is
# required to build the image.
#
#   cd examples/pluto
#   docker build -f app/demo_ts/fulfillment_worker/Dockerfile .
#
# Earlier revisions used the Sol repository root as the build context and copied
# packages/sol-kafka and packages/sol-obs straight out of the monorepo, because
# the two services depended on the in-tree npm workspace. FEAT-085 removed that
# coupling: DEC-024 puts the Sol workspace boundary at sol.yml, and a Sol
# workspace must not require an enclosing JavaScript workspace.
FROM node:22-alpine AS build
WORKDIR /workspace/app/demo_ts

# Manifests only, so the npm layer stays cached until a manifest actually changes.
COPY app/demo_ts/package.json app/demo_ts/package-lock.json ./
COPY app/demo_ts/order_svc/package.json ./order_svc/package.json
COPY app/demo_ts/fulfillment_worker/package.json ./fulfillment_worker/package.json
RUN npm ci

COPY app/demo_ts ./
RUN npm run build -w fulfillment-worker

FROM node:22-alpine
WORKDIR /app
# The workspace's single shared install, plus only this service's tree -- the
# sibling service is deliberately not shipped. node_modules holds a workspace
# symlink per service, and this one resolves because the service sits at the
# matching relative path; the sibling's symlink dangles, which is inert since
# nothing resolves it at runtime.
COPY --from=build /workspace/app/demo_ts/node_modules ./node_modules
COPY --from=build /workspace/app/demo_ts/fulfillment_worker ./fulfillment_worker
USER 65534
CMD ["node", "fulfillment_worker/dist/index.js"]
