# CCVIE Codebase Architecture Plan

Style note: This plan follows ASD-STE100 writing rules (Strict mode). Sentences
are short and active. Each instruction stands alone. Terms stay fixed once
defined. Folder trees and code stay as literal text and are not subject to
prose sentence rules.

## 0. Glossary

Use these terms the same way every time. Do not swap in a synonym.

- **Verbatim**: one piece of raw customer complaint text.
- **Layer**: one of the five fixed architecture layers (Data Foundation,
  Router, Retrieval and Generation, Attribution UI, Evaluation).
- **Player**: one of the four team members. Each player owns one layer.
- **Contract**: a Pydantic schema in `backend/src/ccvie/contracts/`. A
  contract defines one data shape used across layers.
- **Golden set**: the small, hand-checked set of ground-truth files under
  `data/golden/`.
- **Gate**: the CI check that fails a pull request when detection quality
  drops.
- **ADR**: Architecture Decision Record. One short file per locked decision.
- **Agent**: an AI coding agent (for example Claude Code) that reads and
  edits this repository.

## 1. Context

CCVIE is the Consumer Care Verbatim Insight Engine. It is a two-week
capstone project. A team of four players will build it.

The team already locked the five-layer technology stack in an earlier
review. That stack is PostgreSQL with pgvector, LangGraph with Pydantic,
FastAPI with asyncpg, Next.js with shadcn/ui, and Pytest with GitHub
Actions. This plan does not revisit that choice.

The team now needs one repository structure. Four players will write code
in parallel for ten to fifteen days. AI coding agents will do much of the
implementation work. The structure must let any player, and any agent
session, find the right file fast and avoid conflicts with other players.

This plan is the single reference for that structure. It stays in force
until the project ends. Any change to it needs a new ADR, not a silent
edit.

### Two Pipelines, Not One System

The five layers above describe where code lives. They do not describe how
data moves. Two separate flows move through those layers. Keep them
separate in design, diagrams, and code comments, even though they share
tables and contracts.

```
DETECTION PIPELINE (runs on a schedule, no user in the loop)
Complaints -> Taxonomy -> Aggregation -> Poisson Scan -> Emerging Issue

INVESTIGATION PIPELINE (runs on a user query)
User Query -> Deterministic Complexity Detector
  Simple  -> Deterministic Router -> Graph / SQL / Vector / Hybrid
  Complex -> LLM Query Planner -> Pydantic Validation -> Approved
             Operations -> Deterministic Plan Executor
             -> Graph / SQL / Vector / Hybrid
  -> Evidence -> LLM Explanation -> Citation Validation
```

Both pipelines write to, or read from, the same Layer 1 tables. Both feed
the Layer 4 Attribution UI: the Detection pipeline produces the insight
feed, the Investigation pipeline answers a drill-down question about one
insight. Treat a change to one pipeline as independent of the other unless
a change touches a shared contract or table.

Inside the Investigation pipeline, a Simple query and a Complex query are
also two separate paths, not one system. Section 5's Query Planner Safety
Rule states why: the Complex path adds a validated LLM planning step in
front of the same deterministic execution the Simple path already uses,
never a replacement for it.

### GraphRAG Terminology

Describe the Layer 1 graph model with one wording, everywhere:

> PostgreSQL-based relational property-graph model with GraphRAG-style
> retrieval.

Never describe it as a dedicated graph database. The implementation is:

```
graph_nodes
graph_edges
    ↓
SQL-based graph traversal
    ↓
GraphRAG-style retrieval
```

`graph_nodes`/`graph_edges` are ordinary relational tables with JSONB
properties, read with SQL joins. This is precise and defensible in a
panel Q&A; do not add a dedicated graph database to make the retrieval
sound more sophisticated than it is.

A meaningful retrieval from this model is multi-hop, not one join. The
canonical example, used in the investigation flow (Layer 2, GRAPH route)
and in evaluation (graph recall, Section 8):

```
Issue -> Pack -> Region -> Related Issue
```

For example: start from one confirmed Issue node, traverse to its Pack,
from Pack to Region, then from Region to any other Issue node sharing
that Region — this is how the GRAPH route answers "is this issue
happening elsewhere," not a single-table lookup.

### Low-Volume Detection Policy

The Detection pipeline's Poisson scan assumes a baseline count large
enough for a spike to be statistically meaningful. It is not sufficient
when the baseline is zero or very small; a jump from 0 to 3 complaints is
not a Poisson spike, it is the entire population.

```
baseline >= MIN_POISSON_BASELINE_COUNT -> Poisson scan
baseline <  MIN_POISSON_BASELINE_COUNT -> Low-volume detection policy
```

