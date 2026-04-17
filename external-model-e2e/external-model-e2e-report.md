# ExternalModel E2E Test Plan & Results

**Date:** 2026-04-17  
**Version:** MaaS 3.5 (maas-controller + maas-api + BBR payload-processing)  
**Platform:** RHOAI on OCP (AWS)

---

## Overview

This document serves as both a **test plan** and **test report** for the ExternalModel feature.
Each test section describes what is being tested, provides the curl command to reproduce,
and shows side-by-side results for real providers vs. the llm-katan simulator.

The goal is to validate that:
1. Real external providers (OpenAI, Anthropic, Bedrock) work end-to-end through the MaaS + BBR pipeline
2. The llm-katan simulator produces consistent behavior (same HTTP codes, same response format)
3. All error paths return correct status codes

## Setup

### Prerequisites

```bash
# 1. Login to OpenShift
oc login <CLUSTER_API> -u <USER> -p <PASS> --insecure-skip-tls-verify

# 2. Set variables
export GATEWAY_HOST="<GATEWAY_HOSTNAME>"
export TOKEN=$(oc whoami -t)
```

### Mint a MaaS API Key

```bash
curl -sk "https://${GATEWAY_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"e2e-test-key","subscription":"external-models-subscription"}'

# Copy the "key" field:
export API_KEY="<RETURNED_KEY>"
```

### Models Under Test

| Model Name | Provider | Backend | targetModel | Description |
|------------|----------|---------|-------------|-------------|
| `ext-openai` | openai | Real (api.openai.com) | gpt-4o-mini | Real OpenAI API |
| `ext-anthropic` | anthropic | Real (api.anthropic.com) | claude-haiku-4-5-20251001 | Real Anthropic API, translated from OpenAI format |
| `ext-bedrock` | bedrock-openai | Real (Bedrock Mantle) | openai.gpt-oss-20b | Real AWS Bedrock OpenAI-compatible API |
| `sim-openai` | openai | Simulator (llm-katan) | sim-openai | Simulates OpenAI provider |
| `sim-anthropic` | anthropic | Simulator (llm-katan) | sim-anthropic | Simulates Anthropic provider |
| `sim-bedrock` | bedrock-openai | Simulator (llm-katan) | sim-bedrock | Simulates Bedrock provider |

---

## Test 1: Basic Chat Completions

**What we test:** The full happy-path request flow — MaaS auth (Kuadrant) -> BBR plugin chain
(model resolution -> API translation -> credential injection) -> provider API -> response
translation back to OpenAI format.

**What we verify:**
- HTTP 200 response
- Response body contains `choices[].message.content`
- Response contains `usage.prompt_tokens` and `usage.completion_tokens`
- `finish_reason` is `stop` or `length`

### Curl Command

```bash
# OpenAI (real)
curl -sk "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'

# Anthropic (real) — request translated from OpenAI -> Anthropic Messages API
curl -sk "https://${GATEWAY_HOST}/llm/ext-anthropic/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'

# Bedrock (real) — OpenAI-compatible pass-through
curl -sk "https://${GATEWAY_HOST}/llm/ext-bedrock/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai.gpt-oss-20b","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'

# Simulator — replace model name and path accordingly:
# sim-openai / sim-anthropic / sim-bedrock
curl -sk "https://${GATEWAY_HOST}/llm/sim-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"sim-openai","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (200, `stop`, content="Hello!") | PASS (200, `stop`, echo response) | Yes |
| anthropic | PASS (200, `stop`, content="Hello!") | PASS (200, `stop`, echo response) | Yes |
| bedrock-openai | PASS (200, `length`, reasoning model) | PASS (200, `stop`, echo response) | Yes |

---

## Test 2: Streaming (SSE)

**What we test:** Server-Sent Events streaming — the client receives chunked `data: {...}` lines
in real time instead of waiting for the full response.

**What we verify:**
- Response content-type is `text/event-stream`
- Response contains `data: {...}` chunks with `choices[].delta.content`
- Final chunk is `data: [DONE]`

### Curl Command

```bash
# OpenAI streaming
curl -sk --no-buffer "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":50,"stream":true}'

