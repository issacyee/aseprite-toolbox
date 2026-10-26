local Export = {}
Export.__index = Export
local owner = "toolbox-timelapse-recorder-v1"
function Export.new(fs, platform, worker, windows, normalize)
  return setmetatable({ fs = fs, platform = platform, worker = worker, windows = windows,
    normalize = normalize, abandoned = {} }, Export)
end
function Export:read(root, name)
  local path = self.fs.join(root, name)
  if not self.fs.isFile(path) then return "" end
  -- Windows 工作进程发布状态和进度文件时，文件可能被短暂锁定。
  local ok, value = pcall(self.fs.read, path)
  return ok and value or ""
end
function Export:cleanup(root)
  assert(self:read(root, "owner") == owner, "Refusing to clean an unknown task folder")
  assert(not self.fs.exists(self.fs.join(root, "previous.mp4")), "Original video backup kept in the task folder for recovery")
  -- 只清理专属任务目录中的直接普通文件，不递归删除目录。
  for _, file in ipairs(self.fs.list(root)) do
    local path = self.fs.join(root, file)
    assert(self.fs.isFile(path), "Unknown subfolder found; task folder kept: " .. path)
    if file ~= "owner" then self.fs.remove(path) end
  end
  self.fs.remove(self.fs.join(root, "owner"))
  self.fs.rmdir(root)
