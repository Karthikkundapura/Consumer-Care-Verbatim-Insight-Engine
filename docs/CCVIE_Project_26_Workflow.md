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
Complaints -> Daily aggregation cells (date/SKU/pack/region/issue/
  component/supplier/plant) -> 7-day rolling window
  baseline >= MIN_POISSON_BASELINE_COUNT -> Poisson or Negative Binomial scan
  baseline <  MIN_POISSON_BASELINE_COUNT -> Low-Volume Detection Policy
  -> Hierarchical roll-ups -> FDR control -> Emerging Issue
     (marked low-volume when the second branch fired)

INVESTIGATION PIPELINE (fires on a user query)
User Query -> Follow-up Rewrite -> Scope Check -> Entity Resolution
  -> Deterministic Complexity + Confidence Check
  Simple + high confidence -> Deterministic Intent Detection -> Router
             -> Graph / SQL / Vector / Hybrid
  Complex, or Simple + low confidence -> LLM Query Planner -> Pydantic
             Validation -> Approved Operations -> Deterministic Plan
             Executor -> Graph / SQL / Vector / Hybrid
  -> Evidence -> LLM Explanation -> Verification (citation + claim
     support + numeric) -> Answer / Clarification / Partial / Refusal
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
- `graph_nodes(id, label, props jsonb)` + `graph_edges(type, src, dst, props)` = a PostgreSQL-based property graph model with relational tables and SQL joins, with GraphRAG-style retrieval [blueprint requirement met without a dedicated graph database engine - never Neo4j]. **Deep domain ontology** (structure and relationships, not complaint records or counts): `Brand -> Product -> SKU -> Pack -> Component -> Supplier`, `SKU -> Plant`, `Product -> Ingredient`, `IssueType -> IssueCategory`, `City -> Region -> Market`, `Pack -replaced_by-> Pack`, `Pack -uses-> Component`, `Alert -> Pack/SKU/Component/Supplier/Plant/Region/IssueType`. Two canonical multi-hop examples: `Issue -> Pack -> Region -> Related Issue` and the deeper supply-chain traversal `Pack -> Component -> Supplier -> Other Components -> Other Packs -> SKU -> Brand` (see `project-architecture-proposal.md` Section 1), implemented with a PostgreSQL recursive CTE bounded by `GRAPH_TRAVERSAL_MAX_DEPTH`. **Required indexes:** `graph_edges(src)` and `graph_edges(dst)` each need a B-tree index, created in `0001_init_entities.sql`, or multi-hop traversal degrades to sequential scans as depth grows - do not assume a foreign key column is indexed automatically, verify it explicitly. Do not index every JSONB property; index only the ones actually filtered or joined on (a GIN index on `props`, not B-tree, for those). **Local GraphRAG, not Global:** entity-resolved retrieval plus a 2-3 hop subgraph (`Pack -> Component -> Supplier -> Other Products`) via a recursive CTE over `graph_edges(src, dst, type)`, fused with pgvector HNSW and FTS via Reciprocal Rank Fusion (Layer 3, Hybrid Retrieval Design). Global GraphRAG (Leiden community detection + community summaries) is deferred to the COULD/FUTURE tier (`project-architecture-proposal.md` Section 18) - it answers corpus-wide thematic questions CCVIE's entity-centric investigation does not ask. **Panel defense** ("isn't this just SQL graph modeling?" / "why not Neo4j?"): `project-architecture-proposal.md` Section 1 has the recommended responses - frame PostgreSQL vs. a dedicated graph database as a trade-off and scope decision, never claim one is universally better. Depth limit: queries max depth 3; switch threshold depth > 6 or concurrency > 50 parallel traversals → graph engine behind the swappable interface (see proposal Section 1; state as design limit unless measured).
- `audit_log(request_id, operation, parameters, row_count, latency, cost, plan, evidence_count, verification_result, created_at)` - backs the Observability log fields below; supports debugging, evaluation, cost measurement, agentic-AI traceability, and demo evidence (see `project-architecture-proposal.md` Section 16)
- `verbatims(id, text)` + `verbatim_embeddings(verbatim_id, embedding vector(384), model_name, embedding_version)` - dimension and model name come from `EMBEDDING_MODEL_NAME`/`EMBEDDING_DIMENSION` in `config.py`, the one source of truth (`all-MiniLM-L6-v2` outputs 384, not 768); `model_name` + `embedding_version` make a future embedding-model migration explicit
- `low_coverage_queue(verbatim_id, taxonomy_coverage, flagged_at, processed)` - verbatims below taxonomy coverage threshold, unique index on `verbatim_id WHERE processed = FALSE` prevents duplicate flags
- `taxonomy_proposals(topic_id, keywords, status, notes, created_at)` - candidate topics from BERTopic, awaiting human review
- `insight_feedback(feedback_id, insight_id, decision, reason, user_id, created_at, metadata jsonb)` - Quality Manager decision log (`CONFIRM_ISSUE` / `DISMISS` / `FALSE_POSITIVE` / `INVESTIGATE`), keyed by `user_id` not email for a stable audit log, see Section 2 step 5

