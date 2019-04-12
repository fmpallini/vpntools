<#
   CISCO VPN Auto Reconnect Script - version 1.94 - To use with AnyConnect 3.1.x or 4.5.x
   https://github.com/fmpallini/vpntools/blob/master/cisco_vpn_autoconnect.ps1

   This script should self-elevate and maintain the VPN Connected through a powershell background script.
   You can seamsly pause/resume the connection with a simple right button click on tray icon, and better without the need to type your password.

   Some code snippets:
   https://gist.github.com/jhorsman/88321511ce4f416c0605
   https://gist.github.com/jakeballard/11240204

   If your connection is failing, try connecting manually by calling 'vpncli.exe connect vpnname' command and analysing what inputs your vpn is asking.
#>

#connection data - leave empty to use the values from default connection
$vpnurl = ""
$vpngroup = ""
$vpnuser = ""

#configs
$vpnclipath = "${env:ProgramFiles(x86)}\Cisco\Cisco AnyConnect Secure Mobility Client" #without ending \
$default_preferences_file = "$HOME\AppData\Local\Cisco\Cisco AnyConnect Secure Mobility Client\preferences.xml"
$credentials_file = "cred.txt"
$connection_stdout = "vpn_stdout.txt"
$seconds_connection_fail = 20
$seconds_notification = 3
$seconds_main_loop = 5

#icons
$ico_connecting = $vpnclipath + "\res\transition_1.ico"
$ico_idle = $vpnclipath + "\res\GUI.ico"
$ico_connected = $vpnclipath + "\res\vpn_connected.ico"
$ico_error = $vpnclipath + "\res\error.ico"
$ico_warning = $vpnclipath + "\res\attention.ico"

#Import assembly to use send keys
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

#Windows Functions
Add-Type @'
  using System;
  using System.Runtime.InteropServices;

  public class WinFunc {
     [DllImport("user32.dll")]
     [return: MarshalAs(UnmanagedType.Bool)]
     public static extern bool SetForegroundWindow(IntPtr hWnd);

     [DllImport("user32.dll")]
     [return: MarshalAs(UnmanagedType.Bool)]
     public static extern bool BlockInput(bool fBlockIt);
  }
'@ -ErrorAction Stop

#Avoid duplicated instances
if(get-wmiobject win32_process | where{$_.processname -eq 'powershell.exe' -and $_.ProcessId -ne $pid -and $_.commandline -match $($MyInvocation.MyCommand.Path)})
{
   [System.Windows.Forms.MessageBox]::Show('Another instance already running.', 'VPN Connection', 'Ok', 'Warning')
   Exit
}

#Validate/treat variables
if(!$vpnurl -or !$vpnuser)
{
   if(![System.IO.File]::Exists($default_preferences_file))
   {
      [System.Windows.Forms.MessageBox]::Show("Default connection data not found. Please fill the values inside the script.", 'VPN Connection', 'Ok', 'Warning')
      Exit
   }

   $preferences = [xml](Get-Content $default_preferences_file)

   $vpnurl = $preferences.AnyConnectPreferences.DefaultHostName
   $vpnuser = $preferences.AnyConnectPreferences.DefaultUser
   $vpngroup = $preferences.AnyConnectPreferences.DefaultGroup
}
if(![System.IO.File]::Exists("$vpnclipath\vpncli.exe")){
   [System.Windows.Forms.MessageBox]::Show("vpncli.exe not found. Check your path variable.`n`n$($vpnclipath)\vpncli.exe", 'VPN Connection', 'Ok', 'Warning')
   Exit
}

#Functions
Function VPNConnect()
{
    Start-Process -FilePath "$vpnclipath\vpncli.exe" -ArgumentList "connect $vpnurl" -RedirectStandardOutput "$HOME\$connection_stdout" -WindowStyle Minimized
    $counter = 0;
    while($counter++ -lt $seconds_connection_fail)
    {
        start-sleep -seconds 1
        $last_line = Get-Content "$HOME\$connection_stdout" -Tail 1
        if((select-string -pattern "Group:" -InputObject $last_line) -or (select-string -pattern "Username:" -InputObject $last_line))
        {
          break;
        }
    }

    if($counter -ge $seconds_connection_fail)
    {
        $process_id = (Get-Process vpncli).Id
        if($process_id)
        {
           Stop-Process $process_id;
        }
    }
    else
    {
        $window = (Get-Process vpncli).MainWindowHandle

        if($window)
        {
           [void] [WinFunc]::SetForegroundWindow($window)
           [void] [WinFunc]::BlockInput($true)
           if (select-string -pattern "Group:" -InputObject $last_line)
           {
              [System.Windows.Forms.SendKeys]::SendWait("$vpngroup{Enter}")
           }
           [System.Windows.Forms.SendKeys]::SendWait("$vpnuser{Enter}")
           [System.Windows.Forms.SendKeys]::SendWait("$vpnpass{Enter}")
           [void] [WinFunc]::BlockInput($false)

           #wait for connection
           while($counter++ -lt $seconds_connection_fail)
           {
             $process_id = (Get-Process vpncli).Id
             if($process_id)
             {
               start-sleep -seconds 1
             }
             else
             {
               break
             }
           }

           if($process_id)
           {
              Stop-Process $process_id;
           }
        }
    }

    Remove-Variable counter, last_line, window, process_id
    Remove-Item -Path "$HOME\$connection_stdout"
}

Function VPNDisconnect()
{
   Invoke-Expression -Command ".\vpncli.exe disconnect"
}

#Check if its admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')

