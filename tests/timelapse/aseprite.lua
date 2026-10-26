-- 使用真实 Aseprite 图像和事件，仅向指定的工作目录写入测试产物。
local script = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local repo = script:match("^(.*)/tests/timelapse/aseprite.lua$") or "."
local base = app.params["output"] or app.fs.joinPath(repo, ".work", "timelapse-real-" .. tostring(os.time()) .. "-" .. math.random(999999))
app.fs.makeAllDirectories(base)
local resultFile = app.fs.joinPath(base, "result.json")
local function run()
  if Version(tostring(app.version):match("^[%d%.]+")) < Version("1.3.18.6") then
    return { ok = true, skipped = "extension requires 1.3.18.6+" }
  end
  local entry = dofile(repo .. "/extensions/timelapse-recorder/main.lua")
  local fs = dofile(repo .. "/extensions/timelapse-recorder/lib/fs.lua")
  local plugin = { preferences = {} }
  local rt = entry.newRuntime(plugin)
  local sprite = Sprite(9, 7, ColorMode.RGB)
  local source = app.fs.joinPath(base, "画作 % & ' $(literal).aseprite")
  sprite:saveAs(source)
  app.sprite = sprite
  rt:enable()
  local session = assert(rt:current())
  assert(not sprite.isModified and #sprite.frames == 1 and #sprite.layers == 1)
  app.useTool{ tool = "pencil", color = Color{r = 255, g = 0, b = 0}, points = { Point(6, 4) } }
  rt.recorder:flush(session)
  local painted = entry.render(sprite)
  assert(painted:getPixel(6, 4) == app.pixelColor.rgba(255, 0, 0, 255))
  local last = session.record.frames[#session.record.frames]
  assert(Image{fromFile = fs.join(session.record.root, last.file)}:isEqual(painted), "stroke event not captured")
  local before = #session.record.frames
  rt.recorder:capture(session) rt.recorder:flush(session)
  assert(#session.record.frames == before, "unchanged canvas recorded")
  app.undo() rt.recorder:flush(session)
  assert(entry.render(sprite):isEmpty(), "capture polluted undo history")
  app.redo() rt.recorder:flush(session)
  assert(entry.render(sprite):isEqual(painted))
  assert(#session.record.frames == before + 2, "undo/redo events missing")
  sprite.layers[1].isVisible = false rt.recorder:flush(session)
  assert(Image{fromFile = fs.join(session.record.root, session.record.frames[#session.record.frames].file)}:isEmpty())
  sprite.layers[1].isVisible = true rt.recorder:flush(session)
  app.useTool{ tool = "eraser", points = { Point(6, 4) } } rt.recorder:flush(session)
  assert(entry.render(sprite):isEmpty())
  app.useTool{ tool = "paint_bucket", color = Color{r = 20, g = 80, b = 120}, points = { Point(0, 0) } }
  rt.recorder:flush(session)
  app.transaction("move", function() sprite.cels[1].position = Point(1, 1) end)
  rt.recorder:flush(session)
  sprite:resize(11, 9) rt.recorder:flush(session)
  assert(session.record.frames[#session.record.frames].width == 11)
  entry.normalize({file = fs.join(session.record.root, last.file)}, fs.join(base, "normalized.png"), 11, 9, "ffffff")
  local normalized = Image{ fromFile = fs.join(base, "normalized.png") }
  assert(normalized:getPixel(0, 0) == app.pixelColor.rgba(255, 255, 255, 255))
  assert(normalized:getPixel(7, 5) == app.pixelColor.rgba(255, 0, 0, 255), "centering or alpha incorrect")
  rt.recorder:pause(session)
  local pausedCount = #session.record.frames
  app.useTool{ tool = "pencil", color = Color{r = 0, g = 255, b = 0}, points = { Point(3, 3) } }
  assert(#session.queue == 0)
  rt.recorder:resume(session) rt.recorder:flush(session)
  assert(#session.record.frames == pausedCount + 1)
  sprite:saveAs(app.fs.joinPath(base, "副本.aseprite"))
  assert(session.record.source == sprite.filename and #session.record.frames > 1)
  local copiedRoot = session.record.root
  local stressStart = #session.record.frames
  for i = 1, 1000 do
    app.useTool{tool = "pencil", color = Color{r = i % 256, g = math.floor(i / 256), b = 200}, points = {Point(0, 0)}}
    assert(#session.queue <= 8 and session.bytes <= rt.recorder.maxBytes)
  end
  rt.recorder:flush(session)
  assert(#session.record.frames == stressStart + 1000, "1000 real edits lost a frame")
  rt:shutdown() sprite:close()
  local reopened = app.open(app.fs.joinPath(base, "副本.aseprite"))
  rt = entry.newRuntime(plugin) rt:scan()
  session = assert(rt:current())
  assert(session.record.root == copiedRoot and session.record.state == "recording")
  for _, mode in ipairs{ColorMode.GRAY, ColorMode.INDEXED} do
    local other = Sprite(3, 3, mode)
    app.sprite = other
    app.useTool{ tool = "pencil", color = mode == ColorMode.INDEXED and Color{index = 1} or Color{gray = 120, alpha = 255},
      points = {Point(1, 1)} }
    local rendered = entry.render(other)
    assert(rendered.colorMode == ColorMode.RGB and not rendered:isEmpty(), "color mode render failed")
    assert(app.pixelColor.rgbaA(rendered:getPixel(1, 1)) == 255)
    other:close()
  end
  app.sprite = reopened
  if app.params["ffmpeg"] then
    rt.exporter:start(session.record, fs.join(base, "输出 % & ' $(literal).mp4"), {
      fps = 24, scale = 2, hold = 0.5, background = "ffffff", ffmpeg = app.params["ffmpeg"], overwrite = false })
    local deadline, edited = os.time() + 40, false
    repeat
      rt.exporter:tick()
      if rt.exporter.job.phase == "encoding" and not edited then
        app.useTool{tool = "pencil", color = Color{r = 255, g = 0, b = 255}, points = {Point(0, 0)}}
        rt.recorder:flush(session) edited = true
      end
      assert(os.time() < deadline, "background export timed out")
    until rt.exporter.job.finished
    assert(rt.exporter.job.phase == "done", rt.exporter.job.message)
    assert(edited, "recording did not continue during encoding")
  end
  reopened:newFrame() rt.recorder:capture(session)
  assert(session.record.state == "paused", "animation must pause")
  rt:shutdown() reopened:close()
  return { ok = true, output = base, frames = #session.record.frames }
end
local ok, result = pcall(run)
if not ok then result = {ok = false, error = tostring(result)} end
local file = assert(io.open(resultFile, "w")) file:write(json.encode(result)) file:close()
assert(ok, result.error)
print("PASS real Aseprite integration: " .. resultFile)
