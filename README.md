# bc250-fixer: maintenance toolkit for the AMD BC-250

One script for the things that go wrong when you use a BC-250 for local AI. It checks the board, fixes common setup problems, sets up the GPU clock governor and finds the highest clock your board runs reliably, unlocks and tests the extra GPU compute units, and collects a support bundle when you need help.

```bash
curl -fsSL https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/install.sh | sudo bash
sudo bc250-fixer check         # read-only health check
sudo bc250-fixer fix --dry-run # see what it would change
sudo bc250-fixer fix           # fix it (asks before each change)
```

## Install

The one-liner above puts `bc250-fixer` in `/usr/local/sbin`. Run it again to update.

- **How it checks the download:** it downloads to a temporary file and checks it before installing. The file must be the tool, complete (not cut off), valid bash, and must run. All of the installer's code is in one function that's only called on its last line, so a broken download of the installer runs nothing.
- **Options** go after `bash -s --`:
  - `--ref NAME` installs a tag or branch instead of `main`.
  - `--prefix DIR` puts it in another directory.
  - `--check` runs a health check straight after.
  - `--uninstall` removes it.

```bash
curl -fsSL https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/install.sh | sudo bash -s -- --check
```

- **To read it before running it:**

```bash
curl -fsSLO https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/install.sh
less install.sh && sudo bash install.sh
```

- **Without the installer:** download `bc250-fixer` itself, `chmod +x` it, and run it from anywhere. `sudo ./bc250-fixer install` copies it to `/usr/local/sbin`.

## Bazzite, Fedora Atomic and other rpm-ostree systems

The same one-liner works, and nothing gets layered. On these systems `/usr` is read-only, but `/usr/local`, `/opt`, `/var` and `/etc` are writable, and those are the only places the tool and everything it sets up live. Where it would otherwise install packages, it does this instead (`--deps local`, the default on rpm-ostree):

- **`cu setup`** builds the tools in a Fedora container (podman, which Bazzite ships) of the same release as your system, so they run on its glibc. It then copies them out to `/opt/bc250-fixer`:
  - **The compute verifier**, compiled once. The upstream script compiles itself on every run, so it needs gcc and glslang on the system. The prebuilt one is the same shader and C program, cut out of the pinned script unchanged, with the same options and exit codes.
  - **umr**, with its libraries and register database, run through a small wrapper.
  - **stress-ng** (for `cpu test`) and **setpci** (for `cpu unlock`), only if the system doesn't already have them.
  - Each one must load on the host before it replaces the old copy. The image is built once per Fedora release and takes about 1.5 GB of podman storage. After a major upgrade, `cu setup` builds a new image and removes the old one.
- **`gov install`** installs the governor's release build without a package manager:
  - The binary goes in `/usr/local/bin`, with its unit, D-Bus policy and udev rule in `/etc`. The release tarball is checked against its sha256 file.
  - The tarball is missing the D-Bus policy and the `cyan-skillfish-performance-mode` script. Its own `install.sh` stops at the first missing file, after it has already put the binary in `/etc`. So the tool fetches the missing files from the same release tag.
  - `gov uninstall` removes exactly the files it installed and keeps your config.
- **`llama build`** builds in the same container and runs the binaries on the host. ggml is linked statically and OpenMP is off, so the build only needs libvulkan, libstdc++ and glibc from the system, and Bazzite has all three. The build runs as your user, so your `~/llama.cpp` stays yours.
- **`--deps packages`** goes back to layering with rpm-ostree, which needs a reboot.

**Why not a version that lives in your home folder?** Most of this has to run as root: CMOS writes, GPU register writes through debugfs, kernel options, and the boot service. Root running programs from a folder your own account can change hands that account root. Also, SELinux won't let a system service run programs from a home folder. So the tools stay root-owned in `/opt`, which Bazzite lets you write to anyway.

**Secure Boot is the real blocker.** Many Bazzite installs keep it on. Fedora-based kernels then lock themselves down, and lockdown blocks:

