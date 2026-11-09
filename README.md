# bc250-fixer: maintenance toolkit for the AMD BC-250

One script for the things that go wrong when you use a BC-250 for local AI. It checks the board, fixes common setup problems, unlocks and tests the extra GPU compute units, and collects a support bundle when you need help.

```bash
curl -LO https://raw.githubusercontent.com/AnonyMap/bc250-fixer/main/bc250-fixer
chmod +x bc250-fixer
sudo ./bc250-fixer install     # optional: puts it at /usr/local/sbin/bc250-fixer
sudo bc250-fixer check         # read-only health check
sudo bc250-fixer fix --dry-run # see what it would change
sudo bc250-fixer fix           # fix it (asks before each change)
```

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
| `cu setup` | Installs `umr` and the compute-unit test tools. |
| `cu test [WGP...]` | Tests each of the 8 extra CU pairs on its own, live, then soaks all the passing pairs together. A pair fails on wrong results, GPU errors in the kernel log, a hang, or reaching the temperature limit. |
| `cu apply N\|passing\|all\|stock\|WGP...` | Changes the CU layout now, until reboot. `N` is a count from 24 to 40 in pairs; the pairs are spread evenly across the GPU's four sections. |
| `cu bench` | Ollama reading/writing speed, stock vs unlocked. |
| `cu persist` / `cu unpersist` | Applies the layout at every boot, with a crash-loop guard / stops. |
| `cu status` | Current layout, temperatures, clock cap, test results, persistence. |
| `cpu unlock` / `cpu test [SECONDS]` | The 2 disabled CPU cores (6 → 8), and a stress test that checks results on every thread. |
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

**Command flags:**
- `cu test`, `soak` and `cu bench`: `--passes N`, `--rounds N`, `--soak-minutes N`, `--temp-limit C` (default 92), `--model NAME`.
- `fix swap`: `--size GB`.
- `monitor`: `--interval S`, `--count N`, `--log FILE`.
- `llama build` and `llama bench`: `--llama-dir DIR`.

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
- **Cap the GPU clock at 1500 MHz @ 900 mV.** Community boards at 2 GHz and 40 CUs reached 96–107 °C. The tool warns if your governor allows more.

## What it changes, and how to undo it

- **Edited files are backed up next to themselves** as `*.bc250-fixer.bak`, keeping the first original.
- **Kernel boot options** go through whatever your system uses: rpm-ostree, grubby, kernelstub, `/etc/kernel/cmdline`, or `/etc/default/grub` plus `update-grub`/`grub-mkconfig`.
- **Swap:** the swapfile goes at `/var/swap/swapfile` and gets an `/etc/fstab` line. On btrfs it uses `btrfs filesystem mkswapfile`. The SELinux label is set when SELinux is on.
- **zram:** the limit is written to `/etc/systemd/zram-generator.conf`.
- **CMOS:** a backup of the block is saved in `/var/lib/bc250-fixer/`. Clearing CMOS restores the factory settings.
- **Compute units:** a live change ends at reboot unless you persist it. `cu unpersist` removes the boot service.
- **State and tools:** these live in `/var/lib/bc250-fixer` and `/opt/bc250-fixer`; `uninstall purge` removes both.

## Requirements and support

- Linux with systemd, bash 4.4+ and python3. Root for most commands.
- **Package installs** support dnf (Fedora), rpm-ostree (Bazzite/Atomic: layering needs a reboot), pacman (Arch) and apt (Debian/Ubuntu).
- **CMOS access needs Secure Boot off.** Kernel lockdown blocks `/dev/port`, and the tool tells you if that's the case.
- **The GPU must run on Vulkan (RADV), not ROCm.** Newer ROCm can hard-freeze this board.

## Status

- **`vram`:** the diagnosis and CMOS fix were confirmed on a real BC-250 (P3.00 firmware: 7.5 → 14.8 GiB after one reboot). The write was also checked byte for byte against the upstream C tool.
- **Everything else** is tested against a simulated board: fake routing registers, a fake verifier with planted faults, a fake journal, Ollama and systemd. The parts that touch real hardware are the community tools' work.
- **The risky parts were reviewed by a second agent:** boot options, CMOS, swap/fstab, boot persistence and dry-run. Each issue it found has a test that now passes. Two examples: the GRUB editor keeps comments and quoting and checks its result before writing, and nothing is written when an edit fails.
- **First run on your board:** start with `check` and `--dry-run`, and if something looks wrong, [open an issue](https://github.com/AnonyMap/bc250-fixer/issues) with the `report` bundle.

## License

MIT, see [LICENSE](LICENSE). The community tools it downloads keep their own licenses.

## Credits

- [fanoush/bc250_memcfg](https://github.com/fanoush/bc250_memcfg): the CMOS memory-settings block.
- [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager): live CU routing and the CPU core unlock.
- [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock): the compute verifier.
- [AMD BC-250 docs](https://elektricm.github.io/amd-bc250-docs/), [SkillFishOS](https://github.com/MTSistemi/SkillFishOS) and the BC-250 community, for the settings and known-good values.
