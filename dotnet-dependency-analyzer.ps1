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

# Function to ensure required tools are installed
function Ensure-RequiredTools {
    Write-Host "Checking for required tools..." -ForegroundColor Cyan
    
    # Check for .NET SDK
    try {
        $dotnetVersion = dotnet --version
        Write-Host "Found .NET SDK: $dotnetVersion" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: .NET SDK not found. Please install .NET SDK 8.0 or later." -ForegroundColor Red
        exit 1
    }
    
    # Check for and install .NET Upgrade Assistant if needed
    try {
        # Check if the tool is already installed
        $upgradeAssistant = dotnet tool list -g | Select-String "upgrade-assistant"
        
        if (-not $upgradeAssistant) {
            Write-Host "Installing .NET Upgrade Assistant..." -ForegroundColor Yellow
            $result = dotnet tool install -g upgrade-assistant
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to install upgrade-assistant with exit code: $LASTEXITCODE"
            }
            
            # Verify installation
            $upgradeAssistant = dotnet tool list -g | Select-String "upgrade-assistant"
            if (-not $upgradeAssistant) {
                throw "Installation appeared to succeed but tool not found in list"
            }
            
            # Refresh environment path to ensure the tool is accessible
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            
            Write-Host "Successfully installed .NET Upgrade Assistant" -ForegroundColor Green
        }
        else {
            Write-Host "Found .NET Upgrade Assistant: $upgradeAssistant" -ForegroundColor Green
        }
        
        # Test if upgrade-assistant can be called
        try {
            $testOutput = upgrade-assistant --version 2>&1
            Write-Host "Upgrade Assistant is working: $testOutput" -ForegroundColor Green
        }
        catch {
            # Try using the full path
            $dotnetToolsPath = "$env:USERPROFILE\.dotnet\tools"
            $upgradeAssistantPath = Join-Path $dotnetToolsPath "upgrade-assistant.exe"
            
            if (Test-Path $upgradeAssistantPath) {
                Write-Host "Found upgrade-assistant at: $upgradeAssistantPath" -ForegroundColor Yellow
                Write-Host "Adding .NET Tools directory to PATH for this session..." -ForegroundColor Yellow
                $env:Path = "$dotnetToolsPath;$env:Path"
                
                # Create an alias for this session
                Set-Alias -Name upgrade-assistant -Value $upgradeAssistantPath -Scope Global
                
                # Test again
                $testOutput = upgrade-assistant --version 2>&1
                Write-Host "Upgrade Assistant is now working: $testOutput" -ForegroundColor Green
            }
            else {
                throw "Cannot locate upgrade-assistant executable"
            }
        }
    }
    catch {
        Write-Host "WARNING: Failed to setup .NET Upgrade Assistant. Details: $_" -ForegroundColor Yellow
        Write-Host "The script will continue, but project analysis will be limited." -ForegroundColor Yellow
        
        # Provide a fallback approach for users
        Write-Host "To manually install the tool, run: dotnet tool install -g upgrade-assistant" -ForegroundColor Yellow
        Write-Host "You may need to restart your terminal after installation." -ForegroundColor Yellow
        
        # Set a global flag to indicate missing tool
        $global:upgradeAssistantMissing = $true
    }
}

# Function to clone the repository
function Clone-Repository {
    Write-Host "Cloning repository from: $RepoUrl" -ForegroundColor Cyan
    
    $repoFolder = ".\TempRepo"
    if (Test-Path $repoFolder) {
        Remove-Item -Path $repoFolder -Recurse -Force
    }
    
    # Create credential string if PAT is provided
    if ($PersonalAccessToken) {
        $encodedPAT = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("`:$PersonalAccessToken"))
        $authHeader = @{Authorization = "Basic $encodedPAT"}
        
        # Extract the repo URL without auth for git clone
        $uri = [System.Uri]$RepoUrl
        $authUrl = "https://$encodedPAT@$($uri.Host)$($uri.PathAndQuery)"
        
        git clone $authUrl $repoFolder --branch $Branch
    }
    else {
        git clone $RepoUrl $repoFolder --branch $Branch
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to clone repository. Check your URL and credentials." -ForegroundColor Red
        exit 1
    }
    
    return $repoFolder
}