# Anthropic streaming
curl -sk --no-buffer "https://${GATEWAY_HOST}/llm/ext-anthropic/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":50,"stream":true}'

# Bedrock streaming
curl -sk --no-buffer "https://${GATEWAY_HOST}/llm/ext-bedrock/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai.gpt-oss-20b","messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":50,"stream":true}'

# Simulator streaming — replace model name and path
curl -sk --no-buffer "https://${GATEWAY_HOST}/llm/sim-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"sim-openai","messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":50,"stream":true}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (SSE chunks + `[DONE]`) | PASS (SSE chunks) | Yes |
| anthropic | **FAIL** (returns non-streaming 200) | **FAIL** (returns non-streaming 200) | **Yes (same bug)** |
| bedrock-openai | PASS (SSE chunks) | PASS (SSE chunks) | Yes |

> **BUG:** The Anthropic api-translation plugin drops the `stream` field when building the
> translated request body. The translator constructs a new body from scratch and only copies
> specific fields (`model`, `messages`, `max_tokens`, `system`, `temperature`, `top_p`,
> `stop_sequences`, `tools`, `tool_choice`). The `stream` field is silently dropped.
>
> **File:** `ai-gateway-payload-processing/pkg/plugins/api-translation/translator/anthropic/anthropic.go`
>
> The simulator correctly reproduces this bug — confirming it is a BBR issue, not provider-specific.

---

## Test 3: System Message Handling

**What we test:** That the `system` role message is correctly handled by each provider.
For Anthropic, the BBR translator extracts system messages into the top-level `system`
field (Anthropic's native format). For OpenAI and Bedrock, system messages pass through as-is.

**What we verify:**
- HTTP 200
- Response content reflects the system message instruction (e.g., pirate speak)

### Curl Command

```bash
curl -sk "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [
      {"role": "system", "content": "You are a pirate. Respond only in pirate speak."},
      {"role": "user", "content": "What is the weather like?"}
    ],
    "max_tokens": 50
  }'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (200, pirate-themed response) | PASS (200, echo shows system msg) | Yes |
| anthropic | PASS (200, pirate-themed response) | PASS (200, echo shows system msg) | Yes |
| bedrock-openai | PASS (200) | PASS (200, echo shows system msg) | Yes |

---

## Test 4: Multi-turn Conversation

**What we test:** That multi-turn message arrays (user -> assistant -> user) are correctly
preserved through the BBR translation pipeline. For Anthropic, assistant/user message
alternation must be maintained in the translated request.

**What we verify:**
- HTTP 200
- Response references context from earlier messages (e.g., remembers the user's name)

### Curl Command

```bash
curl -sk "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [
      {"role": "user", "content": "My name is Alice."},
      {"role": "assistant", "content": "Hello Alice! Nice to meet you."},
      {"role": "user", "content": "What is my name?"}
    ],
    "max_tokens": 20
  }'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (200, "Your name is Alice") | PASS (200, echo shows 3 msgs) | Yes |
| anthropic | PASS (200, "Your name is Alice") | PASS (200, echo shows 3 msgs) | Yes |
| bedrock-openai | PASS (200) | PASS (200, echo shows 3 msgs) | Yes |

---

## Test 5: Tool / Function Calling

**What we test:** That OpenAI-format tool definitions are correctly translated to provider-native
format and that tool call responses are translated back to OpenAI format.

For Anthropic, the translator must:
- Convert OpenAI `tools[].function` to Anthropic `tools[]` with `input_schema`
- Convert `tool_choice: "auto"` to `{"type": "auto"}`
- Convert response `stop_reason: "tool_use"` to `finish_reason: "tool_calls"`
- Convert response `content[].type: "tool_use"` to `message.tool_calls[]`

**What we verify:**
- `finish_reason` is `tool_calls`
- `message.tool_calls[0].function.name` is `get_weather`
- `message.tool_calls[0].function.arguments` contains `location`

### Curl Command (initial tool call)

