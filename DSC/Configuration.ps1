configuration StandupForest 
{ 
   param 
   ( 
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCredentials,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30
    ) 
    
    Import-DscResource -ModuleName xActiveDirectory, xStorage, xNetworking, PSDesiredStateConfiguration, xPendingReboot
    [System.Management.Automation.PSCredential]$DomainCredentials = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($AdminCredentials.UserName)", $AdminCredentials.Password)
    $Interface = Get-NetAdapter | Where Name -Like "Ethernet*" | Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)

    Node localhost
    {
        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $true
        }

	    WindowsFeature DNS 
        { 
            Ensure = "Present" 
            Name = "DNS"		
        }

        Script EnableDNSDiags
	    {
      	    SetScript = { 
		        Set-DnsServerDiagnostics -All $true
                Write-Verbose -Verbose "Enabling DNS client diagnostics" 
            }
            GetScript =  { @{} }
            TestScript = { $false }
	        DependsOn = "[WindowsFeature]DNS"
        }

	    WindowsFeature DnsTools
	    {
	        Ensure = "Present"
            Name = "RSAT-DNS-Server"
            DependsOn = "[WindowsFeature]DNS"
	    }

        xDnsServerAddress DnsServerAddress 
        { 
            Address        = '127.0.0.1' 
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
	        DependsOn = "[WindowsFeature]DNS"
        }

        xWaitforDisk Disk2
        {
            DiskNumber = 2
            RetryIntervalSec =$RetryIntervalSec
            RetryCount = $RetryCount
        }

        xDisk DataDisk {
            DiskNumber = 2
            DriveLetter = "F"
            DependsOn = "[xWaitForDisk]Disk2"
        }

        WindowsFeature ADDSInstall 
        {
            Ensure = "Present"
            Name = "AD-Domain-Services"
	        DependsOn="[WindowsFeature]DNS"
        }

        WindowsFeature ADDSTools
        {
            Ensure = "Present"
            Name = "RSAT-ADDS-Tools"
            DependsOn = "[WindowsFeature]ADDSInstall"
        }

        WindowsFeature ADDSAdminCenter
        {
            Ensure = "Present"
            Name = "RSAT-AD-AdminCenter"
            DependsOn = "[WindowsFeature]ADDSInstall"
        }

        xADDomain NewForest
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainCredentials
            SafemodeAdministratorPassword = $DomainCredentials
            DatabasePath = "F:\NTDS"
            LogPath = "F:\NTDS"
            SysvolPath = "F:\SYSVOL"
	        DependsOn = "[xDisk]DataDisk"
        } 
   }
}

configuration DomainJoin 
{ 
   param 
    ( 
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [PSCredential]$AdminCredentials
    ) 
    
    Import-DscResource -ModuleName xActiveDirectory, xComputerManagement

    $DomainCredentials = New-Object System.Management.Automation.PSCredential ("$DomainName\$($AdminCredentials.UserName)", $AdminCredentials.Password)
   
    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        WindowsFeature ADPowerShell
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        } 

        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCredentials
            DependsOn = "[WindowsFeature]ADPowerShell" 
        }
   }
}

configuration Gateway
{
   param 
    ( 
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [PSCredential]$AdminCredentials
    ) 

    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
            ConfigurationMode = "ApplyOnly"
        }

        DomainJoin DomainJoin
        {
            DomainName = $DomainName 
            AdminCredentials = $AdminCredentials 
        }

        WindowsFeature RDS-Gateway
        {
            Ensure = "Present"
            Name = "RDS-Gateway"
        }

        WindowsFeature RDS-Web-Access
        {
            Ensure = "Present"
            Name = "RDS-Web-Access"
        }
    }
}

configuration SessionHost
{
    param 
    ( 
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [PSCredential]$AdminCredentials
    ) 

    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
            ConfigurationMode = "ApplyOnly"
        }

        DomainJoin DomainJoin
        {
            DomainName = $DomainName 
            AdminCredentials = $AdminCredentials 
        }

        WindowsFeature RDS-RD-Server
        {
            Ensure = "Present"
            Name = "RDS-RD-Server"
        }
    }
}

