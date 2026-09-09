# Build context is the monorepo root (docker build -f .../Dockerfile .),
# matching the convention this repo's OCaml example Dockerfiles already use
# -- since FEAT-038, this service depends on the in-tree npm workspace
# packages @sol/kafka/@sol/obs (packages/sol-kafka, packages/sol-obs), not
# just its own directory, so a self-contained single-directory build
# context can no longer resolve them.
FROM node:22-alpine AS build
WORKDIR /workspace
COPY package.json package-lock.json ./
COPY packages/sol-kafka/package.json ./packages/sol-kafka/package.json
COPY packages/sol-obs/package.json ./packages/sol-obs/package.json
COPY examples/pluto/app/demo_ts/order_svc/package.json ./examples/pluto/app/demo_ts/order_svc/package.json
RUN npm ci
COPY packages/sol-kafka ./packages/sol-kafka
COPY packages/sol-obs ./packages/sol-obs
COPY examples/pluto/app/demo_ts/order_svc ./examples/pluto/app/demo_ts/order_svc
RUN npm run build -w @sol/obs -w @sol/kafka -w order-svc

FROM node:22-alpine
WORKDIR /app
COPY --from=build /workspace/node_modules ./node_modules
COPY --from=build /workspace/packages/sol-kafka/dist ./node_modules/@sol/kafka/dist
COPY --from=build /workspace/packages/sol-kafka/package.json ./node_modules/@sol/kafka/package.json
COPY --from=build /workspace/packages/sol-obs/dist ./node_modules/@sol/obs/dist
COPY --from=build /workspace/packages/sol-obs/package.json ./node_modules/@sol/obs/package.json
COPY --from=build /workspace/examples/pluto/app/demo_ts/order_svc/dist ./dist
COPY --from=build /workspace/examples/pluto/app/demo_ts/order_svc/package.json ./package.json
USER 65534
CMD ["node", "dist/index.js"]
