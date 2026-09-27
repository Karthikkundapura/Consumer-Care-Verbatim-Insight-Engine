# Project 26: CCVIE - Consumer Complaints & Verbatims Intelligence Engine

Complete Business + Technical Workflow

---

## 1. Business Problem

**Context:** CPG company receives **20k+ consumer complaints per month**:
- "resealable bag won't close in Seattle"
- "stale product"

**Current State:** Analysts read Excel sheets and make monthly PPTs. 
- **Lead time = 30 days**
- By then product is already in market, recall cost is high.

**Goal of CCVIE:** Detect a new pack / region / issue cluster in **3-5 days**, not 30 days, with **45 verbatim citations** to prove it.

---

## 2. Business Workflow - What User Sees

1.  **Consumer** calls care center -> complaint text + product + pack + region stored
2.  **System** hourly ingests verbatims, links to taxonomy, detects spike: 
    > "45 complaints - New resealable lid + Pacific Northwest + Seal Failure"
3.  **Insight Engine** generates:
    > "Emerging issue: Seal failure for new lid in PNW, 5x baseline, first seen 3 days ago" + drill-down to 45 verbatims
4.  **Quality Manager** opens Streamlit Tab 1, sees insight card, clicks to see verbatims, takes action - stop shipment
5.  **Quality Manager decides:** `[Confirm Issue]` `[Dismiss]` `[False Positive]` `[Investigate]` - the decision, a reason, the user ID, and a timestamp are captured to `insight_feedback` (see `project-architecture-proposal.md` Section 7), so this feedback can seed future evaluation data
6.  **Success is measured:** Lead time vs monthly report, citation accuracy, routing correctness, cost per query - all thresholds live only in `config.py`, see `project-architecture-proposal.md` Section 6

---

## 3. Technical Workflow - 5 Layers

> Source: Architecture Proposal

The five layers below host two separate flows. Keep them separate in
design and in code comments, even though they share tables and contracts:

```text
DETECTION PIPELINE (scheduled, no user in the loop)
Complaints -> Taxonomy -> Aggregation -> Poisson Scan -> Emerging Issue

INVESTIGATION PIPELINE (fires on a user query)
User Query -> Deterministic Intent Detection -> Router
           -> Graph / SQL / Vector / Hybrid -> Evidence -> LLM Explanation
```

Both pipelines feed the Layer 4 Attribution UI: Detection produces the
insight feed card, Investigation answers a drill-down question about one
insight.

### Layer 1: Data Foundation [Player 1]
**Postgres + pgvector is the ONLY DB**

**Tables:**
- `taxonomy`: products, packs, regions, issue_types (from `seed.sql`)
- `graph_nodes(id, label, props jsonb)` + `graph_edges(type, src, dst, props)` = a PostgreSQL-based property graph model, implemented with relational tables and SQL joins (not a native SQL/PGQ property-graph feature), using GraphRAG-style retrieval, with Issue nodes [blueprint requirement met without a dedicated graph database engine]
- `verbatims(id, text)` + `verbatim_embeddings(verbatim_id, embedding vector(384), model_name, embedding_version)` - dimension and model name come from `EMBEDDING_MODEL_NAME`/`EMBEDDING_DIMENSION` in `config.py`, the one source of truth (`all-MiniLM-L6-v2` outputs 384, not 768); `model_name` + `embedding_version` make a future embedding-model migration explicit
- `low_coverage_queue(verbatim_id, taxonomy_coverage, flagged_at, processed)` - verbatims below taxonomy coverage threshold, unique index on `verbatim_id WHERE processed = FALSE` prevents duplicate flags
- `taxonomy_proposals(topic_id, keywords, status, notes, created_at)` - candidate topics from BERTopic, awaiting human review
- `insight_feedback(feedback_id, insight_id, decision, reason, user_id, created_at, metadata jsonb)` - Quality Manager decision log (`CONFIRM_ISSUE` / `DISMISS` / `FALSE_POSITIVE` / `INVESTIGATE`), keyed by `user_id` not email for a stable audit log, see Section 2 step 5

