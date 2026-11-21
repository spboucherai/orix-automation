<!--
ORIX OS Automation
File: docs/release/live-provider-smoke.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Live provider smoke tests

Results of the `Live*` suites of `Packages/ORIXProviderAdapters`, run against the real provider APIs with the
developer-only keys injected by `Scripts/test/with-dev-keys.sh`. No key, key fragment or account identifier appears in
this file, in the test output or in the repository.

- **Date:** 2026-11-21
- **Command:** `Scripts/test/with-dev-keys.sh swift test` (from `Packages/ORIXProviderAdapters`; `--filter Live` runs the live suites alone)
- **Build:** debug (`DevEnvironmentCredentials` exists only under `#if DEBUG`; the release object has no such symbol)
- **Result:** 11 of 11 live tests passed; 57 mocked (`Fixture*`) tests passed in the same run
- **Kind of evidence:** live integration against the provider APIs from this Mac. Not a mocked result.

## Results

Latency is wall-clock for the whole test body after the model list was fetched (two requests for the round trips).
Token counts are the usage the provider reported, summed over the requests of the test.

| Provider | Test | Model id | Latency | Input tokens | Output tokens | Cost reported by provider | Result |
|---|---|---|---|---|---|---|---|
| Anthropic | list models (15 listed, 15 priced from the registry) | n/a | 210 ms | n/a | n/a | n/a | pass |
| Anthropic | streamed text, cap 16 | `claude-haiku-5-5` | 491 ms | 16 | 4 | not reported | pass |
| Anthropic | forced tool call → tool result → final text, cap 64 | `claude-haiku-5-5` | 925 ms | 1071 | 53 | not reported | pass |
| Anthropic | tool round trip with thinking on, thinking block replayed, cap 400 | `claude-haiku-5-5` | 1501 ms | 1005 | 124 | not reported | pass |
| OpenAI | list models (41 chat models kept, 39 priced from the registry) | n/a | 642 ms | n/a | n/a | n/a | pass |
| OpenAI | streamed text, cap 16 | `gpt-4o-mini` | 461 ms | 14 | 2 | not reported | pass |
| OpenAI | forced tool call → tool result → final text, cap 64 | `gpt-4o-mini` | 1690 ms | 214 | 19 | not reported | pass |
| OpenRouter | list models (441 in the catalog, 433 with a fixed price) | n/a | 494 ms | n/a | n/a | n/a | pass |
| OpenRouter | streamed text, cap 16 | `openai/gpt-4o-mini` | 560 ms | 14 | 2 | US$0.000003 | pass |
| OpenRouter | forced tool call → tool result → final text, cap 64 | `openai/gpt-4o-mini` | 1688 ms | 214 | 19 | US$0.000044 | pass |
| OpenRouter | cost reporting (`usage.cost` → `TokenUsage.reportedCostUSD`) | `openai/gpt-4o-mini` | 500 ms | 14 | 1 | US$0.000003 | pass |

## What each test checks

- **List models:** the call succeeds, every entry carries the provider id, and the smoke model is present with a known price.
- **Streamed text:** text arrives as stream deltas, the stream ends with a stop event (`endTurn` or `maxTokens`), reported
  output tokens are above zero and within the cap.
- **Tool round trip:** a tool definition is sent with a forced tool choice; the streamed call is parsed and its input
  validates against the declared schema; the result is sent back; the final text uses the result (`42`).
- **Thinking replay (Anthropic):** with thinking left on, the signed thinking block that preceded the tool call is
  re-inserted by the adapter when the call is replayed, and the API accepts it. The run above recorded
  `thinking-blocks-replayed-and-accepted`. An earlier run at low effort did not exercise the path (the model called the
  tool without thinking), so the test prompt now needs a calculation first.

## Cost

| Provider | Basis | Cost of one full live run |
|---|---|---|
| Anthropic | 2,092 input and 181 output tokens at US$0.10 / US$0.50 per MTok (registry prices) | about US$0.0003 |
| OpenAI | 228 input and 21 output tokens at US$0.15 / US$0.60 per MTok (registry prices) | about US$0.00005 |
| OpenRouter | sum of the reported costs | US$0.00005 |

One full run costs about US$0.0004. Everything run while developing the adapters on 2026-11-21 (two full runs and one
extra Anthropic round trip) comes to about US$0.001, against a budget of US$0.05.

## Limits of this evidence

- One model per provider was exercised. Other model ids are covered by the mocked suites and by the registry only.
- OpenRouter was exercised with an OpenAI upstream. Tool calling through other upstream providers was not run live.
- Not run live: prompt caching (the prompts are below every model's minimum cacheable size), structured outputs,
  image input, rate-limit and overload responses, and the retry wrapper. All of these have mocked tests only.
- The OpenAI Responses API is not used by this package, so nothing here speaks for it.

## Running without keys

Without the broker, each live test prints `SKIPPED(no ORIX_DEV_<PROVIDER>_API_KEY)` and returns: 11 skip lines
(4 Anthropic, 3 OpenAI, 4 OpenRouter), and the 57 mocked tests still run.
