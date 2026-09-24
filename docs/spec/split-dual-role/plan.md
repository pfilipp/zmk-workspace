# Runtime dongle/standalone mode switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Halcyon Ferris switch between dongle mode and standalone mode with a keyboard shortcut, with no reflash and no re-pairing, while old build targets keep producing functionally identical firmware.

**Architecture:** The left half gets both split roles linked into one image behind a new Kconfig option; a persisted mode value picked up during settings load decides which role's startup runs, and a new global-locality behavior flips the mode and reboots. The dongle gets a small gate that refuses the right half while in standalone mode, and the right half learns to accept either of two bonded centrals through a filter accept list. All fork changes live behind three default-off Kconfig options.

**Tech Stack:** ZMK (fork `pfilipp/zmk`, checked out at `zmk/` by west), Zephyr 4.1 (`zephyr/`), Kconfig, devicetree, C. Builds run with `just build <target>` from the workspace root inside the direnv/nix shell (already active in this session's shell).

**Spec:** `docs/spec/split-dual-role/design.md`

## Global Constraints

- Every fork change is behind one of `CONFIG_ZMK_SPLIT_ROLE_DYNAMIC`, `CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE`, `CONFIG_ZMK_SPLIT_PERIPHERAL_MULTI_BOND`, all default `n`. With them off, existing targets must build with no new warnings and no behavioral change.
- Dongle-mode power: with the left half in peripheral mode, no BLE scanning, no host advertising, no keymap processing may start. The peripheral path must run the same code the current peripheral image runs.
- Existing four Halcyon targets and both Sweep targets in `build.yaml` stay untouched. New targets are `halcyon_ferris_left_dual`, `halcyon_ferris_right_dual`, `halcyon_ferris_dongle_dual`.
- Fork work goes on branch `split-dual-role` in `zmk/`, created from the current checkout `4994db48` (tip of `layer-state-report`). Never force-push. Commit format: `feat|fix|chore|docs(<scope>): <description>`.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et
  ```
- Behavior node names invoked on peripherals must fit `behavior_dev[16]` (15 chars + NUL).
- Unit tests: ZMK's native_sim test harness cannot run on this macOS host (Zephyr native_sim is Linux-only and the nix shell ships only the ARM toolchain). Verification for every task is: the affected targets build cleanly (`just build <target> -p`), and the final on-hardware checklist. This is a deviation from the spec's "Testing" section and must be stated in the final report.

## Review Focus

Failure modes the spec implies that no build can exercise. Each has a line in the on-hardware checklist (Task 8) and a reviewer should read the owning code with it in mind:

1. **Left half boots with no `split/mode` setting** (first boot after flash): it must come up as split peripheral in dongle mode, advertise openly with the split UUID, and never advertise HID. Owner: Task 1 default + Task 3 gates.
2. **Bonded Mac connects to the left half while it is in dongle mode**: the connection must be dropped immediately. Owner: Task 4 host guard.
3. **Switch pressed while the right half is asleep**: the right must, on waking, only be taken by the currently active central. Owner: Task 6 gate + Task 7 accept list.
4. **Left half already bonded to the dongle before the dual firmware was flashed** (no fresh pairing happens): the dongle address must still be learned so directed advertising works. Owner: Task 4 (`security_changed` capture).
5. **Profile key pressed twice quickly, or dongle key pressed while already in dongle mode**: no reboot loop, no double reboot. Owner: Task 5 early-return when mode unchanged.

---

## File Structure

Fork (`zmk/app/`):

| Path | Responsibility |
|---|---|
| `src/split/Kconfig` | Three new options (modify) |
| `src/split/bluetooth/Kconfig` | `BT_MAX_PAIRED` default 2 under multi-bond (modify) |
| `include/zmk/split/role.h` | Runtime role API; constant inline when not dynamic (create) |
| `src/split/role.c` | Persisted mode + dongle address, settings handler for tree `split` (create, dynamic only) |
| `include/zmk/ble.h` | Profile count formula under dynamic; `zmk_ble_prof_select_persist`, `zmk_ble_peripheral_addr` (modify) |
| `src/ble.c` | Role gates on advertising and startup callbacks; the two new functions (modify) |
| `src/keymap.c`, `src/combo.c` | Bubble position events when not central (modify) |
| `src/split/CMakeLists.txt`, `src/split/bluetooth/CMakeLists.txt` | Link both roles under dynamic (modify) |
| `src/split/peripheral.c` | Rename global, gate listener (modify) |
| `src/split/bluetooth/peripheral.c` | Tolerate `-EALREADY`, gate startup, dongle-addr advertising, host guard, multi-bond accept list (modify) |
| `src/split/bluetooth/central.c` | Gate `finish_init`; mode-gate hooks (modify) |
| `include/zmk/split/central_mode_gate.h`, `src/split/central_mode_gate.c` | Dongle-side gate state and API (create, gate only) |
| `include/dt-bindings/zmk/split_mode.h` | Keymap constants (create) |
| `dts/bindings/behaviors/zmk,behavior-split-mode.yaml`, `dts/behaviors/split_mode.dtsi`, `dts/behaviors.dtsi` | Behavior node (create/modify) |
| `src/behaviors/behavior_split_mode.c` | The `&split_mode` behavior (create) |
| `CMakeLists.txt` | Compile the behavior for any split build (modify) |

Workspace:

| Path | Responsibility |
|---|---|
| `build.yaml` | Three `*_dual` targets (modify) |
| `config/halcyon_ferris.keymap` | `#ifdef HALCYON_DUAL_ROLE` on the three BT keys (modify) |
| `config/west.yml` | `zmk` revision → `split-dual-role` (modify, last) |
| `docs/spec/split-dual-role/hardware-checklist.md` | On-hardware verification record (create) |

---

### Task 1: Kconfig options, runtime role API, and dual build targets

**Files:**
- Modify: `zmk/app/src/split/Kconfig`
- Modify: `zmk/app/src/split/bluetooth/Kconfig:79-103`
- Create: `zmk/app/include/zmk/split/role.h`
- Create: `zmk/app/src/split/role.c`
- Modify: `zmk/app/src/split/CMakeLists.txt`
- Modify: `zmk/app/include/zmk/ble.h:12-19`
- Modify: `build.yaml`

**Interfaces:**
- Produces: `enum zmk_split_mode { ZMK_SPLIT_MODE_DONGLE = 0, ZMK_SPLIT_MODE_STANDALONE = 1 }`, `bool zmk_split_role_is_central(void)`, `enum zmk_split_mode zmk_split_role_get_mode(void)`, `int zmk_split_role_set_mode(enum zmk_split_mode)`, `const bt_addr_le_t *zmk_split_role_dongle_addr(void)`, `int zmk_split_role_set_dongle_addr(const bt_addr_le_t *)`. Settings keys `split/mode` (u8) and `split/dongle_addr` (`bt_addr_le_t`).

- [ ] **Step 1: Create the fork branch**

```bash
cd zmk && git checkout -b split-dual-role 4994db48 && git status --short && cd ..
```
Expected: on branch `split-dual-role`, clean tree.

- [ ] **Step 2: Add the Kconfig options**

In `zmk/app/src/split/Kconfig`, directly after the `config ZMK_SPLIT_ROLE_CENTRAL` block (inside `if ZMK_SPLIT`), add:

```kconfig
config ZMK_SPLIT_ROLE_DYNAMIC
    bool "Select the split role at boot from settings"
    depends on ZMK_SPLIT_BLE && SETTINGS
    select ZMK_SPLIT_ROLE_CENTRAL
    help
      Link both the split central and the split peripheral into one image and
      pick the role at boot from the persisted split mode. The mode is changed
      with the &split_mode behavior, which reboots the device. Meant for a half
      that is sometimes a dongle's peripheral and sometimes the central itself.

config ZMK_SPLIT_CENTRAL_MODE_GATE
    bool "Dongle-side gate for a dynamic-role peripheral"
    depends on ZMK_SPLIT_ROLE_CENTRAL && !ZMK_SPLIT_ROLE_DYNAMIC && SETTINGS
    help
      Remember whether a dynamic-role peripheral switched to standalone mode
      and, while it has, only accept connections from that peripheral so the
      other half can be taken by the standalone central.

config ZMK_SPLIT_PERIPHERAL_MULTI_BOND
    bool "Peripheral accepts connections from any bonded central"
    depends on ZMK_SPLIT_BLE && !ZMK_SPLIT_ROLE_CENTRAL
    select BT_FILTER_ACCEPT_LIST
    help
      Keep bonds to two centrals and advertise with a filter accept list
      containing all of them, so the peripheral follows whichever central is
      active without re-pairing.
```

In `zmk/app/src/split/bluetooth/Kconfig`, inside `if !ZMK_SPLIT_ROLE_CENTRAL`, replace

```kconfig
config BT_MAX_PAIRED
    default 1
```
with
```kconfig
config BT_MAX_PAIRED
    default 2 if ZMK_SPLIT_PERIPHERAL_MULTI_BOND
    default 1
```

- [ ] **Step 3: Create the role header**

`zmk/app/include/zmk/split/role.h`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/sys/util_macro.h>
#include <zephyr/bluetooth/addr.h>

enum zmk_split_mode {
    ZMK_SPLIT_MODE_DONGLE = 0,     /* this half is a split peripheral; a dongle is the central */
    ZMK_SPLIT_MODE_STANDALONE = 1, /* this half is the split central and talks to hosts */
};

#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)

bool zmk_split_role_is_central(void);
enum zmk_split_mode zmk_split_role_get_mode(void);
/* Persists synchronously. Takes effect on the next boot. */
int zmk_split_role_set_mode(enum zmk_split_mode mode);

/* Address of the dongle this half bonded to while in dongle mode, or NULL if unknown. */
const bt_addr_le_t *zmk_split_role_dongle_addr(void);
int zmk_split_role_set_dongle_addr(const bt_addr_le_t *addr);

#else

static inline bool zmk_split_role_is_central(void) {
    return !IS_ENABLED(CONFIG_ZMK_SPLIT) || IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL);
}

