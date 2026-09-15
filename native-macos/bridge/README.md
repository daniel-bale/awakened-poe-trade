# Native trade core bridge

`npm ci && npm run build` bundles the repository's item parser, preset engine,
and official trade query builder into
`../Sources/TradeCore/Resources/trade-core.js`. Node is needed only to build.
`npm test` builds and runs offline regression tests in a JavaScript VM without
browser or Node globals. If the default npm cache is unavailable, use
`npm ci --cache /private/tmp/awakened-native-npm-cache`.

The bundle exports a global `NativeTrade` object. Its methods accept and return
JSON **strings**, so Swift can use `JSValue.invokeMethod` without sharing object
graphs. All failures return `{ "ok": false, "error": "..." }`.

```ts
NativeTrade.analyze(JSON.stringify({
  text: string,
  league?: string, // defaults to Standard
  language?: 'en' | 'cmn-Hant', // defaults to en
  options?: {
    merchantOnly?: boolean, // true
    currency?: string | null, // null
    collapseListings?: 'api' | 'app', // api
    activateStockFilter?: boolean, // false
    searchStatRange?: number // 10, allowed 0...100
  }
}))
// Returns { ok: true, language, league,
//   item: { id, identity, name, baseType, rarity, category?, itemLevel?, icon?, dustEquivalent?,
//     market: {query, related, stackSize?, stackMax?, dustEquivalent?, predictionEligible},
//     properties: [{label: string, value: string}],
//     modifiers: [{text: string, type: string}], unknownModifiers: string[], rawText },
//   presets: [{ id, title, tradeTag?, filters: ItemFilters, stats: FilterOrGroup[] }],
//   requiresIdentification: boolean, uniqueCandidates: [{id, name, icon?}],
//   shouldAutoSearch: boolean, activePreset: string,
//   kind: 'trade' | 'bulk', query: TradeRequest | BulkRequest | null, url: string }

NativeTrade.resolveUnique(JSON.stringify({
  text: string, league?: string, language?: 'en' | 'cmn-Hant', options?: SearchOptions,
  uniqueRefName: string // candidate.id from analyze
}))
// Same result as analyze. The candidate must match the copied unidentified base.

NativeTrade.buildQuery(JSON.stringify({
  league?: string,
  language?: 'en' | 'cmn-Hant',
  filters: ItemFilters,
  stats: FilterOrGroup[],
  tradeTag?: string // preserve the selected preset's value
}))
// Returns { ok: true, kind: 'trade' | 'bulk', query: TradeRequest | BulkRequest, url: string }
```

Pass a selected preset's `filters`, `stats`, and `tradeTag` back to `buildQuery` after native
UI edits. Set a stat's `disabled` flag, `roll.min`, or `roll.max`. A grouped stat
has `group`, `meta`, and `stats`; preserve this structure. Blank numeric values
can be `""` or omitted. The official query builder retains its own grouping,
trade IDs, inversion, and category rules. Enabled filters with a minimum greater
than their maximum return a validation error, including nested groups.
Stat metadata includes `nativeQuality` for normalized properties and `nativeOils`
(`refName`, localized `name`, optional `icon`) for anoint recipes. Neither changes
the query. Item/area level chips support both bounds; map tiers remain exact.
Native Yes/No/Any menus store `nativeValue: boolean | null` on an existing
`unidentified` (meaning identified), `mirrored`, `split`, `imbuedGem`, `fractured`,
`foulborn`, or `vestigial` filter. An absent nativeValue preserves the original
core default; null explicitly removes that API constraint.

An unresolved unique has `requiresIdentification: true`, empty presets, a null
query, an empty URL, and `shouldAutoSearch: false`. Display its candidates first.
The smart-search predicate otherwise matches the original CheckedItem screen;
the host still applies the user's automatic-search preference.

Queries always target `www.pathofexile.com` using canonical English item names,
including when parsing Traditional Chinese. An item with a tradeTag and no
enabled stat/group uses the original bulk builder: Chaos Orb buys with divine,
Divine Orb with chaos, and other bulk items use both. Bulk browser URLs use the
official `{exchange: query.query}` shape; normal URLs encode the full query.
League names retain their exact spelling, case and suffix spacing; only leading
and trailing whitespace is trimmed. Authentication belongs to the host/browser.
Fetching results and observing API rate limits belong to the Swift host.

The adapter reads the checked-in English and Traditional Chinese NDJSON
datasets with exact map lookups. It preserves the renderer's grouped stat
resolution and validates the stat references requested by the shared core.
Only browser/network module boundaries are substituted. Parsing, presets,
modifiers, and both request builders reuse the original modules. The shared
Foulborn request key is updated to the official `mutated` schema. A plain-data clone helper
supplies the `structuredClone` operation used by reduced modifier rolls in the
shared core, because bare JavaScriptCore does not provide browser APIs. The
parser requires the full advanced item description for equipment modifiers. Plain older equipment
clipboard text is rejected instead of silently generating an unfiltered query.
On the macOS game, hover the item and press Control+C (Ctrl+C) to copy it.

Fixtures are synthetic clipboard examples for regression testing. They are not
live listings or evidence of market prices.
