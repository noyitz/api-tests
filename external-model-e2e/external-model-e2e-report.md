# ExternalModel E2E Test Report

**Date:** 2026-04-17  
**Version:** MaaS 3.5 (maas-controller + maas-api + BBR payload-processing)  
**Cluster:** RHOAI on OCP (AWS, NVIDIA L4 GPU)

## Overview

This report documents end-to-end testing of the ExternalModel feature, which enables MaaS
to route inference requests to external LLM providers (OpenAI, Anthropic, AWS Bedrock) through
the BBR (Body-Based Router) plugin chain. Tests cover 3 real providers and 3 simulator-mirrored
providers to validate both real inference and simulator consistency.

## Architecture

```
Client (curl / SDK)
  -> MaaS Gateway (Istio + Kuadrant auth)
     -> BBR ext_proc (payload-processing)
        -> Plugin 1: body-field-to-header (model -> X-Gateway-Model-Name)
        -> Plugin 2: model-provider-resolver (ExternalModel lookup, CycleState)
        -> Plugin 3: api-translation (OpenAI -> provider-native format)
        -> Plugin 4: apikey-injection (K8s Secret -> auth header)
     -> Provider API (real) or llm-katan simulator
```

## Prerequisites

```bash
# 1. Login to OpenShift
oc login <CLUSTER_API> -u <USER> -p <PASS> --insecure-skip-tls-verify

# 2. Set variables
export GATEWAY_HOST="<GATEWAY_HOSTNAME>"    # e.g., maas.apps.<cluster>
export TOKEN=$(oc whoami -t)

# 3. Mint a MaaS API key
curl -sk "https://${GATEWAY_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"e2e-test-key","subscription":"external-models-subscription"}'

# Copy the "key" field from the response:
export API_KEY="<MAAS_API_KEY>"
```

## Models Under Test

| Model Name | Kind | Provider | Backend | targetModel |
|------------|------|----------|---------|-------------|
| ext-openai | ExternalModel | openai | api.openai.com | gpt-4o-mini |
| ext-anthropic | ExternalModel | anthropic | api.anthropic.com | claude-haiku-4-5-20251001 |
| ext-bedrock | ExternalModel | bedrock-openai | bedrock-mantle (AWS) | openai.gpt-oss-20b |
| sim-openai | ExternalModel | openai | llm-katan simulator | sim-openai |
| sim-anthropic | ExternalModel | anthropic | llm-katan simulator | sim-anthropic |
| sim-bedrock | ExternalModel | bedrock-openai | llm-katan simulator | sim-bedrock |
| ext-simulator | ExternalModel | openai | llm-katan simulator | ext-simulator |
| facebook-opt-125m-simulated | LLMInferenceService | (internal) | KServe pod | N/A |

---

## Test 1: Basic Chat Completions

Validates the full request flow: auth -> BBR translation -> provider -> response translation.

### Curl Command (per model)

```bash
curl -sk "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [{"role": "user", "content": "Say hello in one word."}],
    "max_tokens": 10
  }'
```

Replace `<MODEL_NAME>` and `<TARGET_MODEL>` per the table above. Example for OpenAI:

```bash
curl -sk "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'
```

### Results

| Model | Result | HTTP | finish_reason | Response Model | Has choices |
|-------|--------|------|---------------|----------------|-------------|
| ext-openai | PASS | 200 | stop | gpt-4o-mini-2024-07-18 | yes |
| ext-anthropic | PASS | 200 | stop | claude-haiku-4-5-20251001 | yes |
| ext-bedrock | FAIL | 503 | - | - | - |
| sim-openai | PASS | 200 | stop | llm-katan-echo | yes |
| sim-anthropic | PASS | 200 | stop | sim-anthropic | yes |
| sim-bedrock | PASS | 200 | stop | llm-katan-echo | yes |
| ext-simulator | PASS | 200 | stop | llm-katan-echo | yes |

> **ext-bedrock 503**: Transient upstream error from Bedrock Mantle endpoint.
> Retrying succeeds. This is an intermittent provider-side issue, not a MaaS bug.

---

## Test 2: Streaming (SSE)

Validates Server-Sent Events streaming through the BBR pipeline.

### Curl Command

```bash
curl -sk --no-buffer "https://${GATEWAY_HOST}/llm/<MODEL_NAME>/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<TARGET_MODEL>",
    "messages": [{"role": "user", "content": "Count from 1 to 5."}],
    "max_tokens": 50,
    "stream": true
  }'
```

### Results

