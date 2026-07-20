# Multi-stage build: same image is promoted unchanged across all
# environments (dev -> staging -> prod). Environment-specific behavior
# comes only from env vars / ConfigMaps injected by Kubernetes, never from
# rebuilding the image.

FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src
COPY package.json ./
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/healthz || exit 1
CMD ["node", "src/index.js"]