**Jobs:**
- `ingestion.py` - hourly batch + nightly low-coverage flagging job (flags `taxonomy_coverage < 0.3`, idempotent via `ON CONFLICT ... DO NOTHING`)
- `embeddings.py` - sentence-transformers `all-MiniLM-L6-v2`
- HDBSCAN for clustering
- `bertopic_enrichment.py` - daily supplemental BERTopic job, lowest priority after Poisson detection, Graph/Vector/SQL retrieval, evidence attribution, LLM generation, and evaluation/CI; runs when the low-coverage queue exceeds 50 items; seeded (torch/numpy/random) and version-logged for reproducibility; output is human-reviewed and non-blocking to the eval gate. Answers "what if an emerging issue doesn't fit the taxonomy?" If the timeline runs short, cut this job's implementation first; keep the `low_coverage_queue`/`taxonomy_proposals` schema either way. Detail: `docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md`.

**Tools:** PostgreSQL 15, pgvector extension, asyncpg, sentence-transformers==2.7.0, HDBSCAN==0.8.33, umap-learn==0.5.5, bertopic==0.16.0 (all pinned for reproducible clustering), volume-corrected Poisson scan [blueprint page 63] as the primary detection mechanism

### Layer 2: Router [Player 2]
**LangGraph + Pydantic**

- **Input:** `QueryRequest` contract
- **Features:** `entity_count`, `taxonomy_coverage`, `has_agg_word`, `has_semantic_word`
- **Intents (deterministic, keyword/feature-based - no LLM or BERT classifier):**
  `COUNT`, `TREND`, `COMPARISON`, `ENTITY_LOOKUP`, `RELATIONSHIP`, `SEMANTIC_SEARCH`, `HYBRID`
- **Decision Logic:** `Intent + Entities + Time + Query Features -> Deterministic Route`
  - **ENTITY_LOOKUP / RELATIONSHIP -> Route A GRAPH:** "Show seal failures for new lid in PNW" - `entity_count=3` -> PostgreSQL property graph traversal via SQL JOINs (GraphRAG-style retrieval, not a dedicated graph database)
  - **COUNT -> Route B1 SQL Aggregate:** "Count complaints" -> `SELECT COUNT(*) GROUP BY`
  - **TREND / SEMANTIC_SEARCH -> Route B2 Semantic:** "What's trending?" -> `ORDER BY embedding <=> query_embedding`
  - **COMPARISON / HYBRID -> Route C HYBRID:** "Compare PNW seal failures vs California last month" or "Is PNW issue related elsewhere?" -> Graph + Vector, each side scoped by the entities/time window the intent extracted
  - Router stays deterministic even for `COMPARISON`: it splits the query into per-entity sub-queries by rule, not by asking an LLM to interpret it
- **Output:** `RouteDecision` contract
- **Tools:** LangGraph, Pydantic contracts in `backend/src/ccvie/contracts/`, `rules.py` thresholds from `config.py`

### Layer 3: Retrieval + Generation [Player 2]

- **Retrieval:** `graph_queries.py` [PostgreSQL property graph, GraphRAG-style retrieval] + `vector_queries.py` [pgvector] - both asyncpg direct, read-only `ccvie_reader` role, NOT MCP for detection pipeline
- **Generation:** `llm.py` thin client, provider and model name only from `LLM_PROVIDER`/`LLM_MODEL_NAME` in `config.py` (provider-agnostic, no provider or model hardcoded anywhere else), prompt in `synthesize_insight.md` -> generates `InsightResponse` with 45 `SourceRef`
- **Citation Validation:** Retrieve evidence -> LLM generates Claim + Source IDs -> Citation Validator checks every Source ID exists and belongs to the evidence set actually retrieved for that query -> UI renders the verbatim text fetched directly from the database by ID, never the text the LLM produced, so a hallucinated quote cannot reach the Quality Manager
- **Tools:** FastAPI, asyncpg, LLM client selected by `LLM_PROVIDER` (see `project-architecture-proposal.md` Section 6)

### Layer 4: Attribution UI [Player 4]
**Next.js + shadcn**

- **Tab 1: Insight feed** - `insight-card.tsx`, with `[Confirm Issue]` `[Dismiss]` `[False Positive]` `[Investigate]` actions that write to `insight_feedback`
- **Tab 2: Routing proof** - shows query | intent | features | predicted vs expected route | cost G vs V [for M-4]
- **Tab 3: Drill-down** - `verbatim-drilldown.tsx`, shows the top 5 strongest evidence verbatims first, with a `[View all 45]` expander for the full evidence pool (45 stays the evidence pool size, not the number shown at once) - protection against hallucination is source-ID validation and database-backed verbatim rendering (Section 3 Layer 3 Citation Validation), not a hash check: a hash only proves text is unchanged, it does not prove an LLM claim is supported by that source
- **Tools:** Next.js 14, shadcn/ui, types generated from `/openapi.json`

