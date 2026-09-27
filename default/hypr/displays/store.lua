-- Remembered display state in ~/.local/state/omarchy/displays.json:
--   displays: identity -> { selector, size = { w, h } in pixels, scale, transform }
--   layouts:  most recently used first, each { positions = { identity = { x, y } } }
-- It is read and written with io.open and never require()'d: Hyprland watches
-- every required file and reloads the whole config when one changes.

local paths = require("default.hypr.paths")

local M = {}

M.path = paths.state_home .. "/omarchy/displays.json"

local named_escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(value, indent)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(char)
      return named_escapes[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
  elseif kind == "number" then
    if math.type(value) == "integer" or value == math.floor(value) then
      return string.format("%d", value)
    end
    return string.format("%.10g", value)
  elseif kind == "boolean" then
    return tostring(value)
  elseif kind ~= "table" then
    return "null"
  end

  local inner = indent .. "  "
  local items = {}
  if value[1] ~= nil then
    for _, item in ipairs(value) do
      items[#items + 1] = encode(item, inner)
    end
    if #items <= 4 and not items[1]:find("\n", 1, true) then
      return "[" .. table.concat(items, ", ") .. "]"
    end
    return "[\n" .. inner .. table.concat(items, ",\n" .. inner) .. "\n" .. indent .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  if #keys == 0 then
    return "{}"
  end
  for _, key in ipairs(keys) do
    items[#items + 1] = encode(key) .. ": " .. encode(value[key], inner)
  end
  return "{\n" .. inner .. table.concat(items, ",\n" .. inner) .. "\n" .. indent .. "}"
end

local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Enough JSON for this file: objects, arrays, strings, numbers, booleans.
-- Returns nil on anything malformed.
local function decode(text)
  local pos = 1

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end

  local value

  local function string_value()
    local parts = {}
    pos = pos + 1
    while true do
      local chunk_end = text:find('["\\]', pos)
      if not chunk_end then
        error("unterminated string")
      end
      parts[#parts + 1] = text:sub(pos, chunk_end - 1)
      if text:sub(chunk_end, chunk_end) == '"' then
        pos = chunk_end + 1
        return table.concat(parts)
      end
      local escape = text:sub(chunk_end + 1, chunk_end + 1)
      if escape == "u" then
        parts[#parts + 1] = utf8.char(tonumber(text:sub(chunk_end + 2, chunk_end + 5), 16))
        pos = chunk_end + 6
      else
        parts[#parts + 1] = escapes[escape] or escape
        pos = chunk_end + 2
      end
    end
  end

  function value()
    skip()
    local char = text:sub(pos, pos)
    if char == "{" then
      local object = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return object
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          error("expected key")
        end
        local key = string_value()
        skip()
        if text:sub(pos, pos) ~= ":" then
          error("expected colon")
        end
        pos = pos + 1
        object[key] = value()
        skip()
        char = text:sub(pos, pos)
        pos = pos + 1
        if char == "}" then
          return object
        elseif char ~= "," then
          error("expected comma")
        end
      end
    elseif char == "[" then
      local array = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return array
      end
      while true do
        array[#array + 1] = value()
        skip()
        char = text:sub(pos, pos)
        pos = pos + 1
        if char == "]" then
          return array
        elseif char ~= "," then
          error("expected comma")
        end
      end
    elseif char == '"' then
      return string_value()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end

    local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not number or not tonumber(number) then
      error("unexpected character")
    end
    pos = pos + #number
    return tonumber(number)
  end

  local ok, result = pcall(value)
  if not ok then
    return nil
  end
  skip()
  if pos <= #text then
    return nil
  end
  return result
end

M.encode = function(value)
  return encode(value, "") .. "\n"
end
M.decode = decode

local function is_point(p)
  return type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number"
end

-- Drop anything this version can't use instead of failing on it later.
local function sanitize(data)
  local state = { version = 1, displays = {}, layouts = {} }
  if type(data) ~= "table" or data.version ~= 1 then
    return state
  end

  for key, display in pairs(type(data.displays) == "table" and data.displays or {}) do
    if type(key) == "string" and type(display) == "table" and type(display.selector) == "string"
      and is_point(display.size) and type(display.scale) == "number" and display.scale > 0 then
      display.scale = math.floor(display.scale * 120 + 0.5) / 120
      display.transform = math.tointeger(display.transform) or 0
      state.displays[key] = display
    end
  end

  for _, layout in ipairs(type(data.layouts) == "table" and data.layouts or {}) do
    local positions = type(layout) == "table" and layout.positions
    local valid = type(positions) == "table" and next(positions) ~= nil
    for key, p in pairs(valid and positions or {}) do
      valid = valid and type(key) == "string" and is_point(p)
    end
    if valid then
      state.layouts[#state.layouts + 1] = layout
    end
  end

  return state
end

M.sanitize = sanitize

local last_written

function M.load(path)
  path = path or M.path
  local file = io.open(path, "r")
  if not file then
    return sanitize(nil)
  end
  local text = file:read("a")
  file:close()
  last_written = text
  return sanitize(decode(text))
end

-- Write only when the content changed, through a temp file and rename so a
-- crash can't leave half a file behind.
function M.save(state, path)
  path = path or M.path
  local text = M.encode(state)
  if text == last_written then
    return false
  end

  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then
    return false
  end
  file:write(text)
  file:close()
  if not os.rename(tmp, path) then
    os.remove(tmp)
    return false
  end
  last_written = text
  return true
end

return M
