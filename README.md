# tas2781-linux-fix

This project provides a **pragmatic workaround** for Linux systems using the
Texas Instruments **TAS2781 smart amplifier** that randomly lose speaker output,
most commonly after suspend/resume or after some time in normal operation.

It is **not a real fix** for the underlying issue.
Instead, it focuses on one goal only:

> **Make the speakers work reliably, even if that means reinitializing the amp
> more often than strictly necessary.**

## Background

On my system — a **Lenovo Legion Pro 7 (16IRX9H)** running **Debian 13 (trixie)**
with **kernel 6.12.57** — the internal speakers would regularly stop producing
sound. The audio devices remain present, but the TAS2781 amplifier ends up in a
broken state and never recovers on its own.

I spent a significant amount of time trying to properly fix the problem by
disabling or adjusting power management for the TAS2781 at various levels
(ALSA, kernel parameters, runtime PM, suspend hooks). While some of these
approaches helped partially, the issue would always reappear after some random
amount of time.

At that point, the priority shifted from *fixing it correctly* to simply
*making sound work once and for all*.

## Approach

This project implements a small watchdog-style workaround:

- A **systemd user service** runs in the background
- It monitors PipeWire activity using `pw-mon`
- When audio activity is detected, a **controlled reinitialization of the
  TAS2781 amplifier** is triggered

The hook via `pw-mon` is **not perfect** — the underlying issue does not appear
to be directly related to PipeWire state changes. However, it provides a
reliable signal that audio is about to be used, ensuring that:

- the amplifier is reinitialized **before audio is actually needed**
- sound works even if the reset would not have been strictly necessary

This trades elegance for reliability, intentionally.

An important consequence of this approach is that **power management does not
need to be disabled**.

All standard power management mechanisms (runtime PM, suspend/resume, DSP power
saving) can remain enabled. Instead of trying to prevent the TAS2781 from ever
entering a broken state, this workaround **accepts that it may happen** and
simply ensures the amplifier is brought back into a working state **when audio
is actually started**.

This avoids fragile global tweaks and keeps the system’s normal power behavior
intact, while still providing reliable audio output in practice.


## Scope and intent

- This is a **workaround**, not a kernel or ALSA fix
- It does **not** solve the root cause
- It may apply the fix more often than required
- It prioritizes **stable audio output** over architectural cleanliness

If you are affected by the same issue and want something that *just works*,
this approach has proven to be robust in practice.

## Credits

The actual runtime reinitialization logic for the TAS2781 amplifier is based on
work by Daniel Weiner:

<https://github.com/DanielWeiner/tas2781-fix-16IRX8H>

That project provided the crucial insight and code needed to reinitialize the
amplifier during runtime and restore audio output. This repository builds on
that foundation and wraps it in a more automated, always-on workaround.

---

## Tested on

- **Device:** Lenovo Legion Pro 7 (16IRX9H)
- **Distribution:** Debian 13 (trixie)
- **Kernel:** 6.12.57
- **Audio stack:** PipeWire + WirePlumber


## Prerequisites

Before using this workaround, make sure the following requirements are met.

### 1. i2c-tools

The TAS2781 amplifier is accessed via the I²C bus. The `i2c-tools` package is
required to communicate with the device at runtime.

Install it on Debian/Ubuntu with:

```bash
sudo apt update
sudo apt install i2c-tools
```


### 2. i2c-dev kernel module

User-space access to I²C devices requires the `i2c-dev` kernel module to be loaded.

Load the module immediately and verify it is active:

```bash
sudo modprobe i2c_dev
lsmod | grep i2c_dev
```


#### Ensure the module loads automatically on boot (recommended)

On modern Debian systems, persistent kernel modules are configured via
`/etc/modules-load.d/`.

Create a configuration file:

```bash
echo i2c_dev | sudo tee /etc/modules-load.d/i2c_dev.conf
```
This ensures i2c_dev is loaded automatically at every boot.

Verify the module is active:

```bash
lsmod | grep i2c_dev
```

### 3. Force SOF DSP driver (optional, but recommended)

On some systems, the Intel audio stack may **randomly fall back to the legacy
HDA driver** instead of using the **SOF (Sound Open Firmware) DSP driver**. When
this happens, the TAS2781 amplifier may not be initialized or controlled
correctly, resulting in missing or broken speaker output.

While it is not 100% clear whether this is strictly required for all setups,
forcing the SOF DSP driver has proven to improve stability and prevent
unexpected driver switching on the affected system.

To explicitly force the SOF driver, create the following modprobe
configuration file:

```bash
sudo nano /etc/modprobe.d/sof.conf
```

Add this line:
```
options snd-intel-dspcfg dsp_driver=3
```
Because this option is evaluated very early during boot, the 
initramfs should be updated to ensure the setting is applied reliably:
```bash
sudo update-initramfs -u
sudo reboot
```

### 4. Disable NVIDIA HDMI/DP audio (optional, only if you hit the “games kill audio” issue)

On some systems with an NVIDIA GPU, the kernel exposes an additional audio device
for **HDMI/DisplayPort audio** (`snd_hda_codec_hdmi`). In my case, audio via the
internal speakers was generally working, but **starting certain games caused
audio to stop** and it **did not recover after the game exited**.

A likely explanation is that some games (or audio middleware) aggressively
re-enumerate / switch the default output device, and the NVIDIA HDMI sink ends
up interfering with the selected audio route or PipeWire/WirePlumber policy.
When that happens, audio can get stuck in a broken routing state.

To avoid this, you can disable the NVIDIA HDMI/DP audio codec entirely by
blacklisting the driver:

Create the file:

```bash
sudo nano /etc/modprobe.d/disable-nvidia-hdmi.conf
```
Add this line:
```
blacklist snd_hda_codec_hdmi
```

Because this module can be loaded early, update initramfs and reboot:
```bash
sudo update-initramfs -u
sudo reboot
```

#### When you should NOT use this

Do not apply this if you actively use audio over HDMI/DisplayPort
(e.g., external monitor/TV speakers, AV receiver, monitor headphone jack).
Blacklisting will remove those outputs.

If you only want to disable HDMI audio sometimes, consider leaving it enabled
and instead adjusting PipeWire/WirePlumber defaults (preferred output device)
rather than blacklisting the driver globally.

## Installation

This project consists of two parts:

1. `tas2781-fix`  
   A **root-only helper** that reinitializes the TAS2781 amplifier at runtime
   **without requiring a reboot**.

2. `tas2781-pw-trigger.sh`  
   A **user-level watchdog** that monitors PipeWire activity and automatically
   invokes the fix when audio is about to be used.

### 1. Install the runtime fix helper (root)

The `tas2781-fix` script directly accesses the amplifier and therefore **must be
run as root**.

Copy it to `/usr/local/bin`:

```bash
sudo cp tas2781-fix /usr/local/bin/tas2781-fix
```

Set secure permissions:
```bash
sudo chown root:root /usr/local/bin/tas2781-fix
sudo chmod 755 /usr/local/bin/tas2781-fix
```

You can test it manually with:
```bash
sudo /usr/local/bin/tas2781-fix
```

If sound recovers immediately, the helper is working correctly.

> **Note about I²C permissions:**  
> `tas2781-fix` is intended to run as **root** (via `sudo`), so membership in the
> `i2c` group is normally **not required**.  
>  
> If you want to run the helper **without sudo** for debugging, add your user to
> the `i2c` group and re-login:
>
> ```bash
> sudo usermod -aG i2c <your-user>
> ```
>
> Check current permissions with:
>
> ```bash
> ls -l /dev/i2c-*
> ```


### 2. Install the PipeWire watcher (user)

To automate the fix, install the watcher script into your user’s local bindirectory:

```bash
mkdir -p ~/.local/bin
cp tas2781-pw-trigger.sh ~/.local/bin/tas2781-pw-trigger.sh
chmod +x ~/.local/bin/tas2781-pw-trigger.sh
```

This script runs as your user and does not require root itself.

### 3. Configure sudo for non-interactive execution

The watcher invokes the fix helper using sudo -n, which requires a dedicated sudoers rule. This allows exactly one command to be executed as root withouta password.

Run visudo:
```bash
sudo visudo
```

Add the following line, replacing <your-user> with your actual username:
```
<your-user> ALL=(root) NOPASSWD: /usr/local/bin/tas2781-fix
```


### 4. Install the systemd user service

Create the user service file:
```bash
mkdir -p ~/.config/systemd/user
nano ~/.config/systemd/user/tas2781-pw-trigger.service
```

