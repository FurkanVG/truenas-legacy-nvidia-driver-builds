# TrueNAS Legacy NVIDIA Driver Builder

Builds a customized TrueNAS update embedding the proprietary NVIDIA 580.173.02 driver for supported legacy GPU generations.

## GPU support

NVIDIA's 580.xx branch supports the following legacy architectures and product families:

- Maxwell (GMxxx): GeForce GTX 745/750/750 Ti, GTX 900 series, selected 800M/900M/MX mobile GPUs, Quadro M-series and selected Maxwell-based Quadro K-series models, and Tesla M-series models.
- Pascal (GPxxx): GeForce GTX 10-series, Titan X/Xp, Quadro P-series, Tesla P-series, and related OEM/workstation variants.
- Volta (GVxxx): Titan V, Quadro GV100, and Tesla V100 variants.

The exact supported model and PCI-ID table is maintained by NVIDIA in its [580.xx supported-products list](https://www.nvidia.com/en-us/drivers/unix/legacy-gpu/). Product names can be misleading: some K-series models are Maxwell and supported, while Kepler-based K-series models are not.

Not supported by this driver branch:

- Kepler (GKxxx), including many GeForce GTX 600/700, Quadro K, and Tesla K models; NVIDIA's 470.xx branch is the last branch for Kepler.
- Fermi (GF1xx), including GeForce GTX 400/500, older Quadro, and Tesla models; NVIDIA's 390.xx branch is the last branch for Fermi.
- Older G8x/G9x/GT2xx, NV4x/G7x, and earlier GPUs, which require NVIDIA's older 340.xx, 304.xx, 173.xx, 96.xx, or 71.xx branches.

Always verify the exact GPU PCI ID against NVIDIA's table before installing the update. This project changes the TrueNAS embedded driver image; it does not add support for an architecture that NVIDIA's 580.173.02 driver does not support.

## Run

On a 64-bit Ubuntu/Debian Linux host with `sudo` and Docker:

```bash
chmod +x build-fast-update-v3-25.10.7.sh
./build-fast-update-v3-25.10.7.sh
```

The script automatically selects the latest stable TrueNAS release, verifies its SHA256, detects its kernel, builds the proprietary NVIDIA driver, and writes the custom update under the script directory's `output/` folder.

Run as your normal user; the script uses `sudo` when needed.
