local root = app.fs.filePath(debug.getinfo(1, "S").source:sub(2))
local fs = dofile(app.fs.joinPath(root, "lib", "fs.lua"))
local Store = dofile(app.fs.joinPath(root, "lib", "store.lua"))
local Recorder = dofile(app.fs.joinPath(root, "lib", "recorder.lua"))
local Platform = dofile(app.fs.joinPath(root, "lib", "platform.lua"))
local Export = dofile(app.fs.joinPath(root, "lib", "export.lua"))
local runtime

local function render(sprite)
  local image = Image(sprite.width, sprite.height, ColorMode.RGB)
  image:drawSprite(sprite, 1)
  return image
end
local function normalize(frame, path, width, height, hex)
  local image = Image{ fromFile = frame.file }
  local canvas = Image(width, height, ColorMode.RGB)
  canvas:clear(Color{ r = tonumber(hex:sub(1, 2), 16), g = tonumber(hex:sub(3, 4), 16),
    b = tonumber(hex:sub(5, 6), 16), a = 255 })
  canvas:drawImage(image, Point(math.floor((width - image.width) / 2), math.floor((height - image.height) / 2)))
  assert(canvas:saveAs(path) ~= false, "Failed to prepare an export frame")
end
local function newRuntime(plugin)
  local rt = { plugin = plugin, seen = {}, errors = {}, appListeners = {} }
  local function notify(message) rt.errors[#rt.errors + 1] = tostring(message) end
  rt.recorder = Recorder.new(Store.new(fs, json), render,
    function(path) return assert(Image{ fromFile = path }, "Cannot read recorded image: " .. path) end, notify)
  rt.exporter = Export.new(fs, Platform, fs.join(root, "workers", app.os.windows and "encode.ps1" or "encode.sh"),
    app.os.windows, normalize)
  local ok, pending = pcall(json.decode, plugin.preferences.pendingExports or "[]")
  if ok and (type(pending) == "table" or type(pending) == "userdata") then rt.exporter:recover(pending) end
  function rt:rememberJobs() plugin.preferences.pendingExports = json.encode(self.exporter:pendingRoots()) end
  function rt:guard(fn, session)
    local success, err = pcall(fn)
    if not success then
      if session then self.recorder:fail(session, err) else notify(err) end
    end
    return success
  end
  function rt:bind(sprite, create)
    if not sprite or not sprite.isValid or not sprite.hasAssociatedFile then return nil end
    local session = self.recorder:attach(sprite, create)
    if not session or session.bound then return session end
    session.bound = true
    for _, event in ipairs{ "change", "layervisibility", "layeropacity", "layerblendmode" } do
      session.listeners[#session.listeners + 1] = sprite.events:on(event, function()
        self:guard(function()
          self.recorder:rename(session)
          self.recorder:capture(session)
        end, session)
      end)
    end
    session.listeners[#session.listeners + 1] = sprite.events:on("filenamechange", function()
      self:guard(function() self.recorder:rename(session) end, session)
    end)
    if session.record.state == "recording" then self.recorder:capture(session) end
    return session
  end
  function rt:scan()
    for _, sprite in ipairs(app.sprites) do
      if self.seen[sprite.id] ~= sprite.filename then
        self.seen[sprite.id] = sprite.filename
        self:guard(function() self:bind(sprite, false) end)
      end
    end
  end
  function rt:current()
    return app.sprite and self.recorder.sessions[app.sprite.id] or nil
  end
  function rt:enable()
    local sprite = app.sprite
    assert(sprite, "Open an artwork first")
    assert(#sprite.frames == 1, "Only single-frame artwork is supported")
    if not sprite.hasAssociatedFile then
      app.command.SaveFileAs()
      if not sprite.isValid or not sprite.hasAssociatedFile then return end
    end
    local session = self:bind(sprite, true)
    assert(session, "Save the artwork before recording")
    self.recorder:resume(session)
    self.recorder:flush(session)
  end
  function rt:settings()
    local dialog = Dialog{ title = "Timelapse Settings" }
    dialog:file{ id = "ffmpeg", label = "FFmpeg:", filename = plugin.preferences.ffmpeg or "", open = true,
      filetypes = app.os.windows and { "exe" } or {} }
      :label{ text = "Leave blank to use PATH. Requires libx264." }
      :button{ id = "save", text = "Save" }:button{ text = "Cancel" }:show()
    if dialog.data.save then plugin.preferences.ffmpeg = dialog.data.ffmpeg end
  end
  function rt:exportDialog()
    local session = self:current()
    assert(session, "Enable recording for this artwork first")
    assert(self.recorder:flush(session), "Cannot export until recording writes succeed")
    local dialog = Dialog{ title = "Export Timelapse" }
    dialog:file{ id = "output", label = "MP4:", save = true, filetypes = { "mp4" },
      filename = app.fs.filePathAndTitle(session.record.source) .. "-timelapse.mp4" }
      :number{ id = "fps", label = "FPS:", text = "24", decimals = 0 }
      :number{ id = "scale", label = "Integer scale:", text = "1", decimals = 0 }
      :number{ id = "hold", label = "End hold (seconds):", text = "2", decimals = 2 }
      :color{ id = "background", label = "Background:", color = Color{ r = 255, g = 255, b = 255 } }
      :button{ id = "export", text = "Export" }:button{ text = "Cancel" }:show()
    local data = dialog.data
    if not data.export then return end
    local overwrite = false
    if fs.exists(data.output) then
      overwrite = app.alert{ title = "Replace Video", text = "Replace the existing video? Recorded PNGs will be kept.", buttons = { "Replace", "Cancel" } } == 1
      if not overwrite then return end
    end
    local color = data.background
    self.exporter:start(session.record, data.output, { fps = data.fps, scale = data.scale, hold = data.hold,
      background = ("%02x%02x%02x"):format(color.red, color.green, color.blue),
      ffmpeg = plugin.preferences.ffmpeg or "", overwrite = overwrite })
    self:rememberJobs()
    self:panel()
  end
  function rt:updatePanel()
    if not self.dialog then return end
    local session, job = self:current(), self.exporter.job
    local status = not session and "Not enabled" or session.error and "Paused (error)"
      or session.record.state == "recording" and "Recording" or "Paused"
    self.dialog:modify{ id = "state", text = status }
      :modify{ id = "count", text = session and tostring(#session.record.frames + #session.queue) or "0" }
      :modify{ id = "path", text = session and session.record.root or "Save an artwork to enable recording" }
      :modify{ id = "pause", enabled = session ~= nil and session.record.state == "recording" }
      :modify{ id = "resume", text = session and "Resume Recording" or "Enable Recording",
        enabled = app.sprite ~= nil and (not session or session.record.state == "paused") }
      :modify{ id = "export", enabled = session ~= nil and (not job or job.finished) }
      :modify{ id = "cancel", enabled = job ~= nil and not job.finished }
    local phases = { probing = "Checking FFmpeg", preparing = "Preparing frames", encoding = "Encoding", done = "Complete",
      failed = "Export failed", cancelled = "Cancelled" }
    self.dialog:modify{ id = "progress", text = job and ((phases[job.phase] or job.phase)
      .. (" %d%%"):format(math.floor(job.progress * 100))) or "No export running" }
  end
  function rt:panel()
    if self.dialog then self:updatePanel() return end
    self.dialog = Dialog{ title = "Timelapse Recorder", onclose = function() self.dialog = nil end }
    self.dialog:label{ id = "state", label = "Status:", text = "Not enabled" }
      :label{ id = "count", label = "Recorded frames:", text = "0" }
      :entry{ id = "path", label = "Recording folder:", text = "", enabled = false }
      :button{ id = "resume", text = "Enable Recording", onclick = function() self:guard(function() self:enable() end) end }
      :button{ id = "pause", text = "Pause", onclick = function()
        self:guard(function() local s = self:current() if s then self.recorder:pause(s) end end)
      end }:newrow()
      :button{ id = "export", text = "Export MP4...", onclick = function() self:guard(function() self:exportDialog() end) end }
      :button{ text = "Settings...", onclick = function() self:guard(function() self:settings() end) end }
      :label{ id = "progress", label = "Export:", text = "No export running" }
      :button{ id = "cancel", text = "Cancel Export", onclick = function() self:guard(function() self.exporter:cancel() end) end }
      :show{ wait = false }
    self:updatePanel()
  end
  function rt:tick()
    self:scan()
    for id, session in pairs(self.recorder.sessions) do
      if not session.error then self.recorder:flush(session, 2) end
      if not session.sprite.isValid and #session.queue == 0 then
        self.recorder.sessions[id], self.seen[id] = nil, nil
      end
    end
    local success, exportError = pcall(self.exporter.tick, self.exporter)
    if not success then self:guard(function() self.exporter:abort(exportError) end) end
    local job = self.exporter.job
    if job and job.finished and not job.reported then
      job.reported = true
      if job.phase == "done" then notify("Video exported: " .. job.output .. (job.message or ""))
      elseif job.message then notify(job.message) end
    end
    self:rememberJobs()
    self:updatePanel()
    if #self.errors > 0 then
      local message = table.remove(self.errors, 1)
      if app.isUIAvailable then app.alert{ title = "Timelapse Recorder", text = message } else print(message) end
    end
  end
  function rt:shutdown()
    if self.timer then self.timer:stop() end
    self.exporter:cancel()
    self:rememberJobs()
    for _, code in ipairs(self.appListeners) do app.events:off(code) end
    for _, session in pairs(self.recorder.sessions) do
      self.recorder:flush(session)
      if session.sprite.isValid then
        for _, code in ipairs(session.listeners) do session.sprite.events:off(code) end
      end
    end
    if self.dialog then self.dialog:close() end
  end
  return rt
end
function init(plugin)
  -- 自编译的发布版本带有 -dev 后缀，因此只比较数字版本。
  if Version(tostring(app.version):match("^[%d%.]+")) < Version("1.3.18.6") then
    app.alert("Timelapse Recorder requires Aseprite 1.3.18.6 or newer") return
  end
  runtime = newRuntime(plugin)
  plugin:newMenuGroup{ id = "toolbox_timelapse", title = "Timelapse", group = "sprite_properties" }
  for _, item in ipairs{
    { "ToolboxTimelapsePanel", "Recording Panel...", "panel" },
    { "ToolboxTimelapseExport", "Export MP4...", "exportDialog" },
    { "ToolboxTimelapseSettings", "Settings...", "settings" },
  } do
    local method = item[3]
    plugin:newCommand{ id = item[1], title = item[2], group = "toolbox_timelapse", onclick = function()
      runtime:guard(function() runtime[method](runtime) end)
    end }
  end
  runtime.appListeners[#runtime.appListeners + 1] = app.events:on("sitechange", function()
    runtime:guard(function() runtime:scan() end)
  end)
  runtime:scan()
  if app.isUIAvailable then
    runtime.timer = Timer{ interval = 0.2, ontick = function() runtime:guard(function() runtime:tick() end) end }
    runtime.timer:start()
  end
end
function exit() if runtime then runtime:shutdown() runtime = nil end end
return { newRuntime = newRuntime, render = render, normalize = normalize }
