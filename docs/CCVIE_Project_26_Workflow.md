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

**Goal of CCVIE:** Detect a new pack / region / issue cluster in **3-5 days**, not 30 days, with **up to 45 verbatim citations** (`top_k <= MAX_EVIDENCE_ITEMS`, see `project-architecture-proposal.md` Section 5) to prove it. 45 is a cap, not a required count - see Section 3 Layer 3 Evidence Limit below.

---

## 2. Business Workflow - What User Sees

1.  **Consumer** calls care center -> complaint text + product + pack + region stored
2.  **System** hourly ingests verbatims, links to taxonomy, detects spike (example count, not a required number):
    > "45 complaints - New resealable lid + Pacific Northwest + Seal Failure"
3.  **Insight Engine** generates:
    > "Emerging issue: Seal failure for new lid in PNW, 5x baseline, first seen 3 days ago" + drill-down to up to 45 verbatims (top_k <= MAX_EVIDENCE_ITEMS)
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
Complaints -> Taxonomy -> Aggregation
  baseline >= MIN_POISSON_BASELINE_COUNT -> Poisson Scan
  baseline <  MIN_POISSON_BASELINE_COUNT -> Low-Volume Detection Policy
  -> Emerging Issue (marked low-volume when the second branch fired)

INVESTIGATION PIPELINE (fires on a user query)
User Query -> Deterministic Complexity Detector
  Simple  -> Deterministic Intent Detection -> Router
             -> Graph / SQL / Vector / Hybrid
  Complex -> LLM Query Planner -> Pydantic Validation -> Approved
             Operations -> Deterministic Plan Executor
             -> Graph / SQL / Vector / Hybrid
  -> Evidence -> LLM Explanation -> Citation Validation
