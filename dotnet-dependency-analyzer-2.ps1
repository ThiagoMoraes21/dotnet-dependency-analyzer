param (
    [Parameter(Mandatory=$true)]
    [string]$RepoUrl,
    
    [Parameter(Mandatory=$false)]
    [string]$PersonalAccessToken,
    
    [Parameter(Mandatory=$false)]
    [string]$Branch = "master",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder = ".\MigrationReport",
    
    [Parameter(Mandatory=$false)]
    [string[]]$PrivateNuGetSources = @(),
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateNuGetUsername,
    
    [Parameter(Mandatory=$false)]
    [string]$PrivateNuGetPassword
)

# Add error handling for the entire script
$ErrorActionPreference = "Stop"

# Enhanced package compatibility class
class PackageCompatibility {
    [string]$Name
    [string]$CurrentVersion
    [string]$ResolvedVersion
    [bool]$WasUpdated
    [bool]$IsCompatible
    [string]$Notes
    [bool]$IsPrivate
}

# Main report object structure
$GlobalReport = [PSCustomObject]@{
    MigrationResults = @()
    BuildErrors = @()
    FailedUpdates = @()
    SuccessfulUpdates = @()
    PrivatePackages = @()
}

#region Enhanced Helper Functions

# Added missing Ensure-RequiredTools function
function Ensure-RequiredTools {
    # Check for Git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git is not installed or not in the PATH. Please install Git." -ForegroundColor Red
        throw "Git not found"
    }

    # Check for .NET CLI
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Host ".NET CLI is not installed or not in the PATH. Please install .NET SDK." -ForegroundColor Red
        throw ".NET CLI not found"
    }

    Write-Host "Required tools verified." -ForegroundColor Green
}

# Added missing Clone-Repository function
function Clone-Repository {
    # $tempFolder = Join-Path $env:TEMP "dotnet-migration-$(Get-Random)"
    $tempFolder = ".\tempFolder"

    Write-Host "Cloning repository to $tempFolder..." -ForegroundColor Cyan
    
    if ([string]::IsNullOrEmpty($PersonalAccessToken)) {
        git clone --branch $Branch $RepoUrl $tempFolder
    } else {
        # Extract domain from URL to construct auth URL
        if ($RepoUrl -match "https://([^/]+)/") {
            $domain = $matches[1]
            $authUrl = $RepoUrl -replace "https://", "https://$($PersonalAccessToken)@"
            git clone --branch $Branch $authUrl $tempFolder
        } else {
            throw "Invalid repository URL format"
        }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone repository"
    }
    
    return $tempFolder
}

# Added missing Find-DotNetProjects function
function Find-DotNetProjects {
    param (
        [string]$BasePath
    )
    
    $projects = Get-ChildItem -Path $BasePath -Recurse -Filter "*.csproj"
    Write-Host "Found $($projects.Count) .NET projects to analyze." -ForegroundColor Cyan
    return $projects
}

function Update-TargetFramework {
    param (
        [System.IO.FileInfo]$ProjectFile
    )
    
    $content = Get-Content $ProjectFile.FullName -Raw
    $updated = $content -replace '<TargetFramework>netcoreapp3\.1</TargetFramework>', '<TargetFramework>net8.0</TargetFramework>'
    $updated = $updated -replace '<TargetFrameworks>.*?(netcoreapp3\.1).*?</TargetFrameworks>', '<TargetFrameworks>net8.0</TargetFrameworks>'
    
    if ($content -ne $updated) {
        Set-Content -Path $ProjectFile.FullName -Value $updated -Force
        Write-Host "Updated TargetFramework to net8.0 in $($ProjectFile.Name)" -ForegroundColor Green
        return $true
    }
    return $false
}

function Update-PackageVersion {
    param (
        [System.IO.FileInfo]$ProjectFile,
        [string]$PackageName,
        [string]$NewVersion
    )
    
    $projectXml = [xml](Get-Content $ProjectFile.FullName)
    $ns = New-Object System.Xml.XmlNamespaceManager($projectXml.NameTable)
    $ns.AddNamespace("ms", "http://schemas.microsoft.com/developer/msbuild/2003")
    
    # Fix: Use proper XPath with namespace handling
    $packageNode = $null
    
    # Check for SDK-style projects (no namespace)
    $packageNode = $projectXml.Project.ItemGroup.PackageReference | 
                   Where-Object { $_.Include -eq $PackageName } |
                   Select-Object -First 1
    
    # Check for legacy project format (with namespace)
    if (-not $packageNode) {
        $packageNode = $projectXml.SelectSingleNode("//ms:PackageReference[@Include='$PackageName']", $ns)
    }
    
    if ($packageNode) {
        $packageNode.Version = $NewVersion
        $projectXml.Save($ProjectFile.FullName)
        Write-Host "Updated $PackageName to $NewVersion in $($ProjectFile.Name)" -ForegroundColor Green
        return $true
    }
    return $false
}

