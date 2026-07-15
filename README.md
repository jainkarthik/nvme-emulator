# Host NVMe Emulation (Ubuntu 22.04/24.04)

This setup creates **6 emulated NVMe drives, 20GB each**, on the host and keeps them persistent across reboot.

It intentionally creates **raw block devices only**:
- no partitioning
- no filesystem creation
- no mounting
- no ZFS pool creation

You can format/use the drives yourself afterward.

## What this uses

1. Backing image files (`/var/lib/nvme-emu/nvme-drive{1..6}.img`)
2. Loop devices (`/dev/loop*`)
3. Linux NVMe target (`nvmet`) namespaces
4. Local NVMe loop transport connection (`nvme connect -t loop`)

Result: host-visible `/dev/nvme*` devices backed by persistent files.

## Files in this directory

- `setup_nvme_emu.sh`: creates/reconciles emulated NVMe devices
- `teardown_nvme_emu.sh`: disconnects/tears down emulation (keeps images by default)
- `nvme-emu.service`: systemd unit for persistence across reboot
- `install_persistence.sh`: installs scripts/service + enables autostart
- `CONTRIBUTING.md`: contribution guidelines
- `CODE_OF_CONDUCT.md`: community behavior expectations
- `SECURITY.md`: vulnerability reporting policy
- `CHANGELOG.md`: project change history
- `LICENSE`: MIT License

## Prerequisites

Install required packages:

```bash
sudo apt update
sudo apt install -y nvme-cli util-linux kmod
```

Ensure configfs is available:

```bash
sudo modprobe configfs
```

## One-time setup (persistent across reboot)

From this folder:

```bash
chmod +x setup_nvme_emu.sh teardown_nvme_emu.sh install_persistence.sh
sudo ./install_persistence.sh
```

This does:
1. Installs scripts to `/usr/local/sbin/`
2. Installs systemd unit to `/etc/systemd/system/nvme-emu.service`
3. Creates `/etc/modules-load.d/nvme-emu.conf`
4. Enables and starts `nvme-emu.service`

## Verify emulated drives

```bash
nvme list
nvme list-subsys
ls -l /var/lib/nvme-emu
```

You should see six 20GB namespaces as NVMe block devices.

## Reboot persistence check

```bash
sudo reboot
```

After reboot:

```bash
systemctl status nvme-emu.service --no-pager
nvme list
```

The service should be active and drives should be present again.

## Run core NVMe commands on all 6 drives

Example loop:

```bash
for d in /dev/nvme*n1; do
  echo "== $d =="
  sudo nvme id-ctrl "${d%n1}"
  sudo nvme id-ns "$d"
  sudo nvme smart-log "${d%n1}"
done
```

Notes:
- `id-ctrl` and `smart-log` use controller path (e.g., `/dev/nvme0`).
- `id-ns` uses namespace path (e.g., `/dev/nvme0n1`).

## Tuning configuration

Set environment variables before running setup:

```bash
sudo env NUM_DRIVES=6 DRIVE_SIZE_GB=20 BASE_DIR=/var/lib/nvme-emu \
  NQN=nqn.2026-07.local.host:nvme-emu PORT_ID=1 \
  /usr/local/sbin/setup_nvme_emu.sh
```

Defaults already match your requested layout.

## Teardown

Keep backing images:

```bash
sudo /usr/local/sbin/teardown_nvme_emu.sh
```

Destroy backing images too:

```bash
sudo DESTROY_IMAGES=1 /usr/local/sbin/teardown_nvme_emu.sh
```

## Troubleshooting

If service fails:

```bash
journalctl -u nvme-emu.service --no-pager -n 200
```

If no `/dev/nvme*` devices appear:
1. Check modules:
   ```bash
   lsmod | egrep 'nvmet|nvme_loop|loop'
   ```
2. Check subsystem connection:
   ```bash
   nvme list-subsys
   ```
3. Re-run setup:
   ```bash
   sudo /usr/local/sbin/setup_nvme_emu.sh
   ```

## Limitations

- This is software emulation; some hardware/vendor-specific NVMe commands are unsupported.
- Core admin + I/O workflows are the target.
- Device names (`/dev/nvmeXnY`) can vary by probe order; use `nvme list` each boot to confirm mapping.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution and validation guidelines.

## Security

See [SECURITY.md](./SECURITY.md) for responsible vulnerability disclosure.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
