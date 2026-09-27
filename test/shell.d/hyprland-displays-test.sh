#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

require_command lua

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

run_lua() {
  local home="$1"
  mkdir -p "$home/.local/state/omarchy/toggles/hypr"
  HOME="$home" XDG_STATE_HOME="$home/.local/state" OMARCHY_PATH="$ROOT" lua -
}

model_output=$(run_lua "$tmpdir/model" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local model = require("default.hypr.displays.model")

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

local benq = "BNQ BenQ LCD T4M01236019"

-- Identity: EDID description first, connector only as the tie-breaker.
local monitors = model.identify({
  { name = "eDP-1", description = "", serial = "" },
  { name = "USB-2", description = benq, serial = "T4M01236019" },
  { name = "DP-1", description = "Dell U2720Q", serial = "0" },
})
eq(monitors[1].key, "eDP-1", "internal panel key")
eq(monitors[1].selector, "eDP-1", "internal panel selector")
eq(monitors[2].key, "desc:" .. benq, "external key")
eq(monitors[2].selector, "desc:" .. benq, "external selector")
eq(monitors[3].key, "desc:Dell U2720Q@DP-1", "zero serial joins the connector")
eq(monitors[3].selector, "DP-1", "zero serial is selected by connector")

local twins = model.identify({
  { name = "USB-1", description = "LG 27UL850 ABC", serial = "ABC" },
  { name = "USB-2", description = "LG 27UL850 ABC", serial = "ABC" },
})
eq(twins[1].key, "desc:LG 27UL850 ABC@USB-1", "first twin key")
eq(twins[2].selector, "USB-2", "twins are selected by connector")
eq(model.safe_when_absent("USB-2"), false, "connector rules are unsafe while absent")
eq(model.safe_when_absent("eDP-1"), true, "the internal connector is safe while absent")
eq(model.is_virtual("FALLBACK") and model.is_virtual("HEADLESS-2"), true, "synthetic outputs")

-- Geometry and scale.
local w, h = model.logical_size(2560, 1440, 1.6, 0)
eq(w .. "x" .. h, "1600x900", "logical size")
w, h = model.logical_size(2560, 1440, 1.6, 1)
eq(w .. "x" .. h, "900x1600", "rotated logical size")
eq(model.snap_scale(1.6000000238418579), 1.6, "float32 scale snaps to k/120")
eq(model.clean_scale(1.25, 3456, 2160), 160 / 120, "1.25 is not clean on 3456x2160")
eq(model.step_scale(2, 1, 3456, 2160), 3, "step up on the MacBook panel")
eq(model.step_scale(1.6, -1, 2560, 1440), 1.25, "step down on a 1440p display")
eq(model.step_scale(4, 1, 2560, 1440), 4, "step up stops at the top")

-- Main and numbering.
local desk = {
  ["desc:" .. benq] = { x = 0, y = 0, w = 1600, h = 900 },
  ["eDP-1"] = { x = 1600, y = 180, w = 1152, h = 720 },
}
eq(model.main(desk), "eDP-1", "the internal panel is main")
eq(model.numbering(desk)[1], "desc:" .. benq, "D1 is the left display")
eq(model.main({ a = { x = 5, y = 0 }, b = { x = -3, y = 0 } }), "b", "without the panel, the leftmost is main")

-- A display seen for the first time: right of main, bottoms flush.
local x, y = model.place_new({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, 1600, 900)
eq(x .. "," .. y, "1152,-180", "new display right of main, bottom-aligned")
x, y = model.place_new(desk, 1920, 1080)
eq(x .. "," .. y, "2752,-180", "new display right of main on the desk")
x, y = model.place_new({
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 },
  other = { x = 1152, y = 0, w = 1000, h = 720 },
}, 800, 600)
eq(x .. "," .. y, "2152,120", "new display goes past whatever is right of main")

-- Joining: the remembered layout, shifted so what's on stays put.
local layouts = { { positions = { ["eDP-1"] = { 1600, 180 }, ["desc:" .. benq] = { 0, 0 } } } }
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "-1600,-180", "replug lands at the remembered spot relative to main")
x, y = model.place_joining({}, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "0,0", "with nothing on, the stored position is used as is")
x, y = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "unknown", 800, 600, layouts)
eq(x .. "," .. y, "1152,120", "an unknown display gets the default spot")
local blocked = {
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 },
  third = { x = -1600, y = -180, w = 1600, h = 900 },
}
x, y = model.place_joining(blocked, "desc:" .. benq, 1600, 900, layouts)
eq(x .. "," .. y, "1152,-180", "a remembered spot that is taken falls back to the default")
local mru = {
  { positions = { ["eDP-1"] = { 0, 0 }, a = { 1152, 0 } } },
  { positions = { ["eDP-1"] = { 0, 0 }, a = { -500, 0 } } },
}
x = model.place_joining({ ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720 } }, "a", 500, 500, mru)
eq(x, 1152, "the most recently used layout wins")

