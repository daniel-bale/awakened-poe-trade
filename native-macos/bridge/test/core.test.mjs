import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import test from 'node:test'

// No Node/browser globals are supplied. This exercises the same closed runtime
// contract as JavaScriptCore and catches accidental renderer platform imports.
const context = vm.createContext({ console: undefined })
vm.runInContext(readFileSync(new URL('../../Sources/TradeCore/Resources/trade-core.js', import.meta.url), 'utf8'), context)
const core = context.NativeTrade
const fixture = name => readFileSync(new URL(`fixtures/${name}.txt`, import.meta.url), 'utf8')
const analyze = (name, language = 'en') => JSON.parse(core.analyze(JSON.stringify({ text: fixture(name), language, league: 'Standard' })))

test('currency clipboard builds the original bulk query and exchange browser URL', () => {
  const value = analyze('chaos-orb')
  assert.equal(value.ok, true, value.error)
  assert.equal(value.item.name, 'Chaos Orb')
  assert.equal(value.item.properties[0].value, '10 / 20')
  assert.equal(value.kind, 'bulk')
  assert.deepEqual(value.query.query.want, ['chaos'])
  assert.deepEqual(value.query.query.have, ['divine'])
  assert.equal(value.query.sort.have, 'asc')
  const url = new URL(value.url)
  assert.equal(url.origin, 'https://www.pathofexile.com')
  assert.equal(url.pathname, '/trade/exchange/Standard')
  assert.deepEqual(JSON.parse(url.searchParams.get('q')), { exchange: value.query.query })
})

test('default settings, stock, bulk routing and smart-search eligibility match Windows', () => {
  const rare = analyze('rare-ring')
  assert.equal(rare.kind, 'trade')
  assert.equal(rare.query.query.status.option, 'securable')
  assert.equal(rare.shouldAutoSearch, false)
  const bulk = JSON.parse(core.analyze(JSON.stringify({ text: fixture('chaos-orb'), options: { activateStockFilter: true } })))
  assert.equal(bulk.query.query.minimum, 10)
  assert.equal(bulk.shouldAutoSearch, true)
  assert.equal(bulk.item.identity, bulk.item.id)
  const preset = bulk.presets.find(p => p.id === bulk.activePreset)
  assert.equal(preset.tradeTag, 'chaos')
  const allDisabled = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, stats: [{ tradeId: ['explicit.stat_3299347043'], text: 'Life', disabled: true }] })))
  assert.equal(allDisabled.kind, 'bulk')
  const active = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, stats: [{ tradeId: ['explicit.stat_3299347043'], text: 'Life', disabled: false }] })))
  assert.equal(active.ok, true, active.error)
  assert.equal(active.kind, 'trade')
  assert.equal(active.query.query.type, 'Chaos Orb')
  const divine = JSON.parse(core.analyze(JSON.stringify({ text: fixture('chaos-orb').replaceAll('Chaos Orb', 'Divine Orb') })))
  assert.deepEqual(divine.query.query.have, ['chaos'])
  const alchemy = JSON.parse(core.analyze(JSON.stringify({ text: fixture('chaos-orb').replaceAll('Chaos Orb', 'Orb of Alchemy') })))
  assert.deepEqual(alchemy.query.query.have, ['divine', 'chaos'])
})

test('price-check options are honored and invalid preferences fail clearly', () => {
  const value = JSON.parse(core.analyze(JSON.stringify({ text: fixture('rare-ring'), options: { merchantOnly: false, currency: 'divine', collapseListings: 'app' } })))
  assert.equal(value.ok, true, value.error)
  assert.equal(value.query.query.status.option, 'available')
  assert.equal(value.query.query.filters.trade_filters.filters.price.option, 'divine')
  assert.equal(value.query.query.filters.trade_filters.filters.collapse, undefined)
  for (const options of [{ searchStatRange: -1 }, { searchStatRange: 101 }, { merchantOnly: 'true' }, { collapseListings: 'bad' }]) {
    const invalid = JSON.parse(core.analyze(JSON.stringify({ text: fixture('rare-ring'), options })))
    assert.equal(invalid.ok, false)
  }
})

test('private league names retain their exact spelling, case and suffix spacing', () => {
  for (const league of ['LIMEY WHELPS(PL86569)', 'LIMEY WHELPS (PL86569)', ' LIMEY WHELPS  (PL86569) ']) {
    const value = JSON.parse(core.analyze(JSON.stringify({ text: fixture('tabula-rasa'), league })))
    assert.equal(value.league, league.trim())
    assert.equal(decodeURIComponent(new URL(value.url).pathname.split('/').at(-1)), league.trim())
  }
  const unchanged = JSON.parse(core.analyze(JSON.stringify({ text: fixture('tabula-rasa'), league: 'MiXeD league (custom)' })))
  assert.equal(unchanged.league, 'MiXeD league (custom)')
})

