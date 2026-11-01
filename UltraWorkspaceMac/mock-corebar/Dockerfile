# Mock CoreBar — build + run.
FROM node:22-alpine AS build
WORKDIR /app
# package-lock.json is committed: use `npm ci` for reproducible installs.
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY --from=build /app/dist ./dist

# UDP discovery, TLS control, HTTP upload, web viewer.
EXPOSE 5319/udp
EXPOSE 7431
EXPOSE 8080
EXPOSE 8081

CMD ["node", "dist/index.js"]