**Jobs:**
- `ingestion.py` - hourly batch + nightly low-coverage flagging job (flags `taxonomy_coverage < 0.3`, idempotent via `ON CONFLICT ... DO NOTHING`) + ingestion-time PII redaction (email, phone, order number, names; `PII_REDACTION_ENABLED`) + treats complaint text as untrusted data, never as instructions, even where it contains injection-shaped text
- `detection.py` - aggregates complaints into daily cells (date/SKU/pack/region/issue/component/supplier/plant), scans each cell's 7-day rolling window with Poisson, or Negative Binomial when over-dispersion requires it; below `MIN_POISSON_BASELINE_COUNT`, a deterministic low-volume policy (minimum-count and historical-context rules, not a second statistical model) marks its result low-volume. Rolls results up (`Issue Category -> Issue Type`, `Market -> Region -> City`, `Supplier -> Component -> Pack`) and applies Benjamini-Hochberg FDR control (`DETECTION_FDR_ALPHA`) across cells tested together before emitting an Emerging Issue. Lead time is measured as `detection_date - planted onset_date` against two baselines (existing monthly/category baseline + a stronger naive weekly SKU x region baseline without graph dimensions) - never a hardcoded expected-lead-time value. Do not assume Poisson spike detection alone is sufficient at baseline = 0 or 1. Tested at baseline 0, 1, low, normal, and high-volume spike. Poisson + the low-volume policy + one baseline is the MUST-tier working detector; Negative Binomial, FDR, roll-ups, and the second baseline are SHOULD-tier layers added once that baseline is stable, never a Phase 1 blocker (`project-architecture-proposal.md` Section 14/18). The MIN_POISSON_BASELINE_COUNT threshold is justified in ADR-0004 and validated by a sensitivity analysis (Section 8.2 of the architecture proposal).
- `embeddings.py` - sentence-transformers `all-MiniLM-L6-v2`
- HDBSCAN for clustering
- `bertopic_enrichment.py` - daily supplemental BERTopic job, lowest priority after Poisson detection, Graph/Vector/SQL retrieval, evidence attribution, LLM generation, and evaluation/CI; runs when the low-coverage queue exceeds 50 items; seeded (torch/numpy/random) and version-logged for reproducibility; output is human-reviewed and non-blocking to the eval gate. Answers "what if an emerging issue doesn't fit the taxonomy?" If the timeline runs short, cut this job's implementation first; keep the `low_coverage_queue`/`taxonomy_proposals` schema either way. Detail: `docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md`.

**Tools:** PostgreSQL 15, pgvector extension, asyncpg, sentence-transformers==2.7.0, HDBSCAN==0.8.33, umap-learn==0.5.5, bertopic==0.16.0 (all pinned for reproducible clustering), volume-corrected Poisson scan [blueprint page 63] as the primary detection mechanism

### Layer 2: Router [Player 2]
**LangGraph + Pydantic**

