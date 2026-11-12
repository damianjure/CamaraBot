# CueVideo

A simple ATEM control surface for church booths, with PTZ camera control and live
camera previews. Part of the Cue family (CueStack, CueScreens, CueLights,
CueTracks). Native macOS 14+, SwiftUI.

- `Sources/CueATEM`: the shared engine. `ATEM.swift` speaks the ATEM network
  protocol (UDP 9910) with two-way state; `PTZ.swift` drives Canon cameras over
  Canon's HTTP control and VISCA cameras (VISCA over IP UDP 52381, or VISCA over
  TCP 5678); `CameraLogin.swift` keeps the cameras' admin login in the Keychain.
  Meant to be used by CueScreens (slide actions) and CueStack too.
- `Sources/NDIBridge`: copied from CueScreens; loads the NDI runtime at run time.
- `Sources/CueVideo`: the app.
  - One window with two views, switched in the top bar or the View menu:
    - **Operator** (⌘1, where it always opens), for the booth volunteer: Next and
      Live monitors, the source row, then exposure, saved shots, the joystick and
      Fade / Cut / Black / key buttons. Camera controls always act on the camera on Next.
    - **Engineer** (⌘2), for whoever sets the system up, with a page each for Stage
      scan (⇧⌘S), Routing (⇧⌘R), the Full switcher (⇧⌘K: keys, DSKs, styles, T-bar,
      macros, aux), Setup (⌘,: switcher, source row, key buttons, cameras and their
      shots, the camera admin login) and Status (a log of every command sent). A strip
      across the top shows what's Live and Next. Space, Return, the number keys and
      the arrows do nothing here.
  - Menu bar: **View** (Operator, Engineer), **Switcher** (Cut, Fade, Fade to Black,
    key buttons), **Camera** (Track ⌘T, Stop All Tracking ⌘., Follow by Name, Focus
    ⇧⌘F) and **Engineer** (its pages). Switcher and Camera only act from the Operator view.
- `Sources/CueVideoMCP`: the MCP server Claude uses (see below).

Build: `./build.sh` (or `./build.sh debug`) makes `CueVideo.app`.

## Setup file

Everything set up in the app is saved as plain JSON in
`~/Library/Application Support/CueVideo/config.json`: the switcher address, the
M/E volunteers run, the source row, key buttons, cameras and each camera's saved
shots. The app picks up edits to the file within a second, so a person or Claude
can set CueVideo up by editing it. The camera admin login is never in this file.

## Claude (MCP)

`CueVideo.app/Contents/MacOS/cuevideo-mcp` is an MCP server with a tool for every
action in the app (status, Next/Live/Cut/Fade/Black, keys, record and stream,
camera moves, exposure, shots and presets, the full switcher, setup). It passes
calls to the running app over 127.0.0.1:9911, using the key in
`~/Library/Application Support/CueVideo/control-token`. Calling a tool opens
CueVideo if it isn't running; listing the tools (which every Claude session does
when it starts) does not. `.mcp.json` registers it for Claude Code sessions in this folder.
Camera tools refuse a camera that's on Live unless the call says `allow_live: true`.

## Safeguards

- **A camera is never left moving.** If Next is cut to Live while the joystick or an arrow key is held, the camera that was moving is stopped. Quitting CueVideo stops every camera it is moving, tracking included. Arrow keys let go when another window or app comes to the front. A stop that is waiting for a Canon camera is kept and re-sent if the request before it fails.
- **Keys only work in the main window.** Space, Return, the number keys and the arrows do nothing in Setup, Video Routing, the Full Switcher, or while a dialog or popover is open.
- **The setup file is protected.** Every setup that loads or saves cleanly is copied to `config.last-good.json`. If `config.json` has a mistake when CueVideo opens, it runs on that copy and says so on the main screen. Before CueVideo saves over a file it couldn't read, it keeps that file as `config.unreadable-<date>.json`.
- **Claude's tools don't guess.** `set_recording` and `set_streaming` need a clear `on: true` or `on: false`. A part of a name is accepted only when it fits exactly one source, screen or routing button.

`swift test` runs the camera code against pretend cameras on this Mac and checks the stops go out.

## Companion and other control

