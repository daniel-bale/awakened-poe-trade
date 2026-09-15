import { parseClipboard, makeIdentifiedUnique, ItemCategory, type ParsedItem } from '@/parser'
import { createPresets } from '@/web/price-check/filters/create-presets'
import { createTradeRequest, CATEGORY_TO_TRADE_ID } from '@/web/price-check/trade/pathofexile-trade'
import { createTradeRequest as createBulkRequest } from '@/web/price-check/trade/pathofexile-bulk'
import { getDetailsId } from '@/web/price-check/trends/getDetailsId'
import { getTradeMaxQuality } from '@/parser/calc-q20'
import type { ItemFilters, FilterOrGroup } from '@/web/price-check/filters/interfaces'
import { ModifierType } from '@/parser/modifiers'
import { groupLinesByMod, isModInfoLine, parseModInfoLine, parseModType } from '@/parser/advanced-mod-desc'
import { tryParseTranslation } from '@/parser/stat-translations'
import { setLanguage, ITEMS_ITERATOR, ITEM_BY_REF, ITEM_DROP, type Language } from './data'

// JavaScriptCore deliberately has no browser console. The shared parser logs
// caught parse exceptions; provide a quiet sink so it can return its error.
if (typeof globalThis.console === 'undefined') {
  globalThis.console = { log () {}, warn () {}, error () {} } as unknown as Console
}

// The shared filter engine clones plain roll records when displaying a reduced
// stat. structuredClone is a browser API absent from bare JavaScriptCore.
if (typeof globalThis.structuredClone === 'undefined') {
  globalThis.structuredClone = function clonePlainData<T> (value: T): T {
    if (Array.isArray(value)) return value.map(clonePlainData) as T
    if (value !== null && typeof value === 'object') {
      if (Object.getPrototypeOf(value) !== Object.prototype) throw new Error('The core can only clone plain item data.')
      return Object.fromEntries(Object.entries(value).map(([key, nested]) => [key, clonePlainData(nested)])) as T
    }
    return value
  }
}

const presetTitles: Record<string, string> = {
  'filters.preset_pseudo': 'Similar items',
  'filters.preset_exact': 'Exact item',
  'filters.preset_base_item': 'Crafting base',
  'filters.preset_bulk': 'Bulk items'
}

function languageOf (value: unknown): Language {
  if (value == null || value === 'en') return 'en'
  if (value === 'cmn-Hant') return value
  throw new Error('Choose English or Traditional Chinese item text.')
}

function leagueOf (value: unknown) {
  if (value == null) return 'Standard'
  if (typeof value !== 'string' || !value.trim()) throw new Error('Enter a league name.')
  const league = value.trim()
  return league === '標準模式' ? 'Standard' : league === '專家模式' ? 'Hardcore' : league
}

function protect (work: () => unknown): string {
  try { return JSON.stringify(work()) } catch (error) {
    return JSON.stringify({ ok: false, error: error instanceof Error ? error.message : String(error) })
  }
}

function queryResult (filters: ItemFilters, stats: FilterOrGroup[], league: string, tradeTag?: string) {
  validateRanges(filters, stats)
  filters.trade.league = league
  if (tradeTag && !stats.some(stat => stat.group ? !stat.meta.disabled : !stat.disabled)) {
    // The original bulk screen deliberately requests these currencies even when
    // the price filter is set, avoiding incorrect league-start prices.
    const have = tradeTag === 'chaos' ? ['divine'] : tradeTag === 'divine' ? ['chaos'] : ['divine', 'chaos']
    const query = createBulkRequest(filters, { info: { tradeTag } } as ParsedItem, have)
    return {
      kind: 'bulk', query,
      url: `https://www.pathofexile.com/trade/exchange/${encodeURIComponent(league)}?q=${encodeURIComponent(JSON.stringify({ exchange: query.query }))}`
    }
  }
  const query = createTradeRequest(filters, stats)
  // Native menus add explicit Yes/No/Any choices to source filters that only
  // distinguish exclusion from any. Keep the original default semantics intact.
  const misc = query.query.filters.misc_filters ??= { filters: {} }
  const options: Record<string, string> = { unidentified: 'identified', mirrored: 'mirrored', split: 'split', imbuedGem: 'gem_imbued', fractured: 'fractured_item', foulborn: 'mutated', vestigial: 'vestigial' }
  for (const [key, apiKey] of Object.entries(options)) {
    const filter = (filters as unknown as Record<string, { nativeValue?: boolean | null }>)[key]
    if (!filter || !Object.hasOwn(filter, 'nativeValue')) continue
    if (filter.nativeValue !== null && typeof filter.nativeValue !== 'boolean') throw new Error(`Invalid ${key} filter option.`)
    if (filter.nativeValue == null) delete (misc.filters as Record<string, unknown>)[apiKey]
    else (misc.filters as Record<string, unknown>)[apiKey] = { option: String(filter.nativeValue) }
  }
  return {
    kind: 'trade', query,
    url: `https://www.pathofexile.com/trade/search/${encodeURIComponent(league)}?q=${encodeURIComponent(JSON.stringify(query))}`
  }
}

