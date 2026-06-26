# Cursor afterAgentResponse hook — Jarvis-style TTS via edge-tts
param(
    [string]$Worker,
    [string]$PayloadPath,
    [string]$Debounce
)

$ErrorActionPreference = 'SilentlyContinue'

# ── Jarvis voice profile (edit to taste) ─────────────────────────────────────
$Voice        = 'en-GB-RyanNeural'
$Rate         = '-10%'
$Pitch        = '+0Hz'
$Volume       = '+0%'
$MaxChars     = 500
$MaxSentences = 3
$MinChars     = 8
$DebounceSec  = 2.5
$PlaybackMode = 'auto'   # auto | soundplayer | ffplay | default
$StateFile    = Join-Path $PSScriptRoot '.tts-state.json'
$PendingFile  = Join-Path $PSScriptRoot '.tts-pending.json'
$DebounceLock = Join-Path $PSScriptRoot '.tts-debounce.lock'
$LastSpoken   = Join-Path $PSScriptRoot '.tts-last-spoken.json'
$LogFile      = Join-Path $PSScriptRoot 'tts.log'

function Write-TtsLog {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" | Add-Content -Path $LogFile -Encoding UTF8
}

function Write-JsonFile {
    param([string]$Path, [object]$Object)
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Compress), $utf8)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Read-HookStdin {
    $stdin = [Console]::OpenStandardInput()
    $ms = New-Object IO.MemoryStream
    $stdin.CopyTo($ms)
    $bytes = $ms.ToArray()
    if ($bytes.Length -eq 0) { return '' }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }

    $utf8 = New-Object Text.UTF8Encoding $false
    return $utf8.GetString($bytes).Trim()
}

function Parse-HookPayload {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    if ($Raw[0] -eq [char]0xFEFF) { $Raw = $Raw.Substring(1) }

    try {
        return ($Raw | ConvertFrom-Json)
    } catch {
        Write-TtsLog "WARN PowerShell JSON parse failed: $($_.Exception.Message)"
    }

    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        $tmp = Join-Path $env:TEMP ("cursor-hook-json-{0}.json" -f [guid]::NewGuid().ToString('N'))
        try {
            $utf8 = New-Object Text.UTF8Encoding $false
            [IO.File]::WriteAllText($tmp, $Raw, $utf8)
            $text = & $py.Source -c "import json,sys; print(json.load(open(sys.argv[1],encoding='utf-8')).get('text',''))" $tmp 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
                return [PSCustomObject]@{ text = $text }
            }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    Write-TtsLog "ERROR invalid hook JSON len=$($Raw.Length)"
    return $null
}

function Resolve-EdgeTts {
    if ($script:CachedEdgeTts -and (Test-Path $script:CachedEdgeTts)) { return $script:CachedEdgeTts }

    $cmd = Get-Command edge-tts -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:CachedEdgeTts = $cmd.Source
        return $script:CachedEdgeTts
    }

    $candidates = @(
        "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\edge-tts.exe",
        "$env:USERPROFILE\AppData\Local\hermes\hermes-agent\venv\Scripts\edge-tts.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Python\Python311\Scripts\edge-tts.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Python\Python312\Scripts\edge-tts.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            $script:CachedEdgeTts = $path
            return $script:CachedEdgeTts
        }
    }
    return $null
}

function Resolve-Ffplay {
    if ($script:CachedFfplay -and (Test-Path $script:CachedFfplay)) { return $script:CachedFfplay }

    $cmd = Get-Command ffplay -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:CachedFfplay = $cmd.Source
        return $script:CachedFfplay
    }

    $winget = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $winget) {
        $found = Get-ChildItem -Path $winget -Filter 'ffplay.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            $script:CachedFfplay = $found.FullName
            return $script:CachedFfplay
        }
    }
    return $null
}

function Resolve-Ffmpeg {
    if ($script:CachedFfmpeg -and (Test-Path $script:CachedFfmpeg)) { return $script:CachedFfmpeg }

    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:CachedFfmpeg = $cmd.Source
        return $script:CachedFfmpeg
    }

    $ffplay = Resolve-Ffplay
    if ($ffplay) {
        $ffmpeg = Join-Path (Split-Path $ffplay -Parent) 'ffmpeg.exe'
        if (Test-Path $ffmpeg) {
            $script:CachedFfmpeg = $ffmpeg
            return $script:CachedFfmpeg
        }
    }

    $winget = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $winget) {
        $found = Get-ChildItem -Path $winget -Filter 'ffmpeg.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            $script:CachedFfmpeg = $found.FullName
            return $script:CachedFfmpeg
        }
    }
    return $null
}

