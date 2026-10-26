-- Aseprite 文件系统适配层，传入的路径均按字面值处理。
local M = {}
M.join = app.fs.joinPath
M.exists = function(p) return app.fs.isFile(p) or app.fs.isDirectory(p) end
M.isFile = app.fs.isFile
M.isDirectory = app.fs.isDirectory
M.list = app.fs.listFiles
M.size = app.fs.fileSize
M.sidecar = function(p) return app.fs.filePathAndTitle(p) .. ".timelapse" end
M.key = function(p)
  p = app.fs.normalizePath(p):gsub("\\", "/")
  return app.os.windows and p:lower() or p
end

local function checked(ok, err) assert(ok, err or "File operation failed") return ok end
function M.mkdir(p) if not app.fs.isDirectory(p) then checked(app.fs.makeDirectory(p), p) end end
function M.read(p)
  local f = assert(io.open(p, "rb"))
  local data, err = f:read("a")
  f:close()
  return assert(data, err)
end
local function write(p, data, mode)
  local f = assert(io.open(p, mode))
  local ok, err = f:write(data)
  local closed, closeErr = f:close()
  checked(ok, err) checked(closed, closeErr)
end
function M.write(p, data) write(p, data, "wb") end
function M.append(p, data) write(p, data, "ab") end
function M.remove(p) if app.fs.isFile(p) then checked(os.remove(p)) end end
function M.rmdir(p) checked(app.fs.removeDirectory(p)) end
function M.rename(a, b) assert(not M.exists(b), "Destination already exists: " .. b) checked(os.rename(a, b)) end
function M.copy(a, b)
  assert(not M.exists(b), "Destination already exists: " .. b)
  local input = assert(io.open(a, "rb"))
  local output, err = io.open(b, "wb")
  if not output then input:close() error(err) end
  local ok, problem = pcall(function()
    while true do
      local chunk, readError = input:read(128 * 1024)
      assert(not readError, readError)
      if not chunk then break end
      checked(output:write(chunk))
    end
  end)
  input:close()
  local closed, closeError = output:close()
  assert(ok, problem) checked(closed, closeError)
end

-- Windows 的 rename 无法替换已有文件，替换时保留可恢复的备份。
-- 启动读取时，如有需要则回退到备份文件。
function M.replace(p, data)
  M.write(p .. ".next", data)
  M.remove(p .. ".bak")
  if M.exists(p) then M.rename(p, p .. ".bak") end
  local ok, err = pcall(M.rename, p .. ".next", p)
  if not ok then
    if not M.exists(p) and M.exists(p .. ".bak") then pcall(M.rename, p .. ".bak", p) end
    error(err)
  end
end

function M.pngInfo(p)
  local f = assert(io.open(p, "rb"))
  local head = f:read(24)
  f:seek("end", -12)
  local tail = f:read(12)
  f:close()
  if not head or #head ~= 24 or head:sub(1, 8) ~= "\137PNG\r\n\26\n"
      or head:sub(13, 16) ~= "IHDR" or not tail or tail:sub(5, 8) ~= "IEND" then return nil end
  local w, h = string.unpack(">I4I4", head, 17)
  if w > 0 and h > 0 then return w, h end
end
return M
