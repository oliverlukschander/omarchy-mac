-- Macs swipe between workspaces with three fingers, as they do in macOS.
-- Omarchy loads its platform directory (default/hypr/platform) after the
-- user's files, so a three-finger sideways gesture the user set, or
-- omarchy_workspace_gesture = false, keeps this one out instead of Hyprland
-- rejecting it as a duplicate. Lines added to hyprland.lua after the toggles
-- come too late for that, which is why the manual points at input.lua.

if _G.omarchy_workspace_gesture == false or not (o and o.apple_silicon and o.apple_silicon()) then
  return
end

local sideways = {
  horizontal = true,
  horiz = true,
  left = true,
  l = true,
  right = true,
  r = true,
  swipe = true,
}

for _, gesture in ipairs(o.registered_gestures or {}) do
  if gesture.fingers == 3 and not gesture.modified and sideways[gesture.direction] then
    return
  end
end

-- Step by number, so the swipe reaches empty workspaces as Spaces do in macOS.
-- Hyprland's default steps only through workspaces that exist and never out of
-- an empty one into a new one. A user's own gesture keeps Hyprland's stepping.
-- Per-display workspaces keep the swipe on the display's own workspaces
-- instead: stepping by number would run into the next display's.
if not (omarchy_displays and omarchy_displays.own_workspaces) then
  hl.config({ gestures = { workspace_swipe_use_r = true } })
end
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