| Model | Result | HTTP | Details |
|-------|--------|------|---------|
| ext-openai | PASS | 200 | SSE chunks with `data: [DONE]` |
| ext-anthropic | **FAIL** | 200 | Non-streaming response returned (stream field dropped) |
| ext-bedrock | PASS | 200 | SSE chunks |
| sim-openai | PASS | 200 | SSE chunks |
| sim-anthropic | **FAIL** | 200 | Non-streaming response returned (stream field dropped) |
| sim-bedrock | PASS | 200 | SSE chunks |

> **Known Gap**: The Anthropic api-translation plugin builds a new request body from scratch
> and does not copy the `stream` field. Streaming requests to Anthropic providers are
> silently sent as non-streaming. This affects both real and simulator backends.
> File: `ai-gateway-payload-processing/pkg/plugins/api-translation/translator/anthropic/anthropic.go`

---

## Test 3: System Message Handling

Validates that system messages are correctly translated for each provider format.
For Anthropic, the system message is extracted into the top-level `system` field.

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

### Results

| Model | Result | HTTP | Verification |
|-------|--------|------|-------------|
| ext-openai | PASS | 200 | Pirate-themed response confirms system message applied |
| ext-anthropic | PASS | 200 | Pirate-themed response confirms system field translation |
| sim-openai | PASS | 200 | Echo confirms system message in request |
| sim-anthropic | PASS | 200 | Echo confirms system message in request |

---

## Test 4: Multi-turn Conversation

Validates that multi-turn message arrays are correctly preserved through translation.

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

### Results

| Model | Result | HTTP | Verification |
|-------|--------|------|-------------|
| ext-openai | PASS | 200 | Response: "Your name is Alice" |
| ext-anthropic | PASS | 200 | Response: "Your name is Alice" |
| sim-openai | PASS | 200 | Echo confirms 3 messages received |
| sim-anthropic | PASS | 200 | Echo confirms 3 messages received |

---

## Test 5: Tool / Function Calling

Validates OpenAI-format tool definitions are correctly translated to provider-native format
and tool call responses are translated back to OpenAI format.

### Curl Command (request with tools)

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
        {"id": "toolu_123", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\":\"San Francisco\"}"}}
      ]},
      {"role": "tool", "tool_call_id": "toolu_123", "content": "72F, sunny"}
    ],
    "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Get weather", "parameters": {"type": "object", "properties": {"location": {"type": "string"}}, "required": ["location"]}}}],
    "max_tokens": 100
  }'
```

### Results

| Model | Result | HTTP | finish_reason | Tool Name |
|-------|--------|------|---------------|-----------|
| ext-openai | PASS | 200 | tool_calls | get_weather |
| ext-anthropic | PASS | 200 | tool_calls | get_weather |

> For Anthropic: OpenAI `tools[]` are translated to Anthropic `tools[]` with `input_schema`.
> Tool call responses are translated from Anthropic `stop_reason: "tool_use"` to OpenAI
> `finish_reason: "tool_calls"`. Tool result messages (`role: "tool"`) are translated to
> Anthropic `tool_result` content blocks. All translations verified correct.

---

## Test 6: Auth & Error Handling

### Curl Commands

**Invalid API key (expect 401):**
```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer invalid-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
```

**No auth header (expect 401):**
```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
```

**Wrong model name in body (expect 404):**
```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"wrong-model","messages":[{"role":"user","content":"hello"}]}'
```

**Non-existent model path (expect 404):**
```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/nonexistent/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
```

**Malformed JSON body (expect 400):**
```bash
curl -sk -w "\nHTTP %{http_code}" \
  "https://${GATEWAY_HOST}/llm/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d 'this is not json'
```

### Results

| Test | Target | Result | HTTP | Expected |
|------|--------|--------|------|----------|
| Invalid API key | ext-openai | PASS | 401 | 401 |
| Invalid API key | sim-openai | PASS | 401 | 401 |
| No auth | ext-openai | PASS | 401 | 401 |
| No auth | sim-openai | PASS | 401 | 401 |
| Model mismatch | ext-openai | PASS | 404 | 404 |
| Model mismatch | sim-openai | PASS | 404 | 404 |
| Non-existent path | (any) | PASS | 404 | 404 |
| Malformed JSON | ext-openai | PASS | 400 | 400 |
| Malformed JSON | sim-openai | PASS | 400 | 400 |

> Auth enforcement is handled by Kuadrant (Authorino) before the request reaches BBR.
> Model name validation is handled by the BBR model-provider-resolver plugin.
> All error codes are consistent between real providers and the simulator.

---

## Test 7: Model Discovery

### Curl Command

```bash
curl -sk "https://${GATEWAY_HOST}/maas-api/v1/models" \
  -H "Authorization: Bearer $(oc whoami -t)" | python3 -m json.tool
