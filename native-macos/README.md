# Native macOS app

A SwiftUI/AppKit front end that follows the Windows application's compact price-check design: a 460-point dark panel, the original Fontin/Exo2 fonts and palette, inline modifier bounds, filter chips, and striped listings. The existing TypeScript item parser and trade filters run locally in JavaScriptCore. It does not require Electron or Node at runtime.

## Build and run

Requires macOS 14 or newer, Xcode/Swift 6, and Node/npm for the build step. The price panel uses a native AppKit window that accepts keyboard focus and has no system titlebar over the custom header.

```sh
cd native-macos
npm --prefix bridge ci
./scripts/package-app.sh
open "dist/Awakened PoE Trade.app"
```

The script builds for the current Mac's architecture, bundles the English and Traditional Chinese item databases, reuses the existing app icon, and signs the app. The generated app is self-contained. Distribution to other Macs still requires the usual Developer ID signing and notarization. `--debug` produces a debug build.

### Signing and Accessibility across rebuilds

By default the script uses ad-hoc signing (`CODE_SIGN_IDENTITY=-`). A changed ad-hoc build has a different code identity, so macOS may show the app's Accessibility toggle as enabled while rejecting the newly built app. Quit the app before rebuilding. If **Check Again** still reports denied after reopening the current build, remove only Awakened PoE Trade from **System Settings → Privacy & Security → Accessibility**, add the current `dist/Awakened PoE Trade.app` again, enable it, and relaunch. Another changed ad-hoc build may require repeating this.

For ongoing development, use an existing **Apple Development** signing identity consistently. List available identities, then pass the chosen name or SHA-1 fingerprint:

```sh
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY="<existing identity name or SHA-1 fingerprint>" ./scripts/package-app.sh
```

The script does not create certificates or change permissions. If a configured identity cannot sign the app, packaging fails and leaves the previous app bundle in place; it does not silently fall back to ad-hoc signing. Keep the signing identity and bundle identifier consistent across updates. Switching from ad-hoc to certificate signing requires approving the new identity once. For distribution, use a **Developer ID Application** identity and complete notarization separately. Apple explains how code identity affects retained privacy approvals in [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Use

1. In the app's Settings, enable macOS **Accessibility** permission for Awakened PoE Trade. This allows the app to send the game's Ctrl+C copy shortcut.
2. Hover an item in Path of Exile 1 and press **Ctrl+D**, then release the keys. The app copies the hovered item and opens its price check in one action. **Option+D** and **Command+D** are selectable two-key alternatives in Settings.
3. Click the league name at the top to open **Choose league**. Select an available league, or paste the full private-league identifier (for example, `My League (PL12345)`) into **Private or custom league** and choose **Use League**. The same picker is available in Settings. The last loaded list remains available if refresh fails.
4. Smart initial search uses the Windows item rules. Review the preset and modifier bounds, then choose **Search** or press Enter in a bound. Unidentified uniques with multiple possible identities show a chooser. Eligible stackable items use the bulk exchange API, with Chaos/Divine tabs.
5. The listing table uses the Windows grouping rules and representative initial fetching (20, then batches of 10 when needed, capped at 100). **Load more** continues the same search. Seller display, availability, listing age, merchant/default currency, stock, roll range, and grouping options are available in the panel and Settings.
6. **Trade** opens the same query or search result in the default or built-in browser. **Esc** hides the price panel and returns to the game.

Drag the empty header area on either side of the league name to move the panel.

Use **Available leagues**, or enter a private or custom league if it is absent from the list. Copy its exact full name from the trade site, including capitalization, spaces and the `(PL12345)` suffix. Private searches use the built-in **Trade Session**: sign in on the official website with an account that has league access, complete any browser verification, return to the price panel and retry. Safari has a separate session. The app does not read or copy browser credentials. An HTTP 400 still means the service rejected the query; it does not by itself prove an authentication problem.

The shortcut is registered only while Path of Exile is the focused app. Other apps retain their usual shortcuts. To check without Accessibility access, copy manually with **Ctrl+C** and use **Check Clipboard** from the app/menu bar, or paste a full description into **Paste Item Text**. Within the native app, **Ctrl+D** checks the clipboard.

Choose the item's language in Settings (English or Traditional Chinese). Recent checks are stored locally, capped at 50; saving new history can be disabled. Settings and history survive relaunch. The original Windows fonts are bundled with the packaged app.

Each shortcut attempt waits for key release, sends exactly one Ctrl+C to the game process, then waits for changed clipboard contents. It rejects stale/non-item text and cancels if focus changes. Clipboard restoration defaults on and preserves available data representations only if the clipboard has not changed again. Permission is requested only through an explicit setup action.

Trade requests share one serialized queue across anonymous and browser sessions, are separated by at least five seconds, and are cancellable. Server rate-limit headers and an optional extra delay extend waiting. Failed requests are never retried automatically. A bulk search may make a second currency-specific request when its optimistic result underrepresents Chaos offers, as in Windows. Parsing remains local; Search sends the derived trade query. Smart initial search can be disabled in Settings.

Public-league market data includes poe.ninja prices, seven-day trends, Divine conversion, stack values and related items. Private leagues do not receive substituted public-league prices. Local dust valuation remains available. Optional English rare-item prediction sends item descriptions to poeprices.info only when enabled; it is off by default and includes confidence, contributing stats and an explicit feedback control.

This native front end covers the price-check workflow. Overlay widgets, chat macros, map-check tools and the other non-price-check features remain in the Electron app. The native app targets Path of Exile 1 and currently bundles English and Traditional Chinese item databases. Its database follows the checked-out repository version. See [PARITY.md](PARITY.md) for source references, coverage, and remaining verification limits.

## Verification

```sh
npm --prefix bridge test
swift test
```

`bridge test` also regenerates the JavaScriptCore resource. It must exist before a clean `swift build` or `swift test`. See [bridge/README.md](bridge/README.md) for the bridge contract and build-time platform adapters.

On restricted hosts, npm/Swift caches can be directed into a writable temporary directory. The packaging script already uses caches under `.build`; an external volume may require the shell's normal build approval.

See [TESTING.md](TESTING.md) for the on-machine verification record and its limits.