-- Reflow: main keeps its spot, neighbours keep side and alignment.
local new = model.reflow(desk, { ["eDP-1"] = { w = 864, h = 540 } })
eq(new["eDP-1"].x .. "," .. new["eDP-1"].y, "1600,180", "resized main keeps its position")
eq(new["desc:" .. benq].x .. "," .. new["desc:" .. benq].y, "0,-180", "neighbour stays left with bottoms flush")
new = model.reflow(desk, { ["desc:" .. benq] = { w = 2560, h = 1440 } })
eq(new["desc:" .. benq].x .. "," .. new["desc:" .. benq].y, "-960,-540", "resized neighbour re-seats against main")
local stacked = {
  ["eDP-1"] = { x = 0, y = 900, w = 1152, h = 720 },
  top = { x = -224, y = 0, w = 1600, h = 900 },
}
new = model.reflow(stacked, { top = { w = 2560, h = 1440 } })
eq(new.top.x .. "," .. new.top.y, "-704,-540", "a display above stays centred")
local tangled = {
  a = { x = 0, y = 0, w = 100, h = 100 },
  b = { x = 100, y = 0, w = 100, h = 50 },
  c = { x = 100, y = 50, w = 100, h = 50 },
}
new = model.reflow(tangled, { b = { w = 100, h = 100 } })
for key, rect in pairs(new) do
  assert(model.fits(new, rect, key), "reflow never overlaps: " .. key)
end
eq(new.a.x .. "," .. new.a.y, "0,0", "strip fallback keeps main")

