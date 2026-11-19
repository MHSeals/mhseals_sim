# SPDX-License-Identifier: GPL-3.0-or-later
# MHSeals RoboBoat simulator installer for Windows (Windows PowerShell 5.1 and PowerShell 7).
#
#   irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1))) -Dir D:\sim
#   powershell -ExecutionPolicy Bypass -File install\install.ps1 -Help
#
# Components (run in this order): base, vulkan (Linux only; skipped here), unity-hub, unity-editor, repo.
# Under `irm | iex` parameters cannot be passed, so the MHSEALS_* environment variables are read too:
#   MHSEALS_DIR, MHSEALS_BRANCH, MHSEALS_REPO, MHSEALS_COMPONENTS, MHSEALS_YES, MHSEALS_DRY_RUN
# The script is not elevated: each installer asks for UAC itself. No telemetry.
#
# Sources for the URLs used here (checked 2026-11-19):
#   winget ids Git.Git, GitHub.GitLFS, Unity.UnityHub, Unity.CLI: https://github.com/microsoft/winget-pkgs (manifests/)
#   Unity Hub installer (UnityHubSetup.exe 404s; the -x64/-arm64 names are current): https://public-cdn.cloud.unity3d.com/hub/prod/
#   Hub /S silent install: https://docs.unity3d.com/2020.1/Documentation/Manual/GettingStartedHubAdvancedConsiderations.html
#   Hub CLI (`-- --headless`, Hub 3 only; Hub 4 removed it): https://docs.unity.com/en-us/hub/hub-cli
#   Unity CLI (`unity`, winget Unity.CLI or https://unity.com/install.ps1): https://docs.unity.com/en-us/unity-cli/use-unity-cli
#   Editor /S /D= silent install: https://docs.unity3d.com/Manual/InstallingUnity.html
#   Editor and module URLs and md5: https://services.api.unity.com/unity/editor/release/v1/releases?version=6000.5.10f1
#   Git for Windows: https://api.github.com/repos/git-for-windows/git/releases/latest
# The parameters are read in the child scope at the bottom (& { }), which the analyzer cannot follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "")]
param(
  [string]$Dir = "",
  [string]$Branch = "",
  [string]$Repo = "",
  [string]$Components = "",
  [switch]$DryRun,
  [switch]$Yes,
  [switch]$WithLinuxBuild,
  [switch]$WithWindowsBuild,
  [switch]$Open,
  [switch]$Help
)