function Get-CompatibleVersion {
    param (
        [string]$PackageName,
        [string]$CurrentVersion
    )
    
    try {
        # First try public NuGet
        Write-Verbose "Checking public NuGet.org for package $PackageName"
        $apiUrl = "https://api.nuget.org/v3/registration5-semver1/$($PackageName.ToLower())/index.json"
        
        try {
            $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
            $compatibleVersions = Get-VersionsFromResponse -Response $response
            
            if ($compatibleVersions.Count -gt 0) {
                # Return the highest compatible version
                $sortedVersion = Get-HighestVersion -VersionList $compatibleVersions
                return $sortedVersion
            }
        }
        catch {
            Write-Verbose "Package $PackageName not found on public NuGet or error occurred: $_"
            # Continue to check private sources
        }
        
        # If not found on public NuGet, try private sources
        if ($PrivateNuGetSources.Count -gt 0) {
            foreach ($privateSource in $PrivateNuGetSources) {
                Write-Verbose "Checking private NuGet source: $privateSource for package $PackageName"
                
                # Construct the URL for the private package
                $privateApiUrl = "$($privateSource.TrimEnd('/'))/v3/registration5-semver1/$($PackageName.ToLower())/index.json"
                
                try {
                    $headers = @{}
                    
                    # Add authentication if provided
                    if (-not [string]::IsNullOrEmpty($PrivateNuGetUsername) -and -not [string]::IsNullOrEmpty($PrivateNuGetPassword)) {
                        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $PrivateNuGetUsername, $PrivateNuGetPassword)))
                        $headers.Add("Authorization", "Basic $base64AuthInfo")
                    }
                    
                    $privateResponse = Invoke-RestMethod -Uri $privateApiUrl -Headers $headers -ErrorAction Stop
                    $privateCompatibleVersions = Get-VersionsFromResponse -Response $privateResponse
                    
                    if ($privateCompatibleVersions.Count -gt 0) {
                        $sortedVersion = Get-HighestVersion -VersionList $privateCompatibleVersions
                        Write-Host "Found compatible version $sortedVersion for $PackageName on private NuGet source." -ForegroundColor Green
                        return $sortedVersion
                    }
                }
                catch {
                    Write-Verbose "Failed to check private NuGet source $privateSource for $PackageName : $_"
                    # Continue to next private source
                }
            }
        }
        
        # If we get here, no compatible version was found in any source
        Write-Host "No compatible version found for $PackageName on any configured NuGet source." -ForegroundColor Yellow
        return $null
    }
    catch {
        Write-Host "Error checking compatible versions for $PackageName : $_" -ForegroundColor Red
        return $null
    }
}

function Get-VersionsFromResponse {
    param (
        [PSObject]$Response
    )
    
    $compatibleVersions = @()
    
    foreach ($entry in $Response.items) {
        foreach ($versionEntry in $entry.items) {
            $version = $versionEntry.catalogEntry.version
            $dependencies = $versionEntry.catalogEntry.dependencyGroups
            
            # Handle null dependencies
            if ($null -eq $dependencies) {
                $compatibleVersions += $version
                continue
            }
            
            foreach ($depGroup in $dependencies) {
                if ($depGroup.targetFramework -in @(".NETCoreApp8.0", "net8.0", ".NETStandard2.0", ".NETStandard2.1")) {
                    $compatibleVersions += $version
                    break
                }
            }
        }
    }
    
    return $compatibleVersions
}

function Get-HighestVersion {
    param (
        [string[]]$VersionList
    )
    
    # Fix: Use proper version sorting
    $sortedVersions = $VersionList | 
                      ForEach-Object { 
                          if ($_ -match "^\d+\.\d+\.\d+(\.\d+)?$") {
                              [PSCustomObject]@{ VersionString = $_; Version = [Version]$_ }
                          } else {
                              [PSCustomObject]@{ VersionString = $_; Version = [Version]"0.0.0" }
                          }
                      } | 
                      Sort-Object -Property Version -Descending
    
    if ($sortedVersions.Count -gt 0) {
        return $sortedVersions[0].VersionString
    }
    
    return $null
}

#endregion

#region Enhanced Analysis Functions