-- Remember: most recent first, one entry per set, bounded.
local remembered = model.remember({
  { positions = { a = { 0, 0 } } },
  { positions = { a = { 0, 0 }, b = { 1, 0 } } },
}, { a = { x = 5, y = 5 } }, 16)
eq(#remembered, 2, "same set replaces its entry")
eq(remembered[1].positions.a[1], 5, "newest first")
eq(#model.remember(remembered, { c = { x = 0, y = 0 } }, 2), 2, "bounded")

-- Plan: complete set, desc rules first, unsafe absent rules left out.
local present = {
  ["eDP-1"] = { x = 0, y = 0, w = 1152, h = 720, selector = "eDP-1", scale = 3, transform = 0, description = "" },
}
local known = {
  ["desc:" .. benq] = { selector = "desc:" .. benq, size = { 2560, 1440 }, scale = 1.6, transform = 0 },
  ["desc:LG@USB-1"] = { selector = "USB-1", size = { 3840, 2160 }, scale = 2, transform = 0 },
}
local rules = model.plan(present, known, layouts)
eq(#rules, 2, "absent connector-selected display gets no rule")
eq(rules[1].selector, "desc:" .. benq, "desc rules come first")
eq(rules[1].x .. "," .. rules[1].y, "-1600,-180", "absent display rule is precomputed")
eq(rules[2].selector, "eDP-1", "connector rules come last")
present["desc:BNQ BenQ LCD T4M012360190"] = { x = -1600, y = -180, w = 1600, h = 900, selector = "desc:BNQ BenQ LCD T4M012360190", scale = 1.6, transform = 0, description = "BNQ BenQ LCD T4M012360190" }
eq(#model.plan(present, known, layouts), 2, "an absent desc rule that would match a present display is left out")
print("model ok")
LUA
) || fail "display model" "$model_output"
pass "display model: identity, scale, placement, reflow, remember, plan"

store_output=$(run_lua "$tmpdir/store" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
local store = require("default.hypr.displays.store")

local state = {
  version = 1,
  displays = {
    ['desc:Odd "Name" \\ 1'] = { selector = 'desc:Odd "Name" \\ 1', size = { 2560, 1440 }, scale = 1.6, transform = 0, description = "Ünïcode\tTab" },
  },
  layouts = { { positions = { ["eDP-1"] = { 1600, 180 }, ['desc:Odd "Name" \\ 1'] = { -1600, -180 } } } },
}

local decoded = store.decode(store.encode(state))
assert(decoded, "encoded state decodes")
local display = decoded.displays['desc:Odd "Name" \\ 1']
assert(display and display.scale == 1.6 and display.size[2] == 1440, "display record round-trips")
assert(display.description == "Ünïcode\tTab", "strings round-trip")
assert(decoded.layouts[1].positions["eDP-1"][2] == 180, "positions round-trip")
assert(store.decode("{ broken") == nil, "malformed JSON is rejected")
assert(store.decode('{"a": 1} trailing') == nil, "trailing garbage is rejected")

local clean = store.sanitize({
  version = 1,
  displays = { ok = { selector = "eDP-1", size = { 1, 1 }, scale = 2.0000001 }, bad = { selector = 3 } },
  layouts = { { positions = { a = { 0, 0 } } }, { positions = { a = "x" } }, {} },
})
assert(clean.displays.ok and not clean.displays.bad, "invalid display records are dropped")
assert(clean.displays.ok.scale == 2, "stored scales snap to k/120")
assert(#clean.layouts == 1, "invalid layouts are dropped")
assert(#store.sanitize({ version = 99 }).layouts == 0, "unknown versions start fresh")

local path = os.getenv("HOME") .. "/displays.json"
assert(#store.load(path).layouts == 0, "a missing file is an empty state")
assert(store.save(state, path) == true, "first save writes")
assert(store.save(state, path) == false, "an unchanged save is skipped")
local loaded = store.load(path)
assert(loaded.layouts[1].positions["eDP-1"][1] == 1600, "saved state loads back")
assert(io.open(path .. ".tmp", "r") == nil, "no temp file is left behind")
print("store ok")
LUA
) || fail "display store" "$store_output"
pass "display store: JSON round-trip, sanitizing, write only on change"

flow_output=$(run_lua "$tmpdir/flow" 2>&1 <<'LUA'
package.path = os.getenv("OMARCHY_PATH") .. "/?.lua;" .. package.path
require("default.hypr.helpers")

-- A small Hyprland: rules upsert and merge per selector, the newest match
-- wins, a connecting output takes its rule without an overlap check, added
-- fires before the output is positioned, and pending rules apply in one pass
-- per frame with one overlap check.
local H

local function reset_hyprland()
  H = { outputs = {}, order = {}, rules = {}, handlers = {}, timers = {}, notes = {}, pending = false, toasts = 0, moved = {}, focused = nil }
end
reset_hyprland()

local function logical(o)
  local w, h = o.width, o.height
  if (o.transform or 0) % 2 == 1 then
    w, h = h, w
  end
  return math.floor(w / o.scale + 0.5), math.floor(h / o.scale + 0.5)
end

local function matches(selector, o)
  if selector == o.name then
    return true
  end
  return selector:sub(1, 5) == "desc:" and o.description ~= "" and o.description:sub(1, #selector - 5) == selector:sub(6)
end

local function rule_for(o)
  for i = #H.rules, 1, -1 do
    if matches(H.rules[i].output, o) then
      return H.rules[i]
    end
  end
end

local function view(o)
  return { name = o.name, description = o.description, serial = o.serial, width = o.width, height = o.height, x = o.x, y = o.y, scale = o.scale, transform = o.transform or 0 }
end

local function fire(event, ...)
  for _, fn in ipairs(H.handlers[event] or {}) do
    fn(...)
  end
end

local function apply_rule(o)
  local rule = rule_for(o)
  local was_on, old_x, old_y = o.enabled, o.x, o.y
  o.enabled = not (rule and rule.disabled)
  if not o.enabled then
    return was_on and "off" or nil
  end
  o.scale = rule and type(rule.scale) == "number" and rule.scale or o.auto_scale
  o.transform = rule and rule.transform or 0
  local x, y
  if rule and rule.position then
    x, y = rule.position:match("^(-?%d+)x(-?%d+)$")
  end
  if x then
    o.x, o.y = tonumber(x), tonumber(y)
  else
    o.x = nil
    local right = 0
    for _, name in ipairs(H.order) do
      local other = H.outputs[name]
      if other ~= o and other.enabled and other.x then
        right = math.max(right, other.x + logical(other))
      end
    end
    o.x, o.y = right, 0
  end
  if was_on and old_x and (old_x ~= o.x or old_y ~= o.y) then
    H.moved[o.name] = (H.moved[o.name] or 0) + 1
  end
  return not was_on and "on" or nil
end

local function check_overlaps()
  local on = {}
  for _, name in ipairs(H.order) do
    if H.outputs[name].enabled then
      on[#on + 1] = H.outputs[name]
    end
  end
  for i = 1, #on do
    for j = i + 1, #on do
      local a, b = on[i], on[j]
      local aw, ah = logical(a)
      local bw, bh = logical(b)
      if a.x < b.x + bw and b.x < a.x + aw and a.y < b.y + bh and b.y < a.y + ah then
        H.toasts = H.toasts + 1
        return
      end
    end
  end
end

local function frame()
  while H.pending do
    H.pending = false
    local changes = {}
    for _, name in ipairs(H.order) do
      changes[name] = apply_rule(H.outputs[name])
    end
    for _, name in ipairs(H.order) do
      if changes[name] == "off" then
        fire("monitor.removed", view(H.outputs[name]))
      elseif changes[name] == "on" then
        fire("monitor.added", view(H.outputs[name]))
      end
    end
    check_overlaps()
    fire("monitor.layout_changed")
  end
end

hl = {
  monitor = function(rule)
    local merged = {}
    for i, old in ipairs(H.rules) do
      if old.output == rule.output then
        merged = old
        table.remove(H.rules, i)
        break
      end
    end
    for key, value in pairs(rule) do
      merged[key] = value
    end
    H.rules[#H.rules + 1] = merged
    H.pending = true
  end,
  get_monitors = function()
    local list = {}
    for _, name in ipairs(H.order) do
      if H.outputs[name].enabled then
        list[#list + 1] = view(H.outputs[name])
      end
    end
    return list
  end,
  get_active_monitor = function()
    return H.outputs[H.focused] and view(H.outputs[H.focused])
  end,
  on = function(event, fn)
    H.handlers[event] = H.handlers[event] or {}
    table.insert(H.handlers[event], fn)
  end,
  timer = function(fn)
    H.timers[#H.timers + 1] = fn
  end,
  exec_cmd = function(command)
    H.notes[#H.notes + 1] = command
  end,
}

-- A reload clears rules, handlers and timers, then runs the config again.
local function load_config(after)
  H.rules, H.handlers, H.timers = {}, {}, {}
  for _, module in ipairs({ "default.hypr.displays", "default.hypr.displays.model", "default.hypr.displays.store" }) do
    package.loaded[module] = nil
  end
  require("default.hypr.displays")
  if after then
    after()
  end
  H.pending = true
  frame()
end

local function connect(name, description, serial, width, height, auto_scale)
  local o = { name = name, description = description, serial = serial, width = width, height = height, auto_scale = auto_scale or 1 }
  H.outputs[name] = o
  H.order[#H.order + 1] = name
  apply_rule(o)
  if o.enabled then
    local payload = view(o)
    payload.x, payload.y = -1, -1
    fire("monitor.added", payload)
    fire("monitor.layout_changed")
  end
  frame()
end

local function disconnect(name)
  local o = H.outputs[name]
  H.outputs[name] = nil
  for i, other in ipairs(H.order) do
    if other == name then
      table.remove(H.order, i)
      break
    end
  end
  if o.enabled then
    fire("monitor.removed", view(o))
  end
  check_overlaps()
  frame()
end

-- Pending rules apply at the next frame, long before any timer fires.
local function settle()
  frame()
  while #H.timers > 0 do
    local timers = H.timers
    H.timers = {}
    for _, fn in ipairs(timers) do
      fn()
    end
    frame()
  end
end

local function pos(name)
  local o = H.outputs[name]
  return o.x .. "," .. o.y
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
  end
end

local function moves(name)
  return H.moved[name] or 0
end

local benq = "BNQ BenQ LCD T4M01236019"
local toggles = os.getenv("HOME") .. "/.local/state/omarchy/toggles/hypr/"

-- First start with an empty store, laptop alone.
load_config()
connect("eDP-1", "", "", 3456, 2160, 2)
settle()
eq(pos("eDP-1"), "0,0", "laptop alone starts at the origin")

-- A display seen for the first time: right of main, bottom-aligned. The
-- laptop doesn't move; the new display moves once, from Hyprland's auto spot.
H.focused = "eDP-1"
connect("USB-1", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(pos("USB-1"), "1728,-360", "new display right of main, bottoms flush")
eq(moves("eDP-1"), 0, "laptop stays put when a new display connects")
eq(H.toasts, 0, "no overlap toast for a new display")

-- Put it left of the laptop, the way the desk is.
assert(omarchy_displays.place(2, "left"), "place succeeds")
settle()
eq(pos("USB-1"), "-2560,-360", "placed left, bottoms flush")
eq(moves("eDP-1"), 0, "placing one display leaves the others")

-- Unplug, then replug into another port: zero moves, no second pass.
disconnect("USB-1")
settle()
eq(pos("eDP-1"), "0,0", "laptop keeps its place after unplug")
H.moved = {}
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
eq(pos("USB-2"), "-2560,-360", "replug on another port lands at the remembered spot at once")
settle()
eq(moves("USB-2") + moves("eDP-1"), 0, "replug moves nothing")
eq(H.toasts, 0, "replug raises no overlap toast")

-- SUPER+/ on the laptop: main keeps its spot, the BenQ follows its new size.
omarchy_displays.step_scale(1)
settle()
eq(H.outputs["eDP-1"].scale, 3, "laptop steps up to 3")
eq(pos("eDP-1"), "0,0", "scaled main keeps its position")
eq(pos("USB-2"), "-2560,-720", "neighbour stays left with bottoms flush")
eq(H.toasts, 0, "scale step raises no overlap toast")

-- The Monitor panel's scale buttons still run the old script: a connector
-- rule with position=auto. The change is adopted and the layout repaired.
settle()
hl.monitor({ output = "USB-2", mode = "2560x1440@60", position = "auto", scale = 1.6 })
frame()
settle()
eq(H.outputs["USB-2"].scale, 1.6, "outside scale change is kept")
eq(pos("USB-2"), "-1600,-180", "outside scale change is re-seated left of main")

-- Someone arranges with hyprctl: adopted as this set's layout.
hl.monitor({ output = "USB-2", position = "-1600x0" })
frame()
settle()
eq(pos("USB-2"), "-1600,0", "outside move is kept")
local file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/displays.json")
local saved = file:read("a")
file:close()
assert(saved:find('"desc:' .. benq .. '": %[%-1600, 0%]'), "outside move is remembered")

-- A reload changes nothing.
H.moved = {}
load_config()
settle()
eq(moves("USB-2") + moves("eDP-1"), 0, "reload moves nothing")

-- Next boot, docked: the rules from the store put both displays in place in
-- their first modeset.
reset_hyprland()
load_config()
connect("eDP-1", "", "", 3456, 2160, 2)
connect("USB-2", benq, "T4M01236019", 2560, 1440, 1)
settle()
eq(pos("eDP-1"), "0,0", "boot: laptop at its remembered spot")
eq(pos("USB-2"), "-1600,0", "boot: BenQ at its remembered spot")
eq(H.outputs["USB-2"].scale, 1.6, "boot: BenQ at its remembered scale")
eq(moves("eDP-1") + moves("USB-2"), 0, "boot moves nothing")

-- Boot docked with the lid closed: the clamshell toggle disables the panel
-- after this module; no runtime rule may switch it back on.
local flag = io.open(toggles .. "internal-monitor-clamshell.lua", "w")
flag:write('hl.monitor({ output = "eDP-1", disabled = true })\n')
flag:close()
load_config(function()
  hl.monitor({ output = "eDP-1", disabled = true })
end)
settle()
eq(H.outputs["eDP-1"].enabled, false, "clamshell keeps the panel off")
os.remove(toggles .. "internal-monitor-clamshell.lua")

-- Lid opens: the clamshell toggle is gone and the config reloads. The panel
-- comes back beside the BenQ without the BenQ moving.
H.moved = {}
load_config()
settle()
eq(H.outputs["eDP-1"].enabled, true, "panel back on")
eq(pos("eDP-1"), "0,0", "panel returns to its remembered spot beside the BenQ")
eq(moves("USB-2"), 0, "the BenQ stays put when the panel returns")

-- Synthetic outputs are ignored.
connect("FALLBACK", "", "", 1920, 1080, 1)
assert(not omarchy_displays.status():find("FALLBACK"), "FALLBACK is ignored")
disconnect("FALLBACK")

-- Mirroring: nothing is registered while the mirror toggle exists.
flag = io.open(toggles .. "internal-monitor-mirror.lua", "w")
flag:write("-- mirror\n")
flag:close()
local before = #H.rules
omarchy_displays.step_scale(1)
eq(#H.rules, before, "no rules while mirroring")
os.remove(toggles .. "internal-monitor-mirror.lua")

print(omarchy_displays.status())
print("flow ok")
LUA
) || fail "display arrangement flow" "$flow_output"
pass "display arrangement: first sight, place, replug, scale, outside changes, reload, boot, clamshell"
