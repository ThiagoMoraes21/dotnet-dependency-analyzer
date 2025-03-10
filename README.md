
# ANALYZE PACKAGES COMPATIBILITES

- Execute the following script in the powershell, changes the keys:
```powershell
    powershell -ExecutionPolicy Bypass -File .\dotnet-dependency-analyzer.ps1 `
        -RepoUrl "PROJECT_REPO_URL_GOES_HERE" `
        -Branch "branch_name" `
        -PrivateNuGetSources @("PRIVATE_NUGET_PACKAGE_URL") `
        -PrivateNuGetUsername "username" `
        -PrivateNuGetPassword "password" `
        -PersonalAccessToken "personal_access_token"
```

# UPDATE PACKAGES
```powershell
    powershell -ExecutionPolicy Bypass -File .\dotnet-dependency-analyzer-2.ps1 `
        -RepoUrl "PROJECT_REPO_URL_GOES_HERE" `
        -Branch "branch_name" `
        -PrivateNuGetSources @("PRIVATE_NUGET_PACKAGE_URL") `
        -PrivateNuGetUsername "username" `
        -PrivateNuGetPassword "password" `
        -PersonalAccessToken "personal_access_token"
```



