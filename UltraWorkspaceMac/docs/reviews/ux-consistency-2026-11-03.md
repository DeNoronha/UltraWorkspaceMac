# UX consistency review — 2026-11-03 (evening)

Read-only review by a subagent of the CoreBar and VivoCube pages side by side, prompted by: "Publish page top-right is fine, Send to cube halfway down the page is not; labels are inconsistent; the SenseCube has three sensors but the CoreBar only gets two." Applied in commit `83c3a97` unless marked *open*.

## High

- **H1. Primary action in different places.** CoreBar: "Publish page" in the header (top-right). VivoCube: "Send to cube" below the Switch panel with the progress row beside it. The step chains exist on both; the cube one just collapses to "Sent HH:MM ✓" after 20 s. **Pattern adopted for both:** header trailing = the one prominent button (⌘↩); the progress row is the first item under the device strip and shows "Published/Sent HH:MM ✓" when idle and the step chain while running; the same disabled rule (`isWorking || progress.isRunning || list empty`). *Applied.*
- **H2. Wi-Fi pill displaced the primary action** in the VivoCube header and repeated what the strip's fault banner and Maintenance already say. Moved into the device strip's left cluster as caption text (orange when the cube is not connected). *Applied.*
- **H3. SenseCube: three sensors, two bar cards.** Missing: Light (illuminance, lux). The firmware has `SENSE_CUBE_ALS` (PROTOCOL.md, corebar-pages-findings, launcher `WidgetType`), same `param.uid`. Added `SENSE_LUX` → `SENSE_CUBE_ALS` ("Light"); the SenseCube page adds all three with one button; MANUAL updated. Hardware confirmation of the ALS card still pending. *Applied.* Note: the firmware also has `SENSE_CUBE_RADAR` (presence) and `SENSE_CUBE_AUDIO` (sound level) cards — push-only sensors the Mac cannot read, but the bar can show them. *Open: offer them as bar cards too.*

## Medium

- **M1. Section titles did not mirror each other.** Now: "Preview" (with footer "Drawn from the list below — not read back from the bar") / "On the cube now"; "Cards on the bar" / "Cards on the cube"; "Switching"; "Maintenance" on both (was "Advanced" on the bar). *Applied.*
- **M2. Subtitles.** "A row of the bar's own cards; about 4 fit, more scroll sideways." / "One card at a time, up to 6." *Applied.*
- **M3. List footers.** Both start "Drag to reorder." and end with a count; MANUAL now uses ⌁ like the UI. *Applied.*
- **M4. "Add a card…"** is the same control on both pages; the difference was row height. No change.
- **M5. Device-strip wording.** Dropped "(set by Deckhand)"; the not-published fallback starts with "Bar:". *Applied.*
- **M6. Empty states.** "No cards — add some on the right" was wrong (the menu is below); "Nothing on the bar yet — add a card." parallels the cube. *Applied.*
- **M7. Widget vs card.** The app says "card" everywhere except the library page "Widgets" and a few hints ("choose a file in Widgets"). Recommendation: rename the library to "Cards". *Open — owner's call.*
- **M8. Card-name drift.** MANUAL listed cube cards that are no longer offered ("Weather & time", "CPU & memory", …). Fixed to the current library. *Applied.*
- **M9. MANUAL vs UI labels.** "Reboot" → "Restart cube", "Refresh cover only" → "Update picture", "Screen" → "Cube screen"; Doctor's "Fix" → "Fix black screen" everywhere. *Applied.*

## Low

- **L1.** Logs page used its own title row; now the shared `Header("Logs", …)`. *Applied.*
- **L2.** Settings subtitle still described the weather controls that moved to Widgets. *Applied.*
- **L3.** "Add to the cube" / "Add to the CoreBar page" in the library were prominent and competed with Publish/Send; now bordered. *Applied.*
- **L4.** "Show" vs "Showing" vs "Bar shows…" — consistent enough; optionally "Show on bar". *Open.*
- **L5.** The bar's bindings caption repeated the KnobKey/DotKey pages; reduced to one sentence pointing at Controls. *Applied.*
- **L6. Convention to keep:** device screens get one prominent header button; info pages get bordered secondary buttons in the header. (Record in UX-REVIEW.md.) *Open.*