end
function Export:recover(roots)
  for _, root in ipairs(roots) do
    if self.fs.isDirectory(root) and self:read(root, "owner") == owner then
      self.fs.write(self.fs.join(root, "cancel"), "cancel")
      self.abandoned[#self.abandoned + 1] = root
    end
  end
end
function Export:pendingRoots()
  local roots = {}
  for _, root in ipairs(self.abandoned) do roots[#roots + 1] = root end
  if self.job and (not self.job.finished or self.job.cleanupPending) then roots[#roots + 1] = self.job.root end
  return roots
end
function Export:start(record, output, options)
  assert(not self.job or self.job.finished, "An export is already running")
  assert(#record.frames > 0, "No recorded frames to export")
  assert(output:lower():match("%.mp4$"), "Output filename must end in .mp4")
  assert(not output:find("[\r\n%z]"), "Output path cannot contain line breaks")
  assert(not self.fs.isDirectory(output), "Output destination is a folder")
  assert(not self.fs.exists(output) or options.overwrite, "Output file already exists")
  assert(options.fps >= 1 and options.fps <= 120 and options.fps % 1 == 0, "FPS must be an integer from 1 to 120")
  assert(options.scale >= 1 and options.scale <= 16 and options.scale % 1 == 0, "Scale must be an integer from 1 to 16")
  assert(options.hold >= 0 and options.hold <= 60, "End hold must be between 0 and 60 seconds")
  assert(options.background:match("^%x%x%x%x%x%x$"), "Background must be a six-digit RGB hex color")
  local encoder = options.ffmpeg ~= "" and options.ffmpeg or "ffmpeg"
  assert(not encoder:find("[\r\n%z]"), "FFmpeg path cannot contain line breaks")
  local frames, width, height = {}, 0, 0
  for _, frame in ipairs(record.frames) do
    frames[#frames + 1] = { file = self.fs.join(record.root, frame.file), width = frame.width, height = frame.height }
    width, height = math.max(width, frame.width), math.max(height, frame.height)
  end
  assert(width * options.scale <= 16384 and height * options.scale <= 16384, "Export exceeds 16384 pixels on one axis; reduce scale")
  local root
  repeat root = output .. ".timelapse-job-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
  until not self.fs.exists(root)
  self.fs.mkdir(root)
  self.fs.write(self.fs.join(root, "owner"), owner)
  local job = { root = root, output = output, options = options, frames = frames, width = width,
    height = height, prepared = 0, phase = "probing", started = os.time(), progress = 0 }
  self.job = job -- 即使启动失败，也保留任务信息以供后续恢复。
  for name, value in pairs{ ffmpeg = encoder, fps = options.fps, scale = options.scale,
      hold = options.hold, background = options.background, mode = "probe" } do
    self.fs.write(self.fs.join(root, name .. ".txt"), tostring(value) .. "\n")
  end
  self:launch()
  return job
end
function Export:launch()
  self.fs.write(self.fs.join(self.job.root, "status"), "starting")
  self.job.started = os.time()
  self.platform.launch(self.windows, self.worker, self.job.root)
end
function Export:cancel()
  local job = self.job
  if not job or job.finished then return end
  job.cancelled = true
  self.fs.write(self.fs.join(job.root, "cancel"), "cancel")
  if job.phase == "preparing" then self:finish(job.failure and "failed" or "cancelled", job.failure) end
end
function Export:abort(message)
  local job = self.job
  if not job or job.finished then return end
  job.failure = tostring(message)
  local status = self:read(job.root, "status"):match("%S+")
  if job.phase == "preparing" or status == "done" or status == "ready" or status == "failed" or status == "cancelled" then
    self:finish("failed", job.failure)
  else self:cancel() end
end
function Export:finish(state, message)
  local job = self.job
  if state == "done" then
    local fs, encoded = self.fs, self.fs.join(job.root, "encoded.mp4")
    assert(fs.isFile(encoded) and fs.size(encoded) > 0, "FFmpeg did not produce a valid output file")
    local previous = fs.join(job.root, "previous.mp4")
    if fs.exists(job.output) then
      assert(job.options.overwrite, "Output appeared during export and was not overwritten")
      fs.rename(job.output, previous)
    end
    local ok, err = pcall(fs.rename, encoded, job.output)
    if not ok then
      if fs.exists(previous) then fs.rename(previous, job.output) end
      error(err)
    end
    if fs.exists(previous) then fs.remove(previous) end
    job.progress = 1
  end
  job.phase, job.finished, job.message = state, true, message
  local ok, err = pcall(self.cleanup, self, job.root)
  if not ok then
    job.cleanupPending = true
    job.message = (job.message or "") .. "\nTemporary folder kept at " .. job.root .. ": " .. tostring(err)
    -- 发布失败且无法回滚时，保留原视频备份。
  end
end
function Export:tick()
  for i = #self.abandoned, 1, -1 do
    local root = self.abandoned[i]
    local status = self:read(root, "status"):match("%S+")
    if status == "done" or status == "failed" or status == "cancelled" or status == "ready" then
      if not self.fs.isFile(self.fs.join(root, "previous.mp4")) then
        local ok = pcall(self.cleanup, self, root)
        if ok then table.remove(self.abandoned, i) end
      end
    end
  end
  local job = self.job
  if not job or job.finished then return end
  local status = self:read(job.root, "status"):match("%S+")
  if status == "failed" then
    local message = ""
    for _, file in ipairs{ "worker-error.log", "encode-error.log", "stderr.log", "probe-error.log", "probe.log", "launcher.log" } do
      local log = self:read(job.root, file)
      if #log > 0 then message = message .. "\n" .. log:sub(-1800) end
    end
    self:finish("failed", "FFmpeg export failed. Check its path and libx264 support." .. message)
    return
  elseif status == "cancelled" or (job.cancelled and (status == "done" or status == "ready")) then
    self:finish(job.failure and "failed" or "cancelled", job.failure or job.message) return
  elseif job.phase == "probing" and status == "ready" then
    job.phase = "preparing"
  elseif job.phase == "encoding" and status == "done" then
    self:finish("done") return
  end
  if job.phase == "preparing" then
    local started = os.clock()
    for _ = 1, 4 do
      local index = job.prepared + 1
      if index > #job.frames then break end
      self.normalize(job.frames[index], self.fs.join(job.root, ("frame-%08d.png"):format(index)),
        job.width, job.height, job.options.background)
      job.prepared = index
      job.progress = 0.4 * index / #job.frames
      if os.clock() - started > 0.012 then break end
    end
    collectgarbage("step", 64)
    if job.prepared == #job.frames then
      self.fs.write(self.fs.join(job.root, "mode.txt"), "encode\n")
      job.phase = "encoding"
      self:launch()
    end
  elseif job.phase == "encoding" then
    local last = 0
    for frame in self:read(job.root, "progress.txt"):gmatch("frame=(%d+)") do last = tonumber(frame) end
    job.progress = 0.4 + 0.59 * math.min(1, last / (#job.frames + math.ceil(job.options.hold * job.options.fps)))
  end
  if (status == "starting" or job.phase == "probing") and os.time() - job.started > 30 and not job.timeout then
    job.timeout = true
    self:cancel()
    job.message = "Worker did not become ready within 30 seconds. Check FFmpeg and process permissions."
  end
end
return Export