function Stop-CurrentPlayback {
    if (Test-Path $StateFile) {
        try {
            $state = Read-JsonFile $StateFile
            if ($state.workerPid -and $state.workerPid -ne $PID) {
                Stop-Process -Id $state.workerPid -Force -ErrorAction SilentlyContinue
            }
            if ($state.audioFile -and (Test-Path $state.audioFile)) {
                Remove-Item $state.audioFile -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }
    Get-Process ffplay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Write-PlaybackState {
    param([int]$WorkerPid, [string]$AudioFile = '')
    Write-JsonFile -Path $StateFile -Object @{
        workerPid = $WorkerPid
        audioFile = $AudioFile
        ts        = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function ConvertTo-SpeechText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $t = $Text
    $t = $t -replace '```[\s\S]*?```', ' '
    $t = $t -replace '`[^`]+`', ' '
    $t = $t -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
    $t = $t -replace '[#*_~>|]', ' '
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()

    $sentences = [regex]::Split($t, '(?<=[.!?])\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($sentences.Count -gt $MaxSentences) {
        $t = (($sentences | Select-Object -First $MaxSentences) -join ' ').Trim()
        if ($t -notmatch '[.!?]$') { $t += '.' }
        $t += ' More detail in the chat.'
    }

    if ($t.Length -gt $MaxChars) {
        $t = $t.Substring(0, $MaxChars).Trim()
        if ($t -notmatch '[.!?]$') { $t += '.' }
        $t += ' Response truncated for speech.'
    }

    return $t
}

function Get-TextHash {
    param([string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
    } finally {
        $sha.Dispose()
    }
}

function Test-ShouldSpeak {
    param([string]$SpeechText)

    $hash = Get-TextHash $SpeechText
    $last = Read-JsonFile $LastSpoken
    if ($last -and $last.hash -eq $hash) {
        Write-TtsLog "SKIP duplicate speech hash=$($hash.Substring(0,8))"
        return $false
    }
    return $true
}

function Mark-Spoken {
    param([string]$SpeechText)
    Write-JsonFile -Path $LastSpoken -Object @{
        hash = (Get-TextHash $SpeechText)
        ts   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
}

function Play-ViaSoundPlayer {
    param([string]$Path)

    $FfmpegBin = Resolve-Ffmpeg
    if (-not $FfmpegBin) { return $false }

    $wavFile = [IO.Path]::ChangeExtension($Path, '.wav')
    try {
        & $FfmpegBin -y -loglevel quiet -i $Path -ar 44100 -ac 2 $wavFile
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $wavFile)) { return $false }

        Write-TtsLog 'PLAYBACK soundplayer'
        $player = New-Object System.Media.SoundPlayer $wavFile
        $player.PlaySync()
        return $true
    } finally {
        if ($wavFile -and (Test-Path $wavFile)) {
            Remove-Item $wavFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Play-ViaFfplay {
    param([string]$Path)

    $FfplayBin = Resolve-Ffplay
    if (-not $FfplayBin) { return $false }

    Write-TtsLog 'PLAYBACK ffplay'
    & $FfplayBin -nodisp -autoexit -loglevel quiet $Path
    return $true
}

function Play-ViaDefaultApp {
    param([string]$Path)

    Write-TtsLog 'PLAYBACK default'
    Start-Process -FilePath $Path -WindowStyle Hidden
    return $true
}

function Play-AudioFile {
    param([string]$Path)

    switch ($PlaybackMode) {
        'soundplayer' {
            if (-not (Play-ViaSoundPlayer -Path $Path)) {
                Write-TtsLog 'ERROR soundplayer unavailable (ffmpeg required)'
            }
        }
        'ffplay' {
            if (-not (Play-ViaFfplay -Path $Path)) {
                Write-TtsLog 'WARN ffplay unavailable, using default app'
                Play-ViaDefaultApp -Path $Path
            }
        }
        'default' {
            Play-ViaDefaultApp -Path $Path
        }
        default {
            if (Play-ViaSoundPlayer -Path $Path) { return }
            if (Play-ViaFfplay -Path $Path) { return }
            Write-TtsLog 'WARN no playback backend, using default app'
            Play-ViaDefaultApp -Path $Path
        }
    }
}

function Invoke-TtsWorker {
    param([string]$SpeechText)

    if (-not (Test-ShouldSpeak $SpeechText)) { exit 0 }

    $EdgeTtsBin = Resolve-EdgeTts
    if (-not $EdgeTtsBin) {
        Write-TtsLog 'ERROR edge-tts not found'
        exit 1
    }

    Stop-CurrentPlayback

    $textFile  = Join-Path $env:TEMP ("cursor-jarvis-text-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $audioFile = Join-Path $env:TEMP ("cursor-jarvis-{0}.mp3" -f [guid]::NewGuid().ToString('N'))
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($textFile, $SpeechText, $utf8)

    & $EdgeTtsBin @('-v', $Voice, "--rate=$Rate", "--pitch=$Pitch", "--volume=$Volume", '-f', $textFile, '--write-media', $audioFile)
    Remove-Item $textFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $audioFile)) {
        Write-TtsLog "ERROR edge-tts failed exit=$LASTEXITCODE chars=$($SpeechText.Length)"
        Remove-Item $audioFile -Force -ErrorAction SilentlyContinue
        exit 1
    }

    Mark-Spoken $SpeechText
    Write-PlaybackState -WorkerPid $PID -AudioFile $audioFile
    Write-TtsLog "PLAYING pid=$PID chars=$($SpeechText.Length)"

    Play-AudioFile -Path $audioFile

    Remove-Item $audioFile -Force -ErrorAction SilentlyContinue
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-TtsLog 'DONE'
    exit 0
}

function Start-DebouncerIfNeeded {
    if (Test-Path $DebounceLock) {
        try {
            $lock = Read-JsonFile $DebounceLock
            if ($lock -and $lock.pid) {
                $proc = Get-Process -Id $lock.pid -ErrorAction SilentlyContinue
                if ($proc) { return }
            }
        } catch {}
    }

    $debouncer = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $PSCommandPath, '-Debounce', '1'
    ) -PassThru -WindowStyle Hidden

    Write-JsonFile -Path $DebounceLock -Object @{ pid = $debouncer.Id; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
}

function Invoke-DebounceWorker {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(90)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $DebounceSec

        $pending = Read-JsonFile $PendingFile
        if (-not $pending -or [string]::IsNullOrWhiteSpace($pending.speech)) {
            break
        }

        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int]$pending.ts
        if ($age -lt $DebounceSec) { continue }

        $speech = [string]$pending.speech
        Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue
        Remove-Item $DebounceLock -Force -ErrorAction SilentlyContinue

        Write-TtsLog "DEBOUNCE speak chars=$($speech.Length)"
        Invoke-TtsWorker -SpeechText $speech
        break
    }

    Remove-Item $DebounceLock -Force -ErrorAction SilentlyContinue
    exit 0
}

$ValidPlaybackModes = @('auto', 'soundplayer', 'ffplay', 'default')
if ($PlaybackMode -notin $ValidPlaybackModes) {
    Write-TtsLog "WARN unknown PlaybackMode '$PlaybackMode', using auto"
    $PlaybackMode = 'auto'
}

if ($Debounce -eq '1') {
    Invoke-DebounceWorker
}

if ($Worker -eq '1' -and $PayloadPath -and (Test-Path $PayloadPath)) {
    try {
        $payload = Read-JsonFile $PayloadPath
        $speech = $payload.speech
        Remove-Item $PayloadPath -Force -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($speech)) { exit 0 }
        Invoke-TtsWorker -SpeechText $speech
    } catch {
        Write-TtsLog "ERROR worker exception: $_"
        exit 1
    }
}

$raw = Read-HookStdin
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$hookData = Parse-HookPayload -Raw $raw
if (-not $hookData) { exit 0 }

$speech = ConvertTo-SpeechText -Text ([string]$hookData.text)
if ([string]::IsNullOrWhiteSpace($speech) -or $speech.Length -lt $MinChars) {
    Write-TtsLog "SKIP short/empty speech len=$($speech.Length)"
    exit 0
}

Write-JsonFile -Path $PendingFile -Object @{
    speech        = $speech
    ts            = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    generation_id = $hookData.generation_id
}

Stop-CurrentPlayback
Start-DebouncerIfNeeded

Write-TtsLog "QUEUED chars=$($speech.Length)"
exit 0
