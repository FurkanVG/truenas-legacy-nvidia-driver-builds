#!/usr/bin/env bash
set -Eeuo pipefail

VERSION=""
KERNEL_EXPECTED=""
NVIDIA_VERSION="580.173.02"
NVIDIA_RUN_FILE="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"
NVIDIA_RUN_SHA256="e90b79270cfc12fc9374721df4831c6cf0ec332f8ce993c40bb018b0e28bf238"

UPDATE_BASE_URL="https://update.truenas.com/scale"
TRAINS_URL="https://auto-public.sys.truenas.net/trains_v2.json"

NVIDIA_BUILDER_REPO="https://github.com/truenas-community-sysexts/nvidia-driver-support.git"
NVIDIA_BUILDER_COMMIT_EXPECTED="59368f7d4aa094951492f28e23a4db4a80c36a0c"

# Pin the build image so a mutable container tag cannot silently change the
# generated driver or update. This is the digest currently corresponding to
# Ubuntu 24.04 on the supported x86_64 host architecture.
DOCKER_IMAGE="ubuntu@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORK="$SCRIPT_DIR/work"
OUT="$SCRIPT_DIR/output"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || die "Required command not found: $1"
}

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This builder must run on Linux, not $(uname -s)."
fi

HOST_ARCH="$(uname -m)"
[[ "$HOST_ARCH" == "x86_64" || "$HOST_ARCH" == "amd64" ]] \
    || die "Unsupported host architecture '$HOST_ARCH'; use a 64-bit x86_64/amd64 Linux host."

[[ "$(getconf LONG_BIT 2>/dev/null || true)" == "64" ]] \
    || die "A 64-bit userspace is required."

CACHE="$WORK/cache"
COMMUNITY_REPO="$WORK/nvidia-driver-support"
RAW_DIR="$WORK/raw-output"
OUTER="$WORK/update-outer"
ROOTFS_TREE="$WORK/rootfs-tree"
VERIFY="$WORK/verify"
NVIDIA_RUN_CACHE="$CACHE/$NVIDIA_RUN_FILE"
NVIDIA_RUN_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${NVIDIA_RUN_FILE}"

# Use the user's Docker daemon when available. On a standard Ubuntu install,
# fall back to sudo docker when the user is not in the docker group yet.
DOCKER=(docker)

banner() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}

cleanup_mounts() {
    set +e
    findmnt -rn -o TARGET 2>/dev/null |
        grep -F "$WORK/" |
        awk '{print length, $0}' |
        sort -rn |
        cut -d' ' -f2- |
        while IFS= read -r m; do
            sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
        done
}
trap cleanup_mounts EXIT INT TERM

HOST_DISTRO="unknown"
if [[ -r /etc/os-release ]]; then
    # Read distro metadata in a subshell so VERSION remains the TrueNAS
    # release number; /etc/os-release also defines a variable named VERSION.
    HOST_DISTRO="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")"
fi
echo "Host           : ${HOST_ARCH} Linux"
echo "Linux distro   : ${HOST_DISTRO}"
echo "Host kernel    : $(uname -r)"

banner "Install/check native Linux host tools"

require_command sudo
require_command apt-get

sudo apt-get update
sudo apt-get install -y \
    ca-certificates curl git jq kmod libarchive-tools \
    python3 rsync squashfs-tools util-linux wget xz-utils

if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get install -y docker.io
fi

if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
    else
        sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
    fi
fi

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
        DOCKER=(sudo docker)
    else
        die "Docker daemon is not running. Run: sudo systemctl enable --now docker"
    fi
fi

require_command git
require_command sha256sum
require_command findmnt

mkdir -p "$WORK" "$OUT" "$CACHE" "$RAW_DIR"

echo
df -h "$SCRIPT_DIR" || true

banner "Resolve latest stable TrueNAS release"

# The official update service publishes active trains and per-train release
# metadata. Select the newest release marked GENERAL, MISSION_CRITICAL, or
# STABLE, while excluding beta/RC/nightly/developer releases.
RELEASE_INFO="$(python3 - "$TRAINS_URL" "$UPDATE_BASE_URL" <<'PY'
import json
import re
import sys
from urllib.request import Request, urlopen

