# Personal Knowledge Graph

Typed facts about the candidate that Quick Assist can cite: people, companies,
projects, skills, stories, problems, topics, roles, documents, and the
relations among them.

## How it differs from hub memory

Hub memory (`memory_nodes`) stores conversation chunks keyed to sessions. The
knowledge graph stores entities. A question about "the ledger migration"
should surface the project, the people on it, the skills it used, and the
story that came out of it, not the transcript lines where it was mentioned.

## Data model

| Table | Purpose |
| --- | --- |
| `kg_nodes` | kind, label, normalized label (dedupe key), summary, string properties, source, workspace, confidence, mention count |
| `kg_edges` | from, to, relation, weight, evidence; unique per (from, to, relation), weight grows on repeat |
| `kg_nodes_fts` | FTS5 mirror (label, summary, properties) created best effort; LIKE fallback otherwise |

Migration v16 creates the tables. Data access lives in
`SessionDatabase+KnowledgeNodes`, `+KnowledgeEdges`, `+KnowledgeSearch`.

## Retrieval

1. `KnowledgeQueryTokenizer` normalizes the question and drops stop words.
2. `searchKnowledgeNodes` finds lexical seeds (bm25 or LIKE). Tokens the
   FTS tokenizer cannot carry (`c#`, `c++`) are answered by the LIKE scan
   and merged with the FTS hits, so a symbol skill is never read as the
   prefix `c`.
3. `KnowledgeGraphScorer.expand` walks up to two hops with geometric decay
   times the relation's traversal weight. Seeds are never inflated by their
   own neighbors; a node reached by two paths gains corroboration.
4. `KnowledgeGraphScorer.adjust` folds in source trust, confidence, workspace
   affinity, recency, and mention count.
5. `KnowledgeContextComposer` renders the top facts and the induced relations
   as the `PERSONAL KNOWLEDGE GRAPH` block within a character budget.

`KnowledgeRetriever` orchestrates the above against the database.

## Ingestion

- Manual: add or edit facts, link them, on the Knowledge screen in the
  overlay (graph icon in the header).
- Extract from text: paste a resume section or write up; one model call
  through the existing `SessionSummaryLLMCalling` client returns strict JSON
  in the app's kind and relation vocabulary. `KnowledgeExtractionParser`
  tolerates fences and drops anything off vocabulary; `KnowledgeGraphMerger`
  dedupes by normalized label and grows mention counts.
- Learn from turns: when `knowledgeAutoExtractEnabled` is on,
  `KnowledgeQuickAssistBridge.ingestTurn` runs extraction after a Quick
  Assist turn, spaced at least 20 seconds apart, detached from the UI.

## Where it shows up

- Knowledge screen in the overlay: search, kind filter, node list, detail
  with a force directed neighborhood map (`KnowledgeGraphLayout`,
  deterministic), relation list, link composer, extract sheet.
- Quick Assist top chrome: the graph pill toggles retrieval and learning and
  shows counts.
- Prompt: the block joins the extra context channel in
  `SessionController.quickAssist` next to the workspace brief.

## Settings

`knowledgeContextEnabled` (default on), `knowledgeAutoExtractEnabled`
(default off because it costs a model call per turn).

## Tests

`memanagerTests/Knowledge/` covers storage and search, scorer semantics and
layout determinism, the extraction parser, the merger, and retrieval plus
composition end to end against a temp database.