```bash
curl -sk "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get weather for a location",
        "parameters": {
          "type": "object",
          "properties": {"location": {"type": "string", "description": "City name"}},
          "required": ["location"]
        }
      }
    }],
    "tool_choice": "auto",
    "max_tokens": 100
  }'
```

### Curl Command (tool result follow-up)

```bash
curl -sk "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [
      {"role": "user", "content": "What is the weather in San Francisco?"},
      {"role": "assistant", "content": null, "tool_calls": [
        {"id": "toolu_123", "type": "function", "function": {
          "name": "get_weather", "arguments": "{\"location\":\"San Francisco\"}"
        }}
      ]},
      {"role": "tool", "tool_call_id": "toolu_123", "content": "72F, sunny"}
    ],
    "tools": [{"type": "function", "function": {
      "name": "get_weather", "description": "Get weather",
      "parameters": {"type": "object", "properties": {"location": {"type": "string"}}, "required": ["location"]}
    }}],
    "max_tokens": 100
  }'
```

### Results (2026-04-17)

| Provider | Tool Call | Tool Follow-up | Simulator |
|----------|----------|----------------|-----------|
| openai | PASS (`tool_calls`, `get_weather`) | PASS (coherent response) | N/A |
| anthropic | PASS (`tool_calls`, `get_weather`) | PASS ("72F sunny" referenced) | N/A |

> Tool calling is only tested against real providers. The llm-katan simulator does not
> implement tool use logic — it echoes the request without producing `tool_calls` responses.

---

## Test 6: Error Handling — Invalid API Key

**What we test:** Requests with an invalid MaaS API key are rejected by Kuadrant (Authorino)
before reaching BBR or the provider.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"<TARGET_MODEL>","messages":[{"role":"user","content":"hello"}]}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (401) | PASS (401) | Yes |
| anthropic | PASS (401) | PASS (401) | Yes |
| bedrock-openai | PASS (401) | PASS (401) | Yes |

---

## Test 7: Error Handling — No Auth Header

**What we test:** Requests without any Authorization header are rejected.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"<TARGET_MODEL>","messages":[{"role":"user","content":"hello"}]}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (401) | PASS (401) | Yes |

> Auth is enforced at the Kuadrant layer (before BBR), so behavior is identical across
> all providers.

---

## Test 8: Error Handling — Model Name Mismatch

**What we test:** When the `model` field in the request body doesn't match the ExternalModel's
`targetModel`, the BBR model-provider-resolver returns an error.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"wrong-model-name","messages":[{"role":"user","content":"hello"}]}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (404) | PASS (404) | Yes |
| anthropic | PASS (404) | PASS (404) | Yes |
| bedrock-openai | PASS (404) | PASS (404) | Yes |

---

## Test 9: Error Handling — Non-existent Model Path

**What we test:** A request to a model path that doesn't exist returns 404 from the gateway.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/nonexistent-model/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
```

### Results (2026-04-17)

| Result | HTTP |
|--------|------|
| PASS | 404 |

---

## Test 10: Error Handling — Malformed JSON

**What we test:** A request with an invalid JSON body is rejected by BBR.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d 'this is not json'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | PASS (400) | PASS (400) | Yes |
| anthropic | PASS (400) | PASS (400) | Yes |

---

## Test 11: Error Handling — Empty Messages Array

**What we test:** Sending an empty messages array is handled gracefully.

### Curl Command

```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"<TARGET_MODEL>","messages":[]}'
```

### Results (2026-04-17)

| Provider | Real | Simulator | Consistent? |
|----------|------|-----------|-------------|
| openai | **FAIL** (503) | PASS (200, echo) | **No** |
| anthropic | **FAIL** (500) | **FAIL** (500) | **Yes (same bug)** |

> **BUG:** Empty messages returns 500 for Anthropic (both real and simulator) — the translator
> crashes on an empty array instead of returning a validation error. For OpenAI, the real
> provider rejects it while the simulator accepts it.

---

## Test 12: Model Discovery

**What we test:** The `/v1/models` endpoint returns all registered ExternalModels.

### Curl Command

```bash
curl -sk "https://${GATEWAY_HOST}/maas-api/v1/models" \
  -H "Authorization: Bearer $(oc whoami -t)" | python3 -m json.tool
