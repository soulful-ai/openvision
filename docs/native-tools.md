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

The entitlement is **not committed**, on purpose. Adding
`com.apple.developer.networking.wifi-info` to `OpenVision.entitlements` fails the device build
today (verified 2026-08-21):

```
error: Provisioning profile "iOS Team Provisioning Profile: *" doesn't include
       the Access Wi-Fi Information capability.
```

One human step unblocks it, once: developer.apple.com → Certificates, Identifiers & Profiles →
Identifiers → `app.soulless.openvision` → enable **Access Wi-Fi Information** → Save. *Then* add the
key to `OpenVision.entitlements` and rebuild; nothing in the Swift changes. Until then the tool
answers everything else and names the missing piece.

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

## Privacy

Notes are stored **in-app** (UserDefaults + Codable via `ContextualNoteStore`) — they are *not*
written to Apple Notes. Tool logging records the tool name and which parameter *keys* were passed —
never the values (note text, event titles, clipboard contents).

[259]: https://github.com/ml-explore/mlx-swift-lm/issues/259
