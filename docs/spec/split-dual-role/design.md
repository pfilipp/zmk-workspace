# Halcyon Ferris: runtime switch between dongle mode and standalone mode

Status: DESIGN APPROVED (2026-09-24)

## Goal

Switch the Halcyon Ferris between two operating modes with a keyboard shortcut,
without reflashing or re-pairing anything:

- **Dongle mode** (today's default): the dongle is the split central and talks
  to the host. Both halves are split peripherals.
- **Standalone mode**: the left half is the split central and talks BLE
  directly to a host (Vision Pro, macOS). The right half is its peripheral.
  The dongle sits idle.

Three keys on the existing BT row of the shared keymap drive it:

| Key today      | Key after        | Meaning                                   |
|----------------|------------------|-------------------------------------------|
| `&bt BT_SEL 0` | `&split_mode DONGLE`  | dongle mode                          |
| `&bt BT_SEL 1` | `&split_mode HOST 1`  | standalone, host profile 1 (Vision Pro) |
| `&bt BT_SEL 2` | `&split_mode HOST 2`  | standalone, host profile 2 (macOS)   |
| `&bt BT_CLR`   | unchanged        | clears the active host profile of whoever runs the keymap |

## Non-goals

- Hot switching without a reboot of the left half. A one to two second reboot
  is accepted.
- Changing the e-paper status widget. It stays compiled for the central role
  and shows stale host status while in dongle mode. Follow-up.
- Any change to the existing (non-dual) build targets. They must keep
  producing functionally identical firmware.

## Hard constraints

1. **No flashing, no re-pairing on a mode switch.** One initial flash of all
   three devices with the new firmware is fine.
2. **Dongle-mode power stays as it is today.** In dongle mode the left half
   must not scan, must not advertise to hosts, must not run the keymap or HID
   stacks. The peripheral path is the same code that runs today. The only
   permanent cost is flash for the unused role.
3. **Dongle may stay plugged in.** It must never take the right half while in
   standalone mode.
4. **Fully separate from the current setup.** All fork changes sit behind
   Kconfig options that default to off. Old build targets and the shared
   keymap are unchanged unless a target opts in.

## Current state (what is compile-time today)

The split role is `CONFIG_ZMK_SPLIT_ROLE_CENTRAL`, a Kconfig bool. It gates
roughly fifteen places in `zmk/app`:

- `CMakeLists.txt`: keymap, HID, endpoints, behaviors, combos and listeners
  are only linked for the central.
- `src/split/CMakeLists.txt`, `src/split/bluetooth/CMakeLists.txt`: link
  `central.c` or `peripheral.c` (+`service.c`), and one of two linker sections
  for the transport registry.
- `src/ble.c`: host profiles, host advertising, peripheral address storage.
- `src/behavior.c`: central forwards global/peripheral-local behaviors over
  the split; peripheral executes what it is told.
- `src/pm.c`, `src/behaviors/behavior_soft_off.c`, `src/pointing/input_split.c`,
  `include/zmk/ble.h`, plus Kconfig gates in `src/pointing/Kconfig`,
  `src/studio/Kconfig`, `src/display/widgets/Kconfig` and the Halcyon
  e-paper shield.

A pure peripheral image has no keymap and no HID stack at all. All BLE bonds
on every ZMK device live on `BT_ID_DEFAULT`. The peripheral allows exactly one
bond (`BT_MAX_PAIRED=1`) and direct-advertises to the first bond it finds.
That single bond is why the right half must be re-paired whenever its central
changes.

The keymap is shared: `config/halcyon_ferris_dongle.keymap` includes
`config/halcyon_ferris.keymap`. ZMK's build accepts `-DKEYMAP_FILE=<path>` to
override keymap selection per target.

## Design

### State model

| Device     | Persists                                              | Role by mode |
|------------|-------------------------------------------------------|--------------|
| Left half  | `split/mode`, `split/dongle_addr` (set when it bonds to the dongle in peripheral mode) | dongle mode: split peripheral. standalone: split central + BLE host keyboard |
| Dongle     | `split/mode`, `split/left_slot` (peripheral slot index of the left half) | dongle mode: accepts both halves. standalone: accepts only the left half |
| Right half | nothing new                                           | always split peripheral, bonded to both centrals, follows whoever is active |

The mode is read once at boot on the left half. Role selection is a boot-time
decision; a mode change always reboots the left half.

### Sequence: to standalone (key pressed on left half while in dongle mode)

1. The dongle interprets the key. `&split_mode` has global locality, so the
   dongle runs it locally and forwards it to both halves.
2. Dongle: save `mode=standalone`, save `left_slot=<event source slot>`,
   disconnect all peripherals. From now on its device-found callback ignores
   any address that is not the address stored for `left_slot`.
3. Left half: save `mode=standalone` and `ble/active_profile=<n>`, then from a
   work item disconnect and reboot. It boots as central, connects to the right
   half (its stored peripheral address is unchanged), advertises to host
   profile `n`.
4. Right half: ignores the behavior. It is dropped by the dongle, advertises
   with an accept list of both bonded centrals, and only the left half may
   connect because the dongle ignores it.

### Sequence: to dongle mode (key pressed on left half while standalone)

1. The left half interprets the key itself and forwards it to the right half,
   which ignores it.
2. Left half: save `mode=dongle`, disconnect the right half, reboot. It boots
   as peripheral and direct-advertises to `split/dongle_addr`, exactly as the
   current peripheral firmware does.
3. Dongle: a connection from the address of `left_slot` means dongle mode.
   Save `mode=dongle`, reopen the filter.
4. Right half: dropped by the left, advertises to both, the dongle takes it.

### No-op and profile-only cases

- `&split_mode HOST n` while already standalone: `zmk_ble_prof_select(n)`, no
  reboot.
- `&split_mode DONGLE` while in dongle mode: nothing (the dongle receives it;
  it is already in dongle mode; the left half receives it and is already
  peripheral).

### Component: left half dual-role build (fork, Kconfig `ZMK_SPLIT_ROLE_DYNAMIC`)

- `ZMK_SPLIT_ROLE_DYNAMIC` selects `ZMK_SPLIT_ROLE_CENTRAL` so every central
  Kconfig dependency (USB, HID, pointing, layer state report, display widgets)
  stays satisfied. Additionally links `src/split/peripheral.c`,
  `src/split/bluetooth/peripheral.c`, `src/split/bluetooth/service.c` and both
  transport linker sections.
- New API in `include/zmk/split/role.h`:
  `bool zmk_split_role_is_central(void)`. Without `ZMK_SPLIT_ROLE_DYNAMIC` it
  is a constant derived from `CONFIG_ZMK_SPLIT_ROLE_CENTRAL` so existing
  builds compile identically. With it, it returns the persisted mode, loaded
  from settings before any BLE or split init runs (settings handler with an
  early `SYS_INIT` priority, or a retained-memory mirror; implementation
  decides, but the value must be available before `zmk_ble_init`).
- The compile-time gates listed under "Current state" become runtime checks
  where both roles would otherwise both act:
  - `keymap.c` position/sensor listeners: bubble without acting when not
    central.
  - `behavior.c` dispatch: central path forwards; peripheral path executes.
  - `ble.c`: no host advertising, no profile-driven advertising updates, when
    not central. Profile selection still persists the setting.
  - `split/central.c` / `split/bluetooth/central.c`: transport registration
    and scanning only when central.
  - `split/peripheral.c` / `split/bluetooth/peripheral.c`: only when not
    central.
  - `input_split.c`, `pm.c`, `behavior_soft_off.c`, battery and HID
    indicator forwarding: runtime check.
  - Symbol and listener-name clashes between `central.c` and `peripheral.c`
    (both define `SYS_INIT`s and `ZMK_LISTENER`s) are resolved by renaming in
    the fork.
- Peripheral-mode advertising on the left half: direct-advertise to
  `split/dongle_addr` when set; otherwise open advertising with the split
  service UUID, as today. The dongle is learned from the first GATT write to
  the split service by a connected central that is not a bonded host (only a
  ZMK split central writes the selected physical layout or a behavior), and
  stored as `split/dongle_addr`. (Amended after the final review: learning
  from "first encrypted peer" would trust any pairing central.)
- Switch-pending guard: from the moment the switch work starts dropping links
  until the reboot, `zmk_split_role_switch_pending()` is true and no split
  transport or host advertising may restart. Without it the left re-advertises
  to the dongle within milliseconds of dropping the link, the dongle reconnects
  and flips back to dongle mode before the reboot. The dongle also ignores a
  reconnect from the standalone slot while its own delayed disconnect is
  pending.
- Host guard in peripheral mode: the HID GATT service is static and therefore
  present. In the `connected` callback, if the peer matches any stored host
  profile peer, disconnect immediately. This is what stops a Mac from latching
  onto the left half in dongle mode.
- Bond capacity: host profiles + right half + dongle. `BT_MAX_PAIRED` on the
  left half rises by one over today's default (set in the target's conf).

