local M = {}
function M.posixQuote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function psQuote(value) return "'" .. value:gsub("'", "''") .. "'" end
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(bytes)
  local result = {}
  for i = 1, #bytes, 3 do
    local a, b, c = bytes:byte(i, i + 2)
    local value = a * 65536 + (b or 0) * 256 + (c or 0)
    result[#result + 1] = alphabet:sub((value >> 18) + 1, (value >> 18) + 1)
      .. alphabet:sub(((value >> 12) & 63) + 1, ((value >> 12) & 63) + 1)
      .. (b and alphabet:sub(((value >> 6) & 63) + 1, ((value >> 6) & 63) + 1) or "=")
      .. (c and alphabet:sub((value & 63) + 1, (value & 63) + 1) or "=")
  end
  return table.concat(result)
end
function M.encodedCommand(script)
  local units = {}
  for _, code in utf8.codes(script) do
    if code > 65535 then
      code = code - 65536
      units[#units + 1] = string.pack("<I2I2", 0xD800 + (code >> 10), 0xDC00 + (code & 1023))
    else units[#units + 1] = string.pack("<I2", code) end
  end
  return base64(table.concat(units))
end
function M.command(windows, worker, root)
  if windows then
    local child = M.encodedCommand("& " .. psQuote(worker) .. " -JobDir " .. psQuote(root))
    local bootstrap = "Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden "
      .. "-ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " .. child .. "'"
    return "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " .. M.encodedCommand(bootstrap)
  end
  return "sh " .. M.posixQuote(worker) .. " " .. M.posixQuote(root)
    .. " >" .. M.posixQuote(root .. "/launcher.log") .. " 2>&1 &"
end
function M.launch(windows, worker, root)
  local ok, kind, code = os.execute(M.command(windows, worker, root))
  assert(ok == true or ok == 0, "Cannot start the export worker: " .. tostring(kind) .. "/" .. tostring(code))
end
return M
