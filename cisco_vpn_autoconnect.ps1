<#
   CISCO VPN Auto Reconnect Script - version 2.12
   Tested with AnyConnect 3.1.x and 4.5.x.
   https://github.com/fmpallini/vpntools/blob/master/cisco_vpn_autoconnect.ps1

   This script should self-elevate and maintain the VPN connection through a PowerShell background script.
   You can seamlessly pause/resume the connection with a simple right button click on the tray icon, suspend/awake your PC and better of all... without the need to re-type your password.

   Some used code snippets:
   https://gist.github.com/jhorsman/88321511ce4f416c0605
   https://gist.github.com/jakeballard/11240204

   If your connection is failing, try looking at the output file at your home folder or try to connect manually by calling 'vpncli.exe connect vpnname' command and analyzing what inputs your VPN is answering.

   TODO:
   - Suppress VPN's Daemon popup notifications;
   - Don't rely on eternal loop/sleep. Discover a way to make GUI events to be immediately handled, then isolating the monitor function and the events handling;
   - Bypass Windows PowerShell name at process manager;
#>

#Connection data - leave empty to use the values from default connection
$vpn_url = ""
$vpn_group = ""

#Configs
$vpncli_path = "${env:ProgramFiles(x86)}\Cisco\Cisco AnyConnect Secure Mobility Client" #without ending \
$default_preferences_file = "$HOME\AppData\Local\Cisco\Cisco AnyConnect Secure Mobility Client\preferences.xml"
$credentials_file = "vpn_credentials.txt"
$connection_stdout = "vpn_stdout.txt"
$seconds_connection_fail = 20
$seconds_notification = 3
$seconds_main_loop = 10

#Icons
$ico_transition = $vpncli_path + "\res\transition_1.ico"
$ico_idle = $vpncli_path + "\res\GUI.ico"
$ico_connected = $vpncli_path + "\res\vpn_connected.ico"
$ico_error = $vpncli_path + "\res\error.ico"
$ico_warning = $vpncli_path + "\res\attention.ico"

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

     [DllImport("user32.dll")]
     [return: MarshalAs(UnmanagedType.Bool)]
     public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
  }
'@ -ErrorAction Stop

#Functions
Function VPNConnect()
{
    Start-Process -FilePath "$vpncli_path\vpncli.exe" -ArgumentList "connect $vpn_url" -RedirectStandardOutput "$HOME\$connection_stdout" -WindowStyle Minimized
    $counter = 0;
    while($counter++ -lt $seconds_connection_fail)
    {
        Start-Sleep -seconds 1
        $last_line = Get-Content "$HOME\$connection_stdout" -Tail 1
        if((Select-String -pattern "Group:" -InputObject $last_line) -or (Select-String -pattern "Username:" -InputObject $last_line))
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
           [void] [WinFunc]::BlockInput($true)
           [void] [WinFunc]::ShowWindowAsync($window,1)
           [void] [WinFunc]::SetForegroundWindow($window)
           if (Select-String -pattern "Group:" -InputObject $last_line)
           {
              [System.Windows.Forms.SendKeys]::SendWait("$vpn_group{Enter}")
           }
           [System.Windows.Forms.SendKeys]::SendWait("$vpn_user{Enter}")
           [System.Windows.Forms.SendKeys]::SendWait([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($vpn_pass)))
           [System.Windows.Forms.SendKeys]::SendWait("{Enter}")
           [void] [WinFunc]::ShowWindowAsync($window,6)
           [void] [WinFunc]::BlockInput($false)

           #wait for connection
           while($counter++ -lt $seconds_connection_fail)
           {
             $process_id = (Get-Process vpncli).Id
             if($process_id)
             {
               Start-Sleep -seconds 1
             }
             else
             {
               break
             }
           }

           $process_id = (Get-Process vpncli).Id
           if($process_id)
           {
              Stop-Process $process_id;
           }
        }
    }

    "---`r`n`Last connection process finished at " + (Get-Date).ToString() + " using the configuration stored on $HOME\$credentials_file" | Out-File "$HOME\$connection_stdout" -Append -Encoding ASCII
    Remove-Variable counter, last_line, window, process_id
}

