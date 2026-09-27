-- Display arrangement. Remembers where each display goes for every set of
-- connected displays, and keeps a complete monitor rule registered for every
-- known display, including the ones that are off. A display that connects
-- lands on its remembered spot in Hyprland's first pass, so nothing that is
-- already on has to move. Positions change when the user moves a display,
-- when a scale step resizes one and its neighbours follow, or when a display
-- leaves and the others would no longer touch.
--
-- Each display also owns ten workspaces, which SUPER+1..0 reach on the
-- display that has focus.
--
-- Outside code reaches this through the omarchy_displays global, which is
-- only set while monitor rules go through here:
--   hyprctl eval "omarchy_displays.place(2, 'left')"
--   hyprctl repl "return omarchy_displays.status()"

local paths = require("default.hypr.paths")
local model = require("default.hypr.displays.model")
local store = require("default.hypr.displays.store")

local M = {}

local LAYOUT_LIMIT = 16
local SETTLE_MS = 1500

local function toggle_on(name)
  local file = io.open(paths.state_home .. "/omarchy/toggles/hypr/" .. name .. ".lua", "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- Every writer of these toggles reloads the config, so they're read once.
-- Clamshell and the laptop-display toggle turn the internal panel off with a
-- rule loaded after this module, which a runtime rule would override.
-- Mirroring replaces the arrangement altogether.
local internal_off = toggle_on("internal-monitor-clamshell") or toggle_on("internal-monitor-disable")
local mirrored = toggle_on("internal-monitor-mirror")

local state = store.load()
local targets = {} -- connector -> where we put that display, while it's on
local registered = {} -- selector -> the rule last registered for it
local settling = false -- our rules are registered but maybe not applied yet
local generation = 0
local pinned = {} -- identities whose workspace rules are registered
local choosing = 0

-- HL.Monitor objects must not outlive the event that produced them, so only
-- plain copies are kept.
local function read_live()
  local monitors = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if not model.is_virtual(monitor.name) and not monitor.is_mirror and monitor.width > 0 and monitor.scale > 0 then
      monitors[#monitors + 1] = {
        name = monitor.name,
        description = monitor.description or "",
        serial = monitor.serial or "",
        width = monitor.width,
        height = monitor.height,
        x = monitor.x,
        y = monitor.y,
        scale = model.snap_scale(monitor.scale),
        transform = monitor.transform or 0,
      }
    end
  end

  local live = {}
  for _, m in ipairs(model.identify(monitors)) do
    m.w, m.h = model.logical_size(m.width, m.height, m.scale, m.transform)
    live[m.key] = m
  end
  return live
end

local function current()
  local present = {}
  for _, rect in pairs(targets) do
    present[rect.key] = rect
  end
  return present
end

local NEUTRAL = { position = "auto", scale = "auto", transform = 0 }

local function same(a, b)
  return b and a.position == b.position and a.scale == b.scale and a.transform == b.transform
end

-- Register what changed as one synchronous batch, which Hyprland applies in a
-- single pass with one overlap check. Every field is given, because a rule
-- inherits whatever it omits from the previous rule for the same output.
local function register(present)
  local wanted, order = {}, {}
  for _, rule in ipairs(model.plan(present, state.displays, state.layouts)) do
    if not (internal_off and model.is_internal(rule.selector)) then
      wanted[rule.selector] = { position = string.format("%dx%d", rule.x, rule.y), scale = rule.scale, transform = rule.transform }
      order[#order + 1] = rule.selector
    end
  end

  -- A connector rule outlives its display until the next reload; reset it so
  -- it can't catch the next monitor on that port.
  local batch = {}
  for selector in pairs(registered) do
    if not wanted[selector] and not model.safe_when_absent(selector) then
      batch[#batch + 1] = selector
      wanted[selector] = NEUTRAL
    end
  end
  table.sort(batch)

  -- plan() orders desc: rules first. Whenever anything is sent, the external
  -- connector rules go again last, so they stay newer than any desc: rule
  -- that also matches a display sharing its description.
  for _, selector in ipairs(order) do
    if not same(wanted[selector], registered[selector]) then
      batch[#batch + 1] = selector
    end
  end
  if #batch > 0 then
    for _, selector in ipairs(order) do
      if not model.safe_when_absent(selector) and same(wanted[selector], registered[selector]) then
        batch[#batch + 1] = selector
      end
    end
  end

  for _, selector in ipairs(batch) do
    local rule = wanted[selector]
    hl.monitor({
      output = selector,
      mode = "preferred",
      position = rule.position,
      scale = rule.scale,
      transform = rule.transform,
      disabled = false,
      mirror = "",
    })
    registered[selector] = rule ~= NEUTRAL and rule or nil
  end
  return #batch > 0
end

-- Each display owns ten workspace ids: the internal panel 1-10, the next
-- display seen 11-20, and so on. On a machine without an internal panel the
-- first display gets 1-10. has_panel says whether this one has one.
local function free_block(key, has_panel)
  local taken = {}
  for _, display in pairs(state.displays) do
    taken[display.block or -1] = true
  end
  local block = (model.is_internal(key) or not has_panel) and 0 or 1
  while taken[block] do
    block = block + 1
  end
  return block
end

-- Bind a display's workspaces to it, so Hyprland creates them there and
-- brings them home when the display reconnects on any port. They aren't
-- persistent: empty ones go away, as they always have. Workspace rules can't
-- be removed at runtime, so a display selected by connector isn't pinned, and
-- neither is a model seen as twins: those rules would catch another monitor.
local function pin(key)
  local display = state.displays[key]
  if pinned[key] or not display.block or not model.safe_when_absent(display.selector) then
    return
  end
  for other in pairs(state.displays) do
    if other:sub(1, #key + 1) == key .. "@" then
      return
    end
  end
  pinned[key] = true
  for slot = 1, 10 do
    hl.workspace_rule({ workspace = tostring(display.block * 10 + slot), monitor = display.selector, default = slot == 1 })
  end
end

-- The workspaces of a display that's gone wait on main until it's back;
-- Hyprland itself puts them on whichever display it lists first.
local function park(present)
  local main = model.main(present)
  if not main then
    return
  end
  local home = {}
  for key in pairs(present) do
    home[state.displays[key].block] = true
  end
  for _, workspace in ipairs(hl.get_workspaces() or {}) do
    local id = workspace.id
    if id > 0 and not workspace.special and not home[(id - 1) // 10] and workspace.monitor and workspace.monitor.name ~= present[main].name then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = present[main].name }))
    end
  end
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

-- Make present the arrangement: mend it into one piece, remember it for this
-- set if the user made it, and register the rules for it and for every
-- display that's off. Placements this module works out are not remembered;
-- they come out the same the next time.
local function commit(present, made_by_user)
  present = model.connect(present, state.layouts)
  targets = {}

  -- Block 0 stays the panel's, even while clamshell keeps it off.
  local has_panel = internal_off
  for key in pairs(state.displays) do
    has_panel = has_panel or model.is_internal(key)
  end
  for key in pairs(present) do
    has_panel = has_panel or model.is_internal(key)
  end

  for key, rect in pairs(present) do
    targets[rect.name] = rect
    local display = state.displays[key] or {}
    display.selector, display.size, display.scale, display.transform = rect.selector, { rect.width, rect.height }, rect.scale, rect.transform
    display.block = display.block or free_block(key, has_panel)
    state.displays[key] = display
    pin(key)
  end

  if made_by_user and next(present) then
    state.layouts = model.remember(state.layouts, present, LAYOUT_LIMIT)
  end
  store.save(state)

  if register(present) then
    settle()
  end
  park(present)
end

-- The displays that are on after some change size: from where we put them,
-- main stays and the others follow.
local function reflowed(live, sizes)
  local old = {}
  for key, m in pairs(live) do
    old[key] = targets[m.name] or m
  end
  local new = model.reflow(old, sizes, state.layouts)
  local present = {}
  for key, m in pairs(live) do
    present[key] = model.moved(m, new[key].x, new[key].y)
  end
  return present
end

-- A display seen before comes back at its remembered scale and rotation.
local function remembered(m)
  local display = state.displays[m.key]
  if not display or (display.scale == m.scale and display.transform == m.transform) then
    return m
  end
  local rect = model.moved(m, m.x, m.y)
  rect.scale, rect.transform = display.scale, display.transform
  rect.w, rect.h = model.logical_size(m.width, m.height, rect.scale, rect.transform)
  return rect
end

-- Seat the displays that are on after one connects or leaves, or after a
-- reload. The ones already placed stay where they are; with none placed yet,
-- main stays where it is. One that just connected goes where its remembered
-- layout, or the default, puts it: the spot its registered rule already gave
-- it. A set the user arranged comes back as arranged, around that anchor.
local function sync(live)
  local present, fresh = {}, {}
  for key, m in pairs(live) do
    local target = targets[m.name]
    if target then
      present[key] = model.moved(m, target.x, target.y)
    else
      fresh[#fresh + 1] = key
    end
  end

  local anchor = model.main(present)
  if not anchor then
    anchor = model.main(live)
    present[anchor] = remembered(live[anchor])
  end

  table.sort(fresh)
  for _, key in ipairs(fresh) do
    if not present[key] then
      local m = remembered(live[key])
      present[key] = model.moved(m, model.place_joining(present, key, m.w, m.h, state.layouts))
    end
  end

  commit(model.restore(present, anchor, state.layouts) or present, false)
end

-- Runs on every layout change, which Hyprland also sends after a display
-- connects or leaves. Once our own rules have landed, a difference between
-- the screen and what we placed was made by someone else and is adopted: a
-- new size keeps our positions and lets the neighbours follow; a move becomes
-- the layout for this set.
function check()
  local live = read_live()
  local unseen = 0
  for _ in pairs(targets) do
    unseen = unseen + 1
  end
  for _, m in pairs(live) do
    if not targets[m.name] then
      return sync(live)
    end
    unseen = unseen - 1
  end
  if unseen ~= 0 then
    return sync(live)
  end

  local sizes, resized, moved = {}, false, false
  for key, m in pairs(live) do
    local target = targets[m.name]
    sizes[key] = { w = m.w, h = m.h }
    if m.w ~= target.w or m.h ~= target.h or m.scale ~= target.scale or m.transform ~= target.transform then
      resized = true
    elseif m.x ~= target.x or m.y ~= target.y then
      moved = true
    end
  end

  if settling then
    settling = resized or moved
    return
  end

  -- Whoever changed it may have replaced our rule for that output too.
  if resized then
    registered = {}
    commit(reflowed(live, sizes), true)
  elseif moved then
    registered = {}
    commit(live, true)
  end
end

-- Give the display on connector `name` a new scale, snapped to a clean one.
-- It keeps its place and the neighbours follow its new size. Used by SUPER+/
-- and by omarchy-hyprland-monitor-scaling for the Monitor panel.
function M.set_scale(name, scale)
  if mirrored or type(scale) ~= "number" or scale < 0.25 then
    return
  end

  local live = read_live()
  for key, m in pairs(live) do
    if m.name == name then
      scale = model.clean_scale(scale, m.width, m.height)
      local sizes = {}
      for k, other in pairs(live) do
        sizes[k] = { w = other.w, h = other.h }
      end
      local w, h = model.logical_size(m.width, m.height, scale, m.transform)
      sizes[key] = { w = w, h = h }

      local present = reflowed(live, sizes)
      present[key].scale, present[key].w, present[key].h = scale, w, h
      commit(present, true)
      return
    end
  end
end

-- SUPER+/ and SUPER+ALT+/: the next clean scale up or down for the focused
-- display.
function M.step_scale(direction)
  local active = hl.get_active_monitor()
  local name = active and active.name
  for _, m in pairs(read_live()) do
    if m.name == name then
      M.set_scale(name, model.step_scale(m.scale, direction, m.width, m.height))
      return
    end
  end
end

-- Put display D<number> left of, right of, above or below D<reference>
-- (main when omitted). Beside it the bottoms are flush; above or below it's
-- centred. Displays it leaves detached are seated again.
function M.place(number, side, reference)
  local present = current()
  local order = model.numbering(present)
  local key = order[number]
  local anchor = reference and order[reference] or model.main(present)
  local sides = { left = true, right = true, above = true, below = true }
  if mirrored or not key or not anchor or key == anchor or not sides[side] then
    return false
  end

  local rect = present[key]
  local align = (side == "left" or side == "right") and "end" or "center"
  local x, y = model.attach(present[anchor], side, align, nil, rect.w, rect.h)
  local ok, blocker = model.fits(present, { x = x, y = y, w = rect.w, h = rect.h }, key)
  if not ok then
    for index, other in ipairs(order) do
      if other == blocker then
        hl.exec_cmd(o.notify(string.format("D%d can't go there: it would overlap D%d", number, index)))
      end
    end
    return false
  end

  present[key] = model.moved(rect, x, y)
  commit(present, true)
  return true
end

-- The workspace id of slot n on the display that has focus (SUPER+1..0).
function M.slot(n)
  local active = hl.get_active_monitor()
  local rect = active and targets[active.name]
  local display = rect and state.displays[rect.key]
  return tostring((display and display.block or 0) * 10 + n)
end

-- SUPER+D: the next digit picks the display to send the focused window to.
-- The "display" submap is left after any other key, or after 1.5 s.
function M.choose_display()
  hl.dispatch(hl.dsp.submap("display"))
  choosing = choosing + 1
  local mine = choosing
  hl.timer(function()
    if mine == choosing and hl.get_current_submap() == "display" then
      hl.dispatch(hl.dsp.submap("reset"))
    end
  end, { timeout = 1500, type = "oneshot" })
end

-- Send the focused window to D<number>, onto the workspace it shows; focus
-- goes along.
function M.send_window(number)
  local present = current()
  local key = model.numbering(present)[number]
  hl.dispatch(hl.dsp.submap("reset"))
  if key then
    hl.dispatch(hl.dsp.window.move({ monitor = present[key].name }))
  end
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

if not mirrored then
  omarchy_displays = M

  for key in pairs(state.displays) do
    pin(key)
  end

  local live = read_live()
  if next(live) and model.restore(live, model.main(live), state.layouts) then
    -- A reload: bring back the remembered arrangement and scales.
    sync(live)
  elseif next(live) then
    -- The first start of this module on a running desktop: adopt what's
    -- there as this set's arrangement.
    commit(live, true)
  else
    -- First start, before any output exists: assume the most recently used
    -- layout, so each display's first modeset already puts it in place.
    local assumed = {}
    local recent = state.layouts[1]
    for key, p in pairs(recent and recent.positions or {}) do
      local display = state.displays[key]
      if display and model.safe_when_absent(display.selector) then
        local w, h = model.logical_size(display.size[1], display.size[2], display.scale, display.transform)
        assumed[key] = { x = p[1], y = p[2], w = w, h = h, selector = display.selector, scale = display.scale, transform = display.transform }
      end
    end
    register(assumed)
  end

  hl.on("monitor.layout_changed", check)
end

return M
