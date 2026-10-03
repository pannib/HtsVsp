# CI patch: fix HtsVsp server mode (ConfigureService missing ServiceSocket creation).
# Idempotent and self-verifying. Run in repo root before build.
# Auto-detects the file's newline style (CI windows checkout may be CRLF or LF).
$ErrorActionPreference = "Stop"
$f = "ComPort/network.cpp"
$text = [IO.File]::ReadAllText($f)
$orig = $text

# Detect newline style used by this file and preserve it on write.
$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
Write-Host "newline style: $(if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' })"

# 1) Insert WinSockCreate(&ServiceSocket) before the service sockaddr_in block.
$marker = "    CleanupNetwork(deviceContext);$nl$nl    sockaddr_in service;"
$inject = "    CleanupNetwork(deviceContext);$nl$nl    int result = WinSockCreate(&deviceContext->ServiceSocket);$nl    if (result != NO_ERROR) {$nl        Trace(TRACE_LEVEL_ERROR, `"ServiceSocket create error: %#x`", result);$nl        goto cleanup;$nl    }$nl$nl    sockaddr_in service;"
if ($text.Contains($marker)) {
    $text = $text.Replace($marker, $inject)
    Write-Host "patch step1: inserted ServiceSocket creation"
} elseif ($text.Contains("WinSockCreate(&deviceContext->ServiceSocket)")) {
    Write-Host "patch step1: already applied"
} else {
    throw "patch step1 marker not found"
}

# 2) The injected block declares 'int result'; change the later bind declaration to assignment.
$oldBind = "    int result = bind(deviceContext->ServiceSocket,"
$newBind = "    result = bind(deviceContext->ServiceSocket,"
if ($text.Contains($oldBind)) {
    $text = $text.Replace($oldBind, $newBind)
    Write-Host "patch step2: bind declaration -> assignment"
} elseif ($text.Contains($newBind)) {
    Write-Host "patch step2: already applied"
} else {
    throw "patch step2 bind marker not found"
}

if ($text -ne $orig) {
    [IO.File]::WriteAllText($f, $text)
    Write-Host "network.cpp patched and saved"
} else {
    Write-Host "no changes needed (already patched)"
}

# Verify both markers are present in the final file.
$final = [IO.File]::ReadAllText($f)
if (-not $final.Contains("WinSockCreate(&deviceContext->ServiceSocket)")) { throw "verify: creation missing" }
if (-not $final.Contains($newBind)) { throw "verify: bind assignment missing" }
Write-Host "patch verification OK"