Function VPNDisconnect()
{
   Invoke-Expression -Command ".\vpncli.exe disconnect"
}

#Validate/treat variables
if(![System.IO.File]::Exists("$vpncli_path\vpncli.exe"))
{
   [System.Windows.Forms.MessageBox]::Show("vpncli.exe not found. Check your path variable.`n`n$($vpncli_path)\vpncli.exe", 'VPN Connection', 'Ok', 'Warning')
   Exit
}

if(!$vpn_url -or !$vpn_group)
{
   if([System.IO.File]::Exists($default_preferences_file))
   {
      $preferences = [xml](Get-Content $default_preferences_file)

      $vpn_url = $preferences.AnyConnectPreferences.DefaultHostName
      $vpn_user = $preferences.AnyConnectPreferences.DefaultUser
      $vpn_group = $preferences.AnyConnectPreferences.DefaultGroup
   }

   if(!$vpn_url -or !$vpn_group)
   {
      [System.Windows.Forms.MessageBox]::Show("Default connection data not found. Please fill the values inside the script.", 'VPN Connection', 'Ok', 'Warning')
      Exit
   }
}

#Check for previous saved password
if(![System.IO.File]::Exists("$HOME\$credentials_file")){
   $cred = Get-Credential -UserName $vpn_user -Message "Enter your username and password. The password will be stored using SecureString (DPAPI). The URL and Group values are extracted from the default AnyConnect connection but can be overwritten with variables inside the script.`r`n`r`nUrl: $vpn_url `r`nGroup: $vpn_group"
   if(!$cred)
   {
     Exit
   }

   $cred = @{
    user = $cred.UserName
    pass = $cred.Password | ConvertFrom-SecureString
    url = $vpn_url
    group = $vpn_group
   }
   
   $cred | ConvertTo-Json | Set-Content -Path "$HOME\$credentials_file"
}
else
{
    $cred = Get-Content -Path "$HOME\$credentials_file" -Raw | ConvertFrom-Json
}

#Self-elevate the script if required
if(!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator'))
{
  $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
  Start-Process -FilePath PowerShell.exe -Verb Runas -WindowStyle Hidden -ArgumentList $CommandLine
  Exit
}

#Avoid duplicated instances
if(Get-WmiObject win32_process | where{$_.processname -eq 'powershell.exe' -and $_.ProcessId -ne $pid -and $_.commandline -match $($MyInvocation.MyCommand.Path)})
{
   [System.Windows.Forms.MessageBox]::Show('Another instance already running.', 'VPN Connection', 'Ok', 'Warning')
   Exit
}

#Restore variables from JSON Object
$vpn_user = $cred.user
$vpn_pass = $cred.pass | ConvertTo-SecureString
$vpn_url = $cred.url
$vpn_group = $cred.group

#Set control variables
$global:retry = 0
$global:pause = $false

#Create the notification tray icon
$global:balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_transition)
$balloon.BalloonTipTitle = "VPN Connection"
$balloon.Visible = $true

#Create the context menu
$objContextMenu = New-Object System.Windows.Forms.ContextMenu
$objMenuItem = New-Object System.Windows.Forms.MenuItem
$objMenuItem.Index = 1
$objMenuItem.Text = "Pause/Resume"
$objMenuItem.add_Click({

    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_transition)

    if($global:pause -eq $false)
    {
       $global:pause = $true
       VPNDisconnect
       $balloon.Text = "Connection paused on: " + (get-date).ToString('T')
       $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_idle)
    }
    else
    {
       VPNConnect
       $global:retry++
       $global:pause = $false
    }
})
$objContextMenu.MenuItems.Add($objMenuItem) | Out-Null

$objMenuItem = New-Object System.Windows.Forms.MenuItem
$objMenuItem.Index = 2
$objMenuItem.Text = "Exit"
$objMenuItem.add_Click({

   $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_transition)
   $global:pause = $true
   VPNDisconnect
   $balloon.Visible = $false
   $balloon.Dispose()
   Stop-Process -Id $pid;
})
$objContextMenu.MenuItems.Add($objMenuItem) | Out-Null


