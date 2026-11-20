# ccminer-ARM-percore

A Verus (VerusHash 2.2) CPU miner for ARM64 phones and boards, tuned per CPU core type.

Based on [Oink70/CCminer-ARM-optimized](https://github.com/Oink70/CCminer-ARM-optimized), which is based on
[monkins1010/ccminer (ARM)](https://github.com/monkins1010/ccminer/tree/ARM). No dev fee, no donation code.

## What is different in this fork

- One program holds several versions of the hash code and **picks the best one for each CPU core when it starts**
  (big and small cores in the same phone get different code). You do not have to choose anything.
- Shares are fully checked on the phone before they are sent, so the pool does not get "low difficulty" shares.
- One-step install scripts for Termux and UserLAnd.

Current version: **3.8.3-4-percore1** (shown when the miner starts).

Measured on our own phones (all 8 cores, 20-minute runs, against the unmodified miner built with the same compiler):

| Phone | Chip | Before | After | Gain |
|---|---|---|---|---|
| Galaxy S8 | Exynos 8895 | 4.97 MH/s | 6.20 MH/s | +25% |
| Galaxy S9 | Exynos 9810 | 4.64 MH/s | 6.36 MH/s | +37% |
| Galaxy S10 | Exynos 9820 | 5.30 MH/s | 6.98 MH/s | +32% |
| Galaxy S20 | Exynos 990 | 5.04 MH/s | 7.22 MH/s | +43% |

Your numbers depend on the phone, its cooling and the room temperature. Other chips (Snapdragon, MediaTek)
work too, but only the Exynos phones above were measured.

## What you need

- An ARM64 (64-bit) Android phone or board. Most phones from 2017 or later are fine.
- About 1 GB of free storage and a working internet connection.
- **Termux** (recommended) or **UserLAnd** installed on the phone.
- A Verus wallet address and a pool to mine on.
- Good cooling. Mining keeps every core at 100%: take the phone out of its case, and do not leave it
  charging on a bed or sofa. A hot phone slows itself down and wears its battery.

## Install in Termux (recommended)

Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or its
[GitHub releases](https://github.com/termux/termux-app/releases). The Play Store version is outdated and does not work.

Open Termux and paste these two lines:

```bash
curl -fsSL https://raw.githubusercontent.com/zzpajk/ccminer-ARM-percore/main/tools/termux-install.sh -o ~/termux-install.sh
bash ~/termux-install.sh
```

This updates Termux, installs what the build needs, downloads this repository to `~/ccminer` and builds the
miner. It takes roughly 5 to 15 minutes. Nothing is started and no pool or wallet is set.

If `curl` is missing, run `pkg install -y curl` first.

## Install in UserLAnd (Ubuntu or Debian)

Install UserLAnd, create an **Ubuntu** session and connect to it with SSH (the terminal option).
Then paste:

```bash
sudo apt-get update && sudo apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/zzpajk/ccminer-ARM-percore/main/tools/userland-install.sh -o ~/userland-install.sh
bash ~/userland-install.sh
```

**Note:** this installer is new and has not been tested on a phone yet. If something goes wrong, please
open an issue with the last lines it printed.

It asks for your UserLAnd password once. The result is the same as in Termux: the miner is in `~/ccminer`.
The same script also works on other Debian or Ubuntu ARM64 systems (for example a 64-bit Raspberry Pi OS).

## Set your pool and wallet

Open the settings file:

```bash
nano ~/ccminer/verus.conf
```

Change these two lines, then save with `Ctrl+O`, `Enter` and leave with `Ctrl+X`:

```json
"url": "stratum+tcp://YOUR_POOL:PORT",
"user": "YOUR_WALLET_ADDRESS.WORKER_NAME",
```

- `YOUR_WALLET_ADDRESS` is your own Verus address. **The address that is in the file from the start is only a
  placeholder: if you leave it, you mine for somebody else.**
- `WORKER_NAME` is any short name for this phone, for example `s10`. There is exactly one dot, between the
  address and the name.
- `"threads": 8` is the number of CPU cores to use. Lower it if the phone gets too hot.

If `nano` is missing: `pkg install -y nano` (Termux) or `sudo apt-get install -y nano` (UserLAnd).

## Start, watch, stop

```bash
~/ccminer/start-ccminer.sh
```

The miner now runs in the background. To watch it:

```bash
screen -r ccminer
```

Leave the view again with `Ctrl+A` and then `D` (the miner keeps running). To stop mining:

```bash
~/ccminer/stop-ccminer.sh
```

Lines with `accepted` and `yes!` mean the pool took your share. When it starts, every thread prints which
code it chose for its core, for example `Verus thread 6 on cpu 6: 3 nonce(s) per step`.

## Check the speed without a pool

```bash
~/ccminer/ccminer-verus -a verus --benchmark -t 8 --time-limit 60
```

## Update to the newest version

Run the install script again. It keeps your `verus.conf`, and it keeps the previous program as
`ccminer-verus.old` in case the new build fails.

```bash
bash ~/termux-install.sh
```

(in UserLAnd: `bash ~/userland-install.sh`)

## Tips and problems

- **Android stops Termux in the background.** Pull down the Termux notification and tap "Acquire wakelock",
  and switch off battery optimisation for Termux in the Android settings.
- **Only some cores are used in the background (Termux).** Android limits background apps to a few cores.
  Keeping Termux on screen avoids this. On a rooted phone this lifts the limit until the next reboot:

  ```bash
  su -c 'echo 0-7 > /dev/cpuset/foreground/cpus'
  ```

- **The hashrate drops after some minutes.** The phone is too hot and slows itself down. Improve the cooling
  (no case, a fan, a cool room) or use fewer threads.
- **The build fails or the phone freezes while building.** Close other apps and run the install script again.
  Phones with 4 GB of memory are enough for the normal build.
- **"Stratum connection failed".** The pool address or port in `verus.conf` is wrong, or the phone has no
  connection to it.

## How the per-core tuning works

The hash (VerusHash 2.2) runs 32 rounds, and each round jumps to one of eight kinds of work chosen by
the data itself. Different CPU cores struggle with different parts of that: big cores lose time when
they guess the next jump wrong, small cores lose time waiting for one step to finish before the next.
So the miner holds several versions of the hash code and gives each core the one that measured
fastest on it.

| Core type | Found in | Runs | Hashes per step |
|---|---|---|---|
| Cortex-A53 | S8 small cores | fold + batched restore (263296) | 1 |
| Cortex-A55 | S9, S10, S20 small cores | lean + batched restore (396416) | 1 |
| Mongoose M1/M2 | S8 big cores | threaded (7552) | 2 |
| Mongoose M3 / M5 | S9, S20 big cores | lean (2467) | 3 |
| Mongoose M4 | S10 big cores | standard (419) | 3 |
| Cortex-A75 / A76 | S10, S20 middle cores | threaded (7552) | 2 |
| Cortex-A73 | many 2017-2018 phones | standard, older form (384) | 2 |
| Other 64-bit ARM | | general version (483) | 2 |

What the names mean:

- **Several hashes per step:** the big cores work on two or three hashes at once, so while one waits,
  another can use the core. This is the largest single gain on the big cores. The S8's big cores stop
  at two because three no longer fit their fastest cache.
- **Standard:** the base for all versions: branch-free code for the parts that are a coin toss, and the
  key is restored after each hash from a clean copy instead of being rebuilt.
- **Fold:** merges the "which work" and "how many times" decisions into one jump, so the core guesses
  wrong less often. Pays on the S8's cores; the newer Mongoose cores predict well enough without it.
- **Lean:** fewer instructions around each jump. Pays on cores that are limited by instruction count.
- **Threaded:** lean, plus each round's work jumps straight to the next round's instead of returning
  to a central switch.
- **Batched restore:** puts the key back four rounds at a time, which suits the small in-order cores.

You can see each thread's choice when the miner starts, for example
`Verus thread 6 on cpu 6: 3 nonce(s) per step (SEL 2467)`. To force a version, set `VERUS_SEL`
(or `VERUS_SELMAP` per core type) before starting. The normal build only contains the versions above;
build with `--all-variants` to try the experimental ones.

## For developers

- `build-verus.sh` builds the miner in any checkout (`bash build-verus.sh`); the install scripts call it.
  Option `--all-variants` also builds every experimental variant we measured (needs about 2.5 GB of memory);
  those can then be forced with the environment variables `VERUS_SEL`, `VERUS_SELMAP`, `VERUS_X3`.
- With clang 18 or newer the build passes `-mllvm -aarch64-min-jump-table-entries=4`; without it the hash's
  8-way case switch becomes a branch tree and the miner is 4 to 10% slower.
- The per-core choices are in `verus/verusscan.cpp` (`verus_sel_for_cpu`), the hash rounds in
  `verus/verus_clhash_portable.cpp`. `tests/` holds the bit-exactness tests that CI runs on ARM64.
- `tools/` holds the benchmark scripts used for the measurements above.
