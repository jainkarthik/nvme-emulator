# Contributing

Thanks for your interest in improving this project.

## Development workflow

1. Fork the repository and create a feature branch.
2. Keep changes focused and small.
3. Update documentation when behavior or usage changes.
4. Open a pull request with a clear summary of what changed and why.

## Quality expectations

- Scripts should stay idempotent where possible.
- Keep defaults safe for host systems.
- Prefer explicit errors over silent failures.

## Testing and validation

Before opening a pull request, validate changes on Ubuntu 22.04/24.04:

```bash
sudo ./setup_nvme_emu.sh
nvme list
sudo ./teardown_nvme_emu.sh
```

If your change impacts persistence behavior, also verify:

```bash
sudo ./install_persistence.sh
systemctl status nvme-emu.service --no-pager
```

## Code of conduct

Please be respectful and constructive in all discussions and reviews.
