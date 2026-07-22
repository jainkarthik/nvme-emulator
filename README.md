# Host NVMe Emulation (Ubuntu 22.04/24.04)

This repository creates persistent, raw NVMe block devices on the host using backing files, loop devices, `nvmet`, and the NVMe loop transport.

By default it creates **6 drives of 20 GiB each** at `/var/lib/nvme-emu/nvme-drive{1..6}.img`.

It does **not** partition, format, or mount anything.

## Prerequisites

Install the required packages:

```bash
sudo apt update
sudo apt install -y nvme-cli util-linux kmod
```

Make sure `configfs` can be mounted:

```bash
sudo modprobe configfs
```

## Quick start

From the repository root:

```bash
chmod +x setup_nvme_emu.sh teardown_nvme_emu.sh install_persistence.sh
sudo ./install_persistence.sh
```

That will:
1. Install the scripts to `/usr/local/sbin/`
2. Install `nvme-emu.service` to `/etc/systemd/system/`
3. Create `/etc/modules-load.d/nvme-emu.conf`
4. Enable and start the service

To remove the persistent install later:

```bash
sudo ./install_persistence.sh uninstall
```

To tear down the NVMe devices but keep the backing images:

```bash
sudo /usr/local/sbin/teardown_nvme_emu.sh
```

To tear down everything, including the image files:

```bash
sudo DESTROY_IMAGES=1 /usr/local/sbin/teardown_nvme_emu.sh
```

Run `setup_nvme_emu.sh` when you want to create or reconcile the emulated NVMe devices:
- the first time you set the system up
- after a reboot if the service is not enabled
- after changing `NUM_DRIVES`, `DRIVE_SIZE_GB`, `BASE_DIR`, `NQN`, or `PORT_ID`
- after teardown, if you want the drives back immediately

## What gets created

1. Backing image files in `BASE_DIR`
2. Loop devices for those files
3. `nvmet` namespaces
4. A local NVMe loop connection that appears as `/dev/nvme*`

## Configuration

Use environment variables when running `setup_nvme_emu.sh` or `teardown_nvme_emu.sh`:

| Variable | Default | Meaning |
|---|---:|---|
| `NUM_DRIVES` | `6` | Number of namespaces/drives |
| `DRIVE_SIZE_GB` | `20` | Size of each backing image |
| `BASE_DIR` | `/var/lib/nvme-emu` | Directory for backing images |
| `IMAGE_PREFIX` | `nvme-drive` | Backing image filename prefix |
| `NQN` | `nqn.2026-07.local.host:nvme-emu` | NVMe subsystem NQN |
| `PORT_ID` | `1` | NVMe target port ID |
| `DESTROY_IMAGES` | `0` | Set to `1` during teardown to delete images |

`NUM_DRIVES`, `DRIVE_SIZE_GB`, and `PORT_ID` must be positive integers. `NQN` must not contain `/`.

Example:

```bash
sudo env NUM_DRIVES=6 DRIVE_SIZE_GB=20 BASE_DIR=/var/lib/nvme-emu \
  NQN=nqn.2026-07.local.host:nvme-emu PORT_ID=1 \
  ./setup_nvme_emu.sh
```

## Verify

```bash
nvme list
nvme list-subsys
ls -l /var/lib/nvme-emu
```

You should see six NVMe namespaces backed by the image files.

## Reboot persistence

After setup, rebooting should restore the same drives automatically:

```bash
sudo reboot
```

Then verify:

```bash
systemctl status nvme-emu.service --no-pager
nvme list
```

## Common NVMe commands

```bash
for d in /dev/nvme*n1; do
  echo "== $d =="
  sudo nvme id-ctrl "${d%n1}"
  sudo nvme id-ns "$d"
  sudo nvme smart-log "${d%n1}"
done
```

`id-ctrl` and `smart-log` use the controller path (`/dev/nvme0`), while `id-ns` uses the namespace path (`/dev/nvme0n1`).

## Troubleshooting

If the service fails:

```bash
journalctl -u nvme-emu.service --no-pager -n 200
```

If no `/dev/nvme*` devices appear:
1. Check loaded modules:
   ```bash
   lsmod | egrep 'nvmet|nvme_loop|loop'
   ```
2. Check the subsystem connection:
   ```bash
   nvme list-subsys
   ```
3. Re-run setup:
   ```bash
   sudo /usr/local/sbin/setup_nvme_emu.sh
   ```

## Files in this repository

- `setup_nvme_emu.sh`: creates or reconciles the emulated NVMe devices
- `teardown_nvme_emu.sh`: disconnects and tears down the emulation
- `nvme-emu.service`: systemd unit for boot-time persistence
- `install_persistence.sh`: installs or uninstalls the persistent setup
- `CONTRIBUTING.md`: contribution guidelines
- `CODE_OF_CONDUCT.md`: community behavior expectations
- `SECURITY.md`: vulnerability reporting policy
- `CHANGELOG.md`: project history
- `LICENSE`: MIT License

## Limitations

- This is software emulation; some hardware/vendor-specific NVMe commands are unsupported.
- Core admin and I/O workflows are the target.
- Device names (`/dev/nvmeXnY`) can vary by probe order; use `nvme list` after boot to confirm mapping.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Security

See [SECURITY.md](./SECURITY.md).

## License

See [LICENSE](./LICENSE).