# Function to find all .NET projects
function Find-DotNetProjects {
    param (
        [string]$BasePath
    )
    
    Write-Host "Finding .NET projects..." -ForegroundColor Cyan
    
    $projectFiles = Get-ChildItem -Path $BasePath -Recurse -Include "*.csproj","*.fsproj" -ErrorAction SilentlyContinue
    
    Write-Host "Found $($projectFiles.Count) project files." -ForegroundColor Green
    
    return $projectFiles
}

# Function to analyze .csproj package references
function Analyze-ProjectPackages {
    param (
        [System.IO.FileInfo]$ProjectFile
    )
    
    Write-Host "Analyzing packages for: $($ProjectFile.Name)" -ForegroundColor Cyan
    
    # Create a custom object to store project info
    $projectInfo = [PSCustomObject]@{
        ProjectName = $ProjectFile.BaseName
        ProjectPath = $ProjectFile.FullName
        TargetFramework = ""
        NeedsMigration = $false
        Packages = @()
        TransitiveDependencies = @()
        UpgradeAssistantAnalysis = ""
    }
    
    # Read the project file
    $projectXml = [xml](Get-Content $ProjectFile.FullName)
    $ns = New-Object System.Xml.XmlNamespaceManager($projectXml.NameTable)
    $ns.AddNamespace("ms", "http://schemas.microsoft.com/developer/msbuild/2003")
    
    # Get target framework
    $tfm = $projectXml.Project.PropertyGroup | 
           Where-Object { $_ } | 
           ForEach-Object { $_.TargetFramework } | 
           Where-Object { $_ } | 
           Select-Object -First 1
    
    if (-not $tfm) {
        $tfms = $projectXml.Project.PropertyGroup | 
                Where-Object { $_ } | 
                ForEach-Object { $_.TargetFrameworks } | 
                Where-Object { $_ } | 
                Select-Object -First 1
                
        if ($tfms) {
            $tfm = ($tfms -split ';') | Select-Object -First 1
        }
    }
    
    $projectInfo.TargetFramework = $tfm
    
    # Determine if migration is needed
    if ($tfm -match "netcoreapp3.1" -or 
        $tfm -match "net5.0" -or
        $tfm -match "net6.0" -or
        $tfm -match "net7.0" -or
        $tfm -match "netstandard2.0" -or
        $tfm -match "netstandard2.1" -or
        $tfm -match "net4" -or 
        $tfm -match "net3" -or
        $tfm -match "net2") {
        $projectInfo.NeedsMigration = $true
    }
    
    # Get package references
    $packageRefs = $projectXml.Project.ItemGroup | 
                  Where-Object { $_ } | 
                  ForEach-Object { $_.PackageReference } | 
                  Where-Object { $_ }
    
    foreach ($pkg in $packageRefs) {
        $packageInfo = [PSCustomObject]@{
            Name = $pkg.Include
            Version = $pkg.Version
            IsCompatibleWithNet8 = $null
            LatestVersion = ""
            Notes = ""
            IsPrivate = $false
            FoundInPrivateSource = $false
            PrivateSourceUrl = ""
        }
        
        $projectInfo.Packages += $packageInfo
    }
    
    # Get transitive dependencies if possible
    try {
        $transitiveDeps = & dotnet list $ProjectFile.FullName package --include-transitive | Out-String
        $projectInfo.TransitiveDependencies = $transitiveDeps
    }
    catch {
        $projectInfo.TransitiveDependencies = "Failed to retrieve transitive dependencies"
    }
    
    # Run Upgrade Assistant analysis if migration is needed
    if ($projectInfo.NeedsMigration) {
        try {
            # Check if upgrade-assistant is available
            if ($global:upgradeAssistantMissing) {
                $projectInfo.UpgradeAssistantAnalysis = "Upgrade Assistant not available. Manual analysis required."
            }
            else {
                Write-Host "Running .NET Upgrade Assistant analysis..." -ForegroundColor Yellow
                
                # Try to run with direct command
                try {
                    $analysisOutput = upgrade-assistant analyze $ProjectFile.FullName --target-tfm-support net8.0 2>&1 | Out-String
                }
                catch {
                    # Fallback to dotnet tool run
                    Write-Host "  Fallback: Using dotnet tool run approach..." -ForegroundColor Yellow
                    $analysisOutput = dotnet tool run upgrade-assistant analyze $ProjectFile.FullName --target-tfm-support net8.0 2>&1 | Out-String
                }
                
                $projectInfo.UpgradeAssistantAnalysis = $analysisOutput
            }
        }
        catch {
            $projectInfo.UpgradeAssistantAnalysis = "Failed to run Upgrade Assistant: $_"
            
            # Add basic analysis as a fallback
            $projectInfo.UpgradeAssistantAnalysis += "`n`nBasic Compatibility Analysis:`n"
            $projectInfo.UpgradeAssistantAnalysis += "- Project targets $($projectInfo.TargetFramework) and needs migration to .NET 8.0`n"
            $projectInfo.UpgradeAssistantAnalysis += "- Contains $($projectInfo.Packages.Count) direct package dependencies`n"
            
            # Look for well-known problematic dependencies
            $problematicPackages = $projectInfo.Packages | Where-Object { 
                $_.Name -match "Newtonsoft.Json" -or 
                $_.Name -match "Microsoft.AspNetCore.Mvc" -or
                $_.Name -match "Microsoft.AspNetCore.App" -or
                $_.Name -match "Microsoft.EntityFrameworkCore" -or
                $_.Name -match "System.Data.SqlClient"
            }
            
            if ($problematicPackages) {
                $projectInfo.UpgradeAssistantAnalysis += "- Found potentially problematic packages that may need updates:`n"
                foreach ($pkg in $problematicPackages) {
                    $projectInfo.UpgradeAssistantAnalysis += "  * $($pkg.Name) ($($pkg.Version))`n"
                }
            }
        }
    }
    
    return $projectInfo
}

