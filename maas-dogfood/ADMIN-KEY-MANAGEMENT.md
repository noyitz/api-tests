# MaaS Dogfood — Admin Guide: Teams, Users, and API Keys

How to onboard a team onto the MaaS gateway as a cluster admin: create a team
(subscription + group), mint an API key per user, revoke keys, and hand users a
working Claude Code setup. All operations are `oc` + `curl`, so they are easy to
automate.

Author: Noy Itzikowitz

## Concepts

| Thing | What it is |
|---|---|
| **User** | Implicit — created on first key mint. Identified by the `X-MaaS-Username` you pass when minting. Per-user usage/cost shows on the metering dashboard. |
| **Group (team)** | A string label stored on each key at mint time (from the `X-MaaS-Group` header). Shown in the dashboard GROUP column. Not a standalone object. |
| **Subscription** | A `MaaSSubscription` CR — defines model access and token rate limits. Every key references one. Its `owner.groups` list controls which groups may mint keys under it. |

A "team" is therefore: one subscription + one group string + one key per member.

## Prerequisites

- `oc` logged in to the cluster as admin.
- Two variables used throughout:

```bash
export GATEWAY_URL=https://<maas-gateway-route>          # e.g. https://maas.apps.<cluster-domain>
export MAAS_API=https://localhost:18443                  # via the port-forward below
```

- The maas-api is not exposed externally; open a tunnel to it (keep it running
  in a separate terminal, or wrap it in your automation):

```bash
oc port-forward svc/maas-api 18443:8443 -n redhat-ods-applications
```

## 1. One-time per team: create the subscription

Create a `MaaSSubscription` named after the team. `owner.groups` must include
the team group so members' keys can be minted under it.

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: product                    # team name
  namespace: models-as-a-service
spec:
  modelRefs:
  - name: claude-sonnet-4-6
    namespace: llm
    tokenRateLimits:
    - limit: 10000000
      window: 1m
  - name: claude-opus-4-6
    namespace: llm
    tokenRateLimits:
    - limit: 10000000
      window: 1m
  - name: claude-haiku-4-5
    namespace: llm
    tokenRateLimits:
    - limit: 10000000
      window: 1m
  owner:
    groups:
    - name: product                # the team group
    - name: system:authenticated
  priority: 20
```

```bash
oc apply -f subscription-product.yaml
```

**Important (this environment only):** the maas-controller is intentionally
scaled to 0, so the subscription will not reconcile on its own. Activate it
manually after every apply:

```bash
oc patch maassubscription product -n models-as-a-service \
  --subresource=status --type=merge -p '{"status":{"phase":"Active"}}'
```

## 2. Mint a key for a user

One call per user. The username and group are taken from headers; the body
names the key and binds it to the subscription. Keys expire after 90 days.

```bash
curl -sk $MAAS_API/v1/api-keys -X POST \
  -H "Content-Type: application/json" \
  -H "X-MaaS-Username: <username>" \
  -H 'X-MaaS-Group: ["product"]' \
  -d '{"name":"<username>-dogfood","subscription":"product"}'
```

Response — deliver `key` to the user, keep `id` for revocation:

```json
{
  "key": "sk-oai-...",
  "id": "74ffde85-...",
  "name": "<username>-dogfood",
  "subscription": "product",
  "expiresAt": "2026-10-07T21:24:47Z"
}
```

The group you mint with is what the dashboard shows for every request made with
that key — to move a user to another team, revoke and re-mint (see below).

## 3. Verify the key works

```bash
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST $GATEWAY_URL/v1/messages \
  -H "x-api-key: <the-new-key>" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
```

Expect `HTTP 200`. An invalid key returns `403`. Within a minute the request
appears on the metering dashboard attributed to the user and group.

## 4. Revoke a key

```bash
curl -sk -o /dev/null -w "HTTP %{http_code}\n" -X DELETE $MAAS_API/v1/api-keys/<key-id> \
  -H "X-MaaS-Username: <username>" \
  -H 'X-MaaS-Group: ["product"]'
```

## 5. Automating team onboarding

Everything above composes into a loop. Example — mint keys for a member list
and emit a `user,key` CSV:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEAM=product
MEMBERS=(alice bob carol)

oc port-forward svc/maas-api 18443:8443 -n redhat-ods-applications >/dev/null 2>&1 &
PF_PID=$!; trap 'kill $PF_PID' EXIT; sleep 3

for u in "${MEMBERS[@]}"; do
  key=$(curl -sk https://localhost:18443/v1/api-keys -X POST \
    -H "Content-Type: application/json" \
    -H "X-MaaS-Username: $u" \
    -H "X-MaaS-Group: [\"$TEAM\"]" \
    -d "{\"name\":\"$u-dogfood\",\"subscription\":\"$TEAM\"}" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["key"])')
  echo "$u,$key"
done
```

## 6. What to send each user

Claude Code setup — add to `~/.zshrc` (or `~/.bashrc`), then `source` it and
launch with `claude-maas`:

```bash
claude-maas() {
  CLAUDE_CODE_USE_VERTEX= ANTHROPIC_VERTEX_PROJECT_ID= CLOUD_ML_REGION= \
  ANTHROPIC_BASE_URL=<gateway-url> \
  ANTHROPIC_API_KEY=<their-key> \
  ANTHROPIC_MODEL=claude-sonnet-4-6 \
  ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5 \
  claude "$@"
}
```

User-facing notes:

1. The startup banner must **not** say "Google Vertex AI" — if it does, a
   direct-Vertex env var is overriding the gateway; launch via `claude-maas`.
2. Available models: `claude-sonnet-4-6` (default), `claude-opus-4-6`,
   `claude-haiku-4-5`. Switch with the full ID (`/model claude-opus-4-6`).
   The entries in the `/model` picker menu are Anthropic's stock lineup and do
   not exist on this gateway.
3. Per-user usage and cost appear on the metering dashboard.
