<#
	CISCO VPN Auto Reconnect Script - version 1.3 - To use with AnyConnect 3.1.x
	This script should auto-elevate and maintain the VPN Connected through a powershell background script.
	There is a left mouse click context button on the tray icon to disconnect and terminate the script.

	Some code snippets:
	https://gist.github.com/jhorsman/88321511ce4f416c0605
	https://gist.github.com/jakeballard/11240204
#>

#user configurable variables
$vpnurl = ""
$vpngroup = ""
$vpnuser = ""

$vpnclipath = "C:\Program Files (x86)\Cisco\Cisco AnyConnect Secure Mobility Client" #without ending \
$credentials_file = "cred.txt"

#Avoid duplicated instances
if(get-wmiobject win32_process | where{$_.processname -eq 'powershell.exe' -and $_.ProcessId -ne $pid -and $_.commandline -match $($MyInvocation.MyCommand.Path)})
{
   exit
}

#Import assembly to manipulate windows
Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

#Windows Functions
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
    [System.Windows.Forms.SendKeys]::SendWait("$vpngroup{Enter}")
    [System.Windows.Forms.SendKeys]::SendWait("$vpnuser{Enter}")
    [System.Windows.Forms.SendKeys]::SendWait("$vpnpass{Enter}")
    [void] [WinFunc2]::ShowWindowAsync($h, 11)
    start-sleep -seconds 5
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

# Self-elevate the script if required
if (-Not $isAdmin) {
 if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
  $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
  Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine -WindowStyle Hidden 
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

# set control variables
$global:retry = 0
$global:disconnect = 0
$global:reconnect = 0
$global:pause = 0

#create the notification tray icon
Add-Type -AssemblyName System.Windows.Forms 
$global:balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\transition_1.ico")
$balloon.BalloonTipTitle = "VPN Connection"
$balloon.Visible = $true

$objContextMenu = New-Object System.Windows.Forms.ContextMenu

$objExitMenuItem = New-Object System.Windows.Forms.MenuItem
$objExitMenuItem.Index = 1
$objExitMenuItem.Text = "Pause/Resume"
$objExitMenuItem.add_Click({

    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\GUI.ico")
	$balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info

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
	$global:disconnect = 1
	$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\transition_1.ico")
	$balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
	$balloon.BalloonTipText = 'Disconnecting...'
	$balloon.ShowBalloonTip(1000)
})
$objContextMenu.MenuItems.Add($objExitMenuItem) | Out-Null


$balloon.ContextMenu = $objContextMenu

#Make sure any previous connection its terminated
Set-Location $vpnclipath
#Terminate all vpnui processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui")
{$Id = $_.Id; Stop-Process $Id;}}
#Terminate all vpncli processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpncli")
{$Id = $_.Id; Stop-Process $Id;}}

#create the connection
Invoke-Expression -Command "net start vpnagent"
VPNConnect

# check the sucess of the connection and go on or exit
$OutputStatus = (.\vpncli.exe status) | Out-String

if(select-string -pattern "state: Connected" -InputObject $OutputStatus)
{
    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\vpn_connected.ico")
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $balloon.BalloonTipText = 'VPN successfully connected.'
    $balloon.ShowBalloonTip(4000)
}
else
{
    $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\error.ico")
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
    $balloon.BalloonTipText = 'VPN not connected. Verify your configurations/credentials. Terminating PowerShell Script.'
    $balloon.ShowBalloonTip(4000)
    start-sleep -seconds 4
    Remove-Item -Path "$HOME\$credentials_file"
    VPNDisconnect
    Invoke-Expression -Command "net stop vpnagent"
    $balloon.Visible = $false
    $balloon.Dispose()
    exit
}

while ($true)
{
    if($global:disconnect -eq 1)
    {
        VPNDisconnect
        Invoke-Expression -Command "net stop vpnagent"
        
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = 'VPN disconnect and script terminated.'
        $balloon.ShowBalloonTip(3000)
        start-sleep -seconds 3
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
            $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\vpn_connected.ico")
            $global:retry = 0
            $global:reconnect = 0
            $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $balloon.BalloonTipText = 'VPN successfully re-connected'
            $balloon.ShowBalloonTip(4000)
        }
        elseif(select-string -pattern "state: Disconnected" -InputObject $OutputStatus)
	    {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\attention.ico")

           if($global:retry -eq 0)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'VPN Connection Failed. Retrying in 30 seconds.'
               $balloon.ShowBalloonTip(4000)
		       start-sleep -seconds 30
           }
           elseif($global:retry -ge 3)
           {
               $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\error.ico")
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
               $balloon.BalloonTipText = 'VPN connection failed for 3 times in a row. Verify your configurations/credentials. Terminating PowerShell Script.'
               $balloon.ShowBalloonTip(4000)
               start-sleep -seconds 4
               Remove-Item -Path "$HOME\$credentials_file"
               VPNDisconnect
               Invoke-Expression -Command "net stop vpnagent"
               $balloon.Visible = $false
               $balloon.Dispose()
               exit
           }

           $global:retry++
           VPNConnect
        }
        elseif(select-string -pattern "state: Reconnecting" -InputObject $OutputStatus)
        {
           $balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\res\attention.ico")
	   
           if(($global:reconnect%10) -eq 0)
           {
               $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
               $balloon.BalloonTipText = 'Connection lost. Trying to reconnect.'
               $balloon.ShowBalloonTip(4000)
           }

           $global:reconnect++
        }

    }

    start-sleep -seconds 5
    [System.Windows.Forms.Application]::DoEvents()
}