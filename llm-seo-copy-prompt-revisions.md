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

Symptom. A `zh_HK` page ended with the English sentence "Based on Company booking data, July 2025 to June 2026." A different page, in Japanese, ended with a Simplified Chinese attribution sentence.

First instinct was to strengthen the prompt, but the prompt already had a hard requirement, correct and incorrect examples, and a "read the last sentence back" self-check. The other locales in the same batch were correct, so the failure was probabilistic, not a missing rule.

Then the Japanese case gave away the mechanism. The template contained worked examples, one per locale, and the data window on that card happened to be exactly `2025-07 - 2026-06`, the same dates as in the `zh_CN` example. The model did not mistranslate, it copied the example line wholesale, punctuation included. A second card in the same response used a different branch whose example dates did not match, and that one came out in correct Japanese. Same model, same call, different outcome, decided by whether the example matched.

Fix (prompt v5 to v6). The sentence is entirely mechanical: a locale and two `YYYY-MM` values. Code now builds it and places a finished `attribution:` line in the context block; the template says to copy that line verbatim. Month names come from `Intl.DateTimeFormat` rather than a hand-written table of 48 locales, with the calendar and numbering system pinned to `-u-ca-gregory-nu-latn`. That pin is not decoration: without it `th_TH` prints 2568 (Buddhist calendar) and `ar_SA` uses the Islamic calendar with Arabic-Indic digits.

Benefit. The leak path is closed by construction, not by lowering a probability. On tokens, the change removed about 2,260 characters of translation instructions and added about three short lines, a net of roughly minus 13% per request (about 3,384 down to about 2,930 tokens on the measured sample).

A subtlety worth recording, because I almost got it wrong: the removed block sat inside the cached prefix (billed at 10%) while the added lines sit in the variable tail (billed at 100%). So the bill drops by less than the token count does. The saving grows as the cache hit rate falls.

What generalises: models copy worked examples. If an example contains a finished sentence and your data can coincide with it, it will be returned as the answer. Prefer abstract placeholders in examples, or take the sentence out of the model's hands.

### 1.2 English category names inside a Japanese page

Symptom. Rows contained "Observation decks", "Events & shows" and "Tours" in `ja_JP`, `ko_KR` and `zh_HK` pages.

Cause. The template told the model, five times (once per sub-template): "sub_category_name arrives in English, write it in target_language". Delegating a translation of a proper label is how you get three different outcomes: Korean copied "Tours" unchanged, Hong Kong Chinese invented a classifier ("Tour 類活動"), and Japanese happened to get it right.

Fix. The site already has the real names, in every language, in its frontend category tree. The data cards now store the category id, not the English name, and the prompt-rendering step swaps in the locale's official name before the model ever sees it. The template changed from "translate it" to "copy it verbatim; do not translate, reword, add a classifier, or put the English in brackets". A page whose name cannot be resolved is declined (`renderable: false`) rather than generated with an English name, because an empty pack would otherwise fail silently: nobody files a bug for a Japanese page with one English noun in it.

Then the long tail:

- 36 locales had gaps in the official tree, including the main markets for one node (a Japan bus ticket category). An LLM-translated overlay fills them.
- My first guard rejected a whole language whenever any name came back identical to the English. Arabic "eSIM" is correctly written "eSIM", so 134 good translations were thrown away because of one word that should not change. The guard became proportional: individual identical names are kept and listed for a human, and only a high share (above 20%, with a minimum sample of 5) means the model did not translate.
- English variants such as `en-AE` do not need translating at all; the fallback chain already reaches `en`.
- Re-running a translation at temperature 0 gives the same output, so "just rerun it" verified nothing. I had suggested exactly that, and had to retract it.
- The packs were first generated at image build time, then moved to committed JSON files with one key per line. Translations change a few times a year, so a network fetch on every build buys freshness nobody needs and adds a new way for the build to fail. One key per line matters because the only review question is "which name changed".

For rows already generated, a backfill script replaced the names in place. It refuses ambiguous cases (one English name mapping to two ids) and counts them instead of guessing.

### 1.3 "Demand vs a typical month" showed numbers where words were wanted

A product request: show a demand level in words in the month table, not +59% and -57%.

My first plan was a prompt-only change. It would have broken everything, because an ingest check required that column to be a signed percentage matching the data, so every row would have been rejected. The prompt and the checker have to change together.

Then I made the model do the classification, and the second request was the right one: let code decide the level from the percentage (`demandLevel(delta_pct)` returns peak, busier, average, quieter or very quiet) and let the model only phrase it. This moved a judgement from the model to a function.

