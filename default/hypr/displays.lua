-- Display arrangement. Remembers where each display goes for every set of
-- connected displays, and keeps a complete monitor rule registered for every
-- known display, including the ones that are off. A display that connects
-- lands on its remembered spot in Hyprland's first pass, so nothing that is
-- already on has to move. Positions change only when the user moves a
-- display, or when a scale step resizes one and its neighbours follow.
--
-- Everything goes through the omarchy_displays global, also from outside Lua:
--   hyprctl eval "omarchy_displays.place(2, 'left')"
--   hyprctl repl "return omarchy_displays.status()"

local paths = require("default.hypr.paths")
local model = require("default.hypr.displays.model")
local store = require("default.hypr.displays.store")

local M = {}

local LAYOUT_LIMIT = 16
local SETTLE_MS = 1500

local toggles_dir = paths.state_home .. "/omarchy/toggles/hypr/"
local state = store.load()
local targets = {} -- connector -> where we put that display, while it's on
local registered -- signature of the rule set last registered
local settling = false -- our rules are registered but maybe not applied yet
local generation = 0

local function toggle_on(name)
  local file = io.open(toggles_dir .. name .. ".lua", "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- Clamshell and the laptop-display toggle turn the internal panel off with a
-- rule loaded after this module, which a runtime rule would override.
local function internal_forced_off()
  return toggle_on("internal-monitor-clamshell") or toggle_on("internal-monitor-disable")
end

-- Mirroring replaces the arrangement altogether.
local function mirroring()
  return toggle_on("internal-monitor-mirror")
end

-- HL.Monitor objects must not outlive the event that produced them, so only
-- plain copies are kept.
local function plain(monitor)
  local name = monitor.name
  if not name or model.is_virtual(name) or monitor.is_mirror or (monitor.width or 0) <= 0 or (monitor.scale or 0) <= 0 then
    return nil
  end
  return {
    name = name,
    description = monitor.description or "",
    serial = monitor.serial or "",
    width = math.floor(monitor.width),
    height = math.floor(monitor.height),
    x = math.floor(monitor.x + 0.5),
    y = math.floor(monitor.y + 0.5),
    scale = model.snap_scale(monitor.scale),
    transform = math.floor(monitor.transform or 0),
  }
end

-- The displays that are on, keyed by identity. gone is a connector that
-- monitor.removed reported and extra one that monitor.added did; Hyprland's
-- own list may not reflect either yet while the event is delivered.
local function read_live(gone, extra)
  local monitors = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    local m = plain(monitor)
    if m and m.name ~= gone and not (extra and m.name == extra.name) then
      monitors[#monitors + 1] = m
    end
  end
  if extra then
    monitors[#monitors + 1] = extra
  end

  local live = {}
  for _, m in ipairs(model.identify(monitors)) do
    m.w, m.h = model.logical_size(m.width, m.height, m.scale, m.transform)
    live[m.key] = m
  end
  return live
end

local function at(rect, x, y)
  local copy = {}
  for field, value in pairs(rect) do
    copy[field] = value
  end
  copy.x, copy.y = math.floor(x + 0.5), math.floor(y + 0.5)
  return copy
end

local function current()
  local present = {}
  for _, rect in pairs(targets) do
    present[rect.key] = rect
  end
  return present
end

local function notify(message)
  hl.exec_cmd(o.notify(message))
end

local function register(present)
  local skip_internal = internal_forced_off()
  local rules, parts = {}, {}
  for _, rule in ipairs(model.plan(present, state.displays, state.layouts)) do
    if not (skip_internal and model.is_internal(rule.selector)) then
      rules[#rules + 1] = rule
      parts[#parts + 1] = string.format("%s %d %d %s %d", rule.selector, rule.x, rule.y, rule.scale, rule.transform)
    end
  end

  local signature = table.concat(parts, "\n")
  if signature == registered then
    return false
  end
  registered = signature

  -- One synchronous batch: Hyprland applies it in a single pass with one
  -- overlap check. Every field is given, because a rule inherits whatever it
  -- omits from the previous rule for the same output.
  for _, rule in ipairs(rules) do
    hl.monitor({
      output = rule.selector,
      mode = "preferred",
      position = string.format("%dx%d", rule.x, rule.y),
      scale = rule.scale,
      transform = rule.transform,
      disabled = false,
      mirror = "",
    })
  end
  return true
end

local check

local function settle()
  settling = true
  generation = generation + 1
  local mine = generation
  hl.timer(function()
    if mine == generation then
      settling = false
      check()
    end
  end, { timeout = SETTLE_MS, type = "oneshot" })
end

-- Make present the arrangement: remember it for this set of displays and
-- register the rules for it and for every display that's off.
local function commit(present)
  targets = {}
  for key, rect in pairs(present) do
    targets[rect.name] = rect
    local display = state.displays[key] or {}
    display.selector = rect.selector
    display.description = rect.description
    display.size = { rect.width, rect.height }
    display.scale = rect.scale
    display.transform = rect.transform
    state.displays[key] = display
  end

  if next(present) then
    state.layouts = model.remember(state.layouts, present, LAYOUT_LIMIT)
    store.save(state)
  end

  if register(present) then
    settle()
  end
end

-- Seat the displays that are on. The ones already placed stay where they
-- are. One that just connected goes where its remembered layout, or the
-- default, puts it: the spot its registered rule already gave it.
local function sync(gone, extra)
  if mirroring() then
    return
  end

  local live = read_live(gone, extra)
  local present, fresh = {}, {}
  for key, m in pairs(live) do
    local target = targets[m.name]
    if target then
      present[key] = at(m, target.x, target.y)
    else
      fresh[#fresh + 1] = key
    end
  end

  table.sort(fresh)
  for _, key in ipairs(fresh) do
    local m = live[key]
    present[key] = at(m, model.place_joining(present, key, m.w, m.h, state.layouts))
  end

  commit(present)
end

-- Runs on every layout change. Once our own rules have landed, a difference
-- between what's on screen and what we placed was made by someone else and
-- is adopted: a new size (the Monitor panel's scale buttons) keeps our
-- positions and lets the neighbours follow; a move (hyprctl, a settings
-- tool) becomes the layout for this set.
function check()
  if mirroring() then
    return
  end

  local live = read_live()
  local unseen = 0
  for _ in pairs(targets) do
    unseen = unseen + 1
  end
  for _, m in pairs(live) do
    if not targets[m.name] then
      return sync()
    end
    unseen = unseen - 1
  end
  if unseen ~= 0 then
    return sync()
  end

  local resized, moved = {}, false
  for key, m in pairs(live) do
    local target = targets[m.name]
    if m.w ~= target.w or m.h ~= target.h or m.scale ~= target.scale or m.transform ~= target.transform then
      resized[key] = { w = m.w, h = m.h }
    elseif m.x ~= target.x or m.y ~= target.y then
      moved = true
    end
  end

  if settling then
    settling = next(resized) ~= nil or moved
    return
  end

  if next(resized) then
    local old = {}
    for key, m in pairs(live) do
      local target = targets[m.name]
      old[key] = { x = target.x, y = target.y, w = target.w, h = target.h }
    end
    local new = model.reflow(old, resized)
    local present = {}
    for key, m in pairs(live) do
      present[key] = at(m, new[key].x, new[key].y)
    end
    commit(present)
  elseif moved then
    commit(live)
  end
end

-- SUPER+/ and SUPER+ALT+/: the next clean scale up or down for the focused
-- display. It keeps its place and the neighbours follow its new size.
function M.step_scale(direction)
  if mirroring() then
    return
  end

  local active = hl.get_active_monitor()
  local name = active and active.name
  local live = read_live()
  local key
  for k, m in pairs(live) do
    if m.name == name then
      key = k
    end
  end
  if not key then
    return
  end

  local m = live[key]
  local scale = model.step_scale(m.scale, direction, m.width, m.height)
  if scale == m.scale then
    return
  end

  local old = {}
  for k, other in pairs(live) do
    local target = targets[other.name] or other
    old[k] = { x = target.x, y = target.y, w = other.w, h = other.h }
  end
  local w, h = model.logical_size(m.width, m.height, scale, m.transform)
  local new = model.reflow(old, { [key] = { w = w, h = h } })

  local present = {}
  for k, other in pairs(live) do
    present[k] = at(other, new[k].x, new[k].y)
  end
  present[key].scale, present[key].w, present[key].h = scale, w, h
  commit(present)
end

-- Put display D<number> left of, right of, above or below D<reference>
-- (main when omitted). Beside it the bottoms are flush; above or below it's
-- centred. Nothing else moves.
function M.place(number, side, reference)
  local present = current()
  local order = model.numbering(present)
  local key = order[number]
  local anchor = reference and order[reference] or model.main(present)
  local sides = { left = true, right = true, above = true, below = true }
  if not key or not anchor or key == anchor or not sides[side] then
    return false
  end

  local rect = present[key]
  local align = (side == "left" or side == "right") and "end" or "center"
  local x, y = model.attach(present[anchor], side, align, nil, rect.w, rect.h)
  local ok, blocker = model.fits(present, { x = x, y = y, w = rect.w, h = rect.h }, key)
  if not ok then
    for index, other in ipairs(order) do
      if other == blocker then
        notify(string.format("D%d can't go there: it would overlap D%d", number, index))
      end
    end
    return false
  end

  present[key] = at(rect, x, y)
  commit(present)
  return true
end

function M.status()
  local present = current()
  local main = model.main(present)
  local lines = {}
  for index, key in ipairs(model.numbering(present)) do
    local r = present[key]
    lines[#lines + 1] = string.format("D%d %s (%s) %dx%d at %d,%d scale %g%s", index, key, r.name, r.w, r.h, r.x, r.y, r.scale, key == main and " main" or "")
  end
  return table.concat(lines, "\n")
end

omarchy_displays = M

local live = read_live()
if next(live) then
  -- A reload: everything stays exactly where it is.
  commit(live)
else
  -- First start, before any output exists: assume the most recently used
  -- layout, so each display's first modeset already puts it in place.
  local assumed = {}
  local recent = state.layouts[1]
  for key, p in pairs(recent and recent.positions or {}) do
    local display = state.displays[key]
    if display and model.safe_when_absent(display.selector) then
      local w, h = model.logical_size(display.size[1], display.size[2], display.scale, display.transform)
      assumed[key] = {
        x = p[1],
        y = p[2],
        w = w,
        h = h,
        selector = display.selector,
        description = display.description,
        scale = display.scale,
        transform = display.transform,
      }
    end
  end
  register(assumed)
end

hl.on("monitor.added", function(monitor)
  local m = plain(monitor)
  if m then
    sync(nil, m)
  end
end)

hl.on("monitor.removed", function(monitor)
  local name = monitor.name
  if name and not model.is_virtual(name) then
    sync(name)
  end
end)

hl.on("monitor.layout_changed", check)

return M
