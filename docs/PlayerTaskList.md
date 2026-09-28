# CCVIE — Team TODO List

## 👩‍💻 Player1 — Data + GraphRAG + Retrieval

- [ ] Setup PostgreSQL schema and migrations
- [ ] Setup pgvector + HNSW indexes
- [ ] Setup PostgreSQL FTS + `pg_trgm`
- [ ] Implement complaint ingestion + validation
- [ ] Implement deduplication/normalization
- [ ] Implement taxonomy tables and mappings
- [ ] Implement entity/alias tables
- [ ] Implement deep graph ontology:
  - [ ] Brand → Product → SKU → Pack
  - [ ] Pack → Component → Supplier → Plant
  - [ ] Ingredient relationships
  - [ ] City → Region → Market
  - [ ] IssueType → IssueCategory
- [ ] Implement `graph_nodes` / `graph_edges`
- [ ] Add graph indexes for `src`, `dst`, and required filters
- [ ] Implement recursive CTE multi-hop graph traversal
- [ ] Implement graph retrieval interface
- [ ] Implement embedding generation/storage/versioning
- [ ] Implement SQL retrieval
- [ ] Implement vector retrieval
- [ ] Implement PostgreSQL FTS retrieval
- [ ] Implement hybrid FTS + vector retrieval
- [ ] Implement RRF fusion
- [ ] Implement metadata filtering + evidence deduplication
- [ ] Implement entity-resolution backend support (`alias + pg_trgm + embedding`)
- [ ] Implement low-volume data handling support
- [ ] Provide stable APIs/interfaces for Player2's investigation engine
- [ ] Add unit/integration tests for DB, graph and retrieval

## 🤖 Player2 — Agentic AI + Investigation Engine

- [ ] Implement follow-up question rewriting
- [ ] Implement scope detection
- [ ] Implement entity-resolution orchestration
- [ ] Implement ambiguity/clarification flow
- [ ] Implement query complexity detection
- [ ] Implement confidence calculation
- [ ] Implement deterministic intent router
- [ ] Implement router precedence/tie-breaking
- [ ] Implement simple vs complex routing:

  ```text
  SIMPLE + HIGH CONFIDENCE → Deterministic Router
  COMPLEX / LOW CONFIDENCE → LLM Planner
  ```

- [ ] Implement Pydantic `InvestigationPlan`
- [ ] Implement allowed planner operations
- [ ] Implement planner prompt
- [ ] Implement plan validation
- [ ] Implement plan versioning
- [ ] Implement plan limits:
  - [ ] max operations
  - [ ] max depth
  - [ ] max execution time
  - [ ] max evidence = 45
- [ ] Ensure LLM cannot generate arbitrary SQL
- [ ] Implement controlled plan executor
- [ ] Integrate SQL / Graph / Vector / Hybrid backends
- [ ] Implement LangGraph investigation workflow
- [ ] Implement evidence assembly
- [ ] Implement RAG context construction
- [ ] Implement LLM answer generation
- [ ] Implement claim + Source-ID generation
- [ ] Implement citation/source validation
- [ ] Implement numeric-result verification
- [ ] Ensure UI verbatims always come from DB
- [ ] Implement answer states:
  - [ ] answer
  - [ ] clarification
  - [ ] partial answer
  - [ ] refusal/out-of-scope
- [ ] Implement query cost/latency tracking
- [ ] Add LangGraph + planner + RAG tests
- [ ] Integrate investigation API with frontend

## 📊 Player3 — Detection + Evaluation + AI Quality

- [ ] Implement daily complaint aggregation
- [ ] Implement detection cells
- [ ] Implement 7-day smoothing
- [ ] Implement Poisson detection
- [ ] Implement low-volume policy
- [ ] Implement baseline calculation
- [ ] Implement hierarchical roll-ups
- [ ] Implement FDR / false-positive control
- [ ] Implement alert-frequency measurement
- [ ] Implement detection lead-time measurement
- [ ] Create planted ground-truth issues
- [ ] Create detection evaluation dataset
- [ ] Create 120 router golden queries
- [ ] Create complex/planner golden queries
- [ ] Create citation evaluation queries
- [ ] Create numeric correctness queries
- [ ] Create retrieval evaluation queries
- [ ] Create adversarial/security queries
- [ ] Implement detection metrics:
  - [ ] Recall
  - [ ] Precision
  - [ ] False Positive Rate
  - [ ] Alert Frequency
  - [ ] Lead Time
