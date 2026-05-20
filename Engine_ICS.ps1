# ============================================================
#  Engine_ICS.ps1  -  Motor de Internet Connection Sharing
#  Compatible: Windows PowerShell 5.1 (Windows 11 default)
#  Requiere:   Ejecutar como Administrador
#
#  SEGURIDAD: Disable-ICSAllAdapters SOLO se llama si ICS fue
#             activado explicitamente por este script.
# ============================================================
$ErrorActionPreference = "Stop"

# ── Habilitar colores ANSI en consola Windows ─────────────────
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConsoleHelper {
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
}
"@ -ErrorAction SilentlyContinue
    $handle = [ConsoleHelper]::GetStdHandle(-11)
    $mode   = 0
    [void][ConsoleHelper]::GetConsoleMode($handle, [ref]$mode)
    [void][ConsoleHelper]::SetConsoleMode($handle, $mode -bor 4)
} catch { }

# ── Variables de color (concatenacion para evitar falso [array] en PS5.1) ─
$ESC    = [char]27
$GREEN  = $ESC.ToString() + "[92m"
$YELLOW = $ESC.ToString() + "[93m"
$RED    = $ESC.ToString() + "[91m"
$CYAN   = $ESC.ToString() + "[96m"
$WHITE  = $ESC.ToString() + "[97m"
$DIM    = $ESC.ToString() + "[2m"
$RESET  = $ESC.ToString() + "[0m"
$BOLD   = $ESC.ToString() + "[1m"

# ── Estado global ─────────────────────────────────────────────
# ICSActivatedByThisScript: SOLO true si este script activo ICS.
# Garantiza que el cleanup nunca toca redes que no modificamos.
$global:ICSActivatedByThisScript = $false
$global:WifiAdapter              = ""
$global:EthAdapter               = ""

# ─────────────────────────────────────────────────────────────
# FUNCIONES DE UI
# ─────────────────────────────────────────────────────────────

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host ("  " + $BOLD + $CYAN + "=======================================================")
    Write-Host ("  " + "  SHARING WI-FI TO ETHERNET  //  ICS Manager")
    Write-Host ("  " + "=======================================================" + $RESET)
    Write-Host ("  " + $DIM + "  Motor: PowerShell 5.1 + COM HNetCfg.HNetShare" + $RESET)
    Write-Host ""
}

