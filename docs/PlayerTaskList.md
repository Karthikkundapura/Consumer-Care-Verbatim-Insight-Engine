# CCVIE — Player Task List

## 👤 P1 — Backend + Data Foundation

- [ ] PostgreSQL database setup
- [ ] Database migrations
- [ ] Required DB indexes
- [ ] pgvector + HNSW setup
- [ ] Complaint ingestion
- [ ] Taxonomy setup
- [ ] Generate/store embeddings
- [ ] `verbatims` + `verbatim_embeddings`
- [ ] `graph_nodes` + `graph_edges`
- [ ] SQL queries
- [ ] Graph queries
- [ ] Vector queries
- [ ] Pydantic data contracts
- [ ] FastAPI backend support
- [ ] Low-volume Poisson policy
- [ ] `insight_feedback` database schema
- [ ] Support P2 with DB/backend integration

## 👤 P2 — AI + Agentic Orchestration

- [ ] Complexity Detector
- [ ] Deterministic Query Router
- [ ] Router tie-breaking rules
- [ ] Query Planner
- [ ] `InvestigationPlan` Pydantic model
- [ ] Plan validation
- [ ] Plan Executor
- [ ] LangGraph workflow
- [ ] RAG orchestration
- [ ] Graph/Vector retrieval integration
- [ ] LLM generation
- [ ] Citation Validator
- [ ] Source-ID validation
- [ ] DB-backed verbatim rendering
- [ ] `/query` API integration
- [ ] Planner limits: 8 operations / depth 5 / 15 sec / max 45 evidence
- [ ] Guide P3/P4 on AI-related work

## 👤 P3 — Frontend + AI Evaluation

**Frontend**

- [ ] Evaluation Dashboard
- [ ] Display detection metrics
- [ ] Display routing metrics
- [ ] Display citation metrics
- [ ] Display latency/cost
- [ ] API integration

**AI / Backend**

- [ ] Router evaluation
- [ ] Planner evaluation
- [ ] Citation evaluation
- [ ] Detection evaluation
- [ ] `/eval/run` API
- [ ] `/eval/metrics` API
- [ ] Router golden-set queries
- [ ] Complex planner test queries
- [ ] Tie-break test cases
- [ ] Evaluation threshold checks
- [ ] Support CI evaluation gate

**Support**

- [ ] Help prepare rollback demo
- [ ] Help maintain agent review log
- [ ] Coordinate with P2 for expected AI behavior

## 👤 P4 — Frontend + Evidence / Integration

**Frontend**

- [ ] Insight Feed
- [ ] Insight Drill-down
- [ ] Top 5 evidence
- [ ] View all evidence
- [ ] Feedback buttons
- [ ] Routing Proof
- [ ] Health status
- [ ] Loading/error states

**Backend / AI**

- [ ] `get_evidence(top_k ≤ 45)`
- [ ] Evidence pool logic
- [ ] Evidence API integration
- [ ] Feedback API integration
- [ ] `insight_feedback` workflow
- [ ] RAG test cases
- [ ] Evidence tests
- [ ] Citation integration tests
- [ ] E2E tests

**GraphRAG / Demo**

- [ ] Support multi-hop GraphRAG demo
- [ ] Complaint → Pack → Other Products → Region
- [ ] Verify evidence displayed correctly
- [ ] Help prepare final demo

---

## Simple Ownership

| Player | Ownership |
|---|---|
| **P1** | Data + Database + Backend |
| **P2** | AI + Agents + RAG + Query Orchestration |
| **P3** | Frontend + Evaluation + AI Testing |
| **P4** | Frontend + Evidence + Integration + RAG Testing |

## Dependency Chain

```
P1 → Data/Backend foundation
      ↓
P2 → AI/Agentic layer
      ↓
P3 + P4 → Frontend + Evaluation + Evidence + Integration
      ↓
   ALL 4
      ↓
Final Testing + Demo
```