#endif /* IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC) */
```

- [ ] **Step 4: Create the role module**

`zmk/app/src/split/role.c`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <zephyr/settings/settings.h>
#include <zephyr/logging/log.h>

#include <zmk/split/role.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

static uint8_t current_mode = ZMK_SPLIT_MODE_DONGLE;
static bt_addr_le_t dongle_addr;
static bool dongle_addr_known = false;

bool zmk_split_role_is_central(void) { return current_mode == ZMK_SPLIT_MODE_STANDALONE; }

enum zmk_split_mode zmk_split_role_get_mode(void) { return current_mode; }

int zmk_split_role_set_mode(enum zmk_split_mode mode) {
    current_mode = mode;
    return settings_save_one("split/mode", &current_mode, sizeof(current_mode));
}

const bt_addr_le_t *zmk_split_role_dongle_addr(void) {
    return dongle_addr_known ? &dongle_addr : NULL;
}

int zmk_split_role_set_dongle_addr(const bt_addr_le_t *addr) {
    bt_addr_le_copy(&dongle_addr, addr);
    dongle_addr_known = true;
    return settings_save_one("split/dongle_addr", &dongle_addr, sizeof(dongle_addr));
}

static int role_settings_set(const char *name, size_t len, settings_read_cb read_cb,
                             void *cb_arg) {
    const char *next;

    if (settings_name_steq(name, "mode", &next) && !next) {
        if (len != sizeof(current_mode)) {
            return -EINVAL;
        }
        int rc = read_cb(cb_arg, &current_mode, sizeof(current_mode));
        if (rc < 0) {
            return rc;
        }
        LOG_INF("Split mode: %s", zmk_split_role_is_central() ? "standalone (central)"
                                                                : "dongle (peripheral)");
    } else if (settings_name_steq(name, "dongle_addr", &next) && !next) {
        if (len != sizeof(dongle_addr)) {
            return -EINVAL;
        }
        int rc = read_cb(cb_arg, &dongle_addr, sizeof(dongle_addr));
        if (rc < 0) {
            return rc;
        }
        dongle_addr_known = true;
    }

    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(zmk_split_role, "split", NULL, role_settings_set, NULL, NULL);
```

Note: `settings_load()` in `main()` runs every handler's `h_set` for all stored keys before any handler's `h_commit`, so the mode is known by the time the BLE and split transports finish their startup in their own `h_commit` callbacks (Tasks 2 and 3 rely on this).

- [ ] **Step 5: Link the module and fix the profile count**

`zmk/app/src/split/CMakeLists.txt`, append at the end:

```cmake
target_sources_ifdef(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC app PRIVATE role.c)
```

`zmk/app/include/zmk/ble.h`, replace lines 15-19 with:

```c
#if ZMK_BLE_IS_CENTRAL
#define ZMK_SPLIT_BLE_PERIPHERAL_COUNT CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
/* One bond slot is reserved for the dongle this half pairs with in dongle mode. */
#define ZMK_BLE_PROFILE_COUNT                                                                      \
    (CONFIG_BT_MAX_PAIRED - CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS - 1)
#else
#define ZMK_BLE_PROFILE_COUNT (CONFIG_BT_MAX_PAIRED - CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS)
#endif
#else
#define ZMK_BLE_PROFILE_COUNT CONFIG_BT_MAX_PAIRED
#endif
```

- [ ] **Step 6: Add the three dual targets to `build.yaml`**

Append to the `include:` list (after the standalone target):