- [ ] Implement router evaluation
- [ ] Implement planner evaluation:
  - [ ] Valid Plan Rate
  - [ ] Operation Validity
  - [ ] Parameter Completeness
  - [ ] Execution Success
  - [ ] Unsupported Operation Rejection
- [ ] Implement citation evaluation
- [ ] Implement numeric correctness evaluation
- [ ] Implement retrieval evaluation
- [ ] Compare Vector-only vs Hybrid retrieval
- [ ] Implement cost + latency evaluation
- [ ] Implement CI evaluation gates
- [ ] Generate evaluation report automatically
- [ ] Add evaluation dashboard/metrics UI where required
- [ ] Support final demo evidence

## 🎨 Player4 — Frontend + Evidence + Integration

- [ ] Build Insight Feed
- [ ] Build Insight Drilldown
- [ ] Display issue/product/region/timeline information
- [ ] Display detection evidence
- [ ] Display graph relationships
- [ ] Implement Top-5 evidence display
- [ ] Implement "View All" evidence
- [ ] Enforce `top_k <= 45`
- [ ] Implement citation/source display
- [ ] Ensure verbatim text is rendered from DB
- [ ] Implement Confirm feedback
- [ ] Implement Dismiss feedback
- [ ] Implement False Positive feedback
- [ ] Implement Investigate feedback
- [ ] Integrate `insight_feedback`
- [ ] Build investigation/chat UI
- [ ] Support follow-up questions
- [ ] Support clarification UI
- [ ] Support ambiguous entity selection
- [ ] Display partial/refusal responses correctly
- [ ] Display routing proof where appropriate:
  - [ ] Intent
  - [ ] Route
  - [ ] Confidence
  - [ ] Planner used/not used
- [ ] Integrate Evidence API
- [ ] Integrate Investigation API
- [ ] Add frontend/backend contract tests
- [ ] Add RAG/Evidence E2E tests
- [ ] Add GraphRAG multi-hop demo flow
- [ ] Integrate `/healthz`
- [ ] Integrate `/readyz`
- [ ] Support Docker demo verification
- [ ] Support rollback demonstration
- [ ] Validate final runbook

---

## 🔗 Shared Team TODO

- [ ] Freeze DB/API contracts before parallel development
- [ ] Agree on branch/PR strategy
- [ ] Agree on environment/config structure
- [ ] Maintain shared synthetic/golden dataset
- [ ] Add unit + integration + E2E tests
- [ ] Add security tests
- [ ] Add prompt-injection tests
- [ ] Add PII-redaction tests
- [ ] Ensure no LLM-generated raw SQL
- [ ] Ensure DB credentials follow least privilege
- [ ] Add secrets scanning
- [ ] Add dependency/security scanning
- [ ] Setup Docker Compose
- [ ] Implement `/healthz`
- [ ] Implement `/readyz`
- [ ] Demonstrate v1 → v2 rollback
- [ ] Complete operational runbook
- [ ] Run complete evaluation
- [ ] Fix failed evaluation gates
- [ ] Capture final metrics
- [ ] Prepare architecture/demo evidence
- [ ] Prepare panel defense around PostgreSQL-based GraphRAG
- [ ] Record limitations honestly
- [ ] Final end-to-end demo

### 🚫 Defer unless core system is stable

- [ ] Cross-encoder reranker
- [ ] MMR
- [ ] Embedding model bake-off
- [ ] BERTopic
- [ ] Negative Binomial if Poisson is sufficient
- [ ] NLI if it delays core citation validation
- [ ] MCP
- [ ] Neo4j
- [ ] Cloud deployment
- [ ] Kubernetes
- [ ] Semantic-count engine
- [ ] Large-scale/load testing beyond required scope

---

## Simple Ownership

| Owner | Ownership |
|---|---|
| **Player1** | Data + GraphRAG + Retrieval (PostgreSQL, pgvector, FTS, graph, hybrid retrieval) |
| **Player2** | Agentic AI + Investigation Engine (router, planner, executor, generation, verification) |
| **Player3** | Detection + Evaluation + AI Quality (statistics, golden sets, metrics, CI gates) |
| **Player4** | Frontend + Evidence + Integration (insight feed, investigation UI, evidence display) |

## Dependency Chain

```
Player1 → Data/Retrieval foundation
      ↓
Player2 → AI/Agentic investigation layer
      ↓
Player3 + Player4 → Evaluation + Frontend + Evidence + Integration
      ↓
   ALL 4 → Shared Team TODO (contracts, security, Docker, rollback, runbook)
      ↓
Final Testing + Demo
```
