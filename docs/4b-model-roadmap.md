# Dedicated 4B filter model for unrager

Goal: a dense ~4B model that gets close to the live filter (Gemma 4 26B-A4B, Q4_K_M GGUF on llama-swap) at about a quarter of the size: AUC near 0.97 and rage caught near 88% at no more than 7% good posts wrongly hidden. Built first for the owner's own daily use, then published to Hugging Face and Pirate Face.

Eval set, frozen and never trained on: `~/.local/share/unrager/eval/feed-2026-09-27.jsonl` (1,049 hand-labelled posts: 845 keep, 132 hide, 72 either). Scoring harness, already built: `~/.local/share/unrager/eval/bench-2026-09-27/` (`mbench.py` runs a GGUF exactly as unrager asks, `stats.py` gives Wilson intervals, McNemar against a baseline, AUC and rage caught at a fixed share of good posts hidden).

Settled:

- Candidates: Qwen3.5-4B and Gemma 4 E4B. Both are Apache 2.0 and ungated (checked on their Hugging Face pages 2026-10-04). Qwen3.8 has no 4B (only 27B, Flash-Next and 2.4T).
- No throwaway account: collection is passive, from the posts the daemon already fetches for the owner.
- Teacher: Gemma 4 26B-A4B, local and Apache 2.0, so no terms question about training on its outputs. Claude is not used.
- Serving: GGUF through llama-swap, replacing the `gemma4-26b-a4b-gguf` entry.

## 1. Baseline and bake-off (done 2026-09-27, 19 models)

Live filter (Gemma 26B-A4B with `--swa-full`): 6.9% good posts wrongly hidden [5.3, 8.8], 88% rage caught [81, 92], AUC 0.969, 83% caught at 5% good posts hidden. This is the bar.

Best zero-shot small models (Q4_K_M):

| model | wrongly hidden | caught | AUC | caught@5% |
|---|---|---|---|---|
| Nanbeige4.2-3B | 6.4% | 77% | 0.942 | 72% |
| Gemma 4 E4B | 1.5% | 46% | 0.926 | 68% |
| Qwen3.5-4B | 9.0% | 76% | 0.922 | 67% |
| Qwen3-4B-2507 (previous 4B) | 5.0% | 64% | 0.904 | 64% |

Candidates for fine-tuning: Gemma 4 E4B and Qwen3.5-4B. Both load natively in transformers (`gemma4`, `qwen3_5`), are Apache 2.0, and sit within 0.02 AUC of the best small model. Nanbeige4.2-3B (Apache 2.0, a base model exists) scores best zero-shot but needs `trust_remote_code`, so it is the third candidate only if both fail.

## 2. Collect (running)

- No extra requests to X. The serve daemon already polls Home and classifies every post with the live filter, then trims its buffer to 500 rows per feed. `~/.local/bin/unrager-archive-feed` copies new buffered posts, with the live verdict and matched rule, into `~/.local/share/unrager/corpus/archive.db`, run every 15 minutes by `unrager-archive-feed.timer`.
- Tested 2026-10-04: first run archived 983 posts (hide 156, keep 827), second run added 0, the timer fired on schedule. 40,785 older verdicts exist in `filter.db` but without text, so they cannot be used.
- Target 10k posts, expected in roughly a week of normal use. `unrager search` on rage-prone topics is the fallback if the hide class stays thin, kept to 100 to 150 pages a day with the same stop-on-429 rule.
- Before training: drop empty-text posts and posts whose text is in the eval set (30 of the first 983 are), then near-dedup the rest against it.

## 3. Labels

- Labels come from the live filter (Gemma 26B, current rubric), stored per post with its rubric hash. Hide rule numbers come from matching the stored reason text to the 21-rule balanced prompt in `bench-2026-09-27/prompts.json` (rules 1 to 16 are `drop_topics`, 17 to 21 are built in; one built-in reason, "engagement farming", does not match its rule text verbatim and needs an explicit mapping).
- The student inherits the teacher's mistakes: the 26B wrongly hides 40 good posts under rule 10 (AI-company dunking). Check teacher hides against rule 10 and rule 14 by hand before training, and use the hand labels to correct them.
- Use only rows whose rubric hash matches the rubric at training time. A rubric change means relabeling the stored text with the teacher, which is cheap.
- The teacher's agreement with the hand labels is the Phase 1 baseline run. If agreement on hides is low, fix the rubric prompt before training. Drop or hand-check posts where two teacher passes disagree.

## 4. Train (pipeline built and verified end to end)

- Repo `~/Dev/python-unrager-4b`: `scripts/refresh_data.sh SUFFIX` (archive, label with Nanbeige, build teacher and consensus datasets), `scripts/experiment.sh NAME BASE DATA [train flags]` (LoRA SFT, merge, GGUF Q8_0, mbench, stats). LoRA r=32 on all linear layers, lr 1e-4, 2 epochs, answer-only loss, answer format exactly `KEEP` or `HIDE n` (no rationale text: unrager reads the first tokens, so reasons would only add inference cost).
- Label strategy is an experimental axis: teacher-only labels against consensus labels (hide only if the live 26B and Nanbeige4.2-3B agree, keep only if both keep, drop disagreements). On the gold set consensus hides are 85% precise against 67% for the 26B alone.
- `--hide-upsample N` shifts the HIDE/KEEP threshold. Qwen3.5 GGUF conversion needs `--no-mtp` (handled in export.py); Gemma 4 rejects that flag.