`MIN_POISSON_BASELINE_COUNT` (Section 6) is the one switch between the
two policies. The low-volume policy uses deterministic minimum-count and
historical-context rules, not a second statistical model, and marks its
result explicitly as low-volume so the UI and evaluation can distinguish
it from a Poisson-confirmed spike. Do not add statistical complexity here
beyond what the evaluation requires. `data_foundation/detection.py`
(Section 3) owns both the Poisson scan and the low-volume policy, so one
file, not two divergent implementations, decides which path a given
region/issue/week takes.

Test both sides of the switch, not only the common case: `baseline = 0`,
`baseline = 1`, a low but nonzero baseline, a normal baseline, and a
high-volume spike (Section 7).

## 2. Repository Structure Decision

**Decision: one monorepo. Not separate repositories.**

Reasons:

1. The layers share data shapes, not just an interface. The Pydantic
   contract for one API response feeds the router, the evaluation harness,
   and the frontend at the same time. A change in one place must reach all
   three at once. Separate repositories turn each such change into a
   multi-repo version bump. A two-week team cannot absorb that cost.
2. An agent session reads one repository at a time. In one monorepo, an
   agent that changes a contract can see and fix every affected file in
   the same session. Across separate repositories, the agent loses that
   view and needs manual handoffs between checkouts.
3. The project uses only two languages: Python and TypeScript. This is a
   low polyglot cost. A monorepo does not need heavy build tools such as
   Nx or Turborepo to manage two languages. Plain folder separation is
   enough.
4. One pull request must trigger one CI gate. A single repository makes
   this a single workflow file. Cross-repository CI triggers add plumbing
   this timeline does not need.

Do not add Nx, Turborepo, Kubernetes, or a service mesh to this project.
These tools solve problems this project does not have.

**Scope decision: this capstone demonstrates locally.** Do not add cloud
deployment, canary deployment, or rollback implementation to the current
scope. Spend remaining engineering time on GraphRAG correctness,
low-volume detection, evidence limits, the Query Planner, evaluation,
security boundaries, and local demo reliability — not on infrastructure
this two-week project does not need. Section 15 states the resulting
maturity honestly.

## 3. Full Folder Tree