The control server (`ControlServer.swift`, port 9911) is what the MCP server and the
Companion module use. It answers on 127.0.0.1 only, unless **Allow control from other
computers on the network** is on in Setup, on the Control page. That setting is off by default and kept in this Mac's preferences, not in
the config file, so nothing that edits the config can turn it on. On or off, every
request must send the control key (header `x-cuevideo-token`); without it CueVideo
answers 401 and does nothing. The Control page also shows and copies the key. `swift test` checks the key comparison and
which addresses count as this Mac.

## Saved shots on VISCA cameras

Canon cameras report where they point, so a Canon shot keeps pan, tilt and zoom in
the config file. VISCA cameras can't be asked here, so a VISCA shot is saved in one
of the camera's own presets (CAM_Memory Set, `81 01 04 3F 01 pp FF`) and recalled
from it (CAM_Memory Recall, `81 01 04 3F 02 pp FF`). The shot keeps that preset as
`preset`, numbered from 1 like the preset buttons, and the camera's `firstPreset`
maps it to the camera's own count the same way. Shots use presets 9 to 80, so 1 to 8
stay for the preset buttons. A VISCA shot written by hand without `preset` can't move
the camera; `recall_shot` says so instead of answering ok. `swift test` checks the
bytes sent on save and recall against a pretend camera, for cameras that count presets
from 0 and from 1.

## Camera speed, exposure and color matching

- **Manual speed:** a tortoise-to-hare dial under the joystick (0.25× to 2×) sets how fast the joystick, zoom and arrow keys move every camera (config `ptzSpeed`).
- **Tracking speed:** auto tracking works in real angles. It reads each camera's angle of view and position about four times a second. It drives the camera at the person's own speed plus a correction toward the framing mark, and speeds up sharply near the frame edge. It also learns how fast the camera really turns for the speed it was asked for, so zoomed-in shots, or camera modes that slow panning at tele, still keep up.
- **White balance:** a row under gain, shutter and iris. Cooler and warmer step the color temperature, and the middle picks auto, daylight, tungsten, 3200, 4300 or 5600 K, or matches another camera. Exposure shots save white balance too.
- **For Claude:**
  - `set_exposure` takes `white_balance`.
  - `match_exposure` copies gain, shutter, iris and white balance from one camera to the others, snapped to each model's values.
  - `camera_snapshots` returns a picture from each camera with color measurements (average RGB, red÷green and blue÷green cast, brightness, clipping), so cameras can be compared and matched.

## Video routing

**Engineer → Routing** (⇧⌘R) shows how pictures reach the screens:

- **Mixes:** what each M/E is for (M/E 1 the live stream, M/E 2 the side screens), what's on it, and quick buttons to switch the mix the volunteer doesn't run.
- **Screens and outputs:** every aux output, as picture → aux → the screen it feeds and how it's wired. Pick a new picture from the menu and it changes right away. Linked auxes (such as a pair of lobby TVs) switch together. Outputs that feed encoders, recorders or the patch bay can be hidden from volunteers.
- **Volunteer routing buttons:** route the screens the way you want, then save that as a button. The buttons sit in the bottom right of the main window, work like macros (one press can change several screens), and light up while the screens match them. Below them, a short summary says what each volunteer-facing screen is showing.

In the config file, this is `mixNames`, `screens` and `routes`. Claude can use `get_routing`, `route_screen` and `run_route_button`. `route_screen` refuses hidden outputs, such as the stream encoder, unless the call says `allow_hidden: true`.

## Graphics and lower thirds previews (NDI)

