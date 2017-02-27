$RollUpModule = "AzureRM"
$PSProfileMapEndpoint = "https://azureprofile.azureedge.net/powershell/profilemap.json"
$PSModule = $ExecutionContext.SessionState.Module
$script:BootStrapRepo = "BootStrap"
$RepoLocation = "https://www.powershellgallery.com/api/v2/"
$existingRepos = Get-PSRepository | Where-Object {$_.SourceLocation -eq $RepoLocation}
if ($existingRepos -eq $null)
{
  Register-PSRepository -Name $BootStrapRepo -SourceLocation $RepoLocation -PublishLocation $RepoLocation -ScriptSourceLocation $RepoLocation -ScriptPublishLocation $RepoLocation -InstallationPolicy Trusted -PackageManagementProvider NuGet
}
else
{
  $script:BootStrapRepo = $existingRepos[0].Name
}

# Is it Powershell Core edition?
$Script:IsCoreEdition = ($PSVersionTable.PSEdition -eq 'Core')

# Check if current user is Admin to decide on cache path
$script:IsAdmin = $false
if ((-not $Script:IsCoreEdition) -or ($IsWindows))
{
  If (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
  {
    $script:IsAdmin = $true
  }
}
else {
  # on Linux, tests run via sudo will generally report "root" for whoami
  if ( (whoami) -match "root" ) 
  {
    $script:IsAdmin = $true
  }
}

# Get profile cache path
function Get-ProfileCachePath
{
  if ((-not $Script:IsCoreEdition) -or ($IsWindows))
  {
    $ProfileCache = Join-Path -path $env:LOCALAPPDATA -childpath "Microsoft\AzurePowerShell\ProfileCache"
    if ($script:IsAdmin)
    {
      $ProfileCache = Join-Path -path $env:ProgramData -ChildPath "Microsoft\AzurePowerShell\ProfileCache"
    }
    return $ProfileCache
  }

  $ProfileCache = "$HOME/.config/Microsoft/AzurePowerShell/ProfileCache" 

  # If profile cache directory does not exist, create one.
  if(-Not (Test-Path $ProfileCache))
  {
    New-Item -ItemType Directory -Force -Path $ProfileCache | Out-Null
  }

  return $ProfileCache
}

# Function to find the latest profile map from cache
function Get-LatestProfileMapPath
{
  $ProfileCache = Get-ProfileCachePath
  $ProfileMapPaths = Get-ChildItem $ProfileCache
  if ($ProfileMapPaths -eq $null)
  {
    return
  }

  $LargestNumber = Get-LargestNumber -ProfileCache $ProfileCache
  if ($LargestNumber -eq $null)
  {
    return
  }

  $LatestMapPath = $ProfileMapPaths | Where-Object { $_.Name.Startswith($LargestNumber.ToString() + '-') }
  return $LatestMapPath
}

# Function to get the largest number in profile cache profile map names: This helps to find the latest map
function Get-LargestNumber
{
  param($ProfileCache)
  
  $ProfileMapPaths = Get-ChildItem $ProfileCache
  $LargestNumber = $ProfileMapPaths | ForEach-Object { if($_.Name -match "\d+-") { $matches[0] -replace '-' } } | Measure-Object -Maximum 
  if ($LargestNumber -ne $null)
  {
    return $LargestNumber.Maximum
  }
}

# Find the latest ProfileMap 
$script:LatestProfileMapPath = Get-LatestProfileMapPath

# Make Web-Call
function Get-AzureStorageBlob
{
  $WebResponse =  Invoke-WebRequest -uri $PSProfileMapEndpoint 
  return $WebResponse
}

# Get-Content with retry logic; to handle parallel requests
function RetryGetContent
{
  param([string]$FilePath)
  $retryCount = 0
  Do
  {
    $retryCount = $retryCount + 1
    try {
      $ProfileMap = Get-Content -Raw -Path $FilePath -ErrorAction stop | ConvertFrom-Json 
      $Status = "success"
    }
    catch {
      Start-Sleep -Seconds 3
    }
  } 
  while (($Status -ne "success") -and ($retryCount -lt 3))
  return $ProfileMap
}

# Get-ProfileMap from Azure Endpoint
function Get-AzureProfileMap
{
  $ProfileCache = Get-ProfileCachePath

  # Get online profile data using Web request
  $WebResponse = Get-AzureStorageBlob  

  # Get ETag value for OnlineProfileMap
  $OnlineProfileMapETag = $WebResponse.Headers["ETag"]

  # If profilemap json exists, compare online Etag and cached Etag; if not different, don't replace cache.
  if (($script:LatestProfileMapPath -ne $null) -and ($script:LatestProfileMapPath -match "(\d+)-(.*.json)"))
  {
    [string]$ProfileMapETag = [System.IO.Path]::GetFileNameWithoutExtension($Matches[2])
    if (($ProfileMapETag -eq $OnlineProfileMapETag) -and (Test-Path $script:LatestProfileMapPath.FullName))
    {
      $ProfileMap = RetryGetContent -FilePath $script:LatestProfileMapPath.FullName
      if ($ProfileMap -ne $null)
      {
        return $ProfileMap
      }
    }
  }

  # If profilemap json doesn't exist, or if online ETag and cached ETag are different, cache online profile map
  $LargestNoFromCache = Get-LargestNumber -ProfileCache $ProfileCache 
  if ($LargestNoFromCache -eq $null)
  {
    $LargestNoFromCache = 0
  }
  
  $ChildPathName = ($LargestNoFromCache+1).ToString() + '-' + ($OnlineProfileMapETag) + ".json"
  $CacheFilePath = (Join-Path $ProfileCache -ChildPath $ChildPathName)
  $OnlineProfileMap = RetrieveProfileMap -WebResponse $WebResponse
  $OnlineProfileMap | ConvertTo-Json -Compress | Out-File -FilePath $CacheFilePath
   
  # Update $script:LatestProfileMapPath
  $script:LatestProfileMapPath = Get-ChildItem $ProfileCache | Where-Object { $_.FullName.equals($CacheFilePath)}
  return $OnlineProfileMap
}

# Helper to retrieve profile map from http response
function RetrieveProfileMap
{
  param($WebResponse)
  $OnlineProfileMap = ($WebResponse.Content -replace "`n|`r|`t") | ConvertFrom-Json
  return $OnlineProfileMap
}

# Get ProfileMap from Cache, online or embedded source
function Get-AzProfile
{
  [CmdletBinding()]
  param([Switch]$Update)

  $Update = $PSBoundParameters.Update
  # If Update is present, download ProfileMap from online source
  if ($Update.IsPresent)
  {
    return (Get-AzureProfileMap)
  }

  # Check the cache
  if(($script:LatestProfileMapPath -ne $null) -and (Test-Path $script:LatestProfileMapPath.FullName))
  {
    $ProfileMap = RetryGetContent -FilePath $script:LatestProfileMapPath.FullName
    if ($ProfileMap -ne $null)
    {
      return $ProfileMap
    }
  }
     
  # If cache doesn't exist, Check embedded source
  $defaults = [System.IO.Path]::GetDirectoryName($PSCommandPath)
  $ProfileMap = RetryGetContent -FilePath (Join-Path -Path $defaults -ChildPath "ProfileMap.json")
  if($ProfileMap -eq $null)
  {
    # Cache & Embedded source empty; Return error and stop
    throw [System.IO.FileNotFoundException] "Profile meta data does not exist. Use 'Get-AzureRmProfile -Update' to download from online source."
  }

  return $ProfileMap
}


# Lists the profiles available for install from gallery
function Get-ProfilesAvailable
{
  param([parameter(Mandatory = $true)] [PSCustomObject] $ProfileMap)
  $ProfileList = ""
  foreach ($Profile in $ProfileMap) 
  {
    foreach ($Module in ($Profile | get-member -MemberType NoteProperty).Name)
    {
      $ProfileList += "Profile: $Module`n"
      $ProfileList += "----------------`n"
      $ProfileList += ($Profile.$Module | Format-List | Out-String)
    } 
  }
  return $ProfileList
}

# Lists the profiles that are installed on the machine
function Get-ProfilesInstalled
{
  param([parameter(Mandatory = $true)] [PSCustomObject] $ProfileMap, [REF]$IncompleteProfiles)
  $result = @{}
  $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
  foreach ($key in $AllProfiles)
  {
    foreach ($module in ($ProfileMap.$key | Get-Member -MemberType NoteProperty).Name)
    {
      $ModulesList = (Get-Module -Name $Module -ListAvailable)
      $versionList = $ProfileMap.$key.$module
      foreach ($version in $versionList)
      {
        if (($ModulesList | Where-Object { $_.Version -eq $version}) -ne $null)
        {
          if ($result.ContainsKey($key))
          {
            $result[$key] += @{$module = $ProfileMap.$Key.$module}
          }
          else
          {
            $result.Add($key, @{$module = $ProfileMap.$Key.$module})
          }
        }
      }
    }

    # If not all the modules from a profile are installed, add it to $IncompleteProfiles
    if(($result.$key.Count -gt 0) -and ($result.$key.Count -ne ($ProfileMap.$key | Get-Member -MemberType NoteProperty).Count))
    {
      if ($result.$key.Contains($RollUpModule))
      {
        continue
      }
      
      $result.Remove($key)
      if ($IncompleteProfiles -ne $null) 
      {
        $IncompleteProfiles.Value += $key
      }
    }
  }
  return $result
}

# Function to remove Previous profile map
function Remove-ProfileMapFile
{
  [CmdletBinding()]
	param([string]$ProfileMapPath)

  if (Test-Path -Path $ProfileMapPath)
  {
    RemoveWithRetry -Path $ProfileMapPath -Force
  }
}

# Remove-Item command with Retry
function RemoveWithRetry
{
  param ([string]$Path)

  $retries = 3
  $secondsDelay = 2
  $retrycount = 0
  $completedSuccessfully = $false

  while (-not $completedSuccessfully) 
  {
    try 
    {
      Remove-Item @PSBoundParameters -ErrorAction Stop
      $completedSuccessfully = $true
    } 
    catch 
    {
      if ($retrycount -ge $retries) 
      {
        throw
      } 
      else 
      {
        Start-Sleep $secondsDelay
        $retrycount++
      }
    }
  }
}

# Get profiles installed associated with the module version
function Test-ProfilesInstalled
{
  param([String]$Module, [String]$Profile, [PSObject]$PMap, [hashtable]$AllProfilesInstalled)

  # Profiles associated with the particular module version - installed?
  $profilesAssociated = @()
  $versionList = $PMap.$Profile.$Module
  foreach ($version in $versionList)
  {
    foreach ($profileInAllProfiles in $AllProfilesInstalled[$Module + $version])
    {
      $profilesAssociated += $profileInAllProfiles
    }
  }
  return $profilesAssociated
}

# Function to uninstall module
function Uninstall-ModuleHelper
{
  [CmdletBinding(SupportsShouldProcess = $true)] 
  param([String]$Profile, $Module, [System.Version]$version, [Switch]$RemovePreviousVersions)

  $Remove = $PSBoundParameters.RemovePreviousVersions
  Do
  {
    $moduleInstalled = Get-Module -Name $Module -ListAvailable | Where-Object { $_.Version -eq $version} 
    if ($PSCmdlet.ShouldProcess("$module version $version", "Remove module")) 
    {
      if (($moduleInstalled -ne $null) -and ($Remove.IsPresent -or $PSCmdlet.ShouldContinue("Remove module $Module version $version", "Removing Modules for profile $Profile"))) 
      {
        Remove-Module -Name $module -Force -ErrorAction "SilentlyContinue"
        try 
        {
          Uninstall-Module -Name $module -RequiredVersion $version -Force -ErrorAction Stop
        }
        catch
        {
          Write-Error $_.Exception.Message
          break
        }
      }
      else {
        break
      }
    }
    else {
      break
    }
  }
  While($moduleInstalled -ne $null);
}

# Help function to uninstall a profile
function Uninstall-ProfileHelper
{
  [CmdletBinding()]
  param([PSObject]$PMap, [String]$Profile, [Switch]$Force)
  $modules = ($PMap.$Profile | Get-Member -MemberType NoteProperty).Name

  # Get-Profiles installed across all hashes. This is to avoid uninstalling modules that are part of other installed profiles
  $AllProfilesInstalled = Get-AllProfilesInstalled

  foreach ($module in $modules)
  {
    if ($Force.IsPresent)
    {
      Invoke-UninstallModule -PMap $PMap -Profile $Profile -Module $module -AllProfilesInstalled $AllProfilesInstalled -RemovePreviousVersions
    }
    else {
      Invoke-UninstallModule -PMap $PMap -Profile $Profile -Module $module -AllProfilesInstalled $AllProfilesInstalled 
    }
  }
}

# Checks if the module is part of other installed profiles. Calls Uninstall-ModuleHelper if not.
function Invoke-UninstallModule
{
  [CmdletBinding()]
  param([PSObject]$PMap, [String]$Profile, $Module, [hashtable]$AllProfilesInstalled, [Switch]$RemovePreviousVersions)

  # Check if the profiles associated with the module version are installed.
  $profilesAssociated = Test-ProfilesInstalled -Module $Module -Profile $Profile -PMap $PMap -AllProfilesInstalled $AllProfilesInstalled
      
  # If more than one profile is installed for the same version of the module, do not uninstall
  if ($profilesAssociated.Count -gt 1) 
  {
    return
  }

  $PSBoundParameters.Remove('AllProfilesInstalled') | Out-Null
  $PSBoundParameters.Remove('PMap') | Out-Null

  # Uninstall module
  $versionList = $PMap.$Profile.$module
  foreach ($version in $versionList)
  {
    Uninstall-ModuleHelper -version $version @PSBoundParameters
  }  
}

# Helps to uninstall previous versions of modules in the profile
function Remove-PreviousVersions
{
  [CmdletBinding()]
  param([PSObject]$PreviousMap, [PSObject]$LatestMap, [hashtable]$AllProfilesInstalled, [String]$Profile, [Array]$Module, [Switch]$RemovePreviousVersions)

  $Remove = $PSBoundParameters.RemovePreviousVersions
  $Modules = $PSBoundParameters.Module

  $PreviousProfiles = ($PreviousMap | Get-Member -MemberType NoteProperty).Name
  $LatestProfiles = ($LatestMap | Get-Member -MemberType NoteProperty).Name
  
  # If the profile was not in $PreviousProfiles, return
  if($Profile -notin $PreviousProfiles)
  {
    return
  }

  if ($Modules -eq $null)
  {
    $Modules = ($PreviousMap.$Profile | Get-Member -MemberType NoteProperty).Name
  }

  foreach ($module in $Modules)
  {
    # If the latest version is same as the previous version, do not uninstall.
    if (($PreviousMap.$Profile.$module | Out-String) -eq ($LatestMap.$Profile.$module | Out-String))
    {
      continue
    }
      
    # Is that module installed? If not skip
    $versionList = $PreviousMap.$Profile.$module
    foreach ($version in $versionList)
    {
      if ((Get-Module -Name $Module -ListAvailable | Where-Object { $_.Version -eq $version} ) -eq $null)
      {
        continue
      }

      # Modules are different. Uninstall previous version.
      if ($Remove.IsPresent)
      {
        Invoke-UninstallModule -PMap $PreviousMap -Profile $Profile -Module $module -AllProfilesInstalled $AllProfilesInstalled -RemovePreviousVersions
      }
      else {
        Invoke-UninstallModule -PMap $PreviousMap -Profile $Profile -Module $module -AllProfilesInstalled $AllProfilesInstalled         
      }
    }
      
    # Uninstall removes module from session; import latest version again
    $versions = $LatestMap.$Profile.$module
    $versionEnum = $versions.GetEnumerator()
    $toss = $versionEnum.MoveNext()
    $version = $versionEnum.Current
    Import-Module $Module -RequiredVersion $version -Global
  }
}

# Gets profiles installed from all the profilemaps from cache
function Get-AllProfilesInstalled
{
  $AllProfilesInstalled = @{}
  $ProfileCache = Get-ProfileCachePath
  $ProfileMapHashes = Get-ChildItem $ProfileCache 
  foreach ($ProfileMapHash in $ProfileMapHashes)
  {
    $ProfileMap = RetryGetContent -FilePath (Join-Path $ProfileCache $ProfileMapHash.Name) 
    $profilesInstalled = (Get-ProfilesInstalled -ProfileMap $ProfileMap)
    foreach ($Profile in $profilesInstalled.Keys)
    {
      foreach ($Module in ($ProfileMap.$Profile | Get-Member -MemberType NoteProperty).Name)
      {
        $versionList = $ProfileMap.$Profile.$Module
        foreach ($version in $versionList)
        {
          if ($AllProfilesInstalled.ContainsKey(($Module + $version)))
          {
            if ($Profile -notin $AllProfilesInstalled[($Module + $version)])
            {
              $AllProfilesInstalled[($Module + $version)] += $Profile
            }
          }
          else {
            $AllProfilesInstalled.Add(($Module + $version), @($Profile))
          }
        }
      }
    }
  }
  return $AllProfilesInstalled
}

# Helps to remove-previous versions of the update-profile and clean up cache, if none of the old hash profiles are installed
function Update-ProfileHelper
{
  [CmdletBinding()]
  param([String]$Profile, [Array]$Module, [Switch]$RemovePreviousVersions)

  # Get all the hash files (ProfileMaps) from cache
  $ProfileCache = Get-ProfileCachePath
  $ProfileMapHashes = Get-ChildItem $ProfileCache

  $LatestProfileMap = RetryGetContent -FilePath $script:LatestProfileMapPath.FullName 

  # Get-Profiles installed across all hashes. 
  $AllProfilesInstalled = Get-AllProfilesInstalled

  foreach ($ProfileMapHash in $ProfileMapHashes)
  {
    # Set flag to delete hash
    $deleteHash = $true
    
    # Do not process the latest hash; we don't want to remove the latest hash
    if ($ProfileMapHash.Name -eq $script:LatestProfileMapPath.Name)
    {
      continue
    }

    # Compare previous & latest map for the update profile. Uninstall previous if they are different
    $previousProfileMap = RetryGetContent -FilePath (Join-Path $profilecache $ProfileMapHash) 
    Remove-PreviousVersions -PreviousMap $previousProfileMap -LatestMap $LatestProfileMap -AllProfilesInstalled $AllProfilesInstalled @PSBoundParameters

    # If the previous map has profiles installed, do not delete it.
    $profilesInstalled = (Get-ProfilesInstalled -ProfileMap $previousProfileMap)
    foreach ($PreviousProfile in $profilesInstalled.Keys)
    {
      # Map can be deleted if the only profile installed is the updated one.
      if ($PreviousProfile -eq $Profile)
      {
        continue
      }
      else {
        $deleteHash = $false
      }
    }

    # If none were installed, remove the hash
    if ($deleteHash -ne $false)
    {
      Remove-ProfileMapFile -ProfileMapPath (Join-Path $profilecache $ProfileMapHash)
    }
  }
}

# If cmdlets were installed at a different scope, warn users of the potential conflict
function Find-PotentialConflict
{
  [CmdletBinding(SupportsShouldProcess = $true)] 
  param([string]$Module, [switch]$Force)
  
  $availableModules = Get-Module $Module -ListAvailable
  $IsPotentialConflict = $false

  # If Admin, check CurrentUser Module folder path and vice versa
  if ($script:IsAdmin)
  {
    $availableModules | ForEach-Object { if ($_.Path.Contains($env:HOMEPATH)) { $IsPotentialConflict = $true } }
  }
  else {
    $availableModules | ForEach-Object { if ($_.Path.Contains($env:ProgramFiles)) { $IsPotentialConflict = $true } }
  }

  if ($IsPotentialConflict)
  {
    if (($Force.IsPresent) -or ($PSCmdlet.ShouldContinue(`
      "The Cmdlets from module $Module are already present on this device. Proceeding with the installation might cause conflicts. Would you like to continue?", "Detected $Module cmdlets")))
    {
      return $false
    }
    else 
    {
      return $true
    }
  }
  return $false
}

# Add Scope parameter to the cmdlet
function Add-ScopeParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$set = "__AllParameterSets")
  $Keys = @('CurrentUser', 'AllUsers')
  $scopeValid = New-Object -Type System.Management.Automation.ValidateSetAttribute($Keys)
  $scopeAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
  $scopeAttribute.ParameterSetName = 
  $scopeAttribute.Mandatory = $false
  $scopeAttribute.Position = 1
  $scopeCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
  $scopeCollection.Add($scopeValid)
  $scopeCollection.Add($scopeAttribute)
  $scopeParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("Scope", [string], $scopeCollection)
  $params.Add("Scope", $scopeParam)
}

# Add the profile parameter to the cmdlet
function Add-ProfileParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$set = "__AllParameterSets")
  $ProfileMap = (Get-AzProfile)
  $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
  $profileAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
  $profileAttribute.ParameterSetName = $set
  $profileAttribute.Mandatory = $true
  $profileAttribute.Position = 0
  $validateProfileAttribute = New-Object -Type System.Management.Automation.ValidateSetAttribute($AllProfiles)
  $profileCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
  $profileCollection.Add($profileAttribute)
  $profileCollection.Add($validateProfileAttribute)
  $profileParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("Profile", [string], $profileCollection)
  $params.Add("Profile", $profileParam)
}

function Add-ForceParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$set = "__AllParameterSets")
  Add-SwitchParam $params "Force" $set
}

function Add-RemoveParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$set = "__AllParameterSets")
  $name = "RemovePreviousVersions" 
  $newAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
  $newAttribute.ParameterSetName = $set
  $newAttribute.Mandatory = $false
  $newCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
  $newCollection.Add($newAttribute)
  $newParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter($name, [switch], $newCollection)
  $params.Add($name, [Alias("r")]$newParam)
}

function Add-SwitchParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$name, [string] $set = "__AllParameterSets")
  $newAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
  $newAttribute.ParameterSetName = $set
  $newAttribute.Mandatory = $false
  $newCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
  $newCollection.Add($newAttribute)
  $newParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter($name, [switch], $newCollection)
  $params.Add($name, $newParam)
}

function Add-ModuleParam
{
  param([System.Management.Automation.RuntimeDefinedParameterDictionary]$params, [string]$name, [string] $set = "__AllParameterSets")
  $ProfileMap = (Get-AzProfile)
  $Profiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
  if ($Profiles.Count -gt 1)
  {
    $enum = $Profiles.GetEnumerator()
    $toss = $enum.MoveNext()
    $Current = $enum.Current
    $Keys = ($($ProfileMap.$Current) | Get-Member -MemberType NoteProperty).Name
  }
  else {
    $Keys = ($($ProfileMap.$Profiles[0]) | Get-Member -MemberType NoteProperty).Name
  }
  $moduleValid = New-Object -Type System.Management.Automation.ValidateSetAttribute($Keys)
  $AllowNullAttribute = New-Object -Type System.Management.Automation.AllowNullAttribute
  $AllowEmptyStringAttribute = New-Object System.Management.Automation.AllowEmptyStringAttribute
  $moduleAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
  $moduleAttribute.ParameterSetName = 
  $moduleAttribute.Mandatory = $false
  $moduleAttribute.Position = 1
  $moduleCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
  $moduleCollection.Add($moduleValid)
  $moduleCollection.Add($moduleAttribute)
  $moduleCollection.Add($AllowNullAttribute)
  $moduleCollection.Add($AllowEmptyStringAttribute)
  $moduleParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("Module", [array], $moduleCollection)
  $params.Add("Module", $moduleParam)
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Get-AzureRmModule 
{
  [CmdletBinding()]
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-ProfileParam $params
    $ProfileMap = (Get-AzProfile)
    $Profiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
    if ($Profiles.Count -gt 1)
    {
      $enum = $Profiles.GetEnumerator()
      $toss = $enum.MoveNext()
      $Current = $enum.Current
      $Keys = ($($ProfileMap.$Current) | Get-Member -MemberType NoteProperty).Name
    }
    else {
      $Keys = ($($ProfileMap.$Profiles[0]) | Get-Member -MemberType NoteProperty).Name
    }
    $moduleValid = New-Object -Type System.Management.Automation.ValidateSetAttribute($Keys)
    $moduleAttribute = New-Object -Type System.Management.Automation.ParameterAttribute
    $moduleAttribute.ParameterSetName = 
    $moduleAttribute.Mandatory = $true
    $moduleAttribute.Position = 1
    $moduleCollection = New-object -Type System.Collections.ObjectModel.Collection[System.Attribute]
    $moduleCollection.Add($moduleValid)
    $moduleCollection.Add($moduleAttribute)
    $moduleParam = New-Object -Type System.Management.Automation.RuntimeDefinedParameter("Module", [string], $moduleCollection)
    $params.Add("Module", $moduleParam)
    return $params
  }
  
  PROCESS
  {
    $ProfileMap = (Get-AzProfile)
    $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
    $Profile = $PSBoundParameters.Profile
    $Module = $PSBoundParameters.Module
    $versionList = $ProfileMap.$Profile.$Module
    $moduleList = Get-Module -Name $Module -ListAvailable | Where-Object {$_.RepositorySourceLocation -ne $null}
    foreach ($version in $versionList)
    {
      foreach ($module in $moduleList)
      {
        if ($version -eq $module.Version)
        {
          return $version
        }
      }
    }
    return $null
  }
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Get-AzureRmProfile
{
  [CmdletBinding(DefaultParameterSetName="ListAvailableParameterSet")]
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-SwitchParam $params "ListAvailable" "ListAvailableParameterSet"
    Add-SwitchParam $params "Update"
    return $params
  }
  PROCESS
  {
    # ListAvailable helps to display all profiles available from the gallery
    [switch]$ListAvailable = $PSBoundParameters.ListAvailable
    $PSBoundParameters.Remove('ListAvailable') | Out-Null
    $ProfileMap = (Get-AzProfile @PSBoundParameters)
    if ($ListAvailable.IsPresent)
    {
      Get-ProfilesAvailable $ProfileMap
    }
    else
    {
      # Just display profiles installed on the machine
      $IncompleteProfiles = @()
      $profilesInstalled = Get-ProfilesInstalled -ProfileMap $ProfileMap ([REF]$IncompleteProfiles)
      $Output = @()
      foreach ($key in $profilesInstalled.Keys)
      {
        $Output += "Profile : $key"
        $Output += "-----------------"
        $Output += ($profilesInstalled.$key | Format-Table -HideTableHeaders | Out-String)
      }
      if ($IncompleteProfiles.Count -gt 0)
      {
        Write-Warning "Some modules from profile(s) $(@($IncompleteProfiles) -join ', ') were not installed. Use Install-AzureRmProfile to install missing modules."
      }
      $Output
    }
  }
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Use-AzureRmProfile
{
  [CmdletBinding(SupportsShouldProcess=$true)] 
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-ProfileParam $params
    Add-ForceParam $params
    Add-ScopeParam $params
    Add-ModuleParam $params
    return $params
  }
  PROCESS 
  {
    $Force = $PSBoundParameters.Force
    $ProfileMap = (Get-AzProfile)
    $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
    $Profile = $PSBoundParameters.Profile
    $Scope = $PSBoundParameters.Scope
    $Modules = $PSBoundParameters.Module

    # If user hasn't provided modules, use the module names from profile
    if ($Modules -eq $null)
    {
      $Modules = ($ProfileMap.$Profile | Get-Member -MemberType NoteProperty).Name
    }

    # If AzureRM $RollUpModule is present in that profile, it will install all the dependent modules; no need to specify other modules
    if ($Modules.Contains($RollUpModule))
    {
      $Modules = @($RollUpModule)
    }
    
    $PSBoundParameters.Remove('Profile') | Out-Null
    $PSBoundParameters.Remove('Scope') | Out-Null
    $PSBoundParameters.Remove('Module') | Out-Null

    # Variable to track progress
    $ModuleCount = 0
    Write-Host "Loading Profile $Profile"
    foreach ($Module in $Modules)
    {
      $ModuleCount = $ModuleCount + 1
      if ($PSCmdlet.ShouldProcess($Profile, "Loading module $module for profile in the current scope"))
      {
        if (Find-PotentialConflict -Module $Module @PSBoundParameters) 
        {
          continue
        }

        $version = Get-AzureRmModule -Profile $Profile -Module $Module
        if (($version -eq $null) -and ($Force.IsPresent -or $PSCmdlet.ShouldContinue("Install Module $module for Profile $Profile from the gallery?", "Installing Modules for Profile $Profile")))
        {
          if ($PSCmdlet.ShouldProcess($module, "Installing module for profile in the current scope"))
          {
            $versions = $ProfileMap.$Profile.$Module
            $versionEnum = $versions.GetEnumerator()
            $toss = $versionEnum.MoveNext()
            $version = $versionEnum.Current
            Write-Progress -Activity "Installing Module $Module version: $version" -Status "Progress:" -PercentComplete ($ModuleCount/($Modules.Length)*100)
            if (-not $Scope)
            {
              Install-Module $Module -RequiredVersion $version -AllowClobber
            }
            else
            {
              Install-Module $Module -RequiredVersion $version -scope $Scope -AllowClobber
            }
          }
        }
        
        Import-Module -Name $Module -RequiredVersion $version -Global
      }
    }
  }
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Install-AzureRmProfile
{
  [CmdletBinding()]
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-ProfileParam $params
    Add-ScopeParam $params
    Add-ForceParam $params
    return $params
  }

  PROCESS {
    $ProfileMap = (Get-AzProfile)
    $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
    $Profile = $PSBoundParameters.Profile
    $Scope = $PSBoundParameters.Scope
    $Modules = ($ProfileMap.$Profile | Get-Member -MemberType NoteProperty).Name

    # If AzureRM $RollUpModule is present in $profile, it will install all the dependent modules; no need to specify other modules
    if ($Modules.Contains($RollUpModule))
    {
      $Modules = @($RollUpModule)
    }
      
    $PSBoundParameters.Remove('Profile') | Out-Null
    $PSBoundParameters.Remove('Scope') | Out-Null

    $ModuleCount = 0
    foreach ($Module in $Modules)
    {
      $ModuleCount = $ModuleCount + 1
      if (Find-PotentialConflict -Module $Module @PSBoundParameters) 
      {
        continue
      }

      $version = Get-AzureRmModule -Profile $Profile -Module $Module
      if ($version -eq $null) 
      {
        $versions = $ProfileMap.$Profile.$Module
        $versionEnum = $versions.GetEnumerator()
        $toss = $versionEnum.MoveNext()
        $version = $versionEnum.Current
        Write-Progress -Activity "Installing Module $Module version: $version" -Status "Progress:" -PercentComplete ($ModuleCount/($Modules.Length)*100)
        if (-not $Scope)
        {
          Install-Module $Module -RequiredVersion $version -AllowClobber
        }
        else
        {
          Install-Module $Module -RequiredVersion $version -scope $Scope -AllowClobber
        }
      }
    }
  }
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Uninstall-AzureRmProfile
{
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-ProfileParam $params
    Add-ForceParam $params
    return $params
  }

  PROCESS {
    $ProfileMap = (Get-AzProfile)
    $Profile = $PSBoundParameters.Profile
    $Force = $PSBoundParameters.Force

    if ($PSCmdlet.ShouldProcess("$Profile", "Uninstall Profile")) 
    {
      if (($Force.IsPresent -or $PSCmdlet.ShouldContinue("Uninstall Profile $Profile", "Removing Modules for profile $Profile")))
      {
        Uninstall-ProfileHelper -PMap $ProfileMap @PSBoundParameters
      }
    }
  }
}

<#
.ExternalHelp help\AzureRM.Bootstrapper-help.xml 
#>
function Update-AzureRmProfile
{
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()
  DynamicParam
  {
    $params = New-Object -Type System.Management.Automation.RuntimeDefinedParameterDictionary
    Add-ProfileParam $params
    Add-ForceParam $params
    Add-RemoveParam $params 
    Add-ModuleParam $params
    Add-ScopeParam $params
    return $params
  }

  PROCESS {
    # Update Profile cache, if not up-to-date
    $ProfileMap = (Get-AzProfile -Update)
    $profile = $PSBoundParameters.Profile
    $Force = $PSBoundParameters.Force
    $Remove = $PSBoundParameters.RemovePreviousVersions
    $Modules = $PSBoundParameters.Module

    $AllProfiles = ($ProfileMap | Get-Member -MemberType NoteProperty).Name
    $PSBoundParameters.Remove('RemovePreviousVersions') | Out-Null

    # Install & import the required version
    Use-AzureRmProfile @PSBoundParameters
    
    $PSBoundParameters.Remove('Force') | Out-Null
    $PSBoundParameters.Remove('Scope') | Out-Null

    # Remove previous versions of the profile?
    if ($PSCmdlet.ShouldProcess("Remove previous versions")) 
    {
      if (($Remove -or $PSCmdlet.ShouldContinue("Uninstall Previous Module Versions of the profile", "Removing previous versions of the profile")))
      {
        # Remove-PreviousVersions and clean up cache
        Update-ProfileHelper @PSBoundParameters -RemovePreviousVersions
      }
    }
  }
}

function Set-BootstrapRepo
{
	[CmdletBinding()]
	param([string]$Repo)
	$script:BootStrapRepo = $Repo
}
