# Native Productivity Tools

Hands-free productivity actions the AI can invoke by voice — timers, Pomodoro, reminders,
calendar, notes, and clipboard. Built on stable Apple frameworks (EventKit, UserNotifications,
CoreLocation, UIPasteboard), so they are **deterministic** with no vision/hallucination surface:
the model only decides *when* to call a tool and *with what arguments*; the tool does the work.

## The tools

| Tool | Name | Backing framework | Notes |
|------|------|-------------------|-------|
| Timer | `set_timer` | UserNotifications | Countdown; foreground banner + in-app chime |
| Pomodoro | `start_pomodoro` | UserNotifications | Work block → break (defaults 25/5) |
| Reminder | `create_reminder` | EventKit (Reminders) | Optional due time |
| Calendar | `calendar` | EventKit (Events) | `today` / `upcoming` / `add` |
| Note | `note` | UserDefaults + CoreLocation | `save` / `search` / `list` / `delete`, auto-tagged with place + time |
| Clipboard | `copy_to_clipboard` | UIPasteboard | Foreground-only write; queued + re-applied when backgrounded — see [Deferred effects](#deferred-effects--the-clipboard-and-the-wire-the-server-half-is-coded-against-aur-845) |
| Phone status | `status` | UIDevice / Network / NetworkExtension / ProcessInfo | Battery, link type, thermal, free storage — see [Phone status](#phone-status-aur-794) |
| Shazam | `shazam` | ShazamKit | 6-12 s listen on the **phone** mic — see [Shazam → Spotify](#shazam--spotify-aur-793) |
| Spotify | `spotify_play` · `spotify_like` · `spotify_now_playing` · `spotify_control` | Spotify Web API (OAuth PKCE) | Client id shipped; honest `not_linked:spotify` until someone taps **Connect** |

> There is intentionally **no alarm tool**. iOS gives third-party apps no API to create alarms in
> the Clock app, and a plain notification is a poor substitute for a wake-up alarm. Use a reminder
> with a due time instead.

## Architecture — one registry, four backends

All tools implement a single `NativeTool` protocol (name, description, JSON-schema parameters,
`execute`). `NativeToolRegistry.shared` owns the instances and exposes backend-shaped specs:

```
NativeTool  ──►  NativeToolRegistry.shared
                 ├─ openAISpecs          → OpenAI Chat Completions tools loop  (OpenAIService)
                 ├─ geminiDeclarations    → Gemini Live setup + toolCall loop    (GeminiLiveService)
                 ├─ (AppleNativeTools)    → Apple FoundationModels `Tool`        (AppleFoundationService)
                 └─ (JSON-in-text)        → on-device Gemma 4 via LocalAgent      (GemmaLocalService)
```

- **OpenAI / Gemini Live** — the model emits a native function call; we dispatch to
  `NativeToolRegistry.shared.execute(name:args:)` and feed the result back in the same turn.
- **Apple Intelligence** — Apple's `Tool` protocol needs a typed `@Generable` Arguments struct, so
  `AppleNativeTools.swift` wraps each tool in a thin forwarder to the same registry.
- **On-device Gemma 4** — small VLMs don't do reliable native tool-calling, so `LocalAgent.route`
  reuses the app's existing JSON-in-text pattern (already used for face actions + web search): the
  model replies with `{"tool":"set_timer","seconds":300}`, we parse the first `{…}` and dispatch.
  (mlx-swift-lm can't yet parse Gemma 4's native `<|tool_call>` tokens — [issue #259][259] — so the
  JSON path is both more portable and more robust here.)

Adding a tool = implement `NativeTool`, register it in `NativeToolRegistry`, add an
`AppleNativeTools` wrapper, and add one line to each backend's prompt. The dispatch is shared.

## Pixel-perfect times

Small models are unreliable at clock arithmetic (an early test turned "remind me at 6 PM" into a
reminder at 4:02 PM). So **the tool does the date math, never the model.** Reminder and Calendar
accept, in priority order (`NativeToolSupport.resolveDate`):

1. **Clock time** — `hour` (0–23) + optional `minute` + `day_offset` (0=today, 1=tomorrow). The
   model only maps "6 PM → hour 18", which even a 2B model does reliably. If no day is given and the
   time already passed today, it rolls to the next occurrence.
2. **Relative** — `minutes_from_now`, for "in N minutes / from now".
3. **ISO 8601** — `due_iso8601` / `start_iso8601`, last-resort fallback.

Every backend's prompt steers time-of-day requests to `hour`/`minute` and relative requests to
`minutes_from_now`, so times are exact on all four backends.

**Relative-time guard (registry chokepoint).** Prompts alone don't stop a model from turning
"15 minutes from now" into a self-computed (wrong) clock time. So `NativeToolRegistry.execute`
sanity-checks calendar/reminder args against the user's actual words: each backend records the
triggering utterance in `NativeToolContext` (expires after 2 min), and if it contains a clearly
relative phrase ("in N minutes", "N minutes from now", "in an hour"), the registry parses N
itself and replaces the model's time args with `minutes_from_now` — the transcript is ground
truth. Bare durations ("for 30 minutes") deliberately don't match. See
`NativeToolSupport.relativeMinutes` and its unit tests.

## Notifications & sound

Timer/Pomodoro alerts fire even while the app is foregrounded via
`NotificationForegroundPresenter` (a `UNUserNotificationCenterDelegate` returning
`[.banner, .sound, .list]`). Because an active audio session + the silent switch can suppress the
notification sound, the presenter also plays an in-app chime (`SoundService.playAlert()`, audible in
silent mode) for `timer-` / `pomodoro-` notification IDs.

## Permissions

`Info.plist` declares `NSRemindersUsageDescription` / `NSRemindersFullAccessUsageDescription`,
`NSCalendarsUsageDescription` / `NSCalendarsFullAccessUsageDescription`, and
`NSLocationWhenInUseUsageDescription` (note geotagging). Access is requested on first use.

## Deferred effects — the clipboard, and the wire the server half is coded against (AUR-845)

### What iOS actually allows

The general pasteboard is **foreground-only** and has been since iOS 9. A `UIPasteboard.general`
write from a process that is not frontmost is silently not propagated, and a read returns `nil` —
and it starts *before* the app is really in the background: "the pasteboard is even blocked before
the App is actually in the background. Even in the `applicationWillResignActive:` delegate of
`UIApplication` the pasteboard already returns nil"
([Apple Developer Forums thread 13760](https://developer.apple.com/forums/thread/13760)).

Things that do **not** lift the rule, all of them tried in `ClipboardTool.copy`:

| Attempt | What it actually does |
|---|---|
| `setItems(_:options:)` with `.localOnly` / `.expirationDate` | shapes Universal Clipboard + item lifetime, not the foreground rule |
| `beginBackgroundTask` around the write | keeps the **process** alive; it does not make the app frontmost |
| an entitlement | there is none |

So the tool **tries the write anyway** while backgrounded (background task + explicit options) and
lets the **read-back** decide — the doc says iOS drops it, the field gets to disagree — and when
the read-back fails it **queues** the text and re-applies it on `willEnterForeground` (first
chance) and `didBecomeActive` (the write iOS honours), verifying by read-back each time. A local
notification ("Скопирую, как только откроешь приложение") is the one-tap way to bring the app to
the front from whatever app the wearer is pasting into.

**Order rule, everywhere:** *write, then read back.* Reading a pasteboard whose items came from
another app raises the iOS 16+ "…would like to paste from…" alert; reading back what we just wrote
ourselves does not. No path in `ClipboardTool` reads before it writes.

### The two honest results

| Situation | `aurelia.tool_result.result` | `deferred` |
|---|---|---|
| app in front, read-back matched | `Скопировано: <preview>` | absent |
| backgrounded, the write did land anyway | `Скопировано: <preview>` | absent |
| backgrounded, queued for the foreground | `Скопирую, как только откроешь приложение: <preview>` | `true` |
| nothing to copy / write failed in front | `ok:false`, `error: nothing_to_copy` \| `pasteboard_write_failed` | — |

`deferred:true` is only ever set on an `ok:true` whose effect lands later.

### `aurelia.client_tool.applied` — client → server, once per queued effect

Sent when the queued copy **finishes**: verified by read-back after the app came to the front, or
(on `didBecomeActive`, the last chance) the final failure. Only while a session is open; with no
session it is logged and kept in Settings → Debug → Phone tools, never buffered.

```json
{
  "type": "aurelia.client_tool.applied",
  "id": "c1",
  "tool": "phone.copy_to_clipboard",
  "ok": true,
  "verifiedByReadback": true,
  "stage": "active",
  "queuedMs": 41230,
  "appState": "active",
  "chars": 42
}
```

| Field | Meaning |
|---|---|
| `id` | the `aurelia.tool_call` id this completes. **Absent** (not null) when the copy came through the push-to-ask path, which has no wire id |
| `tool` | always the `phone.*` wire name — `phone.copy_to_clipboard` today |
| `ok` | the text is on the pasteboard now |
| `verifiedByReadback` | `ok` was decided by reading the pasteboard back, not assumed. (Today `ok == verifiedByReadback`; the field is separate so a future "landed but unverifiable" path can say so) |
| `stage` | `"foreground"` (`willEnterForeground`) \| `"active"` (`didBecomeActive`) \| `"manual"` |
| `queuedMs` | how long the text waited |
| `appState` | the app state at the moment of the re-apply |
| `chars` | length of the copied text — never the text itself |

**Server half (not implemented on the client side, AUR-845 stops here):** log the frame against the
originating tool call, and let the brain say the landing out loud — e.g. «скопировано» on `ok:true`,
and on `ok:false` tell the wearer the copy did not survive. A `deferred:true` result that never gets
its `applied` frame means the wearer never opened the app: worth a nudge after a while.

### `session.update.metadata.appState`

The client re-declares its metadata whenever the app's foreground state changes during a call
(`didBecomeActive` / `willResignActive` / `didEnterBackground` / `willEnterForeground`, deduped to
real changes) — the same rail AUR-803b built for `tz` / `utcOffsetMin`:

```json
{ "type": "session.update",
  "session": { "metadata": { "client": "openvision", "proto": "aurelia.v2", "route": "a2dp+phone-mic",
                             "aec": true, "tz": "Europe/Amsterdam", "utcOffsetMin": 120,
                             "appState": "background" } } }
```

`appState` is `"active"` | `"inactive"` | `"background"`. The brain needs it to read a `deferred`
clipboard result without guessing: the phone is in the wearer's pocket, so the paste has **not**
landed yet.

## Phone status (AUR-794)

`phone.status` answers «сколько батареи?» / «какой вайфай?» from the glasses. It reads only stable
Apple APIs and has **no `permissionKind`** — battery, thermal, storage and the interface type need
no permission, and gating the whole call behind a location prompt would make "how much battery"
fail for the wrong reason. The one part that does need something reports its own state inline,
which is the AUR-836 rule applied inside a result instead of around it.

| Field | Source | Absent when |
|---|---|---|
| `battery %` + charging | `UIDevice.current.batteryLevel` / `batteryState` (monitoring enabled on first read) | simulator (`-1`) |
| link + `expensive` / low-data | `NWPathMonitor`, one shot, first update wins, 2-s cap | never (falls back to `offline`) |
| Wi-Fi **name** | `NEHotspotNetwork.fetchCurrent()` | see the two misses below |
| thermal | `ProcessInfo.thermalState` | never |
| free storage | `volumeAvailableCapacityForImportantUsage` | never in practice |
| glasses battery | DAT SDK | **always today** — see below |

**The Wi-Fi name needs two things, and the tool says which one is missing.**
`NEHotspotNetwork.fetchCurrent()` returns `nil` both when Location is not granted and when the app
lacks the *Access Wi-Fi Information* entitlement, so the tool reads the location status itself and
reports `ssidMiss: location_permission` | `entitlement` | `not_wifi` | `simulator`. It never guesses
a network name.

**The entitlement is committed as of AUR-845b (2026-08-21).** It was held back for one morning
because the app signed against the XC wildcard profile, which carries no capabilities at all:

```
error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't include
       the Access Wi-Fi Information capability.
```

The fix was not in the repo. `app.soulless.openvision` is now an **explicit App ID** (`4DUB6L4475`,
team `3JAHQ7PYLM`) with *Access Wi-Fi Information* enabled, and automatic signing has to pick it to
satisfy the key — the build log now reads `Provisioning Profile: "iOS Team Provisioning Profile:
app.soulless.openvision"`, not `: *`. `com.apple.developer.networking.wifi-info` is in
`OpenVision.entitlements`; nothing in the Swift changed. The `ssidMiss: entitlement` branch stays —
it is now a real signal (a mis-signed build) rather than the expected state.

**One trap for anyone building this from the CLI.** Fetching the explicit profile needs portal
access, and `xcodebuild` has none: with no Apple ID in Xcode's Accounts it fails with
`error: No Accounts: Add a new account in Accounts settings` and silently falls back to the cached
wildcard profile. Authenticate with the App Store Connect API key instead:

```
xcodebuild build … -allowProvisioningUpdates \
  -authenticationKeyPath ~/.private_keys/AuthKey_6MU7DYSFH7.p8 \
  -authenticationKeyID 6MU7DYSFH7 \
  -authenticationKeyIssuerID be177da0-1e8f-46af-bd33-f243f86f793a
```

**The glasses battery is absent, not faked.** The pinned SDK
(`meta-wearables-dat-ios` **0.4.0**, see `project.yml`) declares
`public struct DeviceState { public let batteryLevel: Int; public let hingeState: HingeState }` and
`final public class DeviceStateSession` — but that class publishes only `state: SessionState`,
`start()` and `stop()`: no accessor, listener or stream in the public interface ever hands a
`DeviceState` back, and `WearablesInterface` has no battery member either. So the number is
unreachable and the result carries `glasses battery unavailable (dat_0.4.0_no_public_accessor)`.
`GlassesManager.glassesBatteryPercent` is the single place to fill in when a later DAT exposes it.

## Connections — the screen IS the wire (AUR-795)

`Settings → Connections` lists one row per integration: what she can do with it in one line, the
live state, a **Connect** button (the OS prompt, or the account link), and a **kill switch**.

The invariant that keeps it honest: **the switch state is what the wire carries.** Each row
contributes exactly one key to `aurelia.client_tools.connections`, and a row that is switched off

1. reports `off` on that key, and
2. has its tools removed from the `tools` array of the manifest — the brain is never told about a
   tool the wearer switched off.

| Row | Tools | State values |
|---|---|---|
| Calendar | `phone.calendar` | granted / denied / unknown / off |
| Reminders | `phone.create_reminder` | granted / denied / unknown / off |
| Notifications | `phone.set_timer`, `phone.start_pomodoro` | granted / denied / unknown / off |
| Location | *(none — unlocks the Wi-Fi name in `phone.status` and the place tag on notes)* | granted / denied / unknown / off |
| Notes | `phone.note` | on / off |
| Clipboard | `phone.copy_to_clipboard` | on / off |
| My Documents | `phone.search_docs` | on / off |
| Phone status | `phone.status` | on / off |
| Shazam | `phone.shazam` | granted / denied / unknown / off (microphone) |
| Spotify | `phone.spotify_*` | linked / unlinked / off |

Apple Music and Shortcuts are on the plan (AUR-796) and deliberately have no row yet — a row that
promises nothing is worse than no row.

**Mid-call flips are honoured immediately.** `PhoneIntegrationStore` persists the off-set in
UserDefaults (default: everything on, only explicit off-switches are stored, so a newly shipped
integration is live without a migration) and posts `PhoneIntegrationStore.didChange`; the bridge
observes it while a session is open and re-sends the manifest — the same rail AUR-836 uses when a
permission prompt resolves.

**A call for a switched-off tool is `disabled:<row>`, not `unknown_tool`** — the two mean different
things to the brain: one is "you switched it off in Connections", the other is "that tool does not
exist". A tool name that was never registered still answers `unknown_tool`.

## Shazam → Spotify (AUR-793)

«Аурелия, что за песня?» → START earcon → 6-12 s listen → «Это Queen — Bohemian Rhapsody» →
«включи её» → «лайкни». Two halves with very different readiness:

### `phone.shazam` — works with no account at all

ShazamKit matches against Apple's catalog on device; there is no login and no key of ours.

**It listens on the PHONE mic, on purpose.** When the glasses mic is open the route is HFP —
8 kHz narrowband, speech-shaped, with the far end's AGC on top. Shazam matches a spectral
fingerprint of the original recording, which narrowband voice audio does not carry, so a match on
the glasses mic fails reliably. The tool therefore sets the audio session's preferred input to the
built-in mic for the duration and restores the previous preference afterwards. If there is no
built-in mic to switch to (or the switch fails) it listens on the current route and **says so** —
the result carries `mic: glasses`, and a no-match on that mic explains itself
(«слушала через микрофон очков… достань телефон»), because that is something the wearer can act on.

A no-match is `ok:false, error: no_match` — never `ok:true` for "nothing happened" (the AUR-833
rule). The tool gets a 20-s wire timeout (`timeoutOverrides`), since the 8-s default would cut a
12-s listen in half. The match is kept in `ShazamLastMatch` so «включи её» has an antecedent without
the model having to carry an id.

**The portal toggle is on** (developer.apple.com → Identifiers → `app.soulless.openvision` →
App Services → **ShazamKit**), confirmed straight from the App Store Connect API on 2026-08-21:
bundle id `4DUB6L4475` carries `IN_APP_PURCHASE`, `SHAZAM_KIT`, `ACCESS_WIFI_INFORMATION`.

**There is still no `com.apple.developer.shazamkit` key in the entitlements file, and that is
correct — not an oversight.** ShazamKit is an App *Service*, authorised server-side by bundle id,
not a profile capability. Three independent checks say the same thing:

* the development profile Apple issued *minutes after* the toggle
  (`iOS Team Provisioning Profile: app.soulless.openvision`) carries `wifi-info` and **no** shazam key;
* adding the key anyway fails the device build —
  `error: Entitlement com.apple.developer.shazamkit not found and could not be included in profile.
  This likely is not a valid entitlement and should be removed from your entitlements file.`;
* Xcode 26.5's own capability bundle lists 192 capabilities, none of them `SHAZAM_KIT`, and the
  string `com.apple.developer.shazamkit` appears nowhere in Xcode.

So the honest reporting in `ShazamTool` stays the truth-teller: if catalog matching is still refused
on device, `shazam_failed:<code>` is the signal to chase — a missing entitlement key is not the cause,
because there is no key to add.

### `phone.spotify_*` — the developer app exists; one tap left

The Spotify app **OpenVision (Aurelia)** exists (redirect URI `openvision://spotify`, Web API,
Development mode, iOS bundle `app.soulless.openvision`) and its client id rides `Config.xcconfig` →
`Info.plist` into the build. `SpotifyConfig.isConfigured` is now **true**, so the Connections row's
blocker is gone and its button is a real **Connect**.

The account is still unlinked until somebody logs in, and that cannot be automated: linking opens an
`ASWebAuthenticationSession` sheet and needs a human at the phone. Until then the connection reports
`unlinked` and **every** Spotify tool answers `not_linked:spotify` with «Spotify не подключён —
открой Connections в настройках и подключи». Never a fake `ok`.

**The one tap that finishes it**, on the phone with this build installed:

> **Settings → Connections → Spotify → Connect** → the Spotify login sheet → **Agree**.

The row flips to `linked`, `aurelia.client_tools.connections["spotify"]` goes out again on the next
manifest, and every `phone.spotify_*` tool starts answering for real.

Because the app is in Spotify's **Development mode**, only accounts added to its dashboard user list
can log in — the owning account works out of the box; anyone else has to be added there first.

*(For a fresh developer app, the five minutes are: developer.spotify.com → Dashboard → Create app →
name `OpenVision (Aurelia)` → Redirect URI `openvision://spotify` → tick **Web API** → Save →
Settings → copy the **Client ID** → paste into `Config.xcconfig` as `SPOTIFY_CLIENT_ID = <id>`,
which is gitignored: not a secret for a PKCE public client, but per-developer.)*

No client **secret** is ever needed or stored: the link is Authorization Code + PKCE (S256), and the
tokens live in the Keychain (never UserDefaults). Scopes requested: `user-read-playback-state`,
`user-modify-playback-state`, `user-read-currently-playing`, `user-library-modify`,
`user-library-read` — the minimum for play / pause / next / volume / now-playing / like.

Why the Web API and not the iOS SDK's App Remote: App Remote needs the Spotify app running and ships
as a binary framework to vendor; the Web API does search / play / like / now-playing / transport over
plain HTTPS and keeps working while our app is backgrounded — which a glasses call always is.

**The one thing the Web API cannot do is create a playback device.** With Spotify not open anywhere,
`PUT /me/player/play` answers `404 NO_ACTIVE_DEVICE`, and launching the Spotify app requires *our*
app to be frontmost. That is the AUR-845 deferred-effect case, handled as one: backgrounded,
`phone.spotify_play` answers `ok:true, deferred:true` with «Включу, как только откроешь приложение»,
queues the uri, and on the next `didBecomeActive` opens Spotify, starts the track and sends
`aurelia.client_tool.applied` with the same frame shape as the queued clipboard write
(`verifiedByReadback:false` — a playback start is confirmed by Spotify's own 204, not a read-back).

## Privacy

Notes are stored **in-app** (UserDefaults + Codable via `ContextualNoteStore`) — they are *not*
written to Apple Notes. Tool logging records the tool name and which parameter *keys* were passed —
never the values (note text, event titles, clipboard contents).

[259]: https://github.com/ml-explore/mlx-swift-lm/issues/259