```yaml
  # Dual-role variant: one left firmware that switches between dongle mode and
  # standalone mode at runtime via &split_mode. See docs/spec/split-dual-role/.
  - board: halcyon_wireless//zmk
    shield: halcyon_ferris_left mod_battery_lipo mod_display_epaper_forest mod_cirque_central
    cmake-args: -DCONFIG_ZMK_SPLIT_ROLE_DYNAMIC=y -DCONFIG_ZMK_HID_LAYER_STATE_REPORT=y -DCONFIG_BT_MAX_PAIRED=7 -DDTS_EXTRA_CPPFLAGS=-DHALCYON_DUAL_ROLE=1
    artifact-name: halcyon_ferris_left_dual
  - board: halcyon_wireless//zmk
    shield: halcyon_ferris_right mod_battery_lipo mod_cirque_hw_right
    cmake-args: -DCONFIG_ZMK_SPLIT_PERIPHERAL_MULTI_BOND=y -DDTS_EXTRA_CPPFLAGS=-DHALCYON_DUAL_ROLE=1
    artifact-name: halcyon_ferris_right_dual
  - board: halcyon_dongle//zmk
    shield: halcyon_ferris_dongle mod_cirque_central
    cmake-args: -DCONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE=y -DDTS_EXTRA_CPPFLAGS=-DHALCYON_DUAL_ROLE=1
    artifact-name: halcyon_ferris_dongle_dual
```

`DTS_EXTRA_CPPFLAGS` is a Zephyr cmake variable passed to the devicetree preprocessor (`zephyr/cmake/modules/dts.cmake:262`); the keymap picks it up in Task 8.

- [ ] **Step 7: Build**

```bash
just build halcyon_ferris_left_dual -p 2>&1 | tail -15
just build halcyon_ferris_left_standalone -p 2>&1 | tail -5
```
Expected: both succeed. The dual build links only `role.c` extra at this point. Confirm `role.c` compiled: `grep -c role.c.obj .build/halcyon_ferris_left_dual/build.ninja` prints ≥ 1.