function Write-StatusBar {
    if ($global:ICSActivatedByThisScript) {
        Write-Host ("  " + $GREEN + $BOLD + "[ * COMPARTIENDO CONEXION ]  Wi-Fi --> Ethernet" + $RESET)
    } else {
        Write-Host ("  " + $DIM + "[ o INACTIVO ]  Internet Connection Sharing detenido" + $RESET)
    }
    Write-Host ("  " + $DIM + ("=" * 54) + $RESET)
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────
# DETECCION DINAMICA DE ADAPTADORES
# ─────────────────────────────────────────────────────────────

function Get-AdaptersInfo {
    <#
    .SYNOPSIS
    Detecta dinamicamente el adaptador Wi-Fi con gateway activo
    y el adaptador Ethernet fisico. Nunca usa nombres hardcoded.
    .NOTES
    Esta funcion es de SOLO LECTURA. No modifica ningun adaptador.
    #>
    $result = @{ Wifi = $null; Eth = $null; Error = $null }
    try {
        # Todos los adaptadores activos y fisicos (excluye virtuales)
        $activeAdapters = Get-NetAdapter | Where-Object {
            $_.Status            -eq 'Up'    -and
            $_.Virtual           -eq $false  -and
            $_.InterfaceDescription -notmatch 'Loopback|WAN Miniport|Teredo|ISATAP|6to4|Bluetooth|Hyper-V'
        }

        if ($activeAdapters.Count -eq 0) {
            $result.Error = "No hay adaptadores de red activos en este sistema."
            return $result
        }

        # Rutas por defecto validas, ordenadas por metrica (menor = preferida)
        $defaultRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                         Where-Object { $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
                         Sort-Object RouteMetric

        # Detectar Wi-Fi: adaptador que tiene la ruta por defecto, priorizando wireless
        $wifiAdapter = $null
        foreach ($route in $defaultRoutes) {
            $ifIdx     = $route.InterfaceIndex
            $candidate = $activeAdapters | Where-Object { $_.ifIndex -eq $ifIdx } | Select-Object -First 1
            if ($null -eq $candidate) { continue }

            $desc       = if ($null -ne $candidate.InterfaceDescription) { $candidate.InterfaceDescription } else { "" }
            $mediaType  = if ($null -ne $candidate.PhysicalMediaType)    { $candidate.PhysicalMediaType }    else { "" }

            $isWireless = ($mediaType -match 'Native 802\.11|Wireless') -or
                          ($desc      -match 'Wi-Fi|Wireless|802\.11|WLAN')

            if ($isWireless) {
                $wifiAdapter = $candidate
                break
            }
            # Fallback: primer adaptador con gateway (si no hay wireless explicito)
            if ($null -eq $wifiAdapter) {
                $wifiAdapter = $candidate
            }
        }

        # Detectar Ethernet fisico: Up, distinto del Wi-Fi, no-wireless
        $wifiIdx    = if ($null -ne $wifiAdapter) { $wifiAdapter.ifIndex } else { -1 }
        $ethAdapter = $activeAdapters | Where-Object {
            $_.ifIndex -ne $wifiIdx -and
            (
                $_.PhysicalMediaType -match '802\.3' -or
                (
                    $_.InterfaceDescription -match 'Ethernet|LAN|Gigabit|Fast Eth|Realtek|Intel.*Eth|Broadcom|RTL' -and
                    $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|802\.11|WLAN|Virtual|Hyper-V|Loopback'
                )
            )
        } | Select-Object -First 1

        $result.Wifi = $wifiAdapter
        $result.Eth  = $ethAdapter

    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

# ─────────────────────────────────────────────────────────────
# HELPERS COM HNetCfg.HNetShare
# ─────────────────────────────────────────────────────────────

function Get-ICSConnection {
    param([string]$AdapterName)
    try {
        $ns    = New-Object -ComObject HNetCfg.HNetShare
        $conns = $ns.EnumEveryConnection()
        foreach ($c in $conns) {
            $p = $ns.NetConnectionProps($c)
            if ($p.Name -eq $AdapterName) { return $c }
        }
    } catch { }
    return $null
}

function Invoke-ICSCleanup {
    <#
    .SYNOPSIS
    Desactiva el ICS UNICAMENTE si este script lo activo previamente.
    NUNCA toca adaptadores que no fueron modificados por esta sesion.
    #>
    if (-not $global:ICSActivatedByThisScript) { return }

    try {
        $ns    = New-Object -ComObject HNetCfg.HNetShare
        $conns = $ns.EnumEveryConnection()
        foreach ($c in $conns) {
            $cfg = $ns.INetSharingConfigurationForINetConnection($c)
            if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
        }
    } catch { }

    $global:ICSActivatedByThisScript = $false
    $global:WifiAdapter = ""
    $global:EthAdapter  = ""
}

# ─────────────────────────────────────────────────────────────
# ACCION 1: ACTIVAR ICS
# ─────────────────────────────────────────────────────────────

function Enable-ICS {
    $info = Get-AdaptersInfo

    if ($info.Error) {
        Write-Host ("  " + $RED + "[ERROR] " + $info.Error + $RESET)
        return
    }
    if ($null -eq $info.Wifi) {
        Write-Host ("  " + $YELLOW + "[AVISO] No se detecto un adaptador Wi-Fi con conexion a internet." + $RESET)
        Write-Host ("  " + $DIM + "  Verifica que el Wi-Fi este conectado y tenga acceso a la red." + $RESET)
        return
    }
    if ($null -eq $info.Eth) {
        Write-Host ("  " + $YELLOW + "[AVISO] No se detecto un adaptador Ethernet fisico conectado." + $RESET)
        Write-Host ("  " + $DIM + "  Conecta el cable RJ45 al puerto de la laptop e intenta de nuevo." + $RESET)
        return
    }

    try {
        Write-Host ("  " + $CYAN + "  Identificando adaptadores..." + $RESET)
        Write-Host ("  " + $DIM + "  Wi-Fi   : " + $info.Wifi.Name + "  [" + $info.Wifi.InterfaceDescription + "]" + $RESET)
        Write-Host ("  " + $DIM + "  Ethernet: " + $info.Eth.Name  + "  [" + $info.Eth.InterfaceDescription  + "]" + $RESET)
        Write-Host ""

        $wifiConn = Get-ICSConnection -AdapterName $info.Wifi.Name
        $ethConn  = Get-ICSConnection -AdapterName $info.Eth.Name

        if ($null -eq $wifiConn) { throw ("No se pudo enlazar COM con '" + $info.Wifi.Name + "'. Verifica que el adaptador este activo.") }
        if ($null -eq $ethConn)  { throw ("No se pudo enlazar COM con '" + $info.Eth.Name  + "'. Verifica que el cable este conectado.") }

        $ns = New-Object -ComObject HNetCfg.HNetShare

        # Antes de activar: limpiar cualquier ICS previo en toda la maquina
        Write-Host ("  " + $DIM + "  Limpiando ICS previo si existia..." + $RESET)
        $allConns = $ns.EnumEveryConnection()
        foreach ($c in $allConns) {
            $cfg = $ns.INetSharingConfigurationForINetConnection($c)
            if ($cfg.SharingEnabled) { $cfg.DisableSharing() }
        }

        Write-Host ("  " + $CYAN + "  Activando ICS..." + $RESET)

        # Wi-Fi = Publica (PublicConnection = 0): la que comparte internet
        # Ethernet = Privada (PrivateConnection = 1): la que distribuye
        $wifiCfg = $ns.INetSharingConfigurationForINetConnection($wifiConn)
        $ethCfg  = $ns.INetSharingConfigurationForINetConnection($ethConn)

        $wifiCfg.EnableSharing(0)
        $ethCfg.EnableSharing(1)

        # Marcar que ESTE script activo el ICS (necesario para cleanup seguro)
        $global:ICSActivatedByThisScript = $true
        $global:WifiAdapter              = $info.Wifi.Name
        $global:EthAdapter               = $info.Eth.Name

        Write-Host ("  " + $GREEN + $BOLD + "[OK] ICS activado correctamente." + $RESET)
        Write-Host ""
        Write-Host ("  " + $YELLOW + "  El router conectado al Ethernet recibira internet via DHCP." + $RESET)
        Write-Host ("  " + $DIM + "  Gateway para el router: 192.168.137.1" + $RESET)
        Write-Host ("  " + $DIM + "  Rango DHCP: 192.168.137.2 - 192.168.137.254" + $RESET)

    } catch {
        Write-Host ("  " + $RED + "[ERROR] No se pudo activar ICS: " + $_.Exception.Message + $RESET)
        Write-Host ("  " + $DIM + "  Verifica que el servicio 'Conexion compartida a Internet (ICS)'" + $RESET)
        Write-Host ("  " + $DIM + "  este habilitado en services.msc (SharedAccess)." + $RESET)
    }
}

# ─────────────────────────────────────────────────────────────
# ACCION 2: MOSTRAR ESTADO
# ─────────────────────────────────────────────────────────────

function Show-Status {
    Write-Host ("  " + $BOLD + $WHITE + "  ESTADO DEL SISTEMA" + $RESET)
    Write-Host ("  " + $DIM + ("-" * 50) + $RESET)

    # Estado ICS real via COM (refleja lo que Windows tiene activo)
    try {
        $ns    = New-Object -ComObject HNetCfg.HNetShare
        $conns = $ns.EnumEveryConnection()
        $pub   = ""
        $priv  = ""
        foreach ($c in $conns) {
            $cfg = $ns.INetSharingConfigurationForINetConnection($c)
            if ($cfg.SharingEnabled) {
                $p = $ns.NetConnectionProps($c)
                if ($cfg.SharingConnectionType -eq 0) { $pub  = $p.Name }
                if ($cfg.SharingConnectionType -eq 1) { $priv = $p.Name }
            }
        }
        if (($pub -ne "") -and ($priv -ne "")) {
            Write-Host ("  " + $GREEN + $BOLD + "  [ACTIVO] Compartiendo internet" + $RESET)
            Write-Host ("  " + $GREEN + "    Fuente (Wi-Fi)   : " + $pub  + $RESET)
            Write-Host ("  " + $GREEN + "    Destino (Eth)    : " + $priv + $RESET)
        } elseif ($pub -ne "" -or $priv -ne "") {
            Write-Host ("  " + $YELLOW + "  [PARCIAL] ICS configurado de forma incompleta." + $RESET)
            Write-Host ("  " + $DIM + "    Publica : " + $pub  + $RESET)
            Write-Host ("  " + $DIM + "    Privada : " + $priv + $RESET)
        } else {
            Write-Host ("  " + $DIM + "  [INACTIVO] ICS no esta activo en ningun adaptador." + $RESET)
        }
    } catch {
        Write-Host ("  " + $RED + "  No se pudo consultar ICS: " + $_.Exception.Message + $RESET)
    }

    Write-Host ""
    Write-Host ("  " + $BOLD + $WHITE + "  ADAPTADORES DE RED DETECTADOS" + $RESET)
    Write-Host ("  " + $DIM + ("-" * 50) + $RESET)

    $info = Get-AdaptersInfo
    if ($info.Error) {
        Write-Host ("  " + $RED + "  Error: " + $info.Error + $RESET)
        return
    }

    if ($null -ne $info.Wifi) {
        $wIP = "No asignada"
        try {
            $addr = Get-NetIPAddress -InterfaceIndex $info.Wifi.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($null -ne $addr) { $wIP = $addr.IPAddress }
        } catch { }
        Write-Host ("  " + $GREEN + "  Wi-Fi   : " + $info.Wifi.Name + $RESET)
        Write-Host ("  " + $DIM + "            " + $info.Wifi.InterfaceDescription + $RESET)
        Write-Host ("  " + $DIM + "            IP actual: " + $wIP + $RESET)
    } else {
        Write-Host ("  " + $YELLOW + "  Wi-Fi   : No detectado o sin gateway activo." + $RESET)
        Write-Host ("  " + $DIM + "            Conecta el Wi-Fi a una red con internet." + $RESET)
    }

    Write-Host ""

    if ($null -ne $info.Eth) {
        $eIP = "Sin IP (normal si ICS no esta activo)"
        try {
            $addr = Get-NetIPAddress -InterfaceIndex $info.Eth.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            if ($null -ne $addr) { $eIP = $addr.IPAddress }
        } catch { }
        Write-Host ("  " + $CYAN + "  Ethernet: " + $info.Eth.Name + $RESET)
        Write-Host ("  " + $DIM + "            " + $info.Eth.InterfaceDescription + $RESET)
        Write-Host ("  " + $DIM + "            IP actual: " + $eIP + $RESET)
    } else {
        Write-Host ("  " + $YELLOW + "  Ethernet: No detectado." + $RESET)
        Write-Host ("  " + $DIM + "            Conecta el cable RJ45 al puerto Ethernet de la laptop." + $RESET)
    }

    Write-Host ""
    Write-Host ("  " + $BOLD + $WHITE + "  TODOS LOS ADAPTADORES ACTIVOS" + $RESET)
    Write-Host ("  " + $DIM + ("-" * 50) + $RESET)
    try {
        $all = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        if ($all.Count -eq 0) {
            Write-Host ("  " + $YELLOW + "  Ningun adaptador activo detectado." + $RESET)
        }
        foreach ($a in $all) {
            $tag = $DIM
            if ($null -ne $info.Wifi -and $a.ifIndex -eq $info.Wifi.ifIndex) { $tag = $GREEN }
            if ($null -ne $info.Eth  -and $a.ifIndex -eq $info.Eth.ifIndex)  { $tag = $CYAN  }
            $line = "  [" + $a.ifIndex.ToString().PadLeft(3) + "] " + $a.Name.PadRight(20) + " " + $a.InterfaceDescription
            Write-Host ($tag + $line + $RESET)
        }
    } catch {
        Write-Host ("  " + $RED + "  Error listando adaptadores: " + $_.Exception.Message + $RESET)
    }
}

# ─────────────────────────────────────────────────────────────
# ACCION 3: DESACTIVAR ICS
# ─────────────────────────────────────────────────────────────

function Disable-ICS {
    try {
        $ns    = New-Object -ComObject HNetCfg.HNetShare
        $conns = $ns.EnumEveryConnection()
        $found = $false
        foreach ($c in $conns) {
            $cfg = $ns.INetSharingConfigurationForINetConnection($c)
            if ($cfg.SharingEnabled) {
                $cfg.DisableSharing()
                $found = $true
            }
        }
        $global:ICSActivatedByThisScript = $false
        $global:WifiAdapter              = ""
        $global:EthAdapter               = ""
        if ($found) {
            Write-Host ("  " + $GREEN + "[OK] ICS desactivado. Los adaptadores vuelven a su estado normal." + $RESET)
        } else {
            Write-Host ("  " + $DIM + "[INFO] El ICS ya estaba inactivo. No se realizo ninguna accion." + $RESET)
        }
    } catch {
        Write-Host ("  " + $RED + "[ERROR] Al desactivar ICS: " + $_.Exception.Message + $RESET)
    }
}

# ─────────────────────────────────────────────────────────────
# MONITOR EN VIVO Y LOG DE CONSUMOS
# ─────────────────────────────────────────────────────────────

function Show-LiveMonitor {
    Write-Header
    Write-Host ("  " + $BOLD + $WHITE + "  MONITOR DE RED EN VIVO (Ethernet)" + $RESET)
    Write-Host ("  " + $DIM + ("-" * 50) + $RESET)
    
    $info = Get-AdaptersInfo
    if ($null -eq $info.Eth) {
        Write-Host ("  " + $YELLOW + "  [AVISO] No se detecto adaptador Ethernet para monitorizar." + $RESET)
        Write-Host ""
        Write-Host ("  " + $DIM + "  Presiona ENTER para volver al menu..." + $RESET)
        Read-Host | Out-Null
        return
    }

    $adapterName = $info.Eth.Name
    Write-Host ("  " + $CYAN + "  Monitorizando: " + $adapterName + $RESET)
    Write-Host ("  " + $DIM + "  (Usa Ctrl+C para salir, o presiona 'Q' para volver al menu)" + $RESET)
    Write-Host ""

    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "NetworkUsageLog.txt"
    $initLogMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] --- Inicio de monitorizacion en $adapterName ---"
    Add-Content -Path $logPath -Value $initLogMsg

    try {
        $prevStats = Get-NetAdapterStatistics -Name $adapterName -ErrorAction Stop
    } catch {
        Write-Host ("  " + $RED + "  Error: No se pudieron obtener estadisticas de $adapterName." + $RESET)
        Write-Host ""
        Write-Host ("  " + $DIM + "  Presiona ENTER para volver al menu..." + $RESET)
        Read-Host | Out-Null
        return
    }

    # Limpiar buffer de teclado ANTES de iniciar por si quedo algun "Enter" rezagado
    while ($Host.UI.RawUI.KeyAvailable) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    $startStats = $prevStats
    $startCursorY = [Console]::CursorTop
    
    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.Character -match 'q|Q' -or $key.VirtualKeyCode -eq 27) { break }
        }

        Start-Sleep -Seconds 1
        $currStats = Get-NetAdapterStatistics -Name $adapterName -ErrorAction SilentlyContinue
        if ($null -eq $currStats) { continue }

        # Velocidad en tiempo real
        $rxBytes = $currStats.ReceivedBytes - $prevStats.ReceivedBytes
        $txBytes = $currStats.SentBytes - $prevStats.SentBytes

        # Consumo acumulado desde que se inicio el monitor
        $rxTotal = $currStats.ReceivedBytes - $startStats.ReceivedBytes
        $txTotal = $currStats.SentBytes - $startStats.SentBytes

        $rxKbps = [math]::Round($rxBytes / 1KB, 2)
        $txKbps = [math]::Round($txBytes / 1KB, 2)
        $rxMbps = [math]::Round($rxBytes / 1MB, 2)
        $txMbps = [math]::Round($txBytes / 1MB, 2)
        
        $rxGb = [math]::Round($rxTotal / 1GB, 3)
        $txGb = [math]::Round($txTotal / 1GB, 3)

        $rxDisp = if ($rxMbps -ge 1) { "$($rxMbps.ToString('0.00').PadLeft(6)) MB/s" } else { "$($rxKbps.ToString('0.00').PadLeft(6)) KB/s" }
        $txDisp = if ($txMbps -ge 1) { "$($txMbps.ToString('0.00').PadLeft(6)) MB/s" } else { "$($txKbps.ToString('0.00').PadLeft(6)) KB/s" }

        $prevStats = $currStats

        $logMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Bajada: $rxDisp (Acumulado: $rxGb GB) | Subida: $txDisp (Acumulado: $txGb GB)"
        Add-Content -Path $logPath -Value $logMsg

        [Console]::SetCursorPosition(0, $startCursorY)
        Write-Host "                                                                                                   " -NoNewline
        [Console]::SetCursorPosition(0, $startCursorY)
        Write-Host ("  " + $GREEN + "  RX: " + $rxDisp + " [" + $rxGb.ToString('0.000') + " GB]" + "   " + $CYAN + "  TX: " + $txDisp + " [" + $txGb.ToString('0.000') + " GB]" + $RESET)
    }

    # Limpiar buffer de teclado si se presiono algo
    while ($Host.UI.RawUI.KeyAvailable) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    $endLogMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] --- Fin de monitorizacion ---"
    Add-Content -Path $logPath -Value $endLogMsg

    Write-Host ""
    Write-Host ""
    Write-Host ("  " + $GREEN + "  Datos guardados en log: " + $logPath + $RESET)
    Write-Host ""
    Write-Host ("  " + $DIM + "  Presiona ENTER para volver al menu..." + $RESET)
    Read-Host | Out-Null
}

