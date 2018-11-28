<#
	CISCO VPN Auto Reconnect Script - To use with AnyConnect 3.1.x
	This script should auto-elevate and maintain the VPN Connected through a powershell background script.
	There is a left mouse click context button on the tray icon to disconnect and terminate the script.
	If needed you can adjust the connection.dat writing to fit your VPN needs.
#>

#user configurable variable
$vpnurl = ""
$vpngroup = ""
$vpnuser = ""
$vpnpass = "" #remember to escape special caracters with '`'
$vpnclipath = "C:\Program Files (x86)\Cisco\Cisco AnyConnect Secure Mobility Client" #without ending \

# Get the ID and security principal of the current user account
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
 
# Get the security principal for the Administrator role
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
 
# Self-elevate the script if required
if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
 if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
  $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments
  Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $CommandLine -WindowStyle Hidden
  Exit
 }
}

#Terminate all vpnui processes to avoid problems
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui")
{$Id = $_.Id; Stop-Process $Id;}}
#Terminate all vpncli processes.
Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpncli")
{$Id = $_.Id; Stop-Process $Id;}}
Invoke-Expression -Command "net start vpnagent"

#Make sure any connection its terminated
Set-Location $vpnclipath
Invoke-Expression -Command ".\vpncli.exe disconnect"

#generate the files necessary to calling the connect command from cmd
'connect ' + $vpnurl + "`r`n" + $vpngroup + "`r`n" + $vpnuser + "`r`n" + $vpnpass | Out-File -Encoding ascii 'connection.dat'
'vpncli.exe -s < connection.dat' | Out-File -Encoding ascii 'connect.bat'

# set control variables
$global:retry = 0
$global:disconnect = 0
$global:reconnect = 0

#create the connection
Start-Process -FilePath .\connect.bat -Wait -WindowStyle Minimized

#create the notification tray icon
Add-Type -AssemblyName System.Windows.Forms 
$global:balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($vpnclipath + "\vpnagent.exe") 
$balloon.BalloonTipTitle = "VPN Connection"
$balloon.Visible = $true

$objContextMenu = New-Object System.Windows.Forms.ContextMenu
$objExitMenuItem = New-Object System.Windows.Forms.MenuItem

$objExitMenuItem.Index = 1
$objExitMenuItem.Text = "Disconnect"
$objExitMenuItem.add_Click({
	$global:disconnect = 1
	$balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
	$balloon.BalloonTipText = 'Disconnecting...'
	$balloon.Visible = $true
	$balloon.ShowBalloonTip(1000)
})
$objContextMenu.MenuItems.Add($objExitMenuItem) | Out-Null
$balloon.ContextMenu = $objContextMenu

# check the sucess of the connection and go on or exit
$OutputStatus = (.\vpncli.exe status) | Out-String

if(select-string -pattern "state: Connected" -InputObject $OutputStatus)
{
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $balloon.BalloonTipText = 'VPN successfully connected.'
    $balloon.ShowBalloonTip(5000)
}
else
{
    $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
    $balloon.BalloonTipText = 'VPN not connected. Terminating PowerShell Script. Verify your credentials.'
    $balloon.ShowBalloonTip(5000)
    exit
}

while ($true)
{
    if($global:disconnect -eq 1)
    {
        Invoke-Expression -Command ".\vpncli.exe disconnect"
        #Terminate all vpnui processes.
        Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpnui")
        {$Id = $_.Id; Stop-Process $Id;}}
        #Terminate all vpncli processes.
        Get-Process | ForEach-Object {if($_.ProcessName.ToLower() -eq "vpncli")
        {$Id = $_.Id; Stop-Process $Id;}}
        
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = 'VPN disconnect and script terminated.'
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(5000)
        start-sleep -seconds 5
        exit
    }

	$OutputStatus = (.\vpncli.exe status) | Out-String

    if ((select-string -pattern "state: Connected" -InputObject $OutputStatus) -and 
       (($global:retry -ne 0) -or ($global:reconnect -ne 0)))
	{
        $global:retry = 0
        $global:reconnect = 0
        $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipText = 'VPN successfully re-connected'
        $balloon.ShowBalloonTip(5000)
    }
    elseif(select-string -pattern "state: Disconnected" -InputObject $OutputStatus)
	{
       if($global:retry -eq 0)
       {
           $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
           $balloon.BalloonTipText = 'VPN Connection Failed. Retrying in 60 seconds.'
           $balloon.ShowBalloonTip(5000)
		   start-sleep -seconds 57
       }
       elseif($global:retry -ge 3)
       {
           $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error 
           $balloon.BalloonTipText = 'VPN connection failed for 3 times in a row. Terminating PowerShell Script. Verify your credentials.'
           $balloon.ShowBalloonTip(5000)
           exit
       }

       $global:retry++
       Start-Process -FilePath .\connect.bat -Wait -WindowStyle Minimized
    }
    elseif(select-string -pattern "state: Reconnecting" -InputObject $OutputStatus)
    {
       if(($global:reconnect%10) -eq 0)
       {
           $balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
           $balloon.BalloonTipText = 'Connection lost. Trying to reconnect.'
           $balloon.ShowBalloonTip(5000)
       }

       $global:reconnect++
    }

	start-sleep -seconds 3
}