### 1.4 Translated tables that kept their English headers

This one took four prompt versions to give up on.

| Version | Change | Result in the next batch |
|---|---|---|
| v23 | Non-English headers and demand cells must be written in the target language | Not followed in `ja_JP`, `zh_HK`, `zh_TW`, `ko_KR` |
| v24 | Make English example headers Title Case | Fixed English; non-English headers still English |
| v25 | Example headers described as meanings, not fixed text; hard check added | 6 demand cells and 1 header still English |
| v26 | Code supplies the exact header cells and demand phrases per locale; the checker compares verbatim | Zero header or demand errors across all 11 locales |

The v24 step is the instructive one. I had put the English example header in the template (`Category | Typical Price | Usual Range`), and the model, working in Korean, copied it. The example was the strongest signal in the prompt, and it was in the wrong language.

The v26 mechanism reuses something the project already had, a per-locale vocabulary block appended at the end of the prompt (`{{locale_vocab}}`, previously used for month names and hotel classes). The header cells and the five demand phrases for each of the 11 locales went into that table, and the prompt says "copied exactly". The model's task changed from translate to copy, which is a task it does reliably.

Scope was a deliberate choice: only the 11 production locales, with the previous rule as a fallback for the rest. Covering all 46 would have been 4 times the review burden for languages that were not shipping.

### 1.5 The section the model forgot to write

Symptom. Every batch had one or two city pages with only the first of three sections. Across four consecutive batches it was a different page each time (`en_MY`, then `en_SG`, then `en_BS`, then `en_HK`).

I checked whether it was truncation. It was not. `finish_reason` was `stop`, the cap was 2,500 tokens, and the broken answers were about 140 tokens long against 625 for a healthy one. The prompt listed all three sections and the data for all three was present. The prompt even said "Stopping after the first section while the others have data is a defect", and the model ignored it. The first section happened to end like a conclusion, and the model stopped there. It is a random behaviour of a small model, so adding rules cannot drive it to zero.

Fix (v27). Change the output contract. The answer used to be one markdown string; now it is an object with one required field per section, each `{heading, body}`, with strict mode forcing every field to be present. Fields are named after the section icons. Code assembles the final markdown, including the `## :icon-x:` heading markers, which means the model also cannot get a marker wrong. Sections without data have no field at all.

The decision that pushed me here was my own: when the assistant suggested accepting the behaviour and relying on retries, my answer was that I wanted guaranteed output, not a probability. The alternative the assistant raised, one call per section, would have doubled the call count and changed the cost structure for the sake of a sporadic defect.

Unmeasured: I did not measure the missing-section rate on a batch generated after v27, so the guarantee is by design, not by observation.

### 1.6 A word the prompt itself introduced: "Global"

Symptom. Section headings such as "When travellers book (Global)", on pages with no particular origin market.

The first fix added "never write from Global" to the heading rule. It did not work. The second analysis found the cause was two instructions colliding: the run block rendered to "Address travellers setting out from Global", while the heading rule asked the model to name the origin market in the heading. The model combined them.

Even after removing that sentence, `origin_market: Global` still sat in the input block, and the model copied the value. The final fix has three parts: render the value as `none`, make the clause a placeholder that is filled with "address travellers in general" for those markets, and re-state the exception in terms of `none`. After that, the word no longer appears anywhere in the data the model reads.

The pattern repeated for other leaked strings. Footnotes said "prices are shown in the card's currency code", and the word "card" leaked 48 times in one batch. The fix was to reword the instruction, and "card" dropped to zero in the next batch. A label like "Bold decision:" appeared in the output because the instruction used it as a heading. Both are the same bug: anything you write into a prompt is a candidate for the output.

### 1.7 Contradictions between rules I wrote myself

Three real ones:

- The shared prefix said "never write the market name in English", which is an instruction that contradicts itself on an English locale. English pages came back with Chinese month names. v13 reworded it to "in the language of target_language", and removed every CJK character from the shared prefix, because the English pages had been picking up the Chinese examples sitting in it.
- The hotel template told the model to call a district "best value", while a global rule forbade "best value" as a bare claim. Both are in the prompt, so the model obeyed one at random. Replaced with "most affordable".
- The month rule said "convert months to names", but never mentioned the `YYYY-MM` strings that the data actually contains, so raw `2026-06` leaked into prose.

A cheap habit that would have caught all three: for each global rule, search every template for the phrase it forbids.

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
