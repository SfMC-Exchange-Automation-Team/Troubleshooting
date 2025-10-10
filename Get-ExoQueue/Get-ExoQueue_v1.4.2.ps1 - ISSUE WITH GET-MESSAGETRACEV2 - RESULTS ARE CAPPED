<#
    DISCLAIMER:
    This script is provided "as is" with no warranties or guarantees, and confers no rights. 
    This script is not officially supported by Microsoft. Use of the script is at your own risk. 
    Microsoft and the author disclaim any liability for any damages or loss resulting from the use of this script.
    The script is intended for informational purposes only and has been provided as a courtesy. 
    Users should exercise caution and test it thoroughly before use in any non-testing environment.
#>

<#

.SYNOPSIS
    Get the Exchange Online message queue for the past X minutes, hours, or days.
.DESCRIPTION
    Get the Exchange Online message queue for the past X minutes, hours, or days.     The function uses the Get-MessageTraceV2 cmdlet to search for messages in the queue. 
    The function can output the results to a CSV, XML, or GridView.
.PARAMETER JournalOnly
    Search for messages sent to a specific journal address. 
    The journal address is saved in the registry for future use of the cmdlet.
.PARAMETER JournalExclude
    Exclude messages sent to a specific journal address. 
    The journal address is saved in the registry for future use of the cmdlet.
.PARAMETER AgeMinutes
    The number of minutes to search for messages in the queue.
.PARAMETER AgeHours
    The number of hours to search for messages in the queue.
.PARAMETER AgeDays
    The number of days to search for messages in the queue.
.PARAMETER TopSenders
    The number of top senders to display in the output.
.PARAMETER TopRecipients
    The number of top recipients to display in the output.
.PARAMETER Output
    The output format for the results. Options are CSV, XML, or GridView.
.NOTES
    File Name      : Get-ExoQueue.ps1
    Author         : cuhaafke
    Version history
    3/8/24   | 1.0  -  Initial release - pending feedback and some features
    3/12/24  | 1.1  -  Finished CSV Output 
                       Modifications to Gridview. To include, increased the output to include all properties, and removed terminal output by removing -Passthru
                       Removed Journal results from default search
                       Made more efficient by combining searches using commas for the StatusTypes and removing an redundant search set. 
                       Prevented user from combining the Age parameters
                       Minor updates to formatting and comments. 
    3/13/24  | 1.1.1 - Added cmdlet binding
    4/1/24   | 1.1.4 - Added Parameters Used to Log output to help understand why numbers may jump around while troubleshooting. Ex: Parameters Used: AgeMinutes=30, JournalOnly=False, Output=GridView
                       Changed the smarsh param to JournalOnly
    4/4/24   | 1.1.5 - Adding Registry logic for JournalOnly
                       Removing plan to implement the following params due to search filter options in output
                         - #[switch]$RecipientDomain
                         - #[switch]$ToIP
    4/24/24  | 1.2   - Completed implementation of JournalOnly and JournalExclude
                        Added JournalExclude parameter
                        Added logic to check if the JournalSmtp value already exists in the registry
                        Added logic to check if the JournalSmtp value is a valid email address
                        Corrected the JournalSmtp value to be a global variable, breaking the SenderAddress filter
             | 1.2.1 - Removed xml import prompt
     5/31/24 | 1.3   - Removed GettingStatus from search after speaking with PG - Produced too many false positives
    11/14/24 | 1.3.1 - Changed the results logic to only show unique results. This will remove the multiple recipient messages from the results. 
     4/14/25 | 1.4 -   Major update:
                        - Replaced Get-MessageTrace with Get-MessageTraceV2 for improved performance and accuracy.
                        - Removed pagination logic; simplified query execution.
                        - Changed output directory from Desktop to C:\Temp\ExoQueueResults\<Date>.
                        - Added confirmation prompts for AgeDays and AgeHours to prevent timeouts in large environments.
                        - Enhanced connection handling with Yes/No prompt for Exchange Online connection.
                        - Improved logging and output handling; log files now stored in C:\Temp\ExoQueueResults\<Date>.
                        - Added auto-import of XML results into global variables for easier analysis.
                        - General code cleanup and improved error handling.
    8/14/25 | 1.4.1 - Update changelog for 1.4, cleaned up syntax, and corrected some entries for $allresults to use $uniqueresults. 
    8/21/25 | 1.4.2 - Added IncludeDelivered parameter to allow testing/demos without having to modify the Delivery Status. Cirrected a few more issues with $allresults to use $uniqueresults.
                        
                        
