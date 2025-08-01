function global:Get-PAM{
    param(
        $Site = $Site
    )  
    Get-DatabaseAvailabilityGroup $Site* -Status -WarningAction SilentlyContinue | select Name, PrimaryActiveManager
}