- `/dev/port`, so the CMOS memory fix (`vram fix`) can't work;
- debugfs register writes, so the CU unlock can't work;
- PCI config-space writes, which is how the governor talks to the GPU's SMU, and how `cpu unlock` works.

Check with `cat /sys/kernel/security/lockdown`: `[none]` means you're fine. Otherwise the tool warns you before each of these. Turning Secure Boot off in the BIOS is the only fix.

## The most common problem: Linux sees only ~7.5 GB

The BC-250 has 16 GB shared between the CPU and GPU. The firmware reserves part of it for the GPU before Linux starts, 8 GB by default. Setting 512 MB in the BIOS menu often doesn't apply.

`sudo bc250-fixer vram` shows where the memory goes. It reads the firmware's memory map and the memory-settings block the firmware keeps in CMOS, and checks whether the CMOS battery is losing power. `sudo bc250-fixer vram fix` then writes the 512 MB setting straight into that CMOS block from Linux. This is the same write as [fanoush/bc250_memcfg](https://github.com/fanoush/bc250_memcfg), so it works on stock P3.00/P5.00 firmware with no BIOS flash. After a reboot, `free -h` should show about 15 GiB.

The write changes only the GPU reservation. It refuses if any memory timing in the block is out of range, and it saves a backup first. Clearing CMOS (jumper, or battery out for 60 s) undoes it.

## Commands

| Command | What it does |
|---|---|
| `check [MODEL.gguf...]` | Read-only health check: kernel, Mesa/Vulkan, IOMMU, memory split, `ttm.pages_limit` and conflicting settings, swap/zram, GPU governor and voltages, temperatures, crash history from recent boots, llama.cpp/Ollama setup, model files (size and KV heads). Saves a report. |
| `fix [ITEM...]` | Guided fixes: `journal` (persistent logs), `pages-limit`, `iommu`, `vram`, `swap`, `zram`. Default: all of them. Asks before each change. |
| `vram [check\|fix [MB]]` | The memory split in detail. Default size 512 MB. 2048 is refused (known not to boot). |
| `headless on\|off\|status` | Boot to a text console (frees ~0.6–1 GB) or back to the desktop. |
| `cu setup` | Installs `umr` and the compute-unit test tools (on rpm-ostree, builds them in a container instead). |
| `cu test [WGP...]` | Tests each of the 8 extra CU pairs on its own, live, then soaks all the passing pairs together. A pair fails on wrong results, GPU errors in the kernel log, a hang, or reaching the temperature limit. |
| `cu apply N\|passing\|all\|stock\|WGP...` | Changes the CU layout now, until reboot. `N` is a count from 24 to 40 in pairs; the pairs are spread evenly across the GPU's four sections. |
| `cu bench` | Ollama reading/writing speed, stock vs unlocked. |
| `cu persist` / `cu unpersist` | Applies the layout at every boot, with a crash-loop guard / stops. |
| `cu status` | Current layout, temperatures, clock cap, test results, persistence. |
| `cpu unlock` / `cpu test [SECONDS]` | The 2 disabled CPU cores (6 → 8), and a stress test that checks results on every thread. |
| `gov install` | Installs, configures and starts the GPU clock governor. It begins capped at 1500 MHz and asks before starting it at boot. |
| `gov status` | Whether it's running, the voltage curve, the clock limit, the current clock and tuning results. |
| `gov safe` / `gov limit MHZ` | Caps the clock at the 1500 MHz baseline, or at `MHZ`. |
| `gov tune` | Steps the clock up 50 MHz at a time, testing each step, and recommends a limit one step below the highest that held. |
| `gov undervolt [MHZ]` | Steps the voltage down at one point on the curve (default 1500 MHz) to cut heat. Checks the clocks on either side at their new voltages, then offers to save the lowest stable voltage plus 20 mV. |
| `gov restore` | Puts back the governor config from before this tool's first change. |
| `gov uninstall` | Removes a governor this tool installed from the release build (your config is kept). Package installs are removed with your package manager. |
| `soak [MINUTES]` | Stability soak at the current settings. |
| `monitor` | Live GPU clock, temperatures, power, GPU memory, RAM, swap. `--log file.csv` saves samples. |
| `llama build` | Builds llama.cpp (master) with Vulkan. |
| `llama bench MODEL.gguf` | llama-bench with q8_0 context, fully on the GPU. |
| `report` | Support bundle (check, memory split, CU state, system details, kernel logs from this and the last boot). Hostname, user name, MAC and IPv4 addresses are blanked out. |
| `install` / `uninstall [purge]` | Installs to /usr/local/sbin/bc250-fixer / removes it. |