$objMenuItem = New-Object System.Windows.Forms.MenuItem
$objMenuItem.Index = 3
$objMenuItem.Text = "More..."

$objMenuItemSub = New-Object System.Windows.Forms.MenuItem
$objMenuItemSub.Index = 1
$objMenuItemSub.Text = "Show last connection log"
$objMenuItemSub.add_Click({
   Start-Process -FilePath "notepad.exe" -ArgumentList "$HOME\$connection_stdout"
})
$objMenuItem.MenuItems.Add($objMenuItemSub) | Out-Null

$objMenuItemSub = New-Object System.Windows.Forms.MenuItem
$objMenuItemSub.Index = 2
$objMenuItemSub.Text = "Clear credentials and Exit"
$objMenuItemSub.add_Click({
   $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_transition)
   $global:pause = $true
   VPNDisconnect
   $balloon.Visible = $false
   $balloon.Dispose()
   Remove-Item -Path "$HOME\$credentials_file"
   Stop-Process -Id $pid;
})
$objMenuItem.MenuItems.Add($objMenuItemSub) | Out-Null
$objContextMenu.MenuItems.Add($objMenuItem) | Out-Null

$balloon.ContextMenu = $objContextMenu

#Terminate all other vpnui/vpncli processes
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui" -or $_.ProcessName.ToLower() -eq "vpncli")
{$Id = $_.Id; Stop-Process $Id;}}

#Clear unused variables
Remove-Variable Id, cred, objContextMenu, objMenuItem, objMenuItemSub, preferences, default_preferences_file

#Set working path
Set-Location $vpncli_path

#create the initial connection
Invoke-Expression -Command "net start vpnagent"
VPNDisconnect
VPNConnect

#Check the success of the connection
$outputStatus = (.\vpncli.exe status) | Out-String

if(Select-String -pattern "state: Connected" -InputObject $outputStatus)
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
    $balloon.BalloonTipText = 'VPN failed to connect. Verify your configurations/credentials. Terminating PowerShell Script.'
    $balloon.ShowBalloonTip($seconds_notification)
    VPNDisconnect
    Remove-Item -Path "$HOME\$credentials_file"
    Start-Sleep -seconds $seconds_notification
    $balloon.Visible = $false
    $balloon.Dispose()
    Exit
}

#Main loop
while ($true)
{
    if($global:pause -eq $false)
    {
        $outputStatus = (.\vpncli.exe status) | Out-String
        $balloon.Text = "Last status check: " + (Get-Date).ToString('T')

        if (Select-String -pattern "state: Connected" -InputObject $outputStatus)
        {
            if($global:retry -ne 0)
            {
               $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_connected)
               $global:retry = 0
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
               $balloon.BalloonTipText = 'VPN successfully re-connected'
               $balloon.ShowBalloonTip($seconds_notification)
            }
        }
        elseif(Select-String -pattern "state: Reconnecting" -InputObject $outputStatus)
        {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_warning)

           if(($global:retry%10) -eq 0)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'Connection lost. Trying to reconnect.'
               $balloon.ShowBalloonTip($seconds_notification)
           }

           $global:retry++
        }
        elseif(Select-String -pattern "state: Disconnected" -InputObject $outputStatus)
        {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_warning)

           if($global:retry -lt 3)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'VPN Connection Failed. Retrying in 30 seconds.'
               $balloon.ShowBalloonTip($seconds_notification)
               Start-Sleep -seconds 30
           }
           else
           {
               $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_error)
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
               $balloon.BalloonTipText = 'VPN connection failed for 3 times in a row. Verify your configurations/credentials. Terminating PowerShell Script.'
               $balloon.ShowBalloonTip($seconds_notification)
               VPNDisconnect
               Remove-Item -Path "$HOME\$credentials_file"
               $balloon.Visible = $false
               $balloon.Dispose()
               Exit
           }

           $global:retry++
           VPNConnect
        }
    }

    Start-Sleep -seconds $seconds_main_loop
    [System.Windows.Forms.Application]::DoEvents()
}