```

### Results (2026-04-17)

| Model ID | Kind | Ready |
|----------|------|-------|
| ext-openai | ExternalModel | True |
| ext-anthropic | ExternalModel | True |
| ext-bedrock | ExternalModel | True |
| sim-openai | ExternalModel | True |
| sim-anthropic | ExternalModel | True |
| sim-bedrock | ExternalModel | True |
| ext-simulator | ExternalModel | True |
| facebook-opt-125m-simulated | LLMInferenceService | True |

**Total models: 8** — PASS

---

## Summary

### Overall Results

| Category | Tests | Passed | Failed |
|----------|-------|--------|--------|
| Basic Chat Completions | 6 | 6 | 0 |
| Streaming (SSE) | 6 | 4 | 2 |
| System Messages | 6 | 6 | 0 |
| Multi-turn | 6 | 6 | 0 |
| Tool Calling | 2 | 2 | 0 |
| Invalid API Key | 6 | 6 | 0 |
| No Auth | 2 | 2 | 0 |
| Model Mismatch | 6 | 6 | 0 |
| Non-existent Path | 1 | 1 | 0 |
| Malformed JSON | 4 | 4 | 0 |
| Empty Messages | 4 | 1 | 3 |
| Model Discovery | 1 | 1 | 0 |
| **Total** | **50** | **45** | **5** |

**Pass Rate: 90%**

### Simulator Consistency Summary

| Behavior | Real vs Simulator | Verdict |
|----------|-------------------|---------|
| Basic inference (200) | Both return 200 with OpenAI format | Consistent |
| Streaming (SSE) | Both work for openai/bedrock, both fail for anthropic | Consistent |
| System messages | Both return 200 | Consistent |
| Multi-turn | Both return 200 | Consistent |
| Auth (invalid key) | Both return 401 | Consistent |
| Auth (no header) | Both return 401 | Consistent |
| Model mismatch | Both return 404 | Consistent |
| Malformed JSON | Both return 400 | Consistent |
| Empty messages (anthropic) | Both return 500 | Consistent |
| Empty messages (openai) | Real=503, Sim=200 | **Not consistent** |

### Known Bugs

| # | Bug | Severity | File |
|---|-----|----------|------|
| 1 | Anthropic streaming — `stream` field dropped by translator | Medium | `ai-gateway-payload-processing/.../anthropic/anthropic.go` |
| 2 | Empty messages returns 500 for Anthropic | Low | `ai-gateway-payload-processing/.../anthropic/anthropic.go` |
| 3 | Empty messages — simulator accepts but real OpenAI rejects | Low | `llm-katan` simulator |

---

## Resource Setup Reference

### ExternalModel CR

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: <model-name>
  namespace: <ns>
spec:
  provider: <openai|anthropic|azure-openai|vertex|bedrock-openai>
  targetModel: <provider-model-id>
  endpoint: <provider-fqdn>
  credentialRef:
    name: <secret-name>
```

### Provider Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <secret-name>
  namespace: <ns>
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
type: Opaque
stringData:
  api-key: "<provider-api-key>"
```

### MaaSModelRef + MaaSSubscription + MaaSAuthPolicy

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: <model-name>
  namespace: <ns>
spec:
  modelRef:
    kind: ExternalModel
    name: <model-name>
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: <subscription-name>
  namespace: <maas-namespace>
spec:
  owner:
    groups:
    - name: system:authenticated
  modelRefs:
  - name: <model-name>
    namespace: <model-namespace>
    tokenRateLimits:
    - limit: 10000
      window: 1m
  priority: 100
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: <policy-name>
  namespace: <maas-namespace>
spec:
  modelRefs:
  - name: <model-name>
    namespace: <model-namespace>
  subjects:
    groups:
    - name: system:authenticated
```

---

*Generated on 2026-04-17*