Results so far, 903 to 1,300 training posts (eval: 1,049 hand-labelled posts):

| run | wrongly hidden | caught | AUC | caught@5% |
|---|---|---|---|---|
| live Gemma 26B (bar) | 6.9% | 88% | 0.969 | 83% |
| Gemma E4B zero-shot | 1.5% | 46% | 0.926 | 68% |
| Qwen3.5-4B zero-shot | 9.0% | 76% | 0.922 | 67% |
| Gemma E4B, teacher labels, 903 posts | 5.7% | 70% | 0.940 | 66% |
| Qwen3.5-4B, teacher labels, 903 posts | 6.4% | 77% | 0.940 | 74% |
| Gemma E4B, teacher labels, 976 posts | 7.8% | 80% | 0.941 | 71% |
| Gemma E4B, consensus, 854 posts | 1.4% | 53% | 0.946 | 77% |
| Gemma E4B, consensus, 1,294 posts | 7.2% | 78% | 0.948 | 71% |
| Gemma E4B, consensus, hides x2 | 4.0% | 70% | 0.942 | 74% |
| Qwen3.5-4B, consensus | 11.8% | 86% | 0.942 | 73% |
| Qwen3.5-4B, consensus, hides x2 | 8.3% | 87% | 0.954 | 73% |

Reading: every tuned 4B reaches AUC 0.94 to 0.95, up from 0.92, still short of 0.969. With about 120 hide examples the HIDE/KEEP threshold moves a lot between runs, so compare on AUC and caught@5% and set the operating point last. More data is the main lever: rerun at each corpus milestone (3k, 5k, 7.5k, 10k posts).

Later rounds (rank 8, 2 epochs, labels as marked; 3 seeds measured AUC noise of about 0.003, operating point noise of several points):

| run | wrongly hidden | caught | AUC | caught@5% |
|---|---|---|---|---|
| Gemma E4B, consensus, 2.6k posts, 3 seeds | 5.0 to 6.2% | 79 to 81% | 0.957 to 0.959 | 78 to 79% |
| Qwen3.5-4B, consensus, 2.6k posts, 2 seeds | 2.2 to 7.1% | 66 to 86% | 0.956 to 0.961 | 82 to 84% |
| Qwen3.5-4B, teacher labels, 4.4k posts | 7.9% | 87% | 0.958 | 76% |
| Qwen3.5-4B, consensus, 4.4k posts | 4.3% | 83% | 0.961 | 88% |
| Qwen3.5-4B, three-way unanimous, 4.4k posts | 2.7% | 73% | 0.962 | 86% |
| Qwen3.5-4B, consensus, 5.4k posts, 2 seeds | 4.1 to 5.6% | 83 to 86% | 0.960 to 0.961 | 85 to 86% |
| Qwen3.5-4B, unanimous, 5.4k posts, 2 seeds | 1.9 to 2.6% | 69 to 73% | 0.956 to 0.957 | 82 to 83% |

Decisions: Qwen3.5-4B is the model (Gemma E4B ranks about 0.004 AUC lower and has a larger GGUF, but runs 2.5 times faster); labels are the live filter plus Nanbeige4.2-3B consensus (best ranking; unanimous with gpt-oss-safeguard-20b is more conservative but ranks slightly worse); rank 8.

Shipping path validated on the 5.4k-post adapter: bf16, Q8_0 and Q4_K_M score the same within noise (Q4_K_M 2.7 GB, AUC 0.959 against 0.961), and `unrager eval --model` through llama-swap reproduces the mbench numbers (AUC 0.961, 86% caught at 5%, 8 answers a second). A candidate entry `unrager-4b-gguf` exists in llama-swap (not yet the `filter_model`).

Final run (2026-10-05): Qwen3.5-4B, rank 8, consensus labels, 7,007 posts from an 8.6k-post corpus (data scaling had flattened, so the 10k target was dropped). Q8_0: 3.7% wrongly hidden, 80% caught, AUC 0.957, 85% caught at 5%; Q4_K_M 3.3%, 74%, 0.957, 84%.

## 5. Evaluate

- Run each tuned model through `mbench.py` and `stats.py` on the eval set, with the Gemma 26B run as the baseline, overall and sliced by feed, language and replies.
- A model wins if its AUC and caught@5% are within noise of the 26B (about 0.97 and 83%) with wrongly hidden no worse than 7%. If neither wins, the best result and the gap to the 26B are still the finding.

## 6. Ship (done 2026-10-05)

- Live: llama-swap entry `unrager-4b-gguf` (Q8_0, `ttl: 0`), `filter_model` set to it, the 26B entry kept for rollback.
- Published: https://huggingface.co/guitaripod/unrager-4b (bf16, Q8_0, Q4_K_M, system prompt, model card, Apache 2.0) and https://pirateface.co/guitaripod/unrager-4b, seeded from `pirateface-seeder.service` (qBittorrent on 127.0.0.1:8091, files in `/mnt/nvme8tb/pirateface-seeds/unrager-4b`).
- Linked from the unrager README and the midgarcorp landing page.
- Not done: NVFP4 and MLX builds; making it the shipped default for all users (needs a retrain on the default rubric, because the model learned a 21-rule prompt whose rule 16 is Finnish politics).