### Component: `&split_mode` behavior (fork, `src/behaviors/behavior_split_mode.c`)

- Binding cells: `<mode> <profile>`. Constants in
  `include/dt-bindings/zmk/split_mode.h`: `SPLIT_MODE_DONGLE`,
  `SPLIT_MODE_HOST`. Keymap macros `DONGLE` and `HOST(n)` are provided via
  the same header.
- Locality: `BEHAVIOR_LOCALITY_GLOBAL`.
- Compiled on all three devices (it is referenced from the shared keymap for
  dual targets). Behaviour by device, decided at compile time:
  - `ZMK_SPLIT_ROLE_DYNAMIC` (left half): if the requested mode differs from
    the persisted one, save mode (and profile for HOST), then submit a work
    item that disconnects peripherals and calls `sys_reboot`. If same mode
    and HOST, select the profile. Otherwise no-op.
  - `ZMK_SPLIT_ROLE_CENTRAL` without dynamic (dongle) and
    `ZMK_SPLIT_CENTRAL_MODE_GATE`: on HOST, record `left_slot` from
    `event.source`, save `mode=standalone`, disconnect all peripherals. On
    DONGLE, no-op (the reconnect of the left half flips the mode).
  - Peripheral only (right half): no-op.
- The reboot runs from a work item after the settings write returns, so the
  key release still reaches the current host and the write is complete.

