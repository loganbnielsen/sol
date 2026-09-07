FROM node:22-alpine AS build
WORKDIR /workspace
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY --from=build /workspace/dist ./dist
USER 65534
CMD ["node", "dist/index.js"]
