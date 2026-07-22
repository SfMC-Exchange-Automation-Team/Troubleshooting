@{
    CustomerName = 'Contoso'
    Environment  = 'Production'

    RunRoot = '\\central-share\ExchangeCU\Runs'

    StageAwareness = @{
        CurrentStage = 'SopAnalysis'
        StageOrder = @(
            'SopAnalysis'
            'UpdateInventory'
            'DagDiscovery'
            'PreCheck'
            'Maintenance'
            'PackagePrep'
            'Install'
            'PostCheck'
            'Rollback'
            'Report'
        )
    }

    SopAnalysis = @{
        SopName = 'Exchange Server 2019 CU DAG Patching SOP'
        SopVersion = 'Current'
        Sources = @(
            @{
                Name = 'Current CU15 SOP'
                Type = 'SOP'
                Path = '\\ams\amsresource\msg_dfs\Software\'
            }
            @{
                Name = 'EPO patching sync notes'
                Type = 'MeetingNotes'
                Path = ''
            }
        )
        RiskThresholds = @{
            BlockOnCritical = $true
            WarnOnHigh = $true
        }
    }

    Package = @{
        CuIsoPath = ''
        ExpectedIsoHash = ''
        ExtractRoot = 'D:\ExchangeCU\Media'
    }

    Services = @{
        SplunkForwarderName = 'splunkForwarder'
        CrowdStrikeServiceNames = @('CSFalconService')
    }

    LoadBalancer = @{
        Mode = 'None'
        AdapterScriptPath = ''
    }

    Inventory = @{
        TargetServers = @()
        IncludeHotFixInventory = $true
        IncludeSetupLogEvidence = $true
    }
}
