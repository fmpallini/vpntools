<#
	CISCO VPN Auto Reconnect Script - version 1.5 - To use with AnyConnect 3.1.x
	This script should self-elevate and maintain the VPN Connected through a powershell background script.
	You can seamsly pause/resume the connection with a simple right button click on tray icon, and better without the need to type your password.

	Some code snippets:
	https://gist.github.com/jhorsman/88321511ce4f416c0605
	https://gist.github.com/jakeballard/11240204

	If your connection is failing, try connecting manually by calling 'vpncli.exe connect vpnname' command and analysing what inputs your vpn is asking.
	Keep in mind that if the VPN already suggest a default vpngroup you should leave this field empty in the script.
#>

#user configurable variables
$vpnurl = ""
$vpngroup = "" #keep it empty if there's no secundary Group option
$vpnuser = ""

$vpnclipath = "C:\Program Files (x86)\Cisco\Cisco AnyConnect Secure Mobility Client" #without ending \
$credentials_file = "cred.txt"
$seconds_connection_fail = 10
$seconds_notification = 3

#icons
$ico_connecting = $vpnclipath + "\res\transition_1.ico"
$ico_idle = $vpnclipath + "\res\GUI.ico"
$ico_connected = $vpnclipath + "\res\vpn_connected.ico"
$ico_error = $vpnclipath + "\res\error.ico"
$ico_warning = $vpnclipath + "\res\attention.ico"

#Avoid duplicated instances
if(get-wmiobject win32_process | where{$_.processname -eq 'powershell.exe' -and $_.ProcessId -ne $pid -and $_.commandline -match $($MyInvocation.MyCommand.Path)})
{
   exit
}

#Import assembly to send keys
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

#Windows Functions - Bring foreground / minimize
Add-Type @'
  using System;
  using System.Runtime.InteropServices;

  public class WinFunc1 {
     [DllImport("user32.dll")]
     [return: MarshalAs(UnmanagedType.Bool)]
     public static extern bool SetForegroundWindow(IntPtr hWnd);
  }

  public class WinFunc2 {
     [DllImport("user32.dll")]
     [return: MarshalAs(UnmanagedType.Bool)]
     public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow); 
  }
'@ -ErrorAction Stop

#Connect Function
Function VPNConnect()
{
    Start-Process -FilePath "$vpnclipath\vpncli.exe" -ArgumentList "connect $vpnurl"
    $counter = 0; $h = 0;
    while($counter++ -lt 1000 -and $h -eq 0)
    {
        sleep -m 10
        $h = (Get-Process vpncli).MainWindowHandle
    }
    [void] [WinFunc1]::SetForegroundWindow($h)
    if($vpngroup -ne "")
    {
       [System.Windows.Forms.SendKeys]::SendWait("$vpngroup{Enter}")
    }
    [System.Windows.Forms.SendKeys]::SendWait("$vpnuser{Enter}")
    [System.Windows.Forms.SendKeys]::SendWait("$vpnpass{Enter}")
    [void] [WinFunc2]::ShowWindowAsync($h, 11)

    #wait for connection
    $counter = 0; $h = 0;
    while($counter++ -lt $seconds_connection_fail)
    {
        $h = (Get-Process vpncli).Id
        if($h -gt 0)
        {
           sleep 1
        }
        else
        {
           break
        }
    }

    if($h -gt 0 -and $counter -gt $seconds_connection_fail)
    {
       Stop-Process $h;
    }
    
    Remove-Variable h, counter
}

#Disconnect Function
Function VPNDisconnect()
{
	Invoke-Expression -Command ".\vpncli.exe disconnect"
}

#Check if its admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')

#Check for previous saved password
if(![System.IO.File]::Exists("$HOME\$credentials_file") -and $isAdmin){
   $cred = Get-Credential -UserName $vpnuser -Message "Enter you VPN password. It will be stored at you home folder using SecureString (DPAPI). The username will always use the one from the script variable."
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
$global:disconnect = 0
$global:reconnect = 0
$global:pause = 0

#Create the notification tray icon
Add-Type -AssemblyName System.Windows.Forms 
$global:balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_connecting)
$balloon.BalloonTipTitle = "VPN Connection"
$balloon.Visible = $true

#Create the context menu
$objContextMenu = New-Object System.Windows.Forms.ContextMenu
$objExitMenuItem = New-Object System.Windows.Forms.MenuItem
$objExitMenuItem.Index = 1
$objExitMenuItem.Text = "Pause/Resume"
$objExitMenuItem.add_Click({

    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_idle)

    if($global:pause -eq 0)
    {
       VPNDisconnect
       $global:pause = 1
       $balloon.Text = "Connection paused on: " + (get-date).ToString('T')
    }
    else
    {
       VPNConnect
       $global:reconnect++
       $global:pause = 0
    }
})
$objContextMenu.MenuItems.Add($objExitMenuItem) | Out-Null

$objExitMenuItem = New-Object System.Windows.Forms.MenuItem
$objExitMenuItem.Index = 2
$objExitMenuItem.Text = "Exit"
$objExitMenuItem.add_Click({

    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ico_idle)
    $global:disconnect = 1

})
$objContextMenu.MenuItems.Add($objExitMenuItem) | Out-Null
$balloon.ContextMenu = $objContextMenu

#Terminate all other vpnui processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui")
{$Id = $_.Id; Stop-Process $Id;}}
#Terminate all other vpncli processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpncli")
{$Id = $_.Id; Stop-Process $Id;}}

#clear unused variables
Remove-Variable isAdmin, cred, CommandLine, Id

#Set working path
Set-Location $vpnclipath

#create the connection
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

while ($true)
{
    if($global:disconnect -eq 1)
    {
        VPNDisconnect

        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = 'VPN disconnect and script terminated.'
        $balloon.ShowBalloonTip($seconds_notification)
        start-sleep -seconds $seconds_notification
        $balloon.Visible = $false
        $balloon.Dispose()
        exit
    }

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

           if($global:retry -eq 0)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'VPN Connection Failed. Retrying in 30 seconds.'
               $balloon.ShowBalloonTip($seconds_notification)
               start-sleep -seconds 30
           }
           elseif($global:retry -ge 3)
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

    start-sleep -seconds 5
    [System.Windows.Forms.Application]::DoEvents()
}
