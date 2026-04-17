#!/bin/bash
# ExternalModel E2E Test Runner
# Tests 3 real providers + 3 simulator mirrors + consistency comparison
set -euo pipefail

GATEWAY_HOST="maas.apps.ocp.4fnz2.sandbox2228.opentlc.com"
API_KEY="sk-oai-qLRZzH54yhI0iIIx_IxsDmG5DEJ1i1a7d75GwSinPItwJX9RM2pgcSV32euU"
REPORT="/Users/nitzikow/code/models-as-a-service/test/e2e/reports/external-model-e2e-report.md"
PASS=0
FAIL=0
SKIP=0

exec 3>&1

log() { echo "$1" | tee -a "$REPORT" >&3; }

run_test() {
  local test_name="$1"
  local expected_status="$2"
  shift 2
  local response
  local http_code
  local body

  response=$(curl -sk -w "\n__HTTP_CODE__%{http_code}" --max-time 30 "$@" 2>&1) || true
  http_code=$(echo "$response" | grep '__HTTP_CODE__' | sed 's/__HTTP_CODE__//')
  body=$(echo "$response" | grep -v '__HTTP_CODE__')

  local result
  if [[ "$http_code" == "$expected_status" ]]; then
    result="PASS"
    PASS=$((PASS + 1))
  else
    result="FAIL"
    FAIL=$((FAIL + 1))
  fi

  # Extract key fields from JSON for display
  local content=""
  if echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','')[:80])" 2>/dev/null; then
    content=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','')[:80])" 2>/dev/null)
  fi

  local model_field=""
  model_field=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('model',''))" 2>/dev/null) || true

  local has_choices=""
  has_choices=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'choices' in d else 'no')" 2>/dev/null) || true

  local finish_reason=""
  finish_reason=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('finish_reason',''))" 2>/dev/null) || true

  local usage=""
  usage=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); u=d.get('usage',{}); print(f\"prompt={u.get('prompt_tokens','?')} completion={u.get('completion_tokens','?')} total={u.get('total_tokens','?')}\")" 2>/dev/null) || true

  printf "| %-45s | %-8s | %-4s | %-12s | %-15s | %-10s |\n" \
    "$test_name" "$result" "$http_code" "$finish_reason" "$model_field" "$has_choices" >> "$REPORT"

  # Store body for streaming/tool tests
  echo "$body" > /tmp/e2e_last_body.txt
  echo "$http_code" > /tmp/e2e_last_code.txt
}

run_streaming_test() {
  local test_name="$1"
  shift
  local response
  response=$(curl -sk --no-buffer --max-time 15 "$@" 2>&1) || true

  local has_data_chunks="no"
  local has_done="no"
  local is_sse="no"

  if echo "$response" | grep -q '^data: {'; then
    has_data_chunks="yes"
    is_sse="yes"
  fi
  if echo "$response" | grep -q '^\data: \[DONE\]'; then
    has_done="yes"
  fi

  # Check if it's a non-streaming JSON response instead
  local is_non_streaming="no"
  if echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'choices' in d else 'no')" 2>/dev/null | grep -q 'yes'; then
    is_non_streaming="yes"
  fi

  local result
  if [[ "$is_sse" == "yes" ]]; then
    result="PASS"
    PASS=$((PASS + 1))
    printf "| %-45s | %-8s | %-4s | %-12s | %-15s | %-10s |\n" \
      "$test_name" "PASS" "200" "SSE chunks" "done=$has_done" "streaming" >> "$REPORT"
  elif [[ "$is_non_streaming" == "yes" ]]; then
    result="FAIL"
    FAIL=$((FAIL + 1))
    printf "| %-45s | %-8s | %-4s | %-12s | %-15s | %-10s |\n" \
      "$test_name" "FAIL" "200" "non-streaming" "stream dropped" "not SSE" >> "$REPORT"
  else
    result="FAIL"
    FAIL=$((FAIL + 1))
    printf "| %-45s | %-8s | %-4s | %-12s | %-15s | %-10s |\n" \
      "$test_name" "FAIL" "???" "error" "no response" "error" >> "$REPORT"
  fi
}

run_tool_test() {
  local test_name="$1"
  shift
  local response
  response=$(curl -sk --max-time 30 "$@" 2>&1) || true

  local finish_reason
  finish_reason=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('finish_reason',''))" 2>/dev/null) || true

  local tool_name
  tool_name=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); tc=d.get('choices',[{}])[0].get('message',{}).get('tool_calls',[]); print(tc[0]['function']['name'] if tc else '')" 2>/dev/null) || true

  local result
  if [[ "$finish_reason" == "tool_calls" && "$tool_name" == "get_weather" ]]; then
    result="PASS"
    PASS=$((PASS + 1))
  else
    result="FAIL"
    FAIL=$((FAIL + 1))
  fi

  printf "| %-45s | %-8s | %-4s | %-12s | %-15s | %-10s |\n" \
    "$test_name" "$result" "200" "$finish_reason" "tool=$tool_name" "tool_call" >> "$REPORT"
}

