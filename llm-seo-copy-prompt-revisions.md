# 27 Prompt Revisions Later: What the Prompt Fixed, What Code Fixed, and the Script for the English That Still Leaked Into Japanese

This is a retrospective on a batch content-generation pipeline: about four weeks of prompt changes, what each one bought, and what happened when the prompt ran out of reach.

The pipeline writes SEO copy for travel pages, in 11 locales, from tables of booking figures. It runs on `gpt-5-mini` through the OpenAI Batch API with strict JSON schemas. There are 16 prompt templates (4 page types, each with several content types), and the model is told never to recompute a number, only to copy and phrase it.

The headline result is a little humbling. The defects that stayed fixed were mostly the ones where I took the decision away from the model (code supplies the value, or the output structure forces it), not the ones where I reworded the prompt. And after all of that, a pilot of 61,523 generated rows still came back with about 3.8% of the rows containing stray English words in non-English text, which I repaired with a scanner and a table of replacement rules, not with another prompt edit.

I reconstructed all of this from three sources, which turned out to be complementary:

- The assistant session transcripts, which record why I changed something.
- `git log` on the prompt files, which records exactly what changed.
- The batch result files, which record whether it worked, down to token counts.

Where an effect was measured I give the number. Where it was not, I say so.

## Prologue: the setup, and the cost model that framed everything

Before any prompt was tuned, a cost proposal sized the job: roughly 100K pages times 4 calls, about 400K requests. Its diagnosis of the first sample file (1,972 requests) was blunt: the average request carried about 1,182 input tokens, 87% of which was static template text repeated verbatim in every request.

That produced three structural decisions, all made before the revisions below, and all of which the later revisions depend on:

1. Static prefix first, variable tail last. Prompt caching matches on exact bytes from the start of the request, so anything that varies per request (city name, locale, the data tables) sits at the end. The 16 templates share one `common-prefix.ts` that is byte-identical across all of them, so the cache stays warm even when a batch mixes page types, and the prefix alone clears OpenAI's 1,024-token minimum. That file carries a hard rule in its header comment: no `{{placeholder}}` inside it, because one substituted value would break the prefix for every template at once.
2. `reasoning_effort: minimal`. Reasoning tokens are hidden but billed at the output rate, which is 8 times the input rate on this model. Templated copy off a table of figures does not need deep reasoning.
3. `max_completion_tokens: 2500` instead of 8192, to bound the case where a reasoning model loops until it hits the cap.

What did these decisions actually yield? I computed it from the result files, using the proposal's price assumptions (Batch pricing of $0.125 per million input tokens, $1.00 per million output tokens, cached input at 10% of the input price; verify against the current price list before relying on these).

| Run | Rows | Avg prompt tokens | Cache hit rate | Avg output tokens | Reasoning tokens | Estimated cost |
|---|---:|---:|---:|---:|---:|---:|
| Earlier full run (shorter prompts) | 58,929 | 2,801 | 77.3% | 270 | 0 | about $22 |
| Pilot parts 1 to 7 (rich content and captions) | 61,523 | 4,455 | 73.8% | 399 | 0 | about $36 |
| One 88-row pilot batch | 88 | 4,814 | 53.5% | 532 | 0 | about $0.07 |

Three things in that table are worth sitting with.

The cache hit rate depends on batch size. The proposal assumed 80% as a conservative figure. Large batches landed at 74% to 77%, but the small 88-row pilots only reached 53% to 58%. I did not isolate the cause; my guess is that few rows share a warm prefix when a batch is that small. The practical consequence is that you cannot judge caching from your pilots.

Output is the cost center, not input. In the pilot, output was about 68% of the spend even though each request sends 11 times more tokens than it receives. Caching still saved about 39% overall, but the lever that mattered most was keeping output small and reasoning at zero.

An iteration is cheap in dollars and expensive in time. The 88-row pilot costs about seven cents. What it costs is a manual round trip: export, submit to the batch provider, wait up to 24 hours, download, inspect. This reframes the whole effort. The scarce resource was never money, it was the number of round trips, and that shaped most of the decisions below.

## Part 1: Seven problems the prompt could not fix, and the code that did

The common thread of this section is a rule of thumb I wish I had applied on day one: if the correct answer can be computed, do not ask the model to produce it.

### 1.1 A Chinese sentence copied into a Japanese page

Every page ends with a data attribution sentence, and two things decide it: the page's language and the card's data window (start and end month). In English it reads "Based on Company booking data, July 2025 to June 2026."; in Japanese it is the same sentence in Japanese, with the months written as 2025年7月 and 2026年6月.

Symptom. A `zh_HK` page ended with the English sentence "Based on Company booking data, July 2025 to June 2026." A different page, in Japanese, ended with a Simplified Chinese attribution sentence. The other locales in the same batch were correct.

The old setup let the model write the sentence. The template held one worked example per locale, plus translation rules, correct and incorrect examples, and a "read the last sentence back" self-check, about 2,260 characters in all. Roughly like this (a reconstruction of the idea, not the literal text):

```
End the page with one data attribution sentence. It must be in the page's
language, and the dates are this card's data window.
Examples:
- en:    Based on Company booking data, July 2025 to June 2026.
- zh_CN: 基于 Company 预订数据，2025年7月至2026年6月。
- ja:    ……
```

First instinct was to strengthen the prompt, but the hard requirement, the examples and the self-check were already there, and the other locales were fine, so the failure was probabilistic, not a missing rule.

The Japanese case gave away the mechanism. The data window on that card happened to be exactly `2025-07` to `2026-06`, the same dates as in the `zh_CN` example. The model had to write "source + July 2025 to June 2026", and the context already held a finished sentence with exactly those dates. It did not rewrite it in Japanese, it copied the Chinese line wholesale, punctuation included. The English sentence on the `zh_HK` page has the same cause.

The best evidence is a second card in the same response. Its dates did not match any example, and the model wrote correct Japanese for it. Same model, same prompt, and the outcome depended only on whether the example dates happened to coincide. When the model sees a string that already looks like the answer, it copies it. Strengthening the prompt only lowers the odds.

One more point: what was wrong was the language of the whole sentence. The dates were right. They were only the trigger. So the fix could not be limited to the date part; the whole sentence had to leave the model's hands.

Fix (prompt v5 to v6). The sentence is entirely mechanical: a locale and two months. The model does not need to write it, so code does, in two parts.

The first half comes from a table in the code: one hand-translated, reviewed sentence per locale, with a `{range}` placeholder where the months go. Only the brand name stays in English:

```ts
en:    'Based on Company booking data, {range}.',
zh_HK: '根據 Company 預訂數據，{range}。',
// ... other locales
```

The months come from `Intl.DateTimeFormat`, instead of a hand-written month table for 48 locales:

```js
const fmt = new Intl.DateTimeFormat('ja-JP-u-ca-gregory-nu-latn',
  { year: 'numeric', month: 'long' });
fmt.format(new Date(2025, 6));   // "2025年7月"
```

The code picks the template for the page's locale, fills `{range}` with the two formatted months, and puts the finished sentence in the context block:

```
attribution: Company の予約データに基づく、2025年7月 – 2026年6月。
```

The template now has one requirement left: end the page with the `attribution` line, verbatim. If a locale has no template in the table, the code throws instead of generating with a gap.

The `-u-ca-gregory-nu-latn` suffix on the locale is a Unicode extension that pins two things: `ca-gregory` fixes the calendar to Gregorian, and `nu-latn` fixes the digits to 0 to 9. Without it each locale uses its own default: `th_TH` uses the Buddhist calendar and prints 2568 for 2025, and `ar_SA` uses the Islamic calendar with Arabic-Indic digits. Every other figure in the copy is a Gregorian year in Latin digits, and the attribution has to agree with them, so the pin is not decoration.

Benefit. The model now holds one sentence that is already in the right language, so even if all it does is copy, it copies the right thing. The leak path no longer exists by construction. On tokens, the change removed about 2,260 characters of translation instructions and added about three short lines, a net of roughly minus 13% per request (about 3,384 down to about 2,930 tokens on the measured sample).

The bill drops by less than the token count does, which I almost got wrong. The removed block sat inside the cached prefix and was billed at 10%, while the new `attribution` line differs on every request, sits in the variable tail and is billed at 100%. The saving grows as the cache hit rate falls.

What generalises: models copy worked examples. If an example contains a finished sentence and the real data can coincide with it, the model will return it as the answer. There are two ways out: use abstract placeholders in examples (for instance "{start month} to {end month}"), or do what I did here and take the mechanical sentence out of the model's hands.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| A `zh_HK` page ended with the English sentence "Based on Company booking data, July 2025 to June 2026."; a Japanese page ended with a Simplified Chinese attribution sentence (the model copied wholesale the example whose dates happened to be identical) | The model only copies one finished `attribution:` line, so every locale gets a sentence in its own language; the leak path is closed by construction, and a request is about 13% fewer tokens | Code holds one hand-translated template per locale with a `{range}` placeholder; the months come from `Intl.DateTimeFormat` (pinned to `-u-ca-gregory-nu-latn`); the filled sentence goes into the context and about 2,260 characters of translation instructions were removed from the template |

### 1.2 English category names inside a Japanese page

Symptom. Pages show category names such as "Observation decks", "Events & shows" and "Tours". In the `ja_JP`, `ko_KR` and `zh_HK` pages those names came out in English.

Cause. The data card stored the category name in English, and the template (five sub-templates, so five copies) told the model to translate it: "sub_category_name arrives in English, write it in target_language".

A category name is a proper label. It has to match what the rest of the site calls it, and it cannot be improvised each time. Asked to translate, the model gave three different results for the same word: Korean copied "Tours" unchanged, Cantonese invented "Tour 類活動" (a category name the site does not have), and Japanese happened to get it right.

So the problem was not how well the model translates. It was that translating should never have been its job: it does not know what the site officially calls the category.

Fix. The site's front end already has a category tree that holds the official name of every category in every language. Roughly like this (illustrative):

```
category id = 123
  en:    Tours
  ja:    ツアー
  ko:    투어
  zh_HK: 觀光團
```

Three changes:

- The data card now stores the category id instead of the English name.
- When the prompt is rendered, before the model sees anything, code looks the id up in the tree and fills in the official name for that locale. The model already sees the correct Japanese or Korean name.
- The template changed from "translate it" to "copy it verbatim: do not translate, do not rephrase, do not add a category word, do not add the English in brackets".

A page whose name cannot be resolved is not rendered at all (`renderable: false`). Nobody files a bug for one English noun inside a Japanese page, so the defect would sit live indefinitely. I would rather the page not exist.

Once the main path worked, a few edge problems remained:

- The official tree has gaps in 36 locales, and one node (the Japan bus pass category) is missing even in the main markets. I added a supplement layer: the missing names are translated by an LLM ahead of time and stored, and a lookup checks the official name first, then the supplement. An LLM is involved here, but as a one-off, archived, reviewable translation, not a translation done on the fly while generating a page.
- My first guard rule for the supplement layer was too strict: if a single name equalled its English original, the whole locale was declared untranslated and thrown away. In Arabic, eSIM is simply written "eSIM", so 134 well-translated names were dropped because of one word. The guard now works on a ratio: a single identical name is kept and listed for a human to look at, and only a high share (over 20%, with at least 5 samples) counts as the model not having translated.
- English variants such as `en-AE` need no translation. The fallback chain goes to `en` when `en-AE` has no name.
- Translation runs at temperature 0, so rerunning gives identical output, and "rerun it to check consistency" verifies nothing. That was my own suggestion, and I had to withdraw it.
- The language pack was first generated during the image build, and later became a JSON file committed to the repo, one key per line, for example `"123": "ツアー"`. Category names change a few times a year, and a network call on every build buys freshness nobody needs and adds one more way for the build to fail. One key per line is for review: the diff shows which name changed, and that is the only question a reviewer has.

For pages already generated with English names, a backfill script replaces the names in place. When a case is ambiguous, for instance one English name that maps to two category ids, the script refuses and counts it instead of guessing.

Takeaway. When a name has an official answer, do not have the model translate it. Store the id, let code look up the official name, and let the model copy it. If the name cannot be found, do not generate. Do supplementary translation ahead of time, archive it and make it reviewable. Judge guard rules by ratio so they do not kill good translations.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| `ja_JP`, `ko_KR` and `zh_HK` pages showed "Observation decks", "Events & shows" and "Tours"; asked to translate, the model gave three results: Korean copied "Tours", Cantonese invented "Tour 類活動", Japanese happened to be right | The model sees the official category name for that locale and only copies it verbatim; a page whose name cannot be resolved is not rendered (`renderable: false`) | The data card stores the category id, and when the prompt is rendered the name is looked up by id in the front-end category tree, with a supplement layer translated by an LLM ahead of time for the gaps; the template changed from "translate it" to "copy it verbatim"; pages already generated are fixed in place by a backfill script |

### 1.3 "Demand vs a typical month" showed numbers where words were wanted

Symptom. The product has a month table, and one column is "Demand vs a typical month". It used to show percentages:

```
Month    Demand
Jul      +59%
Feb      -57%
```

Product then asked for something new: this column should show a word-level tier instead of a number, such as "peak", "busier than usual", "average", "quieter than usual" and "very quiet".

