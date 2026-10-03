$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$parts = Join-Path $root "ci_parts"

function Read-Norm($p) { ([IO.File]::ReadAllText($p)) -replace "`r`n", "`n" }
function Write-Lf($p, $t) { [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($false))) }
function Part($n) { (Read-Norm (Join-Path $parts $n)).TrimEnd("`n","`r") }

function Apply-Literal($file, $old, $new, $tag) {
    $old = $old -replace "`r`n", "`n"
    $new = $new -replace "`r`n", "`n"
    $p = Join-Path $root $file
    $t = Read-Norm $p
    $cnt = ([regex]::Matches($t, [regex]::Escape($old))).Count
    if ($cnt -ne 1) { throw "$tag : expected 1 match, got $cnt" }
    $t = $t.Replace($old, $new)
    Write-Lf $p $t
    [Console]::WriteLine("OK  $tag")
}

function Apply-Regex($file, $pattern, $new, $tag) {
    $pattern = $pattern -replace "`r`n", "`n"
    $new = $new -replace "`r`n", "`n"
    $p = Join-Path $root $file
    $t = Read-Norm $p
    $rx = [regex]$pattern
    $cnt = $rx.Matches($t).Count
    if ($cnt -ne 1) { throw "$tag : expected 1 match, got $cnt" }
    if ($new -match '\$') { throw "$tag : replacement must not contain `$" }
    $t = $rx.Replace($t, $new)
    Write-Lf $p $t
    [Console]::WriteLine("OK  $tag")
}

# ---------- internal.h : ringbuffer.h must precede device.h ----------
Apply-Literal "ComPort\internal.h" @'
#include "device.h"
#include "ringbuffer.h"
'@ @'
#include "ringbuffer.h"
#include "device.h"
'@ "I1 internal include order"

# ---------- device.h : RX_RING_SIZE + receive ring fields ----------
Apply-Literal "ComPort\device.h" @'
#define REG_PATH_SERIALCOMM         REG_PATH_DEVICEMAP L"\\" SERIAL_DEVICE_MAP

typedef struct _DEVICE_CONTEXT
'@ @'
#define REG_PATH_SERIALCOMM         REG_PATH_DEVICEMAP L"\\" SERIAL_DEVICE_MAP

// Size of the receive ring that decouples socket arrival from read IRPs.
#define RX_RING_SIZE                16384

typedef struct _DEVICE_CONTEXT
'@ "D1 device RX_RING_SIZE"

Apply-Literal "ComPort\device.h" @'
    BOOL            crunchDownToOne;

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;
'@ @'
    BOOL            crunchDownToOne;

    //
    // Receive ring and cached queue handles; socket data is drained into the
    // ring on FD_READ and read IRPs are satisfied from the ring (network.cpp).
    //
    RING_BUFFER     ReadRing;
    BYTE            ReadRingStorage[RX_RING_SIZE];
    WDFQUEUE        PendingReadQueue;
    WDFQUEUE        PendingWaitMaskQueue;
    ULONG           PendingRxSignals;

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;
'@ "D2 device ring fields"

# ---------- serial.h : SERIAL_EV_* wait event bits ----------
Apply-Literal "ComPort\serial.h" "`n`n`ntypedef struct _SERIAL_BAUD_RATE {" ("`n`n" + (Part "s_events.txt") + "`n`n`ntypedef struct _SERIAL_BAUD_RATE {") "S1 serial event bits"

# ---------- network.cpp ----------
Apply-Literal "ComPort\network.cpp" '            TerminateThread(deviceContext->ThreadEvent, 1);' '            TerminateThread(deviceContext->ThreadHandle, 1);' "N1 TerminateThread handle"

Apply-Regex "ComPort\network.cpp" '(?s)// returns true if the request was completed else false\.\nvoid processRequest\(.*?\n\}(?=\n\nDWORD ClientThread)' (Part "n_helpers.txt") "N2 receive helpers"

Apply-Regex "ComPort\network.cpp" '(?s)DWORD ClientThread\(PVOID context\)\n\{.*?\n\}(?=DWORD ServiceThread)' (Part "n_client.txt") "N3 client thread"

Apply-Literal "ComPort\network.cpp" @'
    CleanupNetwork(deviceContext);

    struct addrinfo hints = { };
'@ ("    CleanupNetwork(deviceContext);`n`n" + (Part "n_cfg_client.txt") + "`n`n    struct addrinfo hints = { };") "N4 configure client"

Apply-Literal "ComPort\network.cpp" @'
    CleanupNetwork(deviceContext);

    sockaddr_in service;
'@ ("    CleanupNetwork(deviceContext);`n`n" + (Part "n_cfg_service.txt") + "`n`n    sockaddr_in service;") "N5 configure service"

# N6: n_cfg_service already declares 'int result'; the original bind line must not redeclare it.
Apply-Literal "ComPort\network.cpp" '    int result = bind(deviceContext->ServiceSocket,' '    result = bind(deviceContext->ServiceSocket,' "N6 bind result redeclare"

# ---------- queue.cpp ----------
Apply-Literal "ComPort\queue.cpp" @'
}

PCHAR
SerialGetIoctlName(
'@ ("}`n`n" + (Part "q_types.txt") + "`n`nPCHAR`nSerialGetIoctlName(") "Q1 serial types"

Apply-Literal "ComPort\queue.cpp" @'
    queueContext->WaitMaskQueue = queue;

    RingBufferInitialize(&queueContext->RingBuffer,
'@ ("    queueContext->WaitMaskQueue = queue;`n`n" + (Part "q_create.txt") + "`n`n    RingBufferInitialize(&queueContext->RingBuffer,") "Q2 queue create ring"

Apply-Regex "ComPort\queue.cpp" '(?s)    case IOCTL_SERIAL_WAIT_ON_MASK:\n    \{.*?\n    \}(?=\n\n    case IOCTL_SERIAL_SET_WAIT_MASK:)' (Part "q_waitmask.txt") "Q3 wait-on-mask"

Apply-Regex "ComPort\queue.cpp" '(?s)    case IOCTL_SERIAL_SET_QUEUE_SIZE:\n    case IOCTL_SERIAL_SET_DTR:.*?\n        status = STATUS_SUCCESS;\n        break;' (Part "q_ioctl.txt") "Q4 properties/modemstatus ioctls"

[Console]::WriteLine("ALL PATCHES APPLIED")
