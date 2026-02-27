default:
    @just --list --unsorted

config := absolute_path('config')
build := absolute_path('.build')
out := absolute_path('firmware')
draw := absolute_path('draw')

# parse build.yaml and filter targets by expression
_parse_targets $expr:
    #!/usr/bin/env bash
    attrs="[.board, .shield, .snippet, .\"artifact-name\"]"
    filter="(($attrs | map(. // [.]) | combinations), ((.include // {})[] | $attrs)) | join(\",\")"
    echo "$(yq -r "$filter" build.yaml | grep -v "^," | grep -i "${expr/#all/.*}")"

# build firmware for single board & shield combination
_build_single $board $shield $snippet $artifact *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    artifact="${artifact:-${shield:+${shield// /+}-}${board}}"
    build_dir="{{ build / '$artifact' }}"

    echo "Building firmware for $artifact..."
    west build -s zmk/app -d "$build_dir" -b $board {{ west_args }} ${snippet:+-S "$snippet"} -- \
        -DZMK_CONFIG="{{ config }}" ${shield:+-DSHIELD="$shield"}

    if [[ -f "$build_dir/zephyr/zmk.uf2" ]]; then
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.uf2" "{{ out }}/$artifact.uf2"
    else
        mkdir -p "{{ out }}" && cp "$build_dir/zephyr/zmk.bin" "{{ out }}/$artifact.bin"
    fi

# build firmware for matching targets
build expr *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    targets=$(just _parse_targets {{ expr }})

    [[ -z $targets ]] && echo "No matching targets found. Aborting..." >&2 && exit 1
    echo "$targets" | while IFS=, read -r board shield snippet artifact; do
        just _build_single "$board" "$shield" "$snippet" "$artifact" {{ west_args }}
    done

# build sweep firmware from original (unmodified) ZMK main branch
build-sweep-original *west_args:
    #!/usr/bin/env bash
    set -euo pipefail
    zmk_main="{{ absolute_path('.zmk-main') }}"
    tmp_config=$(mktemp -d)
    trap 'git -C zmk worktree remove "$zmk_main" --force 2>/dev/null || true; rm -rf "$tmp_config"' EXIT

    # Create a temporary worktree at ZMK main branch
    git -C zmk fetch local main 2>/dev/null || true
    git -C zmk worktree add "$zmk_main" local/main --detach --force 2>/dev/null \
        || git -C zmk worktree add "$zmk_main" zmkfirmware/main --detach --force

    # Create a filtered config: strip Kconfig symbols that only exist on the feature branch
    cp -a "{{ config }}/." "$tmp_config/"
    for conf in "$tmp_config"/*.conf; do
        grep -v 'CONFIG_ZMK_HID_LAYER_STATE_REPORT' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
    done

    # Build left half
    echo "Building original firmware for splitkb_aurora_sweep_left..."
    west build -s "$zmk_main/app" -d "{{ build }}/sweep_left_original" -p \
        -b nice_nano/nrf52840/zmk {{ west_args }} -- \
        -DZMK_CONFIG="$tmp_config" \
        -DSHIELD="splitkb_aurora_sweep_left nice_view_adapter nice_view"

    # Build right half
    echo "Building original firmware for splitkb_aurora_sweep_right..."
    west build -s "$zmk_main/app" -d "{{ build }}/sweep_right_original" -p \
        -b nice_nano/nrf52840/zmk {{ west_args }} -- \
        -DZMK_CONFIG="$tmp_config" \
        -DSHIELD="splitkb_aurora_sweep_right nice_view_adapter nice_view"

    # Copy artifacts
    mkdir -p "{{ out }}"
    cp "{{ build }}/sweep_left_original/zephyr/zmk.uf2" "{{ out }}/splitkb_aurora_sweep_left-original.uf2"
    cp "{{ build }}/sweep_right_original/zephyr/zmk.uf2" "{{ out }}/splitkb_aurora_sweep_right-original.uf2"
    echo "Done! Firmware at {{ out }}/splitkb_aurora_sweep_*-original.uf2"

# clear build cache and artifacts
clean:
    rm -rf {{ build }} {{ out }}

# clear all automatically generated files
clean-all: clean
    rm -rf .west zmk

# clear nix cache
clean-nix:
    nix-collect-garbage --delete-old

# parse & plot keymap
draw:
    #!/usr/bin/env bash
    set -euo pipefail
    keymap -c "{{ draw }}/config.yaml" parse -z "{{ config }}/splitkb_aurora_sweep.keymap" >"{{ draw }}/base.yaml"
    keymap -c "{{ draw }}/config.yaml" draw "{{ draw }}/base.yaml" -k "ferris/sweep" >"{{ draw }}/base.svg"

# initialize west
init:
    west init -l config
    west update --fetch-opt=--filter=blob:none
    west zephyr-export

# list build targets
list:
    @just _parse_targets all | sed 's/,*$//' | sort | column

# update west
update:
    west update --fetch-opt=--filter=blob:none

# upgrade zephyr-sdk and python dependencies
upgrade-sdk:
    nix flake update --flake .

[no-cd]
test $testpath *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    testcase=$(basename "$testpath")
    build_dir="{{ build / "tests" / '$testcase' }}"
    config_dir="{{ '$(pwd)' / '$testpath' }}"
    cd {{ justfile_directory() }}

    if [[ "{{ FLAGS }}" != *"--no-build"* ]]; then
        echo "Running $testcase..."
        rm -rf "$build_dir"
        west build -s zmk/app -d "$build_dir" -b native_posix_64 -- \
            -DCONFIG_ASSERT=y -DZMK_CONFIG="$config_dir"
    fi

    ${build_dir}/zephyr/zmk.exe | sed -e "s/.*> //" |
        tee ${build_dir}/keycode_events.full.log |
        sed -n -f ${config_dir}/events.patterns > ${build_dir}/keycode_events.log
    if [[ "{{ FLAGS }}" == *"--verbose"* ]]; then
        cat ${build_dir}/keycode_events.log
    fi

    if [[ "{{ FLAGS }}" == *"--auto-accept"* ]]; then
        cp ${build_dir}/keycode_events.log ${config_dir}/keycode_events.snapshot
    fi
    diff -auZ ${config_dir}/keycode_events.snapshot ${build_dir}/keycode_events.log