```

Both pipelines feed the Layer 4 Attribution UI: Detection produces the
insight feed card, Investigation answers a drill-down question about one
insight. Within Investigation, Simple and Complex are also two separate
paths: the Complex path adds a validated LLM planning step in front of
the same deterministic execution the Simple path uses, never a
replacement for it (see `project-architecture-proposal.md` Section 5,
Query Planner Safety Rule).

### Layer 1: Data Foundation [Player 1]
**Postgres + pgvector is the ONLY DB**

**Tables:**
- `taxonomy`: products, packs, regions, issue_types (from `seed.sql`)
- `graph_nodes(id, label, props jsonb)` + `graph_edges(type, src, dst, props)` = a PostgreSQL-based relational property-graph model with GraphRAG-style retrieval: `graph_nodes`/`graph_edges` -> SQL-based graph traversal -> GraphRAG-style retrieval, with Issue nodes [blueprint requirement met without a dedicated graph database engine]. Canonical multi-hop example: `Issue -> Pack -> Region -> Related Issue` (see `project-architecture-proposal.md` Section 1)
- `verbatims(id, text)` + `verbatim_embeddings(verbatim_id, embedding vector(384), model_name, embedding_version)` - dimension and model name come from `EMBEDDING_MODEL_NAME`/`EMBEDDING_DIMENSION` in `config.py`, the one source of truth (`all-MiniLM-L6-v2` outputs 384, not 768); `model_name` + `embedding_version` make a future embedding-model migration explicit
- `low_coverage_queue(verbatim_id, taxonomy_coverage, flagged_at, processed)` - verbatims below taxonomy coverage threshold, unique index on `verbatim_id WHERE processed = FALSE` prevents duplicate flags
- `taxonomy_proposals(topic_id, keywords, status, notes, created_at)` - candidate topics from BERTopic, awaiting human review
- `insight_feedback(feedback_id, insight_id, decision, reason, user_id, created_at, metadata jsonb)` - Quality Manager decision log (`CONFIRM_ISSUE` / `DISMISS` / `FALSE_POSITIVE` / `INVESTIGATE`), keyed by `user_id` not email for a stable audit log, see Section 2 step 5

**Jobs:**
- `ingestion.py` - hourly batch + nightly low-coverage flagging job (flags `taxonomy_coverage < 0.3`, idempotent via `ON CONFLICT ... DO NOTHING`)
- `detection.py` - Poisson scan when `baseline >= MIN_POISSON_BASELINE_COUNT`; below that, a deterministic low-volume policy (minimum-count and historical-context rules, not a second statistical model) that marks its result low-volume. Do not assume Poisson spike detection alone is sufficient at baseline = 0 or 1. Tested at baseline 0, 1, low, normal, and high-volume spike.
- `embeddings.py` - sentence-transformers `all-MiniLM-L6-v2`
- HDBSCAN for clustering
- `bertopic_enrichment.py` - daily supplemental BERTopic job, lowest priority after Poisson detection, Graph/Vector/SQL retrieval, evidence attribution, LLM generation, and evaluation/CI; runs when the low-coverage queue exceeds 50 items; seeded (torch/numpy/random) and version-logged for reproducibility; output is human-reviewed and non-blocking to the eval gate. Answers "what if an emerging issue doesn't fit the taxonomy?" If the timeline runs short, cut this job's implementation first; keep the `low_coverage_queue`/`taxonomy_proposals` schema either way. Detail: `docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md`.

**Tools:** PostgreSQL 15, pgvector extension, asyncpg, sentence-transformers==2.7.0, HDBSCAN==0.8.33, umap-learn==0.5.5, bertopic==0.16.0 (all pinned for reproducible clustering), volume-corrected Poisson scan [blueprint page 63] as the primary detection mechanism

### Layer 2: Router [Player 2]
**LangGraph + Pydantic**

- **Input:** `QueryRequest` contract
- **Complexity Detector (`router/complexity.py`, deterministic, unit-tested, no LLM call):**
  runs first on every query. Signals: multiple requested actions, conjunctions
  such as "and"/"then", investigation language, cross-region requests,
  similarity + comparison requests, historical comparison combined with
  another operation, multiple entities or dimensions. Default with no
  strong signal is `Simple`. Do not build a second LLM or BERT classifier
  to make this call.
- **LangGraph flow:** `START -> load_context -> complexity_detector -> is_complex?`
  - `NO  -> deterministic_router -> execute_retrieval`
  - `YES -> query_planner -> validate_plan -> execute_plan -> collect_evidence`
  - both branches rejoin at `-> generate -> validate_citations -> END`

**Simple path**

- **Features:** `entity_count`, `taxonomy_coverage`, `has_agg_word`, `has_semantic_word`
- **Intents (deterministic, keyword/feature-based - no LLM or BERT classifier):**
  `COUNT`, `TREND`, `COMPARISON`, `ENTITY_LOOKUP`, `RELATIONSHIP`, `SEMANTIC_SEARCH`, `HYBRID`
- **Decision Logic:** `Intent + Entities + Time + Query Features -> Deterministic Route`
  - **ENTITY_LOOKUP / RELATIONSHIP -> Route A GRAPH:** "Show seal failures for new lid in PNW" - `entity_count=3` -> SQL-based graph traversal, GraphRAG-style retrieval, not a dedicated graph database. Multi-hop example: "Is this seal-failure issue happening elsewhere?" -> `Issue -> Pack -> Region -> Related Issue`
  - **COUNT -> Route B1 SQL Aggregate:** "Count complaints" -> `SELECT COUNT(*) GROUP BY`
  - **TREND / SEMANTIC_SEARCH -> Route B2 Semantic:** "What's trending?" -> `ORDER BY embedding <=> query_embedding`
  - **COMPARISON / HYBRID -> Route C HYBRID:** "Compare PNW seal failures vs California last month" or "Is PNW issue related elsewhere?" -> Graph + Vector, each side scoped by the entities/time window the intent extracted
  - Router stays deterministic even for `COMPARISON`: it splits the query into per-entity sub-queries by rule, not by asking an LLM to interpret it
- **Output:** `RouteDecision` contract

**Complex path - Query Planner (`router/planner.py`, `router/plan_executor.py`)**

- Example: "Investigate this issue and see if similar complaints occurred in other regions."
- **Planner:** converts the natural-language query into a validated
  `InvestigationPlan` (`contracts/planner.py`: `original_query`,
  `operations`, `dependencies`, `parameters`, `plan_version="1.0"`). The
  planner determines required operations, parameters, dependencies, and
  context. **It never executes anything.**
- **Approved operations only:** `RESOLVE_INSIGHT`, `GET_ISSUE_DETAILS`,
  `COUNT_COMPLAINTS`, `GET_COMPLAINT_TREND`, `SEARCH_SIMILAR_COMPLAINTS`,
  `FIND_REGIONS`, `GROUP_BY_REGION`, `COMPARE_REGIONS`, `GET_BASELINE`,
  `GET_HISTORICAL_BASELINE`, `GET_ISSUE_HISTORY`, `GET_PRODUCT_HISTORY`,
  `GET_EVIDENCE`. An unknown operation is rejected, not executed.
- **Example plan** for the query above: `RESOLVE_INSIGHT ->
  SEARCH_SIMILAR_COMPLAINTS -> FIND_REGIONS -> GROUP_BY_REGION ->
  COMPARE_REGIONS -> GET_EVIDENCE`.
- **Executor (`plan_executor.py`):** accepts only a Pydantic-validated
  `InvestigationPlan`, maps each operation to one existing retrieval
  function (`COUNT_COMPLAINTS -> sql_queries.count_complaints()`,
  `SEARCH_SIMILAR_COMPLAINTS -> vector_queries.search_similar_complaints()`,
  `FIND_REGIONS -> graph_queries.find_regions()`, `GET_EVIDENCE ->
  evidence.get_evidence()`), and rejects a plan whose `plan_version` is
  not in `PLANNER_SUPPORTED_PLAN_VERSION`. No LLM reasoning happens here.
- **Limits from config, never hardcoded:** `PLANNER_MAX_OPERATIONS=8`,
  `PLANNER_MAX_EXECUTION_DEPTH=5`, `PLANNER_MAX_EXECUTION_TIME_SECONDS=15`,
  `PLANNER_MAX_EVIDENCE_ITEMS=45` (see `project-architecture-proposal.md`
  Section 6).
- **Ambiguous queries** (for example "Is this getting worse?" with more
  than one candidate issue): resolve from deterministic context where
  possible, otherwise ask "Which issue would you like me to compare?".
  Do not guess when ambiguity materially affects the result.
- **Unsupported queries** (for example "What will sales be next
  quarter?" when CCVIE has no sales data): fail safely and state what is
  missing. Do not fabricate a result.
- **Safety boundary:** the LLM plans only. It must never generate SQL for
  execution, execute SQL, access PostgreSQL/pgvector/graph tables or
  credentials directly, modify data or schema, bypass Pydantic
  validation, or invoke arbitrary/unrestricted tools. Full rule: `project-architecture-proposal.md` Section 5, Query Planner Safety Rule.
- **Tools:** LangGraph, Pydantic contracts in `backend/src/ccvie/contracts/`, `rules.py` thresholds from `config.py`

### Layer 3: Retrieval + Generation [Player 1: retrieval primitives; Player 2: orchestration, generation, citation validation]

- **Retrieval (Player 1 implements and optimizes; files live in `retrieval_gen/`, not moved into `data_foundation/` just to match ownership):** `graph_queries.py` [PostgreSQL-based relational property-graph model, GraphRAG-style retrieval, multi-hop example `Issue -> Pack -> Region -> Related Issue`] + `vector_queries.py` [pgvector] + `sql_queries.py` [aggregate ops, also the Complex-path executor's `COUNT_COMPLAINTS` target] - all asyncpg direct, read-only `ccvie_reader` role, NOT MCP for the detection or investigation pipeline (MCP stays out of the core path for both Simple and Complex queries; may be reconsidered later only for external agent interoperability, never added just for a demo). Player 2's `orchestrator.py` and `plan_executor.py` consume these as a dependency: `Player 1 -> Data + Retrieval Primitives -> Player 2 -> Planning + Orchestration + Generation`.
- **Generation:** `llm.py` thin client, provider and model name only from `LLM_PROVIDER`/`LLM_MODEL_NAME` in `config.py` (provider-agnostic, no provider or model hardcoded anywhere else), prompt in `synthesize_insight.md` -> generates `InsightResponse` with up to `MAX_EVIDENCE_ITEMS` (45) `SourceRef` - a cap, not a required count. The same generation step runs for both the Simple and Complex path, over whatever `evidence.py` assembled.
- **Evidence Limit:** `top_k <= MAX_EVIDENCE_ITEMS`: 18 matches -> return 18, 45 matches -> return 45, 250 matches -> retrieve/rank the top 45. Never assume exactly 45.
- **Citation Validation:** Retrieve evidence -> LLM generates Claim + Source IDs -> Citation Validator (`citation_validator.py`) checks every citation the response actually used exists and belongs to the evidence set actually retrieved for that query, whatever its size -> UI renders the verbatim text fetched directly from the database by ID, never the text the LLM produced, so a hallucinated quote cannot reach the Quality Manager
- **Tools:** FastAPI, asyncpg, LLM client selected by `LLM_PROVIDER` (see `project-architecture-proposal.md` Section 6)

### Layer 4: Attribution UI [Player 4]
**Next.js + shadcn**

- **Tab 1: Insight feed** - `insight-card.tsx`, with `[Confirm Issue]` `[Dismiss]` `[False Positive]` `[Investigate]` actions that write to `insight_feedback`
- **Tab 2: Routing proof** - shows query | complexity (Simple/Complex) | intent or plan operations | features | predicted vs expected route | cost G vs V [for M-4, and plan validity for M-4b once the planner lands]
- **Tab 3: Drill-down** - `verbatim-drilldown.tsx`, shows the top 5 strongest evidence verbatims first, with a `[View all]` expander for the rest of the retrieved evidence (`top_k <= MAX_EVIDENCE_ITEMS`, up to 45; UI reads the real count, for example "Showing 18 of 18" or "Showing 45 of 250") - protection against hallucination is source-ID validation and database-backed verbatim rendering (Section 3 Layer 3 Citation Validation), not a hash check: a hash only proves text is unchanged, it does not prove an LLM claim is supported by that source
- **Tools:** Next.js 14, shadcn/ui, types generated from `/openapi.json`

### Layer 5: Evaluation [Player 3]
**Pytest + GitHub Actions**

**Golden Sets:** `data/golden/`
- `planted_issue_ground_truth.json` [20 planted issues]
- `router_golden.jsonl` [120 queries, 2 annotators, kappa>0.65] - THIS WAS MISSING = M-4 CRITICAL
- `eval_fixture.jsonl` [30 queries for citation]
- complex investigation golden set (new, additional to router_golden.jsonl, feeds M-4b): multi-region investigation, similar-complaint investigation, historical comparison, trend + comparison, ambiguous queries, unsupported queries, missing-context queries, multi-step evidence requests

**Metrics:**
- M-1 Detection Rate (Recall - did it catch the planted issue)
- M-1b Precision and False-Positive Rate - did it also raise alerts that were not real issues; reported alongside M-1 so lead time cannot look good only because the system over-alerts
- M-1c Alerts per day/week - answers "does this create alert fatigue"
- M-2 Lead Time vs monthly baseline (Time-to-detection)
- M-3 Citation Accuracy [ID match + evidence-set membership from the Citation Validator, Section 3 Layer 3 + optional RAGAS faithfulness offline]
- M-4 Routing Correctness [accuracy + per-class recall, per intent] - Simple path only, unchanged by the planner addition
- M-4b Investigation Plan Validity (Complex path, `planner_eval.py`): Valid Plan Rate, Operation Validity, Parameter Completeness, Plan Execution Success Rate, Unsupported Operation Rejection
- E13 Cost/query - for the Complex path, `TOTAL_QUERY_COST` = `PLANNER_LLM_COST` + `EXECUTION_COST` + `GENERATION_COST` (retrieval cost is part of `EXECUTION_COST`); track Simple- and Complex-path cost separately, do not treat them as equivalent without identifying the query path; log `planner_llm_cost` and `total_query_cost` in observability, below
- E14 Latency p50/p95

**Gates:** `eval-gate.yml` fails the PR if any `_MIN` metric (citation accuracy, router accuracy, graph recall) falls below its threshold, or any `_MAX` metric (lead-time regression days, false-positive rate) rises above its threshold - see `project-architecture-proposal.md` Section 6 for the one source of truth on those `EVAL_*` values and the `_MIN`/`_MAX` direction. These checks cover the Poisson-based metrics only. The BERTopic enrichment job is supplemental: its results (topics found, human reviewed, added to taxonomy) are reported alongside the gate output but never block it. M-4b is reported the same way once the planner lands: visible in gate output, not blocking, until the team locks an `EVAL_PLANNER_*` threshold (Section 8).

**Observability (Complex path):** log `request_id`, `query_complexity`, `selected_path`, `planner_model`, `plan_version`, `operations`, `validation_result`, `execution_duration`, `evidence_count`, `citation_validation_result`, `planner_llm_cost`, `execution_cost`, `total_query_cost`, `final_status`. Do not log unnecessary sensitive complaint content.

**Tools:** Pytest, GitHub Actions, RAGAS offline only [not in CI]

---

## 4. Tech Stack Role Summary

| Tech | Role | Why not alternative |
| :--- | :--- | :--- |
| **Postgres + pgvector** | Single source for graph + vector + SQL aggregate | No Neo4j/Qdrant = low cost, low ops, one transaction for citation |
| **graph_nodes + graph_edges JSONB** | PostgreSQL-based relational property-graph model with GraphRAG-style retrieval (multi-hop example: Issue -> Pack -> Region -> Related Issue), no Neo4j engine | Ordinary relational tables + JSONB, not a native SQL/PGQ property-graph feature; low cost, low ops |
| **LangGraph** | Thin router graph, not multi-agent | Blueprint says thin, proposal says no multi-agent expansion |
| **Pydantic contracts** | Single source of truth across layers | Prevents drift, required by proposal Section 5 |
| **FastAPI + asyncpg** | API + direct SQL, read-only role | Faster than MCP for detection, MCP optional only for ad-hoc tab |
| **sentence-transformers** | Embeddings, no LLM call in detection | Keeps cost low per blueprint page 63; model + dimension pinned together in `config.py` |
| **LLM_PROVIDER / LLM_MODEL_NAME** | Provider-agnostic LLM client for Layer 3 generation only | No provider or model name hardcoded outside `config.py`/`.env*`, required by proposal Section 6 |
| **Deterministic complexity detector + LLM Query Planner** | Plans, never executes, a Complex investigation query; Simple queries never reach it | Keeps the deterministic router as the default path; LLM never touches SQL/graph/vector directly, see proposal Section 5 |
| **Next.js + shadcn** | UI with attribution | Required for citation drill-down |
| **Pytest + eval-gate** | CI that blocks regression | Proves M-1 to M-4 reliably, thresholds from `config.py` only |

---

## 5. End-to-End Flow in 30 Seconds

```
DETECTION: Consumer text -> ingestion.py -> graph_nodes/edges + embedding
  -> detection.py: baseline >= MIN_POISSON_BASELINE_COUNT ? Poisson scan
  detects spike in 3 days : deterministic low-volume policy marks the
  result low-volume -> Emerging Issue card in UI

