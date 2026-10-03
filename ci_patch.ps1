# CI patch for HtsVsp. Idempotent and self-verifying. Run in repo root before build.
# Auto-detects each file's newline style (windows checkout may be CRLF or LF).
#
# Fixes:
#  A) ConfigureService never created ServiceSocket -> server bind failed.
#  B) CleanupNetwork sets TerminateThread=true and nothing resets it, so after any
#     re-configuration the freshly created worker threads exit immediately.
#  C) Diagnostic counters appended to HTS_VSP_REPORT to trace the receive path.
$ErrorActionPreference = "Stop"

function Detect-NL($p) {
    $t = [IO.File]::ReadAllText($p)
    if ($t.Contains("`r`n")) { return "`r`n" } else { return "`n" }
}
function Patch-File($p, $steps) {
    $text = [IO.File]::ReadAllText($p)
    $orig = $text
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    Write-Host "== $p  newline=$(if ($nl -eq "`r`n") {'CRLF'} else {'LF'})"
    foreach ($s in $steps) {
        $marker  = $s.Marker -replace "`r?`n", [regex]::Escape($nl)
        $marker  = [regex]::Unescape($marker)
        $inject  = $s.Inject -replace "`r?`n", [regex]::Escape($nl)
        $inject  = [regex]::Unescape($inject)
        $already = $s.Already -replace "`r?`n", [regex]::Escape($nl)
        $already = [regex]::Unescape($already)
        if ($text.Contains($marker)) { $text = $text.Replace($marker, $inject); Write-Host "  $($s.Name): applied" }
        elseif ($text.Contains($already)) { Write-Host "  $($s.Name): already applied" }
        else { throw "$($s.Name): marker not found in $p" }
    }
    if ($text -ne $orig) { [IO.File]::WriteAllText($p, $text); Write-Host "  saved" }
    else { Write-Host "  no changes" }
}

# ---------- network.cpp : A, B, and client-loop counter ----------
Patch-File "ComPort/network.cpp" @(
  @{ Name="A1";
     Marker="    CleanupNetwork(deviceContext);`n`n    sockaddr_in service;";
     Inject="    CleanupNetwork(deviceContext);`n`n    int result = WinSockCreate(&deviceContext->ServiceSocket);`n    if (result != NO_ERROR) {`n        Trace(TRACE_LEVEL_ERROR, `"ServiceSocket create error: %#x`", result);`n        goto cleanup;`n    }`n`n    sockaddr_in service;";
     Already="WinSockCreate(&deviceContext->ServiceSocket)" },
  @{ Name="A2";
     Marker="    int result = bind(deviceContext->ServiceSocket,";
     Inject="    result = bind(deviceContext->ServiceSocket,";
     Already="    result = bind(deviceContext->ServiceSocket," },
  @{ Name="B1";
     Marker="    CleanupNetwork(deviceContext);`n`n    struct addrinfo hints = { };";
     Inject="    CleanupNetwork(deviceContext);`n`n    deviceContext->TerminateThread = false;`n`n    struct addrinfo hints = { };";
     Already="TerminateThread = false;`n`n    struct addrinfo hints" },
  @{ Name="B2";
     Marker="    CleanupNetwork(deviceContext);`n`n    int result = WinSockCreate(&deviceContext->ServiceSocket);";
     Inject="    CleanupNetwork(deviceContext);`n`n    deviceContext->TerminateThread = false;`n`n    int result = WinSockCreate(&deviceContext->ServiceSocket);";
     Already="TerminateThread = false;`n`n    int result = WinSockCreate(&deviceContext->ServiceSocket)" },
  @{ Name="C1";
     Marker="    while (!deviceContext->TerminateThread)`n    {`n        NTSTATUS status;";
     Inject="    while (!deviceContext->TerminateThread)`n    {`n        deviceContext->Stats.dbgClientLoop++;`n        NTSTATUS status;";
     Already="Stats.dbgClientLoop++" }
)

# ---------- inc/htsvsp.h : append diagnostic fields ----------
Patch-File "inc/htsvsp.h" @(
  @{ Name="C0";
     Marker="	DWORD   traceLevel;`n	DWORD   waitUnits;`n};";
     Inject="	DWORD   traceLevel;`n	DWORD   waitUnits;`n`n	INT64   dbgIoReadEntered;`n	INT64   dbgForwardOk;`n	INT64   dbgForwardFail;`n	INT64   dbgReadyNotify;`n	INT64   dbgClientLoop;`n	INT64   dbgWaitMaskFwd;`n};";
     Already="dbgWaitMaskFwd" }
)

