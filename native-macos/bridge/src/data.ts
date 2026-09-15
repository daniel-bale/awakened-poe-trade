import type { BaseType, Stat, StatOrGroup, TranslationDict } from '@/assets/data/interfaces'
import english from '../../../renderer/public/data/en/client_strings.js'
import chinese from '../../../renderer/public/data/cmn-Hant/client_strings.js'
import englishItems from '../../../renderer/public/data/en/items.ndjson'
import englishStats from '../../../renderer/public/data/en/stats.ndjson'
import chineseItems from '../../../renderer/public/data/cmn-Hant/items.ndjson'
import chineseStats from '../../../renderer/public/data/cmn-Hant/stats.ndjson'
export { default as ITEM_DROP } from '../../../renderer/public/data/item-drop.json'

export * from '@/assets/data/interfaces'
export type Language = 'en' | 'cmn-Hant'
export let CLIENT_STRINGS: TranslationDict = english
export const CLIENT_STRINGS_REF: TranslationDict = english

type Dataset = {
  items: BaseType[]
  stats: StatOrGroup[]
  itemByName: Map<string, BaseType[]>
  itemByRef: Map<string, BaseType[]>
  statByRef: Map<string, StatOrGroup>
  statByMatcher: Map<string, StatOrGroup>
  itemText: string
  statText: string
}

const cache = new Map<Language, Dataset>()
let current: Dataset
const requestedStats = new Set<string>()

function lines<T> (value: string): T[] { return value.trimEnd().split('\n').map(line => JSON.parse(line)) }
function addItem (index: Map<string, BaseType[]>, key: string, item: BaseType) {
  const entries = index.get(key) ?? []
  entries.push(item)
  index.set(key, entries)
}

export function setLanguage (language: Language) {
  CLIENT_STRINGS = language === 'en' ? english : chinese
  let data = cache.get(language)
  if (!data) {
    const itemText = language === 'en' ? englishItems : chineseItems
    const statText = language === 'en' ? englishStats : chineseStats
    data = {
      items: lines<BaseType>(itemText), stats: lines<StatOrGroup>(statText),
      itemByName: new Map(), itemByRef: new Map(), statByRef: new Map(), statByMatcher: new Map(),
      itemText, statText
    }
    for (const item of data.items) {
      addItem(data.itemByName, `${item.namespace}::${item.name}`, item)
      addItem(data.itemByRef, `${item.namespace}::${item.refName}`, item)
    }
    for (const group of data.stats) {
      for (const stat of 'stats' in group ? group.stats : [group]) {
        data.statByRef.set(stat.ref, group)
        for (const matcher of stat.matchers) data.statByMatcher.set(matcher.advanced ?? matcher.string, group)
      }
    }
    cache.set(language, data)
  }
  current = data
  for (const ref of requestedStats) {
    if (!current.statByRef.has(ref)) throw new Error(`Cannot find stat: ${ref}`)
  }
}

export function ITEM_BY_TRANSLATED (namespace: BaseType['namespace'], name: string) { return current.itemByName.get(`${namespace}::${name}`) }
export function ITEM_BY_REF (namespace: BaseType['namespace'], name: string) { return current.itemByRef.get(`${namespace}::${name}`) }
export function * ITEMS_ITERATOR (includes: string, andIncludes: string[] = []): Generator<BaseType> {
  for (const line of current.itemText.trimEnd().split('\n')) {
    if (line.includes(includes) && andIncludes.every(text => line.includes(text))) yield JSON.parse(line)
  }
}
export function * STATS_ITERATOR (includes: string, andIncludes: string[] = []): Generator<Stat> {
  for (const line of current.statText.trimEnd().split('\n')) {
    if (!line.includes(includes) || !andIncludes.every(text => line.includes(text))) continue
    const group = JSON.parse(line) as StatOrGroup
    yield * ('stats' in group ? group.stats : [group])
  }
}
export function STAT_BY_REF_V2 (ref: string) { return current.statByRef.get(ref) }
export function STAT_BY_MATCH_STR_V2 (text: string) { return current.statByMatcher.get(text) }
export function STAT_BY_MATCH_STR (text: string) {
  const group = STAT_BY_MATCH_STR_V2(text)
  if (!group) return undefined
  const stats = ('stats' in group ? group.stats : [group]).filter(stat => stat.matchers.some(m => m.string === text || m.advanced === text))
  if (stats.length !== 1) return undefined
  const stat = stats[0]
  return { stat, matcher: stat.matchers.find(m => m.string === text || m.advanced === text)! }
}
export function pseudoStatByRef (ref: string) {
  const group = STAT_BY_REF_V2(ref)
  return group && 'stats' in group ? group.stats.find(stat => stat.ref === ref && 'pseudo' in stat.trade.ids) : group
}
export function stat (text: string) { requestedStats.add(text); return text }