test('unidentified unique selection is bounded to the copied base and keeps unidentified search', () => {
  const text = 'Item Class: Rings\nRarity: Unique\nAmethyst Ring\n--------\nItem Level: 80\n--------\nUnidentified'
  const value = JSON.parse(core.analyze(JSON.stringify({ text })))
  assert.equal(value.ok, true, value.error)
  assert.equal(value.requiresIdentification, true)
  assert.equal(value.shouldAutoSearch, false)
  assert.equal(value.query, null)
  assert.ok(value.uniqueCandidates.some(candidate => candidate.id === "Ming's Heart"))
  const resolved = JSON.parse(core.resolveUnique(JSON.stringify({ text, uniqueRefName: "Ming's Heart" })))
  assert.equal(resolved.ok, true, resolved.error)
  assert.equal(resolved.requiresIdentification, false)
  assert.equal(resolved.item.name, "Ming's Heart")
  assert.equal(resolved.query.query.name, "Ming's Heart")
  assert.equal(resolved.query.query.filters.misc_filters.filters.identified.option, 'false')
  assert.equal(JSON.parse(core.resolveUnique(JSON.stringify({ text, uniqueRefName: 'Tabula Rasa' }))).ok, false)
  assert.equal(JSON.parse(core.resolveUnique(JSON.stringify({ text: fixture('chaos-orb'), uniqueRefName: "Ming's Heart" }))).ok, false)
})

test('native item option menus generate true, false and absent API filters', () => {
  const value = analyze('rare-ring')
  const preset = value.presets.find(p => p.id === value.activePreset)
  for (const [key, api] of [['mirrored', 'mirrored'], ['split', 'split'], ['unidentified', 'identified'], ['imbuedGem', 'gem_imbued'], ['fractured', 'fractured_item'], ['foulborn', 'mutated'], ['vestigial', 'vestigial']]) {
    for (const option of [true, false, null]) {
      preset.filters[key] = { ...(preset.filters[key] ?? {}), nativeValue: option }
      const result = JSON.parse(core.buildQuery(JSON.stringify({ ...preset })))
      assert.equal(result.ok, true, result.error)
      assert.deepEqual(result.query.query.filters.misc_filters.filters[api], option == null ? undefined : { option: String(option) })
    }
  }
  preset.filters.foulborn = { value: false }
  const result = JSON.parse(core.buildQuery(JSON.stringify({ ...preset })))
  assert.equal(result.query.query.filters.misc_filters.filters.mutated.option, 'false')
  assert.equal(result.query.query.filters.misc_filters.filters.foulborn_item, undefined)
})

test('item ranges, maps and corruption choices survive query editing', () => {
  const value = analyze('rare-ring')
  const preset = value.presets.find(p => p.id === value.activePreset)
  preset.filters.itemLevel = { value: 80, max: 86, disabled: false }
  preset.filters.corrupted = { value: true, exact: true }
  preset.filters.mapBlighted = { value: 'Blight-ravaged' }
  let result = JSON.parse(core.buildQuery(JSON.stringify(preset)))
  assert.deepEqual(result.query.query.filters.misc_filters.filters.ilvl, { min: 80, max: 86 })
  assert.equal(result.query.query.filters.misc_filters.filters.corrupted.option, 'true')
  assert.equal(result.query.query.filters.map_filters.filters.map_uberblighted.option, 'true')
  preset.filters.itemLevel.max = 70
  assert.equal(JSON.parse(core.buildQuery(JSON.stringify(preset))).ok, false)
  preset.filters.itemLevel.disabled = true
  preset.filters.corrupted.exact = false
  preset.filters.mapBlighted.value = null
  result = JSON.parse(core.buildQuery(JSON.stringify(preset)))
  assert.equal(result.ok, true, result.error)
  assert.equal(result.query.query.filters.misc_filters.filters.ilvl, undefined)
  assert.equal(result.query.query.filters.misc_filters.filters.corrupted, undefined)
  assert.equal(result.query.query.filters.map_filters?.filters.map_uberblighted, undefined)
})

test('market identity is canonical and rare prediction excludes unidentified equipment', () => {
  const currency = analyze('chaos-orb')
  assert.deepEqual(currency.item.market.query, { ns: 'ITEM', name: 'Chaos Orb' })
  assert.equal(currency.item.market.stackSize, 10)
  assert.equal(currency.item.market.stackMax, 20)
  assert.equal(currency.item.market.predictionEligible, false)
  const rare = analyze('rare-ring')
  assert.equal(rare.item.market.predictionEligible, true)
  assert.equal(rare.item.market.query.name, 'Coral Ring')
  const unique = analyze('tabula-rasa')
  assert.equal(unique.item.market.query.variant, 'Simple Robe, 6L')
})