- **Input:** `QueryRequest` contract, after the Query Understanding front
  end has already run (see `project-architecture-proposal.md` Section 1):
  **Follow-up Rewrite** (a conversational follow-up like "And in the
  South?" is rewritten against the prior turn's filters into a
  self-contained query), **Scope Check** (against `scope.yaml`'s
  supported brands/markets/date range/metrics and unsupported-topics
  list - forecasting, medical/safety judgement, recall decisions,
  personal data requests - refuse or redirect out-of-scope queries before
  routing), and **Entity Resolution** (`Alias dictionary -> pg_trgm
  similarity -> Embedding similarity -> Resolved entity`, no LLM as
  first-line resolver; ask a clarification question if more than one
  entity stays plausible, for example "flip cap" matching both "Flip Cap
  v1" and "Flip Cap v2").
- **Complexity Detector (`router/complexity.py`, deterministic, unit-tested, no LLM call):**
  runs first on every query. Signals: multiple requested actions, conjunctions
  such as "and"/"then", investigation language, cross-region requests,
  similarity + comparison requests, historical comparison combined with
  another operation, multiple entities or dimensions. Default with no
  strong signal is `Simple`. Do not build a second LLM or BERT classifier
  to make this call.
- **Confidence score.** Alongside Simple/Complex, compute a deterministic
  confidence score from resolved-entity coverage, number of matching
  intents, conflicting intent signals, ambiguity, and completeness of the
  route's required parameters. Formula (`router/complexity.py`, no LLM): `0.4*entity_coverage + 0.2*intent_clarity + 0.2*param_completeness + 0.2*(1-ambiguity)`, where `entity_coverage = resolved/mentioned`, `intent_clarity = 1.0/0.6/0.3` for 1/2/3+ intents, `ambiguity = 0.3` for short questions. Precedence: `[complexity_detector, COUNT, COMPARISON, RELATIONSHIP, ENTITY_LOOKUP, SEMANTIC]`; `ROUTER_CONFIDENCE_MIN=0.70` (heuristic first cut, tuned on router golden 120 for <5% abstention at >85% accuracy). Full spec: `project-architecture-proposal.md` Section 1.

  ```text
  COMPLEX                                       -> Query Planner
  SIMPLE + confidence >= ROUTER_CONFIDENCE_MIN  -> Deterministic Router
  SIMPLE + confidence <  ROUTER_CONFIDENCE_MIN  -> Query Planner
  ```

  This is what fixes brittle keyword-router behavior: a `Simple` query
  that only weakly or ambiguously matches one intent goes to the Query
  Planner instead of a possibly-wrong deterministic guess. Still no LLM
  decides Simple vs Complex; the confidence score is computed from the
  same deterministic features.
- **Complexity detection has absolute precedence over deterministic
  intent classification.** No intent feature runs until the complexity
  and confidence check has answered:

  ```text
  User Query -> Deterministic Complexity Detector
      ↓
  Is query COMPLEX, or SIMPLE with low confidence?
      ├── YES -> Query Planner
      └── NO  -> Deterministic Intent Router
  ```

  A query classified `COMPLEX` goes to the Query Planner and is never
  routed by the Simple path's intent rules below, even if it also
  contains a strong Simple-intent keyword. See the ambiguous example
  after the Simple path's precedence order.
- **LangGraph flow:** `START -> load_context -> rewrite_followup ->
  scope_check -> resolve_entities -> complexity_and_confidence ->
  is_complex_or_low_confidence?`
  - `NO  -> deterministic_router -> execute_retrieval`
  - `YES -> query_planner -> validate_plan -> execute_plan -> collect_evidence`
  - both branches rejoin at `-> generate -> verify (citations + claim
    support + numeric) -> END` (`END` state is one of Answer,
    Clarification, Partial Answer, or Refusal - see the Query
    Understanding Pipeline in `project-architecture-proposal.md` Section 1)

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
- **Explicit precedence for overlapping intent matches (Simple path only; not a keyword-order accident — `rules.py` evaluates in this fixed order and stops at the first match):**
  1. `RELATIONSHIP` - a resolved entity plus multi-hop language ("elsewhere", "related", "other regions")
  2. `ENTITY_LOOKUP` - `entity_count >= ROUTER_ENTITY_COUNT_THRESHOLD`
  3. `COMPARISON` - an explicit two-sided comparison ("vs", "compared to") between resolved entities
  4. `COUNT` - `has_agg_word`
  5. `TREND` - a temporal trend word ("trending", "over time") without an aggregate word
  6. `SEMANTIC_SEARCH` - `has_semantic_word`, the fallback when nothing more specific matched
  7. `HYBRID` - not a tier of its own; it is what fires when two intents from tiers 1-6 score equally and neither dominates (this is how `COMPARISON` already resolves in practice: comparing two entities needs both sides retrieved, so it always routes `HYBRID`)
- **Ambiguous-query example:** "Count similar seal failures across regions" contains three signals at once - `COUNT` (an aggregate word), semantic similarity (`SEMANTIC_SEARCH`), and multiple regions/comparison (`COMPARISON`). This is exactly why complexity detection runs first: "similarity + comparison requests" and "cross-region requests" are complexity signals (above), so this query is classified `COMPLEX` and goes to the Query Planner - the Simple-path precedence order above is never consulted for it. If a future query trips the same keyword signals but the complexity detector still classifies it `Simple` (no strong complexity signal), the precedence order above applies deterministically instead of an LLM or ad-hoc keyword-scan order.
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
  `GET_EVIDENCE`, extended as the deep graph ontology and the Question
  Coverage Catalogue need it - only once a deterministic backend function
  backs the name (`project-architecture-proposal.md` Section 5):
  `RESOLVE_ENTITIES`, `GET_SUPPLY_LINKS`, `EXPLAIN_CHANGE`, `LIST_ALERTS`,
  `EXPLAIN_ALERT`, `GET_PROFILE`, `GET_THEMES`, `SEMANTIC_COUNT`. An
  unknown operation is rejected, not executed.
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

- **Retrieval (Player 1 implements and optimizes; files live in `retrieval_gen/`, not moved into `data_foundation/` just to match ownership):** `graph_queries.py` [PostgreSQL-based property graph model with relational tables and SQL joins, with GraphRAG-style retrieval, multi-hop example `Issue -> Pack -> Region -> Related Issue`] + `vector_queries.py` [pgvector] + `sql_queries.py` [aggregate ops, also the Complex-path executor's `COUNT_COMPLAINTS` target] - all asyncpg direct, read-only `ccvie_reader` role, NOT MCP for the detection or investigation pipeline (MCP stays out of the core path for both Simple and Complex queries; may be reconsidered later only for external agent interoperability, never added just for a demo). Player 2's `orchestrator.py` and `plan_executor.py` consume these as a dependency: `Player 1 -> Data + Retrieval Primitives -> Player 2 -> Planning + Orchestration + Generation`.
- **Generation:** `llm.py` thin client, provider and model name only from `LLM_PROVIDER`/`LLM_MODEL_NAME` in `config.py` (provider-agnostic, no provider or model hardcoded anywhere else), prompt in `synthesize_insight.md` -> generates `InsightResponse` with up to `MAX_EVIDENCE_ITEMS` (45) `SourceRef` - a cap, not a required count. The same generation step runs for both the Simple and Complex path, over whatever `evidence.py` assembled.
- **Hybrid Retrieval Design:** `Resolved-entity metadata filtering -> PostgreSQL full-text search + pgvector search -> Reciprocal Rank Fusion (k=60) -> Top evidence`. Why RRF: rank-based fusion is robust to BM25-vs-cosine scale mismatch; weighted sum needs weights we have no data to tune; cross-encoder reranking (+300ms + cost) stays SHOULD-tier. Handle 0 matches safely (empty evidence -> Clarification/Refusal, never a fabricated result), not only the common case. Cross-encoder reranking, MMR, and an embedding-model bake-off are SHOULD-tier conditional enhancements (`project-architecture-proposal.md` Section 18) - document, do not block the core path, implement only if the Retrieval set (recall@20, nDCG@10) shows a real problem.
- **Evidence Limit:** `top_k <= MAX_EVIDENCE_ITEMS`: 18 matches -> return 18, 45 matches -> return 45, 250 matches -> retrieve/rank the top 45. Never assume exactly 45.
- **Citation Validation:** Retrieve evidence -> LLM generates Claim + Source IDs -> Citation Validator (`citation_validator.py`) checks every citation the response actually used exists and belongs to the evidence set actually retrieved for that query, whatever its size -> UI renders the verbatim text fetched directly from the database by ID, never the text the LLM produced, so a hallucinated quote cannot reach the Quality Manager. **Evidence-set membership is necessary, not sufficient:** a lightweight NLI/support check (`Claim -> Retrieved Verbatim -> Support/Unsupported`) removes or downgrades-to-partial-answer any claim membership alone would have let through unsupported. The NLI check is a SHOULD-tier layer on top of the MUST-tier citation validation (`project-architecture-proposal.md` Section 18); if it is not operational yet, Source-ID membership + DB-backed verbatim rendering is the validated fallback, not a gap. **Numeric verification:** every number in a generated answer must trace back to a deterministic operation result (for example `COUNT_COMPLAINTS -> 45`); the LLM may explain a number, never invent one.
- **Tools:** FastAPI, asyncpg, LLM client selected by `LLM_PROVIDER` (see `project-architecture-proposal.md` Section 6)

### Layer 4: Attribution UI [Player 4]
**Next.js + shadcn — centerpiece, 25% of functionality**

- **Tab 1: Insight feed** - `insight-card.tsx`, with `[Confirm Issue]` `[Dismiss]` `[False Positive]` `[Investigate]` actions that write to `insight_feedback`. Card shows issue, product, region, lead time vs baseline, evidence count.
- **Tab 2: Routing proof** - shows query | complexity (Simple/Complex) | intent or plan operations | features | predicted vs expected route | cost G vs V [for M-4, and plan validity for M-4b once the planner lands]
- **Tab 3: Drill-down** - `verbatim-drilldown.tsx`, shows the top 5 strongest evidence verbatims first, with a `[View all]` expander for the rest of the retrieved evidence (`top_k <= MAX_EVIDENCE_ITEMS`, up to 45; UI reads the real count, for example "Showing 18 of 18" or "Showing 45 of 250") - protection against hallucination is source-ID validation and database-backed verbatim rendering (Section 3 Layer 3 Citation Validation), not a hash check: a hash only proves text is unchanged, it does not prove an LLM claim is supported by that source
- **Wow moment — 30 sec drill-down [rehearse this]:** click insight → detail page → click claim "seal failure 12 cases" → expands to DB-rendered verbatims (never LLM text) with highlighting → chart from `COUNT_COMPLAINTS` result + graph view pack→component→supplier→other SKUs. Panel remembers: "claim opens to reveal actual complaint text".
- **State handling — specify, not mention:** Loading (skeleton for feed, spinner for evidence); Empty ("No evidence after widening filters once — partial answer with available data"); Error ("/healthz failed, rollback triggered" banner); Partial ("Showing 12 of 45, confidence 0.68 — widened filters once").
- **Demo script 3 min:** 0:00-0:30 Health + Docker Compose up; 0:30-1:00 Insight feed with FDR-controlled alerts; 1:00-1:30 Drill-down + DB-rendered verbatims + graph view [WOW]; 1:30-2:00 Ask "count similar seal failures across regions" → planner + confidence + routing proof; 2:00-2:30 Evaluation 3 headlines (Layer 5) — lead time X days early, citation Z%, FPR Y/week; 2:30-3:00 Rollback demo `scripts/demo_rollback.sh` v1→broken v2→health fail→rollback v1.
- **Tools:** Next.js 14, shadcn/ui, types generated from `/openapi.json`

### Layer 5: Evaluation [Player 3]
**Pytest + GitHub Actions**

**Golden Sets:** `data/golden/`
- `planted_issue_ground_truth.json` [20 planted issues, each with a planted **onset date**, not a hardcoded expected lead time - lead time is always measured as `detection_date - onset_date` against two baselines, see Layer 1]
- `router_golden.jsonl` [120 queries, 2 annotators, kappa>0.65] - THIS WAS MISSING = M-4 CRITICAL. Must include queries matching more than one intent signal, to exercise the deterministic precedence order (Layer 2), not just the obvious single-intent cases: `COUNT` + `SEMANTIC_SEARCH`, `COUNT` + `COMPARISON`, `TREND` + `SEMANTIC_SEARCH`, `ENTITY_LOOKUP` + `RELATIONSHIP`, and a `COMPLEX`-classified query that also contains a strong Simple-intent keyword (for example "Count similar seal failures across regions") to confirm complexity detection still wins.
- `eval_fixture.jsonl` [30 queries for citation]
- complex investigation golden set (new, additional to router_golden.jsonl, feeds M-4b): multi-region investigation, similar-complaint investigation, historical comparison, trend + comparison, ambiguous queries, unsupported queries, missing-context queries, multi-step evidence requests
- **coverage set:** one representative case per Question Coverage Catalogue class (`project-architecture-proposal.md` Section 17 operational table: class → example → route/planner op → coverage case → metric, 15 queries per class). One router handles all via precedence — do not build 15 systems.
- **citation set:** expected supporting `SourceRef` IDs plus labelled claim/verbatim pairs, for M-3 and the claim-support check
- **numeric set:** count/trend/comparison/profile questions with a known-correct number, for numeric verification
- **retrieval set:** measures `recall@20` and `nDCG@10` for hybrid retrieval, ablation where practical
- **adversarial set:** prompt-injection attempts in complaint text, PII probes, unsupported products/entities, out-of-scope questions
- **always-vector baseline:** every router golden-set query sent straight to vector retrieval, no routing - shows whether the deterministic router + Query Planner add real value over "just use vector search for everything"

**Metrics — 3 headlines + supporting (see `project-architecture-proposal.md` Section 8.0 for the full table):**
- Headline 1. Lead Time vs Baselines [M-2] — median lead time, % detected before peak, vs monthly/category + weekly SKU x region baselines at FPR budget 1/week/100 product-regions
- Headline 2. Citation Accuracy [M-3] — claim-to-verbatim accuracy, fabricated citation rate = 0%
- Headline 3. False-Positive Rate [M-1b/M-1c] — precision, alerts per week, FDR controlled
- Supporting (appendix/gate output only): M-1 recall, M-4 routing + per-class recall vs always-vector, M-4b plan validity, E13 cost/query by path, E14 p50/p95, ablation vector-only vs FTS+vector vs FTS+vector+graph for Recall@20/nDCG@10. Single-number answer: "Lead time X days earlier than baselines at Y FPR with Z% citation accuracy" (measured, never hardcoded).
- M-1 Detection Rate (Recall - did it catch the planted issue)
- M-1b Precision and False-Positive Rate - did it also raise alerts that were not real issues; reported alongside M-1 so lead time cannot look good only because the system over-alerts
- M-1c Alerts per day/week - answers "does this create alert fatigue"
- Discovered Cluster Review (part of M-1b precision): a flagged cluster that overlaps no planted issue is human-labelled (a) false positive, (b) real emerging issue found in noisy/decoy data, or (c) ambiguous; report all three counts plus Precision = TP/(TP+FP) and Discovery Rate = real emerging / total non-planted flags. Full process: `project-architecture-proposal.md` Section 8.1.
- M-2 Lead Time (Time-to-detection), measured from the planted onset date, against two baselines: the naive monthly/category baseline and the stronger naive weekly SKU x region baseline (Layer 1) - never a hardcoded expected value
- M-3 Citation Accuracy [ID match + evidence-set membership from the Citation Validator, Section 3 Layer 3 + optional RAGAS faithfulness offline]
- M-4 Routing Correctness [accuracy + per-class recall, per intent] - Simple path only, unchanged by the planner addition
- M-4b Investigation Plan Validity (Complex path, `planner_eval.py`): Valid Plan Rate, Operation Validity, Parameter Completeness, Plan Execution Success Rate, Unsupported Operation Rejection
- E13 Cost/query - for the Complex path, `TOTAL_QUERY_COST` = `PLANNER_LLM_COST` + `EXECUTION_COST` + `GENERATION_COST` (retrieval cost is part of `EXECUTION_COST`); track Simple- and Complex-path cost separately, do not treat them as equivalent without identifying the query path; log `planner_llm_cost` and `total_query_cost` in observability, below
- E14 Latency p50/p95

**Gates:** `eval-gate.yml` fails the PR if any `_MIN` metric (citation accuracy, router accuracy, graph recall) falls below its threshold, or any `_MAX` metric (lead-time regression days, false-positive rate) rises above its threshold - see `project-architecture-proposal.md` Section 6 for the one source of truth on those `EVAL_*` values and the `_MIN`/`_MAX` direction. These checks cover the Poisson-based metrics only. The BERTopic enrichment job is supplemental: its results (topics found, human reviewed, added to taxonomy) are reported alongside the gate output but never block it. M-4b is reported the same way once the planner lands: visible in gate output, not blocking, until the team locks an `EVAL_PLANNER_*` threshold (Section 8). The coverage/citation/numeric/retrieval/adversarial sets and the always-vector baseline comparison are reported the same way: visible, not gating, until the team locks a threshold to gate on.

**Observability (Complex path):** log `request_id`, `query_complexity`, `selected_path`, `planner_model`, `plan_version`, `operations`, `validation_result`, `execution_duration`, `evidence_count`, `citation_validation_result`, `planner_llm_cost`, `execution_cost`, `total_query_cost`, `final_status`. Do not log unnecessary sensitive complaint content. `audit_log` (Layer 1) is where this actually lands, durably.

**Tools:** Pytest, GitHub Actions, RAGAS offline only [not in CI]

---

## 4. Tech Stack Role Summary

| Tech | Role | Why not alternative |
| :--- | :--- | :--- |
| **Postgres + pgvector** | Single source for graph + vector + SQL aggregate | No Neo4j/Qdrant = low cost, low ops, one transaction for citation |
| **graph_nodes + graph_edges JSONB** | PostgreSQL-based property graph model with relational tables and SQL joins, with GraphRAG-style retrieval (multi-hop example: Issue -> Pack -> Region -> Related Issue), no Neo4j engine | Ordinary relational tables + JSONB, not a native SQL/PGQ property-graph feature; low cost, low ops |
| **LangGraph** | Thin router graph, not multi-agent | Blueprint says thin, proposal says no multi-agent expansion |
| **Pydantic contracts** | Single source of truth across layers | Prevents drift, required by proposal Section 5 |
| **FastAPI + asyncpg** | API + direct SQL, read-only role | Faster than MCP for detection, MCP optional only for ad-hoc tab |
| **sentence-transformers** | Embeddings, no LLM call in detection | Keeps cost low per blueprint page 63; model + dimension pinned together in `config.py` |
| **LLM_PROVIDER / LLM_MODEL_NAME** | Provider-agnostic LLM client for Layer 3 generation only | No provider or model name hardcoded outside `config.py`/`.env*`, required by proposal Section 6 |
| **Deterministic complexity detector + LLM Query Planner** | Plans, never executes, a Complex investigation query; Simple queries never reach it | Keeps the deterministic router as the default path; LLM never touches SQL/graph/vector directly, see proposal Section 5 |
| **Confidence score (Section 1) + `ROUTER_CONFIDENCE_MIN`** | Sends a `Simple`-but-low-confidence query to the Query Planner instead of a brittle keyword guess | Fixes brittle keyword-router failures without adding an LLM to the Simple/Complex decision |
| **`audit_log` + security scans (Section 16)** | Durable trace of every operation/plan/cost/verification result; secret/dependency/container scanning in CI | Debugging, evaluation, cost measurement, agentic-AI traceability, and demo evidence in one place |
| **Next.js + shadcn** | UI with attribution | Required for citation drill-down |
| **Pytest + eval-gate** | CI that blocks regression | Proves M-1 to M-4 reliably, thresholds from `config.py` only |

---

## 5. End-to-End Flow in 30 Seconds

```
DETECTION: Consumer text -> ingestion.py (PII redacted, untrusted text)
  -> graph_nodes/edges + embedding -> detection.py aggregates into daily
  cells, 7-day rolling window: baseline >= MIN_POISSON_BASELINE_COUNT ?
  Poisson/Negative-Binomial scan detects spike in 3 days : deterministic
  low-volume policy marks the result low-volume -> hierarchical roll-ups
  -> Benjamini-Hochberg FDR control -> Emerging Issue card in UI, lead
  time measured against two baselines from the planted onset date

INVESTIGATION (Simple): Quality Manager query -> Follow-up Rewrite ->
  Scope Check -> Entity Resolution -> Complexity + Confidence says
  Simple/high-confidence -> Deterministic Intent Detection -> Router
  decides Graph vs Vector vs Hybrid -> Hybrid Retrieval (FTS + vector +
  RRF) gets up to MAX_EVIDENCE_ITEMS (45) verbatims, ranked by match
  strength, never padded to a fixed count -> LLM generates insight with
  SourceRef -> Citation Validator + claim-support check + numeric
  verification -> UI shows top 5 + [View all], with the real "Showing N
  of M" count, verbatim text from DB -> Quality Manager records
  Confirm/Dismiss/False Positive/Investigate -> Evaluation reports the
  measured lead-time improvement, routing accuracy, false-positive rate,
  and cost/query from that run (all thresholds from config.py; these are
  measured values, not fixed demo numbers, and will change as the
  implementation changes)

INVESTIGATION (Complex): "Investigate this issue and see if similar
  complaints occurred in other regions." -> Complexity + Confidence says
  Complex (or Simple/low-confidence) -> LLM Query Planner produces
  InvestigationPlan (RESOLVE_INSIGHT -> SEARCH_SIMILAR_COMPLAINTS ->
  FIND_REGIONS -> GROUP_BY_REGION -> COMPARE_REGIONS -> GET_EVIDENCE) ->
  Pydantic validation + approved-operations check -> plan_executor.py
  runs each operation deterministically (Vector for similar complaints,
  SQL/Graph multi-hop traversal - Issue -> Pack -> Region -> Related
  Issue, or the deeper Pack -> Component -> Supplier -> Other Components
  -> Other Packs -> SKU -> Brand supply-chain traversal - for regional
  grouping and comparison, PostgreSQL for evidence) -> same Generation +
  Verification + UI as the Simple path -> Evaluation reports M-4b plan
  validity plus the Complex-path cost breakdown (PLANNER_LLM_COST +
  EXECUTION_COST + GENERATION_COST = TOTAL_QUERY_COST)
```

Phase 1 boundaries are defined by the Phase 1 Definition of Done table in project-architecture-proposal.md Section 14. Thresholds are recorded in the Decision Register in Section 19.

## 6. Delivery Phases and Maturity

Build in the phase order in `project-architecture-proposal.md` Section 14:
`Data -> Detection -> Retrieval -> Evidence -> API -> UI` is Phase 1,
goal a working end-to-end local demo, and it already includes the
Simple-path deterministic router and its graph/vector/SQL retrieval.
Phase 1 is defined by the Phase 1 Definition of Done table in project-architecture-proposal.md Section 14. Do not treat a Phase 1 capability as complete until its named artifact exists.
Phase 2 is the Query Planner only: complexity detector -> Query Planner
-> plan validation -> controlled plan executor -> complex investigation
evaluation. Then generation/citation trust, then evaluation/CI, then
BERTopic and UX polish last. Do not let Phase 2 delay the Phase 1
milestone. Do not claim this system is production-proven; state its
maturity the way Section 15 of that document states it — working proof
of concept with production-grade engineering discipline, not
production-proven (production-proven needs load/failure/cloud-security
evidence a capstone cannot produce) — on the panel and
in any status update.

**Two-Week Delivery Guardrail** (`project-architecture-proposal.md`
Section 14): none of the advanced capabilities documented in this file -
FDR control, Negative Binomial detection, recursive graph traversal,
entity resolution, query rewriting, hybrid retrieval, reranking, MMR,
NLI claim verification, PII redaction, prompt-injection handling, the
expanded evaluation sets - may delay Phase 1. Build the simplest valid
version first; if an advanced capability threatens the Phase 1
milestone, fall back to the simpler validated version it would have
replaced (validated Poisson instead of Negative Binomial, source-ID
membership instead of NLI verification, FTS+vector+RRF instead of
reranking) and keep the advanced version documented as
incremental/conditional, not deleted. No artificial "Day 6" or similar
deadline applies unless a future ADR defines one.

Before the final demo, confirm the Final Engineering Evidence checklist
(`project-architecture-proposal.md` Section 14) is in place: local health
checks, the rollback demonstration (`scripts/demo_rollback.sh`), the
operating runbook (`docs/runbook.md`), the agent review log
(`docs/AGENT_REVIEW_LOG.md` — every agent PR has an entry with fix +
test evidence; never fabricate, see proposal Section 9), security evidence
(threat model + agent CAN/CANNOT boundary in proposal Section 16, Query
Planner Safety Rule, citation validation), and evaluation evidence (the gate output,
3 headlines in proposal Section 8.0 + discovered-cluster review in 8.1, M-1 through M-4b).

This capstone demonstrates on a local, non-production Docker environment,
with a reproducible rollback demonstration. Per the Scope Decision in
`project-architecture-proposal.md` Section 2, do not add AWS, Azure,
Kubernetes, cloud deployment, or canary/production infrastructure; the
rollback demonstration stays a local Docker script, not a deployment
pipeline. Put remaining time into GraphRAG correctness, low-volume
detection, evidence limits, the Query Planner, evaluation, security
boundaries, and local demo reliability instead.

Every improvement documented in this file (deeper graph ontology,
detection FDR/rollups, query understanding pipeline, confidence-scored
routing, expanded planner operations, hybrid retrieval, claim/numeric
verification, PII/prompt-injection handling, audit logging) is classified
MUST, SHOULD, or COULD/FUTURE in `project-architecture-proposal.md`
Section 18, Scope Control. MCP and a dedicated graph database (Neo4j or
otherwise) stay explicitly COULD/FUTURE, documented as optional, never
core capstone work.
