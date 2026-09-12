# Analytics events

This is the shared list of every analytics event name the Mac app and the
iPhone app send, and what each one carries. Both apps read PostHog data by
event name, so a name in this file is a contract: renaming or re-shaping an
event here breaks any dashboard or funnel built on the old one. Add new
events here; do not rename an existing one without checking who is watching
it.

Values that reference a word like "measured" or "settled" use the words
defined in `CONTEXT.md` in this repository — that glossary is the single
place those words are defined; this file only says which property carries
which one.

Consent differs by app and is not symmetric. The phone is opt-out: analytics
are on by default, with a switch to turn them off. The Mac is opt-out too, but
only through the free trial: analytics are on from first launch, with a
Settings switch to turn them off that sticks once flipped. A paid user is
asked once — a direct buyer sees the onboarding usage-stats card, a trial
converter sees a one-time popover right after their paid key is accepted —
and declining stops future collection, though whatever the trial already sent
stays. Ruling: owner, 2026-09-12. A joined report that lines up a Mac and a
phone by `mac_id` only fails to find a match for a paid user who declined
that one-time ask, a Mac whose owner turned the Settings switch off during
the trial, or a phone that connected before any Mac analytics fired.

`mac_id` is the join key between a Mac and the phones connected to it. It is
the value the Mac sends as `serverID` in its `welcome` message when a phone
connects (`AudioutProtocol`'s `CompanionMessage`); the phone reads it there
and attaches it to its own events. It is a random per-install identifier,
not tied to any Apple ID, name, or hardware serial.

No event, from either app, ever carries a device name, a person's name, an
email address, a bundle identifier, a network identifier, or any other
directly identifying value. Where an app or speaker matters to an event, the
property is a count, a category, or a bucketed number — never the name
itself.

| event | sent by | properties | allowed values | when it fires |
|---|---|---|---|---|
| `app:launched` | mac | — | — | The app launches. The one event that carries PostHog's own coarse geoip lookup on the request; no property of its own. |
| `takeover:retry_tapped` | mac | — | — | The main-mix "Speakers unreachable" strip's Try Again button is clicked. |
| `license:buy_link_opened` | mac | `source` | `mixer_note`, `license_sheet`, `settings`, `gate` | A Buy link is opened, from any of the four places it appears. |
| `license:removed` | mac | — | — | The user removes their license key from the license sheet. |
| `license:key_submitted` | mac | `outcome`, `source` (only from the gate) | `outcome`: the verification result — exactly `active`, `revoked`, `unknown`, `invalid`, `unreachable`, `no_server`, `no_key`; `source`: `gate` | A pasted or typed license key is submitted, from the settings sheet or the first-run gate. |
| `license:enter_sheet_opened` | mac | — | — | The "Enter a license key" sheet opens from Settings. |
| `license:gate_shown` | mac | — | — | The first-run license gate window is shown. |
| `license:trial_started` | mac | — | — | The first-run gate's Start Trial button is clicked. |
| `license:banner_shown` | mac | `day` | `3`, `1` | The days-left-in-trial banner is shown, with how many days remain. |
| `license:expired_gate_shown` | mac | — | — | The gate is shown because the trial or license has expired. |
| `license:conversion_consent_opted_in` | mac | — | — | A trial converter accepts the one-time post-purchase usage-statistics ask. Grant-only: there is no matching decline event, since a decline just stops future events. |
| `license:key_pasted` | mac | `outcome` | `no_key`, `filled` | The Paste button on the license gate is clicked, with whether the clipboard held a usable key. |
| `license:resend_requested` | mac | — | — | The gate's "Resend" (license email) is requested. |
| `mixer:bt_pairing_settings_opened` | mac | — | — | "Pair a Bluetooth speaker" opens macOS's own Bluetooth settings pane. |
| `mixer:volume_adjusted` | mac | `control` | `device`, `master`, `app` | A volume slider (a speaker, Main Audio's master, or a per-app fader) is moved, once per control per mixer session. |
| `mixer:device_mute_toggled` | mac | `muted` | `true`, `false` | A speaker's mute button is toggled. |
| `mixer:device_selected` / `mixer:device_deselected` | mac | `kind`, `refusal_reason` (only when refused) | `kind`: the speaker's connection kind; `refusal_reason`: why the toggle was refused | A speaker is added to or removed from Main Audio (the fired name depends on the direction). |
| `mixer:membership_hint_dismissed` | mac | — | — | The first-run "tap a speaker to add it" hint is dismissed by the first real membership edit. |
| `mixer:reconnect_requested` | mac | — | — | A speaker row's reconnect control is clicked. |
| `settings:pane_selected` | mac | `pane` | the clicked pane's title | A different Settings pane (General, Audio, and so on) is selected. |
| `settings:buffer_changed` | mac | `ms` | the new buffer size in milliseconds | The audio buffer size picker in Settings is changed. |
| `settings:excluded_app_removed` | mac | — | — | An app is removed from the per-app exclusion list in Settings. |
| `settings:excluded_app_added` | mac | — | — | An app is added to the per-app exclusion list in Settings. |
| `settings:reconnect_at_launch_toggled` | mac | `enabled` | `true`, `false` | The "reconnect speakers at launch" switch is toggled. |
| `settings:launch_at_login_toggled` | mac | `enabled` | `true`, `false` | The "launch at login" switch is toggled (fires on the attempted state, whether or not macOS honors it). |
| `surface:shown` | mac | `screen` | the screen shown (mixer, scenes, and so on) | The app's popover or window is shown after being hidden. |
| `surface:screen_selected` | mac | `screen` | the newly selected screen | The user switches tabs/screens inside the app's surface. |
| `surface:pin_toggled` | mac | `pinned` | `true`, `false` | The popover's pin (keep open) control is toggled. |
| `connection:failed` | mac | `kind`, `cause` | `kind`: the speaker's connection kind; `cause`: the failure cause | A speaker's connection state transitions into failed. |
| `connection:connected` | mac | `kind` | the speaker's connection kind | A non-local speaker successfully connects. |
| `connection:diagnosis_shown` | mac | `cause` | the failure cause | The connection-failure diagnosis panel is shown for a speaker. |
| `connection:retry_clicked` | mac | — | — | The diagnosis panel's Retry is clicked. |
| `streaming:daily_active` | mac | `speaker_count` | count of non-local connected speakers | Once per local calendar day, the first time audio reaches a speaker. |
| `scene:created` | mac | `source`; `member_count`, `already_existed` (only from the sheet) | `source`: `sheet` or `mixer`; `member_count`: count of speakers in the new scene; `already_existed`: `true`/`false` | A scene is saved, either from the mixer's "Save as scene" (which sends only `source: mixer`) or the dedicated creation sheet (which sends `source: sheet` plus `member_count` and `already_existed`). |
| `scene:renamed` | mac | — | — | A scene is renamed and saved. |
| `scene:membership_changed` | mac | `added` | `true`, `false` | A speaker is checked or unchecked in a scene's membership editor. |
| `scene:deleted` | mac | — | — | A scene is deleted. |
| `app_routing:app_added` | mac | — | — | An app is added to per-app routing (given its own destination). |
| `app_routing:destination_selected` | mac | `destination` | the chosen destination (a speaker, group, or Main Audio) | A per-app route's destination is changed. |
| `app_routing:group_selected` | mac | `members`, `dropped` | `members`: scene member count; `dropped`: how many of those members this app's route does not currently reach | A per-app route is pointed at a scene. |
| `app_routing:app_removed` | mac | — | — | An app's per-app route is removed. |
| `eq:opened` | mac | `door` | `row_button`, `menu`, `main_out_menu` | The per-speaker or Main Audio equalizer editor is opened, from whichever control opened it. |
| `eq:adjusted` | mac | `target` | `main_out`, `device` | An equalizer change is committed, for Main Audio or for one speaker. |
| `eq:reset` | mac | `target` | `main_out`, `device` | An equalizer is reset to flat, for Main Audio or for one speaker. |
| `main_out:target_selected` | mac | `target` | the new Main Audio target (a speaker, a scene, or similar) | Main Audio's target is changed. |
| `main_out:mute_toggled` | mac | `muted` | `true`, `false` | Main Audio's master mute is toggled. |
| `bt_sync:trim_committed` / `cast_sync:offset_committed` | mac | — | — | A drag on a speaker's sync offset control is released and the value is committed (Bluetooth or Chromecast, depending on which name fires). |
| `cast_sync:offset_reset` | mac | — | — | A Chromecast speaker's sync offset is reset. |
| `bt_sync:note_hidden` | mac | — | — | The "this speaker plays a little behind" first-join note is dismissed without starting the wizard. |
| `bt_sync:wizard_started` | mac | `target`, `door` | `target`: `local` or `bluetooth`; `door`: which of the four entry points opened it | The by-ear alignment wizard starts for a speaker. |
| `bt_sync:wizard_finished` | mac | — | — | The by-ear alignment wizard is completed (a result is kept). |
| `bt_sync:wizard_abandoned` | mac | `target_lost` | `true`, `false` | The by-ear alignment wizard is closed without finishing; `target_lost` is true if the speaker disappeared mid-run. |
| `bt_sync:drift_corrected` | mac | `action`, `placement`, `magnitude_ms_bucket`, `surfaced` | `action`: `correct`, `swap_recorrect`; `placement`: `gap`, `slew`; `magnitude_ms_bucket`: `0-9`, `10-39`, `40-99`, `100+`; `surfaced`: `true`, `false` | The passive drift tracker moves a Bluetooth speaker's alignment after measuring it from the playing music. Fired after the move lands, never before. No device names or ids. |
| `bt_volume:hardware_toggled` | mac | `enabled` | `true`, `false` | The "Control speaker volume" checkbox on a Bluetooth speaker's detail page is flipped, and the new choice was saved to disk. Not sent when the save fails. |
| `onboarding:usage_stats_opted_in` | mac | — | — | The user turns on "Share anonymous usage statistics" during first-run setup, with the card's "Share Usage Counts" button. This is the event that makes every other opt-in Mac event start flowing; it can only ever be seen after the fact, from the presence of later events. |
| `onboarding:setup_completed` | mac | — | — | First-run setup is marked complete. |
| `onboarding:step_granted` | mac | `step` | `audio`, `local_network`, `bluetooth`, `speaker_sync`, `remote_control`, `audiout_remote`, `usage_stats` | A first-run setup step turns complete while the Setup window is open (a grant landing, or the iPhone connecting). Not sent for a step already complete when the window opened. Steps before the usage-statistics card are held in memory and sent only once the user opts in during that same session; a decline or quit drops them. |
| `onboarding:step_skipped` | mac | `step` | `bluetooth`, `remote_control`, `audiout_remote`, `usage_stats` | The user passes on a skippable setup step (Skip for now, or No Thanks on usage statistics). Same hold-until-opt-in rule as `onboarding:step_granted`, so a usage-statistics decline is never actually sent. |
| `onboarding:moved_to_applications` | mac | — | — | The user takes the "Move to Applications" alert shown when macOS is running Audiout from a temporary read-only location, and the copy in Applications is in place with the relaunch started. Not sent when any step of the move fails. Held until the usage-statistics opt-in like the other onboarding rows; sent by the copy in Applications on its first launch after the move. |
| `bt_sync:link_settled` | mac | `speaker`, `codec`, `jump_count`, `settle_seconds_bucket`, `offset_ms_bucket`, `offset_source`, `speaker_kind` | `speaker`: a per-install index (a plain counter, different for every copy of Audiout), never the Bluetooth UID, address or name; `codec`: the negotiated Bluetooth codec, absent if it cannot be read; `jump_count`: number of clock jumps since this connection; `settle_seconds_bucket`: seconds from connect to settled as `0-9`, `10-29`, `30-59` or `60+`, absent when the 60 s floor produced the verdict rather than ten jump-free seconds; `offset_ms_bucket`: see the phone table below; `offset_source`: see below; `speaker_kind`: `bluetooth` (this event only ever fires for Bluetooth speakers) | Once per Bluetooth connection, the first time the Mac's clock verdict reaches settled, or when the link drops before that happens. Opt-in only; never sent for a user who has not turned on "Share anonymous usage statistics". |
| `bt_sync:offset_applied` | mac | `offset_source`, `offset_ms_bucket` | `offset_source`: `measured`, `firstPass`, `fromLastTime`; `offset_ms_bucket`: see the phone table below | Each time the Mac applies an offset to a Bluetooth speaker, whether from a fresh measurement, a first-pass measurement, or the value remembered from the speaker's last connection. Opt-in only. |
| `remote_invite:sheet_shown` | mac | `state` | `allow_off`, `qr`, `connected` | The alignment wizard sheet's "Measure with your iPhone" panel is shown, with which of its three visible states it opened in. |
| `remote_invite:settings_link_opened` | mac | — | — | The "Open audiout.app/remote" button under Settings' Allow switch is clicked. |
| `remote_invite:setup_card_shown` | mac | — | — | The first-run setup card for Audiout Remote is shown. |
| `remote_invite:setup_link_opened` | mac | — | — | The setup card's "Open audiout.app/remote" button is clicked. |
| `support:diagnostics_saved` | mac | — | — | The user saves a diagnostics file from Settings. |
| `intro:card_seen` | phone | `mac_id` (absent before a Mac connects) | — | The phone app's introductory card is shown on first launch. |
| `intro:find_mac_tapped` | phone | `mac_id` (absent before a Mac connects) | — | The intro card's "Find your Mac" control is tapped. |
| `connect:connected` | phone | `mac_id` | — | The phone successfully connects to a Mac. |
| `demo:entered` | phone | `mac_id` (absent — demo mode has no real Mac) | — | The phone enters demo mode (the pretend Mac with six pretend speakers). |
| `sync:opened` | phone | `mac_id`, `speaker_kind` | `speaker_kind`: `bluetooth`, `airplay`, `cast` | The sync screen for one speaker is opened. |
| `sync:measure_tapped` | phone | `mac_id`, `speaker_kind` | see above | The Measure (tuning fork) button is tapped, starting a probe run. |
| `sync:verdict` | phone | `mac_id`, `speaker_kind`, `offset_source`, `settled`, `offset_ms_bucket`, `verdict` | `offset_source`: `measured`, `firstPass`, `fromLastTime`, `byEar`; `settled`: `true`/`false`, the Mac's clock verdict for that speaker at this moment; `offset_ms_bucket`: `0-9`, `10-39`, `40-99`, `100+` (absolute value, in milliseconds); `verdict`: `applied`, `firstPass`, `refused` | A probe run finishes and the phone shows its result. |
| `sync:recheck_accepted` | phone | `mac_id`, `speaker_kind` | see above | The phone's offer to re-check a first-pass measurement (once the Mac reports the speaker settled) is accepted. |
| `sync:by_ear_nudged` | phone | `mac_id`, `speaker_kind` | see above | The user moves the by-ear slider one step in the sync sheet. One event per nudge, so a run's count says how much fiddling it took. Owner ruling 2026-09-10; the earlier reading (once per run that could not get a confident answer) is retired. |

## Licence server events

The licence server (`aa-hh/audiout-license-server`) also sends events, always
gated `sent by: server` below. Its distinct id is the Mac's `install_id` —
the same value that is the Mac's own PostHog anonymous id — except for
`build_downloaded`, which has no install to name and uses a random throwaway
id instead, and a `license_purchased` bought with no prior trial, which is
named by the Paddle transaction id instead of an install.

| event | sent by | properties | allowed values | when it fires |
|---|---|---|---|---|
| `trial_started` | server | `outcome`, `offline_start` | `outcome`: `issued`; `offline_start`: `true`/`false`, whether the trial's start date predates this request (the Mac started it offline, days earlier) | A new trial key is issued. |
| `trial_resumed` | server | — | — | A device asks for a trial it already has, and gets the same key back. |
| `trial_refused` | server | `state` | `live`, `expired`, `converted` | A device asks for a trial and is refused because it already has one in that state. |
| `trial_expired` | server | `converted` | `false` | The daily cron marks a trial expired without it having converted. |
| `trial_converted` | server | `days_into_trial`, `after_expiry` | `days_into_trial`: whole days from trial start to purchase; `after_expiry`: `true`/`false`, whether the trial had already expired at purchase | A trial key's purchase webhook lands and the trial is marked converted. |
| `license_purchased` | server | `from_trial`, `source` | `from_trial`: `true`/`false`; `source`: where the purchase came from | A purchase webhook issues a paid key, once per sale. |
| `build_downloaded` | server | `major` | the downloaded build's major version | A build is downloaded. |

## Diagnostic logs

Alongside events, the licence server and the website send PostHog Logs
(OpenTelemetry log records, EU cloud, 14-day retention). Same project, same
rules as events: no device name, person's name, email, bundle identifier or
network identifier. The Mac app sends no logs: its diagnostic log is written
on the Mac and stays there. The phone sends none either.

| `service.name` | sender | gate | what a line is |
|---|---|---|---|
| `license-server` | licence server worker | always on; no PII by construction | one `log.*` call from `src/log.ts`: a fixed message, attributes carry ids and outcomes. Emails and IPs appear only as `to_hash` / `ip_hash` (salted SHA-256, first 8 bytes). Never a key or token. |
| `website` | website worker | always on | errors only: `path`, `method`, `error`. |

Resource attributes on every record: `service.name` and
`deployment.environment` (`production`, `staging`, `development`). Filter the
Logs view by `service.name` first.

### Failure reports from the Mac app

Instead of logs, the Mac app sends the failures a user felt to PostHog error
tracking, as `$exception` events. Same gate as every Mac event: the "Share
anonymous usage statistics" opt-in, off by default. The exception type is one
of the eight names below, each written into the Mac's source as a literal, so no
runtime value can become an exception's identity. Only the properties listed
here leave the Mac; the speaker id, the file path and the raw error text stay
in the local log. That type is the only locator a report carries; the matching
line in the Mac's local `telemetry.jsonl`, at `level:error`, holds the detail.
Unhandled crashes are reported by the PostHog SDK itself and are not in this
list.

| exception type | properties | allowed values | when it fires |
|---|---|---|---|
| `airplay:session_failed` | `state`, `cause`, `wasStreaming` | `state`: `failed`, `passwordRequired`; `cause`: `authRequired`, `droppedMidStream`, `unknown`; `wasStreaming`: `true`, `false` | A live AirPlay session dies while the user still wants that speaker on. |
| `airplay:connect_failed` | `cause` | `timingUnavailable`, `authRequired`, `timedOut`, `unknown` | An AirPlay speaker fails to connect. |
| `capture:whole_system_failed` | `kind`, `retrying` | `kind`: `tap_creation_failed`, `aggregate_device_failed`, `format_read_failed`, `device_lost`, `os_unsupported`; `retrying`: `true`, `false` | System audio capture fails while capture is wanted. |
| `settings:save_failed` | `domain`, `code` | `domain`: the Cocoa error domain; `code`: the Cocoa error code | A settings file cannot be written. The error's localised description stays local, because it can carry a file path. |
| `settings:file_corrupt` | `files` | a comma-joined list of Audiout's own settings file names, never a user path | Unreadable settings files are set aside at launch. |
| `bt:connect_failed` | `reason` | `timeout`, `no_audio_endpoint`, or a Bluetooth status code as `0x` hex | A Bluetooth speaker fails to connect. |
| `bt_volume:hardware_write_failed` | — | — | Setting a Bluetooth speaker's own volume fails, so that speaker's slider goes back to scaling the sound on the Mac for the rest of the session. The speaker id stays local. |
| `bt_volume:store_write_failed` | — | — | The "Control speaker volume" choices cannot be saved to disk. The choice still holds for the session. The error text stays local, because it can carry a file path. |

## Notes on shared properties

- `offset_source` (`measured`, `firstPass`, `fromLastTime`, and, on the phone
  only, `byEar`): where the applied offset came from. Corresponds to
  `CONTEXT.md`'s "Offset source", "First pass," and "Timing from last time."
  Published by the Mac on `DeviceState.AlignmentState.source`; the phone
  reads it rather than computing it, except for `byEar`, which only the Mac's
  own by-ear wizard can produce.
- `settled` (`true`/`false`): the Mac's clock verdict for a Bluetooth
  speaker at the moment of the event. Corresponds to `CONTEXT.md`'s
  "Settled." The wire's own words are `settling`/`steady`; this property is
  the boolean form of that same verdict.
- `speaker_kind` (`bluetooth`, `airplay`, `cast`): which kind of speaker the
  event is about.
- `offset_ms_bucket` (`0-9`, `10-39`, `40-99`, `100+`): the applied offset's
  size in milliseconds, in absolute value, bucketed so no event carries a
  raw, potentially fingerprinting number.
- `verdict` (`applied`, `firstPass`, `refused`): what the phone did with a
  measurement it just took.
- `mac_id`: the join key described above.