**Global flags** (anywhere on the line):
- `--yes` answers yes to every question.
- `--dry-run` shows every change without making it.
- `--force` skips safety refusals.
- `--no-color` gives plain output.
- `--out DIR` sets where reports are saved.
- `--deps local|packages` sets where `cu setup`, `gov install` and `llama build` get their tools. `packages` uses the package manager. `local` builds them in a Fedora container and installs the governor's release build, with nothing layered (see [above](#bazzite-fedora-atomic-and-other-rpm-ostree-systems)). The default is `local` on rpm-ostree and `packages` everywhere else.

**Command flags:**
- `cu test`, `soak` and `cu bench`: `--passes N`, `--rounds N`, `--soak-minutes N`, `--temp-limit C` (default 92), `--model NAME`.
- `fix swap`: `--size GB`.
- `monitor`: `--interval S`, `--count N`, `--log FILE`.
- `llama build` and `llama bench`: `--llama-dir DIR`.
- `gov tune` and `gov undervolt`:
  - `--from MHZ` / `--to MHZ` set the clock range (default 1500–2000).
  - `--step MHZ` sets the step size (default 50).
  - `--step-seconds S` sets how long each step runs (default 120).
  - `--min-mv MV` is the undervolt floor (default 100 mV below your curve, never under 700).
  - `--ollama-load` keeps Ollama running as heat load.
  - `--retest-frozen` tests clocks at or above one that froze the board before (normally skipped).
  - `--temp-limit C` works as in `cu test`.

## Unlocking compute units

The GPU has 40 compute units but ships with 24 enabled. More units mainly speed up prompt processing; writing speed is limited by memory bandwidth and gains little. Community measurements put 40 CUs at about 1.6× on prompt processing.

```bash
sudo bc250-fixer cu setup
sudo bc250-fixer cu test        # ~25-35 min: 8 pairs one at a time, then a 10-minute soak
sudo bc250-fixer cu apply 36    # or: apply passing
sudo bc250-fixer cu bench
sudo bc250-fixer cu persist
```