test('rare item preserves ranges and combines implicit life and elemental resistances', () => {
  const value = analyze('rare-ring')
  assert.equal(value.ok, true, value.error)
  assert.equal(value.item.name, 'Havoc Circle')
  assert.equal(value.item.itemLevel, 85)
  assert.equal(value.item.modifiers.length, 6)
  assert.equal(value.item.modifiers[5].text, 'Adds 5 to 10 Physical Damage to Attacks')
  assert.deepEqual(value.item.unknownModifiers, [])
  const stats = value.query.query.stats.flatMap(group => group.filters)
  assert.equal(stats.find(stat => stat.id === 'pseudo.pseudo_total_life').value.min, 100)
  assert.equal(stats.find(stat => stat.id === 'pseudo.pseudo_total_elemental_resistance').value.min, 97)
  assert.equal(value.query.query.filters.type_filters.filters.category.option, 'accessory.ring')
})

test('editing enabled state and min/max survives the native JSON round trip', () => {
  const value = analyze('rare-ring')
  const preset = value.presets.find(p => p.id === value.activePreset)
  const life = preset.stats.find(stat => stat.tradeId?.includes('pseudo.pseudo_total_life'))
  life.roll.min = 80
  life.roll.max = 140
  life.disabled = true
  preset.filters.trade.offline = true
  const updated = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, league: 'A League / Test', language: 'en' })))
  assert.equal(updated.ok, true, updated.error)
  assert.equal(updated.query.query.status.option, 'any')
  const filter = updated.query.query.stats.flatMap(group => group.filters).find(stat => stat.id === 'pseudo.pseudo_total_life')
  assert.deepEqual(filter.value, { min: 80, max: 140 })
  assert.equal(filter.disabled, true)
  assert.ok(updated.url.startsWith('https://www.pathofexile.com/trade/search/A%20League%20%2F%20Test?q='))
})

test('unique item keeps its exact identity and six linked sockets', () => {
  const value = analyze('tabula-rasa')
  assert.equal(value.ok, true, value.error)
  assert.equal(value.item.rarity, 'Unique')
  assert.equal(value.query.query.name, 'Tabula Rasa')
  assert.equal(value.query.query.type, 'Simple Robe')
  assert.equal(value.query.query.filters.socket_filters.filters.links.min, 6)
})

test('reversed active ranges are rejected while disabled filters remain editable', () => {
  const value = analyze('rare-ring')
  const preset = value.presets.find(p => p.id === value.activePreset)
  const life = preset.stats.find(stat => stat.tradeId?.includes('pseudo.pseudo_total_life'))
  life.roll.min = 120
  life.roll.max = 80
  life.disabled = false
  let response = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, language: 'en' })))
  assert.equal(response.ok, false)
  assert.match(response.error, /Minimum cannot exceed maximum/)
  life.disabled = true
  response = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, language: 'en' })))
  assert.equal(response.ok, true, response.error)
  life.disabled = false
  preset.stats = [{ group: 'one', meta: { text: 'One modifier', disabled: false }, stats: [life] }]
  response = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, language: 'en' })))
  assert.equal(response.ok, false)
  preset.stats[0].meta.disabled = true
  response = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, language: 'en' })))
  assert.equal(response.ok, true, response.error)
})

test('reduced modifiers work without browser structuredClone and invert query bounds', () => {
  const value = analyze('mings-heart')
  assert.equal(value.ok, true, value.error)
  const preset = value.presets.find(p => p.id === value.activePreset)
  const life = preset.stats.find(stat => stat.text === '#% reduced maximum Life')
  assert.equal(life.roll.isNegated, true)
  assert.equal(life.roll.tradeInvert, true)
  life.disabled = false
  life.roll.min = 15
  life.roll.max = 20
  const response = JSON.parse(core.buildQuery(JSON.stringify({ ...preset, language: 'en' })))
  assert.equal(response.ok, true, response.error)
  const queryStat = response.query.query.stats.flatMap(group => group.filters).find(stat => stat.id === life.tradeId[0])
  assert.deepEqual(queryStat.value, { min: -20, max: -15 })
})

test('Traditional Chinese text uses the same canonical international query', () => {
  for (const name of ['chaos-orb', 'tabula-rasa', 'rare-ring']) {
    const chinese = analyze(`${name}-zh`, 'cmn-Hant')
    const english = analyze(name)
    assert.equal(chinese.ok, true, chinese.error)
    assert.deepEqual(chinese.query, english.query)
    assert.equal(chinese.item.id, english.item.id)
    assert.notEqual(chinese.item.name, english.item.name)
  }
})

test('malformed and ordinary equipment text return useful errors without throwing', () => {
  for (const input of ['{', JSON.stringify({ text: '' }), JSON.stringify({ text: 'not an item' }), JSON.stringify({ text: fixture('rare-ring'), language: 'fr' })]) {
    const value = JSON.parse(core.analyze(input))
    assert.equal(value.ok, false)
    assert.equal(typeof value.error, 'string')
  }
  const ordinary = fixture('rare-ring').split('\n').filter(line => !line.startsWith('{')).join('\n')
  const value = JSON.parse(core.analyze(JSON.stringify({ text: ordinary })))
  assert.equal(value.ok, false)
  assert.match(value.error, /advanced modifier/)
  assert.equal(JSON.parse(core.buildQuery('{}')).ok, false)
})