# Function to check if a package exists in private NuGet sources
function Check-PrivateNuGetSource {
    param (
        [string]$PackageName,
        [string]$SourceUrl,
        [string]$Username,
        [string]$Password
    )
    
    try {
        $headers = @{}
        
        # Add authentication if provided
        if ($Username -and $Password) {
            $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $Username, $Password)))
            $headers.Add("Authorization", ("Basic {0}" -f $base64AuthInfo))
        }
        
        # Construct the URL to check if the package exists
        $apiUrl = "$SourceUrl/v3/registration5-semver1/$($PackageName.ToLower())/index.json"
        
        # Invoke the REST method with error handling
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction SilentlyContinue
        
        # If we get here, the package exists in this source
        return @{
            Exists = $true
            LatestVersion = ($response.items | 
                            Select-Object -ExpandProperty items | 
                            Select-Object -ExpandProperty catalogEntry | 
                            Sort-Object -Property version -Descending | 
                            Select-Object -First 1).version
            SourceUrl = $SourceUrl
        }
    }
    catch {
        # Package not found or other error
        return @{
            Exists = $false
            LatestVersion = ""
            SourceUrl = $SourceUrl
        }
    }
}

# Function to check NuGet package compatibility with .NET 8
function Check-PackageCompatibility {
    param (
        [array]$Projects
    )
    
    Write-Host "Checking package compatibility with .NET 8.0..." -ForegroundColor Cyan
    
    $uniquePackages = @{}
    
    # Collect all unique packages
    foreach ($project in $Projects) {
        foreach ($package in $project.Packages) {
            $key = "$($package.Name)/$($package.Version)"
            if (-not $uniquePackages.ContainsKey($key)) {
                $uniquePackages[$key] = $package
            }
        }
    }
    
    $total = $uniquePackages.Count
    $current = 0
    $privatePackages = @()
    
    # Check each package
    foreach ($key in $uniquePackages.Keys) {
        $current++
        $package = $uniquePackages[$key]
        
        Write-Progress -Activity "Checking NuGet packages" -Status "Checking $($package.Name)" -PercentComplete (($current / $total) * 100)
        
        try {
            # First try registration API (catalog-based)
            $apiUrl = "https://api.nuget.org/v3/registration5-semver1/$($package.Name.ToLower())/index.json"
            $response = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue
            
            # Check if we have the expected structure
            $latestVersion = $null
            $supportsNet8 = $false
            
            # Try to get latest version from registration API
            if ($response.items -and $response.items.Count -gt 0) {
                try {
                    $LatestVersion = $response.items[-1].items |
                        Select-Object -ExpandProperty catalogEntry -ErrorAction SilentlyContinue |
                        Where-Object { $_.version -notmatch "-" } | # Exclude pre-release versions
                        Sort-Object -Property version -Descending |
                        Select-Object -First 1
                }
                catch {
                    Write-Host "  Warning: Could not parse catalog structure for $($package.Name), trying alternative method..." -ForegroundColor Yellow
                }
            }
            
            # If we couldn't get latest version from registration API, try direct package API
            if (-not $latestVersion) {
                try {
                    # Try the package versions endpoint instead
                    $versionsUrl = "https://api.nuget.org/v3-flatcontainer/$($package.Name.ToLower())/index.json"
                    $versionsResponse = Invoke-RestMethod -Uri $versionsUrl -ErrorAction SilentlyContinue
                    
                    if ($versionsResponse.versions -and $versionsResponse.versions.Count -gt 0) {
                        $latestVersionString = $versionsResponse.versions | Sort-Object -Descending | Select-Object -First 1
                        
                        # Create a custom object to simulate the catalogEntry
                        $latestVersion = [PSCustomObject]@{
                            version = $latestVersionString
                        }
                        
                        # Now check compatibility by downloading the nuspec
                        $nuspecUrl = "https://api.nuget.org/v3-flatcontainer/$($package.Name.ToLower())/$latestVersionString/$($package.Name.ToLower()).nuspec"
                        try {
                            $nuspecResponse = Invoke-RestMethod -Uri $nuspecUrl -ErrorAction SilentlyContinue
                            
                            # Parse the nuspec to check for target frameworks
                            if ($nuspecResponse.package.metadata.dependencies.group) {
                                foreach ($group in $nuspecResponse.package.metadata.dependencies.group) {
                                    $targetFramework = $group.targetFramework
                                    if ($targetFramework -eq ".NETCoreApp8.0" -or 
                                        $targetFramework -eq "net8.0" -or 
                                        $targetFramework -eq ".NETStandard2.0" -or 
                                        $targetFramework -eq "netstandard2.0" -or 
                                        $targetFramework -eq "netstandard2.1" -or 
                                        $targetFramework -eq ".NETStandard2.1") {
                                        $supportsNet8 = $true
                                        break
                                    }
                                }
                            }
                            # If no specific target frameworks, check for netstandard
                            elseif ($nuspecResponse.package.metadata.dependencies) {
                                # Assume it works if it's not framework-specific
                                $supportsNet8 = $true
                            }
                        }
                        catch {
                            Write-Host "  Warning: Could not download nuspec for $($package.Name) $latestVersionString" -ForegroundColor Yellow
                        }
                    }
                }
                catch {
                    Write-Host "  Warning: Failed to get versions for $($package.Name) via alternative method" -ForegroundColor Yellow
                }
            }
            # Process the data from registration API if we got it
            else {
                # Check if it supports .NET 8
                if ($latestVersion.dependencyGroups) {
                    foreach ($depGroup in $latestVersion.dependencyGroups) {
                        if ($depGroup.targetFramework -eq ".NETCoreApp8.0" -or 
                            $depGroup.targetFramework -eq "net8.0" -or 
                            $depGroup.targetFramework -eq ".NETStandard2.0" -or 
                            $depGroup.targetFramework -eq ".NETStandard2.1") {
                            $supportsNet8 = $true
                            break
                        }
                    }
                }
            }
            
            # Special handling for well-known packages
            if ($package.Name -eq "AutoMapper") {
                # AutoMapper 12.0.0+ supports .NET 6.0 and higher
                # We can explicitly check version numbers for well-known packages
                if ($latestVersion -and [version]::TryParse(($latestVersion.version -replace '[^\d\.]'), [ref]$null)) {
                    $versionObj = [version]($latestVersion.version -replace '[^\d\.]')
                    if ($versionObj -ge [version]"12.0.0") {
                        $supportsNet8 = $true
                    }
                    else {
                        $supportsNet8 = $false
                    }
                }
            }
            
            # Update package info
            if ($latestVersion) {
                $package.LatestVersion = $latestVersion.version
                $package.IsCompatibleWithNet8 = $supportsNet8
                
                if (-not $supportsNet8) {
                    $package.Notes = "May not support .NET 8.0 directly"
                }
            }
            else {
                $package.IsCompatibleWithNet8 = $false
                $package.Notes = "Could not determine compatibility"
            }
        }
        catch {
            # Not found in public NuGet - check private sources if specified
            $foundInPrivate = $false
            
            if ($PrivateNuGetSources.Count -gt 0 -and ($null -eq $response -or $_.Exception.Response.StatusCode -eq 404)) {
                Write-Host "  Checking private NuGet sources for $($package.Name)..." -ForegroundColor Yellow
                
                foreach ($source in $PrivateNuGetSources) {
                    $result = Check-PrivateNuGetSource -PackageName $package.Name -SourceUrl $source -Username $PrivateNuGetUsername -Password $PrivateNuGetPassword
                    
                    if ($result.Exists) {
                        $foundInPrivate = $true
                        $package.IsPrivate = $true
                        $package.FoundInPrivateSource = $true
                        $package.PrivateSourceUrl = $result.SourceUrl
                        $package.LatestVersion = $result.LatestVersion
                        $package.Notes = "PRIVATE PACKAGE (Found in: $($result.SourceUrl))"
                        $privatePackages += "$($package.Name) [$($result.SourceUrl)]"
                        break
                    }
                }
            }
            
            # If not found in any private source either
            if (-not $foundInPrivate) {
                $package.IsPrivate = $true
                $package.IsCompatibleWithNet8 = $null
                $package.Notes = "PRIVATE PACKAGE: Manual verification required"
                $privatePackages += "$($package.Name) [Unknown Source]"
            }
        }
    }
    
    Write-Progress -Activity "Checking NuGet packages" -Completed
    
    # Update all projects with compatibility info
    foreach ($project in $Projects) {
        foreach ($package in $project.Packages) {
            $key = "$($package.Name)/$($package.Version)"
            if ($uniquePackages.ContainsKey($key)) {
                $package.IsCompatibleWithNet8 = $uniquePackages[$key].IsCompatibleWithNet8
                $package.LatestVersion = $uniquePackages[$key].LatestVersion
                $package.Notes = $uniquePackages[$key].Notes
                $package.IsPrivate = $uniquePackages[$key].IsPrivate
                $package.FoundInPrivateSource = $uniquePackages[$key].FoundInPrivateSource
                $package.PrivateSourceUrl = $uniquePackages[$key].PrivateSourceUrl
            }
        }
    }
    
    # Log private packages
    if ($privatePackages.Count -gt 0) {
        Write-Host "Found $($privatePackages.Count) private packages:" -ForegroundColor Yellow
        foreach ($pkg in $privatePackages) {
            Write-Host "  - $pkg" -ForegroundColor Yellow
        }
    }
    
    return $Projects
}