Tiles and the Next and Live monitors can show any NDI source, typically a CueScreens screen with an NDI output added. In Setup, under Volunteer source row, pick the NDI picture for a non-camera source such as Graphics. Under Key buttons, pick an NDI source with alpha (such as CueScreens' lower thirds sent with alpha). It is laid over the Next and Live pictures when the key is on them: on Live when it's on air, and on Next when it will be on air after the next Cut or Fade (a tied DSK or a key selected in the next transition).

Previews use NDI's low-bandwidth preview stream, so they cost little network or processor time. They need the NDI runtime on this Mac (NDI Tools). In the config file, it's the `ndi` field on a source or key, with the exact name from Setup or Claude's `list_ndi_sources`. The preview shows what CueScreens is drawing, not the switcher's actual output.

## Auto tracking

**Track** (under the joystick) makes the Canon camera on Next follow the person nearest the middle of its shot. Click a person on the Next picture to follow them instead. CueVideo finds people and their body landmarks (eyes, shoulders, hips, ankles) in the camera's preview picture with Apple's Vision framework. It works out whether the shot is **shoulders up**, **waist up** or **full length**, and frames it the way a broadcast operator would:

- Eyes near the upper third line, with headroom to suit the shot size.
- Frame edges between joints: mid-chest, just below the waist, or a little room under the feet.
- Lead room on the side the person faces or walks toward.
- A dead zone, so the camera doesn't chase small moves, with eased starts and stops.
- Slow zooms that hold the shot size as the person comes nearer or moves away.

The Close / Waist / Full buttons under Track reframe the shot. Zooming by hand keeps tracking going and holds the new size. Moving the joystick, recalling a shot or preset, or clicking the badge on a monitor stops tracking. The person being followed is outlined on every picture of that camera, and tracking carries on when the camera goes Live.

The preview runs slightly behind real time, so tracking suits someone walking the stage, not running. Follow speed (0.5 to 2), tilt on/off and zoom-to-hold-size are in Setup and the config file (`trackSpeed`, `trackTilt`, `trackZoom`). The framing numbers live in `ShotSize` in `Tracker.swift`. Claude can use `start_tracking`, `set_tracking_shot` and `stop_tracking`.

### Telling people apart

Tracking keeps to one person by what they look like (clothes, build and colouring, worked out on this Mac with Apple's Vision framework), as well as by where they were. When two people cross it stays with the one it was following. After losing sight it waits for that person and does not pick up whoever is nearest; the badge says "Lost them, looking" until they're back, and clicking a person on the picture follows them instead. It is not face recognition and stores nothing between runs. People dressed alike are harder to tell apart: then it carries on by position while they're in sight.

## Stage scan

**Engineer → Stage scan** (⇧⌘S), for before a service with everyone in place (rehearsal or soundcheck):

1. Each Canon camera that isn't on Live, tracking or held by another controller goes to a wide shot, and comes back afterwards. The wide shot is that camera's shot named **Stage** or **Wide** if it has one (worth making: frame the stage as tightly as covers everyone, so people are bigger in the picture). Otherwise it's where the camera points now, zoomed all the way out.
2. CueVideo finds the people in each wide shot and works out the shot that frames each one from that camera (waist up by default), from the camera's own angles and angle of view.
3. It shows a small picture of each person per camera. A letter marks its guess at the same person on another camera. Type a name or role under one and the others with that letter fill in; fix any it got wrong.
4. **Save shots and names** adds a shot per labelled person to each camera's row in the shot grid (replacing the last scan's; shots made by hand are kept, and marked `"auto": true` in the config file), and remembers each person's look. Under Track, **Follow by name** then follows that person wherever they are in the shot. Names last until CueVideo quits.

The shots are for where people stood during the scan. Claude can use `scan_stage`, `label_stage_scan` and `start_tracking` with `person`.

## Canon cameras take one controller at a time

Only one session controls a Canon camera at a time. If another controller (another
copy of CueVideo or CueStack, a Companion Canon connection, an RC-IP100) keeps
claiming the same cameras, the two trade control and the joystick seems broken.
CueVideo shows "waiting for control" when this happens; close the other one.

## Testing without hardware

`python3 Tools/fake_atem.py 9910 --cams` starts a pretend ATEM and three pretend
VISCA cameras, then
`CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_FAKECAMS=127.0.0.1 CUEVIDEO_SELFTEST=1 CUEVIDEO_SNAPSHOT=<folder> ./CueVideo.app/Contents/MacOS/CueVideo`
runs every command, prints the state after each, and writes screenshots. Self-tests
never write to the setup file. A self-test runs the control server only when it
names its own port with `CUEVIDEO_CONTROL_PORT`, so it never meets the real app's. Never run the self-test against a switcher that is
live on a service.

Keys: 1 to 0 put that source-row tile on Next, Shift plus a number cuts it to Live,
Space cuts, Return fades, arrows move the camera on Next.
