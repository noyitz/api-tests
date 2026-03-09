# vLLM Semantic Router - Postman Tests

## Setup

1. In Postman, click **Import** and select both files:
   - `vsr-collection.postman_collection.json` — all API requests
   - `vsr-environment.postman_environment.json` — environment variables

2. Select the **vSR Environment** in the top-right environment dropdown.

3. Edit the environment variables with your actual URLs:
   - `api_base_url` — Classification API route (port 8080)
   - `envoy_base_url` — Envoy proxy route (chat completions)
   - `metrics_base_url` — Prometheus metrics route
   - `routing_api_base_url` — HTTP Routing API (port 8082, new)

## Test Folders

| Folder | Description |
|--------|-------------|
| **Health & Readiness** | Basic health and readiness probes |
| **Envoy Routing (ExtProc)** | Chat completions through Envoy — check **response headers** for `x-vsr-*` routing info |
| **Classification API** | Direct classification: intent, PII, jailbreak, fact-check, full eval |
| **Info & Models** | List models, classifier info, API overview |
| **Configuration** | View router and classification config |
| **Metrics** | Classification and Prometheus metrics |
| **HTTP Routing API (NEW)** | New REST endpoint returning routing decisions as JSON (Workstream 2) |

## Tips

- For **Envoy Routing** requests, look at the **Headers** tab in the response to see `x-vsr-selected-model`, `x-vsr-selected-decision`, etc.
- The **HTTP Routing API** folder will work once the new HTTP API is deployed (port 8082).
