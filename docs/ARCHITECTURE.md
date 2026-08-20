# Architecture

How ScreenSleep is put together, and — more usefully — *why* each rule exists. Almost
every non-obvious line in `Dimmer.swift` is there because of a specific way the naive
version misbehaves.

## Components

| File | Responsibility |
| --- | --- |
| `main.swift` | Creates `NSApplication`, sets `.accessory` activation policy (menu bar only, no Dock icon), installs the delegate, runs the loop. |
| `AppDelegate.swift` | Owns the `NSStatusItem` and its menu, translates menu clicks into preference writes and `Dimmer` calls, renders the live status line, handles Launch at Login. |
| `Dimmer.swift` | The engine: idle polling, the dim/restore state machine, fading. Knows nothing about the UI beyond an `onStateChange` callback. |
| `Brightness.swift` | The only file that touches display hardware. Runtime-bound private symbols behind a small `get` / `set` / `controllableDisplays` surface. |
| `Preferences.swift` | Typed, clamped wrapper over `UserDefaults.standard`. |

Everything runs on the main thread. There is no concurrency, no queues, and no locking:
two `Timer`s on the main run loop drive the whole app. That is deliberate — brightness
writes and AppKit menu updates both want the main thread anyway, and the workload is a
handful of syscalls per second.

## The state machine

```
                     idle ≥ threshold
    ┌──────────────┐ ──────────────────► ┌──────────┐  fade done  ┌────────┐
    │ idleWatching │                     │ dimming  │ ──────────► │ dimmed │
    └──────────────┘ ◄────────────────── └──────────┘             └────────┘
            ▲          fade done  ┌───────────┐    input after dim started
            └──────────────────── │ restoring │ ◄──────────────────┘
                                  └───────────┘
```

- **idleWatching** — the armed, resting state. Samples your brightness while you're
  present; starts a dim once the idle clock passes the threshold.
- **dimming** / **restoring** — a fade is in flight. Both are interruptible: new input
  during `dimming` flips straight to `restoring`.
- **dimmed** — parked at the target level, waiting for you to come back.

`state` is `private(set)` with a `didSet` that fires `onStateChange`, which is how the
menu bar icon stays in sync without the engine knowing what a status item is.

## Idle detection

```swift
CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
```

`~0` (`0xFFFFFFFF`) is `kCGAnyInputEventType` — any keyboard, mouse, trackpad, or tablet
event. This is a *duration*, not an event stream: the app learns how long it has been
since you last touched the machine and nothing else. That is why ScreenSleep needs no
Accessibility or Input Monitoring grant, unlike anything built on an event tap.

Polled once a second with `tolerance = 0.3` so the timer can coalesce with other wakeups
and not defeat App Nap-style power savings.

## The wake rule

The obvious rule — *restore if there was input in the last few seconds* — is wrong, and
wrong in a way that makes the app look completely broken:

> Click **Dim Now** → the screen dims → one second later the next poll sees "input 1s ago"
> → it restores. The dim appears never to have happened.

The same thing swallows an automatic dim if you nudge the trackpad while checking on it.
So the rule compares two clocks instead:

```swift
let sinceDim = ProcessInfo.processInfo.systemUptime - dimStartedAt
if idle + wakeMargin < sinceDim { restore() }
```

Read it as: *the last input happened after the dim started.* Input that preceded the dim —
the click that requested it — can never cancel it. `wakeMargin` (1s) absorbs poll and fade
jitter so a borderline comparison doesn't produce a spurious wake.

`systemUptime` is used rather than wall-clock `Date` because it is monotonic and unaffected
by clock changes or NTP steps.

### Sticky dims

The wake rule only applies to *automatic* dims. `dim(sticky:)` marks a dim the user asked
for by hand, and a sticky dim ignores input entirely — it ends only via `restore()` or
`undim(to:)`. The reasoning is intent: an idle dim is the app guessing you left, so any
input disproves the guess and should undo it; **Dim Now** is you stating you want the screen
dark, and typing at a screen you deliberately blanked shouldn't overrule that. The
`wakeOnActivity` preference extends the same hold to automatic dims.

## Choosing the level to restore

Naively you'd read the brightness at dim time and put that back. Two things break it:

1. **macOS dims first.** The system runs its own fade shortly before display sleep. If that
   has already started, the "current" brightness is a value you never chose, and restoring
   it leaves your screen mysteriously dark.