trains_url, update_base = sys.argv[1:]

def get_json(url):
    request = Request(url, headers={"User-Agent": "TrueNAS-legacy-nvidia-builder/1.0"})
    with urlopen(request, timeout=30) as response:
        return json.load(response)

def version_key(version):
    return tuple(int(part) for part in re.findall(r"\d+", version))

try:
    trains = get_json(trains_url).get("trains", {})
except Exception as exc:
    raise SystemExit(f"ERROR: unable to read TrueNAS train metadata: {exc}")

candidates = []
for train, metadata in trains.items():
    label = f"{train} {metadata.get('description', '')}"
    if metadata.get("stable") is False:
        continue
    if re.search(r"nightly|beta|rc|prerelease|developer|master", label, re.I):
        continue

    try:
        releases = get_json(f"{update_base}/{train}/releases.json")
    except Exception:
        continue

    stable = []
    for release in releases.values():
        version = str(release.get("version", ""))
        profile = str(release.get("profile", ""))
        if not version or not release.get("filename") or not release.get("checksum"):
            continue
        if re.search(r"beta|rc|alpha|nightly|master|developer", version, re.I):
            continue
        if profile and profile not in {"GENERAL", "MISSION_CRITICAL", "STABLE"}:
            continue
        stable.append(release)

    if not stable:
        continue

    release = max(stable, key=lambda item: version_key(str(item["version"])))
    version = str(release["version"])
    candidates.append((version_key(version), train, release))

if not candidates:
    raise SystemExit("ERROR: no stable TrueNAS release was found")

_, train, release = max(candidates, key=lambda item: item[0])
version = str(release["version"])
filename = str(release["filename"])
checksum = str(release["checksum"])

codename = ""
if train.startswith("TrueNAS-SCALE-"):
    codename = train.removeprefix("TrueNAS-SCALE-")

print("\t".join((train, version, filename, checksum, codename)))
PY
)"

IFS=$'\t' read -r UPDATE_TRAIN VERSION UPDATE_FILENAME UPDATE_SHA256 TRUENAS_CODENAME <<< "$RELEASE_INFO"

[[ -n "$UPDATE_TRAIN" && -n "$VERSION" && -n "$UPDATE_FILENAME" && -n "$UPDATE_SHA256" ]] \
    || die "TrueNAS release metadata was incomplete"