### Component: dongle gate (fork, Kconfig `ZMK_SPLIT_CENTRAL_MODE_GATE`, default n)

- Persists `split/mode` and `split/left_slot`.
- `split_central_device_found` (and the reconnect-by-address path) consults
  `zmk_split_central_peripheral_allowed(addr)`: in standalone mode only the
  address stored for `left_slot` passes.
- In the peripheral `connected` path: if the connecting address is
  `left_slot`'s and mode is standalone, set `mode=dongle` and persist.
- If `left_slot` is unset (dongle never saw a switch), the gate is open.

### Component: right half multi-bond advertising (fork, Kconfig `ZMK_SPLIT_PERIPHERAL_MULTI_BOND`, default n)

- `BT_MAX_PAIRED` default becomes 2 under this option.
- `start_advertising`: while the bond table is not full (fewer than
  `BT_MAX_PAIRED` bonds) advertise openly with the split UUID, as today's
  unbonded case, so the second central can pair; the dongle's mode gate and
  the dynamic half's role gating keep the wrong central away meanwhile. Once
  the table is full, populate the filter accept list with every bond on
  `BT_ID_DEFAULT` and advertise connectable undirected with
  `BT_LE_ADV_OPT_FILTER_CONN | BT_LE_ADV_OPT_FILTER_SCAN_REQ`.
  (Amended after the final review: with the accept list active from the
  first bond, the left half could never pair.)
