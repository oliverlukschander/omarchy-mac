#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

# Prints one line per hl.bind: keys, then "focus <devices>" for a bind scoped to
# keyboards, or the exec command for a launcher.
load_bindings() {
  local apple="$1"

  lua - "$ROOT" "$apple" <<'LUA'
local root, apple = arg[1], arg[2] == "1"
local function proxy()
  return setmetatable({}, {
    __index = function(self, key)
      local value = proxy()
      rawset(self, key, value)
      return value
    end,
    __call = function()
      return {}
    end,
  })
end
hl = {
  dsp = proxy(),
  on = function() end,
  define_submap = function() end,
  unbind = function(keys)
    print("unbind\t" .. keys)
  end,
  bind = function(keys, dispatcher, opts)
    if opts and opts.device then
      assert(opts.device.inclusive == true, "focus bind only matches the listed keyboards")
      assert(dispatcher == o.focus_builtin_screen, "focus bind runs the built-in screen focus")
      print(keys .. "\tfocus " .. table.concat(opts.device.list, ","))
    elseif type(dispatcher) == "table" and dispatcher.cmd then
      print(keys .. "\t" .. dispatcher.cmd)
    else
      print(keys .. "\tother")
    end
  end,
}
hl.dsp.exec_cmd = function(cmd)
  return { cmd = cmd }
end
dofile(root .. "/default/hypr/helpers.lua")
local probes = 0
o.shell_succeeds = function(command)
  if command == "omarchy-hw-apple-silicon" then
    probes = probes + 1
  end
  return apple
end
o.preinstalled_bindings_enabled = function()
  return true
end
dofile(root .. "/default/hypr/bindings/applications.lua")
dofile(root .. "/default/hypr/bindings/utilities.lua")
dofile(root .. "/default/hypr/bindings/clipboard.lua")
dofile(root .. "/default/hypr/bindings/tiling.lua")
o.bind("SUPER + F9", "Power menu (locked)", "omarchy-menu toggle system", { locked = true })
o.rebind("SUPER + SHIFT + F", "File manager", { launch = "flea" })
o.rebind("SUPER + ESCAPE", "System menu", "omarchy-menu toggle system")
assert(probes <= 2, "hardware probe runs once per config load, not per bind (" .. probes .. ")")
LUA
}

apple=$(load_bindings 1) || fail "bindings load on Apple Silicon" "$apple"
other=$(load_bindings 0) || fail "bindings load elsewhere" "$other"

keyboards="apple-spi-keyboard,apple-mtp-keyboard"

expect_focus_then() {
  local keys="$1" command="$2"
  local want=$'\n'"$keys"$'\tfocus '"$keyboards"$'\n'"$keys"$'\t'"$command"$'\n'

  [[ $'\n'"$apple"$'\n' == *"$want"* ]] || fail "$keys focuses the built-in screen first when typed on the MacBook keyboard" "$apple"
}

expect_focus_then "SUPER + SPACE" "omarchy-menu toggle"
expect_focus_then "SUPER + ALT + SPACE" "omarchy-menu toggle apps"
expect_focus_then "SUPER + ESCAPE" "omarchy-menu toggle system"
expect_focus_then "SUPER + K" "omarchy-menu-keybindings"
expect_focus_then "SUPER + CTRL + A" "omarchy-shell shell toggle omarchy.audio"
expect_focus_then "SUPER + CTRL + W" "omarchy-shell shell toggle omarchy.network"
expect_focus_then "SUPER + CTRL + code:10" "omarchy-shell -q shell togglePanelAt right 1"
pass "menus and panels typed on the MacBook keyboard focus the built-in screen first"

expect_no_focus() {
  local keys="$1" command="$2"

  grep -qxF "$keys"$'\t'"$command" <<<"$apple" || fail "$keys still binds $command" "$apple"
  grep -qxF "$keys"$'\tfocus '"$keyboards" <<<"$apple" && fail "$keys opens on the focused screen" "$apple"
  return 0
}

expect_no_focus "SUPER + RETURN" "omarchy-launch-terminal"
expect_no_focus "SUPER + SHIFT + RETURN" "omarchy-launch-browser"
expect_no_focus "SUPER + SHIFT + A" "omarchy-launch-webapp 'https://chatgpt.com'"
expect_no_focus "SUPER + SHIFT + ALT + M" "omarchy-launch-or-focus-tui 'cliamp'"
expect_no_focus "SUPER + SHIFT + W" "uwsm-app -- omawrite"
expect_no_focus "SUPER + CTRL + T" "omarchy-launch-tui 'btop'"
expect_no_focus "SUPER + CTRL + Q" "omacalc"
expect_no_focus "SUPER + SHIFT + CTRL + A" "omarchy-agent --pick"
pass "apps open on the focused screen from any keyboard"

expect_no_focus "SUPER + CTRL + E" "omarchy-shell shell toggle omarchy.emojis"
expect_no_focus "SUPER + CTRL + V" "omarchy-shell shell toggle omarchy.clipboard"
pass "pickers that paste into the focused window stay on its screen"

[[ $apple == *$'unbind\tSUPER + ESCAPE\nSUPER + ESCAPE\tfocus '"$keyboards"$'\nSUPER + ESCAPE\tomarchy-menu toggle system'* ]] ||
  fail "rebinding a menu keeps the built-in screen focus" "$apple"
[[ $apple == *$'unbind\tSUPER + SHIFT + F\nSUPER + SHIFT + F\tuwsm-app -- flea'* ]] ||
  fail "rebinding an app opens it on the focused screen" "$apple"
pass "rebinding keeps the menu and app split"

for keys in "SUPER + F9" "SUPER + BACKSPACE" "SUPER + CTRL + N" "PRINT" "ALT + PRINT" "SUPER + F12" "SUPER + LEFT" "SUPER + 1" "SUPER + SHIFT + ALT + comma"; do
  grep -qxF "$keys"$'\tfocus '"$keyboards" <<<"$apple" && fail "$keys is not a menu and keeps today's focus" "$apple"
done
pass "toggles, captures, notifications, locked and tiling binds keep today's focus"

grep -q $'\tfocus ' <<<"$other" && fail "no keyboard-scoped binds off Apple Silicon" "$other"
grep -qxF $'SUPER + SPACE\tomarchy-menu toggle' <<<"$other" || fail "off Apple Silicon the launchers still bind" "$other"
pass "no keyboard-scoped binds off Apple Silicon"

focus_with() {
  lua - "$ROOT" "$1" <<'LUA'
local root, layout = arg[1], arg[2]
hl = {
  dsp = {
    focus = function(args)
      return args
    end,
  },
  dispatch = function(dispatcher)
    print("focus " .. dispatcher.monitor)
  end,
  get_monitors = function()
    local monitors = {}
    for name, focused in layout:gmatch("([%w%-]+)(%*?)") do
      monitors[#monitors + 1] = { name = name, focused = focused == "*" }
    end
    return monitors
  end,
}
dofile(root .. "/default/hypr/helpers.lua")
o.focus_builtin_screen()
print("done")
LUA
}

[[ $(focus_with "DP-1* eDP-1") == $'focus eDP-1\ndone' ]] || fail "focus moves to the built-in screen from an external one"
[[ $(focus_with "DP-1 eDP-1*") == "done" ]] || fail "focus stays when the built-in screen already has it"
[[ $(focus_with "DP-1* HDMI-A-1") == "done" ]] || fail "clamshell: no built-in screen, focus stays"
[[ $(focus_with "eDP-1*") == "done" ]] || fail "built-in screen alone: nothing to do"
pass "built-in screen focus handles external, built-in only and clamshell layouts"
