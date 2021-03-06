# This module file contains a utility to perform PSWS IIS Endpoint setup
# Module exports Create-PSWSEndpoint function to perform the endpoint setup
#
#	Copyright (c) Microsoft Corporation, 2012
#

# Log supplied data to stdout
#
function Log
{
    param ($data = $(throw "data is a required parameter."))
    
    $data | Out-Host    
}

# Validate supplied configuration to setup the PSWS Endpoint
# Function checks for the existence of PSWS Schema files, IIS config
# Also validate presence of IIS on the target machine
# Backsup existing IIS endpoints and setsup supplied one
#
function ParseCommandLineAndSetupResouce
{
    param (
        $site,
        $path,
        $cfgfile,
        $port,
        $app,
        $applicationPoolIdentityType,
        $svc,
        $mof,
        $dispatch,
        $asax,
        $rbac,
        $dependentBinaries,
        $psFiles,
        $removeSiteFiles = $false)
    
    if (!(Test-Path $cfgfile))
    {        
        throw "ERROR: $cfgfile does not exist"    
    }            
    
    if (!(Test-Path $svc))
    {        
        throw "ERROR: $svc does not exist"    
    }            
    
    if (!(Test-Path $mof))
    {        
        throw "ERROR: $mof does not exist"  
    }   	 
    
    if ($asax -and !(Test-Path $asax))
    {        
        throw "ERROR: $asax does not exist"  
    }   	 
        
    VerifyIISInstall
    
    $appPool = "PSWS"
    
    Log "Delete the App Pool if it exists."
    DeleteAppPool -apppool $appPool
    
    Log "Delete the site if it exists."
    PerformActionOnSite -siteName $site -siteAction delete 
    BackUpIISConfig
    
    if ($removeSiteFiles)
    {
        if(Test-Path $path)
        {
            Remove-Item -Path $path -Recurse -Force
        }
    }
    
    # Create physical path dir if required and copy required files
    if (!(Test-Path $path))
    {
        New-Item -ItemType container -Path $path                
    }                       
    
    ValidateAndCopyFiles -path $path -cfgfile $cfgfile -svc $svc -mof $mof -dispatch $dispatch -rbac $rbac -asax $asax -dependentBinaries $dependentBinaries -psFiles $psFiles
    
    PerformActionOnAllSites stop
    PerformActionOnDefaultAppPool stop
    PerformActionOnDefaultAppPool start
    
    SetupWebSite -site $site -path $path -port $port -app $app -apppool $appPool -applicationPoolIdentityType $applicationPoolIdentityType
}

# Validate if IIS and all required dependencies are installed on the target machine
#
function VerifyIISInstall
{
    if ($script:SrvMgr -eq $null)
    {   
        Log "Checking IIS requirements"        
        
        $iisVersion = (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\InetStp -ErrorAction silentlycontinue).MajorVersion + (Get-ItemProperty HKLM:\SOFTWARE\Microsoft\InetStp -ErrorAction silentlycontinue).MinorVersion
        
        if ($iisVersion -lt 7.0) 
        {
            throw "ERROR: IIS Version detected is $iisVersion , must be running higher than 7.0"            
        }        
        
        $wsRegKey = (Get-ItemProperty hklm:\SYSTEM\CurrentControlSet\Services\W3SVC -ErrorAction silentlycontinue).ImagePath
        if ($wsRegKey -eq $null)
        {
            throw "ERROR: Cannot retrieve W3SVC key. IIS Web Services may not be installed"            
        }        
        
        [System.Reflection.Assembly]::LoadFrom("$env:windir\system32\inetsrv\Microsoft.Web.Administration.dll")
        
        $script:SrvMgr = New-Object Microsoft.Web.Administration.ServerManager -ErrorAction silentlycontinue
        
        if ($script:SrvMgr -eq $null)
        {
            throw "ERROR: Cannot retrieve Microsoft.Web.Administration.ServerManager Object. IIS may not be installed"            
        }
        
        if ((Get-Service w3svc).Status -ne "running")
        {
            throw "ERROR: service W3SVC is not running"
        }        
    }    
}

# Verify if a given IIS Site exists
#
function VerifyIISSiteExists
{
    param ($siteName)
    
    $returnValue = $false
    $siteList = @(& $script:appCmd list site)
    $siteList | % { if ($_.Split('"')[1] -eq $siteName)
        {
            $returnValue = $true}
    }
    return $returnValue
}