- Advertising interval: fast for the first 30 s after a disconnect, then the
  slow interval. The peripheral only advertises while disconnected, so idle
  power is comparable to today's low-duty directed advertising.
- Assumption to verify early in implementation: centrals use static identity
  addresses (ZMK does not enable `BT_PRIVACY`), so the accept list matches
  without a resolving list. The left half already scans with identity.

### Component: builds and keymap (this repo)

- `build.yaml`: existing four Halcyon targets unchanged. Three new targets:
  - `halcyon_ferris_left_dual`: `halcyon_wireless//zmk`, shields
    `halcyon_ferris_left mod_battery_lipo mod_display_epaper_forest mod_cirque_central`,
    cmake-args `-DCONFIG_ZMK_SPLIT_ROLE_DYNAMIC=y -DCONFIG_ZMK_HID_LAYER_STATE_REPORT=y -DKEYMAP_FILE=$(config)/halcyon_ferris_dual.keymap`
  - `halcyon_ferris_right_dual`: as `halcyon_ferris_right`, plus
    `-DCONFIG_ZMK_SPLIT_PERIPHERAL_MULTI_BOND=y`
  - `halcyon_ferris_dongle_dual`: as `halcyon_ferris_dongle`, plus
    `-DCONFIG_ZMK_SPLIT_CENTRAL_MODE_GATE=y -DKEYMAP_FILE=$(config)/halcyon_ferris_dual.keymap`
- `KEYMAP_FILE` must be an absolute path. The Justfile already computes the absolute config dir; the GitHub workflow needs the equivalent (implementation detail for the plan).
- `config/halcyon_ferris_dual.keymap`: `#define HALCYON_DUAL_ROLE 1` then
  `#include "halcyon_ferris.keymap"`.
- `config/halcyon_ferris.keymap`: the three BT keys are chosen with
  `#ifdef HALCYON_DUAL_ROLE`. No other change.
- `config/halcyon_ferris_left_dual.conf` (or cmake-args): `BT_MAX_PAIRED`
  raised by one. Left conf files are per shield name, so if a dual-specific
  conf is not picked up automatically, pass it as a cmake arg.
- `west.yml`: `zmk` revision moves to the new fork branch `split-dual-role`,
  which is `layer-state-report` plus the new commits. With all new Kconfig
  options off, old targets build identically.

## Edge cases

- **Right half asleep during a switch.** It wakes, advertises to both
  centrals, only the active one may connect. Handled.
- **Dongle unplugged during a switch to standalone.** It never learns the
  mode and will take the right half when plugged back in. Recovery: press the
  dongle key, then the standalone key, with the left half at hand. Documented,
  not solved.
- **First pairing in dongle mode.** The left half advertises openly. A host
  bonded in standalone mode may connect during that window; the host guard
  drops it.
- **Reboot at any point after the settings write.** The write is synchronous,
  the reboot is scheduled afterwards, so the switch completes on next boot.
- **Both centrals up in standalone mode.** The dongle's gate rejects the
  right half; there is no race.

## Testing

- ZMK native POSIX tests under `zmk/app/tests/split-mode/` for the behavior:
  mode change (settings written, reboot requested), profile change without
  reboot, no-op cases. Dongle-gate logic tested where it is separable from the
  BLE stack.
- All seven Halcyon targets and the Sweep targets build with `just build all`.
- On-hardware checklist, run and recorded before the work is called done:
  1. Fresh flash of all three, pair in dongle mode, pair standalone to each
     host once.
  2. Dongle → standalone (Vision Pro), standalone → dongle, dongle →
     standalone (macOS), standalone profile switch without reboot.
  3. Switch with right half asleep.
  4. Switch with dongle unplugged, then recovery sequence.
  5. Host guard: Mac bluetooth on, left half in dongle mode, no HID
     connection to the left half appears.
  6. Power: idle hour in dongle mode, battery delta compared with the current
     firmware on the left half.

## Rollback

Flash the existing non-dual artifacts and re-pair as today. The dual code is
never compiled into them.