The first time, I changed only the prompt and told the model to turn the percentage into words. Every row was rejected. Before the model's content is written to the database there is an ingest check, and its rule was that this column must be a signed percentage that matches the source data. Once the model wrote words, no row satisfied it. The prompt and the check are two halves of one rule, and changing one half guarantees a clash.

The second time, I let the model look at the percentage and decide the tier itself, for instance whether +59% counts as "peak" or "busier". That was the wrong direction too. The same number could land in different tiers on different pages and in different languages, so the result was unstable and could not be guaranteed.

The fix has three steps.

First, code decides the tier. A function `demandLevel(delta_pct)` takes the percentage and returns one of five tiers by fixed thresholds:

| Tier | Meaning |
|---|---|
| `peak` | peak season |
| `busier` | busier than usual |
| `average` | average |
| `quieter` | quieter than usual |
| `very quiet` | very quiet |

+59% going in always returns `peak`, and -57% always returns `very quiet`. The same number always gets the same tier.

Second, the model only does the wording. It receives the tier, for example `peak`, and its job is just to write it naturally in the target language, say "旺季" in Chinese or "ピーク" in Japanese. Code makes the judgement, the model does the expression. (That wording was later taken away from the model too, see 1.4: the five phrases for each language are supplied by code and the model copies them verbatim.)

Third, the prompt and the ingest check change together. The check went from "must be a signed percentage" to "must correspond to one of the five tiers", in step with the new prompt.

Takeaway. A judgement that a rule can compute, such as which range a number falls in, belongs to code. The model should do the part it is good at, saying the result in natural language. And when you change an output format, change the downstream check with the prompt.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| The demand column printed "+59%" and "-57%" when the product wanted word tiers; changing only the prompt made every row fail the ingest check, which still required a signed percentage; letting the model pick the tier put the same number in different tiers on different pages and languages | The demand column is one of peak, busier, average, quieter or very quiet in the target language, and the same number always maps to the same tier | `demandLevel(delta_pct)` returns the tier from fixed thresholds in code and the model only does the wording; the ingest check changed from "signed percentage" to "one of the five tiers", in step with the prompt |

### 1.4 Translated tables that kept their English headers

This one took four versions. The first three changed the prompt and did not work; the fourth switched to code.

Symptom. Pages have tables such as a price table, and the header should follow the page's language. In Korean, Japanese, `zh_HK` and `zh_TW` pages the header was English throughout:

```
Category    Typical Price    Usual Range
...         ...              ...
```

Besides the header, some cells of the demand column from the previous section (peak, busier than usual and so on) were also in English.

| Version | Change | Result on the next batch |
|---|---|---|
| v23 | Non-English headers and demand cells must be written in the target language | `ja_JP`, `zh_HK`, `zh_TW`, `ko_KR` did not comply |
| v24 | English example header changed to Title Case | English fixed, non-English headers still English |
| v25 | Example header changed to describe the meaning rather than fixed wording, plus a hard check | 6 demand cells and 1 header still English |
| v26 | Code supplies the exact header and demand phrases per locale, and the check compares them verbatim | Zero header and demand-column errors across 11 locales |

The cause showed itself at v24. I had put an English example header (`Category | Typical Price | Usual Range`) into the template, and when writing a Korean page the model copied that line as it was. In a prompt an example weighs more than a rule, and "write it in the target language" cannot outweigh an English line sitting right there. v25 removed the concrete example and things improved a lot, but as long as the model translates it itself, a small share will always come out wrong.

Fix (v26). Stop asking the model to translate and give it the standard wording for each language.

The project already had a mechanism for this: a per-locale vocabulary block (`{{locale_vocab}}`) appended at the end of the prompt, previously used for month names and hotel classes. v26 added each locale's header cells and the five demand phrases to it. Roughly like this (the translations are illustrative):

```
ko_KR  header: 카테고리 / 일반 가격 / 보통 범위    demand: 성수기 / …
ja_JP  header: カテゴリー / 一般的な価格 / …        demand: ピーク / …
zh_HK  header: 類別 / 一般價格 / …                  demand: 旺季 / …
```

The prompt says "copy verbatim". The model's job went from translating to copying, which it does reliably. The ingest check became a verbatim comparison too: the header and demand column must match the vocabulary exactly, otherwise the row is rejected.

The scope was a deliberate choice: only the 11 live locales, with the rest still on the earlier rules as a fallback. Covering all 46 locales would have meant four times the translations to review, and those locales are not live.

The result was zero errors in the header and demand column across 11 locales.

Takeaway. Fixed wording such as headers and tier names should not be translated by the model. Code gives the standard form per language, the model copies it, and the check compares it verbatim. Also remember that examples in a prompt beat rules: if an example is in the wrong language, the model follows it into the error.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| Korean, Japanese, Cantonese and Traditional Chinese pages kept the header `Category / Typical Price / Usual Range` (the model copied the English example header in the prompt); after v25, 6 demand cells and 1 header were still English | Zero header and demand-column errors across 11 locales | v26: code supplies the exact header and five demand phrases per locale in the per-locale vocabulary block `{{locale_vocab}}`, the prompt says "copy verbatim", and the check compares verbatim; only the 11 live locales are covered |

### 1.5 The section the model forgot to write

Symptom. Every city page should have three sections. But every batch had one or two pages with only the first section, and the other two simply missing.

It was hard to catch. Four batches in a row, the failing page was a different one each time: first `en_MY`, then `en_SG`, then `en_BS`, then `en_HK`. There was no fixed pattern, and when I fixed one, another page showed it.

I suspected truncation first, the model hitting the length cap before it finished. Checking ruled it out:

- `finish_reason` was `stop`, so the model ended on its own. A truncation would show `length`.
- The cap was 2,500 tokens, the broken answers were about 140 tokens and the healthy ones about 625, nowhere near the cap.

The prompt was fine too. All three sections were listed, the data for all three was supplied, and the prompt even said "complete data but only the first section is a defect". The model still dropped them.

My judgement is that the end of the first section reads like a summary, the model feels the piece is over at that point and stops. That is random behaviour of a small model. However strictly the rule is written, it only lowers the frequency, it cannot reach zero.

Fix (v27). Change the output format.

Before, the model returned one markdown string and how many sections it wrote was up to it. Now it returns an object with one required field per section, whose value is `{heading, body}`, and the field names are the sections' icon names. Roughly like this (the field names are illustrative):

```json
{
  "<icon name 1>": { "heading": "...", "body": "..." },
  "<icon name 2>": { "heading": "...", "body": "..." },
  "<icon name 3>": { "heading": "...", "body": "..." }
}
```

With strict schema mode on top, every field must appear, and an output missing a field is invalid in format. "Writing only one section" can no longer happen structurally.

