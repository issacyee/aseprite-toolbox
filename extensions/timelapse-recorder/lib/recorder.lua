local Recorder = {}
Recorder.__index = Recorder
function Recorder.new(store, render, load, notify)
  return setmetatable({ store = store, render = render, load = load, notify = notify,
    sessions = {}, maxQueue = 8, maxBytes = 32 * 1024 * 1024 }, Recorder)
end
function Recorder:fail(session, err)
  session.error = tostring(err)
  session.record.state = "paused"
  pcall(self.store.setState, self.store, session.record, "paused")
  self.notify(session.error)
end
function Recorder:attach(sprite, create)
  if self.sessions[sprite.id] then return self.sessions[sprite.id] end
  local key = self.store.fs.key or function(p) return p end
  local root = key(self.store.fs.sidecar(sprite.filename))
  for id, other in pairs(self.sessions) do
    if key(other.record.root) == root then
      if other.sprite.isValid == false and self:flush(other) then self.sessions[id] = nil
      else error("Another open document is already using this recording folder") end
    end
  end
  local record = self.store:open(sprite.filename, create)
  if not record then return nil end
  local session = { sprite = sprite, record = record, queue = {}, bytes = 0, listeners = {} }
  self.sessions[sprite.id] = session
  if #record.frames > 0 then
    local ok, image = pcall(self.load, self.store.fs.join(record.root, record.frames[#record.frames].file))
    if ok then session.last = image else self:fail(session, image) end
  end
  if record.damaged then self:fail(session, "Incomplete PNGs detected. Valid frames were kept. Check the recording before resuming.") end
  return session
end
function Recorder:flush(session, limit)
  for _ = 1, math.min(limit or #session.queue, #session.queue) do
    local item = session.queue[1]
    local frame, err = self.store:commit(session.record, item.image)
    if frame then
      table.remove(session.queue, 1)
      session.bytes = session.bytes - item.bytes
    end
    if err then self:fail(session, err) return false end
  end
  collectgarbage("step", 64) -- 定期释放不再被引用的原生 Image 缓冲区。
  return true
end
function Recorder:capture(session)
  if session.record.state ~= "recording" or session.error then return end
  if #session.sprite.frames ~= 1 then
    self:fail(session, "Animation frames detected. Recording paused; only single-frame artwork is supported.") return
  end
  local ok, image = pcall(self.render, session.sprite)
  if not ok then self:fail(session, image) return end
  if session.last and image:isEqual(session.last) then return end
  local bytes = image.width * image.height * 4
  if #session.queue > 0 and (#session.queue >= self.maxQueue or session.bytes + bytes > self.maxBytes) then
    if not self:flush(session) then return end
  end
  session.queue[#session.queue + 1] = { image = image, bytes = bytes }
  session.bytes = session.bytes + bytes
  session.last = image
  if bytes >= self.maxBytes then self:flush(session) end
end
function Recorder:pause(session)
  if not self:flush(session) then return end
  self.store:setState(session.record, "paused")
end
function Recorder:resume(session)
  assert(#session.sprite.frames == 1, "Only single-frame artwork is supported")
  if session.sprite.filename ~= session.record.source then
    self:rename(session)
    assert(session.sprite.filename == session.record.source, "Resolve the Save As recording-folder conflict before resuming")
  end
  -- 追加新记录前先修复不完整的日志，同时保留仍待写入的图像。
  session.record = assert(self.store:open(session.record.source, false))
  session.error = nil
  if not self:flush(session) then return end
  self.store:setState(session.record, "recording")
  self:capture(session)
end
function Recorder:rename(session)
  if session.sprite.filename == session.record.source then return end
  if not self:flush(session) then return end
  local ok, record = pcall(self.store.fork, self.store, session.record, session.sprite.filename)
  if ok then session.record = record else self:fail(session, record) end
end
return Recorder
