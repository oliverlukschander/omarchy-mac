#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

auto="$ROOT/bin/omarchy-brightness-keyboard-auto"

[[ -x $auto ]] || fail "omarchy-brightness-keyboard-auto is executable"

map_lux() {
  "$auto" --map-lux "$1"
}

[[ $(map_lux 0) == 100 ]] || fail "pitch dark lights the keyboard fully" "got $(map_lux 0)"
[[ $(map_lux 8) == 100 ]] || fail "dim indoor still uses full keyboard light" "got $(map_lux 8)"
[[ $(map_lux 94) == 50 ]] || fail "mid lux maps to half keyboard light" "got $(map_lux 94)"
[[ $(map_lux 180) == 0 ]] || fail "bright room turns the keyboard light off" "got $(map_lux 180)"
[[ $(map_lux 400) == 0 ]] || fail "daylight keeps the keyboard light off" "got $(map_lux 400)"
pass "ambient lux maps inversely onto keyboard backlight"

if ! "$auto" --map-lux >/dev/null 2>&1; then
  pass "map-lux without a value is an error"
else
  fail "map-lux without a value should fail"
fi

grep -F 'Drive keyboard backlight from the ambient light sensor' "$auto" >/dev/null
pass "auto helper declares command metadata"

grep -F 'POLL_SECONDS=5' "$auto" >/dev/null || fail "ALS keyboard loop still wakes every second"
pass "ALS keyboard loop polls every 5 seconds"

grep -F 'exit $?' "$auto" >/dev/null &&
  fail "--available still relies on set -e to turn a failed [[ ]] into the exit status"
pass "--available uses an explicit if/else exit"

eval "$(sed -n '/^find_als()/,/^}/p' "$auto")"

fake=$(mktemp -d)
leds=$(mktemp -d)
trap 'rm -rf "$fake" "$leds"' EXIT
mkdir -p "$fake/iio:device0" "$fake/iio:device1" "$fake/iio:device2"

printf 'aop-sensors-las\n' >"$fake/iio:device0/name"
printf '12\n' >"$fake/iio:device0/in_illuminance_raw"
printf 'aop-sensors-als\n' >"$fake/iio:device1/name"
printf '23\n' >"$fake/iio:device1/in_illuminance_input"
printf 'ambient-light\n' >"$fake/iio:device2/name"
printf '40\n' >"$fake/iio:device2/in_illuminance_input"

got=$(OMARCHY_IIO_DEVICES_DIR=$fake find_als)
[[ $got == "$fake/iio:device1/in_illuminance_input" ]] ||
  fail "find_als prefers a device whose name contains als" "got $got"
pass "find_als prefers a named ALS device over an earlier illuminance channel"

rm -r "$fake/iio:device1"
got=$(OMARCHY_IIO_DEVICES_DIR=$fake find_als)
[[ $got == "$fake/iio:device0/in_illuminance_raw" ]] ||
  fail "find_als falls back to the first readable illuminance channel" "got $got"
pass "find_als falls back when no device name contains als"

mkdir -p "$leds/kbd_backlight"
printf '255\n' >"$leds/kbd_backlight/max_brightness"
printf '0\n' >"$leds/kbd_backlight/brightness"

if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds "$auto" --available; then
  pass "--available succeeds when both ALS and keyboard LED are present"
else
  fail "--available should succeed when both ALS and keyboard LED are present"
fi

rm -r "$leds/kbd_backlight"
if OMARCHY_IIO_DEVICES_DIR=$fake OMARCHY_LEDS_DIR=$leds "$auto" --available; then
  fail "--available should fail when the keyboard LED is missing"
else
  pass "--available fails when the keyboard LED is missing"
fi

manual="$ROOT/manual/34-keyboard-mouse-trackpad.md"
grep -F 'Lock and lid-close keep the keys off' "$manual" >/dev/null &&
  fail "manual still claims lock and lid-close turn the keys off"
grep -F 'Automatic control pauses while the screen is locked or the lid is closed' "$manual" >/dev/null ||
  fail "manual does not describe lock and lid-close as a pause"
pass "manual describes lock and lid-close as pausing automatic control"

