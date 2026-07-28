#!/usr/bin/env luajit
-- Generate character_map_embedded.h from character_map.txt

local function read_lines(path)
  local fh, err = io.open(path, 'r')
  if not fh then return nil, err end
  local lines = {}
  for line in fh:lines() do
    line = line:gsub('\r$', '')
    lines[#lines+1] = line
  end
  fh:close()
  return lines
end

local function script_root()
  local src = debug.getinfo(1, 'S').source
  if src:sub(1,1) == '@' then
    local path = src:sub(2)
    local root = path:match('^(.*)/utils/[^/]+$')
    if root then return root end
  end
  return '.'
end

local ROOT = script_root()
local MAP_PATH = ROOT .. '/character_map.txt'
local OUTPUT_PATH = ROOT .. '/character_map_embedded.h'

local raw_lines, err = read_lines(MAP_PATH)
if not raw_lines then
  io.stderr:write('ERROR: ', err or 'unable to read character_map.txt', '\n')
  os.exit(1)
end

-- Filter blank and full-line `#` comments; glyph = first whitespace-delimited
-- token (trailing `<glyph> # comment` is ignored).
local lines = {}
for _, line in ipairs(raw_lines) do
  if line ~= '' and line:sub(1, 2) ~= '##' then
    lines[#lines + 1] = line:match('^(%S+)')
  end
end

if #lines ~= 256 then
  io.stderr:write(string.format('expected 256 glyph lines in %s, got %d\n', MAP_PATH, #lines))
  os.exit(1)
end

local out, err2 = io.open(OUTPUT_PATH, 'w')
if not out then
  io.stderr:write('ERROR: ', err2 or 'unable to write output', '\n')
  os.exit(1)
end

out:write('#pragma once\n')
out:write('// Auto-generated from character_map.txt to support embedded builds\n')
out:write('static const char *embedded_character_map[256] = {\n')
for _, line in ipairs(lines) do
  out:write(string.format('    %q,\n', line))
end
out:write('};\n')
out:close()

print(string.format('Wrote %s', OUTPUT_PATH:gsub('^' .. ROOT .. '/+', '')))