- [ ] **Step 8: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(split): Kconfig options and runtime role API for dynamic split role

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
git add build.yaml && git commit -q -m "feat(halcyon): add dual-role build targets

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et"
```

---

### Task 2: Link both split transports into the dynamic build

**Files:**
- Modify: `zmk/app/src/split/CMakeLists.txt`
- Modify: `zmk/app/src/split/bluetooth/CMakeLists.txt`
- Modify: `zmk/app/src/split/peripheral.c:30,81-121,141-146`
- Modify: `zmk/app/src/split/bluetooth/peripheral.c:236-266`
- Modify: `zmk/app/src/split/bluetooth/central.c:1274-1282`

**Interfaces:**
- Consumes: `zmk_split_role_is_central()` from Task 1.
- Produces: a dual image that links; in peripheral mode only the peripheral transport becomes "available", in central mode only the central transport.

- [ ] **Step 1: CMake — link both roles under dynamic**

`zmk/app/src/split/CMakeLists.txt` — replace the `if (CONFIG_ZMK_SPLIT_ROLE_CENTRAL) ... else() ... endif()` block with:

```cmake
if (CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
    target_sources(app PRIVATE central.c)
    zephyr_linker_sources(SECTIONS ../../include/linker/zmk-split-transport-central.ld)
endif()

if (NOT CONFIG_ZMK_SPLIT_ROLE_CENTRAL OR CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
    target_sources(app PRIVATE peripheral.c)
    zephyr_linker_sources(SECTIONS ../../include/linker/zmk-split-transport-peripheral.ld)
endif()
```
(keep the `role.c` line from Task 1 after it).

`zmk/app/src/split/bluetooth/CMakeLists.txt` — replace the first two `if` blocks with:

```cmake
if (NOT CONFIG_ZMK_SPLIT_ROLE_CENTRAL OR CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
  target_sources(app PRIVATE service.c)
  target_sources(app PRIVATE peripheral.c)
endif()
if (CONFIG_ZMK_SPLIT_ROLE_CENTRAL)
  target_sources(app PRIVATE central.c)
endif()
```

- [ ] **Step 2: Build to see the expected link failure**

```bash
just build halcyon_ferris_left_dual 2>&1 | grep -E "multiple definition|error" | head
```
Expected: `multiple definition of 'active_transport'` (defined in both `split/central.c:24` and `split/peripheral.c:30`). If other duplicates are listed, note them; each must be fixed by renaming the peripheral-side symbol with an `peripheral_` prefix in Step 3.

- [ ] **Step 3: Rename the peripheral's global and gate its listener**

In `zmk/app/src/split/peripheral.c`:
- Rename every occurrence of `active_transport` to `active_peripheral_transport` (declaration on line 30 and the uses in `zmk_split_peripheral_report_event` and `select_first_available_transport`, `transport_status_changed_cb`).
- Add `#include <zmk/split/role.h>` after `#include <zmk/split/transport/peripheral.h>`.
- At the top of `split_peripheral_listener`, before `LOG_DBG("");`, add:

```c
    if (zmk_split_role_is_central()) {
        /* Dynamic-role build running as central: nothing to forward. */
        return ZMK_EV_EVENT_BUBBLE;
    }
```

- [ ] **Step 4: Gate the BLE peripheral transport startup**

In `zmk/app/src/split/bluetooth/peripheral.c`:
- Add `#include <zmk/split/role.h>` next to the other `zmk/` includes.
- In `zmk_peripheral_ble_complete_startup`, as the first statement:

```c
    if (zmk_split_role_is_central()) {
        LOG_DBG("Split role is central; BLE split peripheral transport stays unavailable");
        return 0;
    }
```
- In `zmk_peripheral_ble_init`, change the `bt_enable` error check to tolerate the other role's init having enabled BT already:

```c
    int err = bt_enable(NULL);

    if (err < 0 && err != -EALREADY) {
        LOG_ERR("BLUETOOTH FAILED (%d)", err);
        return err;
    }
```

- [ ] **Step 5: Gate the BLE central transport startup**

In `zmk/app/src/split/bluetooth/central.c`:
- Add `#include <zmk/split/role.h>` next to the other `zmk/` includes.
- In `finish_init`, as the first statement:

```c
    if (!zmk_split_role_is_central()) {
        LOG_DBG("Split role is peripheral; BLE split central transport stays unavailable");
        return 0;
    }
```
`settings_loaded` stays false, so `split_central_bt_get_status().available` is false and `split/central.c` never enables it, which means no scanning ever starts in dongle mode.

- [ ] **Step 6: Build all three role variants**

```bash
just build halcyon_ferris_left_dual 2>&1 | tail -6
just build halcyon_ferris_left_standalone -p 2>&1 | tail -3
just build halcyon_ferris_right -p 2>&1 | tail -3
just build halcyon_ferris_dongle -p 2>&1 | tail -3
```
Expected: all four succeed, no warnings mentioning `split`. Record the dual left FLASH usage line from the memory report for the final report.

- [ ] **Step 7: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(split): link both split transports in a dynamic-role build

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 3: Role gates in ble.c, keymap.c, combo.c and the two new BLE helpers

**Files:**
- Modify: `zmk/app/src/ble.c:178-183,258-283,381-418,700-712`
- Modify: `zmk/app/include/zmk/ble.h`
- Modify: `zmk/app/src/keymap.c:817-830`
- Modify: `zmk/app/src/combo.c:510-517`

**Interfaces:**
- Produces: `int zmk_ble_prof_select_persist(uint8_t index)` (selects and writes `ble/active_profile` synchronously, bypassing the 60 s debounce); `const bt_addr_le_t *zmk_ble_peripheral_addr(uint8_t index)` (central builds only; NULL when out of range).

- [ ] **Step 1: Gate host advertising and startup in `ble.c`**

Add `#include <zmk/split/role.h>` after `#include <zmk/ble.h>`.

In `update_advertising`, after the existing `#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL) ... #endif` block (the profile-advertising early return), add:

```c
    if (!zmk_split_role_is_central()) {
        /* Dongle mode: this half is a split peripheral and must never advertise as a host keyboard. */
        return 0;
    }
```

In `zmk_ble_complete_startup`, replace

```c
    bt_conn_cb_register(&conn_callbacks);
    bt_conn_auth_cb_register(&zmk_ble_auth_cb_display);
    bt_conn_auth_info_cb_register(&zmk_ble_auth_info_cb_display);

    zmk_ble_ready(0);
```
with
```c
    if (!zmk_split_role_is_central()) {
        /* Dongle mode: the split peripheral transport owns connection and pairing callbacks. */
        LOG_INF("Split role is peripheral; host BLE profiles are dormant");
        return 0;
    }

    bt_conn_cb_register(&conn_callbacks);
    bt_conn_auth_cb_register(&zmk_ble_auth_cb_display);
    bt_conn_auth_info_cb_register(&zmk_ble_auth_info_cb_display);

    zmk_ble_ready(0);
```
The profile settings are still loaded by `ble_profiles_handle_set` in peripheral mode; Task 4's host guard depends on that.

- [ ] **Step 2: Add the synchronous profile select**

In `ble.c`, directly after `zmk_ble_prof_select`:

```c
int zmk_ble_prof_select_persist(uint8_t index) {
    int err = zmk_ble_prof_select(index);
    if (err) {
        return err;
    }
#if IS_ENABLED(CONFIG_SETTINGS)
    k_work_cancel_delayable(&ble_save_work);
    return settings_save_one("ble/active_profile", &active_profile, sizeof(active_profile));
#else
    return 0;
#endif
}
```

- [ ] **Step 3: Add the peripheral address accessor**

In `ble.c`, inside the existing `#if IS_ENABLED(CONFIG_ZMK_SPLIT_BLE) && IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)` block that holds `zmk_ble_put_peripheral_addr`, add after it:

```c
const bt_addr_le_t *zmk_ble_peripheral_addr(uint8_t index) {
    if (index >= ZMK_SPLIT_BLE_PERIPHERAL_COUNT) {
        return NULL;
    }
    return &peripheral_addrs[index];
}
```

In `zmk/app/include/zmk/ble.h`: after `int zmk_ble_prof_select(uint8_t index);` add `int zmk_ble_prof_select_persist(uint8_t index);`. Inside the `#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_CENTRAL)` block add `const bt_addr_le_t *zmk_ble_peripheral_addr(uint8_t index);`.

- [ ] **Step 4: Gate the keymap and combo listeners**

`zmk/app/src/keymap.c`: add `#include <zmk/split/role.h>` with the other `zmk/` includes. In `keymap_listener`, first statement:

```c
    if (!zmk_split_role_is_central()) {
        /* Dongle mode: positions are forwarded by the split peripheral, not processed here. */
        return ZMK_EV_EVENT_BUBBLE;
    }
```

`zmk/app/src/combo.c`: add `#include <zmk/split/role.h>` with the other `zmk/` includes. In `behavior_combo_listener`, first statement, the same three lines (comment: "Dongle mode: combos are resolved on the central."). Combos capture position events, so without this gate they would swallow keys before the split peripheral forwards them.

- [ ] **Step 5: Build**

```bash
just build halcyon_ferris_left_dual 2>&1 | tail -4
just build halcyon_ferris_left_standalone 2>&1 | tail -3
just build halcyon_ferris_dongle 2>&1 | tail -3
```
Expected: all succeed. `zmk_split_role_is_central()` is a constant `true` in the non-dynamic builds, so the compiler drops the gates.

- [ ] **Step 6: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(ble): runtime role gates for host advertising, keymap and combos

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 4: Left half in dongle mode — directed advertising to the dongle and the host guard

**Files:**
- Modify: `zmk/app/src/split/bluetooth/peripheral.c:51-73,87-100,119-129`

**Interfaces:**
- Consumes: `zmk_split_role_dongle_addr`, `zmk_split_role_set_dongle_addr` (Task 1), `zmk_ble_profile_index` (existing, `ble.h`).

- [ ] **Step 1: Choose the central address by role**

In `zmk/app/src/split/bluetooth/peripheral.c`, replace `start_advertising` with:

```c
static void find_central_addr(bt_addr_le_t *central_addr) {
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
    /* Bonds on BT_ID_DEFAULT also hold hosts and the other half; only the stored dongle counts. */
    const bt_addr_le_t *dongle = zmk_split_role_dongle_addr();
    if (dongle) {
        bt_addr_le_copy(central_addr, dongle);
    }
#else
    bt_foreach_bond(BT_ID_DEFAULT, each_bond, central_addr);
#endif
}

static int start_advertising(bool low_duty) {
    bt_addr_le_t central_addr = bt_addr_le_none;

    find_central_addr(&central_addr);

    if (bt_addr_le_cmp(&central_addr, BT_ADDR_LE_NONE) != 0) {
        is_bonded = true;
        struct bt_le_adv_param adv_param = low_duty ? *BT_LE_ADV_CONN_DIR_LOW_DUTY(&central_addr)
                                                    : *BT_LE_ADV_CONN_DIR(&central_addr);
        return bt_le_adv_start(&adv_param, NULL, 0, NULL, 0);
    } else {
        is_bonded = false;
        return bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, zmk_ble_ad, ARRAY_SIZE(zmk_ble_ad), NULL, 0);
    }
};
```
Wrap the now-conditionally-unused `each_bond` in `#if !IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC) ... #endif` to avoid an unused-function warning. (Task 7 replaces this function again for the multi-bond option; both `#if` branches must coexist, see Task 7 Step 1.)

- [ ] **Step 2: Host guard on connect**

In `connected()`, before `is_connected = (err == 0);`:

```c
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
    if (err == 0 && zmk_ble_profile_index(bt_conn_get_dst(conn)) >= 0) {
        char addr[BT_ADDR_LE_STR_LEN];
        bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
        LOG_WRN("Dropping host %s: this half is in dongle mode", addr);
        bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        return;
    }
#endif
```
`recycled()` restarts advertising after the drop.

- [ ] **Step 3: Learn the dongle address once the link is encrypted**

In `security_changed()`, inside the `if (!err)` branch after the `LOG_DBG`:

```c
#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
        if (level >= BT_SECURITY_L2 && !zmk_split_role_dongle_addr()) {
            LOG_INF("Recording %s as the dongle", addr);
            zmk_split_role_set_dongle_addr(bt_conn_get_dst(conn));
        }
#endif
```
This covers both a fresh pairing and a bond that already existed before the dual firmware was flashed.

- [ ] **Step 4: Build**

```bash
just build halcyon_ferris_left_dual 2>&1 | tail -4
just build halcyon_ferris_right 2>&1 | tail -3
```
Expected: both succeed, no `unused` warnings from `peripheral.c`.

- [ ] **Step 5: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(split): dongle-mode advertising and host guard for dynamic role

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 5: The `&split_mode` behavior

**Files:**
- Create: `zmk/app/include/dt-bindings/zmk/split_mode.h`
- Create: `zmk/app/dts/bindings/behaviors/zmk,behavior-split-mode.yaml`
- Create: `zmk/app/dts/behaviors/split_mode.dtsi`
- Modify: `zmk/app/dts/behaviors.dtsi`
- Create: `zmk/app/src/behaviors/behavior_split_mode.c`
- Modify: `zmk/app/CMakeLists.txt:44`

**Interfaces:**
- Consumes: Task 1 role API, `zmk_ble_prof_select_persist` (Task 3).
- Produces: keymap bindings `&split_mode SM_DONGLE`, `&split_mode SM_HOST <n>`. Task 6 adds the dongle branch into this file at the marked spot.

- [ ] **Step 1: Keymap constants**

`zmk/app/include/dt-bindings/zmk/split_mode.h`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#define SPLIT_MODE_DONGLE_CMD 0
#define SPLIT_MODE_HOST_CMD 1

/* &split_mode SM_DONGLE      -> become a split peripheral of the dongle */
/* &split_mode SM_HOST <n>    -> become the split central and talk to host profile n */
#define SM_DONGLE SPLIT_MODE_DONGLE_CMD 0
#define SM_HOST SPLIT_MODE_HOST_CMD
```

- [ ] **Step 2: Devicetree binding and node**

`zmk/app/dts/bindings/behaviors/zmk,behavior-split-mode.yaml`:

```yaml
# Copyright (c) 2026 The ZMK Contributors
# SPDX-License-Identifier: MIT

description: Split Mode Behavior (dongle mode vs standalone mode)

compatible: "zmk,behavior-split-mode"

include: two_param.yaml
```

`zmk/app/dts/behaviors/split_mode.dtsi`:

```dts
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

/ {
    behaviors {
        // Only instantiated when a keymap references it, so non-dual builds are untouched.
        /omit-if-no-ref/
        // Invoked on peripherals over the split link: node name must be <= 15 characters.
        split_mode: splitmode {
            compatible = "zmk,behavior-split-mode";
            #binding-cells = <2>;
            display-name = "Split Mode";
        };
    };
};
```

`zmk/app/dts/behaviors.dtsi`: append `#include <behaviors/split_mode.dtsi>` after the `mouse_keys.dtsi` include.

- [ ] **Step 3: The behavior source**

`zmk/app/src/behaviors/behavior_split_mode.c`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT zmk_behavior_split_mode

#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/logging/log.h>

#include <drivers/behavior.h>
#include <dt-bindings/zmk/split_mode.h>
#include <zmk/behavior.h>
#include <zmk/split/role.h>
#include <zmk/events/position_state_changed.h>

#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)
#include <zmk/ble.h>
#endif

#if IS_ENABLED(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE)
#include <zmk/split/central_mode_gate.h>
#endif

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#if DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT)

#if IS_ENABLED(CONFIG_ZMK_SPLIT_ROLE_DYNAMIC)

/* Time for the settings write and any in-flight split command to complete before we drop links. */
#define SWITCH_DELAY_MS 100
/* Time for the disconnects to go out on air before the reboot. */
#define REBOOT_DELAY_MS 300

static void reboot_work_cb(struct k_work *work) {
    LOG_INF("Rebooting into new split mode");
    sys_reboot(SYS_REBOOT_WARM);
}

static K_WORK_DELAYABLE_DEFINE(reboot_work, reboot_work_cb);

static void disconnect_conn(struct bt_conn *conn, void *data) {
    bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
}

static void switch_work_cb(struct k_work *work) {
    bt_conn_foreach(BT_CONN_TYPE_LE, disconnect_conn, NULL);
    k_work_schedule(&reboot_work, K_MSEC(REBOOT_DELAY_MS));
}

static K_WORK_DELAYABLE_DEFINE(switch_work, switch_work_cb);

static int handle_pressed(struct zmk_behavior_binding *binding,
                          struct zmk_behavior_binding_event event) {
    enum zmk_split_mode requested = (binding->param1 == SPLIT_MODE_DONGLE_CMD)
                                        ? ZMK_SPLIT_MODE_DONGLE
                                        : ZMK_SPLIT_MODE_STANDALONE;

    if (binding->param1 == SPLIT_MODE_HOST_CMD) {
        int err = zmk_ble_prof_select_persist(binding->param2);
        if (err) {
            LOG_ERR("Failed to select host profile %d (%d)", binding->param2, err);
        }
    }

    if (requested == zmk_split_role_get_mode()) {
        LOG_DBG("Already in split mode %d", requested);
        return ZMK_BEHAVIOR_OPAQUE;
    }

    if (k_work_delayable_is_pending(&switch_work) || k_work_delayable_is_pending(&reboot_work)) {
        LOG_DBG("Mode switch already in progress");
        return ZMK_BEHAVIOR_OPAQUE;
    }

    int err = zmk_split_role_set_mode(requested);
    if (err) {
        LOG_ERR("Failed to persist split mode %d (%d)", requested, err);
        return ZMK_BEHAVIOR_OPAQUE;
    }

    LOG_INF("Split mode -> %s, rebooting shortly",
            requested == ZMK_SPLIT_MODE_DONGLE ? "dongle" : "standalone");
    k_work_schedule(&switch_work, K_MSEC(SWITCH_DELAY_MS));
    return ZMK_BEHAVIOR_OPAQUE;
}

#elif IS_ENABLED(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE)

static int handle_pressed(struct zmk_behavior_binding *binding,
                          struct zmk_behavior_binding_event event) {
    /* TASK6: dongle branch */
    return ZMK_BEHAVIOR_OPAQUE;
}

#else

static int handle_pressed(struct zmk_behavior_binding *binding,
                          struct zmk_behavior_binding_event event) {
    /* Plain peripheral (the right half): the centrals handle the switch. */
    return ZMK_BEHAVIOR_OPAQUE;
}

#endif

static int on_keymap_binding_pressed(struct zmk_behavior_binding *binding,
                                     struct zmk_behavior_binding_event event) {
    return handle_pressed(binding, event);
}

static int on_keymap_binding_released(struct zmk_behavior_binding *binding,
                                      struct zmk_behavior_binding_event event) {
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api behavior_split_mode_driver_api = {
    .binding_pressed = on_keymap_binding_pressed,
    .binding_released = on_keymap_binding_released,
    .locality = BEHAVIOR_LOCALITY_GLOBAL,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

BEHAVIOR_DT_INST_DEFINE(0, NULL, NULL, NULL, NULL, POST_KERNEL, CONFIG_KERNEL_INIT_PRIORITY_DEFAULT,
                        &behavior_split_mode_driver_api);

#endif /* DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT) */
```

Notes for the implementer: `BEHAVIOR_LOCALITY_GLOBAL` makes the central invoke it locally and forward it to every peripheral (`behavior.c:98-103`). Forwarding is queued on a work queue before the local call, and the local call only schedules work, so the forwarded command still goes out before any disconnect. The `/* TASK6 */` placeholder is intentional and is replaced in Task 6.

- [ ] **Step 4: Compile it for every split build**

`zmk/app/CMakeLists.txt`, after `target_sources(app PRIVATE src/behaviors/behavior_reset.c)` (line 44, outside the central-only block):

```cmake
target_sources_ifdef(CONFIG_ZMK_SPLIT app PRIVATE src/behaviors/behavior_split_mode.c)
```
The file compiles to nothing unless a keymap references the node, so non-dual builds stay unchanged.

- [ ] **Step 5: Temporary keymap reference to force instantiation, then build**

Temporarily edit `config/halcyon_ferris.keymap`: add `#include <dt-bindings/zmk/split_mode.h>` next to the other `dt-bindings` includes and replace `&bt BT_SEL 0` on the numpad layer with `&split_mode SM_DONGLE`. Then:

```bash
just build halcyon_ferris_left_dual 2>&1 | tail -4
just build halcyon_ferris_right_dual 2>&1 | tail -4
```
Expected: both succeed; `grep -c behavior_split_mode .build/halcyon_ferris_right_dual/build.ninja` ≥ 1. Then **revert the keymap edit** (`git checkout config/halcyon_ferris.keymap`); Task 8 does the real keymap change.

- [ ] **Step 6: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(behaviors): add split_mode behavior for dongle/standalone switching

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 6: Dongle-side mode gate

**Files:**
- Create: `zmk/app/include/zmk/split/central_mode_gate.h`
- Create: `zmk/app/src/split/central_mode_gate.c`
- Modify: `zmk/app/src/split/CMakeLists.txt`
- Modify: `zmk/app/src/split/bluetooth/central.c:797-806,922-949`
- Modify: `zmk/app/src/behaviors/behavior_split_mode.c` (the `TASK6` branch)

**Interfaces:**
- Consumes: `zmk_ble_peripheral_addr` (Task 3), `enum zmk_split_mode` (Task 1), `ZMK_POSITION_STATE_CHANGE_SOURCE_LOCAL` (`zmk/events/position_state_changed.h`), `peripheral_slot_index_for_conn` (existing in `central.c`).
- Produces: `bool zmk_split_central_mode_gate_allows(const bt_addr_le_t *addr)`, `int zmk_split_central_mode_gate_enter_standalone(uint8_t left_slot)`, `void zmk_split_central_mode_gate_peripheral_connected(int slot)`. Settings keys `split/mode` (u8) and `split/left_slot` (u8).

- [ ] **Step 1: Header**

`zmk/app/include/zmk/split/central_mode_gate.h`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/bluetooth/addr.h>

/* True when the central may connect to a peripheral advertising from addr. */
bool zmk_split_central_mode_gate_allows(const bt_addr_le_t *addr);

/* The peripheral in slot left_slot asked to become standalone: remember it, refuse the others. */
int zmk_split_central_mode_gate_enter_standalone(uint8_t left_slot);

/* A peripheral connected into slot; if it is the standalone one, we are back in dongle mode. */
void zmk_split_central_mode_gate_peripheral_connected(int slot);
```

- [ ] **Step 2: Module**

`zmk/app/src/split/central_mode_gate.c`:

```c
/*
 * Copyright (c) 2026 The ZMK Contributors
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/settings/settings.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/split/role.h>
#include <zmk/split/central_mode_gate.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#define LEFT_SLOT_UNKNOWN 0xFF

/* Let the forwarded split command reach the peripherals before we drop them. */
#define DISCONNECT_DELAY_MS 500

static uint8_t mode = ZMK_SPLIT_MODE_DONGLE;
static uint8_t left_slot = LEFT_SLOT_UNKNOWN;

static int persist(void) {
    int err = settings_save_one("split/mode", &mode, sizeof(mode));
    if (err) {
        return err;
    }
    return settings_save_one("split/left_slot", &left_slot, sizeof(left_slot));
}

bool zmk_split_central_mode_gate_allows(const bt_addr_le_t *addr) {
    if (mode != ZMK_SPLIT_MODE_STANDALONE || left_slot == LEFT_SLOT_UNKNOWN) {
        return true;
    }

    const bt_addr_le_t *left = zmk_ble_peripheral_addr(left_slot);
    return left != NULL && bt_addr_le_cmp(addr, left) == 0;
}

static void disconnect_peripheral(struct bt_conn *conn, void *data) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) == 0 && info.role == BT_CONN_ROLE_CENTRAL) {
        bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
    }
}

static void disconnect_work_cb(struct k_work *work) {
    bt_conn_foreach(BT_CONN_TYPE_LE, disconnect_peripheral, NULL);
}

static K_WORK_DELAYABLE_DEFINE(disconnect_work, disconnect_work_cb);

int zmk_split_central_mode_gate_enter_standalone(uint8_t slot) {
    mode = ZMK_SPLIT_MODE_STANDALONE;
    left_slot = slot;

    int err = persist();
    if (err) {
        LOG_ERR("Failed to persist standalone mode (%d)", err);
        return err;
    }

    LOG_INF("Peripheral in slot %d goes standalone; releasing peripherals", slot);
    k_work_schedule(&disconnect_work, K_MSEC(DISCONNECT_DELAY_MS));
    return 0;
}

void zmk_split_central_mode_gate_peripheral_connected(int slot) {
    if (mode == ZMK_SPLIT_MODE_STANDALONE && slot >= 0 && slot == left_slot) {
        mode = ZMK_SPLIT_MODE_DONGLE;
        LOG_INF("Standalone peripheral is back; dongle mode");
        int err = persist();
        if (err) {
            LOG_ERR("Failed to persist dongle mode (%d)", err);
        }
    }
}

static int gate_settings_set(const char *name, size_t len, settings_read_cb read_cb,
                             void *cb_arg) {
    const char *next;
    uint8_t *target = NULL;

    if (settings_name_steq(name, "mode", &next) && !next) {
        target = &mode;
    } else if (settings_name_steq(name, "left_slot", &next) && !next) {
        target = &left_slot;
    }

    if (target) {
        if (len != sizeof(*target)) {
            return -EINVAL;
        }
        int rc = read_cb(cb_arg, target, sizeof(*target));
        if (rc < 0) {
            return rc;
        }
    }

    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(zmk_split_central_mode_gate, "split", NULL, gate_settings_set, NULL,
                               NULL);
```

`zmk/app/src/split/CMakeLists.txt`, append:

```cmake
target_sources_ifdef(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE app PRIVATE central_mode_gate.c)
```
(`role.c` and `central_mode_gate.c` both own settings tree `split`; Kconfig makes the two options mutually exclusive so they never share a build.)

- [ ] **Step 3: Hooks in the BLE central transport**

`zmk/app/src/split/bluetooth/central.c`:
- Add `#if IS_ENABLED(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE)` / `#include <zmk/split/central_mode_gate.h>` / `#endif` with the other includes.
- In `split_central_eir_found`, as the first statements:

```c
#if IS_ENABLED(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE)
    if (!zmk_split_central_mode_gate_allows(addr)) {
        LOG_DBG("Mode gate: ignoring peripheral while standalone");
        return false;
    }
#endif
```
- In `split_central_connected`, directly after `confirm_peripheral_slot_conn(conn);`:

```c
#if IS_ENABLED(CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE)
    zmk_split_central_mode_gate_peripheral_connected(peripheral_slot_index_for_conn(conn));
#endif
```

- [ ] **Step 4: Dongle branch of the behavior**

In `behavior_split_mode.c`, replace the `TASK6` function body with:

```c
    if (binding->param1 != SPLIT_MODE_HOST_CMD) {
        /* Back to dongle mode is signalled by the standalone half reconnecting to us. */
        return ZMK_BEHAVIOR_OPAQUE;
    }

    if (event.source == ZMK_POSITION_STATE_CHANGE_SOURCE_LOCAL) {
        LOG_WRN("split_mode pressed on the dongle itself; ignoring");
        return ZMK_BEHAVIOR_OPAQUE;
    }

    int err = zmk_split_central_mode_gate_enter_standalone(event.source);
    if (err) {
        LOG_ERR("Failed to enter standalone mode (%d)", err);
    }
    return ZMK_BEHAVIOR_OPAQUE;
```
`event.source` is the peripheral slot index the keypress came from (`split/central.c:41-46`), which equals the index into `peripheral_addrs` (`reserve_peripheral_slot` → `zmk_ble_put_peripheral_addr`).

- [ ] **Step 5: Build with the temporary keymap reference, then revert**

Apply the same temporary keymap edit as Task 5 Step 5, then:

```bash
just build halcyon_ferris_dongle_dual -p 2>&1 | tail -4
just build halcyon_ferris_dongle -p 2>&1 | tail -3
```
Expected: both succeed. Revert the keymap edit afterwards (`git checkout config/halcyon_ferris.keymap`).

- [ ] **Step 6: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(split): dongle-side mode gate for a dynamic-role peripheral

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 7: Right half — accept either bonded central

**Files:**
- Modify: `zmk/app/src/split/bluetooth/peripheral.c` (the `find_central_addr`/`start_advertising` area from Task 4)

**Interfaces:**
- Consumes: Zephyr `bt_le_filter_accept_list_clear()`, `bt_le_filter_accept_list_add()`, `BT_LE_ADV_OPT_FILTER_CONN`, `BT_LE_ADV_OPT_FILTER_SCAN_REQ` (all in `zephyr/include/zephyr/bluetooth/bluetooth.h`), `CONFIG_BT_FILTER_ACCEPT_LIST` (selected by the Kconfig option in Task 1).

- [ ] **Step 1: Accept-list advertising**

In `peripheral.c`, wrap the Task 4 `find_central_addr` + `start_advertising` pair in `#if !IS_ENABLED(CONFIG_ZMK_SPLIT_PERIPHERAL_MULTI_BOND) ... #else ... #endif`, with this in the `#else` branch:

```c
static void add_bond_to_accept_list(const struct bt_bond_info *info, void *user_data) {
    int *count = user_data;
    char addr[BT_ADDR_LE_STR_LEN];

    bt_addr_le_to_str(&info->addr, addr, sizeof(addr));

    int err = bt_le_filter_accept_list_add(&info->addr);
    if (err) {
        LOG_ERR("Failed to add %s to the filter accept list (%d)", addr, err);
        return;
    }

    LOG_DBG("Accepting central %s", addr);
    (*count)++;
}

/* Advertise to every bonded central at once; whichever is currently the active central connects.
 * Interval matches the low-duty directed advertising the single-bond path settles into, so idle
 * power is comparable. The low_duty flag is meaningless for undirected advertising. */
static int start_advertising(bool low_duty) {
    ARG_UNUSED(low_duty);
    int count = 0;

    int err = bt_le_filter_accept_list_clear();
    if (err) {
        LOG_ERR("Failed to clear the filter accept list (%d)", err);
        return err;
    }

    bt_foreach_bond(BT_ID_DEFAULT, add_bond_to_accept_list, &count);

    if (count > 0) {
        is_bonded = true;
        return bt_le_adv_start(BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONN | BT_LE_ADV_OPT_FILTER_CONN |
                                                   BT_LE_ADV_OPT_FILTER_SCAN_REQ,
                                               BT_GAP_ADV_FAST_INT_MIN_2, BT_GAP_ADV_FAST_INT_MAX_2,
                                               NULL),
                               zmk_ble_ad, ARRAY_SIZE(zmk_ble_ad), NULL, 0);
    }

    is_bonded = false;
    return bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, zmk_ble_ad, ARRAY_SIZE(zmk_ble_ad), NULL, 0);
}
```
`each_bond` must also be excluded from the multi-bond branch (it is unused there). Both ZMK centrals scan and connect with their identity address (`BT_SCAN_WITH_IDENTITY` is selected for every central), and ZMK does not enable `BT_PRIVACY`, so bond addresses match the accept list without a resolving list.

- [ ] **Step 2: Build every peripheral variant**

```bash
just build halcyon_ferris_right_dual -p 2>&1 | tail -4
just build halcyon_ferris_right -p 2>&1 | tail -3
just build halcyon_ferris_left_dual 2>&1 | tail -3
```
Expected: all succeed; the right_dual build's `.config` has `CONFIG_BT_MAX_PAIRED=2` and `CONFIG_BT_FILTER_ACCEPT_LIST=y`:

```bash
grep -E "^CONFIG_BT_MAX_PAIRED=|^CONFIG_BT_FILTER_ACCEPT_LIST=" .build/halcyon_ferris_right_dual/zephyr/.config
```

- [ ] **Step 3: Commit**

```bash
cd zmk && git add -A && git commit -q -m "feat(split): peripheral multi-bond advertising with a filter accept list

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et" && cd ..
```

---

### Task 8: Workspace wiring — keymap, fork branch push, manifest, full build, hardware checklist

**Files:**
- Modify: `config/halcyon_ferris.keymap:13-22,217`
- Modify: `config/west.yml:31`
- Create: `docs/spec/split-dual-role/hardware-checklist.md`

- [ ] **Step 1: Keymap switch on the DTS flag**

In `config/halcyon_ferris.keymap`, after `#include <dt-bindings/zmk/bt.h>` add:

```c
#include <dt-bindings/zmk/split_mode.h>

/* Dual-role builds (HALCYON_DUAL_ROLE via -DDTS_EXTRA_CPPFLAGS) switch dongle/standalone mode with
 * the BT keys; every other build keeps plain profile selection. */
#ifdef HALCYON_DUAL_ROLE
#define BT_KEY_0 &split_mode SM_DONGLE
#define BT_KEY_1 &split_mode SM_HOST 1
#define BT_KEY_2 &split_mode SM_HOST 2
#else
#define BT_KEY_0 &bt BT_SEL 0
#define BT_KEY_1 &bt BT_SEL 1
#define BT_KEY_2 &bt BT_SEL 2
#endif
```
On the numpad layer replace `&bt BT_SEL 0       &bt BT_SEL 1      &bt BT_SEL 2` with `BT_KEY_0           BT_KEY_1          BT_KEY_2` (keep the column alignment). The `split_mode.h` include is unconditional; it exists on the fork branch for every build.

- [ ] **Step 2: Push the fork branch and point the manifest at it**

```bash
cd zmk && git log --oneline 4994db48..HEAD && git push pfilipp split-dual-role && cd ..
```
Expected: seven commits listed; push creates the remote branch (a plain push of a new branch, never a force-push). Then in `config/west.yml` change `revision: layer-state-report` under the `zmk` project to `revision: split-dual-role`, and run:

```bash
west update zmk 2>&1 | tail -3 && git -C zmk rev-parse HEAD
```
Expected: HEAD unchanged (west now tracks the pushed branch at the same commit). If `west update` moves HEAD or detaches to an older commit, re-run `git -C zmk checkout split-dual-role`.

- [ ] **Step 3: Build everything**

```bash
just build all -p 2>&1 | grep -E "Building firmware|FLASH:|error|warning: .*split" 
ls firmware/
```
Expected: nine artifacts (`splitkb_aurora_sweep_left/right`, `halcyon_ferris_dongle`, `halcyon_ferris_left`, `halcyon_ferris_right`, `halcyon_ferris_left_standalone`, `halcyon_ferris_left_dual`, `halcyon_ferris_right_dual`, `halcyon_ferris_dongle_dual`), no errors, no new warnings. Save the FLASH lines of `halcyon_ferris_left` (old peripheral build) and `halcyon_ferris_left_dual` for the report.

- [ ] **Step 4: Check the non-dual targets are functionally unchanged**

```bash
for t in halcyon_ferris_left halcyon_ferris_right halcyon_ferris_dongle halcyon_ferris_left_standalone; do
  echo "== $t"; grep -E "^CONFIG_ZMK_SPLIT_ROLE_DYNAMIC|^CONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE|^CONFIG_ZMK_SPLIT_PERIPHERAL_MULTI_BOND|^CONFIG_BT_MAX_PAIRED=" .build/$t/zephyr/.config
done
grep -c "splitmode" .build/halcyon_ferris_left/zephyr/zephyr.dts .build/halcyon_ferris_left_dual/zephyr/zephyr.dts
```
Expected: none of the three new options appear in the old targets' `.config` (Kconfig omits `n` symbols that are not visible); `BT_MAX_PAIRED` is 1 for the old right, 6 for the old left/dongle. The `splitmode` node count is 0 for the old left and ≥ 1 for the dual left.

- [ ] **Step 5: Write the hardware checklist**

`docs/spec/split-dual-role/hardware-checklist.md`:

```markdown
# Split dual-role: on-hardware checklist

Flash order: `settings_reset` on all three devices first (clears every bond), then
`halcyon_ferris_left_dual`, `halcyon_ferris_right_dual`, `halcyon_ferris_dongle_dual`.
Keys are on the NUMPAD layer, left half, top row: key 1 = dongle mode, key 2 = standalone on
profile 1, key 3 = standalone on profile 2, key 4 = clear active profile.

| # | Check | Expected | Result |
|---|-------|----------|--------|
| 1 | Fresh boot, dongle plugged in | Both halves connect to the dongle; typing works on both; left shows no HID advertising to hosts | |
| 2 | Press key 2 | Left reboots (~2 s); Vision Pro sees "Halcyon Ferris" for pairing on profile 1; right half follows the left; dongle keeps only nothing connected | |
| 3 | Press key 3 (still standalone) | No reboot; left advertises to Mac for profile 2; right stays connected | |
| 4 | Press key 1 | Left reboots into dongle mode; dongle reconnects left, then right; typing works | |
| 5 | Press key 2 again | As in 2, but Vision Pro reconnects without pairing | |
| 6 | Right half asleep during a switch (wait 30 min idle, or hold nothing and switch right after sleep) | After waking, right connects only to the active central | |
| 7 | Dongle unplugged during a switch to standalone, replugged later | Dongle takes the right half (known limitation); pressing key 1 then key 2 recovers | |
| 8 | Host guard: in dongle mode, Mac Bluetooth on and previously bonded | No HID connection from the left to the Mac appears; log shows "Dropping host" if it tried | |
| 9 | Power: 1 h idle in dongle mode on the dual firmware vs 1 h on `halcyon_ferris_left` | Battery delta comparable | |
| 10 | If pairing to the dongle fails with a security error in step 1 | Rebuild left_dual with `-DCONFIG_BT_GATT_AUTO_SEC_REQ=y` added to its cmake-args and retry | |
```

- [ ] **Step 6: Commit the workspace**

```bash
git add config/halcyon_ferris.keymap config/west.yml docs/spec/split-dual-role/hardware-checklist.md
git commit -q -m "feat(halcyon): runtime dongle/standalone switch on the BT keys for dual builds

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015E8GyX6BnRNX4AeyGNe5et"
git log --oneline -4
```

---

## Self-review notes

- Spec coverage: state model (T1, T6), both sequences (T5, T6, T7), no-op cases (T5), left dual build and runtime gates (T2, T3), peripheral-mode advertising and host guard (T4), bond capacity (T1 `BT_MAX_PAIRED=7` + profile count), behavior (T5), dongle gate (T6), right half multi-bond (T7), builds/keymap/manifest (T1, T8), edge cases and hardware checklist (T8). Not covered on purpose: the spec's native POSIX tests (environment cannot run them; see Global Constraints), and `pm.c`/`behavior_soft_off.c` runtime gates (both compile as central in the dual build and their central-only extra work is harmless in peripheral mode: `zmk_endpoint_clear_reports` with no reports, and the 100 ms sleep before soft-off).
- Deviation from spec wording: keymap constants are `SM_DONGLE` / `SM_HOST n` instead of `DONGLE` / `HOST n`, to avoid clashing with common macro names. The keymap wrapper file was replaced by `-DDTS_EXTRA_CPPFLAGS`, which is simpler and CI-safe.
- Deviation from spec: right-half advertising stays at the fast interval permanently rather than dropping to a slow interval; today's single-bond path also settles at the same 100-150 ms interval, so idle power is unchanged and reconnects stay quick.