function Show-UsageLogs {
    Write-Header
    Write-Host ("  " + $BOLD + $WHITE + "  HISTORIAL DE CONSUMOS" + $RESET)
    Write-Host ("  " + $DIM + ("-" * 50) + $RESET)

    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "NetworkUsageLog.txt"

    if (Test-Path $logPath) {
        Write-Host ("  " + $CYAN + "  Ultimos registros en ${logPath}:" + $RESET)
        Write-Host ""
        $lines = Get-Content -Path $logPath -Tail 25 -ErrorAction SilentlyContinue
        if ($null -ne $lines -and $lines.Count -gt 0) {
            foreach ($line in $lines) {
                Write-Host ("  " + $DIM + $line + $RESET)
            }
        } else {
            Write-Host ("  " + $YELLOW + "  El log esta vacio." + $RESET)
        }
    } else {
        Write-Host ("  " + $YELLOW + "  No se encontro archivo de log. Aun no hay consumos registrados." + $RESET)
    }

    Write-Host ""
    Write-Host ("  " + $DIM + "  Presiona ENTER para volver al menu..." + $RESET)
    Read-Host | Out-Null
}

# ─────────────────────────────────────────────────────────────
# PANTALLA VISUAL "COMPARTIENDO"
# ─────────────────────────────────────────────────────────────