```
CCVIE/
├── .github/
│   └── workflows/
│       ├── ci.yml                    # lint + unit/integration tests, required on every PR
│       └── eval-gate.yml             # regression gate: lead-time, citation, router accuracy
├── backend/                          # all Python code, one installable package
│   ├── pyproject.toml                # uv-managed, single package "ccvie"
│   ├── uv.lock
│   ├── Dockerfile
│   ├── src/
│   │   └── ccvie/
│   │       ├── __init__.py
│   │       ├── config.py             # the one Settings object, see Section 6
│   │       ├── contracts/            # the shared schemas, see Section 5
│   │       │   ├── __init__.py
│   │       │   ├── entities.py       # Product, Pack, Region, IssueType, DatePeriod
│   │       │   ├── query.py          # QueryRequest
│   │       │   ├── router.py         # RouterFeatures, RouteDecision
│   │       │   ├── insight.py        # Claim, SourceRef, InsightResponse
│   │       │   └── planner.py        # InvestigationPlan, InvestigationOperation, OperationType, see Query Planner Safety Rule
│   │       ├── data_foundation/      # Player 1 code
│   │       │   ├── db.py             # asyncpg pool and connection helpers
│   │       │   ├── ingestion.py      # hourly batch ingestion job, nightly low-coverage flagging job
│   │       │   ├── detection.py      # Poisson scan + low-volume detection policy, see Section 1
│   │       │   ├── embeddings.py     # sentence-transformers wrapper
│   │       │   ├── bertopic_enrichment.py  # daily supplemental clustering job, see docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md
│   │       │   └── queries/
│   │       │       ├── graph_queries.py    # raw SQL: entity joins
│   │       │       ├── vector_queries.py   # raw SQL: pgvector distance queries
│   │       │       └── sql_queries.py      # raw SQL: aggregate ops (COUNT_COMPLAINTS etc.), same read-only ownership as the two files above
│   │       ├── router/               # Player 2 code, Layer 2
│   │       │   ├── graph.py          # the thin LangGraph node graph, see the complexity-branch flow in Section 5
│   │       │   ├── features.py       # entity_count, word_count, taxonomy_coverage
│   │       │   ├── rules.py          # threshold rules, values pulled from config
│   │       │   ├── complexity.py     # deterministic Simple vs Complex detector, unit-tested, no LLM call
│   │       │   ├── planner.py        # LLM Query Planner: query -> InvestigationPlan, planning only, never executes
│   │       │   └── plan_executor.py  # deterministic executor, accepts only a validated InvestigationPlan
│   │       ├── retrieval_gen/        # Player 2 code, Layer 3
│   │       │   ├── api.py            # FastAPI app and route handlers
│   │       │   ├── orchestrator.py   # hybrid retrieval orchestration
│   │       │   ├── llm.py            # thin LLM client, model name from config only
│   │       │   ├── evidence.py       # evidence assembly, shared by the Simple and Complex paths
│   │       │   ├── citation_validator.py  # Source ID existence + evidence-set membership check, see Section 5
│   │       │   └── prompts/
│   │       │       └── synthesize_insight.md
│   │       └── evaluation/           # Player 3 code, Layer 5 harness
│   │           ├── simulate.py       # replays synthetic data over simulated time
│   │           ├── lead_time.py      # lead time vs. naive monthly baseline
│   │           ├── scoring.py        # citation accuracy, router accuracy
│   │           ├── planner_eval.py   # M-4b Investigation Plan Validity, see Section 7
│   │           └── gate.py           # CI gate entry point
│   └── tests/
│       ├── unit/
│       ├── integration/              # runs against a throwaway pgvector container
│       └── eval/
│           ├── test_lead_time_regression.py   # the CI gate test
│           ├── test_citation_accuracy.py
│           └── test_router_accuracy.py
├── frontend/                         # all TypeScript code, the only Node part
│   ├── package.json
│   ├── next.config.js
│   ├── Dockerfile
│   ├── .env.local.example
│   └── src/
│       ├── app/
│       │   ├── page.tsx              # insight feed
│       │   └── insight/[id]/page.tsx # drill-down to source verbatims
│       ├── components/
│       │   ├── ui/                   # shadcn components
│       │   ├── insight-card.tsx
│       │   └── verbatim-drilldown.tsx
│       ├── lib/
│       │   ├── api-client.ts
│       │   └── types.generated.ts    # generated from backend OpenAPI, never hand-edited
│       └── mocks/
│           └── insight-response.mock.json   # Day-1 mock, matches the locked contract
├── db/
│   ├── migrations/                   # numbered plain SQL, applied in order
│   │   ├── 0001_init_entities.sql
│   │   ├── 0002_pgvector_extension_and_index.sql
│   │   ├── 0003_verbatims_and_embeddings.sql
│   │   ├── 0004_low_coverage_queue_and_taxonomy_proposals.sql   # unique index prevents duplicate queue entries
│   │   └── 0005_insight_feedback.sql # Quality Manager decision log, see Section 7
│   ├── seed/
│   │   └── seed_taxonomy.sql         # static Product/Pack/Region/IssueType rows
│   └── schema.sql                    # generated snapshot, committed, do not hand-edit
├── data/
│   ├── generators/                   # Player 3 code, committed
│   │   ├── generate_synthetic_verbatims.py
│   │   ├── plant_issue.py
│   │   └── taxonomy_config.yaml      # shared vocabulary, mirrors db/seed/seed_taxonomy.sql
│   ├── golden/                       # committed, small, hand-checked ground truth
│   │   ├── planted_issue_ground_truth.json   # region, week, count, expected lead time
│   │   ├── router_labeled_queries.json       # 120 query pairs (30 per route class) and the correct path
│   │   └── eval_fixture.jsonl        # small fixed dataset, used by the CI gate
│   └── generated/                    # gitignored, bulk output, regenerated on demand
│       └── .gitkeep
├── docs/
│   ├── architecture.md               # the living architecture doc, see Section 9
│   ├── api-contract.md               # points to code and to /openapi.json, no field copies
│   ├── runbook.md                    # local setup steps and demo-day steps
│   ├── demo-script.md                # panel walkthrough talking points
│   └── adr/
│       ├── template.md
│       ├── 0001-router-threshold-rules.md
│       ├── 0002-planted-issue-design.md
│       └── 0003-ingestion-cadence.md
├── docker-compose.yml                # postgres+pgvector, backend, frontend
├── .env.example                      # every env var used anywhere in the system
├── .gitignore
├── Makefile                          # thin convenience wrapper, see Section 11
├── CLAUDE.md                         # agent orientation file, see Section 10
└── README.md
```

## 4. Folder Ownership Map

Each player owns one set of folders. Ownership means that player merges
changes to that folder. Other players may propose changes there, but the
owner approves them.

| Player | Owned folders |
|---|---|
| Player 1 (Data Foundation) | `db/migrations/`, `db/seed/`, `backend/src/ccvie/data_foundation/` |
| Player 2 (Router, Retrieval, Generation) | `backend/src/ccvie/router/`, `backend/src/ccvie/retrieval_gen/`, joint ownership of `backend/src/ccvie/contracts/` |
| Player 3 (Data, Evaluation) | `data/generators/`, `data/golden/`, `backend/src/ccvie/evaluation/`, `backend/tests/eval/`, `.github/workflows/eval-gate.yml` |
| Player 4 (Frontend, Attribution UI) | `frontend/`, `docs/demo-script.md` |

`backend/src/ccvie/contracts/` has two owners: Player 2 and Player 4. Lock
its first version on Day 1, before other backend code exists. Treat any
later change to a contract file as a change both owners must approve.

## 5. Shared Contract Rule

**Rule: `backend/src/ccvie/contracts/` is the only place that defines an
API data shape. No other file may redefine one.**