#>

function global:Get-ExoQueue {
    [CmdletBinding()]
    param(
        [switch]$JournalOnly,
        [switch]$JournalExclude,
        
        [ValidateRange(1, 59)]
        [int]$AgeMinutes,

        [ValidateRange(1, 25)]
        [int]$TopSenders,

        [ValidateRange(1, 25)]
        [int]$TopRecipients,

        [ValidateSet("CSV","XML","GridView")]
        [string]$Output,
        
        #[string]$LogPath = "C:\Temp\ExoQueueLog.txt",  ### Not implemented yet ###

        [ValidateRange(0,24)]
        [int]$AgeHours = 0,

        [ValidateRange(0,10)]
        [int]$AgeDays = 0,

        [switch]$IncludeDelivered
    )
    ########################
    ### Param Validation ###
    ########################

    # Only allow one of the following parameters to be used: AgeMinutes, AgeHours, AgeDays
    if (($AgeMinutes -and $AgeHours) -or ($AgeMinutes -and $AgeDays) -or ($AgeHours -and $AgeDays)) {
        Write-Error "Error: Only one of the following parameters can be used: AgeMinutes, AgeHours, AgeDays." -Category InvalidArgument
        return
    }

    # Check if JournalOnly and JournalExclude are both set
    if ($JournalOnly -and $JournalExclude) {
        Write-Error "Error: Only one of the following parameters can be used: JournalOnly, JournalExclude." -Category InvalidArgument
        return
    }
    
    # Check if AgeMinutes, AgeHours or AgeDays is specified, default to 30 minutes
    if (-not $AgeDays -and -not $AgeHours -and -not $AgeMinutes) {
        Write-Host "NOTE: " -ForegroundColor Cyan -NoNewline
        Write-Host "-AgeMinutes or -AgeHours not set. Defaulting to 30 minutes."
        $AgeMinutes = 30
    }
    
    # Output tip
    if($Output -like $null){
        Write-Host "NOTE: " -ForegroundColor Cyan -NoNewline
        Write-Host "-Output parameter using default: 'GridView' - CSV and XML are also available." 
        Write-Host " "
        $Output = "GridView"
    }
    

    ########################
    #### Journal Config ####
    ########################

    # if JournalOnly is set, set the JournalSmtp address and save to the registry for later use
    if($JournalOnly -eq $true -or $JournalExclude -eq $true) {
    
        # Create the registry key if it doesn't exist
        if (-not (Test-Path "HKCU:\Software\Microsoft\Exchange\ExoQueue")) {
            try {
                New-Item -Path "HKCU:\Software\Microsoft\Exchange\ExoQueue" | Out-Null    
            }
            catch {
                Write-Error "Unable to create the registry key. Please ensure you have the necessary permissions." -Category PermissionDenied
                Exit
            }           
        }
    
        # Check if the JournalSmtp value already exists and matches the input
        
        $existingValue = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Exchange\ExoQueue" -Name "JournalSmtp" -ErrorAction SilentlyContinue).JournalSmtp
        if ($existingValue -ne $null) {
            Write-Host "NOTE: " -ForegroundColor Cyan -NoNewline 
            Write-Host "The Journal SMTP address is already set to " -NoNewline
            Write-Host "$existingValue" -ForegroundColor Cyan -NoNewline
            Write-Host " in the registry. To change it, remove the registry key: HKCU:\Software\Microsoft\Exchange\ExoQueue."
            $global:JournalSmtp = $existingValue
        } else {
            Write-Host "Enter the Journal address to search for. Example: Journal@contoso.com" -ForegroundColor Yellow
            $JournalSmtp = Read-Host "Journal Address"
            # check if the input is a valid email address
            if ($JournalSmtp -notmatch "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$") {
                Write-Error "Error: Invalid email address. Please try again." -Category InvalidData
                return
            }
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Exchange\ExoQueue" -Name "JournalSmtp" -Value $JournalSmtp
            Write-Host "JournalSmtp value set to $JournalSmtp in the registry. This will be saved for future use of this cmdlet." -ForegroundColor Cyan
        }
    }
    

    # $JournalDomain = "contoso.Journal.cloud" - Not currently used. May be removed if JournalSmtp above works

    
    # Validate EXO connection by testing a cmdlet 
    try{
    $test = Get-Mailbox -ResultSize 1 -WarningAction SilentlyContinue -ErrorAction Stop
    }
    Catch{
        # yes or no prompt to connect to Exchange Online
        Write-Host "You are not connected to Exchange Online. Do you want to connect now? (Y/N) - Default is Yes." -ForegroundColor Yellow
        $Connect = Read-Host
        if($Connect -ne "Y" -and $Connect -ne "") {
            Write-Host "Search cancelled.."
            Exit
        }
        Write-Host "Connecting to Exchange Online.." -ForegroundColor Yellow
        Write-Host "If the cmdlet stalls, there may be a MFA prompt in the background."
        try {
            Connect-ExchangeOnline -ShowProgress $false
        }
        catch {
            Write-Host "Unable to connect to Exchange Online. Please try again." -ForegroundColor Red
            #close window in 5 seconds with countdown
            Write-Host "Closing in 5 seconds.." -ForegroundColor Yellow
            for ($i = 5; $i -gt 0; $i--) {
                Write-Host "$i"
                Start-Sleep -Seconds 1
            }
            Exit
        }
    }

    # Check to see if the user is connected to Exchange Online
    if(-not (Get-Module -Name ExchangeOnlineManagement)) {
        Write-Host "Unable to connect to Exchange Online. Please try again." -ForegroundColor Red
        Exit
    }

    ######################
    #### Begin Output ####
    ######################

    Write-Host "DISCLAIMER: " -foregroundColor Yellow -noNewline
    Write-Host "THIS IS AN APPROXIMATION OF THE QUEUE USING MESSAGE TRACE DATA. IT IS NOT AN EXACT REPRESENTATION OF THE QUEUE." 
    Write-Host " "

    # Timeout warnings
    if($AgeDays){
        Write-Warning "Using the -AgeDays parameter WILL timeout in large environments and should only be used in a low-volume, or test environments. Try using -AgeMinutes instead."
        Write-Host "Are you sure you want to continue? (Y/N) - Default is No." -ForegroundColor Yellow
        $Continue = Read-Host
        if($Continue -ne "Y") {
            Write-Host "Search cancelled.."
            Exit
        }
    }
    # AgeHours warning disabled due to improved performance of Get-MessageTraceV2
    <#
    if($AgeHours){
        Write-Warning "Using the -AgeHours parameter MAY timeout in large environments and should only be used for extended delays. Try using -AgeMinutes instead."
        Write-Host "Are you sure you want to continue? (Y/N) - Default is No." -ForegroundColor Yellow
        $Continue = Read-Host
        if($Continue -ne "Y") {
            Write-Host "Search cancelled.."
            Exit
        }
    }
    #>

    # Age entry output to terminal. Days, Hours, Minutes have multiple outputs to provide pluralization
    if($AgeDays -eq 1) {
        Write-Host "Getting the message queue for the past $AgeDays day. Please wait.." -ForegroundColor Cyan
    }
    elseif($AgeDays -gt 1) {
        Write-Host "Getting the message queue for the past $AgeDays days. Please wait.." -ForegroundColor Cyan
    }
    if($AgeHours -eq 1){
        Write-Host "Getting the message queue for the past $AgeHours hour. Please wait.." -ForegroundColor Cyan
    }
    elseif($AgeHours -gt 1) {
        Write-Host "Getting the message queue for the past $AgeHours hours. If the queue is large and there is a timeout, attempt to reduce the -AgeHours setting. Please wait.." -ForegroundColor Cyan
    }
    if($AgeMinutes -eq 1){
        Write-Host "Getting the message queue for the past $AgeMinutes minute. Please wait.." -ForegroundColor Cyan
    }
    elseif($AgeMinutes -gt 1) {
        Write-Host "Getting the message queue for the past $AgeMinutes minutes. If the queue is large and there is a timeout, attempt to reduce the -AgeMinutes setting. Please wait.." -ForegroundColor Cyan
    }
    
    # Translate Age into start date
    if($AgeHours -ne 0){
        $startDate = (Get-Date).AddHours(-$AgeHours)
    }
    elseif($AgeDays -ne 0){
        $startDate = (Get-Date).AddDays(-$AgeDays)
    }
    elseif($AgeMinutes -ne 0){
        $startDate = (Get-Date).AddMinutes(-$AgeMinutes)
    }

   # Wait-Debugger
    ######################
    ### Search section ###
    ######################
    
    $endDate = Get-Date
    # $Status = @("Pending")   # ENABLE THIS FOR PRODUCTION USE 
    if($IncludeDelivered -eq $true) {
            $Status = @("Pending", "Delivered")
        }
    else {
        $Status = @("Pending")
    }
    $allResults = @()

    # Search for Pending messages

        if($JournalOnly -eq $true) {
            try {
                $PendingResults = Get-MessageTraceV2 -StartDate $startDate -EndDate $endDate -Status $Status -SenderAddress $JournalSmtp -ErrorAction Stop
            }
            catch {
                Write-Host "An error occurred: $_." -ForegroundColor Red
                Exit
            }
        }
        if($JournalExclude -eq $true) {
            try {
               # Wait-Debugger
                $PendingResults = Get-MessageTraceV2 -StartDate $startDate -EndDate $endDate -Status $Status | Where-Object {$_.SenderAddress -notlike $JournalSmtp} -ErrorAction Stop
            }
            catch {
                Write-Host "An error occurred: $_." -ForegroundColor Red
                Exit
            }
        }
        
        if($JournalOnly -eq $false -and $JournalExclude -eq $false) {
            try {
                $PendingResults = Get-MessageTraceV2 -StartDate $startDate -EndDate $endDate -Status $Status -ErrorAction Stop  
                }   
            catch {
                Write-Host "An error occurred: $_." -ForegroundColor Red
                Exit
            }
        }
        
     
        if ($PendingResults.Count -eq 0) {
            Write-Host "No messages found in the queue."
            break
        }
        $allResults += $PendingResults
  #  }

    # Remove results with multiple recipients
    $UniqueResults = $allResults | Sort-Object -Property MessageId -Unique
    
    # Count the number of messages in the queue
    Write-Host "Number of messages in the queue:" $UniqueResults.Count
    Write-Host " "
    
    ######################
    ### Output Section ###
    ######################
    <#  CHANGED fromc:\TEMP to Desktop in version 1.4
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    # add folder to path using today's date
    $DesktopPath = "$DesktopPath\ExoQueueResults\$(Get-Date -Format dd-MMM-yyyy)"
    # Create the folder if it doesn't exist
    if (-not (Test-Path -Path $DesktopPath)) {
        try {
            New-Item -Path $DesktopPath -ItemType Directory | Out-Null    
        }
        catch {
            Write-Error "Unable to create the folder $DesktopPath. Please ensure you have the necessary permissions." -Category PermissionDenied
            Exit
        }
    }
    #>
    # add folder to path using today's date
    $OutputFilePath = "$env:SystemDrive\temp\ExoQueueResults\$(Get-Date -Format dd-MMM-yyyy)"
    # Create the folder if it doesn't exist
    if (-not (Test-Path -Path $OutputFilePath)) {
        try {
            New-Item -Path $OutputFilePath -ItemType Directory | Out-Null    
        }
        catch {
            Write-Error "Unable to create the folder $OutputFilePath. Please ensure you have the necessary permissions." -Category PermissionDenied
            Exit
        }
    }
  
    # Create a log file and add a line with the number of messages in the queue each time the function is run
    $LogPath = "$OutputFilePath\ExoQueueLog--$(Get-Date -Format dd-MMM-yyyy).txt"
    $AgeParam = @()
        if($AgeMinutes -ne 0) { $AgeParam += "AgeMinutes=$AgeMinutes" }
        if($AgeHours -ne 0) { $AgeParam += "AgeHours=$AgeHours" }
        if($AgeDays -ne 0) { $AgeParam += "AgeDays=$AgeDays" }
    $LogEntry = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") - $($UniqueResults.Count) messages in the queue | Parameters Used: $AgeParam, JournalOnly=$JournalOnly, Output=$Output" 
    Add-Content -Path $logPath -Value $logEntry
    Write-Host "Log File:" -ForegroundColor Cyan
    Write-Host "A log file with the number a messages in queue has saved/updated to: " -NoNewline
    Write-Host "$LogPath" -ForegroundColor Cyan
    Write-Host " "

    # GridView Output
    if($Output -like "GridView") {    
        # Top Senders and Recipients
        if($TopSenders -ne 0) {
            $GroupedSenders = $UniqueResults | Group-Object SenderAddress | Select-Object Name, Count
            if($GroupedSenders.Count -ne 0) {
            Write-Host "Top $TopSenders senders:" -ForegroundColor Cyan
            $GroupedSenders | Sort-Object Count -Descending | Select-Object -First $TopSenders | Format-Table -AutoSize
            }
        }
        if($TopRecipients -ne 0) {
            $GroupedRecipients = $UniqueResults | Group-Object RecipientAddress | Select-Object Name, Count  
            if($GroupedRecipients.Count -ne 0) {
            Write-Host "Top $TopRecipients recipients:" -ForegroundColor Cyan
            $GroupedRecipients | Sort-Object Count -Descending | Select-Object -First $TopRecipients | Format-Table -AutoSize
            }
        }
        #>
        Write-Host "Current Queue: (If Gridview window doesn't appear, check for a hidden PowerShell pop-up window)." -ForegroundColor Cyan
        $UniqueResults | select * | Out-GridView -Title "Exchange Online Message Queue"
    }

    # XML Output
    elseif($Output -like "XML") {
        $filePath = "$OutputFilePath\ExoQueue - $(Get-date -Format dd-MMM-yyyy--HHmm).xml"
        $UniqueResults | Export-Clixml -Path $filePath
        if($TopSenders -ne 0) {
            $filePathTS = "$filePath-TopSenders.xml"
            $GroupedRecipients = $UniqueResults | Group-Object SenderAddress | Select-Object -ExpandProperty Group
            $GroupedRecipients | Sort-Object Count -Descending | Select-Object -First $TopSenders | Export-Clixml -Path $filePathTS
            $TopSendersXml = $true
        }
        if($TopRecipients -ne 0) {
            $filePathTR = "$filePath-TopRecipients.xml"
            $GroupedRecipients = $UniqueResults | Group-Object RecipientAddress | Select-Object -ExpandProperty Group
            $GroupedRecipients | Sort-Object Count -Descending | Select-Object -First $TopRecipients | Export-Clixml -Path $filePathTR
            $TopRecipientsXml = $true
        }
        Write-Host "XML File(s):" -ForegroundColor Cyan
        Write-Host "XML file saved to: " -NoNewline
        Write-Host "$filePath" -ForegroundColor Cyan
        Write-Host " "
    }

    # CSV Output
    elseif($Output -like "CSV"){
        $filePath = "$OutputFilePath\ExoQueue - $(Get-date -Format dd-MMM-yyyy--HHmm).csv"
        $UniqueResults | Export-Csv -Path $filePath -NoTypeInformation
        if($TopSenders -ne 0) {
            $filePathTS = "$OutputFilePath\ExoQueue - $(Get-date -Format dd-MMM-yyyy--HHmm)-TopSenders.csv"
            $GroupedRecipients = $UniqueResults | Group-Object SenderAddress | Select-Object -ExpandProperty Group
            $GroupedRecipients | Sort-Object Count -Descending | Select-Object -First $TopSenders | Export-Csv -Path $filePathTS -NoTypeInformation
            Write-Host "CSV file for Top Senders saved to     :  " -NoNewline
            Write-Host "$filePathTS" -ForegroundColor Cyan
        }
        if($TopRecipients -ne 0) {
            $filePathTR = "$OutputFilePath\ExoQueue - $(Get-date -Format dd-MMM-yyyy--HHmm)-TopRecipients.csv"
            $GroupedRecipients = $UniqueResults | Group-Object RecipientAddress | Select-Object -ExpandProperty Group
            $GroupedRecipients | Sort-Object Count -Descending | Select-Object -First $TopRecipients | Export-Csv -Path $filePathTR -NoTypeInformation
            Write-Host "CSV file for Top Recipients saved to  :  " -NoNewline
            Write-Host "$filePathTR" -ForegroundColor Cyan
        }
        Write-Host "CSV file with All Results saved to    :  " -NoNewline
        Write-Host "$filePath" -ForegroundColor Cyan
    }
   
    # Prompt to open the file
    if($filePath -like "*.csv") {
        $OpenFile = Read-Host "Do you want to open the queue csv file for All Results? (Y/N)"
        if($OpenFile -eq "Y") {
            # Specify the path to the Excel executable
            try {
                # Method 1: Check the Registry
                $excelpath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\excel.exe" -ErrorAction Stop).'(default)'
            } 
            catch {
                try {
                    # Method 2: Search Program Files                    
                    $excelpath = Get-Item "C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE"  -ErrorAction Stop
                } 
                catch {
                    Write-Host "Excel executable not found. Please ensure Excel is installed." -ForegroundColor Red
                }
            }

            # Check if the Excel executable exists
            if (Test-Path -Path $excelPath) {
                # If Excel exists, use Start-Process to open the file with Excel
                Start-Process -FilePath $excelPath -ArgumentList "`"$filePath`""
            } 
        }
    }
    if($filePath -like "*.xml") {
       # Write-Host "Do you want to auto-import the XML to a variable? (Y/N) - Default is Yes." -ForegroundColor Yellow
      #  $OpenFile = Read-Host
      #  if($OpenFile -notlike "n" -and $OpenFile -notlike "no") {
            
            $global:QueueXml = Import-Clixml -Path $filePath
            Write-Host "XML Variables:" -ForegroundColor Cyan
            Write-Host "XML file(s) automatically imported. View object using the variable(s) below: " 
            Write-Host "All results     :  " -NoNewline
            Write-Host  "`$QueueXml` " -ForegroundColor Cyan
            if($TopSendersXml -eq $true) {
                $global:TopSendersXml = Import-Clixml -Path $filePathTS
                Write-Host "Top senders     :  " -NoNewline
                Write-Host "`$TopSendersXml` " -ForegroundColor Cyan
            }
            if($TopRecipientsXml -eq $true) {
                $global:TopRecipientsXml = Import-Clixml -Path $filePathTR
                Write-Host "Top recipients  :  " -NoNewline
                Write-Host "`$TopRecipientsXml` " -ForegroundColor Cyan
            }
     #   }
    }
}