function Show-SharingScreen {
    Write-Header
    Write-Host ("  " + $GREEN + $BOLD)
    Write-Host "  +======================================================+"
    Write-Host "  |                                                      |"
    Write-Host "  |   [*]  COMPARTIENDO CONEXION  [*]                   |"
    Write-Host "  |                                                      |"
    Write-Host "  |   Wi-Fi  ---------------------->  Ethernet / Router  |"
    Write-Host "  |                                                      |"
    Write-Host "  +======================================================+"
    Write-Host ($RESET)
    Write-Host ("  " + $DIM + "  Fuente  : " + $global:WifiAdapter + $RESET)
    Write-Host ("  " + $DIM + "  Destino : " + $global:EthAdapter  + $RESET)
    Write-Host ("  " + $DIM + "  DHCP    : 192.168.137.0/24  (gateway: 192.168.137.1)" + $RESET)
    Write-Host ""
    Write-Host ("  " + $YELLOW + "  Presiona ENTER para volver al menu..." + $RESET)
    Read-Host | Out-Null
}

# ─────────────────────────────────────────────────────────────
# SALIDA SEGURA
# ─────────────────────────────────────────────────────────────

function Invoke-SafeExit {
    Write-Host ""
    if ($global:ICSActivatedByThisScript) {
        Write-Host ("  " + $YELLOW + "  Desactivando ICS antes de salir..." + $RESET)
        Invoke-ICSCleanup
        Write-Host ("  " + $GREEN + "  ICS desactivado. Adaptadores restaurados." + $RESET)
    } else {
        Write-Host ("  " + $DIM + "  ICS no estaba activo, nada que limpiar." + $RESET)
    }
    Write-Host ("  " + $GREEN + "  Hasta pronto." + $RESET)
    Write-Host ""
    Start-Sleep -Seconds 1
    exit 0
}