function Invoke-SolutionBuild {
    param (
        [string]$RepoFolder
    )
    
    try {
        Write-Host "Restoring NuGet packages..." -ForegroundColor Cyan
        
        # Make sure we're in the repository folder
        Push-Location $RepoFolder
        
        try {
            # Add private sources to restore command if provided
            $restoreArgs = @("restore", "--verbosity", "normal")
            
            foreach ($privateSource in $PrivateNuGetSources) {
                $restoreArgs += "--source"
                $restoreArgs += $privateSource
            }
            
            # Add the public NuGet source as well
            $restoreArgs += "--source"
            $restoreArgs += "https://api.nuget.org/v3/index.json"
            
            & dotnet $restoreArgs
            
            if ($LASTEXITCODE -ne 0) {
                $GlobalReport.BuildErrors += "Package restore failed with exit code $LASTEXITCODE"
                return $false
            }
            
            Write-Host "Building solution..." -ForegroundColor Cyan
            $buildOutput = dotnet build --configuration Release --no-restore -clp:"ErrorsOnly;Summary" | Out-String
            
            if ($LASTEXITCODE -ne 0) {
                $GlobalReport.BuildErrors += $buildOutput
                return $false
            }
            return $true
        }
        finally {
            # Make sure we go back to the original location
            Pop-Location
        }
    }
    catch {
        $GlobalReport.BuildErrors += $_.ToString()
        return $false
    }
}

function Invoke-DependencyResolution {
    param (
        [System.IO.FileInfo]$ProjectFile
    )
    
    $projectXml = [xml](Get-Content $ProjectFile.FullName)
    $packageUpdates = @()
    
    # Get all package references, handling both SDK-style and legacy projects
    $packageRefs = @()
    
    # SDK-style projects
    if ($projectXml.Project.ItemGroup) {
        $packageRefs += $projectXml.Project.ItemGroup.PackageReference | Where-Object { $_ }
    }
    
    # Legacy projects with namespace
    if ($packageRefs.Count -eq 0) {
        $ns = New-Object System.Xml.XmlNamespaceManager($projectXml.NameTable)
        $ns.AddNamespace("ms", "http://schemas.microsoft.com/developer/msbuild/2003")
        $packageRefs += $projectXml.SelectNodes("//ms:PackageReference", $ns)
    }
    
    foreach ($pkg in $packageRefs) {
        $packageName = $pkg.Include
        $currentVersion = $pkg.Version
        
        # Skip null or empty values
        if ([string]::IsNullOrEmpty($packageName) -or [string]::IsNullOrEmpty($currentVersion)) {
            continue
        }
        
        # Skip system packages that shouldn't be updated
        if ($packageName.StartsWith("System.") -or $packageName.StartsWith("Microsoft.NETCore") -or $packageName.StartsWith("NETStandard.Library")) {
            Write-Verbose "Skipping system package $packageName"
            continue
        }
        
        # Skip private packages if they start with your internal prefix
        if ($packageName.StartsWith("Internal.")) {
            $privatePackage = [PSCustomObject]@{
                PackageName = $packageName
                CurrentVersion = $currentVersion
                Project = $ProjectFile.Name
            }
            
            if (-not ($GlobalReport.PrivatePackages | Where-Object { $_.PackageName -eq $packageName })) {
                $GlobalReport.PrivatePackages += $privatePackage
            }
            continue
        }
        
        # Get compatible version
        $compatibleVersion = Get-CompatibleVersion -PackageName $packageName -CurrentVersion $currentVersion
        
        if ($compatibleVersion -and ($compatibleVersion -ne $currentVersion)) {
            if (Update-PackageVersion -ProjectFile $ProjectFile -PackageName $packageName -NewVersion $compatibleVersion) {
                $packageUpdate = [PSCustomObject]@{
                    PackageName = $packageName
                    OldVersion = $currentVersion
                    NewVersion = $compatibleVersion
                    Project = $ProjectFile.Name
                }
                $packageUpdates += $packageUpdate
            }
        }
        elseif (-not $compatibleVersion) {
            $failedUpdate = [PSCustomObject]@{
                PackageName = $packageName
                CurrentVersion = $currentVersion
                Project = $ProjectFile.Name
            }
            
            if (-not ($GlobalReport.FailedUpdates | Where-Object { $_.PackageName -eq $packageName -and $_.Project -eq $ProjectFile.Name })) {
                $GlobalReport.FailedUpdates += $failedUpdate
            }
        }
    }
    
    return $packageUpdates
}

#endregion

#region Enhanced Reporting

