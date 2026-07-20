// Minimal demo microservice used to exercise the GitOps pipeline.
//
// Endpoints:
//   GET  /            -> basic greeting + environment + version info
//   GET  /healthz      -> liveness probe target
//   GET  /readyz        -> readiness probe target
//   GET  /version        -> build metadata (used to visually confirm which
//                           image/version is running in each environment)
//   GET  /metrics         -> Prometheus metrics (used by Argo Rollouts
//                             AnalysisTemplate to gate canary promotion)
//
// Configuration is entirely via environment variables so the same container
// image is promoted unchanged across dev -> staging -> prod (a core GitOps
// principle: build once, promote the artifact, not rebuild per environment).

const express = require('express');
const client = require('prom-client');

const app = express();
const PORT = process.env.PORT || 8080;
const APP_VERSION = process.env.APP_VERSION || 'dev-local';
const ENVIRONMENT = process.env.ENVIRONMENT || 'unknown';
const GIT_SHA = process.env.GIT_SHA || 'unknown';

// --- Prometheus metrics setup -------------------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpErrorsTotal = new client.Counter({
  name: 'http_errors_total',
  help: 'Total HTTP 5xx responses (used as the canary failure signal)',
  labelNames: ['method', 'route'],
  registers: [register],
});

// Artificial failure injection for demoing canary rollback.
// Set FAILURE_RATE=0.5 (i.e. 50%) via env var / ConfigMap to simulate a bad
// release and watch Argo Rollouts automatically halt/rollback the canary.
const FAILURE_RATE = parseFloat(process.env.FAILURE_RATE || '0');

app.use((req, res, next) => {
  res.on('finish', () => {
    httpRequestsTotal.inc({ method: req.method, route: req.path, status_code: res.statusCode });
    if (res.statusCode >= 500) {
      httpErrorsTotal.inc({ method: req.method, route: req.path });
    }
  });
  next();
});

app.get('/', (req, res) => {
  if (FAILURE_RATE > 0 && Math.random() < FAILURE_RATE) {
    return res.status(500).json({ error: 'injected failure for canary testing' });
  }
  res.json({
    message: `Hello from ${ENVIRONMENT}!`,
    version: APP_VERSION,
    gitSha: GIT_SHA,
    environment: ENVIRONMENT,
    hostname: process.env.HOSTNAME || 'local',
  });
});

app.get('/healthz', (req, res) => res.status(200).json({ status: 'ok' }));

app.get('/readyz', (req, res) => res.status(200).json({ status: 'ready' }));

app.get('/version', (req, res) => res.json({ version: APP_VERSION, gitSha: GIT_SHA, environment: ENVIRONMENT }));

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`app listening on :${PORT} | env=${ENVIRONMENT} | version=${APP_VERSION} | gitSha=${GIT_SHA}`);
  });
}

module.exports = app;
