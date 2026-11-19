# Installing the MHSeals RoboBoat simulator

One command sets up everything needed to open the simulator in Unity: git and Git LFS, Unity Hub,
Unity Editor **6000.5.10f1** (changeset `3bd4f66ad299`), a Vulkan check on Linux, and a checkout of
this repository. Re-running the command updates the checkout in place, and skips anything that is
already installed.

**Linux** (any distribution):

```bash
curl -fsSL https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.sh | bash
```

**Windows** (PowerShell 5.1 or 7; do not use an administrator window, since each installer asks for UAC itself):

```powershell
irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1 | iex
```

Afterwards, do the [two manual steps](#after-installing-the-manual-steps).

## Options

You can pass flags through the pipe:

```bash
curl -fsSL https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.sh | bash -s -- --dir ~/sim --yes
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/MHSeals/mhseals_sim/main/install/install.ps1))) -Dir D:\sim -Yes
```

`irm | iex` can't take parameters, so both scripts also read environment variables. For example,
`$env:MHSEALS_DIR = "D:\sim"; irm ... | iex`. (Under `irm | iex`, the script's parameter block resets any
`$Dir`, `$Repo`, `$Branch` or `$Components` variables in your PowerShell session to empty.)

| Linux flag | Windows parameter | Environment variable | Default |
|---|---|---|---|
| `--components a,b` | `-Components a,b` | `MHSEALS_COMPONENTS` | all: `base,vulkan,unity-hub,unity-editor,repo` |
| `--dir DIR` | `-Dir DIR` | `MHSEALS_DIR` | `~/mhseals_sim` / `$HOME\mhseals_sim` |
| `--branch NAME` | `-Branch NAME` | `MHSEALS_BRANCH` | `main` |
| `--repo URL\|PATH` | `-Repo URL\|PATH` | `MHSEALS_REPO` | `https://github.com/MHSeals/mhseals_sim.git` |
| `--dry-run` | `-DryRun` | `MHSEALS_DRY_RUN=1` | off: prints every command instead of running it |
| `--yes` / `-y` | `-Yes` | `MHSEALS_YES=1` | off: asks before each component |
| `--with-windows-build` | (n/a) | (n/a) | Linux only: adds the *Windows Build Support (Mono)* module |
| (n/a) | `-WithLinuxBuild` | (n/a) | Windows only: adds the *Linux Build Support (Mono)* module |
| `--open` | `-Open` | (n/a) | opens the project in Unity when done |
| `--help` | `-Help` | (n/a) | |

`--repo` accepts a local path as well as a URL. This is handy for testing a checkout you already have.

Prompts: the Linux script asks on the terminal even when piped from `curl`, because it reads from
`/dev/tty`. If no terminal is attached (CI, `docker run` without `-t`), it proceeds as if you had
passed `--yes`. On Windows, the same is true, except that `git config --global core.longpaths true`
is only set if you confirm or pass `-Yes`.

## What each component does

The components always run in this order. Pick a subset with `--components`.

| Component | Linux | Windows |
|---|---|---|
| `base` | Installs whichever of `git`, `git-lfs`, `curl`, `tar` and `xz` are missing, with apt, dnf, pacman or zypper (using sudo only for this). On image-based hosts (Silverblue/Bazzite/bootc, SteamOS, NixOS) or unknown distributions, `git-lfs` is installed as the static release from GitHub into `~/.local/bin`, with its sha256 checked. | winget `Git.Git`, which bundles Git LFS. If LFS is still missing, winget `GitHub.GitLFS`. Without winget, it uses the latest Git for Windows installer from GitHub, run silently. It warns if Windows long paths are off, and offers `git config --global core.longpaths true`. |
| `vulkan` | Installs the Vulkan loader and `vulkan-tools` (`libvulkan1`/`vulkan-loader`/`vulkan-icd-loader`), runs `vulkaninfo --summary`, and **warns** if there is no GPU device, or only `llvmpipe` (software rendering). It never installs GPU drivers. | Skipped, because Windows GPU drivers already ship Vulkan and DirectX. |
| `unity-hub` | Debian/Ubuntu: Unity's apt repository (key in `/etc/apt/keyrings/unityhub.gpg`, `/etc/apt/sources.list.d/unityhub.sources`). Fedora/RHEL: Unity's rpm repository (`/etc/yum.repos.d/unityhub.repo`). openSUSE: the same rpm repository through zypper, falling back to Flatpak if zypper can't resolve it (see below). Arch: AUR `unityhub` through `yay` or `paru`, else Flatpak. Anything else: Flatpak `com.unity.UnityHub` from Flathub, installed per user. | winget `Unity.UnityHub`. Without winget, `UnityHubSetup-x64.exe /S` from Unity's CDN. |
| `unity-editor` | Skipped if `~/Unity/Hub/Editor/6000.5.10f1/Editor/Unity` (or the Hub's custom install path) already exists. Otherwise it tries three routes in order. (1) The **Unity CLI** (`unity install 6000.5.10f1 --changeset 3bd4f66ad299`), installed if needed from Unity's repository (`unity-cli` package) or `https://unity.com/install.sh` into `~/.local/bin`. (2) The Hub 3 command line (`unityhub --headless install ...`). (3) The editor archive (4.3 GB, md5-checked, resumable), extracted to `~/Unity/Hub/Editor/6000.5.10f1/`, where the Hub finds it. | Skipped if `C:\Program Files\Unity\Hub\Editor\6000.5.10f1\Editor\Unity.exe` exists. Otherwise the same order: (1) the Unity CLI (winget `Unity.CLI` or `https://unity.com/install.ps1`); (2) `"Unity Hub.exe" -- --headless install ...`; (3) `UnitySetup64-6000.5.10f1.exe /S /D=...`, md5-checked, plus the Linux Mono module installer if requested. |
| `repo` | Runs `git lfs install`. Then, for a new directory: `git clone --filter=blob:none --branch BRANCH REPO DIR` followed by `git lfs pull`. For an existing checkout: `git fetch`, `git merge --ff-only`, `git lfs pull`. | Same. |

Why the Unity CLI comes first: Unity Hub 4 (the current Hub on every platform) has removed the old
`--headless` command line, and its replacement is the standalone `unity` CLI. The Hub-CLI route is
kept for machines that still run Hub 3.

Why some hosts get the Flatpak Hub: Unity's current Hub package (4.0.1) is built against glibc 2.39.
It installs on Debian 12, Ubuntu 22.04 and RHEL 9 but fails to start there. So on hosts with glibc
older than 2.39, the installer uses the Flatpak Hub, which brings its own runtime.

Privacy: the installer collects nothing. The Unity CLI sends an anonymous usage count and crash
reports by default, so the scripts set `UNITY_NO_CLI_INVOKED_TELEMETRY=1`, `UNITY_NO_CRASH_REPORT=1`
and `UNITY_NO_UPDATE_CHECK=1` for the commands they run. To turn this off permanently, set those
variables yourself and run `unity analytics opt-out`. See
[Unity's page](https://docs.unity.com/en-us/unity-cli/data-collection-privacy-controls/turn-off-data-collection).
The Unity Hub and Editor have their own settings.

Why the clone is partial (`--filter=blob:none`): the git history contains about 150 MB of large files
that are not in LFS, and you don't need old versions of them to work on the simulator. Git fetches
old blobs on demand if you ever check out an old commit.

The update path never discards your work. It stops, says why, and changes nothing if:

- the checkout has uncommitted changes to tracked files (untracked files are fine)
- the checkout is on a different branch than `--branch`
- your branch has diverged from the remote
- `--dir` is a non-empty directory that isn't a git checkout

Exit status: `0` if nothing failed, `1` if any component failed (the summary lists which), `2` for a
bad flag.

## After installing: the manual steps

These can't be scripted, and the summary always repeats them.

1. **Activate a Unity licence.** Open Unity Hub and sign in with a Unity ID (free to create).
   Then go to *Preferences > Licenses > Add > Get a free personal license*. A Personal licence is
   free for individuals and organisations under Unity's revenue threshold. Students can also use
   [Unity Student](https://unity.com/products/unity-student). Unity won't open a project without an
   activated licence.
2. **Open the project.** In Unity Hub, go to *Projects > Add > Add project from disk* and choose the
   checkout directory (`~/mhseals_sim` by default). Or run the editor directly:

   ```bash
   ~/Unity/Hub/Editor/6000.5.10f1/Editor/Unity -projectPath ~/mhseals_sim
   ```

   ```powershell
   & "C:\Program Files\Unity\Hub\Editor\6000.5.10f1\Editor\Unity.exe" -projectPath "$HOME\mhseals_sim"
   ```

   The first import builds the `Library/` cache and takes several minutes. `--open` / `-Open` does
   this step for you once the licence is active.

## Troubleshooting

**Vulkan: "No Vulkan device found" or "llvmpipe".** Unity renders this project with Vulkan on Linux.
The installer installs the Vulkan *loader*, but never GPU drivers. Install your GPU's driver:

- AMD/Intel: Mesa's Vulkan drivers (`mesa-vulkan-drivers` on Debian/Ubuntu/Fedora; `vulkan-radeon`
  or `vulkan-intel` on Arch; `libvulkan_radeon` or `libvulkan_intel` on openSUSE)
- NVIDIA: the proprietary driver from your distribution

Then check with `vulkaninfo --summary`. On a machine with no usable GPU, such as a VM, you can start
Unity with `-force-glcore` to use OpenGL, but expect it to be slow.

**Flatpak Unity Hub.** The Flathub build is maintained by the community, not by Unity. It has host
filesystem access, so editors still install to `~/Unity/Hub/Editor`, and projects anywhere in your
home directory are visible. If the Hub can't see a project on another drive, grant access with
`flatpak override --user --filesystem=/path com.unity.UnityHub`. Run it with
`flatpak run com.unity.UnityHub`. Inside containers without user namespaces, Flatpak installs fail
(`apply_extra script failed`); install the Hub on the host instead.

**openSUSE.** Unity's Hub 4.0.1 rpm requires a package called `vulkan-loader`, but openSUSE calls it
`libvulkan1`, so zypper refuses to install it. The installer then removes the repository it added
and uses Flatpak instead. Unity's [AppImage](https://docs.unity.com/en-us/hub/install-hub-linux) is
another option.

**Git LFS: "This repository is over its data quota" / "batch response: ... bandwidth".** GitHub
limits free LFS bandwidth per repository owner, so heavy cloning by a whole team or a CI job can
exhaust it for the month. You then get pointer files instead of models. Wait for the quota to reset,
ask a maintainer to buy a data pack, or copy `.git/lfs/objects` from a teammate's checkout and run
`git lfs pull`. Re-running the installer retries `git lfs pull` and only fetches what is missing.

**Proxies, school or company networks.** Both scripts use the system's standard proxy settings:

```bash
export https_proxy=http://proxy.example:8080 http_proxy=http://proxy.example:8080
curl -fsSL .../install.sh | bash
```

On Windows, winget and the installers use the system proxy (*Settings > Network > Proxy*); git uses
`git config --global http.proxy http://proxy.example:8080`.

Some networks block one of these hosts:

- `raw.githubusercontent.com` and `github.com`
- `*.unity3d.com`, `unity.com` and `public-cdn.cloud.unity3d.com`
- `dl.flathub.org`

Ask the network admin to allow them, or run the installer on another network once. After that,
updates only need GitHub. A TLS-inspecting proxy needs its root certificate in the system trust store,
or curl and git report certificate errors.

**sudo asks for a password when piped.** That is expected: sudo reads the password from the
terminal, not from the pipe. Without a terminal (for example `ssh host 'curl ... | bash'`), run
`sudo -v` first, or use `bash <(curl -fsSL .../install.sh)`.

**Windows: "running scripts is disabled".** `irm | iex` is not affected by the execution policy. To
run a downloaded copy, use `powershell -ExecutionPolicy Bypass -File install\install.ps1`.

**The editor is installed somewhere else.** If you changed the Hub's install location, the scripts
check it, as reported by `unity install-path`, and skip the download when the editor is there.

## Adding a component (for maintainers)

The installer will grow to cover the whole RoboBoat suite, including the `astro_dock` ROS workspace
through Docker. To add a component:

1. **Linux (`install.sh`)**:
   - Write `component_<name>()`, using `-` to `_` in the name. Start it with `heading`.
   - Check first and call `skip_ <name> "already installed"` when there is nothing to do.
   - Ask with `approve "..."`.
   - Run every state-changing command through `run`, `run_shell`, `as_root` (sudo) or `pm_install`,
     so that `--dry-run` shows it.
   - End with `done_`, `skip_` or `fail_` (plus `manual_ "..."` for anything left to the user), and
     `return 1` on failure. Components run with `set -e` suspended, so check each command
     (`... || { fail_ name "why"; return 1; }`).
   - Add the name to `ALL_COMPONENTS` and to the ordered list in `main()`.
2. **Windows (`install.ps1`)**:
   - Write `Install-<Name>`, using `Invoke-Native`, `Invoke-Installer`, `Install-Winget` and
     `Get-File` for anything that changes state.
   - Record results with `Add-Result done|skip|fail` and `Add-Manual`.
   - Call `Import-RegistryEnvironment` after installing anything that changes `PATH`.
   - Add it to `$AllComponents` and to the `switch` in the main loop. A Linux-only component
     reports `skip` there.
3. Keep these rules:
   - Components must be idempotent.
   - Never discard user changes.
   - Never install GPU drivers.
   - Collect nothing (no telemetry).
   - Cite the source of any URL in the header comment.
4. Test:
   - `shellcheck install/install.sh` must be clean.
   - PSScriptAnalyzer should report no errors and no warnings other than `PSAvoidUsingWriteHost`,
     which is intentional because pipeline output would leak into the `irm | iex` caller.
   - Do a `--dry-run` in a few distribution containers (`ubuntu:24.04`, `debian:12`, `fedora`,
     `archlinux`, `opensuse/tumbleweed`), running as a non-root sudo user.
   - Do a real run of the new component.

A future `docker`/`astro-dock` component would follow `astro_dock/setup.linux.sh`'s `stage_docker`
(Docker's own apt/dnf repositories, or Podman on immutable hosts) and clone the workspace next to
`--dir`.
