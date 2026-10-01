# Web Tools

The Web Tools extension provides agents with web search and URL fetching capabilities. It supports multiple search providers and includes SSRF protection for secure deployments.

## Overview

| Property | Value |
|----------|-------|
| Extension ID | `botnexus-web` |
| Tool names | `web_search`, `web_fetch` |
| Source | `BotNexus.Extensions.WebTools` |

## Tools

### `web_search`

Search the web using a configurable provider and return formatted markdown results.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | Yes | Search query. |
| `count` | integer | No | Number of results to return (1 to maxResults). Overrides the configured default per call. |

### `web_fetch`

Fetch a URL and return content as readable text or raw HTML. Supports pagination for large pages.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `url` | string | Yes | URL to fetch. |
| `raw` | boolean | No | If true, return raw HTML; if false, convert to readable text. Default: false. |
| `max_length` | integer | No | Maximum characters to return. Default: 5000, max: 20000. |
| `start_index` | integer | No | Character offset for pagination. Default: 0. |

## Configuration

Configure in your agent's extension config block:

```json
{
  "extensions": {
    "botnexus-web": {
      "search": {
        "provider": "brave",
        "apiKey": "${env:BRAVE_API_KEY}",
        "maxResults": 5
      },
      "fetch": {
        "maxLengthChars": 20000,
        "timeoutSeconds": 30,
        "userAgent": "BotNexus/1.0 (compatible; bot)",
        "allowPrivateNetworks": false,
        "additionalBlockedHosts": [],
        "maxResponseBytes": 16777216
      }
    }
  }
}
```

### Search Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `provider` | string | `"brave"` | Search provider: `brave`, `tavily`, `bing`, `microsoft` (alias `microsoft-ai`), or `copilot`. |
| `apiKey` | string | — | API key for the search provider. Supports `${env:VAR}` syntax. |
| `maxResults` | integer | 5 | Maximum number of results to return. |

### Fetch Configuration

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `maxLengthChars` | integer | 20000 | Maximum content length in characters. |
| `timeoutSeconds` | integer | 30 | HTTP timeout in seconds. |
| `userAgent` | string | `"BotNexus/1.0 (compatible; bot)"` | User-Agent header for requests. |
| `allowPrivateNetworks` | boolean | false | Allow requests to private/loopback IPs. See [Security](#security). |
| `additionalBlockedHosts` | string[] | `[]` | Hostnames always blocked, even when `allowPrivateNetworks` is true. |
| `maxResponseBytes` | integer | 16777216 | Maximum bytes read from a fetched response body before the read is aborted. Because the fetched URL is fully agent-controlled, an oversized or maliciously streamed body is capped *during* the read to prevent an out-of-memory denial of service. Default: 16 MiB. |

## Search Providers

| Provider | API Key Required | Notes |
|----------|-----------------|-------|
| `brave` | Yes | Brave Search API. Set `BRAVE_API_KEY`. |
| `tavily` | Yes | Tavily Search API. Set `TAVILY_API_KEY`. |
| `bing` | Yes | Bing Web Search API. Set `BING_API_KEY`. |
| `microsoft` / `microsoft-ai` | Yes | Microsoft [Web IQ](https://webiq.microsoft.ai/) (`api.microsoft.ai/v3/search/web`). AI-grounding search built on Bing; returns rich markdown content. Sends the `x-apikey` header. |
| `copilot` | No | Uses GitHub Copilot MCP bridge (requires Copilot provider configured). |

> **Microsoft Web IQ** returns full-page markdown content per result; the provider truncates each
> result's content to keep search responses compact for the model's context window. Web IQ also
> exposes news, image, and video verticals (Beta) and an MCP (JSON-RPC 2.0) interface — see the
> [API reference](https://webiq.microsoft.ai/documentation/api-reference/web) — which BotNexus may
> surface as additional search options in future.

### Copilot search authentication

Copilot search requires a signed-in Copilot OAuth profile for the agent's selected provider
instance. A model-inference API key alone is not enough. Search uses the retained GitHub OAuth
credential; model inference continues to use the exchanged Copilot session credential.
The stored credential fields are not swapped or rewritten by search.

Only instances in the `github-copilot` or `copilot` provider family can supply search credentials.
An explicit provider `type` determines the family; otherwise the instance key is used.
Other provider families are rejected even when they have an OAuth profile.

Named provider instances keep their own authentication routing. A direct auth profile for the
instance takes precedence over its `auth:` reference. When no direct profile exists, search uses
the referenced profile rather than the default Copilot account. An unusable direct profile does
not fall through to the reference.
Enterprise endpoint selection is unchanged. If the selected OAuth credential is missing,
search reports that authentication is unavailable instead of using an inference token or
another account. Sign in to the selected provider profile again; do not paste credentials into
messages, logs, or documentation.

An HTTP 405 response to the initial MCP GET allows the existing transport to proceed with POST
initialization. HTTP 400 remains an error. A 405 response alone does not prove that initialization
or search succeeds; those steps require separate verification.

## Security

### SSRF Protection

By default, the fetch tool blocks requests to:

- Private IP ranges (10.x.x.x, 172.16-31.x.x, 192.168.x.x)
- Loopback addresses (127.0.0.1, ::1)
- Link-local addresses (169.254.x.x, fe80::)
- Cloud metadata endpoints (169.254.169.254)
- Reserved IP ranges

Set `allowPrivateNetworks: true` only for self-hosted deployments where agents legitimately need to reach internal services.

#### Reaching this gateway from an agent

The refusal covers the gateway's own loopback endpoints, so an agent **cannot** call
`http://localhost:5005/health` or `/api/logs/recent` with `web_fetch`. As of #2691 this restriction
is stated in the tool's own description rather than discovered at call time, so an agent can pick a
working approach before burning a turn. The sanctioned alternative is to issue the request from the
`shell`/`exec` tool against the local API.

### Host Blocking

Use `additionalBlockedHosts` to block specific hostnames that resolve to public IPs but serve internal content:

```json
{
  "additionalBlockedHosts": ["internal.corp.example", "secrets.internal"]
}
```

## Behavior Notes

- HTML content is automatically converted to readable text using an internal `HtmlToText` converter unless `raw: true` is specified.
- The fetch tool respects `max_length` and `start_index` for paginating through large documents.
- Search results are returned as formatted markdown with titles, URLs, and snippets.

## Related

- [Configuration Reference](/configuration) — Full platform configuration reference
