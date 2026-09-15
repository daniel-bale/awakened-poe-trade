# Windows price-check parity

Scope: the compact item price-check workflow discussed in this task. This is not a claim that all Electron overlay widgets, chat macros, map tools, or supported languages have been ported.

The native parser and query builder reuse the checked-out Windows TypeScript code in `renderer/src`. Native controls expose the underlying values instead of maintaining a separate approximation of trade filters.

| Behavior | Windows reference under `renderer/src/web/price-check` | Native implementation |
| --- | --- | --- |
| Item presets, roll range, merchant/currency/stock defaults | `CheckedItem.vue`, `filters/create-presets.ts` | `bridge/src/index.ts`, `NativeSearchOptions`, `AppModel` |
| Smart initial search and same-item currency | `CheckedItem.vue` | Bridge predicate, identity-preserving `checkText` |
| Exact/relaxed type, numeric bounds, influences, item variants | `filters/FiltersBlock.vue`, `filters/FilterBtnNumeric.vue` | `MainView`, `FilterPanel` |
| Stat/group selection, source mods, specialized options | `filters/FilterModifier.vue`, `filters/FilterGroup.vue` | `FilterPanel` with shared filter JSON |
| Unidentified unique resolution | `unidentified-resolver/UnidentifiedResolver.vue` | Bridge resolver and native candidate chooser |
| Availability, listed period, currency, merchant mode | `trade/OnlineFilterCore.vue` | `TradeOptionsView`, Settings, shared query builder |
| Representative listings and grouping | `trade/TradeListing.vue`, `trade/pathofexile-trade.ts` | `TradeClient`, `TradeResultsView` |
| Bulk routing, currencies, ratio, stock and fulfillment | `trade/common.ts`, `trade/pathofexile-bulk.ts`, `trade/TradeBulk.vue` | Bridge bulk query, `TradeClient.exchange`, `BulkResultsView` |
| Account session for private leagues | `main/src/proxy.ts` (repository root) | Persistent `TradeBrowserSession`, same-origin WebKit transport; live native authenticated search and fetch verified |
| Market price/trend, Divine table, stack/related/dust values | `trends`, `expected-value`, `related-items` | `MarketDataClient`, `MarketDataView`, shared query metadata |
| Optional prediction, confidence/contributions, feedback | `price-prediction/PricePrediction.vue` | `MarketDataClient`, `MarketDataView`; disabled by default |

Transport tests use explicit fixtures for response decoding, rate limiting, cancellation, sessions, pagination and exchange behavior. Bridge tests run the actual generated JavaScript in Node and JavaScriptCore. These checks do not establish that a private account is signed in or that a live league accepts its query.

The earlier live bulk-row retest opened its seller popover in Standard (Orb of Alteration: 23 matches, 6 shown in the Chaos tab), including account, character, status, stock and listing time. Raw whisper placeholders were exposed. An HTTP 200 response confirmed the API's separate templates for each exchange side; the completed formatter uses each listed lot and preserves the API wording, with Trade as the fallback for unresolved templates. Two new regressions passed. The final packaged retest returned 21 Standard matches, with 6 in the Chaos tab; a row opened the popover with fully filled “4 Orb of Alteration for my 1 Chaos Orb” text and Copy whisper. No actual copy or send was performed.

In an earlier browser diagnostic, the temporary browser-only app `/private/tmp/poe-browser-compat.0jsl_oqk` reached the official `/login` Sign In page with Email, Steam, Epic, Xbox and PlayStation Network options without the agent solving a CAPTCHA. The user then signed in; Computer Use observed “Logged in as” and `/my-account` in that separate diagnostic browser. The official Trade site selector confirmed the exact identifier `Limey Whelps (PL86569)`. Selecting it and The Baron / Close Helmet through the site's autocomplete returned 15 real listings for an item-only query with status Any. This established website account access; native authenticated transport was verified separately below. The canonical identifier was subsequently saved in the production app through its UI, and the picker heading is now Available leagues. No whisper, travel or trade action was performed.

The earlier approved main app remained at verification after ordinary reload. The diagnostic app allowed `about:srcdoc` child frames and initial popups, but this comparison does not isolate that policy as the cause. The final package includes that support. Its browser initially appeared blank, then ordinary refresh reached a Cloudflare challenge with an actionable checkbox. The agent left verification/sign-in to the user. After the user completed sign-in, Computer Use verified “Logged in as” in the actual production browser on `Limey Whelps (PL86569)`.

Native authenticated POST and listing fetch then succeeded with Use browser session ON. The Baron's original three filters (base percentile minimum 65, zombie leech minimum 1.61, minion maximum life minimum 20) returned 0 matching listings without an error. Unchecking only minion life and searching again returned 5 matches and loaded five real seller rows, all priced at 1 chaos. The minion-life checkbox was restored to ON afterward; the normal filter change cleared those results, and no subsequent result is claimed. The canonical league and browser-session setting were preserved. No source or packaged-app changes were made during these checks.

The completed source passed 80 Swift tests (15 capture, 14 bridge, 39 network, 12 market) and 28 Node tests. Final packaging and strict code-signature verification passed; source and packaged JavaScript resources match. Accessibility permission is now verified for that same final binary: a targeted reset succeeded, the app recreated its OFF entry, Computer Use toggled Awakened PoE Trade ON without a new password dialog, and native Settings → Check Again reported Accessibility enabled. Its CDHash remained `31a30ae4d1a664d85f240f43ea8e702999be7380`; no further build or source change occurred.

For actual on-machine checks, results and remaining limitations, see [TESTING.md](TESTING.md). Native authenticated private-league search and current Accessibility permission are verified. No fresh physical hover-and-Ctrl+D capture was performed during the final check; the earlier user-confirmed capture remains historical. A loaded browser origin is still reported only as ready, never as proof of sign-in.
