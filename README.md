# TrueNAS Legacy NVIDIA Driver Builder

Builds a customized TrueNAS update with NVIDIA driver 580.173.02 support for legacy GPUs such as the Quadro P2000.

## Run

On a 64-bit Ubuntu/Debian Linux host with `sudo` and Docker:

```bash
chmod +x build-fast-update-v3-25.10.7.sh
./build-fast-update-v3-25.10.7.sh
```

The script automatically selects the latest stable TrueNAS release, verifies its SHA256, detects its kernel, builds the proprietary NVIDIA driver, and writes the custom update under the script directory's `output/` folder.

Run as your normal user; the script uses `sudo` when needed.