- **No kernel patches or reboots.** The routing registers are written live by [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager), so kernel updates don't undo anything.
- **Every GPU result is checked.** Correctness is checked by [duggasco's](https://github.com/duggasco/bc250-40cu-unlock) `bc250-compute-verify.sh`, which repeats the GPU's maths on the CPU. Both tools are fetched at pinned commits.
- **Crashes are attributed.** If a test freezes the board, the next run marks that pair as failed and skips it from then on.
- **If Ollama is running, the soak uses it as load,** because heat problems only show up under sustained real use. gpu-yield, if installed, is paused during the single-pair tests.
- **Crash-loop guard:** two unclean shutdowns in a row while unlocked and the board boots at 24 CUs until you run `persist` again. A power cut counts as unclean too.
- **Cap the GPU clock at 1500 MHz @ 900 mV** (`gov safe`) until you've tuned it. Community boards at 2 GHz and 40 CUs reached 96–107 °C. The tool warns if your governor allows more.

## GPU clock governor and clock tuning

The BC-250's GPU needs a governor to manage its clock and voltage. [cyan-skillfish-governor-smu](https://github.com/filippor/cyan-skillfish-governor) is the only one that works on it. It picks a clock from the GPU load, and takes the voltage for that clock from the `[[safe-points]]` curve in `/etc/cyan-skillfish-governor-smu/config.toml`.

```bash
sudo bc250-fixer gov install    # install, cap at 1500 MHz, start, optionally at boot
sudo bc250-fixer cu setup       # the tuner uses the same GPU correctness checker
sudo bc250-fixer gov tune       # ~20-25 min: 1500 -> 2000 MHz in 50 MHz steps
sudo bc250-fixer soak           # a longer check at the new limit
sudo bc250-fixer gov undervolt  # optional: less voltage at 1500 MHz = less heat
```

- **Installing:**
  - Fedora gets the [COPR package](https://copr.fedorainfracloud.org/coprs/filippor/bazzite/), and Arch gets the AUR package through `paru` or `yay`.
  - Bazzite and other rpm-ostree systems get the release build in `/usr/local` with no layering (see [above](#bazzite-fedora-atomic-and-other-rpm-ostree-systems)). `--deps packages` layers the COPR package instead, then you reboot and run `gov install` again.
  - Debian/Ubuntu get the `.deb`. Anything else gets the same release build as rpm-ostree.
  - Releases are pinned to v0.4.15 (`GOV_TAG=` picks another). It must be v0.4.10 or later: before that the D-Bus name was different and there was no test mode for the tuner.
  - The tarball is checked against the release's sha256 file. That catches a broken download but comes from the same place as the tarball. The `.deb` has no published checksum.
  - The governor's default config allows 1850 MHz, so `gov install` offers to cap it at 1500 MHz first.
- **How the tuner works:** the governor has a test mode (a root-only D-Bus call) that holds the GPU at one clock and voltage. The tuner uses it to step the clock up, taking each step's voltage from your own curve, and runs the same checks as `cu test` at each step: GPU results compared against the CPU, GPU errors in the kernel log, hangs, and the temperature limit. The first failure ends the run. The recommended limit is one step below the highest clock that held, and it's only applied if you agree.
- **Undervolting** holds one point of the curve and steps its voltage down 10 mV at a time. Lowering one point also lowers the voltage of every clock between it and the points either side, because the governor interpolates. So before anything is saved, the clocks halfway to each neighbour are tested at their new voltages. The lowest stable voltage plus 20 mV is then offered as the new point, and the curve is kept valid (voltage never drops as the clock rises). After a curve change, run `gov tune` again, since earlier results were measured on the old curve.
- **Safety:**
  - The tuner never asks for more than 1050 mV, or a clock beyond the top of your curve, unless you pass `--force`. It refuses to run without a readable GPU temperature sensor, or with `--temp-limit` above 95 °C, because the governor's own throttling is off in test mode.
  - Voltages are calculated exactly the way the governor does, so what's tested is what it will use.
  - Overheating ends test mode immediately.
  - Every exit (finishing, an error, Ctrl-C) restarts the governor, which ends test mode and reloads the config.
  - If a step freezes the board, including during the switch to a new clock, the next run marks it failed and tests nothing at or above that clock, whatever the step size. `--retest-frozen` overrides this.
  - A step only counts as passed if the governor held the test clock throughout. If the governor restarts mid-step or rejects the D-Bus call, the run stops with no recommendation, rather than blaming the clock.
  - gpu-yield is paused during tuning, so no AI request runs at an untested clock. `--ollama-load` keeps Ollama running as a more realistic heat load instead.
- **Tune at the CU setting you'll actually run.** More compute units at the same clock means more heat, so unlock CUs first, then tune the clock.

## What it changes, and how to undo it

- **Edited files are backed up next to themselves** as `*.bc250-fixer.bak`, keeping the first original.
- **Kernel boot options** go through whatever your system uses: rpm-ostree, grubby, kernelstub, `/etc/kernel/cmdline`, or `/etc/default/grub` plus `update-grub`/`grub-mkconfig`.
- **Swap:** the swapfile goes at `/var/swap/swapfile` and gets an `/etc/fstab` line. On btrfs it uses `btrfs filesystem mkswapfile`. The SELinux label is set when SELinux is on.
- **zram:** the limit is written to `/etc/systemd/zram-generator.conf`.
- **Governor:** the config is backed up as `config.toml.bc250-fixer.bak` before the first change. `gov restore` puts it back. Edits keep its comments and layout, are checked before they're written, and replace the file in one step, so a crash can't leave it half-written.
- **CMOS:** a backup of the block is saved in `/var/lib/bc250-fixer/`. Clearing CMOS restores the factory settings.
- **Compute units:** a live change ends at reboot unless you persist it. `cu unpersist` removes the boot service.
- **State and tools:** these live in `/var/lib/bc250-fixer` and `/opt/bc250-fixer`. `uninstall purge` removes both, plus the container image `cu setup` built.

## Requirements and support

- Linux with systemd, bash 4.4+ and python3. Root for most commands.
- **Package installs** support dnf (Fedora), pacman (Arch) and apt (Debian/Ubuntu). On rpm-ostree (Bazzite/Atomic) nothing is layered unless you pass `--deps packages`, and that layering needs a reboot.
- **Secure Boot must be off** for the CMOS fix, the CU unlock and the governor. Kernel lockdown blocks `/dev/port`, GPU register writes and PCI config writes, and the tool tells you when that's the case.
- **The GPU must run on Vulkan (RADV), not ROCm.** Newer ROCm can hard-freeze this board.

## Status

- **`vram`:** the diagnosis and CMOS fix were confirmed on a real BC-250 (P3.00 firmware: 7.5 → 14.8 GiB after one reboot). The write was also checked byte for byte against the upstream C tool.
- **Everything else** is tested against a simulated board: fake routing registers, a fake verifier with planted faults, a fake journal, Ollama and systemd. The parts that touch real hardware are the community tools' work.
- **`--deps local`** was tested with a stand-in for podman that runs the container steps on the host, with real tools:
  - The verifier's shader and program were cut out of the pinned script and compiled. They then ran on Mesa's software Vulkan driver (lavapipe), with only the AMD-device check lifted, and checked 1M values with 0 errors.
  - Real stress-ng and setpci were bundled with their libraries and run through the wrappers. That covered a full `cpu test`.
  - The governor's v0.4.15 release was downloaded, checksum-checked and installed into a test root, then removed with `gov uninstall`.
  - Not tested: a real podman build on Bazzite, umr from Fedora's package, and any of it on a BC-250.
- **`gov`** is tested against a simulated governor: a fake D-Bus test mode, and a verifier that fails above a set clock or below a set voltage. The simulation also covered freezes, a failing D-Bus call, governor restarts mid-step and failing neighbour clocks. The config editor was tested on the governor's real default configs, and the module had its own independent review; each finding was fixed and re-tested.
- **The risky parts were reviewed by a second agent:** boot options, CMOS, swap/fstab, boot persistence and dry-run. Each issue it found has a test that now passes. Two examples: the GRUB editor keeps comments and quoting and checks its result before writing, and nothing is written when an edit fails.
- **First run on your board:** start with `check` and `--dry-run`, and if something looks wrong, [open an issue](https://github.com/AnonyMap/bc250-fixer/issues) with the `report` bundle.

## License

MIT, see [LICENSE](LICENSE). The community tools it downloads keep their own licenses.

## Credits

- [fanoush/bc250_memcfg](https://github.com/fanoush/bc250_memcfg): the CMOS memory-settings block.
- [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager): live CU routing and the CPU core unlock.
- [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock): the compute verifier.
- [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor): the GPU governor and its test mode.
- [AMD BC-250 docs](https://elektricm.github.io/amd-bc250-docs/), [SkillFishOS](https://github.com/MTSistemi/SkillFishOS) and the BC-250 community, for the settings and known-good values.
