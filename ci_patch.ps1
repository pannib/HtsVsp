# CI patch for HtsVsp. Idempotent and self-verifying. Run in repo root before build.
# Auto-detects the file's newline style (CI windows checkout may be CRLF or LF).
#
# Fixes:
#  A) ConfigureService never created ServiceSocket -> server bind failed.
#  B) CleanupNetwork sets TerminateThread=true and nothing resets it, so after any
#     re-configuration the freshly created Client/Service threads exit immediately
#     (while(!TerminateThread)), breaking the TCP->COM receive path.
$ErrorActionPreference = "Stop"
$f = "ComPort/network.cpp"
$text = [IO.File]::ReadAllText($f)
$orig = $text

$nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
Write-Host "newline style: $(if ($nl -eq "`r`n") { 'CRLF' } else { 'LF' })"

# A1) Insert WinSockCreate(&ServiceSocket) before the service sockaddr_in block.
$markerA = "    CleanupNetwork(deviceContext);$nl$nl    sockaddr_in service;"
$injectA = "    CleanupNetwork(deviceContext);$nl$nl    int result = WinSockCreate(&deviceContext->ServiceSocket);$nl    if (result != NO_ERROR) {$nl        Trace(TRACE_LEVEL_ERROR, `"ServiceSocket create error: %#x`", result);$nl        goto cleanup;$nl    }$nl$nl    sockaddr_in service;"
if ($text.Contains($markerA)) { $text = $text.Replace($markerA, $injectA); Write-Host "A1: inserted ServiceSocket creation" }
elseif ($text.Contains("WinSockCreate(&deviceContext->ServiceSocket)")) { Write-Host "A1: already applied" }
else { throw "A1 marker not found" }

# A2) Injected block declares 'int result'; change the later bind declaration to assignment.
$oldBind = "    int result = bind(deviceContext->ServiceSocket,"
$newBind = "    result = bind(deviceContext->ServiceSocket,"
if ($text.Contains($oldBind)) { $text = $text.Replace($oldBind, $newBind); Write-Host "A2: bind declaration -> assignment" }
elseif ($text.Contains($newBind)) { Write-Host "A2: already applied" }
else { throw "A2 bind marker not found" }

# B1) Reset TerminateThread in ConfigureClient (anchored on the addrinfo block).
$markerC = "    CleanupNetwork(deviceContext);$nl$nl    struct addrinfo hints = { };"
$injectC = "    CleanupNetwork(deviceContext);$nl$nl    deviceContext->TerminateThread = false;$nl$nl    struct addrinfo hints = { };"
if ($text.Contains($markerC)) { $text = $text.Replace($markerC, $injectC); Write-Host "B1: reset TerminateThread (client)" }
elseif ($text.Contains("TerminateThread = false;$nl$nl    struct addrinfo hints")) { Write-Host "B1: already applied" }
else { throw "B1 client marker not found" }

# B2) Reset TerminateThread in ConfigureService (anchored on the A1-injected ServiceSocket create).
$markerS = "    CleanupNetwork(deviceContext);$nl$nl    int result = WinSockCreate(&deviceContext->ServiceSocket);"
$injectS = "    CleanupNetwork(deviceContext);$nl$nl    deviceContext->TerminateThread = false;$nl$nl    int result = WinSockCreate(&deviceContext->ServiceSocket);"
if ($text.Contains($markerS)) { $text = $text.Replace($markerS, $injectS); Write-Host "B2: reset TerminateThread (service)" }
elseif ($text.Contains("TerminateThread = false;$nl$nl    int result = WinSockCreate(&deviceContext->ServiceSocket)")) { Write-Host "B2: already applied" }
else { throw "B2 service marker not found" }

if ($text -ne $orig) { [IO.File]::WriteAllText($f, $text); Write-Host "network.cpp patched and saved" }
else { Write-Host "no changes needed (already patched)" }

# Verify.
$final = [IO.File]::ReadAllText($f)
if (-not $final.Contains("WinSockCreate(&deviceContext->ServiceSocket)")) { throw "verify A1 missing" }
if (-not $final.Contains($newBind)) { throw "verify A2 missing" }
$resetCount = ([regex]::Matches($final, [regex]::Escape("deviceContext->TerminateThread = false;"))).Count
if ($resetCount -lt 2) { throw "verify B: expected >=2 TerminateThread resets, got $resetCount" }
Write-Host "patch verification OK (TerminateThread resets=$resetCount)"
