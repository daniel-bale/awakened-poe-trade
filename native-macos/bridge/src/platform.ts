import type { ParsedItem } from '@/parser'

export const PERMANENT_SC = ['Standard', '標準模式']
export function tradeTag (item: ParsedItem) { return item.info.tradeTag }

// Native code owns networking and rate limiting. These exports allow esbuild
// to discard the renderer's network functions without pulling in browser code.
function nativeOnly (): never { throw new Error('Networking belongs to the native host.') }
export const Host = { proxy: nativeOnly }
export const getTradeEndpoint = nativeOnly
export const adjustRateLimits = nativeOnly
export const preventQueueCreation = nativeOnly
export const RATE_LIMIT_RULES = {}
export class RateLimiter { static waitMulti = nativeOnly }
export class Cache { get = nativeOnly; set = nativeOnly; static deriveTtl = nativeOnly }