INVESTIGATION (Simple): Quality Manager query -> Complexity Detector
  says Simple -> Deterministic Intent Detection -> Router decides Graph
  vs Vector vs Hybrid -> Retrieval gets up to MAX_EVIDENCE_ITEMS (45)
  verbatims, ranked by match strength, never padded to a fixed count ->
  LLM generates insight with SourceRef -> Citation Validator checks
  every citation actually used against the retrieved set -> UI shows
  top 5 + [View all], with the real "Showing N of M" count, verbatim
  text from DB -> Quality Manager records Confirm/Dismiss/False
  Positive/Investigate -> Evaluation reports the measured lead-time
  improvement, routing accuracy, false-positive rate, and cost/query
  from that run (all thresholds from config.py; these are measured
  values, not fixed demo numbers, and will change as the implementation
  changes)

INVESTIGATION (Complex): "Investigate this issue and see if similar
  complaints occurred in other regions." -> Complexity Detector says
  Complex -> LLM Query Planner produces InvestigationPlan
  (RESOLVE_INSIGHT -> SEARCH_SIMILAR_COMPLAINTS -> FIND_REGIONS ->
  GROUP_BY_REGION -> COMPARE_REGIONS -> GET_EVIDENCE) -> Pydantic
  validation + approved-operations check -> plan_executor.py runs each
  operation deterministically (Vector for similar complaints, SQL/Graph
  multi-hop traversal - Issue -> Pack -> Region -> Related Issue - for
  regional grouping and comparison, PostgreSQL for evidence) -> same
  Generation + Citation Validation + UI as the Simple path -> Evaluation
  reports M-4b plan validity plus the Complex-path cost breakdown
  (PLANNER_LLM_COST + EXECUTION_COST + GENERATION_COST = TOTAL_QUERY_COST)