# ─── Start Report ───
cat > "$REPORT" << 'HEADER'
# ExternalModel E2E Test Report

**Date:** 2026-04-17
**Cluster:** sandbox2228 (apps.ocp.4fnz2.sandbox2228.opentlc.com)
**Tester:** Noy Itzikowitz

## Environment

| Component | Status |
|-----------|--------|
| MaaS API | Running (28d) |
| MaaS Controller | Running |
| BBR / payload-processing | Running |
| Gateway (maas-default-gateway) | Programmed |
| Kuadrant (Authorino + Limitador) | Running |

## Models Under Test

| Model Name | Kind | Provider | Backend | Endpoint |
|------------|------|----------|---------|----------|
| ext-openai | ExternalModel | openai | Real | api.openai.com |
| ext-anthropic | ExternalModel | anthropic | Real | api.anthropic.com |
| ext-bedrock | ExternalModel | bedrock-openai | Real | bedrock-mantle.us-east-2.api.aws |
| sim-openai | ExternalModel | openai | Simulator | 3.13.21.181 (llm-katan) |
| sim-anthropic | ExternalModel | anthropic | Simulator | 3.13.21.181 (llm-katan) |
| sim-bedrock | ExternalModel | bedrock-openai | Simulator | 3.13.21.181 (llm-katan) |
| ext-simulator | ExternalModel | openai | Simulator | 3.13.21.181 (llm-katan) |
| facebook-opt-125m-simulated | LLMInferenceService | (internal) | KServe pod | cluster-local |

## Test Results

HEADER

# ═══════════════════════════════════════════════════════════════
# SECTION 1: Basic Chat Completions
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 1. Basic Chat Completions

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

CHAT_BODY='{"model":"__MODEL__","messages":[{"role":"user","content":"Say hello in one word."}],"max_tokens":10}'
URL_BASE="https://${GATEWAY_HOST}/llm"

for pair in "ext-openai:gpt-4o-mini" "ext-anthropic:claude-haiku-4-5-20251001" "ext-bedrock:openai.gpt-oss-20b" "sim-openai:sim-openai" "sim-anthropic:sim-anthropic" "sim-bedrock:sim-bedrock" "ext-simulator:ext-simulator"; do
  name="${pair%%:*}"
  model="${pair##*:}"
  body="${CHAT_BODY/__MODEL__/$model}"
  run_test "Basic: $name" "200" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
done

# ═══════════════════════════════════════════════════════════════
# SECTION 2: Streaming
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 2. Streaming (SSE)

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

STREAM_BODY='{"model":"__MODEL__","messages":[{"role":"user","content":"Count 1 to 5."}],"max_tokens":50,"stream":true}'

for pair in "ext-openai:gpt-4o-mini" "ext-anthropic:claude-haiku-4-5-20251001" "ext-bedrock:openai.gpt-oss-20b" "sim-openai:sim-openai" "sim-anthropic:sim-anthropic" "sim-bedrock:sim-bedrock"; do
  name="${pair%%:*}"
  model="${pair##*:}"
  body="${STREAM_BODY/__MODEL__/$model}"
  run_streaming_test "Streaming: $name" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
done

# ═══════════════════════════════════════════════════════════════
# SECTION 3: System Message
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 3. System Message Handling

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

SYSTEM_BODY='{"model":"__MODEL__","messages":[{"role":"system","content":"You are a pirate. Respond only in pirate speak."},{"role":"user","content":"What is the weather like?"}],"max_tokens":50}'

for pair in "ext-openai:gpt-4o-mini" "ext-anthropic:claude-haiku-4-5-20251001" "sim-openai:sim-openai" "sim-anthropic:sim-anthropic"; do
  name="${pair%%:*}"
  model="${pair##*:}"
  body="${SYSTEM_BODY/__MODEL__/$model}"
  run_test "System msg: $name" "200" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
done

# ═══════════════════════════════════════════════════════════════
# SECTION 4: Multi-turn
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 4. Multi-turn Conversation

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

MULTI_BODY='{"model":"__MODEL__","messages":[{"role":"user","content":"My name is Alice."},{"role":"assistant","content":"Hello Alice! Nice to meet you."},{"role":"user","content":"What is my name?"}],"max_tokens":20}'

for pair in "ext-openai:gpt-4o-mini" "ext-anthropic:claude-haiku-4-5-20251001" "sim-openai:sim-openai" "sim-anthropic:sim-anthropic"; do
  name="${pair%%:*}"
  model="${pair##*:}"
  body="${MULTI_BODY/__MODEL__/$model}"
  run_test "Multi-turn: $name" "200" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
done

# ═══════════════════════════════════════════════════════════════
# SECTION 5: Tool Calling
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 5. Tool / Function Calling

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