#Check for previous saved password
if(![System.IO.File]::Exists("$HOME\$credentials_file") -and $isAdmin){
   $cred = Get-Credential -UserName $vpnuser -Message "Enter you VPN password. It will be stored at you home folder using SecureString (DPAPI). The username will always use the one from the default connection or script variable."
   if(!$cred)
   {
     Exit
   }
   $cred = $cred.Password
}

#Self-elevate the script if required
if (-Not $isAdmin) {
 if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
  $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
  Start-Process -FilePath PowerShell.exe -Verb Runas -WindowStyle Hidden -ArgumentList $CommandLine
  Exit
 }
}

#Use or Generate Credentials file
if(![System.IO.File]::Exists("$HOME\$credentials_file")){
   $cred | ConvertFrom-SecureString |  Set-Content -Path "$HOME\$credentials_file"
}
else
{
   $cred = Get-Content -Path "$HOME\$credentials_file" | ConvertTo-SecureString
}
$vpnpass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((($cred))))

#Set control variables
$global:retry = 0
$global:reconnect = 0
$global:pause = 0

#Create the notification tray icon
$global:balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_connecting)
$balloon.BalloonTipTitle = "VPN Connection"
$balloon.Visible = $true

#Create the context menu
$objContextMenu = New-Object System.Windows.Forms.ContextMenu
$objMenuItem = New-Object System.Windows.Forms.MenuItem
$objMenuItem.Index = 1
$objMenuItem.Text = "Pause/Resume"
$objMenuItem.add_Click({

    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_idle)

    if($global:pause -eq 0)
    {
       $global:pause = 1
       start-sleep -seconds $seconds_main_loop
       VPNDisconnect
       $balloon.Text = "Connection paused on: " + (get-date).ToString('T')
    }
    else
    {
       VPNConnect
       $global:reconnect++
       $global:pause = 0
    }
})
$objContextMenu.MenuItems.Add($objMenuItem) | Out-Null

$objMenuItem = New-Object System.Windows.Forms.MenuItem
$objMenuItem.Index = 2
$objMenuItem.Text = "Exit"
$objMenuItem.add_Click({

   $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_idle)
   $global:pause = 1
   start-sleep -seconds $seconds_main_loop
   VPNDisconnect

   $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
   $balloon.BalloonTipText = 'VPN disconnect and script terminated.'
   $balloon.ShowBalloonTip($seconds_notification)
   start-sleep -seconds $seconds_notification
   $balloon.Visible = $false
   $balloon.Dispose()
   Stop-Process -Id $pid;

})
$objContextMenu.MenuItems.Add($objMenuItem) | Out-Null
$balloon.ContextMenu = $objContextMenu

#Terminate all other vpnui processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui")
{$Id = $_.Id; Stop-Process $Id;}}
#Terminate all other vpncli processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpncli")
{$Id = $_.Id; Stop-Process $Id;}}

#clear unused variables
Remove-Variable isAdmin, Id, cred, objContextMenu, objMenuItem, preferences, default_preferences_file

#Set working path
Set-Location $vpnclipath

#create the connection
VPNDisconnect
VPNConnect

# check the sucess of the connection and go on or exit
$OutputStatus = (.\vpncli.exe status) | Out-String

if(select-string -pattern "state: Connected" -InputObject $OutputStatus)
{
    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_connected)
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $balloon.BalloonTipText = 'VPN successfully connected.'
    $balloon.ShowBalloonTip($seconds_notification)
}
else
{
    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_error)
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
    $balloon.BalloonTipText = 'VPN not connected. Verify your configurations/credentials. Terminating PowerShell Script.'
    $balloon.ShowBalloonTip($seconds_notification)
    VPNDisconnect
    Remove-Item -Path "$HOME\$credentials_file"
    start-sleep -seconds $seconds_notification
    $balloon.Visible = $false
    $balloon.Dispose()
    exit
}

#Force GC before main loop
[System.GC]::Collect()

while ($true)
{
    if($global:pause -eq 0)
    {
        $OutputStatus = (.\vpncli.exe status) | Out-String
        $balloon.Text = "Last status check: " + (get-date).ToString('T')

        if ((select-string -pattern "state: Connected" -InputObject $OutputStatus) -and 
           (($global:retry -ne 0) -or ($global:reconnect -ne 0)))
        {
            $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_connected)
            $global:retry = 0
            $global:reconnect = 0
            $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $balloon.BalloonTipText = 'VPN successfully re-connected'
            $balloon.ShowBalloonTip($seconds_notification)
        }
        elseif(select-string -pattern "state: Disconnected" -InputObject $OutputStatus)
        {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_warning)

           if($global:retry -lt 3)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'VPN Connection Failed. Retrying in 30 seconds.'
               $balloon.ShowBalloonTip($seconds_notification)
               start-sleep -seconds 30
           }
           else
           {
               $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_error)
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
               $balloon.BalloonTipText = 'VPN connection failed for 3 times in a row. Verify your configurations/credentials. Terminating PowerShell Script.'
               $balloon.ShowBalloonTip($seconds_notification)
               start-sleep -seconds $seconds_notification
               VPNDisconnect
               Remove-Item -Path "$HOME\$credentials_file"
               $balloon.Visible = $false
               $balloon.Dispose()
               exit
           }

           $global:retry++
           VPNConnect
        }
        elseif(select-string -pattern "state: Reconnecting" -InputObject $OutputStatus)
        {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_warning)

           if(($global:reconnect%10) -eq 0)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'Connection lost. Trying to reconnect.'
               $balloon.ShowBalloonTip($seconds_notification)
           }

           $global:reconnect++
        }
    }

    start-sleep -seconds $seconds_main_loop
    [System.Windows.Forms.Application]::DoEvents()
}