The final markdown is assembled by code. After receiving the object, code builds the page from the sections, including heading markers such as `## :icon-x:`. The model no longer touches those markers, so it cannot get them wrong.

If a city has no data for a section, code leaves that field out when it builds the schema, so the model is not forced to make something up.

What pushed me to this was a decision. The assistant had suggested accepting the behaviour and covering it with retries. My answer was that I wanted guaranteed output, not a probability. The other option it offered was one call per section, which would never drop a section but would double the number of calls, and changing the whole cost structure for a rare defect was not worth it.

Not measured: I have not measured the missing-section rate on batches generated after v27, so "no missing sections" is a guarantee by design, not a conclusion from observation.

Takeaway. Random problems like the model occasionally forgetting to write something cannot be pushed to zero by adding rules. The more reliable way is to change the output format: make each part a required field so that leaving it out is structurally impossible, and leave the formatting to code.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| Every batch had one or two city pages with only the first of three sections (broken answers about 140 tokens, healthy ones about 625), `finish_reason` was `stop` and not truncation; writing "complete data but only the first section is a defect" into the prompt did not help | By design every section is a required field, so a missing section is structurally impossible; not measured on batches after v27 | v27 changed the output from one markdown string to an object with one required `{heading, body}` field per section, enforced by a strict schema; markdown and heading markers are assembled by code; a section with no data has no field |

### 1.6 A word the prompt itself introduced: "Global"

Some pages are written for a specific origin market, such as "for travellers setting out from Singapore", and then putting the origin market in a section title makes sense. Other pages have no specific origin market, and the title still read:

```
When travellers book (Global)
```

"Global" only means "no specific origin market" inside the system. It was never meant to appear on the page a reader sees.

Two similar problems showed up as well. In one batch the word "card" appeared 48 times on pages. And a label-like string, "Bold decision:", showed up in the output.

Cause. The first time I got it wrong: I added "do not write from Global" to the title rule, and it did nothing.

Digging further, two instructions were colliding. The prompt had a run block that rendered as "Address travellers setting out from Global". The system simply filled in the origin-market value, without considering that with the value Global the sentence makes no sense on its own. And the title rule asked the model to put the origin market in the title. The model combined the two and wrote "(Global)".

Deleting that sentence was not enough either. The input data still had a line `origin_market: Global`, and the model would still copy that value into the title. As long as the word appears anywhere the model can see, it can be written out.

The other two problems are the same thing. The footer instruction said "prices are shown in the card's currency code". "Card" is the system's internal name for a data card, and the model took it as a word for the body text. "Bold decision:" was a heading the instruction used to mark a formatting requirement, and the model printed it as content.

Fix. For "Global" I changed three things so that the word disappears from the model's view entirely:

- The data no longer says Global. When there is no origin market, `origin_market` is rendered as `none`.
- The sentence in the run block that describes the target reader no longer hard-codes "from xx". It is a placeholder: the specific market if there is one, otherwise "for general travellers".
- The exception rule that used to test "is it Global" now tests "is it `none`".

After that, the model reads no data containing the word "Global". I did not recheck on a new batch afterwards, so the effect is inferred from the design, not measured.

For "card" I rewrote the footer instruction so the word no longer appears, and on the next batch its count dropped to zero.

Takeaway. Anything you write into a prompt can end up in the output. Internal terms, placeholder values and format labels can all be written into the body text as long as the model can see them. Adding "do not write X" often does nothing; the reliable way is to make sure X is not in what the model reads at all.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| A page with no specific origin market had the section title "When travellers book (Global)"; the word "card" from the footer instruction leaked 48 times in one batch | "Global" no longer appears in any data the model reads (not rechecked on a new batch); "card" dropped to zero on the next batch | The origin market renders as `none`, the related clause became a placeholder that reads "for general travellers" when there is no origin, and the exception rule tests for `none`; the footer instruction was rewritten and no longer mentions "card" |

### 1.7 Contradictions between rules I wrote myself

The problem in this section is in rules I wrote: several rules fought each other, the model did not know which to obey, and mistakes followed. Here are three real examples. First a term: the shared prefix is the opening part of the prompt that all languages and all templates share, so whichever language a page is generated in, the model reads it.

Example 1: Chinese month names on an English page.

Symptom. On an English page the months were written in Chinese, for instance "7月".

Cause. The shared prefix had a rule: "never write market names in English". It was meant to stop non-English pages from mixing in English, but on an English page it contradicts itself: the page asks for English and the rule says English is not allowed. Worse, the shared prefix also had Chinese examples, which English pages read as well, and the model picked up the Chinese form from them.

Fix (v13). The rule became "write it in the language of target_language", which makes sense on a page in any language. I also deleted every CJK character from the shared prefix so that English pages stop learning from Chinese examples.

Example 2: a hotel area called "best value".

Symptom. The page described an area as "best value".

Cause. Two rules conflicted. The hotel template asked the model to call one area "best value", while a global rule forbade stating "best value" as an unsupported fact, since "best value" needs data behind it. With both rules in the prompt, the model could not satisfy both and followed one at random, so it wrote it sometimes and sometimes not.

Fix. I replaced "best value" in the template with "most affordable". "Most affordable" can be read straight off the price data and no longer conflicts with the global ban.

Example 3: a raw `2026-06` in the body text.

Symptom. The body text contained `2026-06`, a data format, instead of "June 2026".

Cause. The month rule said "turn months into names" but did not say what the months in the data look like. The data actually stores `YYYY-MM` strings, the rule never mentioned that form, so the model did not realise it was also a month to convert and wrote it into the body as it was.

Fix. I added the `YYYY-MM` form to the month rule and said explicitly that it must be converted to a month name.

A cheap habit that would have caught all three: for every global rule, search all templates for the word it forbids. If a global rule bans "best value", one search shows that the hotel template asks for exactly that, and the conflict is exposed at once. The check costs almost nothing.

After these fixes I did not count whether the three problems recur, so "no longer in conflict" is a statement about the rules, not measured data.

Takeaway. The more rules there are, the more likely they contradict each other, and faced with conflicting rules the model just picks one at random. When writing a rule, think about whether it holds in every language and every template, and make a habit of searching globally each time you add one.

| What went wrong | Effect after the fix | The fix |
|---|---|---|
| English pages showed Chinese month names ("never write market names in English" contradicts itself on English pages); a hotel area was called "best value" (conflict with a global ban); a raw `2026-06` leaked into the body (the month rule never mentioned `YYYY-MM`) | The rules no longer conflict; I have not measured how often the three problems recur | The prefix now says "write it in the language of target_language" and every CJK character was removed from the shared prefix; "best value" became "most affordable"; the month rule gained the `YYYY-MM` conversion; habit: search every template for the word a global rule forbids |

