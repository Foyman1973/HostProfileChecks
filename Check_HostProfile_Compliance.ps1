<#        
	.SYNOPSIS
	 A brief summary of the commands in the file.

	.DESCRIPTION
	A detailed description of the commands in the file.

	.NOTES
	========================================================================
		 Windows PowerShell Source File 
		 
		 NAME:Check_HostProfile_Compliance.ps1 
		 
		 AUTHOR: Jason Foy , DaVita Inc.
		 DATE  : 19-May-2021
		 
		 COMMENT: 
		 
	==========================================================================
#>
$error.Clear()
Clear-Host
# ==============================================================================================
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
function Get-PowerCLI{
	$pCLIpresent=$false
	Get-Module -Name VMware.VimAutomation.Core -ListAvailable | Import-Module -ErrorAction SilentlyContinue
	try{$pCLIpresent=((Get-Module VMware.VimAutomation.Core).Version.Major -ge 6)}
	catch{}
	return $pCLIpresent
}
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
function Exit-Script{
	Write-Host "Script Exit Requested, Exiting..."
	Stop-Transcript
	exit
}
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

$Version = "2021.5.1.11"
$ScriptName = $MyInvocation.MyCommand.Name
$scriptPath = Split-Path $MyInvocation.MyCommand.Path
$CompName = (Get-Content env:computername).ToUpper()
$userName = ($env:UserName).ToUpper()
$userDomain = ($env:UserDomain).ToUpper()
$StartTime = Get-Date
$Date = Get-Date -Format g
$dateSerial = Get-Date -Format yyyyMMddhhmmss
$ReportFolder = Join-Path -Path $scriptPath -ChildPath "Reports"
$ReportFile = Join-Path -Path $ReportFolder -ChildPath "$dateSerial-ProfileCompliance.html"
$logsfolder = Join-Path -Path $scriptPath -ChildPath "Logs"
$traceFile = Join-Path -Path $logsfolder -ChildPath "$ScriptName.log"
$configFile = Join-Path -Path $scriptPath -ChildPath "config.xml"
Start-Transcript -Force -LiteralPath $traceFile
Write-Host "Checking PowerCLI Snap-in..."
if(!(Get-PowerCLI)){Write-Host "* * * * No PowerCLI Installed or version too old. * * * *" -ForegroundColor Red;Exit-Script}
if(!(Test-Path $ReportFolder)){New-Item -Path $ReportFolder -ItemType Directory|Out-Null}
if(!(Test-Path $logsfolder)){New-Item -Path $logsfolder -ItemType Directory|Out-Null}
if(!(Test-Path $configFile)){Write-Host "! ! ! Missing CONFIG.XML file ! ! !";Exit-Script}
[xml]$XMLfile = Get-Content $configFile -Encoding UTF8
$RequiredConfigVersion = "1"
if($XMLFile.TagData.Config.Version -lt $RequiredConfigVersion){Write-Host "Config version is too old!";Exit-Script}
$DEV_MODE=$false;if($XMLFile.TagData.Config.DevMode.value -eq "TRUE"){$DEV_MODE=$true}
$reportTitle = $($XMLFile.TagData.Config.ReportTitle.value)
$DoReporting=$false;if($XMLfile.TagData.Config.DoReporting.value -eq "TRUE"){$DoReporting=$true}
$sendMail=$false;if($XMLfile.TagData.Config.SendMail.value -eq "TRUE"){$sendMail=$true}
if($DEV_MODE){
	$vCenterFile = $XMLFile.TagData.Config.vCenterList_TEST.value
	$FROM = $XMLFile.TagData.Config.FROM_TEST.value
	$TO = $XMLFile.TagData.Config.TO_TEST.value
	$reportTitle = "DEV $reportTitle"
	$DebugPreference = "Continue"
}
else{
	$vCenterFile = $XMLFile.TagData.Config.vCenterList.value
	$FROM = $XMLFile.TagData.Config.FROM.value
	$TO = $XMLFile.TagData.Config.TO.value
	$DebugPreference = "SilentlyContinue"
}
$SMTP = $XMLFile.TagData.Config.SMTP.value
$subject = "$reportTitle $(Get-Date -Format yyyy-MMM-dd)"
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
Write-Host `t`t"$scriptName v$Version"
Write-Host `t`t"Started $Date"
Write-Host ""
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
if(Test-Path $vCenterFile){
	Write-Host "Importing vCenter information..." -ForegroundColor Cyan
	[array]$vCenterList = Import-Csv $vCenterFile -Delimiter ","
	Write-Host "vCenter Instances to Process:" $vCenterList.Count
}
else{Write-Host "Invalid or missing vCenter List file!" -ForegroundColor Red;Exit-Script}
$reportColumns = @('Name','vCenter','Section','Issue')
$complianceReport = @()
$profileReport = @()
$noProfileReport = @()
$profileColumns = @('Name','vCenter')
$hostCount=$vCenterCount=0
$v = 1
$noProfileCount = 0
$vCenterList|ForEach-Object{
	$thisvCenterName = $_.Name
	Write-Progress -Id 999 -Activity "$StartTime - v$Version - Processing vCenter $thisvCenterName " -CurrentOperation "vCenter $v of $($vCenterList.Count)" -PercentComplete ($v/$($vCenterList.Count)*100);$v++
	$vConn=""
	Write-Host "Connecting vCenter $thisvCenterName" -ForegroundColor Yellow
	$vConn = Connect-VIServer $thisvCenterName -Credential (New-Object System.Management.Automation.PSCredential $_.ADMIN, (ConvertTo-SecureString $_.HASH2)) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
	if($vConn){
		$vCenterCount++
		Write-Host "Gathering Host List..." -ForegroundColor Cyan
		$hostList = Get-VMHost|Where-Object{$_.ConnectionState -match "Connected|Maintenance"}|Sort-Object Name
		if($hostList){
			$hostCount += $hostList.Count
			Write-Host "Checking for Compliance Issues..."
			$i=1
			$complianceFailures = foreach($esxiHost in $hostList){
				Write-Progress -Id 998 -ParentId 999 -Activity "Processing Host $($esxiHost.Name) " -CurrentOperation "Host $i of $($hostList.Count)" -PercentComplete ($i/$($hostList.Count)*100);$i++
				try {
					$esxiHost|Test-VMHostProfileCompliance -UseCache -ErrorAction 'Stop'
				}				
				catch {
					if($error[$($error.count-1)].FullyQualifiedErrorId -match '.TryGetHostProfileByVMHost_NoAssociatedProfile.'){
						Write-Debug -Message "No Profile Associated"
						$row = ""|Select-Object $profileColumns
						$row.Name = $esxiHost.Name
						$row.vCenter = $thisvCenterName
						$noProfileReport += $row
						$noProfileCount++
					}
					else{Write-Debug -Message "SOME OTHER ERROR OCCURRED"}
				}
			}
			if($complianceFailures){
				Write-Host "Adding Compliance failures to the report..."
				$complianceFailures|ForEach-Object{
					if($_.IncomplianceElementList.description -is [array]){$thisIssue = ($_.IncomplianceElementList.description)|Out-String}
					else{$thisIssue = $_.IncomplianceElementList.description}
					if($_.IncomplianceElementList.PropertyName -is [array]){$thisSection = ($_.IncomplianceElementList.PropertyName)|Out-String}
					else{$thisSection = $_.IncomplianceElementList.PropertyName}
					$24hourCheck = $((Get-Date)-(Get-Date($_.ExtensionData.CheckTime))).Days
					if($24hourCheck -gt 1){
						$profileName = $_.VMHostProfile
						$row = ""|Select-Object $profileColumns
						$row.Name = $profileName
						$row.vCenter = $thisvCenterName
						$profileReport += $row
					}
					else{$profileName = $null}
					$row=""|Select-Object $reportColumns
					$row.Name = $_.VMHost
					$row.vCenter = $thisvCenterName
					$row.Issue = $thisIssue
					$row.Section = $thisSection
					$complianceReport += $row
				}

			}
			else{Write-Debug -Message "No Compliance Issues found for $thisvCenterName"}

		}
		else{Write-Debug -Message "No Hosts Found for $thisvCenterName"}
		Write-Host "Disconnecting vCenter $thisvCenterName..." -ForegroundColor Cyan
		Disconnect-VIServer $vConn -Confirm:$false
	}
}

