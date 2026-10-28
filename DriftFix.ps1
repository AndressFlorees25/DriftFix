# DriftFix: sirve la página en localhost y guarda la zona muerta en el perfil de DS4Windows.
$ErrorActionPreference = 'Stop'
$Port = 8765
$Root = $PSScriptRoot
$Ds4Dir = Join-Path $env:USERPROFILE 'Downloads\ds4windows-3-3-3\DS4Windows'
$Ds4Exe = Join-Path $Ds4Dir 'DS4Windows.exe'
$Fields = 'LSDeadZone', 'RSDeadZone', 'LSAntiDeadZone', 'RSAntiDeadZone'

function Get-ProfilePath {
    $name = 'Default'
    $profiles = Join-Path $Ds4Dir 'Profiles.xml'
    if (Test-Path $profiles) {
        $m = [regex]::Match((Get-Content $profiles -Raw), '<Controller1>([^<]+)</Controller1>')
        if ($m.Success) { $name = $m.Groups[1].Value }
    }
    Join-Path $Ds4Dir "Profiles\$name.xml"
}

function Get-Config {
    $path = Get-ProfilePath
    $xml = Get-Content $path -Raw
    $cfg = [ordered]@{ profile = [IO.Path]::GetFileNameWithoutExtension($path) }
    foreach ($f in $Fields) {
        $m = [regex]::Match($xml, "<$f>(\d+)</$f>")
        $cfg[$f] = if ($m.Success) { [int]$m.Groups[1].Value } else { $null }
    }
    $cfg.backups = @(Get-ChildItem (Split-Path $path) -Filter "$($cfg.profile).xml.driftfix-*.bak" -ErrorAction SilentlyContinue).Count
    $cfg
}

# DS4Windows puede reescribir el perfil al cerrarse, así que se cierra antes de editar y se vuelve a abrir después.
function Invoke-WithDs4Closed([scriptblock]$Action) {
    $proc = Get-Process DS4Windows -ErrorAction SilentlyContinue
    if ($proc) { $proc | Stop-Process -Force; $proc | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }
    & $Action
    if ($proc -and (Test-Path $Ds4Exe)) { Start-Process $Ds4Exe -WorkingDirectory $Ds4Dir }
    [bool]$proc
}

function Set-Config($values) {
    $path = Get-ProfilePath
    $restarted = Invoke-WithDs4Closed {
        Copy-Item $path "$path.driftfix-$(Get-Date -Format yyyyMMdd-HHmmss).bak"
        $xml = Get-Content $path -Raw
        foreach ($f in $Fields) {
            if ($null -eq $values.$f) { continue }
            $max = if ($f -like '*Anti*') { 100 } else { 127 }
            $v = [math]::Max(0, [math]::Min($max, [int]$values.$f))
            $xml = [regex]::Replace($xml, "<$f>\d+</$f>", "<$f>$v</$f>")
        }
        [IO.File]::WriteAllText($path, $xml, (New-Object Text.UTF8Encoding $false))
    }
    @{ ok = $true; restarted = $restarted; config = Get-Config }
}

function Restore-Config {
    $path = Get-ProfilePath
    $first = Get-ChildItem (Split-Path $path) -Filter "$([IO.Path]::GetFileName($path)).driftfix-*.bak" |
        Sort-Object Name | Select-Object -First 1
    if (-not $first) { return @{ ok = $false; error = 'No hay respaldo para restaurar.' } }
    $restarted = Invoke-WithDs4Closed { Copy-Item $first.FullName $path -Force }
    @{ ok = $true; restarted = $restarted; config = Get-Config }
}

function Send($ctx, $status, $type, [byte[]]$body) {
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $type
    $ctx.Response.OutputStream.Write($body, 0, $body.Length)
    $ctx.Response.Close()
}

function Send-Json($ctx, $obj) {
    Send $ctx 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 4)))
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "DriftFix abierto en http://localhost:$Port  (cierra esta ventana para salir)"
Start-Process "http://localhost:$Port/"

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        switch ("$($req.HttpMethod) $($req.Url.AbsolutePath)") {
            'GET /' { Send $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $Root 'index.html'))) }
            'GET /config' { Send-Json $ctx (Get-Config) }
            'POST /apply' {
                $body = (New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                Send-Json $ctx (Set-Config ($body | ConvertFrom-Json))
            }
            'POST /restore' { Send-Json $ctx (Restore-Config) }
            default { Send $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('No encontrado')) }
        }
    } catch {
        Send-Json $ctx @{ ok = $false; error = $_.Exception.Message }
    }
}