# ---------- queue.cpp : counters ----------
Patch-File "ComPort/queue.cpp" @(
  @{ Name="C2";
     Marker="    RtlZeroMemory(requestContext, sizeof(*requestContext));`n`n    Trace(TRACE_LEVEL_VERBOSE,`n            `" request:0x%p length: %d`", Request, (int) Length);";
     Inject="    RtlZeroMemory(requestContext, sizeof(*requestContext));`n    queueContext->DeviceContext->Stats.dbgIoReadEntered++;`n`n    Trace(TRACE_LEVEL_VERBOSE,`n            `" request:0x%p length: %d`", Request, (int) Length);";
     Already="Stats.dbgIoReadEntered++" },
  @{ Name="C3";
     Marker="    status = WdfRequestForwardToIoQueue(Request,`n                        queueContext->ReadQueue);`n    if( !NT_SUCCESS(status) ) {";
     Inject="    status = WdfRequestForwardToIoQueue(Request,`n                        queueContext->ReadQueue);`n    if (NT_SUCCESS(status)) { queueContext->DeviceContext->Stats.dbgForwardOk++; }`n    else { queueContext->DeviceContext->Stats.dbgForwardFail++; }`n    if( !NT_SUCCESS(status) ) {";
     Already="Stats.dbgForwardOk++" },
  @{ Name="C4";
     Marker="        status = WdfRequestForwardToIoQueue(`n                            Request,`n                            queueContext->WaitMaskQueue);";
     Inject="        queueContext->DeviceContext->Stats.dbgWaitMaskFwd++;`n        status = WdfRequestForwardToIoQueue(`n                            Request,`n                            queueContext->WaitMaskQueue);";
     Already="Stats.dbgWaitMaskFwd++" }
)

# EvtReadQueueReady counter: that function is near the top of queue.cpp.
$q = "ComPort/queue.cpp"
$qt = [IO.File]::ReadAllText($q)
$qnl = if ($qt.Contains("`r`n")) { "`r`n" } else { "`n" }
$qmarker = "    PQUEUE_CONTEXT queueContext = (PQUEUE_CONTEXT)Context;`n    SetEvent(queueContext->DeviceContext->ReadQueueEvent);"
$qmarker = $qmarker -replace "`n", [regex]::Escape($qnl); $qmarker=[regex]::Unescape($qmarker)
$qinject = "    PQUEUE_CONTEXT queueContext = (PQUEUE_CONTEXT)Context;" + $qnl + "    queueContext->DeviceContext->Stats.dbgReadyNotify++;" + $qnl + "    SetEvent(queueContext->DeviceContext->ReadQueueEvent);"
if ($qt.Contains("Stats.dbgReadyNotify++")) { Write-Host "  C5: already applied" }
elseif ($qt.Contains($qmarker)) { $qt = $qt.Replace($qmarker, $qinject); [IO.File]::WriteAllText($q,$qt); Write-Host "  C5: applied" }
else { throw "C5 EvtReadQueueReady marker not found" }

# ---------- verify ----------
$net = [IO.File]::ReadAllText("ComPort/network.cpp")
if (-not $net.Contains("WinSockCreate(&deviceContext->ServiceSocket)")) { throw "verify A1" }
if (([regex]::Matches($net,[regex]::Escape("TerminateThread = false;"))).Count -lt 2) { throw "verify B" }
$h = [IO.File]::ReadAllText("inc/htsvsp.h")
foreach ($fld in @("dbgIoReadEntered","dbgForwardOk","dbgForwardFail","dbgReadyNotify","dbgClientLoop","dbgWaitMaskFwd")) {
    if (-not $h.Contains($fld)) { throw "verify field $fld" }
}
$qq2 = [IO.File]::ReadAllText($q)
foreach ($c in @("dbgIoReadEntered++","dbgForwardOk++","dbgWaitMaskFwd++","dbgReadyNotify++","dbgClientLoop++")) {
    if (-not $qq2.Contains($c) -and -not $net.Contains($c)) { throw "verify counter $c" }
}
Write-Host "ALL PATCH VERIFICATION OK"