# Build Reporting and Send Mail
$profileReport = $profileReport|Select-Object -Unique Name,vCenter
$unexpectedErrorCount = $error.count - $noProfileCount
Write-Debug -Message "Unexpected Error Count: $unexpectedErrorCount"
if($sendMail -or ($unexpectedErrorCount -gt 0)){
	Write-Host "Building Report..."

	if($complianceReport.count -gt 0){
		[string]$complianceHTML = $complianceReport|ConvertTo-Html -PreContent "<h4> Compliance Failures </h4>" -PostContent "<br><hr><br>" -Fragment
	}
	else{[string]$complianceHTML = "<h4> No Compliance issues found </h4><hr><br>"}
	if($profileReport.count -gt 0){
		[string]$profileHTML = $profileReport|ConvertTo-Html -PreContent "<h4> Profiles missing Scheduled Checks </h4>" -PostContent "<br><hr><br>" -Fragment
	}
	else{[string]$profileHTML = "<h4> All Profile checks were up to date </h4><hr><br>"}
	if($noProfileReport.count -gt 0){
		[string]$noProfileHTML = $noProfileReport|ConvertTo-Html -PreContent  "<h4> Hosts with No Host Profile </h4>" -PostContent "<br><hr><br>" -Fragment
	}
	else{[string]$noProfileHTML = "<h4> All Host have a host profile </h4><hr><br>"}
	if($unexpectedErrorCount -gt 0){
		$errorReport = $error|Select-Object Exception,@{n="Position";e={$_.InvocationInfo.PositionMessage}}
		[string]$errorHTML = $errorReport|ConvertTo-Html -PreContent "<h4> Errors </h4>" -PostContent "<br><hr><br>" -Fragment
		[string]$headFormat = $XMLfile.TagData.Config.TableFormats.Red.value
	}
	else{
		[string]$errorHTML = "<h4> No Errors </h4>"
		[string]$headFormat = $XMLfile.TagData.Config.TableFormats.Blue.value
	}
	[string]$headHTML = $headFormat
	[string]$bodyHTML = "<h3> $reportTitle </h3>"
	[string]$footerHTML =  "<hr><span style=""background-color:White; font-weight:normal; font-size:10px;color:Orange;align:right""><blockquote>v$Version - $CompName : $userName @ $userDomain - $StartTime - Runtime (min): $([math]::Round(($stopwatch.Elapsed.TotalMinutes),1))</blockquote></span>"

	[string]$postHTML = $noProfileHTML + $profileHTML + $complianceHTML + $errorHTML + $footerHTML

	$statsReport = [ordered]@{
		"vCenters"= "$vCenterCount of $($vCenterList.Count)";
		"Hosts Checked" = $hostCount;
		"Compliance Issues"= $complianceReport.Count
	}
	$statsReport = $statsReport.GetEnumerator()|Select-Object @{n="Summary";e={$_.Name}},Value
	[string]$reportHTML = $statsReport.GetEnumerator()|ConvertTo-Html -Head $headHTML -Body $bodyHTML -postcontent $postHTML
	Write-Host "Emailing Report..."
	Send-MailMessage -Subject $subject -From $FROM -To $TO -Body $reportHTML -BodyAsHtml -SmtpServer $SMTP

	if($DoReporting){
		Write-Host "Writing report to disk"
		$reportHTML|Out-File -FilePath $ReportFile -Confirm:$false
	}	

}
# ==============================================================================================
# ==============================================================================================
$stopwatch.Stop()
$Elapsed = [math]::Round(($stopwatch.Elapsed.TotalMinutes),1)
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ("="*80) -ForegroundColor DarkGreen
Write-Host ""
Write-Host "Script Completed in $Elapsed minutes(s)"
Write-Host ""
Write-Host ("="*80) -ForegroundColor DarkGreen
Exit-Script