function validateRanges (filters: ItemFilters, stats: FilterOrGroup[]) {
  const validate = (min: unknown, max: unknown, label: string) => {
    if (typeof min === 'number' && typeof max === 'number' && min > max) {
      throw new Error(`Minimum cannot exceed maximum for “${label.trim()}”.`)
    }
  }
  for (const stat of stats) {
    if (stat.group) {
      if (stat.meta.disabled) continue
      validate(stat.meta.roll?.min, stat.meta.roll?.max, stat.meta.text)
      for (const child of stat.stats) {
        if (!child.disabled) validate(child.roll?.min, child.roll?.max, child.text)
      }
    } else if (!stat.disabled) {
      validate(stat.roll?.min, stat.roll?.max, stat.text)
    }
  }
  for (const [key, filter] of Object.entries(filters)) {
    if (filter && typeof filter === 'object' && filter.disabled === false) {
      validate(filter.value, filter.max, key.replace(/[A-Z]/g, character => ` ${character.toLowerCase()}`))
    }
  }
}

function summarize (item: ParsedItem) {
  // Some unidentified uniques require a roll to distinguish their market
  // variant. Missing trend metadata must not prevent a valid trade search.
  let marketQuery: ReturnType<typeof getDetailsId>
  try { marketQuery = getDetailsId(item) } catch { marketQuery = undefined }
  const marketKey = marketQuery && `${marketQuery.ns}::${marketQuery.name}${marketQuery.variant ? ` // ${marketQuery.variant}` : ''}`
  const drop = marketKey ? ITEM_DROP.find(entry => entry.query.includes(marketKey)) : undefined
  const related = [...(drop?.query ?? []), ...(drop?.items ?? [])].flatMap(id => {
    const [ns, encoded] = id.split('::')
    if (!ns || !encoded) return []
    const [name, variant] = encoded.split(' // ')
    return [{ name, query: { ns, name, variant }, highlighted: id === marketKey }]
  })
  const properties: Array<{ label: string, value: string }> = []
  const add = (label: string, value: unknown, suffix = '') => {
    if (value != null) properties.push({ label, value: `${String(value)}${suffix}` })
  }
  add('Item level', item.itemLevel)
  add('Quality', item.quality, '%')
  add('Gem level', item.gemLevel)
  add('Map tier', item.mapTier)
  add('Area level', item.areaLevel)
  add('Disenchant dust', item.dustEquivalent)
  add('Armour', item.armourAR)
  add('Evasion', item.armourEV)
  add('Energy shield', item.armourES)
  add('Ward', item.armourWARD)
  add('Block', item.armourBLOCK, '%')
  add('Physical DPS', item.weaponPHYSICAL != null && item.weaponAS != null ? Math.round(item.weaponPHYSICAL * item.weaponAS * 10) / 10 : undefined)
  add('Elemental DPS', item.weaponELEMENTAL != null && item.weaponAS != null ? Math.round(item.weaponELEMENTAL * item.weaponAS * 10) / 10 : undefined)
  add('Critical strike chance', item.weaponCRIT, '%')
  add('Attacks per second', item.weaponAS)
  add('Linked sockets', item.sockets?.linked)
  if (item.stackSize) add('Stack size', `${item.stackSize.value} / ${item.stackSize.max}`)
  if (item.isCorrupted) add('Corrupted', 'Yes')
  if (item.isUnidentified) add('Identified', 'No')
  if (item.isFractured) add('Fractured', 'Yes')
  if (item.influences.length) add('Influence', item.influences.join(', '))
  const name = item.isUnidentified && item.info.unique ? item.info.name : (item as ParsedItem & { name?: string }).name ?? item.info.name
  // Preserve the actual clipboard ranges, e.g. "Adds 5 to 10", rather than
  // displaying the average rolls that the trade filter engine uses internally.
  const modifiers: Array<{ text: string, type: string }> = []
  for (const section of item.rawText.split(/\r?\n--------\r?\n/)) {
    const lines = section.split(/\r?\n/)
    if (isModInfoLine(lines[0])) {
      for (const group of groupLinesByMod(lines)) {
        modifiers.push({ text: group.statLines.join('\n'), type: parseModInfoLine(group.modLine).type })
      }
    } else if (lines.some(line => / \((?:enchant|scourge)\)$/.test(line))) {
      const parsed = parseModType(lines)
      modifiers.push({ text: parsed.lines.join('\n'), type: parsed.modType })
    }
  }
  return {
    id: `${item.info.namespace}:${item.info.refName}`,
    identity: `${item.info.namespace}:${item.info.refName}`,
    name,
    baseType: item.uniqueBase?.name ?? item.info.name,
    rarity: item.rarity ?? (item.category === 'Currency' ? 'Currency' : 'Normal'),
    category: item.category,
    itemLevel: item.itemLevel,
    icon: item.info.icon,
    dustEquivalent: item.dustEquivalent,
    market: {
      query: marketQuery ?? null, related,
      stackSize: item.stackSize?.value, stackMax: item.stackSize?.max, dustEquivalent: item.dustEquivalent,
      predictionEligible: item.rarity === 'Rare' && !item.isUnidentified &&
        ![ItemCategory.Map, ItemCategory.CapturedBeast, ItemCategory.HeistContract, ItemCategory.HeistBlueprint, ItemCategory.Chart, ItemCategory.Invitation].includes(item.category!) &&
        item.info.refName !== 'Expedition Logbook'
    },
    properties,
    modifiers,
    unknownModifiers: item.unknownModifiers.map(modifier => modifier.text),
    rawText: item.rawText
  }
}