Paste the following:
```
[Unit]
Description=TAS2781 PipeWire trigger (run fix after suspend/resume)
After=pipewire.service wireplumber.service
Wants=pipewire.service wireplumber.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 1
ExecStart=%h/.local/bin/tas2781-pw-trigger.sh
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Reload the user systemd daemon and enable the service:
```bash
systemctl --user daemon-reload
systemctl --user enable tas2781-pw-trigger.service
systemctl --user start tas2781-pw-trigger.service
```

You can check its status with:
```bash
systemctl --user status tas2781-pw-trigger.service
```

Logs are available via:
```bash
journalctl -f --user -u tas2781-pw-trigger.service
```

## Uninstall / Disable

If you want to stop using this workaround, the most important step is to disable the **systemd user service** that triggers the fix automatically.


### 1. Disable and stop the user service

Stop the service immediately:

```bash
systemctl --user stop tas2781-pw-trigger.service
```

Disable it so it no longer starts automatically:
```bash
systemctl --user disable tas2781-pw-trigger.service
```

Reload the user systemd configuration:
```bash
systemctl --user daemon-reload
```

At this point, the workaround is fully inactive.

Remove the systemd unit file:
```bash
rm -f ~/.config/systemd/user/tas2781-pw-trigger.service
```

### 2. Remove sudoers rule
Run
```bash
sudo visudo
```
and remove
```
<your-user> ALL=(root) NOPASSWD: /usr/local/bin/tas2781-fix
```

### 3.  Remove `i2c_dev` module configuration 
#### Unload the module (current session)

```bash
sudo modprobe -r i2c-dev
```

#### Prevent the module from loading automatically

If you added a modules-load configuration file, remove it:
```bash
sudo rm -f /etc/modules-load.d/i2c-dev.conf
```

### 4. (Optional) Revert related configuration changes

If you applied additional configuration changes while experimenting (for example disabling power management, forcing SOF, or blacklisting HDMI audio), you may want to revert those manually:

- /etc/modprobe.d/sof.conf
- /etc/modprobe.d/disable-nvidia-hdmi.conf
- /etc/modprobe.d/snd-hda-intel.conf

After reverting kernel module options, update initramfs and reboot:
```bash
sudo update-initramfs -u
sudo reboot
```

## Other approaches I tried (did not reliably solve the issue)

The following approaches were tested while investigating the TAS2781 audio
issues. While some of them improved behavior in certain situations, **none of
them solved the problem reliably over time** on my affected system.

They are documented here for completeness and may still be useful depending on
your hardware, kernel version, or distribution.

---

### Disable `power-profiles-daemon`

Disabling `power-profiles-daemon` initially made sound work reliably **after
boot**, but the audio issue would still reappear after some time or after
suspend/resume.

To stop and disable the service:

```bash
sudo systemctl stop power-profiles-daemon.service
sudo systemctl disable power-profiles-daemon.service
```

Because the service may be re-enabled automatically by package updates,
it is recommended to mask it as well:
```bash
sudo systemctl mask power-profiles-daemon.service
```

> **Note**
>
> Masking is reversible and prevents the service from being started by
> dependencies or updates.
>
> This was necessary in my case, as the service was reactivated unexpectedly
> after an update.


### Disabling various power management mechanisms

Several power management settings were tested in an attempt to keep the
amplifier from entering a broken state. These settings sometimes improved
stability, but never eliminated the issue completely.

#### Runtime tweaks
```bash
# Disable power saving for snd_hda_intel
echo 0 | sudo tee /sys/module/snd_hda_intel/parameters/power_save

# Force TAS2781 device to stay powered
echo on | sudo tee /sys/bus/i2c/drivers/tas2781-hda/i2c-TIAS2781:00/power/control
```


#### Persistent kernel module configuration
Create or edit:
```bash
sudo nano /etc/modprobe.d/snd-hda-intel.conf
```
Add:
```
options snd_hda_intel power_save=0
options snd_hda_intel power_save_controller=N
blacklist snd_soc_avs
```

After changing these options, update initramfs and reboot:
```bash
sudo update-initramfs -u
sudo reboot
```

While these settings may reduce the frequency of failures, they were not sufficient on their own to keep audio working reliably over time.

### Credit: TAS2781 I²C reinitialization work by Daniel Weiner
The following project initially looked like the **most promising approach** and was the main reference during my investigation:

<https://github.com/DanielWeiner/tas2781-fix-16IRX8H>

When used as-is on my system, this approach unfortunately disabled speaker output completely. However, it
provided the **crucial I²C reinitialization code** required to bring the TAS2781 amplifier back into a working state at runtime.

This repository builds on that contribution and reuses the core I²C handling
logic in a different way.

## Summary

In isolation, many of the above approaches appear to help. However, on the
affected system they all eventually failed after some random amount of time.

The solution implemented in this repository intentionally avoids relying on
power management behavior and instead actively recovers the amplifier at
runtime whenever audio is needed.
