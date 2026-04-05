# ADR-003: Corpus-preferring grounding over strict grounding

## Status

Accepted (2026-04-02)

## Context

RAG systems face a grounding policy choice:

1. **Strict grounding** — only answer from retrieved documents. Refuse or say "I don't know" for anything not in the corpus.
2. **Ungrounded** — use documents as supplementary context but freely mix with general knowledge, without distinguishing which is which.
3. **Corpus-preferring** — use documents as the primary source, but fall back to general knowledge when the corpus is silent, with explicit transparency about which mode produced the answer.

Strict grounding is safe but frustrating — users expect a knowledgeable assistant, and a corpus will never cover every possible question. Ungrounded is useful but dangerous — there's no way to tell if an answer came from a verified document or the model's training data.

## Decision

Implement corpus-preferring grounding with transparent fallback:

- The model uses retrieved documents as its primary source and **cites every claim** with `[doc_id:chunk_id]`
- When the corpus is silent, the model answers from general knowledge but **prefixes** with `⚠️ Not in corpus:`
- Mixed responses cite the corpus-sourced portion and prefix the general knowledge portion
- Response metadata classifies the grounding mode (`corpus`, `general`, `mixed`) by **parsing the response**, not by asking the LLM

Citations are validated after the response:
- Each cited `[doc_id:chunk_id]` must exist in the docstore and must have been in the retrieved set
- Invalid citations are stripped (not the whole response)
- Validation results are logged for monitoring

Empty retrieval is not an error — it's a signal for corpus gap analysis.

## Consequences

**Positive:**
- Users get helpful answers for any question
- Corpus-sourced claims are verifiable via citations
- General knowledge is clearly marked, so callers can assess confidence
- Empty retrievals surface corpus gaps instead of being silent failures
- Audit log enables monitoring of grounding quality without exposing content

**Negative:**
- The model may not always follow the ⚠️ prefix instruction perfectly — LLMs are probabilistic
- Citation validation adds post-processing latency (~1ms, negligible)
- Streaming responses can't be post-processed for citation validation
- The system prompt is longer, consuming ~200 tokens of the context window

**Alternatives considered:**
- **Strict grounding:** Rejected — too restrictive for a general-purpose assistant
- **Ungrounded RAG:** Rejected — no transparency about source, can't verify claims
- **LLM-generated metadata:** Rejected — unreliable, adds latency, can be hallucinated. Parsing is deterministic.
