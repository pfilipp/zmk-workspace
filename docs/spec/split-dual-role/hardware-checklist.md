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