## Part 2: What the prompt did fix

Not everything needed code. These prompt-only changes worked, and they share a property: each removed ambiguity or removed something the model could misuse.

| Problem | Change | Why it works |
|---|---|---|
| Analyst shorthand `p25 / p50 / p75` printed in copy | One house rule saying the shorthand is for you, never the reader; say "entry-level", "typical", "upper end" in words | The model was reading the field names in the data as vocabulary; naming the failure and the substitute removes the guess |
| Hotel class keys printed raw, such as "premium 等級" | Name the exact fields (`best_value_tier`, `biggest_jump_*`, the class column) in the rule | The generic rule did not reach the fields where the keys actually appear |
| Sub-category table gained a sixth row for the page's own category | Fix the row count to the comparison rows in the context and say when this category gets a row | The model was trying to be complete; the rule says what complete means |
| Optional sections instructed even when their data was absent | Template gating: instructions for a section are removed at render time when its data block is absent | Fewer tokens, fewer contradictions, and it also removed the numbering gap (sections 1, 2, 4) that I suspected, but could not prove, was encouraging early stopping |
| Tours page repeated other verticals' prices in a comparison table | Remove the cross-category table; only that category's own figures | A request to scope down the data is also a hallucination guard, since there is nothing left to mix up |
| A table needed a lead-in sentence | Replace "heading, then table, no lead-in" with "exactly one lead-in sentence, no numbers, no names, no bold" | A narrow, checkable instruction beats a vague one |

The "Problem" column is terse, so here is one concrete example per row. The data and rule wording come from the real prompts and batch results; the output sentences are illustrative reconstructions of the defect's shape, not verbatim quotes.

#### Example 1: `p25 / p50 / p75` printed in copy

The data the model received:

```
p25: 68    p50: 105    p75: 350    currency: SGD
```

Before, the rule said "State the typical price (p50) and the range (p25–p75)". The model took the letters in the parentheses as words it could quote:

> The p50 price for this category is about SGD 105, with a p25–p75 range of SGD 68–350.

A reader has no idea what p50 means. After, the rule required words and forbade printing those letters:

> The typical price for this category is about SGD 105, and most prices fall between SGD 68 and SGD 350.

#### Example 2: hotel class keys printed raw

The data the model received:

```
best_value_tier: premium
biggest_jump_from: standard
biggest_jump_to: premium
```

Before, the rule only said "write hotel classes as ordinary words in the target language". The model did that for the class column, but these three fields are not in the class column, so `zh_TW` came out as:

> 性價比最高的是 premium 等級，從 standard 升到 premium 價格跳升最明顯。

After, the rule named the fields: "this also holds for `best_value_tier`, `biggest_jump_from` and `biggest_jump_to`":

> 性價比最高的是高級酒店，從標準等級升到高級價格跳升最明顯。

#### Example 3: sub-category table gained a sixth row for the page's own category

The page is Tours. The context held 5 comparison rows plus a separate "typical price for this category" card:

```
comparison rows: Observation decks / Museums / Theme parks / Cultural experiences / Attractions
this-category card: Tours  typical 49
```

Tours is not among the 5 rows. The model tried to make the table "complete" and built a sixth row from the card:

```
| Observation decks    | SGD 26 | SGD 22 – 28  |
| Museums              | SGD 39 | SGD 24 – 44  |
| Theme parks          | SGD 49 | SGD 31 – 57  |
| Cultural experiences | SGD 40 | SGD 23 – 84  |
| Attractions          | SGD 55 | SGD 30 – 90  |
| Tours                | SGD 49 | SGD 22 – 104 |   ← the extra row
```

After, the rule said "the table has exactly as many data rows as there are comparison rows; this category gets a row only when it is itself one of them; never build one from another card". The output went back to 5 rows.

#### Example 4: optional sections instructed even when their data was absent

The city template has 4 sections, and section 3, "Where to stay", depends on hotel price-by-district data. Suppose one city has no such data.

Before, the instructions for section 3 stayed in the prompt while the context had no matching block. The model either skipped the section or started inventing it, while another rule ("write every listed section") pulled the other way. The output was numbered 1, 2, 4, or section 3 was made up.

After, the render step detected the missing block and removed all of section 3's instructions. The prompt held only the three sections that had data, so the model had nothing to agonise over, and the prompt was a few hundred tokens shorter.

#### Example 5: Tours page repeated other verticals' prices

The page is Tours for Tokyo. Before, the body was followed by a cross-category comparison table:

```
Category              Typical Price   Usual Range
Observation decks     SGD 26          SGD 22 – 28
Museums               SGD 39          SGD 24 – 44
Theme parks           SGD 49          SGD 31 – 57
Cultural experiences  SGD 40          SGD 23 – 84
Tours                 SGD 49          SGD 22 – 104
```

A Tours page showing other categories' prices is off-topic, and it gives the model a chance to mix up numbers. After, the prompt no longer supplied the other categories' data, and the ingest check marks any table in that output invalid. What remained was one paragraph with the category's own prices:

> Entry-level excursions typically start around SGD 22, mid-range options sit around SGD 49, and premium tours reach up to SGD 104.

#### Example 6: a table needed a lead-in sentence

Before, the rule was "heading, then table, no lead-in", and the output was:

```
## How prices compare
Category | Typical Price | Usual Range
...
```

Nothing sits between the heading and the table, which reads abruptly. After, the rule was "exactly one lead-in sentence, no numbers, no category names, no bold":

```
## How prices compare
The table below compares the most popular categories by price,
so you can check your budget before choosing.

| Category | Typical Price | Usual Range |
...
```

The "no numbers, no names, no bold" limits keep that sentence from repeating the table's figures or going wrong.

What the six have in common is that the model followed the literal instruction, but the instruction had a gap. Examples 1 and 2 missed specific fields, example 3 did not say where "complete" ends, example 4 had more instructions than data, example 5 supplied data it should not have, and example 6 was written too absolutely. Closing the gap fixed each one, with no code taking over.

One failure worth recording on the other side: rules for hard counts did not hold. After I added a limit of three bold spans per paragraph, the next batch still had answers over the limit in every template (21, 13, 7 and 12 in four of them), and word and title ranges kept drifting too. A small model does not count reliably. I stopped chasing them. Which brings me to triage.

## Part 3: Triage is a prompt-engineering skill

The first review of a batch listed eleven findings, and I fixed them all. The next batch came back better but not clean, and the second review listed six. This time I answered with an explicit keep-or-drop list: relax the bold limit, explain and fix the "Global" heading, rewrite the hotel wording to relative terms, and ignore the missing hedges, the word counts and the demand-level check. Three of six were dropped on purpose, and a fourth (bold) was loosened instead of enforced.

