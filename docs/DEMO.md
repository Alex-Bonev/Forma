# Demo run sheet (owner: Alex)

Target: 3 minutes, live, on Alex's iPhone 17 Pro. Backup device: Michelle's LiDAR iPhone with the same build.

## Night before
- [ ] Final build installed on both phones from `main` (free provisioning lasts 7 days, so a reinstall resets the clock).
- [ ] Demo room and chair are pulled into `Resources/DemoData/` (`scripts/pull_demo_assets.py`) and committed.
- [ ] On both phones: delete the app, reinstall, then ••• > Load Demo Data. Confirm "Demo Living Room" and "Demo Chair" (the real scan, not boxes).
- [ ] Also keep the real scanned room in the app (not just the demo copy), with the chair already placed next to the sofa.
- [ ] Screen-record one complete run (Control Center > Screen Recording) and AirDrop it to a laptop. This is the last-resort video.
- [ ] AI render for the demo room and camera angle is generated and cached (David), so step 5 works offline.

## 15 minutes before
- [ ] Phone at 80%+ battery, Do Not Disturb on, brightness up, Auto-Lock off (Settings > Display & Brightness).
- [ ] Hit the backend `/health` URL from the phone's Safari to warm the server (David has the URL).
- [ ] Open the app to the Home screen. Close every other app (memory for reconstruction and RoomPlan).
- [ ] If doing the live room scan: check the stage area has visible walls and decent light. Skip the scan if it's chaotic.

## Script

| Time | Do | Say | If it breaks |
|---|---|---|---|
| 0:00 | Home > open the scanned room | "This is my living room, scanned in 30 seconds with LiDAR." | Open "Demo Living Room" instead |
| 0:20 | Orbit (one finger on empty space), pinch to zoom, tap the cutaway-walls toggle | "A clean architectural dollhouse: every wall, door and piece of furniture." | |
| 0:40 | (Optional) Scan Room, ~20 s pass of the stage, Done, Save | "Let me prove it's real." | Discard and go to the next step. Never wait more than 30 s |
| 1:10 | Back > Scan Object; show the guided capture for ~5 s, then Cancel | "In a store I scanned this chair with Apple's Object Capture." | |
| 1:20 | Back in the room, tap **+ Store chair** in the tray | "Here's the real chair, at real scale." | Use "Demo Chair" |
| 1:30 | Drag it next to the sofa, twist two fingers to rotate | "Does it fit? Now we know." | Use the rotate buttons |
| 2:00 | **Make it real ✨** | "And this is what it'll actually look like." | Cached render / skip |
| 2:30 | (If built) Vibe: pick an inspiration image | "Want a different vibe? Shop the look." | Skip |
| 2:50 | Wrap | "Scan, place, see it real. RoomVibe." | |

## Rules on stage
- Never wait live on object reconstruction (minutes). Always use the pre-scanned chair.
- If anything stalls for more than 5 s, move to the next step or the fallback. Don't debug on stage.
- If the phone dies or the app crashes twice, switch to the backup phone, then to the video.