```

## 6. Delivery Phases and Maturity

Build in the phase order in `project-architecture-proposal.md` Section 14:
`Data -> Detection -> Retrieval -> Evidence -> API -> UI` is Phase 1,
goal a working end-to-end local demo, and it already includes the
Simple-path deterministic router and its graph/vector/SQL retrieval.
Phase 2 is the Query Planner only: complexity detector -> Query Planner
-> plan validation -> controlled plan executor -> complex investigation
evaluation. Then generation/citation trust, then evaluation/CI, then
BERTopic and UX polish last. Do not let Phase 2 delay the Phase 1
milestone. Do not claim this system is production-proven; state its
maturity the way Section 15 of that document states it, on the panel and
in any status update.

Before the final demo, confirm the Final Engineering Evidence checklist
(`project-architecture-proposal.md` Section 14) is in place: local health
checks, the rollback demonstration (`scripts/demo_rollback.sh`), the
operating runbook (`docs/runbook.md`), the agent review log
(`docs/AGENT_REVIEW_LOG.md`), security evidence (Query Planner Safety
Rule, citation validation), and evaluation evidence (the gate output,
M-1 through M-4b).

This capstone demonstrates on a local, non-production Docker environment,
with a reproducible rollback demonstration. Per the Scope Decision in
`project-architecture-proposal.md` Section 2, do not add AWS, Azure,
Kubernetes, cloud deployment, or canary/production infrastructure; the
rollback demonstration stays a local Docker script, not a deployment
pipeline. Put remaining time into GraphRAG correctness, low-volume
detection, evidence limits, the Query Planner, evaluation, security
boundaries, and local demo reliability instead.