The reasoning was about what a reader or a search engine sees. A hedge word missing before one price is a minor wording issue. A heading with "(Global)" in it is visible on the page. A table that does not render because the lead-in sentence shares a line with the header is broken. Rank by what a human would notice and what breaks rendering, and leave the rest.

I also pushed back on validation as the default answer. A validator that merely rejects a row costs me a manual rerun, so I asked the question differently: how do I make the output right before it is generated, or repair it after? That led to the three-tier model I now use.

| Tier | Mechanism | When to use it |
|---|---|---|
| Prevent | Code supplies the value or the structure (attribution line, category name, demand phrase, header cells, required section fields) | The correct answer is computable or enumerable |
| Detect and retry | An ingest check marks the row invalid and the queue retries automatically | The failure is rare, random, and a retry is free (missing section, wrong header) |
| Repair | A script patches finished output | The defect is cheap to detect mechanically, the fix is deterministic, and the volume is small |

A check that rejects without an automatic retry is only a to-do list. The checks I did keep, such as `checkTableLanguage`, run inside ingest, where a rejected row goes back into the queue by itself. I also added a local replay command (`batch:check`) that feeds a finished batch through the exact function ingest uses, offline, in seconds, with no API and no database. That turned "wait a day to learn whether the prompt worked" into "see which rows ingest would reject" before submitting anything.

## Part 4: The English that still got through

By the time the prompts reached v27 there was a pilot of 61,523 rows (parts 1 to 7) across 11 locales: 7 English variants plus `zh_HK`, `zh_TW`, `ja_JP`, `ko_KR`. A language scan found stray English in about 3.8% of them, roughly 2,350 rows. The proportion was nearly constant per part (4.1%, 3.8%, 3.8%, 4.1%, 3.8%, 3.7% for the larger parts).

By locale, `ja_JP` was always the largest share, roughly 36% to 51% of hits in each part; `zh_HK`, `zh_TW` and `ko_KR` followed.

A caveat that matters for interpretation: all seven parts were exported before the last prompt change described below, so 3.8% is a baseline, not the result of that change. I have not measured the after.

### Why it leaked, and what the prompt did about it

Reading the hits, most of them were not random. Three families accounted for the bulk:

- Hedge words. `around`, `typically`, `roughly`, written as `通常 around **JPY 15,000** 程度`.
- Time units and phrases. `**5 days ahead**`, `days out`, `two weeks out`, `in advance`.
- Words from the footnotes and framing: `median`, `travellers`, `entry-level`, `upper-end`, `bookings`.

The cause was partly mine. The house rules gave the hedge as English literals (`"around", "typically", "~"`), plus the example `"typically around **{currency} 51**"`. A Japanese page copies the part of the example that looked like a hedge. The no-English-left section listed activity types, price vocabulary and chart labels, but never mentioned hedges or time units.

The prompt change (the latest commit on the branch) does three things:

- Says the hedge is a meaning, not a word: in any non-English locale, write that language's own word for it.
- Extends the no-English rule to hedges, time units and phrases like "ahead" and "in advance". Only the digits and the currency code stay Latin.
- Adds a minimal Wrong/Right pair per language, such as the Japanese `around **JPY 15,000**` against `約 **JPY 15,000**`, and the Traditional Chinese `**5 days ahead**` against `**5 天**`.

Honest expectation, which I gave the assistant too when asked whether prompts could fully solve it: they can only lower the probability. A prompt cannot guarantee that a model never emits a Latin word. So the plan was a scan after generation.

### Should AI re-read everything and fix it? No.

My own proposal was to have an AI check and replace everything once all results were generated. The assistant's counter-proposal was better, and I took it:

- Use a script to find the problem. It costs nothing, takes seconds for 176 rows or 14,000, and unlike a model it never gets tired or skips a line.
- Use the AI only on the hits, and only to write the rules. A few hundred rows, not 60,000.
- Never let a model rewrite whole answers it was not asked to touch. It can silently change correct content.

I also looked at the alternative of simply rerunning the affected rows. On the token numbers above, regenerating all 2,350 would cost about $1.40. The money is irrelevant. What a rerun costs is the manual export, submit, wait, download, ingest loop, plus the real risk that a new generation has different defects than the old one. Repairing in place is deterministic and touches one string per row.

### The scanner

A result line is JSON; the answer is itself a JSON string inside it. The scan walks every string value in the answer, skipping structural keys (`icon`, `type`, `key`), and applies one of two checks depending on the locale:

- English locales: any Hiragana, Katakana, Han or Hangul character is a defect (this also catches Chinese months in an English page).
- Non-English locales: any Latin word of three or more letters that is not on an allowlist (currency codes, the brand name) is a hit.

```python
# scan.py (simplified)
OK = set('Company JPY KRW HKD TWD USD AUD SGD ...'.split())   # brand + currency codes

def strs(o, path=''):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ('icon', 'type', 'key'): continue
            yield from strs(v, path + '.' + k)
    elif isinstance(o, list):
        for i, v in enumerate(o): yield from strs(v, f'{path}[{i}]')
    elif isinstance(o, str):
        yield path, o

for line in open(path):
    row = json.loads(line)
    locale = row['custom_id'].split('|')[2]
    answer = json.loads(row['response']['body']['choices'][0]['message']['content'])
    for p, s in strs(answer):
        if locale.startswith('en'):
            if re.search(r'[぀-ヿ一-鿿가-힯]', s): report('ENCJK', p)
        else:
            hits = [m for m in re.finditer(r"[A-Za-z][A-Za-z'\-_]{2,}", s) if m.group(0) not in OK]
            if hits: report(row['custom_id'], p, hits)
```

The first version worked on the first two parts and fell apart on the third. Part 3 had 14,014 rows, many for small cities that exist in the data only under English names: Savannah, Reno, Whistler, Nakhon Chai Si. Hand-maintaining an allowlist of place names cannot work at that scale.

The second version asks a dictionary instead. A token is treated as English only if:

- it contains an underscore (a leaked field name such as `typical_days`), or
- it starts with a lowercase letter, or
- it is capitalised and its lowercase form is a dictionary word while the capitalised form is not itself a dictionary entry.

ALL-CAPS tokens are skipped (currency codes). A capitalised token that is not a common word is assumed to be a proper noun and passes. So "Advance" and "Typically" are flagged, "Savannah" and "Whistler" are not. It still produced false positives (the Lyon district "Presqu'île"), which I added to the allowlist by hand and noted in the report instead of "fixing".

### The fixer

The fixer is a table of ordered replacements per locale, applied only to the answer text, and extended after each scan. The scanner output is read, grouped, and rules are added until the rescan comes back empty. The rule shapes, simplified:

