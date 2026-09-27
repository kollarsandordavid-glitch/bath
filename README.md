# Long Horizon Agent

Long Horizon Agent is a Zig 0.14.1 framework for durable, file-centered autonomous work. It treats the workspace as the authoritative state and rebuilds a deterministic, strictly bounded decision context before each model call. It supports recursive DAG planning, OpenAI-compatible inference, external document attention, controlled tools, resumable execution, and evaluation from real run artifacts.

## Core invariant

At step `t`, `F_t` denotes every authoritative workspace file and artifact. An accepted action `a_t` produces `F_(t+1) = T(F_t, a_t)`. The last `k` action summaries, with `k = 10` by default, are maintained as `recent_actions[t-k:t-1]`. The next reasoning context is `c_t_bounded = g(F_t, recent_actions[t-k:t-1])`. The function `g` is deterministic and enforces configured byte budgets. Full history grows only in `state/events.jsonl` and artifact files. The main model never receives the full event log, full documents, raw PDFs, or an unbounded conversation transcript.

## Requirements

Builds require Zig 0.14.1. Runtime PDF ingestion requires Poppler `pdftotext`. HTTPS uses Zig's standard TLS client and the host CA bundle. A real OpenAI-compatible endpoint and the environment variable named by `llm.api_key_env` are required for agent decisions and document answers. Web search requires a configured SearxNG JSON endpoint or configured commercial JSON endpoint and credential. Missing external services produce explicit errors rather than generated substitutes.

## Build and test

```sh
zig build
zig build test
./zig-out/bin/long-horizon-agent help
```

## Quick start

Create an objective file and edit a configuration copied from `config/default.config.json`.

```sh
cp config/default.config.json agent.config.json
printf '%s
' 'Investigate the evidence for the stated research question and write a cited report.' > objective.txt
export OPENAI_API_KEY='your-key'
zig build run -- init --workspace ./workspace --objective-file ./objective.txt --config ./agent.config.json
zig build run -- run --workspace ./workspace
zig build run -- status --workspace ./workspace --json
```

The configured model defaults to `gpt-oss-20b`; change `llm.model` to a model offered by the endpoint. The resolved configuration is copied into the workspace, and secrets are read from environment variables rather than serialized.

## CLI

| Command | Purpose |
| --- | --- |
| `init --workspace PATH --objective-file FILE --config FILE` | Create a complete durable workspace and root DAG node. |
| `run --workspace PATH` | Acquire the lock and execute until a terminal state or configured limit. |
| `resume --workspace PATH` | Reconstruct from files and continue execution. |
| `step --workspace PATH` | Execute one bounded decision step. |
| `status --workspace PATH [--json]` | Print task and DAG state. |
| `inspect-context --workspace PATH` | Print the exact current bounded context. |
| `consolidate --workspace PATH` | Rebuild progress and a consolidation artifact from events. |
| `tool document-ingest --workspace PATH --path FILE` | Copy, hash, extract, chunk, index, and register a document. |
| `tool document-answer --workspace PATH --document DOC --query QUERY` | Rank chunks with BM25 and answer through an isolated model call. |
| `eval deepresearch --config FILE --tasks FILE --out DIR` | Execute JSONL benchmark tasks in isolated workspaces and aggregate actual metrics. |
| `eval literature-review --config FILE --papers FILE --topic FILE --out DIR` | Ingest and review as many as 80 paper records using persistent evidence artifacts. |

Errors are emitted as JSON to standard error. Exit code 2 indicates invalid input, 3 a workspace lock, 4 credentials, 5 a provider, and 6 validation or evaluation failure.

## Configuration

`config/config.schema.json` defines every setting. Context budgets are byte limits, not advisory values. `tools.code_execution.enabled` is false by default. Search providers remain unavailable until their URL and, where required, key environment variable are configured. API keys are never persisted by configuration resolution or request logging.

## Workspace

Initialization creates task metadata, resolved configuration, event and manifest state, the recent-action ring, plan and progress files, current and historical context locations, snapshots, a task DAG, typed artifact directories, separate agent/tool/model logs, cache, and locks. Every managed write validates a relative path, rejects traversal, writes a temporary sibling, flushes the file, and renames it into place. Artifact entries carry SHA-256 hashes.

## Document attention

PDF files are extracted with configured `pdftotext`; text and Markdown are copied directly; HTML is reduced to readable text. Extracted text is stored in chunk files with source, page, byte range, and hash metadata. BM25 ranks chunks against a query. Only top evidence fitting `context.document_answer_context_bytes` reaches the isolated answering call. The answer artifact preserves citations and ranked evidence, while the coordinator receives its path rather than the source document.

## Recovery

After interruption, use `resume`. The scheduler reloads resolved configuration, manifest, recent actions, and DAG from disk. A stale lock may be removed only after verifying that no process owns the workspace. Hash verification detects modified managed artifacts. Provider failures preserve failure events and do not invent responses.

See `docs/ARCHITECTURE.md`, `docs/STATE_MODEL.md`, `docs/TOOLS.md`, and `docs/EVALUATION.md` for contracts and operational details.
