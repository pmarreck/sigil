#!/usr/bin/env luajit
-- Audit printable-binary character_map.txt for basic invariants.

local bit = require('bit')

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

local function script_dir()
  local info = debug.getinfo(1, 'S')
  local src = info.source
  if src:sub(1,1) == '@' then
    local dir = src:match('^@(.*/)[^/]*$') or './'
    return dir
  end
  return './'
end

local function load_eaw()
  local path = script_dir() .. 'data/EastAsianWidth.txt'
  local fh, err = io.open(path, 'r')
  if not fh then
    error('Unable to open EastAsianWidth.txt: ' .. (err or 'unknown'))
  end
  local ranges = {}
  for line in fh:lines() do
    if not line:match('^#') and line:find(';') then
      local range, prop = line:match('(%S+)%s*;%s*(%a+)')
      if range and prop then
        local start_hex, end_hex = range:match('^(%x+)%.%.(%x+)$')
        if not start_hex then
          start_hex, end_hex = range, range
        end
        local start_cp = tonumber(start_hex, 16)
        local end_cp = tonumber(end_hex, 16)
        ranges[#ranges+1] = {start_cp, end_cp, prop}
      end
    end
  end
  fh:close()
  table.sort(ranges, function(a,b) return a[1] < b[1] end)
  return ranges
end

local EAW_RANGES = load_eaw()

local function east_asian_width(cp)
  local lo, hi = 1, #EAW_RANGES
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local r = EAW_RANGES[mid]
    if cp < r[1] then
      hi = mid - 1
    elseif cp > r[2] then
      lo = mid + 1
    else
      return r[3]
    end
  end
  return '?'
end

local function utf8_codepoint(str)
  local b1 = str:byte(1)
  if not b1 then return nil end
  if b1 < 0x80 then
    return b1
  elseif bit.rshift(b1,5) == 0x6 then
    local b2 = str:byte(2)
    return bit.bor(bit.lshift(bit.band(b1,0x1F),6), bit.band(b2,0x3F))
  elseif bit.rshift(b1,4) == 0xE then
    local b2, b3 = str:byte(2), str:byte(3)
    return bit.bor(
      bit.lshift(bit.band(b1,0x0F),12),
      bit.lshift(bit.band(b2,0x3F),6),
      bit.band(b3,0x3F)
    )
  elseif bit.rshift(b1,3) == 0x1E then
    local b2, b3, b4 = str:byte(2), str:byte(3), str:byte(4)
    return bit.bor(
      bit.lshift(bit.band(b1,0x07),18),
      bit.lshift(bit.band(b2,0x3F),12),
      bit.lshift(bit.band(b3,0x3F),6),
      bit.band(b4,0x3F)
    )
  end
  return nil
end

local function audit(path)
  local entries, err = read_lines(path)
  if not entries then
    io.stderr:write('ERROR: ', err or 'failed to read file', '\n')
    return 1
  end

  if #entries ~= 256 then
    io.stderr:write(string.format('ERROR: Expected 256 entries, found %d\n', #entries))
    return 1
  end

  local seen = {}
  local duplicates = {}
  for _, ch in ipairs(entries) do
    if seen[ch] then
      duplicates[ch] = true
    end
    seen[ch] = true
  end
  local dup_count = 0
  for _ in pairs(duplicates) do dup_count = dup_count + 1 end
  if dup_count > 0 then
    local list = {}
    for ch in pairs(duplicates) do list[#list+1] = ch end
    table.sort(list)
    io.stderr:write('ERROR: Duplicate characters detected: ', table.concat(list, ', '), '\n')
    return 1
  end

  print('character map OK (256 unique entries)')
  print('\nIndex | Char | Code point | UTF-8 bytes | Width')
  print('----- | ---- | ---------- | ------------ | -----')
  local length_counts = {}
  for idx, ch in ipairs(entries) do
    local cp = utf8_codepoint(ch)
    local bytes = {}
    for i = 1, #ch do
      bytes[#bytes+1] = string.format('%02X', ch:byte(i))
    end
    local width = cp and east_asian_width(cp) or '?'
    print(string.format('%5d | %s | U+%04X    | %-12s | %s', idx-1, ch, cp or 0, table.concat(bytes, ' '), width))
    local len = #ch
    length_counts[len] = (length_counts[len] or 0) + 1
  end

  print('\nUTF-8 length distribution:')
  local keys = {}
  for len in pairs(length_counts) do keys[#keys+1] = len end
  table.sort(keys)
  for _, len in ipairs(keys) do
    print(string.format('  %d-byte glyphs: %d', len, length_counts[len]))
  end

  return 0
end

local target = arg[1] or 'character_map.txt'
os.exit(audit(target))