```

### Results

| Model ID | Kind | Ready |
|----------|------|-------|
| ext-openai | ExternalModel | True |
| ext-anthropic | ExternalModel | True |
| ext-bedrock | ExternalModel | True |
| ext-simulator | ExternalModel | True |
| sim-openai | ExternalModel | True |
| sim-anthropic | ExternalModel | True |
| sim-bedrock | ExternalModel | True |
| facebook-opt-125m-simulated | LLMInferenceService | True |

**Total models visible: 8** - PASS

---

## Summary

| Metric | Count |
|--------|-------|
| Total Tests | 33 |
| Passed | 30 |
| Failed | 3 |
| Pass Rate | 90.9% |

### All Failures Explained

| Test | HTTP | Root Cause | Severity |
|------|------|-----------|----------|
| Basic: ext-bedrock | 503 | Transient Bedrock Mantle upstream error (retries succeed) | Low |
| Streaming: ext-anthropic | 200 (non-streaming) | Anthropic translator drops `stream` field | Medium |
| Streaming: sim-anthropic | 200 (non-streaming) | Same as above (confirms simulator matches real behavior) | Medium |

---

## Simulator Consistency Analysis

The llm-katan simulator mirrors real provider behavior for:

| Behavior | Real Provider | Simulator | Consistent? |
|----------|--------------|-----------|-------------|
| HTTP 200 on valid request | Yes | Yes | Yes |
| HTTP 401 on invalid key | Yes (Kuadrant) | Yes (Kuadrant) | Yes |
| HTTP 404 on model mismatch | Yes (BBR) | Yes (BBR) | Yes |
| HTTP 400 on malformed JSON | Yes (BBR) | Yes (BBR) | Yes |
| OpenAI response format | Yes | Yes | Yes |
| `choices[].message.content` | Real content | Echo/mock | Expected diff |
| `usage.prompt_tokens` | Variable | Fixed | Expected diff |
| Streaming (SSE) | Provider-dependent | Works for openai/bedrock | Yes |
| Anthropic streaming | Broken (stream dropped) | Broken (stream dropped) | Yes (same bug) |
| System messages | Applied by model | Echoed back | Expected diff |
| Multi-turn context | Understood by model | Echoed back | Expected diff |
| Tool calling | Executed by model | Not supported | Expected diff |

> The simulator correctly reproduces the MaaS + BBR infrastructure behavior (auth, routing,
> translation, error handling). Content differences are expected since the simulator echoes
> requests rather than performing inference.

---

## Known Gaps & Bugs

1. **Anthropic streaming broken** (Medium)  
   The `api-translation` Anthropic translator builds a new request body and does not copy the
   `stream` field. Streaming requests are silently downgraded to non-streaming.  
   **File:** `ai-gateway-payload-processing/pkg/plugins/api-translation/translator/anthropic/anthropic.go`

2. **Empty messages returns 500** (Low)  
   Sending `"messages": []` returns HTTP 500 instead of 400. The translator should validate
   the messages array before attempting translation.

3. **Bedrock model availability** (Info)  
   The Bedrock Mantle endpoint (`bedrock-mantle.us-east-2.api.aws`) does not list Claude models.
   Only `openai.gpt-oss-20b` and similar models are available via this key. The `openai.gpt-oss-20b`
   model is a reasoning model that returns content in a `reasoning` field instead of `content`.

4. **Simulator bedrock-openai key mismatch** (Info)  
   The llm-katan simulator validates API keys by endpoint path. Since `bedrock-openai` routes to
   `/v1/chat/completions` (same as OpenAI), the simulator expects the OpenAI key, not the Bedrock
   key. Use `llm-katan-openai-key` for simulator bedrock models.

---

## Resource Setup Reference

### ExternalModel CR

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: <model-name>        # client-facing model name
  namespace: <ns>
spec:
  provider: <openai|anthropic|azure-openai|vertex|bedrock-openai>
  targetModel: <provider-model-id>   # e.g., gpt-4o-mini
  endpoint: <provider-fqdn>          # e.g., api.openai.com (no scheme)
  credentialRef:
    name: <secret-name>              # Secret in same namespace
```

### Provider Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <secret-name>
  namespace: <ns>
  labels:
    inference.networking.k8s.io/bbr-managed: "true"   # required for BBR
type: Opaque
stringData:
  api-key: "<provider-api-key>"
```

### MaaSModelRef

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: <model-name>       # must match ExternalModel name
  namespace: <ns>
spec:
  modelRef:
    kind: ExternalModel
    name: <model-name>
```

### MaaSSubscription

```yaml
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
  priority: 100               # must be unique across subscriptions
```

### MaaSAuthPolicy

```yaml
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

*Generated on 2026-04-17. Test runner: `test/e2e/e2e-test-runner.sh`*