### Layer 5: Evaluation [Player 3]
**Pytest + GitHub Actions**

**Golden Sets:** `data/golden/`
- `planted_issue_ground_truth.json` [20 planted issues]
- `router_golden.jsonl` [120 queries, 2 annotators, kappa>0.65] - THIS WAS MISSING = M-4 CRITICAL
- `eval_fixture.jsonl` [30 queries for citation]

**Metrics:**
- M-1 Detection Rate (Recall - did it catch the planted issue)
- M-1b Precision and False-Positive Rate - did it also raise alerts that were not real issues; reported alongside M-1 so lead time cannot look good only because the system over-alerts
- M-1c Alerts per day/week - answers "does this create alert fatigue"
- M-2 Lead Time vs monthly baseline (Time-to-detection)
- M-3 Citation Accuracy [ID match + evidence-set membership from the Citation Validator, Section 3 Layer 3 + optional RAGAS faithfulness offline]
- M-4 Routing Correctness [accuracy + per-class recall, per intent]
- E13 Cost/query
- E14 Latency p50/p95

**Gates:** `eval-gate.yml` fails the PR if any `_MIN` metric (citation accuracy, router accuracy, graph recall) falls below its threshold, or any `_MAX` metric (lead-time regression days, false-positive rate) rises above its threshold - see `project-architecture-proposal.md` Section 6 for the one source of truth on those `EVAL_*` values and the `_MIN`/`_MAX` direction. These checks cover the Poisson-based metrics only. The BERTopic enrichment job is supplemental: its results (topics found, human reviewed, added to taxonomy) are reported alongside the gate output but never block it.

**Tools:** Pytest, GitHub Actions, RAGAS offline only [not in CI]

---

## 4. Tech Stack Role Summary

| Tech | Role | Why not alternative |
| :--- | :--- | :--- |
| **Postgres + pgvector** | Single source for graph + vector + SQL aggregate | No Neo4j/Qdrant = low cost, low ops, one transaction for citation |
| **graph_nodes + graph_edges JSONB** | PostgreSQL-based property graph model implemented with relational tables and SQL joins, using GraphRAG-style retrieval, no Neo4j engine | Ordinary relational tables + JSONB, not a native SQL/PGQ property-graph feature; low cost, low ops |
| **LangGraph** | Thin router graph, not multi-agent | Blueprint says thin, proposal says no multi-agent expansion |
| **Pydantic contracts** | Single source of truth across layers | Prevents drift, required by proposal Section 5 |
| **FastAPI + asyncpg** | API + direct SQL, read-only role | Faster than MCP for detection, MCP optional only for ad-hoc tab |
| **sentence-transformers** | Embeddings, no LLM call in detection | Keeps cost low per blueprint page 63; model + dimension pinned together in `config.py` |
| **LLM_PROVIDER / LLM_MODEL_NAME** | Provider-agnostic LLM client for Layer 3 generation only | No provider or model name hardcoded outside `config.py`/`.env*`, required by proposal Section 6 |
| **Next.js + shadcn** | UI with attribution | Required for citation drill-down |
| **Pytest + eval-gate** | CI that blocks regression | Proves M-1 to M-4 reliably, thresholds from `config.py` only |

---

## 5. End-to-End Flow in 30 Seconds

```
DETECTION: Consumer text -> ingestion.py -> graph_nodes/edges + embedding
  -> Poisson scan detects spike in 3 days -> Emerging Issue card in UI

INVESTIGATION: Quality Manager query -> Deterministic Intent Detection
  -> Router decides Graph vs Vector vs Hybrid -> Retrieval gets 45
  verbatims -> LLM generates insight with SourceRef -> Citation Validator
  checks IDs -> UI shows top 5 + [View all 45], verbatim text from DB
  -> Quality Manager records Confirm/Dismiss/False Positive/Investigate
  -> Evaluation reports the measured lead-time improvement, routing
  accuracy, false-positive rate, and cost/query from that run (all
  thresholds from config.py; these are measured values, not fixed demo
  numbers, and will change as the implementation changes)
```

## 6. Delivery Phases and Maturity

Build in the phase order in `project-architecture-proposal.md` Section 14:
core detection-to-UI path first, then the investigation pipeline, then
generation/citation trust, then evaluation/CI, then BERTopic and UX
polish last. Do not claim this system is production-proven; state its
maturity the way Section 15 of that document states it, on the panel and
in any status update.