function annotateStats (stats: FilterOrGroup[], item: ParsedItem): unknown[] {
  const annotate = (stat: FilterOrGroup): unknown => {
    if (stat.group) return { ...stat, meta: annotate(stat.meta), stats: stat.stats.map(annotate) }
    return {
      ...stat,
      nativeQuality: ['item.armour', 'item.evasion_rating', 'item.energy_shield', 'item.ward', 'item.total_dps', 'item.physical_dps'].includes(stat.tradeId[0]) ? getTradeMaxQuality(item) : undefined,
      nativeOils: stat.oils?.map(refName => { const info = ITEM_BY_REF('ITEM', refName)?.[0]; return { refName, name: info?.name ?? refName, icon: info?.icon } })
    }
  }
  return stats.map(annotate)
}

/** JSON-in/JSON-out avoids bridging JS object graphs or exceptions into Swift. */
export function analyze (json: string): string {
  return protect(() => {
    const input = JSON.parse(json)
    const language = languageOf(input.language)
    const league = leagueOf(input.league)
    if (typeof input.text !== 'string' || !input.text.trim()) throw new Error('Copy an item in Path of Exile, then choose Check Clipboard.')
    if (input.text.length > 100_000) throw new Error('The clipboard is too large to be a Path of Exile item.')
    setLanguage(language)
    const parsed = parseClipboard(input.text.trim())
    if (parsed.isErr()) throw new Error(`Could not read this item (${parsed.error}). Copy an item with Control+C (Ctrl+C) in Path of Exile and check the item language.`)
    let item = parsed.value
    if (item.rarity === 'Unique' && item.isUnidentified && !item.info.unique) {
      const seen = new Set<string>()
      const candidates = [...ITEMS_ITERATOR(JSON.stringify(item.info.refName))].filter(candidate => {
        if (candidate.namespace !== 'UNIQUE' || candidate.unique?.base !== item.info.refName || seen.has(candidate.refName)) return false
        seen.add(candidate.refName)
        return true
      })
      const selected = input.uniqueRefName == null && candidates.length === 1 ? candidates[0] : candidates.find(candidate => candidate.refName === input.uniqueRefName)
      if (input.uniqueRefName != null && !selected) throw new Error('That unique item does not match this unidentified base.')
      if (selected) item = makeIdentifiedUnique(selected, item)
      else return {
        ok: true, language, league, item: summarize(item), requiresIdentification: true,
        uniqueCandidates: candidates.map(candidate => ({ id: candidate.refName, name: candidate.name, icon: candidate.icon })),
        shouldAutoSearch: false, presets: [], activePreset: '', kind: 'trade', query: null, url: ''
      }
    } else if (input.uniqueRefName != null) throw new Error('This item does not need unique identification.')
    const hasAdvancedMods = /^\{.*\}$/m.test(input.text)
    if (!hasAdvancedMods && !item.isUnidentified && (
      item.rarity === 'Rare' || item.rarity === 'Magic' ||
      (item.rarity === 'Unique' && input.text.split(/\r?\n/).some((line: string) =>
        tryParseTranslation({ string: line.replace(/ \(implicit\)$/, ''), unscalable: true }, ModifierType.Explicit, item.category)))
    )) {
      throw new Error('This item is missing advanced modifier descriptions. Copy the full item description in Path of Exile again so its modifiers can be searched.')
    }
    const options = input.options ?? {}
    if (options.collapseListings != null && !['api', 'app'].includes(options.collapseListings)) throw new Error('Choose API or app listing grouping.')
    if (options.searchStatRange != null && (typeof options.searchStatRange !== 'number' || options.searchStatRange < 0 || options.searchStatRange > 100)) throw new Error('Modifier range must be between 0 and 100 percent.')
    if (options.currency != null && (typeof options.currency !== 'string' || !options.currency.trim())) throw new Error('Choose a valid price currency.')
    for (const key of ['merchantOnly', 'activateStockFilter']) {
      if (options[key] != null && typeof options[key] !== 'boolean') throw new Error(`Invalid ${key} setting.`)
    }
    const result = createPresets(item, {
      league,
      merchantOnly: options.merchantOnly ?? true,
      collapseListings: options.collapseListings ?? 'api',
      activateStockFilter: options.activateStockFilter ?? false,
      searchStatRange: options.searchStatRange ?? 10,
      useEn: true,
      currency: options.currency ?? null
    })
    const active = result.presets.find(preset => preset.id === result.active)!
    return {
      ok: true,
      language,
      league,
      item: summarize(item),
      requiresIdentification: false,
      uniqueCandidates: [],
      shouldAutoSearch: Boolean(item.rarity === 'Unique' || result.active === 'filters.preset_bulk' || item.mapCompletionReward ||
        [ItemCategory.HeistContract, ItemCategory.HeistBlueprint, ItemCategory.SanctumRelic, ItemCategory.Charm, ItemCategory.Idol].includes(item.category!) ||
        (!CATEGORY_TO_TRADE_ID.has(item.category!) && item.info.refName !== 'Mercenary Warrant') || item.isUnidentified || item.isVeiled),
      presets: result.presets.map(preset => ({ ...preset, stats: annotateStats(preset.stats, item), tradeTag: item.info.tradeTag, title: presetTitles[preset.id] ?? preset.id })),
      activePreset: result.active,
      ...queryResult(active.filters, active.stats, league, item.info.tradeTag)
    }
  })
}

export function resolveUnique (json: string): string {
  return protect(() => {
    const input = JSON.parse(json)
    if (typeof input.uniqueRefName !== 'string' || !input.uniqueRefName) throw new Error('Choose a unique item first.')
    return JSON.parse(analyze(json))
  })
}

export function buildQuery (json: string): string {
  return protect(() => {
    const input = JSON.parse(json)
    const league = leagueOf(input.league)
    setLanguage(languageOf(input.language))
    if (!input.filters?.trade || !input.filters?.searchExact || !Array.isArray(input.stats)) {
      throw new Error('The item filters are missing. Check the item again.')
    }
    if (input.tradeTag != null && (typeof input.tradeTag !== 'string' || !input.tradeTag)) throw new Error('The bulk item type is missing. Check the item again.')
    return { ok: true, ...queryResult(input.filters, input.stats, league, input.tradeTag) }
  })
}
