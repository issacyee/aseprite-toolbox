-- 格式版本 1：manifest.jsonl 以追加方式记录日志，编号 PNG 保存实际画面。
-- PNG 已完整发布但日志追加失败时，重新打开记录即可恢复该帧。
local Store = {}
Store.__index = Store
function Store.new(fs, codec)
  return setmetatable({ fs = fs, codec = codec }, Store)
end
function Store:line(value) return self.codec.encode(value) .. "\n" end
function Store:open(source, create)
  local fs, root = self.fs, self.fs.sidecar(source)
  local manifest = fs.join(root, "manifest.jsonl")
  if not fs.exists(root) then
    if not create then return nil end
    fs.mkdir(root)
    fs.write(manifest, self:line{ type = "header", version = 1, source = source }
      .. self:line{ type = "state", state = "recording" })
  end
  local input = manifest
  if not fs.exists(input) and fs.exists(input .. ".bak") then input = input .. ".bak" end
  assert(fs.isFile(input), "Existing recording folder has no valid manifest: " .. root)
  local data, expected, state, header = fs.read(input), {}, "paused", nil
  local pos = 1
  while true do
    local stop = data:find("\n", pos, true)
    if not stop then break end
    local line = data:sub(pos, stop - 1)
    local ok, entry = pcall(self.codec.decode, line)
    if not ok or (type(entry) ~= "table" and type(entry) ~= "userdata") then break end
    if not header then
      assert(entry.type == "header" and entry.version == 1, "Unsupported recording format")
      header = entry
    elseif entry.type == "state" then
      assert(entry.state == "paused" or entry.state == "recording", "Invalid recording state")
      state = entry.state
    elseif entry.type == "frame" then
      assert(type(entry.file) == "string" and entry.file:match("^frame%-%d%d%d%d%d%d%d%d%.png$"), "Invalid frame entry")
      expected[entry.file] = true
    else error("Invalid recording manifest") end
    pos = stop + 1
  end
  assert(header, "Recording manifest is damaged; existing records were left untouched")
  assert(type(header.source) == "string", "Invalid recording source")
  local key = fs.key or function(p) return p end
  local previousName = key(header.source):gsub("\\", "/"):match("[^/]+$")
  local currentName = key(source):gsub("\\", "/"):match("[^/]+$")
  if previousName ~= currentName then
    assert(previousName:gsub("%.[^.]+$", "") ~= currentName:gsub("%.[^.]+$", ""),
      "Another file format with the same name owns this recording folder; use a different artwork name")
  end
  -- 以 PNG 校验和恢复记录，避免依赖尚未完整追加的日志尾部。
  local frames, found, maxId, damaged = {}, {}, 0, false
  for _, name in ipairs(fs.list(root)) do
    local number = name:match("^frame%-(%d%d%d%d%d%d%d%d)%.png$")
    if number then
      local id = tonumber(number)
      maxId = math.max(maxId, id)
      local ok, w, h = pcall(fs.pngInfo, fs.join(root, name))
      if ok and w then
        frames[#frames + 1] = { type = "frame", id = id, file = name, width = w, height = h }
        found[name] = true
      else damaged = true end
    end
  end
  for name in pairs(expected) do if not found[name] then damaged = true end end
  table.sort(frames, function(a, b) return a.id < b.id end)
  if damaged then state = "paused" end
  local lines = { self:line(header), self:line{ type = "state", state = state } }
  for _, frame in ipairs(frames) do lines[#lines + 1] = self:line(frame) end
  local recovered = table.concat(lines)
  if input ~= manifest or recovered ~= data then fs.replace(manifest, recovered) end
  return { source = source, root = root, manifest = manifest, state = state,
    frames = frames, nextId = maxId + 1, damaged = damaged }
end
function Store:setState(record, state)
  assert(state == "paused" or state == "recording")
  self.fs.append(record.manifest, self:line{ type = "state", state = state })
  record.state = state
end
function Store:commit(record, image)
  local fs, id = self.fs, record.nextId
  assert(id <= 99999999, "Recording frame limit exceeded")
  record.nextId = id + 1 -- 不覆盖尚未登记或已经损坏的编号文件。
  local name = ("frame-%08d.png"):format(id)
  local dest = fs.join(record.root, name)
  local temp = fs.join(record.root, ("pending-%08d.png"):format(id))
  local ok, err = pcall(function()
    assert(not fs.exists(dest), "Recorded frame already exists")
    assert(image:saveAs(temp) ~= false, "Failed to save snapshot")
    fs.rename(temp, dest)
  end)
  if not ok then return nil, err end
  local frame = { type = "frame", id = id, file = name, width = image.width, height = image.height }
  record.frames[#record.frames + 1] = frame
  ok, err = pcall(fs.append, record.manifest, self:line(frame))
  return frame, not ok and err or nil
end
function Store:fork(record, source)
  local fs, root = self.fs, self.fs.sidecar(source)
  local key = fs.key or function(p) return p end
  if key(source) == key(record.source) then record.source = source return record end
  assert(not fs.exists(root), "Save As recording folder already exists; recording paused: " .. root)
  fs.mkdir(root)
  for _, frame in ipairs(record.frames) do
    fs.copy(fs.join(record.root, frame.file), fs.join(root, frame.file))
  end
  local lines = { self:line{ type = "header", version = 1, source = source },
    self:line{ type = "state", state = record.state } }
  for _, frame in ipairs(record.frames) do lines[#lines + 1] = self:line(frame) end
  -- 最后发布清单，避免复制失败的目录被识别为完整的独立记录。
  fs.write(fs.join(root, "manifest.jsonl"), table.concat(lines))
  return assert(self:open(source, false))
end
return Store
