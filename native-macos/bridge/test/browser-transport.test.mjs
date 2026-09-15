import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

// Run the actual Swift-embedded function bodies with mocked browser APIs.
// These contract tests make no network requests and do not use real credentials.
const source = readFileSync(new URL('../../Sources/AwakenedPoeTrade/TradeBrowserSession.swift', import.meta.url), 'utf8')
function embeddedScript(name) {
  const marker = `private static let ${name} = #"""`
  const start = source.indexOf(marker)
  assert.notEqual(start, -1, `Missing embedded ${name}`)
  const end = source.indexOf('"""#', start + marker.length)
  assert.notEqual(end, -1, `Unterminated embedded ${name}`)
  return source.slice(start + marker.length, end)
}
const fetchScript = embeddedScript('fetchScript')
const abortScript = embeddedScript('abortScript')
const apiURL = 'https://www.pathofexile.com/api/trade/search/Standard'
const fixtureBody = '{"result":[]}'

function context(overrides = {}) {
  const document = {}
  Object.defineProperty(document, 'cookie', {
    get() { throw new Error('The transport must not read browser cookies') }
  })
  return vm.createContext({
    URL, Map, Set, Uint8Array, String, AbortController, setTimeout, clearTimeout, btoa, document,
    location: { origin: 'https://www.pathofexile.com' },
    requestID: 'fixture-request', requestURL: apiURL, requestMethod: 'POST',
    requestHeaders: { 'Content-Type': 'application/json' }, requestBody: '{"query":{}}',
    timeoutMilliseconds: 1000,
    fetch: async () => { throw new Error('Unexpected network request') },
    ...overrides
  })
}

function run(ctx, script = fetchScript) {
  return vm.runInContext(`(async () => {${script}\n})()`, ctx)
}

function response(status = 200) {
  return {
    status, url: apiURL,
    headers: new Map([
      ['content-type', 'application/json'], ['retry-after', '7'],
      ['x-rate-limit-account', '5:10:60'], ['x-rate-limit-account-state', '1:10:0'],
      ['set-cookie', 'fixture-session=private'], ['unrelated', 'omitted']
    ]),
    arrayBuffer: async () => new TextEncoder().encode(fixtureBody).buffer
  }
}

function waitUntilAborted(_url, options) {
  return new Promise((_resolve, reject) => {
    const abort = () => reject(Object.assign(new Error('fixture abort'), { name: 'AbortError' }))
    if (options.signal.aborted) abort()
    else options.signal.addEventListener('abort', abort, { once: true })
  })
}

test('POST is sent once with same-origin credentials and preserves rate limits without exposing cookies', async () => {
  let calls = 0
  let receivedURL
  let options
  const body = JSON.stringify({ query: { name: 'Literal "; throw new Error("not code")' } })
  const ctx = context({
    requestBody: body,
    fetch: async (url, request) => { calls++; receivedURL = url; options = request; return response(429) }
  })
  const result = await run(ctx)
  assert.equal(calls, 1)
  assert.equal(receivedURL, apiURL)
  assert.equal(options.method, 'POST')
  assert.equal(options.body, body)
  assert.equal(options.headers['Content-Type'], 'application/json')
  assert.equal(options.headers.Cookie, undefined)
  assert.equal(options.headers.Authorization, undefined)
  assert.equal(options.credentials, 'same-origin')
  assert.equal(options.mode, 'same-origin')
  assert.equal(options.redirect, 'error')
  assert.equal(result.status, 429)
  assert.equal(result.url, apiURL)
  assert.equal(result.headers['content-type'], 'application/json')
  assert.equal(result.headers['retry-after'], '7')
  assert.equal(result.headers['x-rate-limit-account'], '5:10:60')
  assert.equal(result.headers['x-rate-limit-account-state'], '1:10:0')
  assert.equal(result.headers['set-cookie'], undefined)
  assert.equal(result.headers.unrelated, undefined)
  assert.equal(JSON.stringify(result).includes('fixture-session'), false)
  assert.equal(Buffer.from(result.body, 'base64').toString(), fixtureBody)
})

for (const [name, overrides] of [
  ['a foreign main-frame origin', { location: { origin: 'https://other.example' } }],
  ['a foreign API origin', { requestURL: 'https://other.example/api/trade/search/Standard' }],
  ['a non-trade API path', { requestURL: 'https://www.pathofexile.com/account' }],
  ['an unencrypted API URL', { requestURL: 'http://www.pathofexile.com/api/trade/search/Standard' }],
  ['credentials in the API URL', { requestURL: 'https://user@www.pathofexile.com/api/trade/search/Standard' }],
  ['a fragment in the API URL', { requestURL: `${apiURL}#fragment` }]
]) {
  test(`rejects ${name} before fetching`, async () => {
    let calls = 0
    const ctx = context({ ...overrides, fetch: async () => { calls++; return response() } })
    assert.equal((await run(ctx)).failure, 'wrong-origin')
    assert.equal(calls, 0)
  })
}

test('a rejected fetch produces a safe error and never retries the POST', async () => {
  let calls = 0
  const ctx = context({ fetch: async () => { calls++; throw new TypeError('private fixture redirect or network details') } })
  const result = await run(ctx)
  assert.equal(result.failure, 'request-failed')
  assert.equal(calls, 1)
  assert.equal(JSON.stringify(result).includes('private fixture'), false)
})

test('the request timeout aborts the pending fetch', { timeout: 1500 }, async () => {
  const ctx = context({ timeoutMilliseconds: 10, fetch: waitUntilAborted })
  assert.equal((await run(ctx)).failure, 'aborted')
})

test('cancellation delivered before fetch prevents the request', async () => {
  let calls = 0
  const ctx = context({ fetch: async () => { calls++; return response() } })
  await run(ctx, abortScript)
  assert.equal((await run(ctx)).failure, 'aborted')
  assert.equal(calls, 0)
})

test('cancellation after fetch starts aborts that request', { timeout: 1500 }, async () => {
  let calls = 0
  const ctx = context({ fetch: (...args) => { calls++; return waitUntilAborted(...args) } })
  const pending = run(ctx)
  assert.equal(calls, 1)
  await run(ctx, abortScript)
  assert.equal((await pending).failure, 'aborted')
  assert.equal(calls, 1)
})

test('oversized responses fail without returning their body', async () => {
  const ctx = context({ fetch: async () => ({ ...response(), arrayBuffer: async () => new ArrayBuffer(8_388_609) }) })
  const result = await run(ctx)
  assert.equal(result.failure, 'too-large')
  assert.equal(result.body, undefined)
})

test('GET requests have no body and return the response bytes', async () => {
  let calls = 0
  const ctx = context({
    requestMethod: 'GET', requestBody: null,
    fetch: async (_url, options) => {
      calls++
      assert.equal(options.method, 'GET')
      assert.equal(options.body, null)
      return response()
    }
  })
  const result = await run(ctx)
  assert.equal(calls, 1)
  assert.equal(result.status, 200)
  assert.equal(Buffer.from(result.body, 'base64').toString(), fixtureBody)
})