[[ "$UPDATE_FILENAME" != */* && "$UPDATE_FILENAME" != *\\* ]] \
    || die "TrueNAS release metadata returned an invalid filename"

[[ "$UPDATE_SHA256" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "TrueNAS release metadata returned an invalid SHA256"

UPDATE_URL="$UPDATE_BASE_URL/$UPDATE_TRAIN/$UPDATE_FILENAME"
OFFICIAL_UPDATE="$CACHE/$UPDATE_FILENAME"
CUSTOM_RAW="$OUT/nvidia.raw"
CUSTOM_UPDATE="$OUT/${UPDATE_FILENAME%.update}-NVIDIA580.update"

echo "Selected train : ${UPDATE_TRAIN}"
echo "Selected version: ${VERSION}"
echo "Update URL     : ${UPDATE_URL}"
echo "Expected SHA256 : ${UPDATE_SHA256}"

banner "1/10 Obtain + verify official TrueNAS ${VERSION} update"

if [[ ! -f "$OFFICIAL_UPDATE" ]]; then
    wget -c --show-progress -O "$OFFICIAL_UPDATE" "$UPDATE_URL"
fi

printf '%s  %s\n' "$UPDATE_SHA256" "$OFFICIAL_UPDATE" | sha256sum -c - \
    || die "Official TrueNAS ${VERSION} SHA256 verification failed"

echo "Official update verified."

# Read the kernel actually shipped by this update instead of carrying a
# release-specific kernel string in the builder.
KERNEL_EXPECTED="$(sudo unsquashfs -cat "$OFFICIAL_UPDATE" manifest.json | \
    python3 -c '
import json
import sys

expected = sys.argv[1]
manifest = json.load(sys.stdin)
manifest_version = manifest.get("version")
if manifest_version != expected:
    raise SystemExit(
        "ERROR: downloaded manifest version {!r} does not match "
        "selected release {!r}".format(manifest_version, expected)
    )
kernel = manifest.get("kernel_version")
if not kernel:
    raise SystemExit("ERROR: downloaded update manifest has no kernel_version")
print(kernel)
' "$VERSION")"

echo "TrueNAS kernel: ${KERNEL_EXPECTED}"

banner "2/10 Clone pinned NVIDIA sysext builder"

sudo rm -rf "$COMMUNITY_REPO"

git init "$COMMUNITY_REPO" >/dev/null
git -C "$COMMUNITY_REPO" remote add origin "$NVIDIA_BUILDER_REPO"
git -C "$COMMUNITY_REPO" fetch --depth 1 origin "$NVIDIA_BUILDER_COMMIT_EXPECTED"
git -C "$COMMUNITY_REPO" checkout --detach "$NVIDIA_BUILDER_COMMIT_EXPECTED" >/dev/null

cd "$COMMUNITY_REPO"

# Only needed by legacy 470 branch, but harmless and makes checkout complete.
git submodule update --init --recursive

NVIDIA_BUILDER_COMMIT_ACTUAL="$(git rev-parse HEAD)"
[[ "$NVIDIA_BUILDER_COMMIT_ACTUAL" == "$NVIDIA_BUILDER_COMMIT_EXPECTED" ]] \
    || die "Checked out NVIDIA builder commit '$NVIDIA_BUILDER_COMMIT_ACTUAL', expected '$NVIDIA_BUILDER_COMMIT_EXPECTED'"
echo "Builder commit: ${NVIDIA_BUILDER_COMMIT_ACTUAL}"

# Patch the pinned upstream entrypoint only in the disposable checkout so the
# verified host-side NVIDIA installer is used and verified inside the build
# container before the upstream script can execute it.
python3 - "$COMMUNITY_REPO/scripts/build-nvidia-sysext.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

preload_needle = 'BUILD_DIR="${WORK_ROOT}/nvidia_build"\n'
preload_insert = (
    preload_needle
    + '\n'
    + '# Preloaded and independently verified by the outer builder.\n'
    + 'PRELOADED_RUN_FILE="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"\n'
    + 'mkdir -p "$BUILD_DIR"\n'
    + 'if [ -f "/work/cache/$PRELOADED_RUN_FILE" ]; then\n'
    + '    cp "/work/cache/$PRELOADED_RUN_FILE" "$BUILD_DIR/$PRELOADED_RUN_FILE"\n'
    + 'fi\n'
)
if text.count(preload_needle) != 1:
    raise SystemExit("ERROR: upstream builder layout changed; cannot preload NVIDIA installer")
text = text.replace(preload_needle, preload_insert, 1)

download_block = '''if [ -f "$RUN_FILE" ]; then
    info "Run file already present, skipping download"
else
    info "Downloading from $NV_URL"
    wget -q --show-progress -c "$NV_URL" || die "Failed to download $RUN_FILE"
fi
'''
download_replacement = '''if [ -f "/work/cache/$RUN_FILE" ]; then
    cp "/work/cache/$RUN_FILE" "$RUN_FILE"
else
    die "Verified NVIDIA installer is missing from /work/cache"
fi
'''
if text.count(download_block) != 1:
    raise SystemExit("ERROR: upstream builder layout changed; cannot disable unverified installer download")
text = text.replace(download_block, download_replacement, 1)

verify_needle = 'chmod +x "$RUN_FILE"\n'
verify_insert = (
    'printf \'%s  %s\\n\' "${NVIDIA_RUN_SHA256:?}" "$RUN_FILE" | sha256sum -c - \\\n'
    '    || die "NVIDIA installer SHA256 verification failed"\n'
    + verify_needle
)
if text.count(verify_needle) != 1:
    raise SystemExit("ERROR: upstream builder layout changed; cannot verify NVIDIA installer")
text = text.replace(verify_needle, verify_insert, 1)
path.write_text(text)
PY

banner "3/10 Ensure pinned Ubuntu 24.04 Docker image exists"

"${DOCKER[@]}" pull "$DOCKER_IMAGE"

banner "4/10 Obtain + verify pinned NVIDIA ${NVIDIA_VERSION} installer"

if [[ -f "$NVIDIA_RUN_CACHE" ]] && \
    ! printf '%s  %s\n' "$NVIDIA_RUN_SHA256" "$NVIDIA_RUN_CACHE" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$NVIDIA_RUN_CACHE"
fi

if [[ ! -f "$NVIDIA_RUN_CACHE" ]]; then
    wget -c --show-progress -O "$NVIDIA_RUN_CACHE" "$NVIDIA_RUN_URL"
fi

printf '%s  %s\n' "$NVIDIA_RUN_SHA256" "$NVIDIA_RUN_CACHE" | sha256sum -c - \
    || die "NVIDIA ${NVIDIA_VERSION} installer SHA256 verification failed"

banner "5/10 Build proprietary NVIDIA nvidia.raw"

sudo rm -rf "$RAW_DIR"
mkdir -p "$RAW_DIR"

# The repository is deliberately mounted READ-ONLY.
#
# IMPORTANT FIX FROM v3:
# Do NOT chmod anything in /work/repo.
# Invoke the script through bash, which does not require executable permission.
"${DOCKER[@]}" run --rm \
    -v "$COMMUNITY_REPO:/work/repo:ro" \
    -v "$OFFICIAL_UPDATE:/work/truenas.update:ro" \
    -v "$CACHE:/work/cache:ro" \
    -v "$RAW_DIR:/work/out" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e NVIDIA_VERSION="$NVIDIA_VERSION" \
    -e NVIDIA_RUN_SHA256="$NVIDIA_RUN_SHA256" \
    -e TRUENAS_VERSION="$VERSION" \
    -e TRUENAS_CODENAME="$TRUENAS_CODENAME" \
    "$DOCKER_IMAGE" \
    bash -lc '
        set -Eeuo pipefail

        apt-get update -qq

        apt-get install -y --no-install-recommends \
            build-essential \
            gcc-14 \
            squashfs-tools \
            kmod \
            xz-utils \
            bison \
            flex \
            libelf-dev \
            bc \
            rsync \
            libssl-dev \
            pkg-config \
            pciutils \
            gnupg \
            ca-certificates \
            wget \
            curl \
            patch \
            git

        bash /work/repo/scripts/build-nvidia-sysext.sh \
            --nvidia-version="$NVIDIA_VERSION" \
            --truenas-version="$TRUENAS_VERSION" \
            --truenas-codename="$TRUENAS_CODENAME" \
            --kernel-module-type=proprietary \
            --update-file=/work/truenas.update \
            --out=/work/out
    '

[[ -f "$RAW_DIR/nvidia.raw" ]] \
    || die "NVIDIA builder did not produce nvidia.raw"

sudo chown "$(id -u):$(id -g)" "$RAW_DIR/nvidia.raw" 2>/dev/null || true

if [[ -f "$RAW_DIR/nvidia.raw.sha256" ]]; then
    sudo chown "$(id -u):$(id -g)" "$RAW_DIR/nvidia.raw.sha256" 2>/dev/null || true
fi

cp -f "$RAW_DIR/nvidia.raw" "$CUSTOM_RAW"
( cd "$(dirname "$CUSTOM_RAW")" && sha256sum "$(basename "$CUSTOM_RAW")" ) \
    > "$OUT/nvidia.raw.sha256"

banner "6/10 Hard-verify nvidia.raw"

RAW_VERIFY="$VERIFY/raw"

sudo rm -rf "$RAW_VERIFY"
mkdir -p "$RAW_VERIFY"

sudo unsquashfs -d "$RAW_VERIFY" "$CUSTOM_RAW" >/dev/null

echo "NVIDIA kernel modules:"
find "$RAW_VERIFY" -type f -name 'nvidia*.ko' -printf '  %P\n' | sort || true

MAIN_KO="$(find "$RAW_VERIFY" -type f -name 'nvidia.ko' -print -quit)"

[[ -n "$MAIN_KO" ]] \
    || die "Generated nvidia.raw has no nvidia.ko"

NVIDIA_SMI="$(find "$RAW_VERIFY" -type f -path '*/usr/bin/nvidia-smi' -print -quit)"

[[ -n "$NVIDIA_SMI" ]] \
    || die "Generated nvidia.raw has no nvidia-smi"

VERMAGIC="$(modinfo -F vermagic "$MAIN_KO" 2>/dev/null || true)"
MOD_VERSION="$(modinfo -F version "$MAIN_KO" 2>/dev/null || true)"
MOD_LICENSE="$(modinfo -F license "$MAIN_KO" 2>/dev/null || true)"

echo
echo "nvidia.ko version : $MOD_VERSION"
echo "nvidia.ko vermagic: $VERMAGIC"
echo "nvidia.ko license : $MOD_LICENSE"

[[ "$MOD_VERSION" == "$NVIDIA_VERSION" ]] \
    || die "Module version '$MOD_VERSION' != expected '$NVIDIA_VERSION'"

[[ "$VERMAGIC" == "$KERNEL_EXPECTED"* ]] \
    || die "Module vermagic '$VERMAGIC' does not target '$KERNEL_EXPECTED'"

echo "nvidia.raw verification PASSED."

banner "7/10 Extract official update + inject verified nvidia.raw"

sudo rm -rf "$OUTER" "$ROOTFS_TREE"

sudo unsquashfs -d "$OUTER" "$OFFICIAL_UPDATE" >/dev/null

ROOTFS="$OUTER/rootfs.squashfs"
MANIFEST="$OUTER/manifest.json"

[[ -f "$ROOTFS" ]] || die "rootfs.squashfs missing from official update"
[[ -f "$MANIFEST" ]] || die "manifest.json missing from official update"

python3 - "$MANIFEST" "$VERSION" "$KERNEL_EXPECTED" <<'PY'
import json
import sys

path, version, kernel = sys.argv[1:]
m = json.load(open(path))

print("Manifest version:", m.get("version"))
print("Manifest kernel :", m.get("kernel_version"))

if m.get("version") != version:
    raise SystemExit("ERROR: unexpected TrueNAS version")

if m.get("kernel_version") != kernel:
    raise SystemExit("ERROR: unexpected TrueNAS kernel")
PY

sudo unsquashfs -d "$ROOTFS_TREE" "$ROOTFS" >/dev/null

TARGET_RAW="$ROOTFS_TREE/usr/share/truenas/sysext-extensions/nvidia.raw"

[[ -f "$TARGET_RAW" ]] \
    || die "Stock nvidia.raw missing from official rootfs"

STOCK_RAW_SHA="$(sudo sha256sum "$TARGET_RAW" | awk '{print $1}')"
CUSTOM_RAW_SHA="$(sha256sum "$CUSTOM_RAW" | awk '{print $1}')"

echo "Stock  nvidia.raw: $STOCK_RAW_SHA"
echo "Custom nvidia.raw: $CUSTOM_RAW_SHA"

sudo cp -f "$CUSTOM_RAW" "$TARGET_RAW"
sudo chown root:root "$TARGET_RAW"
sudo chmod 0644 "$TARGET_RAW"

banner "8/10 Regenerate rootfs.mtree + rootfs.squashfs"

MTREE_BODY="$WORK/rootfs.mtree.body"

sudo bash -c '
set -Eeuo pipefail
cd "$1"

bsdtar \
  -f "$2" \
  -c \
  --format=mtree \
  --exclude "./boot/initrd.img*" \
  --exclude "./etc/aliases" \
  --exclude "./etc/audit/audit.rules" \
  --exclude "./etc/console-setup/cached_setup_*" \
  --exclude "./etc/default/keyboard" \
  --exclude "./etc/default/kdump-tools" \
  --exclude "./etc/default/zfs" \
  --exclude "./etc/fstab" \
  --exclude "./etc/group" \
  --exclude "./etc/machine-id" \
  --exclude "./etc/nsswitch.conf" \
  --exclude "./etc/passwd" \
  --exclude "./etc/shadow" \
  --exclude "./etc/sudoers" \
  --exclude "./etc/nfs.conf.d" \
  --exclude "./etc/nut" \
  --exclude "./etc/dhcp/dhclient.conf" \
  --exclude "./etc/libvirt" \
  --exclude "./etc/default/libvirt-guests" \
  --exclude "./etc/ssl/openssl.cnf" \
  --exclude "./etc/netdata/netdata.conf" \
  --exclude "./etc/pam.d/common-account" \
  --exclude "./etc/pam.d/common-auth" \
  --exclude "./etc/pam.d/common-password" \
  --exclude "./etc/pam.d/common-session" \
  --exclude "./etc/pam.d/common-session-noninteractive" \
  --exclude "./etc/pam.d/sshd" \
  --exclude "./etc/rc?\\.d" \
  --exclude "./etc/ssl/certs/ca-certificates.crt" \
  --exclude "./usr/lib/debug/*" \
  --exclude "./var/lib/ssl/fipsmodule.cnf" \
  --exclude "./var/cache" \
  --exclude "./var/trash" \
  --exclude "./var/spool/*" \
  --exclude "./var/log/*" \
  --exclude "./var/lib/dbus/machine-id" \
  --exclude "./var/lib/certmonger/cas/*" \
  --exclude "./var/lib/certmonger/local/*" \
  --exclude "./var/lib/smartmontools/*" \
  --options "!all,mode,uid,gid,type,link,size,sha256" \
  boot etc usr opt var conf/audit_rules
' _ "$ROOTFS_TREE" "$MTREE_BODY"

{
    printf '# %s\n' "$VERSION"
    sudo cat "$MTREE_BODY"
} | sudo tee "$ROOTFS_TREE/conf/rootfs.mtree" >/dev/null

MTREE_LINE="$(sudo grep 'usr/share/truenas/sysext-extensions/nvidia.raw' \
    "$ROOTFS_TREE/conf/rootfs.mtree" || true)"

echo "mtree nvidia.raw entry:"
echo "$MTREE_LINE"

[[ -n "$MTREE_LINE" ]] \
    || die "rootfs.mtree does not contain nvidia.raw"

echo "$MTREE_LINE" | grep -q "$CUSTOM_RAW_SHA" \
    || die "rootfs.mtree has wrong nvidia.raw SHA256"

sudo rm -f "$ROOTFS"

sudo mksquashfs "$ROOTFS_TREE" "$ROOTFS" -comp xz >/dev/null

banner "9/10 Recompute update manifest + build final .update"

sudo python3 - "$OUTER" "$ROOTFS_TREE" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

outer, root = sys.argv[1:]
manifest_path = os.path.join(outer, "manifest.json")

with open(manifest_path) as f:
    m = json.load(f)

for rel in list(m["checksums"]):
    p = os.path.join(outer, rel)

    if not os.path.isfile(p):
        raise SystemExit(f"ERROR: missing checksummed file: {rel}")

    with open(p, "rb") as f:
        m["checksums"][rel] = hashlib.file_digest(f, "sha1").hexdigest()

du_bytes = int(
    subprocess.run(
        ["du", "--block-size", "1", "-d", "0", "-x", root],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.split()[0]
)

m["size"] = int(du_bytes * 1.1)

with open(manifest_path, "w") as f:
    json.dump(m, f)

print("Version         :", m["version"])
print("Kernel          :", m["kernel_version"])
print("New rootfs SHA1 :", m["checksums"].get("rootfs.squashfs"))
print("Required bytes  :", m["size"])
PY

sudo python3 - "$OUTER" <<'PY'
import hashlib
import json
import os
import sys

outer = sys.argv[1]
m = json.load(open(os.path.join(outer, "manifest.json")))

for rel, expected in m["checksums"].items():
    p = os.path.join(outer, rel)

    with open(p, "rb") as f:
        h1 = hashlib.file_digest(f, "sha1").hexdigest()

    if h1 == expected:
        continue

    with open(p, "rb") as f:
        h2 = hashlib.file_digest(f, "sha256").hexdigest()

    if h2 != expected:
        raise SystemExit(f"ERROR: checksum mismatch: {rel}")

print("All internal update checksums: OK")
PY

rm -f "$CUSTOM_UPDATE" "$CUSTOM_UPDATE.sha256"

sudo mksquashfs "$OUTER" "$CUSTOM_UPDATE" -noD >/dev/null

sudo chown "$(id -u):$(id -g)" "$CUSTOM_UPDATE"

( cd "$(dirname "$CUSTOM_UPDATE")" && sha256sum "$(basename "$CUSTOM_UPDATE")" ) \
    > "$CUSTOM_UPDATE.sha256"

banner "10/10 End-to-end verify final custom update"

FINAL_OUTER="$VERIFY/final-outer"
FINAL_ROOT="$VERIFY/final-root"
FINAL_RAW_TREE="$VERIFY/final-raw"

sudo rm -rf "$FINAL_OUTER" "$FINAL_ROOT" "$FINAL_RAW_TREE"

sudo unsquashfs -d "$FINAL_OUTER" "$CUSTOM_UPDATE" >/dev/null

sudo python3 - "$FINAL_OUTER" "$VERSION" "$KERNEL_EXPECTED" <<'PY'
import hashlib
import json
import os
import sys

outer, version, kernel = sys.argv[1:]

m = json.load(open(os.path.join(outer, "manifest.json")))

if m["version"] != version:
    raise SystemExit("ERROR: final manifest version mismatch")

if m["kernel_version"] != kernel:
    raise SystemExit("ERROR: final manifest kernel mismatch")

for rel, expected in m["checksums"].items():
    p = os.path.join(outer, rel)

    with open(p, "rb") as f:
        h1 = hashlib.file_digest(f, "sha1").hexdigest()

    if h1 == expected:
        continue

    with open(p, "rb") as f:
        h2 = hashlib.file_digest(f, "sha256").hexdigest()

    if h2 != expected:
        raise SystemExit(f"ERROR: final checksum mismatch: {rel}")

print("Final update manifest/checksums: OK")
PY

sudo unsquashfs -d "$FINAL_ROOT" "$FINAL_OUTER/rootfs.squashfs" \
    usr/share/truenas/sysext-extensions/nvidia.raw \
    conf/rootfs.mtree >/dev/null

EMBEDDED_RAW="$FINAL_ROOT/usr/share/truenas/sysext-extensions/nvidia.raw"
EMBEDDED_SHA="$(sudo sha256sum "$EMBEDDED_RAW" | awk '{print $1}')"

echo "Built    nvidia.raw: $CUSTOM_RAW_SHA"
echo "Embedded nvidia.raw: $EMBEDDED_SHA"

[[ "$CUSTOM_RAW_SHA" == "$EMBEDDED_SHA" ]] \
    || die "Final update contains different nvidia.raw"

mkdir -p "$FINAL_RAW_TREE"

sudo unsquashfs -d "$FINAL_RAW_TREE" "$EMBEDDED_RAW" >/dev/null

FINAL_KO="$(find "$FINAL_RAW_TREE" -type f -name nvidia.ko -print -quit)"

[[ -n "$FINAL_KO" ]] \
    || die "Final embedded nvidia.raw has no nvidia.ko"

FINAL_VERMAGIC="$(modinfo -F vermagic "$FINAL_KO" 2>/dev/null || true)"
FINAL_VERSION="$(modinfo -F version "$FINAL_KO" 2>/dev/null || true)"

echo "Final module version : $FINAL_VERSION"
echo "Final module vermagic: $FINAL_VERMAGIC"

[[ "$FINAL_VERSION" == "$NVIDIA_VERSION" ]] \
    || die "Final embedded NVIDIA version wrong"

[[ "$FINAL_VERMAGIC" == "$KERNEL_EXPECTED"* ]] \
    || die "Final embedded NVIDIA kernel target wrong"

banner "SUCCESS"

ls -lh \
    "$CUSTOM_RAW" \
    "$OUT/nvidia.raw.sha256" \
    "$CUSTOM_UPDATE" \
    "$CUSTOM_UPDATE.sha256"

echo
echo "Custom update:"
echo "  $CUSTOM_UPDATE"
echo
echo "SHA256:"
cat "$CUSTOM_UPDATE.sha256"
echo
echo "Internal TrueNAS version remains ${VERSION}."