```python
def fix(locale, text):
    if locale.startswith('zh'):
        # "**5 days ahead**" -> "**5 天**" ; add 前 unless the context already has it
        text = re.sub(r'\*\*(\d+) days(?: ahead| out)?\*\*', zh_days, text)
    if locale == 'ja_JP':
        text = re.sub(r'\*\*(\d+) days(?: ahead| out)?\*\*', r'**\1日前**', text)
        text = re.sub(r'(概ね|おおむね|通常) around ', r'\1 ', text)   # already hedged: drop
        text = re.sub(r' ?\baround ?', '約', text)                      # otherwise: 約
    if locale == 'ko_KR':
        text = text.replace('typically around ', '보통 약 ')
    for wrong, right in TABLE[locale]:                                    # footnotes, glossary words
        text = text.replace(wrong, right)
    return text
```

The context-sensitive ones are the interesting ones. `around` becomes nothing when a Japanese hedge such as `概ね` already precedes it, and `約` otherwise; otherwise you produce "概ね約". The `days` rule checks the eight characters before and the three after for an existing "前" before adding one.

The ordinary hits were the families above. The table also grew some replacement entries for things that were not language at all but were caught by the same net, because garbage tends to contain Latin tokens:

- Leaked field names: `typical_days`, `ttd_demand_index`, `fallback_all`, `top_vs_bottom_ratio`, `data_window`.
- An unfilled placeholder in prose: `biggest_jump_from 到 biggest_jump_to`.
- A price table whose twelve rows were all `**TBD**`.
- The model's own working notes printed into a Japanese paragraph: `most旅行者booking phrasing must use typical_days which is absent, return empty string for this card if section absent.`
- Other languages: Spanish `alrededor` and `típicamente` inside Japanese, a truncated word `Standaードが`, an invented marker `<#}…_invalid_token_marker_removed---`.

A handful of whole English sentences were rewritten by hand, one at a time.

### Two ways the repair went wrong, and the guards that caught them

I broke things twice, and both are worth showing.

First, a replacement rule meant for prose also matched a JSON key. `ttd_demand_index` is both a leaked field name in text and a real key in the `insightdesc` JSON structure. The rule replaced the key with `需要指数` in about 180 rows. I caught it because the verification step compares every repaired file against its backup: same keys, same structure, and only the `content` string may differ. It did not match, I reverted, and re-ran with the rule restricted to the text value.

Second, a mechanical replacement of `upper-end` with `상위권` left a Korean particle that agrees with the old English word, giving `상위권는` instead of `상위권은`. A small particle-repair pass fixed nine rows. Korean particles depend on the final sound of the noun before them, so any replacement that changes the noun must re-pick the particle.

The guard rails that the process settled on, which I would copy to any script that edits generated data:

- Back up each part before touching it.
- Re-parse the repaired answer (`json.loads`) before writing it. A rule that produces invalid JSON fails at that line.
- After repairing, diff against the backup: only the `content` strings may have changed, and the key structure must be identical.
- Rescan after repair. The loop ends at zero hits (excluding listed proper nouns).
- Do not touch the English locales, where `days ahead` is just English.

### What the scan does not do

- It checks script and vocabulary, not quality. A Japanese sentence can be free of Latin letters and still read badly.
- It only works for locales that use a non-Latin script, plus the English-contains-CJK direction. English words inside German or Spanish text would need real language identification.
- Proper nouns are assumed, by the dictionary heuristic. A wrongly translated place name passes.
- It surfaced data defects it was not looking for: tables with twelve identical monthly prices, "increase of about 0%", and a few empty answers (one of them truncated, with `finish_reason: length`). The language fix cannot repair these. They are on a rerun list.

## Lessons, ordered by how much they paid

On accuracy:

1. Anything mechanical belongs in code. Attribution sentences, category names, demand levels, table headers and section structure all moved out of the prompt, and each stopped leaking the moment it did.
2. Examples are the loudest instruction. They get copied, in the wrong language, with the wrong dates. Keep examples abstract, or in the output language.
3. Anything you write into a prompt can come out. Do not put a value in the context you do not want printed (`Global`, `p50`, `card`, field names). Substitute it or remove it.
4. Search for contradictions. For every global rule, grep the templates for what it forbids.
5. Change the output contract before adding another rule. Required fields in a strict schema removed a failure that four rounds of rules did not.
6. Rank defects by what a reader sees and what breaks rendering. Drop the rest.

On cost and speed:

7. Put the static text first, the variables last, and share one prefix across templates. Measured at 74% to 77% cache hit at scale.
8. Measure your cache hit rate at the real batch size. Small pilots hit 53% to 58%.
9. Output is the spend. Set reasoning to minimal and cap output. Measured: 0 reasoning tokens, about 400 output tokens per row.
10. Gate instructions out of the prompt when their data is absent. It cuts tokens and removes contradictions.
11. Shrink the iteration loop first. A local replay of the ingest check turns a day-long round trip into seconds.
12. Compare repair with rerun on time and risk, not only on tokens. Rerunning 2,350 rows costs about $1.40; the cost is the manual loop and the chance of different defects.

## What I have not measured yet

| Change | Why I cannot claim an effect |
|---|---|
| Hedge words and time units in the shared prefix | All seven pilot parts were exported before it; the 3.8% leak rate is the before |
| Section schema in v27 | No later batch to compare; the guarantee is structural, not observed |
| Origin market rendered as `none` | I did not re-check headings for "Global" on a batch generated after the change |
| Effect of tiering page types onto cheaper models | Proposed in the cost doc, not run |

## Side note: zombie processes left by browser recycling, amplified by xtransit into memory growth

This section has nothing to do with prompts. It covers another investigation on the same kind of service that is worth writing down: why the memory of the PDF rendering services (nodepdfrenderer and commonpdfrenderer) kept growing, and why it grew in an unexpected place.

### Symptom

Pod memory only went up and never came back down: over a week it climbed from about 120 MB to more than 600 MB, with no sawtooth in the curve. A periodic browser recycle had already been shipped. It did bring the growth of kernel memory down (from 1.5 to 3 GB per day to about 0.1 GB), but anonymous memory still rose at about 3.5 MB per hour. The recycle had not stopped it.

Split by process, the one growing was the egg agent process, not the workers that handle requests and not Chrome. Two features of the chart stood out: RSS climbed steadily while the JS `heap_used` was almost flat, and the agent's CPU kept rising with uptime, with spikes getting denser and taller, even though the agent handles no requests.

Together these say that the growth is outside the JS heap, in native memory, and that the agent is doing a periodic job that gets more expensive over time.

### Cause: two harmless things stacked together

First, what a zombie process is. After a process exits, its parent has to call `wait()` to reap it before the system removes it from the process table. If nobody does, it stays in `ps` with state `Z`. It uses no CPU and almost no memory, but it still has a directory under `/proc`.