# Perform an action (such as stop, start, delete) for a given IIS Site
#
function PerformActionOnSite
{
    param (
        [Parameter(ParameterSetName = 'SiteName', Mandatory = $true, Position = 0)]
        [String]$siteName,
        [Parameter(ParameterSetName = 'Site', Mandatory = $true, Position = 0)]
        [Microsoft.Web.Administration.Site]$site,
        [Parameter(ParameterSetName = 'SiteName', Mandatory = $true, Position = 1)]
        [Parameter(ParameterSetName = 'Site', Mandatory = $true, Position = 1)]
        [String]$siteAction)
    
    [String]$name = $null
    if ($PSCmdlet.ParameterSetName -eq 'SiteName')
    {
        if (-not $siteName)
        {
            throw "ERROR: Site is null or empty"   
        }
        $name = $siteName
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Site')
    {
        if (-not $site)
        {
            throw "ERROR: Site is null or empty"   
        }    
        $name = $site.Name
    }
    else
    {
        throw "ERROR: unknown parameter set name: $($PSCmdLet.ParameterSetName)"
    }
    
    if (VerifyIISSiteExists  $name)
    {
        & $script:appCmd $siteAction site $name
    }
}

# Delete the given IIS Application Pool
# This is required to cleanup any existing conflicting apppools before setting up the endpoint
#
function DeleteAppPool
{
    param (
        $appPool)
    
    Log "Delete $appPool AppPool"    
    & $script:appCmd delete apppool $appPool     
}

# Perform given action(start, stop, delete) on all IIS Sites
#
function PerformActionOnAllSites
{
    param ($action)
    
    foreach ($site in $script:SrvMgr.sites)
    {
        PerformActionOnSite $site $action
    }
}

# Perform given action(start, stop) on the default app pool
#
function PerformActionOnDefaultAppPool
{
    param ($action)
    
    Log "Trying to $action the default app pool"
    $null = & $script:appCmd $action apppool /apppool.name:DefaultAppPool
}

# BackUp all IIS config and Endpoint details
#
function BackUpIISConfig
{
    $dateTimeNow = Get-Date
    $backupID = "PSWSIISSetup_" + $dateTimeNow.Year + "-" + $dateTimeNow.Month + "-" + $dateTimeNow.Day + "-" + $dateTimeNow.Hour + "-" + $dateTimeNow.Minute + "-" + $dateTimeNow.Second
    
    Log "Backing up IIS configuration to $backupID"
    $null = & $script:appCmd add backup $backupID
}   

# Generate an IIS Site Id while setting up the endpoint
# The Site Id will be the max available in IIS config + 1
#
function GenerateSiteID
{
    return ($script:SrvMgr.Sites | % { $_.Id } | Measure-Object -Maximum).Maximum + 1
}

# Validate the PSWS config files supplied and copy to the IIS endpoint in inetpub
#
function ValidateAndCopyFiles
{
    param (
        $path,
        $cfgfile,
        $svc,
        $mof,    
        $dispatch,    
        $rbac,
        $asax,
        $dependentBinaries,
        $psFiles)    
    
    if (!(Test-Path $cfgfile))
    {
        throw "ERROR: $cfgfile does not exist"    
    }
    
    if (!(Test-Path $svc))
    {
        throw "ERROR: $svc does not exist"    
    }
    
    if (!(Test-Path $mof))
    {
        throw "ERROR: $mof does not exist"    
    }
    
    if ($asax -and !(Test-Path $asax))
    {
        throw "ERROR: $asax does not exist"    
    }

    if (!(Test-Path $path))
    {
        New-Item -ItemType container $path        
    }
    
    foreach ($dependentBinary in $dependentBinaries)
    {
        if (!(Test-Path $dependentBinary))
        {					
            throw "ERROR: $dependentBinary does not exist"  
        } 	
    }
    
    # Create the bin folder for deploying custom dependent binaries required by the endpoint
    $binFolderPath = Join-Path $path "bin"
    New-Item -path $binFolderPath  -itemType "directory" -Force
    
    foreach ($dependentBinary in $dependentBinaries)
    {
        Copy-Item $dependentBinary $binFolderPath -Force
    }
    
    foreach ($psFile in $psFiles)
    {
        if (!(Test-Path $psFile))
        {					
            throw "ERROR:"  + $psFile + " does not exist"  
        } 	
        
        Copy-Item $psFile $path -Force
    }		
    
    Copy-Item $cfgfile (Join-Path $path "web.config") -Force
    Copy-Item $svc $path -Force
    Copy-Item $mof $path -Force

    if ($asax)
    {
        Copy-Item $asax $path -Force
    }
    
    if ($dispatch)
    {
        Copy-Item $dispatch $path -Force
    }
    
    if ($rbac)
    {
        Copy-Item $rbac (Join-Path $path "RbacConfiguration.xml") -Force 
    }
}

# Enable IIS Auth such as Anonymous, Basic, WindowsIntegrated (NTLM/Negotiate)
#
function UnlockIISAuthSections
{
    Log "Unlocking IIS auth sections"
    & $script:appCmd unlock config -section:access
    & $script:appCmd unlock config -section:anonymousAuthentication
    & $script:appCmd unlock config -section:basicAuthentication
    & $script:appCmd unlock config -section:windowsAuthentication
}

# Enable IIS Auth such as Anonymous, Basic, WindowsIntegrated (NTLM/Negotiate) for the given Site
#
function SetRequiredAuth
{
    param ($effVdir)
    
    Log "Setting auth schemes on $effVdir"         
    
    & $script:appCmd set config $effVdir /section:system.webServer/security/authentication/anonymousAuthentication /enabled:false /commit:apphost
    & $script:appCmd set config $effVdir /section:system.webServer/security/authentication/basicAuthentication /enabled:true /commit:apphost
    & $script:appCmd set config $effVdir /section:system.webServer/security/authentication/windowsAuthentication /enabled:true /commit:apphost
}

# Setup IIS Apppool, Site and Application
#
function SetupWebSite
{
    param (
        $site,
        $path,    
        $port,
        $app,
        $appPool,        
        $applicationPoolIdentityType)    
    
    $siteID = GenerateSiteID
    
    Log "Adding App Pool"
    & $script:appCmd add apppool /name:$appPool
    
    if ($applicationPoolIdentityType)
    {
        $applicationPoolIdentity = "/processModel.identityType:$applicationPoolIdentityType"
        
    }
    
    Log "Set App Pool Properties"
    & $script:appCmd set apppool /apppool.name:$appPool /enable32BitAppOnWin64:true /managedRuntimeVersion:"v4.0" $applicationPoolIdentity
    
    Log "Adding Site"
    & $script:appCmd add site /name:$site /id:$siteID /bindings:http://*:$port /physicalPath:$path
    
    Log "Set Site Properties"
    & $script:appCmd set site /site.name:$site /[path=`'/`'].applicationPool:$appPool
    
    Log "Trying to delete application:$app."    
    $null = & $script:appCmd delete app $site/$app
    
    Log "Adding application:$app."    
    & $script:appCmd add app /site.name:$site /path:/$app /physicalPath:$path
    
    Log "Set application:$app."    
    & $script:appCmd set app /app.name:$site/$app /applicationPool:$appPool
    
    $effVdir = "$site"   
    
    UnlockIISAuthSections
    
    SetRequiredAuth $effVdir    
    
    PerformActionOnSite -siteName $site -siteAction start
    
}

# Allow Clients outsite the machine to access the setup endpoint on a User Port
#
function CreateFirewallRule
{
    param ($firewallPort)
    
    Log "Disable Inbound Firewall Notification"
    & $script:netsh advfirewall set currentprofile settings inboundusernotification disable
    
    Log "Add Firewall Rule for port $firewallPort"
    & $script:netsh advfirewall firewall add rule name=PSWS_IIS_Port dir=in action=allow protocol=TCP localport=$firewallPort
}

<#
.Synopsis
   Create PowerShell WebServices IIS Endpoint
.DESCRIPTION
   Creates a PSWS IIS Endpoint by consuming PSWS Schema and related dependent files
.EXAMPLE
   Create a PSWS Endpoint [@ http://Server:39689/PSWS_Win32Process] by consuming PSWS Schema Files and any dependent scripts/binaries
   Create-PSWSEndpoint -site Win32Process -path $env:HOMEDRIVE\inetpub\wwwroot\PSWS_Win32Process -cfgfile Win32Process.config -port 39689 -app Win32Process -svc PSWS.svc -mof Win32Process.mof -dispatch Win32Process.xml -rbac RbacConfig.xml -asax Global.asax -dependentBinaries ConfigureProcess.ps1, Rbac.dll -psFiles Win32Process.psm1
#>
function Create-PSWSEndpoint
{
    param (
        
        # Unique Name of the IIS Site
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $site,
        
        # Physical path for the IIS Endpoint on the machine (under inetpub/wwwroot)
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $path,
        
        # Web.config file
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $cfgfile,
        
        # Port # for the IIS Endpoint
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Int] $port,
        
        # IIS Application Name for the Site
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $app,
        
        # IIS App Pool Identity Type - must be one of LocalService, LocalSystem, NetworkService, ApplicationPoolIdentity		
        [ValidateSet('LocalService', 'LocalSystem', 'NetworkService', 'ApplicationPoolIdentity')]		
        [String] $applicationPoolIdentityType,
        
        # WCF Service SVC file
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $svc,
        
        # PSWS Specific MOF Schema File
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $mof,
        
        # Global.asax file [Optional]
        [ValidateNotNullOrEmpty()]
        [String] $asax,        
        
        # PSWS Specific Dispatch Mapping File [Optional]
        [ValidateNotNullOrEmpty()]		
        [String] $dispatch,
        
        # PSWS Test Specific RBAC Config File [Optional when using the Pass-Through Plugin]
        [ValidateNotNullOrEmpty()]
        [String] $rbac,
        
        # Any dependent binaries that need to be deployed to the IIS endpoint, in the bin folder
        [ValidateNotNullOrEmpty()]
        [String[]] $dependentBinaries,
        
        # Any dependent PowerShell Scipts/Modules that need to be deployed to the IIS endpoint application root
        [ValidateNotNullOrEmpty()]
        [String[]] $psFiles,
        
        # True to remove all files for the site at first, false otherwise
        [Boolean]$removeSiteFiles = $false)
    
    $script:wshShell = New-Object -ComObject wscript.shell
    $script:appCmd = "$env:windir\system32\inetsrv\appcmd.exe"
    $script:SrvMgr = $null
    $script:netsh = "$env:windir\system32\netsh.exe"
    
    Log ("Setting up test site at http://$env:COMPUTERNAME.$env:USERDNSDOMAIN:$port")
    ParseCommandLineAndSetupResouce -site $site -path $path -cfgfile $cfgfile -port $port -app $app -applicationPoolIdentityType $applicationPoolIdentityType -svc $svc -mof $mof -asax $asax -dispatch $dispatch -rbac $rbac -dependentBinaries $dependentBinaries -psFiles $psFiles -removeSiteFiles $removeSiteFiles
    
    CreateFirewallRule $port
    
    PerformActionOnAllSites start	
}

<#
.Synopsis
   Set the option into the web.config for an endpoint
.DESCRIPTION
   Set the options into the web.config for an endpoint allowing customization.
.EXAMPLE
#>
function Set-Webconfig-AppSettings
{
    param (
                
        # Physical path for the IIS Endpoint on the machine (possibly under inetpub/wwwroot)
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $path,
        
        # Key to add/update
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $key,

        # Value 
        [parameter(mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $value

        )
                
    Log ("Setting options at $path")

    $webconfig = Join-Path $path "web.config"
    [bool] $Found = $false

    if (Test-Path $webconfig)
    {
        $xml = [xml](get-content $webconfig);
        $root = $xml.get_DocumentElement(); 

        foreach( $item in $root.appSettings.add) 
        { 
            if( $item.key -eq $key ) 
            { 
                $item.value = $value; 
                $Found = $true;
            } 
        }

        if( -not $Found)
        {
            $newElement = $xml.CreateElement("add");                               
            $nameAtt1 = $xml.CreateAttribute("key")                    
            $nameAtt1.psbase.value = $key;                                
            $newElement.SetAttributeNode($nameAtt1);    
                                   
            $nameAtt2 = $xml.CreateAttribute("value");                      
            $nameAtt2.psbase.value = $value;                       
            $newElement.SetAttributeNode($nameAtt2);       
                                   
            $xml.configuration["appSettings"].AppendChild($newElement);   
        }
    }

    $xml.Save($webconfig) 
}

Export-ModuleMember -function Set-Webconfig-AppSettings
Export-ModuleMember -function Create-PSWSEndpoint
