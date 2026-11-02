# Checks that THIRD-PARTY-NOTICES.md names every file in BriefBar for Windows' build that BriefBar doesn't build itself,
# in the table of the package it comes from: a row like "| `Package.Id` | 1.2.3 | `File.dll`, `Other.dll` |", with the
# version the build restored (obj\project.assets.json). A file comes from the packages that have the same bytes under
# its name, among those the build restored and those the .NET SDK downloaded for it. It also fails on a file that a
# table names but that no build here has from that table's package, as when the package stops shipping it, and on a
# build whose copy of the notices isn't the current one. Packages that the .NET SDK picks itself, such as the Windows
# SDK's projection, follow whichever SDK builds, so their versions aren't checked. CI runs it on the Release builds for
# x64 and Arm64; run it after you build, and whenever you add, update or remove a package. Build first.
#   scripts\check-notices.ps1 [-Output <folder>[, <folder>...]]   (the Debug build for x64 by default)
param(
    [string[]] $Output = @(Join-Path -Path $PSScriptRoot -ChildPath '..\BriefBar\bin\Debug\net10.0-windows10.0.26100.0\win-x64')
)

$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$app = Join-Path -Path $windows -ChildPath 'BriefBar'
$noticesPath = Join-Path -Path $windows -ChildPath 'THIRD-PARTY-NOTICES.md'
$assetsPath = Join-Path -Path $app -ChildPath 'obj\project.assets.json'
$failures = [System.Collections.Generic.List[string]]::new()

function Fail([string] $what) {
    Write-Host "FAIL  $what"
    $failures.Add($what)
}

# What BriefBar's projects build themselves: the app and BriefBar.Core, their symbols, the app's resources and XAML,
# and these notices. BriefBar.exe is .NET's app host, which the notices name in prose.
$own = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in 'BriefBar.exe', 'BriefBar.dll', 'BriefBar.pdb', 'BriefBar.pri', 'BriefBar.deps.json',
    'BriefBar.runtimeconfig.json', 'BriefBar.Core.dll', 'BriefBar.Core.pdb', 'THIRD-PARTY-NOTICES.md') {
    [void]$own.Add($name)
}
Get-ChildItem -LiteralPath $app -Recurse -File -Filter '*.xaml' |
    Where-Object { $_.FullName.Substring($app.Length) -notmatch '^\\(bin|obj)\\' } |
    ForEach-Object { [void]$own.Add([IO.Path]::ChangeExtension($_.FullName.Substring($app.Length + 1), '.xbf')) }

# The packages' tables, outside the license texts' fences: each package's version, and for each file's name, the
# packages whose tables list it.
$packages = [ordered]@{}
$named = @{}
$inFence = $false
foreach ($line in Get-Content -LiteralPath $noticesPath -Encoding utf8) {
    if ($line -match '^\s*(```|~~~)') {
        $inFence = -not $inFence
        continue
    }
    if ($inFence -or $line -notmatch '^\|\s*`(?<id>[^`]+)`\s*\|\s*(?<version>[0-9][^|\s]*)\s*\|(?<files>.*)\|\s*$') {
        continue
    }
    $id = $Matches['id']
    $packages[$id] = $Matches['version']
    foreach ($file in [regex]::Matches($Matches['files'], '`([^`]+)`')) {
        $name = Split-Path -Path $file.Groups[1].Value -Leaf
        if (-not $named.ContainsKey($name)) { $named[$name] = [System.Collections.Generic.List[string]]::new() }
        if ($named[$name] -notcontains $id) { $named[$name].Add($id) }
    }
}
if ($packages.Count -eq 0) {
    Fail "THIRD-PARTY-NOTICES.md has no package tables"
}

# The versions the build restored, from the NuGet packages it resolved.
if (-not (Test-Path -LiteralPath $assetsPath)) {
    Fail "No $($assetsPath): build BriefBar first"
    exit 1
}
$assets = Get-Content -LiteralPath $assetsPath -Raw -Encoding utf8 | ConvertFrom-Json
$restored = @{}
foreach ($library in $assets.libraries.PSObject.Properties) {
    if ($library.Value.type -eq 'package') {
        $id, $version = $library.Name -split '/', 2
        $restored[$id] = $version
    }
}
$downloaded = @{}
foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
    foreach ($download in $framework.Value.downloadDependencies) {
        $downloaded[$download.name] = $download.version.Trim('[', ']', ' ').Split(',')[0].Trim()
    }
}
foreach ($id in $packages.Keys) {
    if ($restored.ContainsKey($id)) {
        if ($restored[$id] -ne $packages[$id]) {
            Fail "THIRD-PARTY-NOTICES.md says $id $($packages[$id]), but the build has $($restored[$id]): update its row, and its license and notices if they changed"
        }
    } elseif (-not $downloaded.ContainsKey($id)) {
        Fail "THIRD-PARTY-NOTICES.md has a row for $id, which the build doesn't use"
    }
}

