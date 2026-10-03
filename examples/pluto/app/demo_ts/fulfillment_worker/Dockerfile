FROM node:22-alpine AS build
WORKDIR /workspace/app/demo_ts

COPY app/demo_ts/package.json app/demo_ts/package-lock.json ./
COPY app/demo_ts/contract/package.json ./contract/package.json
COPY app/demo_ts/order_svc/package.json ./order_svc/package.json
COPY app/demo_ts/fulfillment_worker/package.json ./fulfillment_worker/package.json
RUN npm ci

COPY app/demo_ts ./
RUN npm run build -w fulfillment-worker

FROM node:22-alpine
WORKDIR /app
COPY --from=build /workspace/app/demo_ts/node_modules ./node_modules
COPY --from=build /workspace/app/demo_ts/contract ./contract
COPY --from=build /workspace/app/demo_ts/fulfillment_worker ./fulfillment_worker
RUN printf '#!/bin/sh\nexec node /app/contract/dist/main.js "$@"\n' > /usr/local/bin/contract && chmod +x /usr/local/bin/contract
USER 65534
CMD ["node", "fulfillment_worker/dist/index.js"]