configuration RDInitialDeployment
{
   param 
    ( 
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [PSCredential]$AdminCredentials,

        # Connection Broker Server name
        [String]$ConnectionBroker,
        
        # Web Access Server name
        [String]$WebAccess,

        # Gateway external FQDN
        [String]$ExternalFQDN,
        
        # RD Session Host count and naming prefix
        [Int]$numberOfRdshInstances = 1,
        [String]$sessionHostNamingPrefix = "SessionHost-",

        # Initial Collection Name
        [String]$CollectionName,

        # Initial Collection Description
        [String]$CollectionDescription
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration -ModuleVersion 1.1
    Import-DscResource -ModuleName xActiveDirectory, xComputerManagement, xRemoteDesktopSessionHost
   
    $localhost = [System.Net.Dns]::GetHostByName((hostname)).HostName

    $UserName = $AdminCredentials.UserName -split '\\' | select -last 1
    $DomainCredentials = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $AdminCredentials.Password)

    if (-not $ConnectionBroker) { $ConnectionBroker = $localhost }
    if (-not $WebAccess) { $WebAccess = $localhost }

    if ($sessionHostNamingPrefix)
    { 
        $sessionHosts = @( 0..($numberOfRdshInstances-1) | % { "$sessionHostNamingPrefix$_.$domainname"} )
    }
    else
    {
        $sessionHosts = @( $localhost )
    }

    if (-not $CollectionName)         { $CollectionName = "Initial Collection" }
    if (-not $CollectionDescription)  { $CollectionDescription = "An initial collection setup in Azure." }

    Node localhost
    {
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
            ConfigurationMode = "ApplyOnly"
        }

        DomainJoin DomainJoin
        {
            DomainName = $DomainName 
            AdminCredentials = $AdminCredentials 
        }

        WindowsFeature RSAT-RDS-Tools
        {
            Ensure = "Present"
            Name = "RSAT-RDS-Tools"
            IncludeAllSubFeature = $true
        }

        Registry RdmsEnableUILog
        {
            Ensure = "Present"
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDMS"
            ValueName = "EnableUILog"
            ValueType = "Dword"
            ValueData = "1"
        }
 
        Registry EnableDeploymentUILog
        {
            Ensure = "Present"
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDMS"
            ValueName = "EnableDeploymentUILog"
            ValueType = "Dword"
            ValueData = "1"
        }
 
        Registry EnableTraceLog
        {
            Ensure = "Present"
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDMS"
            ValueName = "EnableTraceLog"
            ValueType = "Dword"
            ValueData = "1"
        }
 
        Registry EnableTraceToFile
        {
            Ensure = "Present"
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDMS"
            ValueName = "EnableTraceToFile"
            ValueType = "Dword"
            ValueData = "1"
        }

        WindowsFeature RDS-Licensing
        {
            Ensure = "Present"
            Name = "RDS-Licensing"
        }

        xRDSessionDeployment Deployment
        {
            DependsOn = "[DomainJoin]DomainJoin"

            ConnectionBroker = $ConnectionBroker
            WebAccessServer  = $WebAccess

            SessionHosts     = $SessionHosts

            PsDscRunAsCredential = $DomainCredentials
        }

        xRDServer AddLicenseServer
        {
            DependsOn = "[xRDSessionDeployment]Deployment"
            
            Role    = 'RDS-Licensing'
            Server  = $ConnectionBroker

            PsDscRunAsCredential = $DomainCredentials
        }

        xRDLicenseConfiguration LicenseConfiguration
        {
            DependsOn = "[xRDServer]AddLicenseServer"

            ConnectionBroker = $ConnectionBroker
            LicenseServers   = @( $ConnectionBroker )

            LicenseMode = 'PerUser'

            PsDscRunAsCredential = $DomainCredentials
        }


        xRDServer AddGatewayServer
        {
            DependsOn = "[xRDLicenseConfiguration]LicenseConfiguration"
            
            Role    = 'RDS-Gateway'
            Server  = $WebAccess

            GatewayExternalFqdn = $ExternalFQDN

            PsDscRunAsCredential = $DomainCredentials
        }

        xRDGatewayConfiguration GatewayConfiguration
        {
            DependsOn = "[xRDServer]AddGatewayServer"

            ConnectionBroker = $ConnectionBroker
            GatewayServer    = $WebAccess

            ExternalFqdn = $ExternalFQDN

            GatewayMode = 'Custom'
            LogonMethod = 'Password'

            UseCachedCredentials = $true
            BypassLocal = $false

            PsDscRunAsCredential = $DomainCredentials
        }
        
        xRDSessionCollection InitialCollection
        {
            DependsOn = "[xRDGatewayConfiguration]GatewayConfiguration"

            ConnectionBroker = $ConnectionBroker

            CollectionName = $CollectionName
            CollectionDescription = $CollectionDescription
            
            SessionHosts = $SessionHosts

            PsDscRunAsCredential = $DomainCredentials
        }
    }
}