FastAPI route handlers in `retrieval_gen/api.py` use these contract classes
directly as request and response types. This keeps the live
`/openapi.json` file in sync with the contract code at all times, with no
extra step.

Three consumers read the same contract file, never a copy:

1. The router (`router/rules.py`) imports `contracts.router.RouteDecision`.
2. The evaluation harness (`evaluation/scoring.py`) imports
   `contracts.insight.InsightResponse` to check golden-set results against
   the real response shape.
3. The frontend never hand-writes matching TypeScript types. Run
   `make gen-types` to call `openapi-typescript` against the backend
   OpenAPI schema. This command writes
   `frontend/src/lib/types.generated.ts`. The file carries a header comment
   that says `GENERATED — do not edit`. CI re-runs this generation step and
   fails the build if the committed file does not match the fresh output.

On Day 1, write the contract classes by hand to match the UI mockups,
before backend logic exists. Player 4 then builds the UI against
`frontend/src/mocks/insight-response.mock.json`. Add a small backend test,
`backend/tests/unit/test_mock_matches_contract.py`, that checks this mock
file validates against the real contract class. Player 4 later swaps the
mock for a live network call, with no type changes needed.

A valid `SourceRef` ID is not proof the claim is true. Before
`InsightResponse` leaves `retrieval_gen/api.py`, a citation validator step
checks two things: every `SourceRef` ID exists, and every `SourceRef` ID
belongs to the evidence set that was actually retrieved for that query
(not just any verbatim in the database). The frontend never renders a
verbatim string the LLM produced. It renders the verbatim text fetched
directly from the database by ID, so a hallucinated quote cannot reach the
Quality Manager.

The database schema follows the same rule at the SQL level.
`db/migrations/*.sql` files are the source of truth. `db/schema.sql` is a
generated, committed snapshot. Produce it with `make db-schema-dump`, which
runs `pg_dump --schema-only` against the local database. Any reader, human
or agent, can open this one file to see the current table structure.

### Query Planner Safety Rule