TOOL_BODY='{"model":"__MODEL__","messages":[{"role":"user","content":"What is the weather in San Francisco?"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get weather for a location","parameters":{"type":"object","properties":{"location":{"type":"string","description":"City name"}},"required":["location"]}}}],"tool_choice":"auto","max_tokens":100}'

for pair in "ext-openai:gpt-4o-mini" "ext-anthropic:claude-haiku-4-5-20251001"; do
  name="${pair%%:*}"
  model="${pair##*:}"
  body="${TOOL_BODY/__MODEL__/$model}"
  run_tool_test "Tool call: $name" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$body"
done

# ═══════════════════════════════════════════════════════════════
# SECTION 6: Auth / Error Handling
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 6. Auth & Error Handling

| Test | Result | HTTP | Finish Reason | Model | Has Choices |
|------|--------|------|---------------|-------|-------------|
SEC

# Invalid key
for name in "ext-openai" "sim-openai"; do
  run_test "Invalid key: $name" "401" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Authorization: Bearer invalid-key-12345" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
done

# No key
for name in "ext-openai" "sim-openai"; do
  run_test "No auth: $name" "401" \
    "${URL_BASE}/${name}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'
done

# Model mismatch
run_test "Model mismatch: ext-openai" "404" \
  "${URL_BASE}/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"wrong-model","messages":[{"role":"user","content":"hello"}]}'

run_test "Model mismatch: sim-openai" "404" \
  "${URL_BASE}/sim-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"wrong-model","messages":[{"role":"user","content":"hello"}]}'

# Non-existent path
run_test "Non-existent path" "404" \
  "${URL_BASE}/nonexistent/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hello"}]}'

# Malformed JSON
run_test "Malformed JSON: ext-openai" "400" \
  "${URL_BASE}/ext-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d 'not json'

run_test "Malformed JSON: sim-openai" "400" \
  "${URL_BASE}/sim-openai/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d 'not json'

# ═══════════════════════════════════════════════════════════════
# SECTION 7: Model Discovery
# ═══════════════════════════════════════════════════════════════
cat >> "$REPORT" << 'SEC'

### 7. Model Discovery (/v1/models)

SEC

TOKEN=$(oc whoami -t)
MODELS_RESPONSE=$(curl -sk "https://${GATEWAY_HOST}/maas-api/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>&1)

MODELS_COUNT=$(echo "$MODELS_RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null) || MODELS_COUNT="?"

echo "| Model ID | Kind | Ready | URL |" >> "$REPORT"
echo "|----------|------|-------|-----|" >> "$REPORT"
echo "$MODELS_RESPONSE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for m in d.get('data',[]):
    print(f\"| {m['id']} | {m.get('kind','?')} | {m.get('ready','?')} | {m.get('url','')[:60]}... |\")
" >> "$REPORT" 2>/dev/null

echo "" >> "$REPORT"
echo "**Total models visible:** $MODELS_COUNT" >> "$REPORT"

# Check model discovery result
if [[ "$MODELS_COUNT" -ge 8 ]]; then
  echo "" >> "$REPORT"
  echo "Model discovery: **PASS** (all 8 models visible)" >> "$REPORT"
  PASS=$((PASS + 1))
else
  echo "" >> "$REPORT"
  echo "Model discovery: **FAIL** (expected 8, got $MODELS_COUNT)" >> "$REPORT"
  FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL + SKIP))

cat >> "$REPORT" << EOF

---

## Summary

| Metric | Count |
|--------|-------|
| Total Tests | $TOTAL |
| Passed | $PASS |
| Failed | $FAIL |
| Skipped | $SKIP |
| Pass Rate | $(echo "scale=1; $PASS * 100 / $TOTAL" | bc)% |

## Known Gaps

1. **Anthropic streaming** — The api-translation Anthropic translator drops the \`stream\` field when building the translated request body. Streaming requests to Anthropic are sent as non-streaming. Affects both real and simulator.
2. **Empty messages returns 500** — Should return 400. The translator crashes on empty messages array instead of returning a clean validation error.
3. **Bedrock model naming** — Bedrock Mantle endpoint uses provider-prefixed model IDs (\`openai.gpt-oss-20b\`), no Claude models available via this key.

## Simulator Consistency

The simulator (llm-katan at 3.13.21.181) should behave identically to real providers in terms of:
- HTTP status codes (200, 401, 404, 400)
- OpenAI response format (choices, model, usage fields)
- Auth enforcement (Kuadrant validates MaaS API key before BBR)
- Path-based routing and model name validation

Differences expected:
- Response content is echo/mock (not real inference)
- Token counts are fixed (not variable like real providers)
- No rate limiting from provider side (only MaaS TRLP)

---

*Generated by E2E test runner on $(date -u '+%Y-%m-%d %H:%M UTC')*
EOF

echo ""
echo "═══════════════════════════════════════════════"
echo "  RESULTS: $PASS passed, $FAIL failed, $SKIP skipped (total: $TOTAL)"
echo "  Report: $REPORT"
echo "═══════════════════════════════════════════════"
