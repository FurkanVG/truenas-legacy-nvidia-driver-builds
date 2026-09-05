# Third-party notices

The MIT license in this repository applies only to the original builder script and documentation. It does not apply to software downloaded, assembled, or published by the builder.

## NVIDIA driver

The NVIDIA 580.173.02 driver and its accompanying components remain the property of NVIDIA Corporation and are governed by the [NVIDIA Driver License Agreement](https://www.nvidia.com/en-us/drivers/nvidia-license/). Review that agreement before using or redistributing any NVIDIA-containing release asset. Release recipients are responsible for complying with the applicable NVIDIA terms.

## TrueNAS

TrueNAS update contents and related components remain subject to their respective iXsystems/TrueNAS licenses, notices, and applicable [TrueNAS EULAs and legal policies](https://www.truenas.com/legal/). This project is unofficial and is not affiliated with or endorsed by iXsystems or TrueNAS.

## Build dependencies

The build uses an Ubuntu container image, Ubuntu/Debian packages, and the external [TrueNAS Community NVIDIA driver builder](https://github.com/truenas-community-sysexts/nvidia-driver-support). Each component remains subject to its own license and terms. The builder pins the external source commit and container image digest used for reproducible builds, but package repositories and vendor download terms still apply.
