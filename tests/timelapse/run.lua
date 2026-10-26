-- 使用 lua5.4（需 lua-cjson）或 aseprite -b --script tests/timelapse/run.lua 运行。
local script = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local repo = script:match("^(.*)/tests/timelapse/run.lua$") or "."
local lib = repo .. "/extensions/timelapse-recorder/lib/"
local Store, Recorder = dofile(lib .. "store.lua"), dofile(lib .. "recorder.lua")
local Platform, Export = dofile(lib .. "platform.lua"), dofile(lib .. "export.lua")
local codec = json or require("cjson")
local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then error("FAIL " .. name .. ": " .. tostring(err)) end
  passed = passed + 1 print("PASS " .. name)
end
local function environment()
  local files, dirs, fs = {}, {}, {}
  fs.join = function(...) return table.concat({...}, "/") end
  fs.sidecar = function(p) return p:gsub("%.[^./]+$", "") .. ".timelapse" end
  fs.exists = function(p) return files[p] ~= nil or dirs[p] ~= nil end
  fs.isFile = function(p) return files[p] ~= nil end
  fs.isDirectory = function(p) return dirs[p] ~= nil end
  fs.mkdir = function(p) assert(not fs.exists(p)) dirs[p] = true end
  fs.read = function(p) return assert(files[p], p) end
  fs.write = function(p, data) assert(not fs.failWrite, "disk full") files[p] = data end
  fs.append = function(p, data) assert(not fs.failAppend, "journal full") fs.write(p, fs.read(p) .. data) end
  fs.replace = fs.write
  fs.rename = function(a, b) assert(not fs.exists(b)) files[b], files[a] = fs.read(a), nil end
  fs.copy = function(a, b) assert(not fs.exists(b)) fs.write(b, fs.read(a)) end
  fs.remove = function(p) files[p] = nil end
  fs.rmdir = function(p) dirs[p] = nil end
  fs.size = function(p) return type(files[p]) == "string" and #files[p] or 64 end
  fs.list = function(p)
    local list = {}
    for file in pairs(files) do if file:sub(1, #p + 1) == p .. "/" then list[#list + 1] = file:sub(#p + 2) end end
    return list
  end
  fs.pngInfo = function(p)
    local data = files[p]
    if type(data) == "table" and not data.damaged then return data.width, data.height end
  end
  local function image(value, width, height)
    local im = { value = value, width = width or 16, height = height or 16 }
    function im:saveAs(p) fs.write(p, { value = self.value, width = self.width, height = self.height }) return true end
    function im:isEqual(other) return self.value == other.value and self.width == other.width and self.height == other.height end
    return im
  end
  local store, notices = Store.new(fs, codec), {}
  local recorder = Recorder.new(store, function(s) return image(s.value, s.width, s.height) end,
    function(p) local d = fs.read(p) return image(d.value, d.width, d.height) end,
    function(e) notices[#notices + 1] = e end)
  local sprite = { id = 1, filename = "/art/hero.aseprite", frames = {1}, value = 0 }
  return { fs = fs, files = files, dirs = dirs, store = store, recorder = recorder, sprite = sprite,
    image = image, notices = notices }
end
test("1000 edits preserve every distinct state with a bounded queue", function()
  local e = environment()
  local session = e.recorder:attach(e.sprite, true)
  e.recorder:capture(session)
  for i = 1, 1000 do
    e.sprite.value = i e.recorder:capture(session)
    assert(#session.queue <= 8 and session.bytes <= e.recorder.maxBytes)
  end
  assert(e.recorder:flush(session)) assert(#session.record.frames == 1001)
  for i, frame in ipairs(session.record.frames) do assert(e.files[e.fs.join(session.record.root, frame.file)].value == i - 1) end
end)
test("dedup, undo/redo, pause and resume", function()
  local e = environment() local s = e.recorder:attach(e.sprite, true)
  e.recorder:capture(s) e.recorder:capture(s) e.recorder:pause(s)
  e.sprite.value = 1 e.recorder:capture(s) assert(#s.record.frames == 1)
  e.recorder:resume(s) e.sprite.value = 0 e.recorder:capture(s)
  e.sprite.value = 1 e.recorder:capture(s) e.recorder:flush(s)
  assert(#s.record.frames == 4)
end)
test("close/reopen retains recording and paused states", function()
  local e = environment() local s = e.recorder:attach(e.sprite, true)
  e.recorder:capture(s) e.recorder:flush(s)
  local reopened = e.store:open(e.sprite.filename, false)
  assert(reopened.state == "recording" and #reopened.frames == 1)
  e.recorder:pause(s) assert(e.store:open(e.sprite.filename, false).state == "paused")
end)
test("damaged journal tail and complete orphan PNG recover without overwrite", function()
  local e = environment() local r = e.store:open(e.sprite.filename, true)
  e.store:commit(r, e.image(0))
  e.image(1):saveAs(e.fs.join(r.root, "frame-00000002.png"))
  e.files[r.manifest] = e.files[r.manifest] .. '{"type":"fra'
  e.files[e.fs.join(r.root, "frame-00000003.png")] = "truncated PNG"
  local recovered = e.store:open(e.sprite.filename, false)
  assert(#recovered.frames == 2 and recovered.nextId == 4 and recovered.state == "paused")
  e.store:commit(recovered, e.image(4)) assert(recovered.frames[3].id == 4)
end)
test("disk failure pauses, retains queued image, and resumes after repair", function()
  local e = environment() local s = e.recorder:attach(e.sprite, true)
  e.recorder:capture(s) e.fs.failWrite = true
  assert(not e.recorder:flush(s)) assert(#s.queue == 1 and s.record.state == "paused")
  e.fs.failWrite = nil e.recorder:resume(s) e.recorder:flush(s)
  assert(#s.queue == 0 and #s.record.frames == 1 and not s.error)
end)
test("journal failure retains a durable PNG", function()
  local e = environment() local s = e.recorder:attach(e.sprite, true)
  e.recorder:capture(s) e.fs.failAppend = true
  assert(not e.recorder:flush(s)) assert(#s.queue == 0)
  e.fs.failAppend = nil e.recorder:resume(s)
  assert(#s.record.frames == 1 and not s.error)
end)
test("save-as copies history and a conflict cannot mix works", function()
  local e = environment() local s = e.recorder:attach(e.sprite, true)
  e.recorder:capture(s) e.recorder:flush(s)
  local oldRoot = s.record.root e.sprite.filename = "/art/copy.aseprite" e.recorder:rename(s)
  assert(s.record.root ~= oldRoot and #s.record.frames == 1)
  assert(e.fs.exists(e.fs.join(oldRoot, "frame-00000001.png")))
  e.sprite.filename = "/art/hero.aseprite" e.recorder:rename(s)
  assert(s.error and s.record.state == "paused")
  assert(not pcall(e.recorder.resume, e.recorder, s))
end)
test("multiple works are independent and multi-frame editing pauses", function()
  local e = environment() local a = e.recorder:attach(e.sprite, true)
  local other = { id = 2, filename = "/art/other.aseprite", frames = {1}, value = 9 }
  local b = e.recorder:attach(other, true)
  e.recorder:capture(a) e.recorder:capture(b) e.recorder:flush(a) e.recorder:flush(b)
  assert(a.record.root ~= b.record.root)
  e.sprite.frames = {1, 2} e.recorder:capture(a)
  assert(a.record.state == "paused" and b.record.state == "recording")
end)
test("same basename in another format never adopts the existing history", function()
  local e = environment() local r = e.store:open(e.sprite.filename, true)
  e.store:commit(r, e.image(1))
  assert(not pcall(e.store.open, e.store, "/art/hero.png", false))
  assert(not pcall(e.store.fork, e.store, r, "/art/hero.png"))
  assert(e.store:open(e.sprite.filename, false).frames[1].file == r.frames[1].file)
end)
test("two open documents cannot write the same recording", function()
  local e = environment() e.recorder:attach(e.sprite, true)
  local other = { id = 2, filename = e.sprite.filename, frames = {1}, value = 9 }
  assert(not pcall(e.recorder.attach, e.recorder, other, false))
end)
test("future record versions are rejected without changes", function()
  local e = environment() local r = e.store:open(e.sprite.filename, true)
  e.files[r.manifest] = '{"type":"header","version":99}\n'
  assert(not pcall(e.store.open, e.store, e.sprite.filename, false))
  assert(e.files[r.manifest]:find('99'))
end)
test("UTF-16 launcher and shell quoting preserve metacharacters", function()
  assert(Platform.encodedCommand("A") == "QQA=")
  assert(Platform.encodedCommand("中") == "LU4=")
  assert(Platform.encodedCommand("😀") == "PdgA3g==")
  assert(Platform.posixQuote("a'b $()") == "'a'\\''b $()'")
  local command = Platform.command(true, "C:/a % & ' 中/encode.ps1", "D:/out;$(x)")
  assert(not command:find("%$") and not command:find("out;"))
end)
local function exporterFixture()
  local e = environment() local r = e.store:open(e.sprite.filename, true)
  e.store:commit(r, e.image(1, 5, 3)) e.store:commit(r, e.image(2, 7, 1))
  local launches = 0
  local ex = Export.new(e.fs, { launch = function() launches = launches + 1 end }, "worker", false,
    function(_, p, w, h) assert(w == 7 and h == 3) e.image(0, w, h):saveAs(p) end)
  local options = { fps = 24, scale = 1, hold = 2, background = "ffffff", ffmpeg = "", overwrite = false }
  ex:start(r, "/art/video.mp4", options)
  return e, ex, r, function() return launches end
end
test("export freezes history, normalizes dimensions, publishes and cleans", function()
  local e, ex, r, launches = exporterFixture()
  e.store:commit(r, e.image(3)) assert(#ex.job.frames == 2)
  e.fs.write(e.fs.join(ex.job.root, "status"), "ready") ex:tick()
  assert(ex.job.phase == "encoding" and launches() == 2)
  e.fs.write(e.fs.join(ex.job.root, "encoded.mp4"), "encoded video")
  e.fs.write(e.fs.join(ex.job.root, "status"), "done") ex:tick()
  assert(ex.job.finished and e.fs.read("/art/video.mp4") == "encoded video")
  assert(not e.fs.exists(ex.job.root) and #r.frames == 3)
end)
test("cancel during preparation cleans only private task", function()
  local e, ex, r = exporterFixture()
  ex.job.phase = "preparing" ex:cancel()
  assert(ex.job.phase == "cancelled" and not e.fs.exists(ex.job.root))
  assert(e.fs.exists(r.manifest))
end)
test("missing encoder reports error and keeps source", function()
  local e, ex, r = exporterFixture()
  e.fs.write(e.fs.join(ex.job.root, "probe.log"), "not found")
  e.fs.write(e.fs.join(ex.job.root, "status"), "failed") ex:tick()
  assert(ex.job.phase == "failed" and ex.job.message:find("not found"))
  assert(e.fs.exists(r.manifest) and not e.fs.exists(ex.job.root))
end)
test("preparation failure cleans private files and preserves the existing output", function()
  local e, ex = exporterFixture()
  e.fs.write("/art/video.mp4", "existing video")
  ex.normalize = function() error("corrupt PNG") end
  e.fs.write(e.fs.join(ex.job.root, "status"), "ready")
  local ok, err = pcall(ex.tick, ex) assert(not ok)
  ex:abort(err)
  assert(ex.job.phase == "failed" and not e.fs.exists(ex.job.root))
  assert(e.fs.read("/art/video.mp4") == "existing video")
end)
test("failed publication rolls back the previously existing video", function()
  local e, ex = exporterFixture()
  ex.job.options.overwrite = true
  e.fs.write("/art/video.mp4", "existing video")
  e.fs.write(e.fs.join(ex.job.root, "status"), "ready") ex:tick()
  e.fs.write(e.fs.join(ex.job.root, "encoded.mp4"), "new video")
  e.fs.write(e.fs.join(ex.job.root, "status"), "done")
  local rename = e.fs.rename
  e.fs.rename = function(a, b)
    if a:match("encoded%.mp4$") then error("publication failed") end
    return rename(a, b)
  end
  local ok, err = pcall(ex.tick, ex) assert(not ok) ex:abort(err)
  assert(ex.job.phase == "failed" and e.fs.read("/art/video.mp4") == "existing video")
end)
test("failed rollback retains the original backup for recovery", function()
  local e, ex = exporterFixture()
  ex.job.options.overwrite = true
  e.fs.write("/art/video.mp4", "existing video")
  e.fs.write(e.fs.join(ex.job.root, "status"), "ready") ex:tick()
  e.fs.write(e.fs.join(ex.job.root, "encoded.mp4"), "new video")
  e.fs.write(e.fs.join(ex.job.root, "status"), "done")
  local rename = e.fs.rename
  e.fs.rename = function(a, b) if b == "/art/video.mp4" then error("destination unavailable") end return rename(a, b) end
  local ok, err = pcall(ex.tick, ex) assert(not ok) ex:abort(err)
  assert(ex.job.phase == "failed" and ex.job.cleanupPending)
  assert(e.fs.read(e.fs.join(ex.job.root, "previous.mp4")) == "existing video")
end)
print(("%d timelapse tests passed"):format(passed))