# Function to generate a report
function Generate-Report {
    param (
        [array]$Projects,
        [string]$OutputFolder,
        [array]$PrivateNuGetSources
    )
    
    Write-Host "Generating report..." -ForegroundColor Cyan
    
    # Create output folder if it doesn't exist
    if (-not (Test-Path $OutputFolder)) {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    }
    
    # Count private packages
    $privatePackages = @()
    $privatePackagesFound = @()
    $privatePackagesUnknown = @()
    
    foreach ($project in $Projects) {
        foreach ($package in $project.Packages) {
            if ($package.IsPrivate) {
                $packageInfo = [PSCustomObject]@{
                    Name = $package.Name
                    FoundInPrivateSource = $package.FoundInPrivateSource
                    PrivateSourceUrl = $package.PrivateSourceUrl
                }
                
                # Check if we already have this package
                $exists = $false
                foreach ($pkg in $privatePackages) {
                    if ($pkg.Name -eq $package.Name) {
                        $exists = $true
                        break
                    }
                }
                
                if (-not $exists) {
                    $privatePackages += $packageInfo
                    
                    if ($package.FoundInPrivateSource) {
                        $privatePackagesFound += "$($package.Name) [$($package.PrivateSourceUrl)]"
                    } else {
                        $privatePackagesUnknown += $package.Name
                    }
                }
            }
        }
    }
    
    # Create a summary HTML report
    $htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <title>.NET 8.0 Migration Analysis</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1, h2, h3 { color: #0066cc; }
        table { border-collapse: collapse; width: 100%; margin-bottom: 20px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        .compatible { color: green; }
        .incompatible { color: red; }
        .unknown { color: orange; }
        .private { color: purple; font-weight: bold; }
        .private-found { color: #6d28d9; }
        .project-card { border: 1px solid #ddd; padding: 15px; margin-bottom: 20px; border-radius: 5px; }
        .project-header { display: flex; justify-content: space-between; align-items: center; }
        .needs-migration { background-color: #fff8e1; }
        .no-migration { background-color: #e8f5e9; }
        summary { cursor: pointer; font-weight: bold; }
        .private-packages-alert { background-color: #e1e5f2; border-left: 5px solid #6d28d9; padding: 15px; margin-bottom: 20px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>.NET 8.0 Migration Analysis Report</h1>
    <p>Generated on $(Get-Date)</p>
    
    <h2>Summary</h2>
    <p>Total Projects: $($Projects.Count)</p>
    <p>Projects Needing Migration: $($Projects | Where-Object { $_.NeedsMigration } | Measure-Object | Select-Object -ExpandProperty Count)</p>
    
"@

    # Add private packages section
    if ($privatePackages.Count -gt 0) {
        $htmlReport += @"
    <div class="private-packages-alert">
        <h3>Private NuGet Packages</h3>
        <p>Found $($privatePackages.Count) private packages:</p>
"@

        if ($privatePackagesFound.Count -gt 0) {
            $htmlReport += @"
        <h4>Packages Found in Private Sources ($($privatePackagesFound.Count)):</h4>
        <ul>
"@
            foreach ($pkg in $privatePackagesFound) {
                $htmlReport += @"
            <li class="private-found">$pkg</li>
"@
            }
            $htmlReport += @"
        </ul>
"@
        }

        if ($privatePackagesUnknown.Count -gt 0) {
            $htmlReport += @"
        <h4>Packages Requiring Manual Verification ($($privatePackagesUnknown.Count)):</h4>
        <ul>
"@
            foreach ($pkg in $privatePackagesUnknown) {
                $htmlReport += @"
            <li>$pkg</li>
"@
            }
            $htmlReport += @"
        </ul>
        <p>These packages require manual verification for .NET 8.0 compatibility.</p>
"@
        }

        $htmlReport += @"
    </div>
"@
    }

    # Add private NuGet sources section if specified
    if ($PrivateNuGetSources.Count -gt 0) {
        $htmlReport += @"
    <div class="private-packages-alert" style="background-color: #e8f5e9; border-left-color: #2e7d32;">
        <h3>Private NuGet Sources Checked</h3>
        <ul>
"@
        foreach ($source in $PrivateNuGetSources) {
            $htmlReport += @"
            <li>$source</li>
"@
        }
        $htmlReport += @"
        </ul>
    </div>
"@
    }
    
    $htmlReport += @"
    <h2>Projects</h2>
"@

    foreach ($project in $Projects) {
        $projectClass = if ($project.NeedsMigration) { "needs-migration" } else { "no-migration" }
        
        $htmlReport += @"
    <div class="project-card $projectClass">
        <div class="project-header">
            <h3>$($project.ProjectName)</h3>
            <span>Target Framework: $($project.TargetFramework)</span>
        </div>
        <p>Path: $($project.ProjectPath)</p>
        <p>Needs Migration: $($project.NeedsMigration)</p>
        
        <details>
            <summary>Package Dependencies ($($project.Packages.Count))</summary>
            <table>
                <tr>
                    <th>Package</th>
                    <th>Current Version</th>
                    <th>Latest Version</th>
                    <th>.NET 8.0 Compatible</th>
                    <th>Private Package</th>
                    <th>Notes</th>
                </tr>
"@

        foreach ($package in $project.Packages) {
            $compatClass = if ($package.IsPrivate) {
                              if ($package.FoundInPrivateSource) { "private-found" } else { "private" }
                          }
                          elseif ($package.IsCompatibleWithNet8 -eq $true) { "compatible" } 
                          elseif ($package.IsCompatibleWithNet8 -eq $false) { "incompatible" } 
                          else { "unknown" }
            
            $htmlReport += @"
                <tr>
                    <td>$($package.Name)</td>
                    <td>$($package.Version)</td>
                    <td>$($package.LatestVersion)</td>
                    <td class="$compatClass">$($package.IsCompatibleWithNet8)</td>
                    <td>$($package.IsPrivate)</td>
                    <td>$($package.Notes)</td>
                </tr>
"@
        }

        $htmlReport += @"
            </table>
        </details>
"@

        if ($project.NeedsMigration) {
            $htmlReport += @"
        <details>
            <summary>Upgrade Assistant Analysis</summary>
            <pre>$($project.UpgradeAssistantAnalysis)</pre>
        </details>
"@
        }

        $htmlReport += @"
    </div>
"@
    }

    $htmlReport += @"
</body>
</html>
"@

    # Save the HTML report
    $htmlReportPath = Join-Path $OutputFolder "migration-analysis.html"
    $htmlReport | Out-File -FilePath $htmlReportPath -Encoding utf8
    
    # Create separate private packages report
    if ($privatePackages.Count -gt 0) {
        $privatePackagesPath = Join-Path $OutputFolder "private-packages.txt"
        $privatePackagesOutput = "# Private NuGet Packages`n`n"
        
        if ($privatePackagesFound.Count -gt 0) {
            $privatePackagesOutput += "## Packages Found in Private Sources ($($privatePackagesFound.Count)):`n"
            foreach ($pkg in $privatePackagesFound) {
                $privatePackagesOutput += "- $pkg`n"
            }
            $privatePackagesOutput += "`n"
        }
        
        if ($privatePackagesUnknown.Count -gt 0) {
            $privatePackagesOutput += "## Packages Requiring Manual Verification ($($privatePackagesUnknown.Count)):`n"
            foreach ($pkg in $privatePackagesUnknown) {
                $privatePackagesOutput += "- $pkg`n"
            }
        }
        
        $privatePackagesOutput | Out-File -FilePath $privatePackagesPath -Encoding utf8
    }
    
    # Save detailed project data as JSON
    $jsonReportPath = Join-Path $OutputFolder "migration-analysis.json"
    $Projects | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonReportPath -Encoding utf8
    
    Write-Host "Report generated at:" -ForegroundColor Green
    Write-Host "  HTML: $htmlReportPath" -ForegroundColor Green
    Write-Host "  JSON: $jsonReportPath" -ForegroundColor Green
    
    if ($privatePackages.Count -gt 0) {
        Write-Host "  Private Packages: $privatePackagesPath" -ForegroundColor Yellow
    }
    
    return $htmlReportPath
}

# Main execution
Ensure-RequiredTools

# Display private NuGet sources if specified
if ($PrivateNuGetSources.Count -gt 0) {
    Write-Host "Private NuGet sources that will be checked:" -ForegroundColor Cyan
    foreach ($source in $PrivateNuGetSources) {
        Write-Host "  - $source" -ForegroundColor Cyan
    }
    
    if ($PrivateNuGetUsername) {
        Write-Host "Using provided authentication for private NuGet sources" -ForegroundColor Cyan
    }
}

$repoFolder = Clone-Repository
$projects = Find-DotNetProjects -BasePath $repoFolder
$projectInfos = @()

# Analyze each project
foreach ($project in $projects) {
    $projectInfo = Analyze-ProjectPackages -ProjectFile $project
    $projectInfos += $projectInfo
}

# Check package compatibility
$projectInfos = Check-PackageCompatibility -Projects $projectInfos

# Generate report
$reportPath = Generate-Report -Projects $projectInfos -OutputFolder $OutputFolder -PrivateNuGetSources $PrivateNuGetSources

# Open the report
Start-Process $reportPath

# Cleanup
Write-Host "Cleaning up temporary files..." -ForegroundColor Cyan
Remove-Item -Path $repoFolder -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Analysis complete!" -ForegroundColor Green