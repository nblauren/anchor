# Anchor — Maestro Test Suite

End-to-end UI flows for visual documentation and regression testing.

---

## Prerequisites

### 1. Install Maestro

```bash
curl -Ls "https://get.maestro.mobile.dev" | bash
```

Verify: `maestro --version`

### 2. App bundle ID

| Platform | ID |
|---|---|
| iOS | `dev.nikkothe.anchor` |
| Android | `dev.nikkothe.anchor` |

### 3. Device / simulator setup

- **iOS simulator**: any iPhone simulator running iOS 16+
- **Android emulator**: API 31+ recommended
- BLE is **not available** on simulators/emulators — flows that require live peers are marked `optional: true` and will skip gracefully in CI.

### 4. Seed photos for profile setup (flow 02)

Profile creation requires at least one photo. Pre-seed the device before running:

```bash
# iOS simulator (replace UDID with your simulator UDID)
UDID=$(xcrun simctl list devices booted | grep -oE '[A-F0-9-]{36}' | head -1)
xcrun simctl addmedia "$UDID" /Users/nblaurenciana/Downloads/path_to_test_photo.png

# Android emulator
adb push /path/to/test_photo.jpg /storage/emulated/0/DCIM/Camera/test_photo.jpg
```

---

## Flow index

| File | Covers | Clears state? |
|---|---|---|
| `01_onboarding.yaml` | Splash → 4 intro pages → BLE permissions | Yes |
| `02_profile_setup.yaml` | Name/Age/Bio/Position/Interests/Photos/Preview | Yes |
| `03_discovery.yaml` | Grid, radar, filters, anchor drops list | No |
| `04_chat.yaml` | Messages tab, conversation, send text, photo sheet | No |
| `05_anchor_drop.yaml` | Drop ⚓ from grid / detail / chat AppBar | No |
| `06_settings.yaml` | Settings toggles, edit profile, debug menu | No |

> Flows 03–06 rely on a profile being set up. Run flow 02 once on the device
> before running the rest, or run the full suite sequentially (see below).

---

## Running

### Single flow

```bash
maestro test maestro/flows/01_onboarding.yaml \
  --output maestro/screenshots
```

### All flows in sequence

```bash
for flow in maestro/flows/*.yaml; do
  maestro test "$flow" --output maestro/screenshots
done
```

### All flows in parallel (faster, requires multiple connected devices)

```bash
maestro test maestro/flows/ --output maestro/screenshots
```

### Interactive studio (for debugging selectors)

```bash
maestro studio
```

---

## Screenshot output structure

```
maestro/screenshots/
  onboarding/
    01_splash.png
    02_discover_nearby.png
    03_chat_offline.png
    04_stay_private.png
    05_keep_anchor_open.png
    06_permissions_screen.png
    07_permissions_after_grant.png
    08_post_onboarding.png
  profile/
    01_name_step.png … 16_home_after_setup.png
  discovery/
    01_grid_initial.png … 13_back_to_grid.png
  chat/
    01_messages_tab.png … 10_back_to_list.png
  anchor_drop/
    01_drops_list_empty.png … 09_drops_list_final.png
  settings/
    01_profile_tab.png … 12_back_to_settings.png
```

---

## Widget keys added to Flutter source

The following `Key()` values were added to enable reliable `id:` selectors
(all added in the same PR as this README):

| Key | Widget | File |
|---|---|---|
| `onboarding_skip_btn` | Skip TextButton | `onboarding_screen.dart` |
| `onboarding_next_btn` | Next/Get Started ElevatedButton | `onboarding_screen.dart` |
| `permissions_skip_btn` | "Skip for now" TextButton | `permissions_screen.dart` |
| `profile_name_field` | Name TextFormField | `profile_setup_screen.dart` |
| `profile_age_field` | Age TextFormField | `profile_setup_screen.dart` |
| `profile_bio_field` | Bio TextFormField | `profile_setup_screen.dart` |
| `discovery_anchor_drops_btn` | Anchor Drops AppBar IconButton | `discovery_screen.dart` |
| `discovery_view_toggle_btn` | Grid/Radar toggle IconButton | `discovery_screen.dart` |
| `discovery_filter_btn` | Filter IconButton | `discovery_screen.dart` |
| `profile_settings_btn` | Settings AppBar IconButton | `profile_view_screen.dart` |
| `chat_photo_btn` | Photo IconButton | `chat_screen.dart` |
| `chat_message_input` | Message TextField | `chat_screen.dart` |
| `chat_send_btn` | Send IconButton | `chat_screen.dart` |
| `chat_anchor_btn` | Anchor AppBar IconButton | `chat_screen.dart` |
| `chat_more_menu_btn` | More PopupMenuButton | `chat_screen.dart` |

---

## Known limitations

| Limitation | Workaround |
|---|---|
| BLE discovery requires physical devices | Flows use `optional: true` — skipped gracefully in CI |
| Photos page requires at least one gallery photo | Pre-seed simulator (see setup above) |
| iOS system permission dialogs vary by OS version | Multiple `optional: true` variants cover common cases |
| Peer-dependent flows (chat, anchor drop) | Use debug menu to inject test peers, or run on physical devices |
| Radar view is visual canvas with no text — hard to assert | Screenshot-only for that step |

---

## CI integration example (GitHub Actions)

```yaml
- name: Run Maestro flows
  uses: mobile-dev-inc/action-maestro-cloud@v1
  with:
    api-key: ${{ secrets.MAESTRO_CLOUD_API_KEY }}
    app-file: build/ios/ipa/anchor.ipa   # or .apk
    workspace: maestro/flows
```