# ── Registro limpio de evento de salida ──────────────────────
# CRITICO: Solo limpia si este script activo ICS
$null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    try {
        if ($global:ICSActivatedByThisScript) {
            Invoke-ICSCleanup
        }
    } catch { }
}

# ─────────────────────────────────────────────────────────────
# VERIFICACION DE SERVICIO ICS AL INICIO
# ─────────────────────────────────────────────────────────────
function Test-ICSService {
    try {
        $svc = Get-Service -Name SharedAccess -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') {
            Write-Host ("  " + $YELLOW + "[AVISO] El servicio ICS (SharedAccess) esta deshabilitado." + $RESET)
            Write-Host ("  " + $DIM + "  Para habilitarlo: services.msc > 'Conexion compartida a Internet' > Manual." + $RESET)
            Write-Host ""
        }
    } catch { }
}

# ─────────────────────────────────────────────────────────────
# BUCLE PRINCIPAL DEL MENU
# ─────────────────────────────────────────────────────────────
try {
    Test-ICSService

    while ($true) {
        Write-Header
        Write-StatusBar

        Write-Host ("  " + $BOLD + $WHITE + "  MENU PRINCIPAL" + $RESET)
        Write-Host ""
        Write-Host ("   " + $CYAN + "[1]" + $RESET + "  " + $WHITE + "Iniciar modo red" + $RESET + "       " + $DIM + "- Activa ICS: Wi-Fi -> Ethernet" + $RESET)
        Write-Host ("   " + $CYAN + "[2]" + $RESET + "  " + $WHITE + "Estado de la red" + $RESET + "       " + $DIM + "- Muestra adaptadores y estado ICS" + $RESET)
        Write-Host ("   " + $CYAN + "[3]" + $RESET + "  " + $WHITE + "Monitor en vivo" + $RESET + "        " + $DIM + "- Ver subida/bajada Ethernet en tiempo real" + $RESET)
        Write-Host ("   " + $CYAN + "[4]" + $RESET + "  " + $WHITE + "Ver historial consumos" + $RESET + " " + $DIM + "- Muestra log de consumos guardados" + $RESET)
        Write-Host ("   " + $CYAN + "[5]" + $RESET + "  " + $WHITE + "Detener modo red" + $RESET + "       " + $DIM + "- Desactiva ICS y limpia adaptadores" + $RESET)
        Write-Host ("   " + $RED  + "[6]" + $RESET + "  " + $WHITE + "Salir" + $RESET + "                  " + $DIM + "- Cierra la herramienta de forma segura" + $RESET)
        Write-Host ""
        Write-Host ("  " + $DIM + ("=" * 54) + $RESET)
        Write-Host -NoNewline ("  " + $YELLOW + "  Tu eleccion [1-6]: " + $RESET)

        $choice = Read-Host

        Write-Host ""

        switch ($choice.Trim()) {
            '1' {
                if ($global:ICSActivatedByThisScript) {
                    Write-Host ("  " + $YELLOW + "[INFO] El ICS ya esta activo. Usa la opcion 5 para detenerlo primero." + $RESET)
                } else {
                    Enable-ICS
                    if ($global:ICSActivatedByThisScript) {
                        Start-Sleep -Milliseconds 800
                        Show-SharingScreen
                    }
                }
                Write-Host ""
                Write-Host ("  " + $DIM + "  Presiona ENTER para continuar..." + $RESET)
                Read-Host | Out-Null
            }
            '2' {
                Show-Status
                Write-Host ""
                Write-Host ("  " + $DIM + "  Presiona ENTER para volver al menu..." + $RESET)
                Read-Host | Out-Null
            }
            '3' {
                Show-LiveMonitor
            }
            '4' {
                Show-UsageLogs
            }
            '5' {
                Disable-ICS
                Write-Host ""
                Write-Host ("  " + $DIM + "  Presiona ENTER para continuar..." + $RESET)
                Read-Host | Out-Null
            }
            '6' {
                Invoke-SafeExit
            }
            default {
                Write-Host ("  " + $YELLOW + "[AVISO] Opcion invalida. Elige una opcion del 1 al 6." + $RESET)
                Start-Sleep -Milliseconds 800
            }
        }
    }
} finally {
    # Cleanup de emergencia: SOLO si este script activo ICS
    if ($global:ICSActivatedByThisScript) {
        try { Invoke-ICSCleanup } catch { }
    }
}