Condition one: recycling the browser leaves zombies behind. Every Chrome recycle leaves 4 exited descendants that nobody reaps: 2 `chrome_crashpad_handler` processes (Chrome's crash reporter) and 2 `cat` processes (started by the `google-chrome` wrapper script). Their parent is already gone, so the system re-parents them to PID 1. The container's PID 1 is `yarn`, which only reaps the children it started itself and ignores orphans, so the zombies pile up.

Condition two: xtransit runs with `docker: true`. xtransit is the monitoring component inside the agent. In this mode, every 60 seconds it walks `/proc` and reads `/proc/<pid>/stat` for every PID. The trouble is in how the files are read: files under `/proc` report a size of 0, and when Node's `fs.readFile` meets such a file it first allocates a 64 KiB buffer for it. Zombies have a directory under `/proc` too, so they get read as well.

Together they form an amplifier:

- More zombies means more PIDs in `/proc`, so each scan allocates more buffers.
- Those buffers are native memory outside the JS heap, and the glibc allocator does not hand it back to the operating system quickly, so the agent's RSS grows linearly with the zombie count.
- The scan itself also gets slower, so the agent's CPU grows linearly as well.

Neither condition causes trouble on its own. With xtransit but no zombies, each scan covers a few dozen PIDs and the cost is constant; other services run the same egg plus xtransit and their agents did not grow. With zombies but no xtransit, each zombie costs a small kernel structure of roughly 8 to 12 KB, which is negligible.

This also explains why the problem did not exist before the recycle shipped: Chrome used to stay up and never restart, so it never produced zombies. The recycle itself is correct. It fixed the kernel-memory half and, as a side effect, exposed this half.

### How it was confirmed

The conclusion was not a guess from experience. It was verified layer by layer.

First, reading the code. xtransit's `getAllUsedCpuFromProc()` reads `/proc` in a way that directly explains why the cost is proportional to the PID count.

Second, a local reproduction. With the real xtransit code, raising the PID count from 3 to 6003 grew the process RSS from 47 MB to 445 MB while the JS heap grew by only a dozen MB, and `arrayBuffers` came out at exactly 128 KiB times the PID count.

Third, a reproduction in the test environment. Using the same image as production, with the recycle frequency raised to accumulate zombies quickly, I counted 2876 zombies inside the Pod, half of them `cat` and half `chrome_crashpad_handler`, and PID 1 was indeed yarn. Sampling the processes' anonymous memory once a minute, 516 more zombies appeared in 30 minutes and the agent's anonymous memory grew by about 74 MB, which works out to about 143 KB per zombie. Over the same period the app worker and the master did not move.

Scaling that back to production: 143 KB times about 3000 zombies is roughly 430 MB, and the production agent had actually grown by 428 MB since startup. The orders of magnitude match.

The decisive step was a controlled experiment: remove one condition and the problem disappears. With `tini` as PID 1 reaping zombies, the same load test produced 0 zombies, and the thread count and container RSS stopped growing over two hours. I also checked that repeatedly starting Chrome does not leak by itself: with zombies being reaped, 200 consecutive Chrome launches left the render process RSS steady at about 51 MB. So the growth comes from the zombies, not from Chrome.

### Fix

Add `tini` as PID 1 in the Dockerfile:

```dockerfile
RUN apt-get install -y ... tini
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["yarn", "start"]
```

`tini` has a single job, reaping. Orphans re-parented to PID 1 are reaped as soon as they exit, so zombies no longer accumulate. `-g` makes it forward SIGTERM to the whole process group, so `yarn`, the egg master and the workers all receive the exit signal. A side benefit: previously the app was killed outright when the Pod stopped, and now it can exit gracefully.

Both Dockerfiles (voucher and non-voucher) must change together. If either is missed, the other service keeps the problem.

### What is worth remembering from this investigation

- A chart can narrow the search but cannot establish the cause. RSS rising while the heap stays flat only says the growth is in native memory. Pinning it on zombies came from splitting by process, comparing with other services, and finally an experiment that could be reproduced and controlled.
- "The recycle works" and "the problem is solved" are different statements. The recycle made the kernel-memory curve look good but never touched the anonymous half. Memory has to be looked at by type (anonymous, kernel, cache) rather than as a single total.
- An unremarkable default (`/proc` files get a 64 KiB buffer) and an unremarkable leftover (a few unreaped zombies) were each harmless. The problem only appeared where they met, and no single component looks faulty on its own. Look at the combination.

What has not been verified directly: the number of zombies in production was never counted. The roughly 3000 above is estimated from the recycle frequency, and only the order of magnitude matches the observed memory growth. Also, before the recycle shipped, the growth of about 3.7 MB per hour cannot have come from this mechanism (there were no zombies then). It is presumed to be growth of the long-running Chrome itself, but the per-process data from that period has expired and cannot be looked up.

## Appendix: prompt revision timeline

| Date | Revision | Change |
|---|---|---|
| Sep 21 | currency | Figures printed in the page's own currency, never converted |
| Sep 24 | v5 to v6 | Attribution built in code; template block shortened |
| Sep 24 to Oct 8 | category names | Names resolved by id from the category tree, with an AI overlay for gaps |
| Oct 19 | v13 | Shared prefix free of CJK; fixed sub-category row count; months and hotel classes in words; `p25/p50/p75` banned |
| Oct 20 | v18 | Template gating; richcontent ingest check rejects leaked shorthand and unlisted icons |
| Oct 20 | v21 to v23 | Tours-only data; lead-in sentence before a table; demand level in words, computed in code |
| Oct 21 | v24 to v26 | Title Case headers; per-locale header and demand vocabulary supplied by code |
| Oct 21 | v27 | One required field per section; markdown assembled in code |
| Oct 21 | run block | Origin market rendered as `none`, clause removed for markets with no origin |
| Oct 22 | shared prefix | Hedge words, time units and phrases must be in the target language |

## Appendix: a short checklist for the next batch pipeline

1. Before writing rules, decide for each requirement whether the answer is computable. If it is, supply it.
2. Put static text first, variables last. Make one shared prefix. Never put a placeholder in it.
3. Set reasoning to minimal and cap output. Read the usage block from the first real batch and recompute your budget.
4. Never use an example whose content can coincide with the data.
5. Do not put forbidden strings in the data the model sees. Render a neutral value instead.
6. Prefer required structured fields to prose rules about structure.
7. Build a local replay of your ingest check before the first pilot.
8. For each defect, choose: prevent, detect and retry, or repair. Do not add a rejecting check that has no automatic retry.
9. If you repair with a script: back up, re-parse, diff the structure, rescan, and restrict edits to the text field.
10. Keep a list of what you did not measure.
