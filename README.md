# PlayTools

PlayTools is an essential part of [PlayCover](https://github.com/PlayCover/PlayCover). PlayTools implements core functions of PlayCover, including display control, key mapping and bypassing.

The [MaaTools v5 protocol](#maatools-protocol-v5) documents automation touch
sequences, delivery guarantees, timeouts, compatibility, and verification limits.

## Display Control

<!-- iOS APPs running on macOS usually have fixed display settings, which may not be suitable for the user's needs. PlayTools allows you to adjust the display settings of the game, so that you can enjoy the game in a more comfortable way. -->

PlayTools allows you to control:

- Resolution: Supports 1080p, 4k, 1440p and custom resolution
- Aspect Ratio: Supports 16:9, 16:10, 4:3 and custom aspect ratio
- Scale Factor: Supports custom scale factor (e.g. 1.0, 1.5, 2.0)
- Display Orientation: Supports manually rotating the game window during game play.
- Application type (most useful case is changing to type `game` and the type reflects in screen time usage)
- Custom discord activity
- Device type

## Key Mapping

PlayTools provides a key mapping tool to map game actions to the keyboard, mouse, trackpad or controller.

Supported input devices include:

- Keyboard
- Mouse
- Trackpad
- Controller

Input from these devices can be mapped to these in-game actions:

- Button
- Joystick (e.g. WASD)
- Camera Control (usually by mouse)
- Draggable Button (e.g. wheel menu selection)

More mapping options such as swiping will be added in the future.

## Bypassing

Games designed for iOS devices may not work properly on macOS. PlayTools provides a solution to bypass these issues.

### Jailbreak Bypassing

Some games refuse to work on macOS because they detect the environment as a jailbroken device. PlayTools hijacks the detection process of popular jailbreak detection tools, so that the game will think it is running on a non-jailbroken device.

PlayTools also allows per-game configuration for more advanced jailbreak bypassing techniques.

### PlayChain

PlayChain is a tool that solves key chain issues by replacing the game's key chain with a custom one. Key chain issues usually prevent the game from logging in.

### Introspection Library

Some games only work under debug environment. By inserting the Introspection Library, PlayTools tricks the game into thinking it is running under debug environment.

# How to Use

PlayTools is shipped with PlayCover, and is installed together with the game. You do not need to install PlayTools manually.

PlayTools provides in-game menus mostly for key mapping setup. Other features are accessible through the PlayCover settings menu.

Localization is handled in [Weblate](https://hosted.weblate.org/projects/playcover/).

# How it Works

PlayTools runs alongside of the game. During IPA installation, PlayTools is inserted into the game's executable. When the game is launched, PlayTools will be launched together.

PlayTools uses swizzle techniques to replace framework methods and system calls with the versions provided by PlayTools. During game play, PlayTools intercepts game input events and translates them to the corresponding touch events and feed them to the game.

# How to Build

PlayTools is built using Xcode.

## Production Build
In release builds, the building script of PlayCover will automatically fetch the latest version of PlayTools from the official repository and build it. Generally, you do not need to build PlayTools manually.

To build PlayCover with a specific version of PlayTools, mostly for testing purposes, change the [Cartfile](https://github.com/PlayCover/PlayCover/blob/develop/Cartfile) of PlayCover to point to the specific version of PlayTools. You can specify which branch/tag of which repository to build from.

You can also edit the Cartfile to build from a local directory. To do this, edit the Cartfile to be:
```
git "file:///path/to/playtools" "branch or tag"
```
See [Cartfile format](https://github.com/Carthage/Carthage/blob/master/Documentation/Artifacts.md#example-cartfile)

In most cases, `Cartfile.resolved` would be automatically updated based on the Cartfile. In rare cases, you may need to manually edit the resolved file.

## Development Build
PlayTools can also be built separately. This is useful when you want to modify the source code.

To do so, 

1. Clone the PlayTools repository.

1. Open the PlayTools project in Xcode.

1. Set the development team in the Xcode project settings. Both `PlayTools` and `AKInterface` targets need to be set. You may need to create a development team first.

1. Build PlayTools towards iOS platform. This will create a `PlayTools.framework` in the build directory.

1. Find the build path. This can be done by right clicking on `PlayTools.framework` in `Product`, and selecting `Show in Finder`. 

6. Deploy the build. Replace the `BUILD_PATH` in the following script with your build path and run:

```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/PlayTools-<YOUR-UUID>/Build/Products/Debug-iphoneos

echo "Converting to maccatalyst"
vtool \
	-set-build-version maccatalyst 11.0 14.0 \
	-replace -output \
	"$BUILD_PATH/PlayTools.framework/PlayTools" \
	"$BUILD_PATH/PlayTools.framework/PlayTools"

echo "Codesigning PlayTools"
codesign -fs- "$BUILD_PATH/PlayTools.framework/PlayTools"

echo "Copying to PlayCover"
rm -r "/Applications/PlayCover.app/Contents/Frameworks/PlayTools.framework"
cp -r "$BUILD_PATH/PlayTools.framework" "/Applications/PlayCover.app/Contents/Frameworks/"

```
This script transforms the target platform to Mac Catalyst, codesigns PlayTools and copies the binaries into the PlayCover App.

7. Relaunch PlayCover.

### Temporary Deploy

If you are debugging and testing your own code, relaunching PlayCover every time you make a change is a bit annoying. 

To avoid this, run this script instead:

```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/PlayTools-<YOUR-UUID>/Build/Products/Debug-iphoneos

echo "Converting to maccatalyst"
vtool \
	-set-build-version maccatalyst 11.0 14.0 \
	-replace -output \
	"$BUILD_PATH/PlayTools.framework/PlayTools" \
	"$BUILD_PATH/PlayTools.framework/PlayTools"

echo "Codesigning PlayTools"
codesign -fs- "$BUILD_PATH/PlayTools.framework/PlayTools"

echo "Copying to frameworks"
cp "$BUILD_PATH/PlayTools.framework/PlayTools" "~/Library/Frameworks/PlayTools.framework/"
```

This only copies `PlayTools.framework/PlayTools` to `~/Library/Frameworks/PlayTools.framework/`, instead of the whole `PlayTools.framework` directory into PlayCover. Changes take effect immediately, no PlayCover relaunch needed. Changes will be lost when you relaunch PlayCover.

However, If you modified `AKInerface` or added localization strings, the temporary deploy method may not work for you. You may copy the whole `PlayTools.framework` as described above, or directly copy them into the game you're testing on:
```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/PlayTools-<YOUR-UUID>/Build/Products/Debug-iphoneos

cp "$BUILD_PATH/PlayTools.framework/PlugIns/AKInterface.bundle" "~/Library/Containers/io.playcover.PlayCover/Applications/<YOUR-GAME-NAME>.app/PlugIns"

cp "$BUILD_PATH/PlayTools.framework/*.lproj" "~/Library/Containers/io.playcover.PlayCover/Applications/<YOUR-GAME-NAME>.app/"
```
This will be overwritten when you launch the game through PlayCover. You can launch the game from Finder to avoid this.

# Products

## PlayTools

The main part of PlayTools. This ends up as a dynamic library. This part is built towards iOS platform because it uses iOS APIs that are not available on Mac Catalyst.

## AKInerface

A bridge that encapsulates native macOS APIs to expose an interface for PlayTools. This includes manipulating mouse and keyboard events, controlling cursor and application state, and reading window information.

## Localizable Strings

Localizations for PlayTools are tricky. As PlayTools runs as a dynamic library inside the game, localizable strings must be copied into the game to take effect. This is done during IPA installation and every launch of the game through PlayCover.

To avoid conflicting with the game's own localizable strings, PlayTools' localizable strings are renamed to `PlayTools.strings`, instead of the default `Localizable.strings`.

# MaaTools protocol v5

This document specifies the MaaTools protocol implemented by PlayTools. Clients
may send `TSEQ` only after `VERN >= 5`; no `CAPS` negotiation is used. Existing
`TUCH`, `TSYN`, `SCRN`, `BGR\x01`, `NATV`, `SIZE`, `BNDL`, `RECT`, and `TERM`
commands remain available. Screenshot formats and window-scaling behavior are
unchanged.

## Connection and framing

1. Connect using TCP and send the four unframed bytes `4d 41 41 00` (`MAA\0`).
2. Read the four unframed bytes `4f 4b 41 59` (`OKAY`).
3. Each subsequent request is `u16be payloadLength` followed by exactly that many
   payload bytes, including its four-byte command identifier. The length prefix
   does not include itself. Responses do not use this request-length prefix.

Payload lengths must be in `4...9222`. Invalid lengths, incomplete frames, and
transport errors close the connection and cancel its active touch. At most 256
complete messages can wait in the receive buffer (up to 2.25 MiB of payload bytes,
excluding allocation overhead). Overflow closes the connection; buffered commands
are not executed after closure.

Commands execute in receive order on each connection. A running `TSEQ` must finish
or fail before the next command on that connection executes. Other connections
have independent touch contexts and sequence tasks.

| Request payload | Response |
| --- | --- |
| `VERN` | `u32be version`; v5 returns `00 00 00 05` |
| `BNDL` | `u32be utf8Length`, then that many UTF-8 bundle identifier bytes |
| `SIZE` | `u16be width`, `u16be height` in the existing native-pixel coordinate space |
| `TUCH`, `u8 phase`, `u16be x`, `u16be y` | No response; legacy streaming touch semantics |
| `TSYN` | Exactly four ASCII bytes, `OKAY` or `FAIL` |
| `TSEQ` and the body below | Exactly one four-byte ASCII `OKAY` or `FAIL`, if the connection remains usable |

## TSEQ binary layout and validation

All multibyte integers are unsigned and big-endian. Offsets below are relative to
the payload, after the outer two-byte length prefix.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | ASCII `TSEQ` (`54 53 45 51`) |
| 4 | 2 | `eventCount` |
| `6 + 9*i` | 4 | Event `i`: `delayAfterPreviousEventUs` |
| `10 + 9*i` | 1 | Event `i`: `phase` |
| `11 + 9*i` | 2 | Event `i`: `x` |
| `13 + 9*i` | 2 | Event `i`: `y` |

`i` ranges from zero to `eventCount - 1`. The payload must be exactly
`6 + 9 * eventCount` bytes; the complete framed request is two bytes longer.

- Count: `1...1024`; the complete-gesture rule makes two the smallest valid count.
- Phase: `0` = down, `1` = move, `3` = up; all other values are rejected.
- Each delay: `0...30_000_000` microseconds, including the first delay.
- Sum of all delays: at most `120_000_000` microseconds.
- Coordinates: `0 <= x < width` and `0 <= y < height`, using the native dimensions
  sampled before parsing. These are the existing `TUCH`/`SIZE` coordinates, not
  necessarily `NATV` bitmap coordinates. Both commands use the same rounded
  division by `scale` when dispatching to UIKit. Re-query `SIZE` after resizing;
  do not resize the app during a gesture.
- Gesture grammar: `(down move* up)+`. An inactive sequence accepts only down;
  an active sequence accepts only move or up; the final state must be inactive.
  Multiple complete gestures are permitted in one request. TSEQ cannot continue
  a preceding TUCH hold with an initial move or up.

The server validates the entire count, exact length, every event, and the final
lifecycle before dispatching any event from the sequence. A rejection returns
`FAIL` after cleaning up any pre-existing touch belonging to this connection.
Validation is atomic; execution is not transactional and cannot be rolled back.

For example, a zero-delay tap at `(100, 100)` is 26 bytes including framing:

```text
00 18                         # payloadLength = 24
54 53 45 51 00 02             # TSEQ, eventCount = 2
00 00 00 00 00 00 64 00 64    # delay = 0, down, x = 100, y = 100
00 00 00 00 03 00 64 00 64    # delay = 0, up,   x = 100, y = 100
```

## Timing, ordered delivery, and acknowledgment

The first delay is relative to the monotonic start of the sequence executor,
after parsing. Each subsequent delay is relative to the preceding event's actual
dispatch time, not the time its delivery acknowledgment arrives.

After dispatching **every** event, TSEQ awaits the existing
`PTFakeMetaTouch.syncPendingEvents(timeout:completion:)` delivery barrier before
it may mutate that connection's touch again. Waiting for the barrier counts
toward the next event's requested delay. Only the unelapsed part of the delay is
passed to asynchronous `Task.sleep`; the main thread is not blocked by a sleep or
a synchronous wait. A delayed barrier may lengthen an interval, never shorten it.
Zero delay is valid but does not bypass ordered delivery.

This barrier is necessary because PTFakeMetaTouch stores mutable UITouch objects,
not immutable event snapshots. A sleep or yield alone would allow an up to replace
an undelivered began, or a move to be ignored while the touch is still began.
TSEQ does not intentionally coalesce moves: on `OKAY`, each requested event has
passed its delivery barrier before the next one is dispatched. The final event's
barrier also serves as the sequence's final synchronization. Internal barriers do
not send extra replies, TSYN commands, or network round trips.

Here, **delivered** means that PTFakeMetaTouch's RunLoop callback passed the current
touch state to `UIApplication.sendEvent`, returned from that call, and advanced
its delivery counter. It does not mean that the game accepted the action,
completed an animation, or rendered a new screenshot. The barrier uses the
existing global delivery counter and can include other pending input, but each
connection owns its touch context; another client's touch cannot advance this
sequence to its next event before this barrier completes.

## Execution budget and client timeout

Let `D` be the sum of all requested delays in seconds.

- The executor has one shared monotonic deadline: `start + D + 3 seconds`.
  The three seconds cover aggregate delivery/scheduling overhead, not three
  seconds for every event.
- Each internal delivery wait is capped at the smaller of three seconds and
  the remaining execution budget. No zero-timeout/unbounded barrier is used.
- Expiry or delivery failure stops further event dispatch. Cleanup can perform
  one additional delivery wait of at most three seconds before returning `FAIL`.
- Thus the conservative server-processing allowance is `D + 6 seconds`
  (at most 126 seconds); successful execution is limited to `D + 3 seconds`.

These are cooperative execution deadlines, not a hard real-time guarantee when
the application's main thread is stalled or the process is suspended. The
executor checks the deadline before dispatch and after each barrier, so it does
not resume emitting overdue events after regaining execution. Network transport
and time spent behind previously pipelined commands are not part of this budget.

A client should keep one gesture in flight, hold its socket lock from request
through response, and temporarily set its response timeout to at least
`D + 6 seconds + network allowance` (for example, two more seconds on a local
connection). Restore the previous timeout in `finally`. A fixed three- or
five-second timeout is not sufficient for the existing 5.5-second long press.

## Failures, cancellation, and replay safety

`OKAY` is sent once, only after all events and their delivery barriers succeed.
The sequence's touch lifecycle is then inactive. A malformed request, execution
deadline, or delivery failure produces one `FAIL` when a response can still be
sent. Connection failure can prevent any response, including after the gesture
has already completed.

`FAIL` and a lost response **do not mean safe to replay**. The same response covers
parse rejection, partial execution, and failure to confirm final delivery. Some
or all actions may already have affected the game. The protocol has no request
IDs, rollback, or exactly-once replay facility. Do not blindly retry a TSEQ click
or fall back to TUCH after sending it. Inspect the application's state and let the
higher-level workflow decide whether a new action is appropriate.

Cancellation, disconnect, receive-buffer overflow, parse rejection, and execution
failure reuse this connection's `MaaToolsTouchState` cleanup. An active touch is
cancelled at its last position; no other connection's touch is reset. Once the
connection is marked closed, neither its active sequence nor buffered commands
may continue dispatching. A cancelled/failed sequence may deliver only a prefix
and a cancellation; it never acknowledges that prefix as a successful sequence.

## Legacy and feedback-driven input

TUCH retains the existing streaming phase/coordinate behavior and no-response
format. TSYN retains its single `OKAY`/`FAIL` response and three-second delivery
timeout. Its barrier confirms pending state; it cannot reconstruct phases that
legacy TUCH calls have already overwritten before a barrier. For reliable
streaming input, synchronize before mutating the same touch again.

TSEQ is for gestures whose complete event list is known before sending. A
feedback-driven hold that takes screenshots and decides when to release must
continue using TUCH/TSYN with exception-safe release. Queuing a screenshot after
an unfinished TSEQ on the same connection cannot provide mid-hold feedback.
Clients with `VERN < 5` retain their supported legacy path; v5 does not require a
PlayCover Manager change because its existing probe accepts `VERN >= 3` and
validates BNDL.

## Native verification

Before native integration is approved, build the PlayTools scheme for iOS with
Xcode as described above, and test in an isolated UIKit host
(not a live game). Record actual responder-delivery phases and coordinates, not
just the Toucher dispatch log. The required native cases are:

1. Zero-delay down/up and zero/short-delay down/move/up: began, every requested
   move, and ended are delivered in order before the single OKAY.
2. Deliberately delay servicing the custom RunLoop source: no following phase is
   dispatched until the prior delivery completes; expiry gives FAIL, not OKAY.
3. Multiple gestures: each complete lifecycle is delivered before the next begins.
4. Cancel a long hold: deliver cancelled, stop subsequent events, and clear only
   that connection's context.
5. Malformed frames/sequences and receive overflow: no new partial gesture for a
   parse rejection, and no buffered dispatch after connection closure.
6. Two concurrent connections: independent complete/cancelled lifecycles.
7. Confirm execution/cleanup budgets, one response, legacy TUCH/TSYN behavior,
   and unchanged VERN/BNDL/screenshot interfaces.

Native build and delivery results must be obtained on a supported Mac before
claiming native verification. Source inspection alone is not evidence of UIKit
event delivery.