function Invoke-MhsealsInstall {
  # $Yes and $DryRun are read by the nested helpers (dynamic scope), which the analyzer cannot see.
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSReviewUnusedParameter", "")]
  param([string]$Dir, [string]$Branch, [string]$Repo, [string]$Components,
        [bool]$DryRun, [bool]$Yes, [bool]$WithLinuxBuild, [bool]$Open)

  # Everything is scoped to this function, so `irm | iex` leaves the caller's session settings alone.
  $ErrorActionPreference = "Continue"   # native tools are checked through $LASTEXITCODE
  $ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is many times slower with its progress bar
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose "TLS 1.2: $_" }

  $UnityVersion = "6000.5.10f1"
  $UnityChangeset = "3bd4f66ad299"
  $DownloadBase = "https://download.unity3d.com/download_unity/$UnityChangeset"
  $EditorUrl = "$DownloadBase/Windows64EditorInstaller/UnitySetup64-$UnityVersion.exe"
  $EditorMd5 = "7c56b6f2c147fec7d54a7daf6a7d55fe"      # md5-fFa28sFH/sfVSn2van1V/g==
  $LinuxMonoUrl = "$DownloadBase/TargetSupportInstaller/UnitySetup-Linux-Mono-Support-for-Editor-$UnityVersion.exe"
  $LinuxMonoMd5 = "46ea7907facc99a84d4e45a4c2d5fb84"   # md5-Rup5B/rMmahNTkWkwtX7hA==
  $AllComponents = @("base", "vulkan", "unity-hub", "unity-editor", "repo")

  $onWindows = ($PSVersionTable.PSEdition -eq "Desktop") -or ($IsWindows -eq $true)
  # [IO.Path]::Combine, not Join-Path: Join-Path rejects C:\ paths when previewing (-DryRun) on Linux/macOS.
  $programFiles = $env:ProgramFiles; if (-not $programFiles) { $programFiles = "C:\Program Files" }
  $localAppData = $env:LOCALAPPDATA; if (-not $localAppData) { $localAppData = [IO.Path]::Combine($HOME, "AppData\Local") }
  $tempDir = [IO.Path]::GetTempPath()
  $hubExe = [IO.Path]::Combine($programFiles, "Unity Hub\Unity Hub.exe")
  $editorRoot = [IO.Path]::Combine($programFiles, "Unity\Hub\Editor")
  $editorExe = [IO.Path]::Combine($editorRoot, "$UnityVersion\Editor\Unity.exe")

  $mhDone = New-Object System.Collections.ArrayList
  $mhSkipped = New-Object System.Collections.ArrayList
  $mhFailed = New-Object System.Collections.ArrayList
  $mhManual = New-Object System.Collections.ArrayList
  $mhWarnings = New-Object System.Collections.ArrayList

  # ------------------------------------------------------------------ helpers
  function Write-Heading([string]$text) { Write-Host ""; Write-Host "== $text ==" }
  function Write-Info([string]$text) { Write-Host "  $text" }
  function Write-Warn([string]$text) { Write-Host "  WARNING: $text" -ForegroundColor Yellow; [void]$mhWarnings.Add($text) }
  function Add-Result([string]$kind, [string]$name, [string]$why = "") {
    $item = $name; if ($why) { $item = "$name ($why)" }
    switch ($kind) {
      "done" { [void]$mhDone.Add($item) }
      "skip" { [void]$mhSkipped.Add($item) }
      "fail" { [void]$mhFailed.Add($item); Write-Host "  FAILED: $item" -ForegroundColor Red }
    }
  }
  function Add-Manual([string]$text) { [void]$mhManual.Add($text) }

  function Format-Command([string]$exe, [string[]]$arguments) {
    $parts = @($exe) + @($arguments) | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq "") { "'" + ($_ -replace "'", "''") + "'" } else { $_ } }
    return "  `$ " + ($parts -join " ")
  }

  # Invoke-Native EXE ARGS: print, then run unless dry-run; true when the exit code is 0.
  # Arguments are splatted from an array, so a literal "--" reaches the program (Hub CLI).
  function Invoke-Native([string]$exe, [string[]]$arguments = @()) {
    Write-Host (Format-Command $exe $arguments)
    if ($DryRun) { return $true }
    $global:LASTEXITCODE = 0
    try {
      # Piping makes PowerShell wait for GUI-subsystem programs (the Hub) and keeps output on the host.
      & $exe @arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
    } catch { Write-Info "$exe failed to start: $($_.Exception.Message)"; return $false }
    return ($LASTEXITCODE -eq 0)
  }

  # Invoke-Installer EXE ARGSTRING: run an installer and wait (it raises UAC itself when it needs to).
  function Invoke-Installer([string]$exe, [string]$argString) {
    Write-Host "  `$ $exe $argString"
    if ($DryRun) { return $true }
    try {
      $p = Start-Process -FilePath $exe -ArgumentList $argString -Wait -PassThru
      if ($p.ExitCode -ne 0) { Write-Info "installer exit code $($p.ExitCode)" }
      return ($p.ExitCode -eq 0)
    } catch { Write-Info "installer did not run: $($_.Exception.Message)"; return $false }
  }

  function Get-File {
    # MD5 is what Unity's release API publishes for its installers; it guards against truncated downloads.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingBrokenHashAlgorithms", "")]
    param([string]$url, [string]$out, [string]$md5 = "")
    Write-Host "  `$ download $url -> $out"
    if ($DryRun) { return $true }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    try {
      if ($curl) {   # resumable, and much faster than Invoke-WebRequest on Windows PowerShell 5.1
        & $curl.Source -fL --retry 5 --retry-delay 5 -C - -o $out $url
        if ($LASTEXITCODE -ne 0) { throw "curl exit code $LASTEXITCODE" }
      } else {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
      }
    } catch { Write-Info "download failed: $($_.Exception.Message)"; return $false }
    if ($md5) {
      $h = (Get-FileHash -Algorithm MD5 -Path $out).Hash.ToLowerInvariant()
      if ($h -ne $md5) { Write-Info "md5 mismatch ($h); deleting $out"; Remove-Item -Force $out; return $false }
    }
    return $true
  }

  # Approve PROMPT [STRICT]: yes under -Yes/-DryRun; asks when a console is attached. Without a console the
  # answer is yes, except for STRICT prompts (settings changes), which then need -Yes.
  function Approve([string]$prompt, [bool]$strict = $false) {
    if ($DryRun -or $Yes) { return $true }
    $interactive = [Environment]::UserInteractive
    try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { Write-Verbose "console: $_" }
    if (-not $interactive) { return (-not $strict) }
    $answer = Read-Host "$prompt [Y/n]"
    return ($answer -eq "" -or $answer -match '^(y|yes)$')
  }

  # Import-RegistryEnvironment: re-read the machine and user environment from the registry (as refresh_env.bat does),
  # so tools installed a moment ago are found without opening a new terminal.
  function Import-RegistryEnvironment {
    if (-not $onWindows) { return }
    foreach ($scope in "Machine", "User") {
      $vars = [Environment]::GetEnvironmentVariables($scope)
      foreach ($name in $vars.Keys) {
        if ($name -in "Path", "USERNAME", "PROCESSOR_ARCHITECTURE", "PSModulePath") { continue }
        Set-Item -Path "Env:$name" -Value $vars[$name]
      }
    }
    $paths = @()
    foreach ($p in @([Environment]::GetEnvironmentVariable("Path", "Machine"), [Environment]::GetEnvironmentVariable("Path", "User"), $env:Path)) {
      if ($p) { foreach ($e in ($p -split ";")) { if ($e -and ($paths -notcontains $e)) { $paths += $e } } }
    }
    $env:Path = $paths -join ";"
  }

  function Find-Tool([string]$name, [string[]]$candidates = @()) {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source -notlike "*\WindowsApps\*") { return $cmd.Source }   # Store alias stubs don't count
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
  }

  function Get-Winget {
    $w = Get-Command winget -ErrorAction SilentlyContinue   # winget itself lives under WindowsApps
    if (-not $w) { return $null }
    & $w.Source --version *> $null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $w.Source
  }

  function Install-Winget([string]$id) {
    $wg = Get-Winget
    if (-not $wg) { if ($DryRun) { $wg = "winget" } else { return $false } }
    $ok = Invoke-Native $wg @("install", "--id", $id, "--exact", "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--silent")
    Import-RegistryEnvironment
    return $ok
  }

  function Get-Git { return (Find-Tool "git" @(([IO.Path]::Combine($programFiles, "Git\cmd\git.exe")))) }
  function Test-LfsInstalled {
    $g = Get-Git; if (-not $g) { return $false }
    & $g lfs version *> $null
    return ($LASTEXITCODE -eq 0)
  }

  function Install-GitFromGitHub {
    $arch = "64-bit"; if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }
    try {
      $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/git-for-windows/git/releases/latest"
      $asset = $rel.assets | Where-Object { $_.name -like "Git-*-$arch.exe" } | Select-Object -First 1
    } catch { Write-Info "GitHub API: $($_.Exception.Message)"; return $false }
    if (-not $asset) { return $false }
    $out = [IO.Path]::Combine($tempDir, $asset.name)
    if (-not (Get-File $asset.browser_download_url $out)) { return $false }
    $ok = Invoke-Installer $out "/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES"
    if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
    Import-RegistryEnvironment
    return $ok
  }

  function Install-GitLfsFromGitHub {
    try {
      $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/git-lfs/git-lfs/releases/latest"
      $asset = $rel.assets | Where-Object { $_.name -like "git-lfs-windows-v*.exe" } | Select-Object -First 1
    } catch { Write-Info "GitHub API: $($_.Exception.Message)"; return $false }
    if (-not $asset) { return $false }
    $out = [IO.Path]::Combine($tempDir, $asset.name)
    if (-not (Get-File $asset.browser_download_url $out)) { return $false }
    $ok = Invoke-Installer $out "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES"
    if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
    Import-RegistryEnvironment
    return $ok
  }

  # ------------------------------------------------------------------ component: base
  function Install-Base {
    Write-Heading "base: git, git-lfs (curl and tar ship with Windows 10+)"
    $missing = @()
    if (-not (Get-Git)) { $missing += "git" }
    if (-not (Test-LfsInstalled)) { $missing += "git-lfs" }
    if ($missing.Count -eq 0) {
      Write-Info "$(& (Get-Git) --version) and $(& (Get-Git) lfs version) are installed."
      Add-Result skip base "already installed"
    } elseif (-not (Approve "Install $($missing -join ', ')?")) {
      Add-Result skip base "declined"
    } else {
      if ($missing -contains "git") {
        # Git for Windows bundles Git LFS by default.
        if (-not ((Install-Winget "Git.Git") -and ($DryRun -or (Get-Git)))) {
          Write-Info "winget could not install Git; using the Git for Windows installer from GitHub."
          [void](Install-GitFromGitHub)
        }
      }
      if (-not $DryRun -and -not (Test-LfsInstalled)) {
        if (-not ((Install-Winget "GitHub.GitLFS") -and (Test-LfsInstalled))) { [void](Install-GitLfsFromGitHub) }
      }
      if ($DryRun -or ((Get-Git) -and (Test-LfsInstalled))) { Add-Result done base "installed $($missing -join ', ')" }
      else {
        Add-Result fail base "git/git-lfs not installed"
        Add-Manual "Install Git for Windows (https://git-scm.com/download/win; it includes Git LFS), then re-run."
        return
      }
    }
    # Long paths: Unity packages can exceed MAX_PATH.
    if ($onWindows) {
      $lp = 0
      try { $lp = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled } catch { Write-Verbose "LongPathsEnabled is unset: $_" }
      if ($lp -ne 1) {
        Write-Warn "Windows long paths are disabled (LongPathsEnabled=0). To enable them, run as administrator: New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force"
      }
    }
    $g = Get-Git
    if ($g -or $DryRun) {
      $cur = ""; if ($g) { $cur = (& $g config --global --get core.longpaths) 2>$null }
      if ($cur -ne "true") {
        if (Approve "Set 'git config --global core.longpaths true' (lets git write paths over 260 characters)?" $true) {
          if (-not $g) { $g = "git" }
          [void](Invoke-Native $g @("config", "--global", "core.longpaths", "true"))
        } else { Write-Info "Left core.longpaths unset (re-run with -Yes or answer y to set it)." }
      }
    }
  }

  # ------------------------------------------------------------------ component: unity-hub
  function Install-UnityHub {
    Write-Heading "unity-hub: Unity Hub"
    if (Test-Path $hubExe) { Write-Info "Unity Hub is installed: $hubExe"; Add-Result skip unity-hub "already installed"; return }
    if (-not (Approve "Install Unity Hub?")) { Add-Result skip unity-hub "declined"; return }
    if ((Install-Winget "Unity.UnityHub") -and ($DryRun -or (Test-Path $hubExe))) { Add-Result done unity-hub "winget"; return }
    Write-Info "winget could not install the Hub; using Unity's installer."
    $arch = "x64"; if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }
    $out = [IO.Path]::Combine($tempDir, "UnityHubSetup-$arch.exe")
    if ((Get-File "https://public-cdn.cloud.unity3d.com/hub/prod/UnityHubSetup-$arch.exe" $out) -and (Invoke-Installer $out "/S") -and ($DryRun -or (Test-Path $hubExe))) {
      if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
      Add-Result done unity-hub "Unity installer"; return
    }
    Add-Result fail unity-hub "no install method worked"
    Add-Manual "Install Unity Hub from https://unity.com/download, then re-run."
  }

  # ------------------------------------------------------------------ component: unity-editor
  function Get-UnityCli { return (Find-Tool "unity" @(([IO.Path]::Combine($localAppData, "Unity\bin\unity.exe")))) }

  function Find-Editor {
    if (Test-Path $editorExe) { return $editorExe }
    $cli = Get-UnityCli
    if ($cli) {   # a custom install path set in the Hub or with `unity install-path --set`
      $root = (& $cli install-path --no-banner --non-interactive 2>$null | Select-Object -Last 1)
      if ($root) { $c = [IO.Path]::Combine($root, "$UnityVersion\Editor\Unity.exe"); if (Test-Path $c) { return $c } }
    }
    return $null
  }

  function Test-LinuxModule([string]$exe) {
    return (Test-Path ([IO.Path]::Combine((Split-Path $exe), "Data\PlaybackEngines\LinuxStandaloneSupport")))
  }

  function Install-UnityCli {
    if (Get-UnityCli) { return $true }
    if ((Install-Winget "Unity.CLI") -and ($DryRun -or (Get-UnityCli))) { return $true }
    Write-Info "Installing the Unity CLI with Unity's installer (https://unity.com/install.ps1)."
    $out = [IO.Path]::Combine($tempDir, "unity-cli-install.ps1")
    if (-not (Get-File "https://unity.com/install.ps1" $out)) { return $false }
    $ps = (Get-Process -Id $PID).Path
    $ok = Invoke-Native $ps @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $out)
    if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
    Import-RegistryEnvironment
    $env:Path = ([IO.Path]::Combine($localAppData, "Unity\bin")) + ";" + $env:Path
    return ($ok -and ($DryRun -or (Get-UnityCli)))
  }

  function Install-EditorWithUnityCli {
    if (-not (Install-UnityCli)) { return $false }
    $cli = Get-UnityCli; if (-not $cli) { $cli = "unity" }
    $a = @("install", $UnityVersion, "--changeset", $UnityChangeset, "--yes", "--accept-eula", "--non-interactive", "--no-banner")
    if ($WithLinuxBuild) { $a += @("--module", "linux-mono") }
    return (Invoke-Native $cli $a)
  }

  function Install-EditorWithHubCli {
    if (-not (Test-Path $hubExe) -and -not $DryRun) { return $false }
    # Hub 3 only: Hub 4 prints the Unity CLI replacement and exits with an error.
    $a = @("--", "--headless", "install", "--version", $UnityVersion, "--changeset", $UnityChangeset)
    if ($WithLinuxBuild) { $a += @("--module", "linux-mono") }
    return (Invoke-Native $hubExe $a)
  }

  function Install-EditorDirect {
    $dest = [IO.Path]::Combine($editorRoot, $UnityVersion)
    $out = [IO.Path]::Combine($tempDir, "UnitySetup64-$UnityVersion.exe")
    Write-Info "Downloading the editor installer (about 4 GB, resumable)."
    if (-not (Get-File $EditorUrl $out $EditorMd5)) { return $false }
    # /D= must come last and must not be quoted, even with spaces (Unity's install docs).
    if (-not (Invoke-Installer $out "/S /D=$dest")) { return $false }
    if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
    if ($WithLinuxBuild) { [void](Install-LinuxModuleDirect $dest) }
    return $true
  }

  function Install-LinuxModuleDirect([string]$dest) {
    $out = [IO.Path]::Combine($tempDir, "UnitySetup-Linux-Mono-Support-for-Editor-$UnityVersion.exe")
    if ((Get-File $LinuxMonoUrl $out $LinuxMonoMd5) -and (Invoke-Installer $out "/S /D=$dest")) {
      if (-not $DryRun) { Remove-Item -Force $out -ErrorAction SilentlyContinue }
      return $true
    }
    Add-Manual "Add 'Linux Build Support (Mono)' in Unity Hub > Installs > $UnityVersion > Add modules."
    return $false
  }

  function Install-UnityEditor {
    Write-Heading "unity-editor: Unity $UnityVersion ($UnityChangeset)"
    $found = Find-Editor
    if ($found) {
      Write-Info "Unity $UnityVersion is installed: $found"
      if ($WithLinuxBuild -and -not (Test-LinuxModule $found)) {
        $cli = Get-UnityCli
        if ($cli -and (Invoke-Native $cli @("install-modules", "--editor-version", $UnityVersion, "--module", "linux-mono", "--yes", "--accept-eula", "--non-interactive", "--no-banner"))) {
          Add-Result done unity-editor "added linux-mono"; return
        }
        if (Install-LinuxModuleDirect (Split-Path (Split-Path $found))) { Add-Result done unity-editor "added linux-mono"; return }
        Add-Result skip unity-editor "installed; linux-mono left manual"; return
      }
      Add-Result skip unity-editor "already installed"; return
    }
    if (-not (Approve "Download and install Unity $UnityVersion (about 4 GB download, 12 GB on disk)?")) { Add-Result skip unity-editor "declined"; return }
    if ((Install-EditorWithUnityCli) -and ($DryRun -or (Find-Editor))) { Add-Result done unity-editor "Unity CLI"; return }
    Write-Info "The Unity CLI route did not work; trying the Hub 3 command line."
    if ((Install-EditorWithHubCli) -and ($DryRun -or (Find-Editor))) { Add-Result done unity-editor "Unity Hub CLI"; return }
    Write-Info "The Hub command line did not work; running Unity's editor installer directly."
    if ((Install-EditorDirect) -and ($DryRun -or (Find-Editor))) { Add-Result done unity-editor "direct installer"; return }
    Add-Result fail unity-editor "every install route failed"
    Add-Manual "Install Unity $UnityVersion from the Unity Hub (Installs > Install Editor > Archive, changeset $UnityChangeset)."
  }

  # ------------------------------------------------------------------ component: repo
  function Resolve-RepoUrl {
    if ($Repo -notmatch '://' -and $Repo -notmatch '^[^/\\]+@[^:]+:' -and (Test-Path -PathType Container $Repo)) {
      # file:///C:/path (Windows) or file:///path: git-lfs's file transfer adapter needs a file:// URL.
      $p = ((Resolve-Path $Repo).Path) -replace '\\', '/'
      if (-not $p.StartsWith("/")) { $p = "/" + $p }
      return "file://$p"
    }
    return $Repo
  }

  function Install-Repo {
    Write-Heading "repo: $Dir ($Branch)"
    $g = Get-Git
    if (-not $g) {
      if (-not $DryRun) { Add-Result fail repo "git is required (run the base component)"; return }
      $g = "git"
    }
    $url = Resolve-RepoUrl
    $env:GIT_TERMINAL_PROMPT = "0"
    if (-not (Invoke-Native $g @("lfs", "install"))) { Add-Result fail repo "git lfs install failed"; return }

    if (Test-Path ([IO.Path]::Combine($Dir, ".git"))) {
      Write-Info "Existing checkout found; updating it in place."
      $dirty = & $g -C $Dir status --porcelain --untracked-files=no
      if ($dirty) {
        $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
        Write-Info "Local changes found in $Dir; not touching it. Commit or stash them (git stash), then re-run."
        Add-Result fail repo "local changes in $Dir, left untouched"; return
      }
      $current = (& $g -C $Dir symbolic-ref --short -q HEAD); if (-not $current) { $current = "DETACHED" }
      if ($current -ne $Branch) {
        Write-Info "$Dir is on '$current', not '$Branch'; not switching branches. Run: git -C `"$Dir`" switch $Branch"
        Add-Result fail repo "on branch $current, expected $Branch"; return
      }
      $before = (& $g -C $Dir rev-parse HEAD)
      if (-not (Invoke-Native $g @("-C", $Dir, "fetch", "--filter=blob:none", $url, $Branch))) { Add-Result fail repo "git fetch failed"; return }
      if (-not (Invoke-Native $g @("-C", $Dir, "merge", "--ff-only", "FETCH_HEAD"))) {
        Write-Info "Your branch and $url $Branch have diverged; not merging. Rebase or reset it yourself."
        Add-Result fail repo "cannot fast-forward"; return
      }
      if (-not (Invoke-Native $g @("-C", $Dir, "lfs", "pull", $url))) { Add-Result fail repo "git lfs pull failed (see LFS quota in install/README.md)"; return }
      $after = (& $g -C $Dir rev-parse HEAD)
      if ($DryRun -or $before -eq $after) { Add-Result done repo "up to date at $("$after".Substring(0, [Math]::Min(10, "$after".Length)))" }
      else { Add-Result done repo "updated $($before.Substring(0,10))..$($after.Substring(0,10))" }
      return
    }
    if ((Test-Path $Dir) -and (Get-ChildItem -Force $Dir | Select-Object -First 1)) {
      Add-Result fail repo "$Dir exists, is not empty and is not a git checkout; choose another -Dir"; return
    }
    # Partial clone: history holds large non-LFS blobs that a full clone would download.
    # LFS smudge is skipped during the clone, then fetched in one batch (resumable on re-run).
    $env:GIT_LFS_SKIP_SMUDGE = "1"
    Write-Info "(GIT_LFS_SKIP_SMUDGE=1 for the clone)"
    $ok = Invoke-Native $g @("clone", "--filter=blob:none", "--branch", $Branch, $url, $Dir)
    Remove-Item Env:GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
    if (-not $ok) { Add-Result fail repo "git clone failed"; return }
    if (-not (Invoke-Native $g @("-C", $Dir, "lfs", "pull"))) { Add-Result fail repo "git lfs pull failed (see LFS quota in install/README.md)"; return }
    Add-Result done repo "cloned into $Dir"
  }

  # ------------------------------------------------------------------ main
  $comps = @($Components -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($comps -contains "all") { $comps = $AllComponents }
  foreach ($c in $comps) {
    if ($AllComponents -notcontains $c) { Write-Host "Unknown component: $c (choose from $($AllComponents -join ','))" -ForegroundColor Red; return 2 }
  }
  if (-not [IO.Path]::IsPathRooted($Dir)) { $Dir = Join-Path (Get-Location).Path $Dir }

  Write-Heading "MHSeals RoboBoat simulator installer"
  $osText = [Environment]::OSVersion.VersionString
  Write-Info "Host:        $osText, PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
  if (-not $onWindows) { Write-Info "Not Windows: Windows-only steps can only be previewed with -DryRun." }
  Write-Info "winget:      $(if (Get-Winget) { 'available' } else { 'not found (falls back to the official installers)' })"
  Write-Info "Components:  $($comps -join ',')"
  Write-Info "Checkout:    $Dir (branch $Branch from $Repo)"
  $mod = ""; if ($WithLinuxBuild) { $mod = " + linux-mono" }
  Write-Info "Unity:       $UnityVersion ($UnityChangeset)$mod"
  if ($DryRun) { Write-Info "Dry run:     commands are printed, not run" }
  if (-not (Approve "Continue?")) { Write-Host "Cancelled."; return 0 }

  foreach ($c in $AllComponents) {
    if ($comps -notcontains $c) { continue }
    try {
      switch ($c) {
        "base" { Install-Base }
        "vulkan" { Write-Heading "vulkan"; Write-Info "Linux only (Windows GPU drivers include Vulkan and DirectX)."; Add-Result skip vulkan "Linux only" }
        "unity-hub" { Install-UnityHub }
        "unity-editor" { Install-UnityEditor }
        "repo" { Install-Repo }
      }
    } catch { Add-Result fail $c $_.Exception.Message }
  }

  if ($Open) {
    Write-Heading "open"
    $exe = Find-Editor
    if (-not $exe -and $DryRun) { $exe = $editorExe }
    if ($exe -and ((Test-Path $Dir) -or $DryRun)) {
      Write-Host "  `$ $exe -projectPath `"$Dir`""
      if (-not $DryRun) { Start-Process -FilePath $exe -ArgumentList @("-projectPath", "`"$Dir`"") }
    } else { Write-Info "Unity $UnityVersion or $Dir is missing; cannot open." }
  }

  Write-Heading "Summary"
  $label = "Done"; if ($DryRun) { $label = "Planned (dry run)" }
  foreach ($pair in @(@($label, $mhDone), @("Skipped", $mhSkipped), @("Failed", $mhFailed))) {
    Write-Host "$($pair[0]):"
    if ($pair[1].Count -eq 0) { Write-Host "  - none" } else { foreach ($i in $pair[1]) { Write-Host "  - $i" } }
  }
  if ($mhWarnings.Count -gt 0) { Write-Host "Warnings:"; foreach ($i in $mhWarnings) { Write-Host "  - $i" } }
  Write-Host "Manual steps:"
  foreach ($i in $mhManual) { Write-Host "  - $i" }
  Write-Host "  - Open Unity Hub, sign in with a Unity ID, and activate a free Personal licence"
  Write-Host "    (Hub > Preferences > Licenses > Add > Get a free personal license). This cannot be scripted."
  Write-Host "  - Open the project: Unity Hub > Projects > Add > $Dir, or run:"
  $shown = Find-Editor; if (-not $shown) { $shown = $editorExe }
  Write-Host "      & `"$shown`" -projectPath `"$Dir`""
  Write-Host "    The first import takes several minutes. Re-run this installer any time to update."
  if ($mhFailed.Count -gt 0) { return 1 }
  return 0
}

# Run as a file (-File) the script exits with its status; under irm | iex or a scriptblock `exit` would close
# the caller's window, so only $LASTEXITCODE is set. The child scope (& { }) keeps the caller's variables untouched.
$mhsealsAsFile = [bool]$MyInvocation.MyCommand.Path
& {
if ($Help) {
  Write-Host @"
MHSeals RoboBoat simulator installer (Windows)

  irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1 | iex
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1))) [options]

Options (environment variable in brackets, for irm | iex):
  -Components LIST   Comma-separated subset of base,vulkan,unity-hub,unity-editor,repo (default: all) [MHSEALS_COMPONENTS]
  -Dir DIR           Where to clone the simulator (default: `$HOME\mhseals_sim)                     [MHSEALS_DIR]
  -Branch NAME       Branch to check out (default: main)                                           [MHSEALS_BRANCH]
  -Repo URL|PATH     Git URL or local path (default: https://github.com/MHSeals/mhseals_sim.git)   [MHSEALS_REPO]
  -WithLinuxBuild    Also install the Unity "Linux Build Support (Mono)" module
  -Open              Open the project in the Unity Editor when done
  -DryRun            Print the commands without running them                                       [MHSEALS_DRY_RUN=1]
  -Yes               Do not ask for confirmation                                                    [MHSEALS_YES=1]
  -Help              Show this help
"@
} else {
  function Test-Truthy([string]$v) { return ($v -match '^(1|true|yes|y|on)$') }
  if (-not $Dir) { $Dir = $env:MHSEALS_DIR }; if (-not $Dir) { $Dir = Join-Path $HOME "mhseals_sim" }
  if (-not $Branch) { $Branch = $env:MHSEALS_BRANCH }; if (-not $Branch) { $Branch = "main" }
  if (-not $Repo) { $Repo = $env:MHSEALS_REPO }; if (-not $Repo) { $Repo = "https://github.com/MHSeals/mhseals_sim.git" }
  if (-not $Components) { $Components = $env:MHSEALS_COMPONENTS }; if (-not $Components) { $Components = "all" }
  if ($WithWindowsBuild) { Write-Host "Note: -WithWindowsBuild applies to Linux; the Windows editor builds for Windows already." }
  # The Unity CLI sends an anonymous usage count and crash reports by default; switch them (and its update check)
  # off for the commands run here, then restore the caller's values.
  # https://docs.unity.com/en-us/unity-cli/data-collection-privacy-controls/turn-off-data-collection
  $mhsealsSavedEnv = @{}
  foreach ($n in "UNITY_NO_CLI_INVOKED_TELEMETRY", "UNITY_NO_CRASH_REPORT", "UNITY_NO_UPDATE_CHECK") {
    $mhsealsSavedEnv[$n] = [Environment]::GetEnvironmentVariable($n); Set-Item -Path "Env:$n" -Value "1"
  }
  try {
    $mhsealsRc = Invoke-MhsealsInstall -Dir $Dir -Branch $Branch -Repo $Repo -Components $Components `
      -DryRun ($DryRun.IsPresent -or (Test-Truthy $env:MHSEALS_DRY_RUN)) -Yes ($Yes.IsPresent -or (Test-Truthy $env:MHSEALS_YES)) `
      -WithLinuxBuild $WithLinuxBuild.IsPresent -Open $Open.IsPresent | Select-Object -Last 1
  } finally {
    foreach ($n in $mhsealsSavedEnv.Keys) {
      if ($null -eq $mhsealsSavedEnv[$n]) { Remove-Item -Path "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item -Path "Env:$n" -Value $mhsealsSavedEnv[$n] }
    }
  }
  $global:LASTEXITCODE = $mhsealsRc
  if ($mhsealsAsFile) { exit $mhsealsRc }
}
}