# Every file in the packages the build restored, and in those the .NET SDK downloads for it, such as the Windows SDK's
# projection, by name: a file in the build comes from the packages that have the same bytes under its name.
$sources = @{}
foreach ($versions in $restored, $downloaded) {
    foreach ($id in $versions.Keys) {
        foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
            $root = Join-Path -Path $folder -ChildPath "$($id.ToLowerInvariant())\$($versions[$id])"
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
                if (-not $sources.ContainsKey($file.Name)) { $sources[$file.Name] = [System.Collections.Generic.List[object]]::new() }
                $sources[$file.Name].Add([pscustomobject]@{ Package = "$id $($versions[$id])"; Id = $id; File = $file })
            }
            break
        }
    }
}
$hashes = @{}
function Get-Hash([IO.FileInfo] $file) {
    if (-not $hashes.ContainsKey($file.FullName)) {
        $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes[$file.FullName]
}
function Find-Packages([IO.FileInfo] $file) {
    $found = [System.Collections.Generic.List[object]]::new()
    if ($sources.ContainsKey($file.Name)) {
        foreach ($candidate in $sources[$file.Name]) {
            if ($candidate.File.Length -eq $file.Length -and (Get-Hash $candidate.File) -eq (Get-Hash $file) -and
                -not ($found | Where-Object { $_.Id -eq $candidate.Id })) {
                $found.Add($candidate)
            }
        }
    }
    return , $found
}

foreach ($folder in $Output) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Fail "No build in $($folder): build BriefBar first"
        exit 1
    }
}
$shipped = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
# Each file name in the builds with each package it comes from, "Package.Id|File.dll", and the names already reported.
$shippedFrom = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$reported = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($folder in $Output) {
    $root = (Resolve-Path -LiteralPath $folder).Path.TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        $relative = $file.FullName.Substring($root.Length + 1)
        [void]$shipped.Add($file.Name)
        if ($own.Contains($relative)) { continue }
        $from = Find-Packages $file
        foreach ($source in $from) { [void]$shippedFrom.Add("$($source.Id)|$($file.Name)") }
        if ($from.Count -eq 0) { [void]$reported.Add($file.Name) }
        $where = 'it comes from ' + (($from | ForEach-Object { $_.Package } | Sort-Object) -join ' or ')
        if (-not $named.ContainsKey($file.Name)) {
            if ($from.Count -eq 0) { $where = 'find where it comes from' }
            Fail "$relative, in $root, isn't in THIRD-PARTY-NOTICES.md: $where; add it to that package's table, with the package's license and notices"
        } elseif ($from.Count -eq 0) {
            Fail "$relative, in $root, is in no package the build restored, though THIRD-PARTY-NOTICES.md names it under $($named[$file.Name] -join ' and '): find where it comes from"
        } elseif (-not ($from | Where-Object { $named[$file.Name] -contains $_.Id })) {
            [void]$reported.Add($file.Name)
            Fail "THIRD-PARTY-NOTICES.md names $relative under $($named[$file.Name] -join ' and '), but $where, in $($root): move it to that package's table, with the package's license and notices"
        }
    }
    $copy = Join-Path -Path $root -ChildPath 'THIRD-PARTY-NOTICES.md'
    if (-not (Test-Path -LiteralPath $copy)) {
        Fail "$root has no THIRD-PARTY-NOTICES.md"
    } elseif ((Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $noticesPath).Hash) {
        Fail "THIRD-PARTY-NOTICES.md in $root isn't the current one: build again"
    }
}
# And the other way: each file a table names must be in a build, from that table's package.
foreach ($name in $named.Keys) {
    if ($reported.Contains($name)) { continue }
    foreach ($id in $named[$name]) {
        if ($shippedFrom.Contains("$id|$name")) { continue }
        if ($shipped.Contains($name)) {
            Fail "THIRD-PARTY-NOTICES.md names $name under $id, but the build's $name doesn't come from $($id): take it out of that table"
        } else {
            Fail "THIRD-PARTY-NOTICES.md names $name under $id, but the build doesn't have it: take it out of that table"
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) problem(s) with THIRD-PARTY-NOTICES.md."
    exit 1
}
Write-Host "ok    THIRD-PARTY-NOTICES.md names every file from someone else in $($Output.Count) build(s): $($named.Count) files from $($packages.Count) packages, at the versions restored"
exit 0