2. **You might change it yourself** while the screen is dimmed.

So `lastActiveLevels` is sampled every poll while `idle < presenceThreshold` (5s) — a
continuously refreshed record of the brightness you had while demonstrably present. At dim
time the app restores `max(lastActiveLevels[id], current)`, which can't be fooled by a
fade that has already begun.

For (2), `lastWritten` records the exact value written to each display. At restore time the
app backs off only if the panel is meaningfully *brighter* than it left it (`> 0.15`) —
i.e. you turned it up to keep working, so your level wins.

The asymmetry matters. An earlier version compared `abs(written - current) > 0.03` in both
directions, which ambient-light auto-brightness trips on its own: set the panel to 0.05 and
the ALS drifts it to ~0.10 within seconds. The app would read that as "the user took over",
skip the restore, and strand you on a dark screen when you came back. Drift is not a
decision; only a deliberate brighten is.

## Fading

`fade(from:to:completion:)` steps at 30 Hz over `fadeSeconds`, interpolating with an
ease-out curve:

```swift
let eased = 1 - pow(1 - p, 2)
```

Most of the change lands early and the approach to the target is gradual, which reads as a
smooth settle rather than a cut. A `fadeSeconds` of 0 skips the timer and writes the target
directly. Only one fade can be in flight; starting another cancels the first, which is what
makes an interrupted dim reverse instantly.

## Brightness: the private-API problem

macOS has no public API for setting display brightness. It has never had one. The two that
work are private:

| Symbol | Framework | Notes |
| --- | --- | --- |
| `DisplayServicesGetBrightness` / `SetBrightness` | `DisplayServices` (private) | Primary path; drives the built-in panel on Apple silicon and Intel. Returns a non-zero status on failure. |
| `CoreDisplay_Display_GetUserBrightness` / `SetUserBrightness` | `CoreDisplay` | Fallback; also covers some external panels. Returns no status, so it is used only when the first path is unavailable. |

Both are resolved at launch with `dlopen` + `dlsym` rather than linked. Linking against
private frameworks makes the app fail to *start* if a symbol disappears in a future macOS;
resolving at runtime turns that same event into a clean, explainable failure — `isAvailable`
returns `false`, and `AppDelegate` shows an alert saying brightness control isn't available
on this macOS version, then exits. Verified working through macOS 26 on Apple silicon.

`controllableDisplays(includeExternal:)` filters `CGGetActiveDisplayList` down to displays
the app can actually *read*, treating a successful read as proof the write path exists too,
and sorts built-in first. Displays that only respond to their own hardware buttons drop out
here rather than failing later.

## Sleep and wake

`willSleepNotification` cancels any in-flight fade — finishing it against a sleeping panel
is pointless and the writes can be lost. On `didWake` / `screensDidWake`, the system has
taken the backlight back, so the app writes the remembered level once, resets to
`idleWatching`, and re-samples. It does not try to fade on wake; the display is already
being restored by macOS at that moment and a competing fade looks like a flicker.

## Logging

The engine logs through `os.Logger` on subsystem `com.local.screensleep`:

```bash
log show --last 5m --info --predicate 'subsystem == "com.local.screensleep"' --style compact
log stream --predicate 'subsystem == "com.local.screensleep"'
```

Every tenth poll emits idle seconds, threshold, state, enabled flag, and display count;
`dim()`, `restore()`, `undim()` and fade completion each log a line. Note that `os.Logger`
redacts interpolated values by default — the state strings are explicitly marked
`privacy: .public`, which is why they're readable while numbers appear as-is only where
they're safe. `info`-level entries are memory-backed, so `log show` needs `--info` to see
them.

## Extending it

- **A new setting** — add a key + clamped accessor in `Preferences.swift`, a submenu built
  from a `[(String, Double)]` choice list in `AppDelegate.buildMenu()`, and a checkmark rule
  in `menuNeedsUpdate`. The existing `Dim To` / `Undim To` submenus are the pattern to copy.
- **A new trigger** (on lock, on battery, on a schedule) — call `dimmer.dim()`. The state
  machine doesn't care where the request came from.
- **A different dimming mechanism** (a black overlay window, gamma tables) — implement
  behind the `BrightnessAPI` surface: `get`, `set`, `controllableDisplays`. Nothing above it
  assumes a backlight.
