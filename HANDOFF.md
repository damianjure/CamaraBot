# Handoff (2026-11-10)

Status of CueVideo when it moved from Jake's MacBook Pro to the church booth.

## Built
- ATEM engine (`Sources/CueATEM/ATEM.swift`): connect, full state from the
  switcher, program/preview, cut, auto, T-bar, transition style and rate,
  next-transition keys, upstream keys, DSKs (tie/cut/auto), fade to black,
  aux, macros, stream and record, tally by source.
- PTZ (`Sources/CueATEM/PTZ.swift`): Canon's own HTTP control (no camera
  settings, no login; reads the camera's preset names), VISCA over IP (UDP
  52381) and VISCA over TCP (5678): joystick pan/tilt, zoom, focus, home,
  preset recall, and preset save on VISCA (Canon needs an admin login to save).
  "Follow next" selects the camera whose ATEM input is on preview.
- NDI preview monitor (`Sources/CueVideo/NDIMonitor.swift`), meant for the ATEM multiview.
- UI: Simple mode (Live / Next / Cut / Fade / Black) and Full mode.

## Tested
- Every command above against `Tools/fake_atem.py` (fake ATEM plus three fake
  VISCA cameras) through the self-test; screenshots looked right.

- 2026-11-10 on the church's real ATEM 2 M/E Constellation HD (192.168.20.31,
  protocol 2.32): read-only probe (`CUEVIDEO_PROBE=1`) read every input, both
  M/Es, 4 keys, 2 DSKs, 12 aux. `CUEVIDEO_REALTEST=1` ran 25 commands (preview,
  cut, auto, T-bar, style, rate, next transition, key, DSK tie, aux, fade to
  black) and put everything back: 25 of 25 passed, twice.
- Fixed from the real switcher: it resends packets, so each is applied once
  (an old fade update was undoing a newer one); a finished auto can end with a
  program change and no final "not in transition" update; big switchers (12 aux)
  overflowed the panel; Record and Stream now show only on models that have them.
- CueStack's ATEM code (Devices.swift) has the same resend problem; fix it when it moves onto CueATEM.

- 2026-11-10 on the church's three Canon cameras (CR-N500 .91, CR-N100 .92,
  CR-N300 .93) over Canon HTTP: `CUEVIDEO_PTZTEST=ip,ip,ip` nudged pan, tilt and
  zoom and recalled a preset on each; a watcher saw pan, tilt and zoom change on
  all three; `Tools/canon_position.py` saved and restored every camera exactly.
  VISCA never answered on these cameras (and the CR-N100 is on old firmware 1.0.1).

- Camera inputs: Cam 1 CR-N500 (.91) on Camera 101 (input 9), Cam 2 CR-N100 (.92)
  on Camera 102 (input 10), Cam 3 CR-N300 (.93) on Camera 103 (input 11).
  `CUEVIDEO_FOLLOWTEST=1` put each on M/E 1 preview: Follow next picked the right
  camera 3 of 3, preview put back.

## Not tested yet
- The joystick and zoom rocker by hand (the test drives the same code paths).
- Live NDI video in the monitor (no multiview NDI source on the network yet).
- Macros (this switcher has none recorded).

## Church network (192.168.20.0/24), from a quick scan; not yet confirmed
| IP | Hardware maker (MAC prefix) | Likely device |
|---|---|---|
| 192.168.20.31 | Blackmagic Design | ATEM 2 M/E Constellation HD (confirmed) |
| 192.168.20.91 / .92 / .93 | Canon | CR-N500 / CR-N100 / CR-N300 PTZ (confirmed; Canon HTTP works, VISCA off) |
| 192.168.20.164 | Allen & Heath | Audio console |
| 192.168.20.206, .254 | Shure | Wireless receivers |
| 192.168.20.1 | Ubiquiti | Gateway |

## First steps at the booth
1. `./build.sh debug`
2. Read-only first: open the app, connect to the ATEM IP, confirm names, tally
   and state match the hardware panel before pressing anything.
3. Test commands one at a time with someone watching; never while live.
4. Add the PTZ cameras in settings (gear icon) and try the joystick and presets.
5. Turn on the multiview's NDI output in ATEM Setup and pick it from the NDI menu.

## Next after this
- Use `CueATEM` in CueScreens for ATEM actions on slides (its own branch; CueScreens is Matt's repo).
- Move CueStack's send-only ATEM code onto `CueATEM`.