A Complex investigation query (Section 1's "Two Pipelines") does not skip
the rules above. It adds one more validated hop in front of them.

**Rule: the LLM Query Planner may only plan. It never executes a query.**

```
LLM Planner -> InvestigationPlan -> Pydantic Validation
            -> Approved Operations -> Deterministic Executor
            -> SQL / Graph / Vector / Hybrid
```

`backend/src/ccvie/contracts/planner.py` defines `InvestigationPlan`,
`InvestigationOperation`, and `OperationType`. A plan carries
`original_query`, `operations`, `dependencies`, `parameters`, and
`plan_version`. The initial `plan_version` is `"1.0"`.

`router/plan_executor.py` accepts only an `InvestigationPlan` that passed
Pydantic validation. It maps each operation to one existing retrieval
function and contains no LLM reasoning, for example:

```
COUNT_COMPLAINTS          -> sql_queries.count_complaints()
SEARCH_SIMILAR_COMPLAINTS -> vector_queries.search_similar_complaints()
FIND_REGIONS              -> graph_queries.find_regions()
GET_EVIDENCE              -> evidence.get_evidence()
```

The planner may use only this approved operation vocabulary:

```
RESOLVE_INSIGHT, GET_ISSUE_DETAILS, COUNT_COMPLAINTS,
GET_COMPLAINT_TREND, SEARCH_SIMILAR_COMPLAINTS, FIND_REGIONS,
GROUP_BY_REGION, COMPARE_REGIONS, GET_BASELINE,
GET_HISTORICAL_BASELINE, GET_ISSUE_HISTORY, GET_PRODUCT_HISTORY,
GET_EVIDENCE
```

`plan_executor.py` rejects any operation name outside this list, and never
silently runs a plan whose `plan_version` is not in
`PLANNER_SUPPORTED_PLAN_VERSION` (Section 6). The LLM must never: generate
SQL for execution, execute SQL, access PostgreSQL, pgvector, or graph
tables directly, access credentials, modify data or schema, bypass
Pydantic validation, invoke arbitrary tools, or invoke unrestricted
external services.

A breaking change to `InvestigationPlan` or to operation semantics needs
all of: an incremented `plan_version`, updated Pydantic contracts, updated
executor compatibility, an updated planner prompt/schema, updated planner
golden tests, updated evaluation fixtures, and a new ADR.

### Evidence and Citation Limit

Do not word anything, in code, docs, or the demo script, as if the system
requires exactly 45 verbatims. `MAX_EVIDENCE_ITEMS` (Section 6, default
45) is a cap, not a target: `top_k <= MAX_EVIDENCE_ITEMS`.

```
18 matching complaints  -> return up to 18
45 matching complaints  -> return 45
250 matching complaints -> retrieve/rank the top 45
```

Citation validation (above) already checks every citation the generated
response actually used against the retrieved evidence set; it does not,
and must not, assume the set has exactly 45 members. The UI reflects the
real count: `Showing 18 of 18`, or `Showing 45 of 250` with `[View all]`.
`PLANNER_MAX_EVIDENCE_ITEMS` (Section 6) is the Complex path's version of
this same cap; keep both settings equal by default so "45" means one
thing across the Simple and Complex paths.

## 6. Configuration Rule

**Rule: one settings object holds every configuration value. No file reads
an environment variable directly except that one object.**

`backend/src/ccvie/config.py` defines one `pydantic-settings` class named
`Settings`. Code imports it as `from ccvie.config import settings` and
reads values from that object.

The root file `.env.example` lists every variable the system uses, grouped
by layer:

```
# --- Database ---
DATABASE_URL=postgresql://ccvie:ccvie@localhost:5432/ccvie

# --- Embeddings (Layer 1) ---
# EMBEDDING_DIMENSION must match the output size of EMBEDDING_MODEL_NAME.
# all-MiniLM-L6-v2 outputs 384 dimensions, not 768. Change both values
# together if the model changes. db/migrations/*.sql reads this pair, not
# a hardcoded vector() width, when defining verbatim_embeddings.
EMBEDDING_MODEL_NAME=all-MiniLM-L6-v2
EMBEDDING_DIMENSION=384

# --- LLM (Layer 3) — change the provider or model here, nowhere else ---
LLM_PROVIDER=anthropic
LLM_MODEL_NAME=

# --- Router thresholds (Layer 2, see ADR-0001) ---
ROUTER_ENTITY_COUNT_THRESHOLD=3
ROUTER_WORD_COUNT_LOW=50
ROUTER_WORD_COUNT_HIGH=150
ROUTER_TAXONOMY_COVERAGE_HIGH=0.80
ROUTER_TAXONOMY_COVERAGE_LOW=0.40

# --- Evidence retrieval cap (Layer 3, both Simple and Complex paths).
# This is a cap, not a required count: top_k <= MAX_EVIDENCE_ITEMS. See
# the Evidence and Citation Limit note in Section 5. ---
MAX_EVIDENCE_ITEMS=45

# --- Query Planner (Layer 2/3, Complex investigation path only,
# see the Query Planner Safety Rule in Section 5). PLANNER_MAX_EVIDENCE_ITEMS
# is this same cap for the Complex path; keep it equal to
# MAX_EVIDENCE_ITEMS above unless a documented reason requires otherwise. ---
PLANNER_ENABLED=true
PLANNER_MAX_OPERATIONS=8
PLANNER_MAX_EXECUTION_DEPTH=5
PLANNER_MAX_EXECUTION_TIME_SECONDS=15
PLANNER_MAX_EVIDENCE_ITEMS=45
PLANNER_SUPPORTED_PLAN_VERSION=1.0

# --- Detection thresholds (Layer 1, see the Low-Volume Detection Policy
# in Section 1). Below this baseline, detection.py uses the deterministic
# low-volume policy instead of the Poisson scan. ---
MIN_POISSON_BASELINE_COUNT=5

# --- Ingestion cadence (see ADR-0003) ---
INGESTION_CADENCE_MINUTES=60

# --- Detection pipeline enrichment (Layer 1, non-blocking)
# see docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md ---
LOW_COVERAGE_QUEUE_THRESHOLD=0.3
BERTOPIC_RUN_THRESHOLD=50
BERTOPIC_RUN_SCHEDULE=daily
BERTOPIC_MAX_QUEUE_SIZE=2000
BERTOPIC_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
BERTOPIC_RANDOM_STATE=42

# --- Eval / CI gate thresholds (Layer 5) ---
# This block is the only place a threshold value is written. Every other
# document (docs/CCVIE_Project_26_Workflow.md, ADRs, demo slides) must
# reference these names, never restate the number, so the docs cannot
# drift out of sync with the gate.
#
# A _MIN name fails when the measured value is below it. A _MAX name
# fails when the measured value is above it. gate.py reads the suffix to
# pick the comparison direction; do not treat every threshold as a
# "below threshold fails" check.
EVAL_LEAD_TIME_REGRESSION_MAX_DAYS_DROP=1
EVAL_CITATION_ACCURACY_MIN=0.95
EVAL_ROUTER_ACCURACY_MIN=0.85
EVAL_GRAPH_RECALL_MIN=0.70
EVAL_FALSE_POSITIVE_RATE_MAX=0.15

# --- Frontend, copied into frontend/.env.local by make bootstrap ---
NEXT_PUBLIC_API_BASE_URL=http://localhost:8000
```

Leave `LLM_MODEL_NAME` blank in the template on purpose. The team may
decide, and change, this value often. Set the real value only in the
local `.env` file and in the CI secret store, never in code.

Add one CI check that scans the repository for model-name-shaped strings
(for example text starting with `claude-` or `gpt-`) outside `config.py`
and files matching `.env*`. Fail the build if it finds one. This stops a
model name from leaking into code where it becomes hard to change.

## 7. Synthetic Data and Golden Set Rule

- `data/generators/` holds committed Python scripts only, no generated
  data. `taxonomy_config.yaml` lists the shared Product, Pack, Region, and
  IssueType vocabulary. Both `generate_synthetic_verbatims.py` and
  `db/seed/seed_taxonomy.sql` must use this same vocabulary, so the
  generator never invents an entity the database does not know.
- `data/golden/planted_issue_ground_truth.json` is the machine-readable
  form of ADR-0002. It states the exact region, week range, complaint
  count, and expected baseline lead time. `plant_issue.py` reads this file
  to seed the data. `evaluation/lead_time.py` reads the same file to check
  detection. One file removes drift between what the team planted and what
  the team checks for. Include planted cases on both sides of
  `MIN_POISSON_BASELINE_COUNT`: baseline = 0, baseline = 1, a low nonzero
  baseline, a normal baseline, and a high-volume spike, so `detection.py`'s
  low-volume policy is tested, not only the Poisson scan (see Section 1,
  Low-Volume Detection Policy).
- `data/golden/router_labeled_queries.json` holds 120 query pairs and
  their correct path: 30 Graph, 30 SQL Aggregate, 30 Vector, 30 Hybrid.
  Include ambiguous and difficult queries (for example a comparison query
  spanning two regions), not only obvious single-entity cases. The Graph
  set must include at least one genuine multi-hop case (`Issue -> Pack ->
  Region -> Related Issue`, Section 1), not only single-join lookups, so
  graph recall reflects real GraphRAG-style retrieval. Both the router
  test harness and CI use this file. This is the one number for the
  router golden set; do not restate a different count elsewhere.
- `data/golden/eval_fixture.jsonl` is a small, fixed dataset. The CI gate
  uses this file, not the full generated dataset, so every CI run stays
  fast and repeats the same result.
- `data/generated/` is gitignored. It holds the bulk output of
  `make gen-data`. Never commit this folder. Regenerate it at any time
  with a fixed random seed, so results stay repeatable.
- `generate_synthetic_verbatims.py` must not generate clean taxonomy terms
  only. Include synonyms, typos, abbreviations, short and long complaints,
  ambiguous complaints, complaints naming more than one issue, missing
  metadata, duplicates, and irrelevant complaints, in natural consumer
  language (for example "lid doesn't close", "bag keeps opening", "seal
  comes loose", not only "seal failure"). Clean-only data makes detection
  and routing look better than they will on real complaint text.
- Quality Manager decisions on an insight (`Confirm Issue`, `Dismiss`,
  `False Positive`, `Investigate`) are captured, not discarded. Player 1
  owns an `insight_feedback` table (`feedback_id`, `insight_id`,
  `decision`, `reason`, `user_id`, `created_at`, optional `metadata jsonb`
  for future fields) under `db/migrations/`. Use `user_id`, not an email
  address, so the audit log stays stable if a user's email changes and
  does not leak an email address into a table other services may read.
  This is not part of the golden set; it is a growing feedback log the
  evaluation harness may sample from later.
- A separate golden set of complex investigation queries feeds M-4b
  (Section 8): multi-region investigation, similar-complaint
  investigation, historical comparison, trend plus comparison, ambiguous
  queries, unsupported queries, missing-context queries, and multi-step
  evidence requests. This set is additional to, not a replacement for,
  the 120-query router golden set above; router evaluation stays
  unchanged.

## 8. CI Gate Structure

Two workflow files live under `.github/workflows/`.

**`ci.yml`** runs on every pull request and must pass before merge. It
runs:

1. `ruff` and `black` checks on the backend code.
2. `eslint` and a TypeScript type check on the frontend code.
3. `pytest backend/tests/unit backend/tests/integration`, against a
   pgvector service container started inside the workflow.
4. The generated-types drift check from Section 5.

**`eval-gate.yml`** runs on pull requests that touch `backend/`, `db/`,
`data/generators/`, or `data/golden/`. It runs:

1. Start a pgvector service container.
2. Apply migrations and load seed data.
3. Load `data/golden/eval_fixture.jsonl`.
4. Run `backend/tests/eval/*`, which call `evaluation/gate.py`.
5. Compare the lead-time, citation-accuracy, router-accuracy,
   graph-recall, and false-positive-rate results against the `EVAL_*`
   thresholds from `config.py`. Detection quality is not only "did it
   detect the planted issue" (recall); also check how many alerts fired
   that were not planted issues (false-positive rate) and alerts per
   day/week, so a noisy detector cannot pass the gate on lead time alone.
6. Exit with a non-zero status if any `_MIN` metric falls below its
   threshold, or any `_MAX` metric rises above its threshold (see the
   `_MIN`/`_MAX` note in Section 6).

The gate checks Poisson-based detection metrics only. The BERTopic
enrichment job (`data_foundation/bertopic_enrichment.py`) is supplemental
and non-blocking: its output (topics found, human reviewed, added to
taxonomy) is reported separately and never fails `eval-gate.yml`. See
`docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md` for the detection
pipeline design. If the timeline runs short, cut BERTopic scope first.
Do not remove the `low_coverage_queue` or `taxonomy_proposals` schema:
keeping the schema costs nothing and leaves the door open to finish the
job later.

Once the Query Planner (Phase 2, Section 14) exists, `evaluation/gate.py`
also reports M-4b Investigation Plan Validity: valid plan rate, operation
validity, parameter completeness, plan execution success rate, and
unsupported-operation rejection rate, from the complex investigation
golden set in Section 7. Report M-4b in the gate output as soon as the
planner lands; do not block a merge on it until the team locks an
`EVAL_PLANNER_*` threshold in this config, the same way every other gate
metric is locked here first.

Mark both workflows as required status checks in branch protection. This
makes the eval gate a real block on merge, not an optional report.

## 9. Documentation and ADR Rule

- Each locked decision gets one ADR file under `docs/adr/`, written from
  `docs/adr/template.md`. The template has four sections: Context,
  Decision, Consequences, Status.
- Write `0001-router-threshold-rules.md`, `0002-planted-issue-design.md`,
  and `0003-ingestion-cadence.md` by the end of Day 2. Do not start Layer 2
  or Layer 5 implementation before these three files exist.
- `docs/architecture.md` is the one living architecture document. Each
  player updates their own section as their layer changes. Add a line to
  the pull-request template that asks: "Did you update
  docs/architecture.md?"
- `docs/api-contract.md` stays short. It points to
  `backend/src/ccvie/contracts/` and to the live `/openapi.json` file. It
  does not restate field names, so it cannot drift out of sync with the
  code.
- `docs/runbook.md` holds local setup steps. `docs/demo-script.md` holds
  the panel-day walkthrough.

## 10. CLAUDE.md — Agent Orientation File

Create `CLAUDE.md` at the repository root. Any AI coding agent reads this
file first. Write it in the same short, direct style as this plan. It must
state, in this order:

1. **One-line project summary.** What the system does, in one sentence.
2. **The five layers and their owners.** A short table matching Section 4.
3. **The three fixed rules.** State each as one sentence:
   - Contracts live only in `backend/src/ccvie/contracts/`. See Section 5.
   - Configuration lives only in `backend/src/ccvie/config.py`. See
     Section 6.
   - No file states a model name except `config.py` and `.env` files.
4. **Where to find the current decisions.** Point to `docs/adr/` and
   `docs/architecture.md`.
5. **Where to find the golden set.** Point to `data/golden/` and state
   that these files define correct system behavior.
6. **Commands to run tests and the eval gate locally.** List the exact
   `make` targets from Section 11.
7. **Three explicit warnings**, each as one sentence:
   - Do not add a graph database. The entity model is a shallow hierarchy
     and fits plain SQL tables.
   - Do not expand the router into a multi-agent system. Keep it a thin
     graph over fixed threshold rules.
   - Do not commit files under `data/generated/`. That folder is
     gitignored on purpose.
8. **Query Planner warnings**, once Phase 2 (Section 14) lands, each as
   one sentence:
   - Do not let the Complex path replace the deterministic router. Only
     a query the complexity detector classifies Complex reaches the
     planner.
   - Do not let the LLM execute SQL or touch the database directly. It
     may only produce a validated `InvestigationPlan`, per the Query
     Planner Safety Rule in Section 5.

Keep `CLAUDE.md` under one page. Update it only when a rule in this plan
changes, and record that change as a new ADR.

## 11. Local Development Steps

Run these steps in order, from a fresh clone.

1. `cp .env.example .env` and fill in the LLM API key and any other blank
   value.
2. `make bootstrap` — installs backend dependencies with `uv`, installs
   frontend dependencies with `npm`, and copies frontend-relevant values
   into `frontend/.env.local`.
3. `docker compose up -d db` — starts the Postgres and pgvector container.
4. `make migrate` — applies every file under `db/migrations/` in order.
5. `make seed` — loads `db/seed/seed_taxonomy.sql`.
6. `make gen-data` — runs the scripts under `data/generators/`, writes
   output to `data/generated/`, and plants the seeded issue.
7. `make dev-backend` — starts the FastAPI app with live reload.
8. `make dev-frontend` — starts the Next.js dev server.
9. Open `http://localhost:3000` in a browser.

Windows note: the team works on Windows with PowerShell. Treat the
`Makefile` as an optional convenience layer, not a requirement. Install GNU
Make through a package manager, or use a `justfile` as a cross-platform
fallback. Write out the exact PowerShell command behind each `make` target
in `docs/runbook.md`, so no player is blocked if `make` is not installed.

If Docker on a given laptop causes setup problems, fall back to a shared
hosted Postgres instance with pgvector enabled, such as Supabase or Neon.
Point `DATABASE_URL` at that instance instead of the local container. Keep
this as a documented fallback in `docs/runbook.md`, not the default path.

## 12. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Python import errors across folders | Use one `src/ccvie` package layout with one `pyproject.toml`. Every import reads as `from ccvie.<layer> import ...`, regardless of the caller's location. |
| Docker image bloat from mixing Python and Node | Give `backend/` and `frontend/` separate `Dockerfile`s and separate `.dockerignore` entries for `node_modules`, `.venv`, and `__pycache__`. |
| Large synthetic data files entering git history | Keep `data/generated/` gitignored. Add a pre-commit or CI check that rejects new files over roughly 1 MB under `data/`. |
| Leaked secrets | Add `.env` and `frontend/.env.local` to `.gitignore` from the first commit. Track only `.env.example` and `.env.local.example`. Store real keys as CI repository secrets. |
| Frontend types drifting from the backend contract | Generate frontend types from the live OpenAPI schema. Fail CI if the committed generated file does not match a fresh generation run. |
| Database schema drifting from migrations | Regenerate and commit `db/schema.sql` after every migration change. Check it in CI. |
| A model name hardcoded outside config | Run the CI grep check from Section 6 on every pull request. |
| Merge conflicts on the shared contract file | Lock the first version on Day 1. Require both Player 2 and Player 4 to approve any later change. Keep each change small. |

## 13. Verification Plan

Confirm this structure works before any layer logic is complex. Run these
checks in order, once the skeleton exists.

1. Run `make bootstrap` on a clean clone. Confirm it finishes with no
   error, for both the backend and the frontend.
2. Run `docker compose up -d db`, then `make migrate`, then `make seed`.
   Confirm the database contains the taxonomy rows.
3. Run `make gen-data`. Confirm `data/generated/` fills with files and
   `data/golden/planted_issue_ground_truth.json` stays unchanged.
4. Start the backend with `make dev-backend`. Open `/openapi.json` in a
   browser. Confirm the contract classes from Section 5 appear there.
5. Run `make gen-types` in the frontend. Confirm
   `frontend/src/lib/types.generated.ts` updates with no manual edit
   needed.
6. Run the mock-contract test,
   `backend/tests/unit/test_mock_matches_contract.py`. Confirm it passes,
   which proves the Day-1 mock matches the real contract.
7. Push a pull request that changes only a comment. Confirm `ci.yml` runs
   and passes.
8. Push a pull request that edits a file under `backend/`. Confirm
   `eval-gate.yml` also runs, and confirm it fails on purpose if you lower
   a value in `data/golden/eval_fixture.jsonl` below a set threshold. This
   proves the gate blocks a real regression.
9. Read `CLAUDE.md` from a fresh AI agent session with no other context.
   Confirm the agent can state, from that file alone, where contracts
   live, where config lives, and which folder it may edit for a stated
   task.

If every check above passes, the repository structure is ready for full
layer implementation to begin.

## 14. Development Phases

The full architecture in this plan is larger than the timeline. Build it
in this order. Do not start a later phase before the core end-to-end demo
in Phase 1 through Phase 4 works.

1. **Phase 1 — Core path.** Data Foundation tables, the Poisson detection
   pipeline, evidence retrieval, the FastAPI route, and the insight feed
   UI. This alone must run end to end before any other phase starts.
2. **Phase 2 — Investigation pipeline.** Graph queries, vector queries,
   and the deterministic router (Section on router intents in
   `docs/CCVIE_Project_26_Workflow.md`) for the Simple path; the
   deterministic complexity detector, LLM Query Planner, Pydantic plan
   validation, and `plan_executor.py` (Section 5's Query Planner Safety
   Rule) for the Complex path. Do not let Query Planner work delay the
   Phase 1 milestone; land the Simple path and the planner's safety
   boundary before polishing complex-query coverage.
3. **Phase 3 — Generation and trust.** LLM synthesis and the citation
   validator from Section 5.
4. **Phase 4 — Evaluation and CI.** The golden sets, `eval-gate.yml`, and
   the metrics in Section 8.
5. **Phase 5 — BERTopic and UX polish.** The supplemental enrichment job
   from `docs/DETECTION_PIPELINE_IMPLEMENTATION_CORRECTED.md`, the
   top-5-then-view-all evidence UX, and the feedback buttons. Cut this
   phase first if time runs out; it is additive, not load-bearing.

## 15. Project Maturity Statement

State the project's maturity honestly, in any doc or demo that discusses
production readiness. Do not assign an arbitrary "production readiness"
percentage.

The honest framing: academically strong, architecturally
production-minded, not yet production-proven. Production-proven requires
evidence this two-week capstone does not produce: load testing,
failure/recovery testing, security validation, observability, and a
rollback demonstration. Evaluation results from Section 8 prove detection
and routing quality; they do not by themselves prove production
readiness.