function New-MigrationReport {
    param (
        [string]$OutputFolder
    )
    
    $htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <title>.NET 8 Migration Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 2em; }
        .section { margin-bottom: 2em; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 0.8em; border: 1px solid #ddd; }
        th { background-color: #f8f9fa; }
        .success { color: #2ecc71; }
        .warning { color: #f1c40f; }
        .error { color: #e74c3c; }
        .build-errors pre { background-color: #f8d7da; padding: 1em; }
    </style>
</head>
<body>
    <h1>.NET 8 Migration Report</h1>
    <p>Generated: $(Get-Date)</p>
    
    <div class="section">
        <h2>Migration Summary</h2>
        <p>Successful Package Updates: $($GlobalReport.SuccessfulUpdates.Count)</p>
        <p>Failed Package Updates: $($GlobalReport.FailedUpdates.Count)</p>
        <p>Private Packages Requiring Attention: $($GlobalReport.PrivatePackages.Count)</p>
    </div>
    
    <div class="section">
        <h2>Successful Updates</h2>
        <table>
            <tr><th>Package</th><th>Old Version</th><th>New Version</th><th>Project</th></tr>
"@

    foreach ($update in $GlobalReport.SuccessfulUpdates) {
        $htmlReport += @"
            <tr>
                <td>$($update.PackageName)</td>
                <td>$($update.OldVersion)</td>
                <td class="success">$($update.NewVersion)</td>
                <td>$($update.Project)</td>
            </tr>
"@
    }

    $htmlReport += @"
        </table>
    </div>

    <div class="section">
        <h2>Failed Updates</h2>
        <table>
            <tr><th>Package</th><th>Current Version</th><th>Project</th></tr>
"@

    foreach ($failed in $GlobalReport.FailedUpdates) {
        $htmlReport += @"
            <tr>
                <td>$($failed.PackageName)</td>
                <td>$($failed.CurrentVersion)</td>
                <td class="error">$($failed.Project)</td>
            </tr>
"@
    }

    $htmlReport += @"
        </table>
    </div>

    <div class="section">
        <h2>Private Packages</h2>
        <table>
            <tr><th>Package</th><th>Current Version</th><th>Project</th></tr>
"@

    foreach ($private in $GlobalReport.PrivatePackages) {
        $htmlReport += @"
            <tr>
                <td>$($private.PackageName)</td>
                <td>$($private.CurrentVersion)</td>
                <td class="warning">$($private.Project)</td>
            </tr>
"@
    }

    $htmlReport += @"
        </table>
    </div>

    <div class="section">
        <h2>Build Errors</h2>
        <div class="build-errors">
            <pre>$($GlobalReport.BuildErrors | ConvertTo-Html -Fragment)</pre>
        </div>
    </div>
</body>
</html>
"@

    $reportPath = Join-Path $OutputFolder "migration-report.html"
    $htmlReport | Out-File -Path $reportPath -Encoding UTF8
    return $reportPath
}

#endregion

# Main Execution Flow
try {
    # Display info about private NuGet sources
    if ($PrivateNuGetSources.Count -gt 0) {
        Write-Host "Using private NuGet sources:" -ForegroundColor Cyan
        foreach ($source in $PrivateNuGetSources) {
            Write-Host " - $source" -ForegroundColor Cyan
        }
    }
    
    # Initial setup
    Ensure-RequiredTools
    $repoFolder = Clone-Repository
    $projects = Find-DotNetProjects -BasePath $repoFolder

    if (-not (Test-Path $repoFolder)) {
        Write-Host "Repository folder not found: $repoFolder" -ForegroundColor Red
        throw "Repository folder not found"
    }

    # Phase 1: Framework Migration
    foreach ($project in $projects) {
        if (Update-TargetFramework -ProjectFile $project) {
            $GlobalReport.MigrationResults += [PSCustomObject]@{
                Project = $project.Name
                FrameworkUpdated = $true
            }
        }
    }

    # Phase 2: Dependency Resolution
    foreach ($project in $projects) {
        $updates = Invoke-DependencyResolution -ProjectFile $project
        $GlobalReport.SuccessfulUpdates += $updates
    }

    # Phase 3: Build Verification
    $buildSuccess = Invoke-SolutionBuild -RepoFolder $repoFolder

    # Generate Reports
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder | Out-Null
    }
    
    $reportPath = New-MigrationReport -OutputFolder $OutputFolder
    
    # Only start browser if on Windows and in interactive session
    if ($env:OS -match "Windows" -and [Environment]::UserInteractive) {
        Start-Process $reportPath
    } else {
        Write-Host "Report generated at: $reportPath" -ForegroundColor Green
    }

    # Final Status
    if ($buildSuccess) {
        Write-Host "Migration completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Host "Migration completed with build errors. Check report for details." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Critical error: $_" -ForegroundColor Red
    exit 1
}
finally {
    # Cleanup temp folder
    if ($repoFolder -and (Test-Path $repoFolder) -and $repoFolder.StartsWith($env:TEMP)) {
        Write-Host "Cleaning up temporary repository folder..." -ForegroundColor Cyan
        Remove-Item -Path $repoFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}