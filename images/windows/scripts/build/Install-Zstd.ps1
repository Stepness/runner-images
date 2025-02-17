################################################################################
##  File:  Install-Zstd.ps1
##  Desc:  Install zstd
################################################################################

$url = "https://api.github.com/repos/facebook/zstd/releases/latest"
# Explicitly set type to string since match returns array by default
[System.String] $zstdLatest = (Invoke-RestMethod -Uri $url).assets.browser_download_url -match "zstd-.+-win64.zip$"
$zstdArchivePath = Invoke-DownloadWithRetry $zstdLatest

$toolPath = "C:\tools"
$zstdPath = Join-Path $toolPath zstd
$zstdParentName = [IO.Path]::GetFileNameWithoutExtension($zstdLatest)
$filesInArchive = 7z l $zstdArchivePath | Out-String

if ($filesInArchive.Contains($zstdParentName)) {
    Expand-7ZipArchive -Path $zstdArchivePath -DestinationPath $toolPath
    Invoke-ScriptBlockWithRetry -Command {
        Move-Item -Path "${zstdPath}*" -Destination $zstdPath -ErrorAction Stop
    }
} else {
    Expand-7ZipArchive -Path $zstdArchivePath -DestinationPath $zstdPath
}

# Add zstd-win64 to PATH
Add-MachinePathItem $zstdPath

Invoke-PesterTests -TestFile "Tools" -TestName "Zstd"
