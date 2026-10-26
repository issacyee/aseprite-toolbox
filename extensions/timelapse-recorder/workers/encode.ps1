# 以 UTF-8 BOM 保存，确保 Windows PowerShell 5.1 正确读取中文注释。
param([Parameter(Mandatory = $true)][string]$JobDir)
$ErrorActionPreference = 'Stop'
function Write-Status([string]$Value) {
    [IO.File]::WriteAllText((Join-Path $JobDir 'status.next'), $Value)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            Move-Item -LiteralPath (Join-Path $JobDir 'status.next') -Destination (Join-Path $JobDir 'status') -Force
            return
        } catch { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 25 }
    }
}
function Read-Setting([string]$Name) {
    [IO.File]::ReadAllText((Join-Path $JobDir "$Name.txt"), [Text.Encoding]::UTF8).TrimEnd("`r", "`n")
}
# 按 Windows CRT 规则引用进程参数，不经过 cmd 插值。
function Quote-Argument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
function Start-Encoder([string[]]$Arguments, [string]$Prefix) {
    $argumentString = (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $process = Start-Process -FilePath $script:Encoder -ArgumentList $argumentString -PassThru -WindowStyle Hidden -WorkingDirectory $JobDir `
        -RedirectStandardOutput (Join-Path $JobDir "$Prefix.log") `
        -RedirectStandardError (Join-Path $JobDir "$Prefix-error.log")
    # 进程退出前先缓存句柄，避免 PS 5.1 丢失 ExitCode。
    $null = $process.Handle
    return $process
}
$child = $null
try {
    Write-Status 'probing'
    $script:Encoder = Read-Setting 'ffmpeg'
    $mode = Read-Setting 'mode'
    foreach ($probe in @(@('-version'), @('-hide_banner', '-encoders'))) {
        $child = Start-Encoder -Arguments $probe -Prefix 'probe'
        while (-not $child.WaitForExit(100)) {
            if (Test-Path -LiteralPath (Join-Path $JobDir 'cancel')) {
                $child.Kill(); $child.WaitForExit(); Write-Status 'cancelled'; exit 0
            }
        }
        if ($child.ExitCode -ne 0) { throw 'FFmpeg probe failed.' }
    }
    if ([IO.File]::ReadAllText((Join-Path $JobDir 'probe.log')) -notmatch '\blibx264\b') {
        throw 'FFmpeg needs the libx264 encoder.'
    }
    if (Test-Path -LiteralPath (Join-Path $JobDir 'cancel')) { Write-Status 'cancelled'; exit 0 }
    if ($mode -eq 'probe') { Write-Status 'ready'; exit 0 }
    $fps = Read-Setting 'fps'
    $scale = Read-Setting 'scale'
    $hold = Read-Setting 'hold'
    $background = Read-Setting 'background'
    $filter = "scale=iw*$($scale):ih*$($scale):flags=neighbor,pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0:color=0x$($background),tpad=stop_mode=clone:stop_duration=$hold"
    $encodeArgs = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-framerate', $fps,
        '-start_number', '1', '-i', 'frame-%08d.png', '-vf', $filter,
        '-an', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart', '-progress', (Join-Path $JobDir 'progress.txt'), '-nostats',
        (Join-Path $JobDir 'encoded.mp4'))
    Write-Status 'encoding'
    $child = Start-Encoder -Arguments $encodeArgs -Prefix 'encode'
    while (-not $child.WaitForExit(100)) {
        if (Test-Path -LiteralPath (Join-Path $JobDir 'cancel')) {
            $child.Kill(); $child.WaitForExit(); Write-Status 'cancelled'; exit 0
        }
    }
    if (Test-Path -LiteralPath (Join-Path $JobDir 'cancel')) { Write-Status 'cancelled' }
    elseif ($child.ExitCode -eq 0) { Write-Status 'done' }
    else { throw "FFmpeg exited with code $($child.ExitCode)." }
} catch {
    if ($null -ne $child -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
    [IO.File]::WriteAllText((Join-Path $JobDir 'worker-error.log'), $_.ToString(), [Text.Encoding]::UTF8)
    Write-Status 'failed'
    exit 1
}