migration=$(ls "$ROOT"/migrations/*keyboard*als* "$ROOT"/migrations/*als*keyboard* 2>/dev/null | tail -n 1 || true)
if [[ -z $migration ]]; then
  migration=$(grep -l omarchy-brightness-keyboard-auto.service "$ROOT"/migrations/*.sh | tail -n 1 || true)
fi
[[ -n $migration ]] || fail "a migration enables the ALS keyboard backlight unit"
grep -F 'omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null
grep -F 'systemctl --user enable' "$migration" >/dev/null
grep -F '/usr/lib/systemd/user/omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null ||
  fail "migration does not enable the package-owned unit"
grep -e 'cp .*omarchy-brightness-keyboard-auto.service' "$migration" >/dev/null &&
  fail "migration copies the unit into ~/.config/systemd/user"
pass "migration enables ambient keyboard backlight for existing installs"

grep -F 'EFFECTIVELY_OFF_PERCENT=2' "$auto" >/dev/null ||
  fail "ALS keyboard helper no longer treats a 1% leftover as off"
pass "ALS keyboard helper treats a 1% leftover as off"

grep -F 'If something else turns the keys fully off' "$manual" >/dev/null ||
  fail "manual does not describe recovery from a fully-off leftover"
pass "manual describes recovery from lock-blank and 0% restore"

tick_tmp=$(mktemp -d)
trap 'rm -rf "$fake" "$leds" "$tick_tmp"' EXIT

extract_fn() {
  sed -n "/^$1()/,/^}/p" "$auto"
}

DARK_LUX=8
BRIGHT_LUX=180
DEADBAND_PERCENT=4
OVERRIDE_LUX_DELTA=20
OVERRIDE_LUX_RATIO=40
EFFECTIVELY_OFF_PERCENT=2

eval "$(extract_fn lux_to_percent)"
eval "$(extract_fn led_effectively_off)"
eval "$(extract_fn read_lux)"
eval "$(extract_fn session_locked)"
eval "$(extract_fn lid_closed)"
eval "$(extract_fn apply_percent)"
eval "$(extract_fn tick)"

max=255
led_effectively_off 0 || fail "0 is effectively off"
led_effectively_off 2 || fail "2/255 (1%) is effectively off"
led_effectively_off 5 || fail "5/255 (2%) is effectively off"
if led_effectively_off 6; then
  fail "6/255 is above the 2% leftover band"
fi
pass "a 1% leftover is treated as off, a visible 3% is not"

iio="$tick_tmp/iio"
stub="$tick_tmp/bin"
kbd="$tick_tmp/leds"
mkdir -p "$iio/iio:device1" "$kbd/kbd_backlight" "$stub"
printf 'aop-sensors-als\n' >"$iio/iio:device1/name"
printf '26\n' >"$iio/iio:device1/in_illuminance_input"
printf '255\n' >"$kbd/kbd_backlight/max_brightness"
printf '2\n' >"$kbd/kbd_backlight/brightness"

cat >"$stub/brightnessctl" <<'SH'
#!/bin/bash
device=""
while (($#)); do
  case "$1" in
    -d)
      device=$2
      shift 2
      ;;
    get)
      cat "$OMARCHY_LEDS_DIR/$device/brightness"
      exit 0
      ;;
    set)
      printf '%s\n' "$2" >"$OMARCHY_LEDS_DIR/$device/brightness"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done
exit 1
SH

cat >"$stub/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash
exit "${SESSION_LOCKED:-1}"
SH

cat >"$stub/omarchy-hw-laptop-closed" <<'SH'
#!/bin/bash
exit "${LID_CLOSED:-1}"
SH

chmod +x "$stub"/*

als_path="$iio/iio:device1/in_illuminance_input"
kbd_path="$kbd/kbd_backlight"
device=kbd_backlight
max=255
export OMARCHY_LEDS_DIR=$kbd
export PATH="$stub:$PATH"

last_set=2
paused=1
pause_lux=26
tick
got=$(<"$kbd/kbd_backlight/brightness")
[[ $got == 226 ]] || fail "paused 1% leftover in a dark room is re-applied from ALS" "got $got"
(( paused == 0 )) || fail "recovering from an off leftover clears the pause"
pass "a paused 1% leftover in a dark room is restored from ALS"

printf '226\n' >"$kbd/kbd_backlight/brightness"
last_set=226
paused=0
pause_lux=0
printf '128\n' >"$kbd/kbd_backlight/brightness"
tick
got=$(<"$kbd/kbd_backlight/brightness")
[[ $got == 128 ]] || fail "a visible manual level still pauses auto" "got $got"
(( paused == 1 )) || fail "a visible manual level should set paused"
tick
got=$(<"$kbd/kbd_backlight/brightness")
[[ $got == 128 ]] || fail "paused manual level is kept while lux is stable" "got $got"
pass "Shift+F1/F2 to a visible level still pauses automatic control"

printf '2\n' >"$kbd/kbd_backlight/brightness"
last_set=2
paused=1
pause_lux=26
SESSION_LOCKED=0 tick
got=$(<"$kbd/kbd_backlight/brightness")
[[ $got == 2 ]] || fail "lock still pauses automatic control" "got $got"
pass "lock still skips ALS while the session is locked"
