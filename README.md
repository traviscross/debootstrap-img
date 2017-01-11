# debootstrap-img

This program builds a minimal Debian virtual machine image using
[debootstrap](https://wiki.debian.org/Debootstrap).  The resulting
virtual machine image can be in any
[format](http://wiki.qemu.org/download/qemu-doc.html#qemu_005fimg_005finvocation)
supported by [QEMU](http://www.qemu.org).

## Usage

Run with:

    $ ./debootstrap-img.sh [-h] [-c]
        [-d <workdir>]
        [-e <fs_type>]
        [-f <output_fmt>]
        [-i <deb_mirror>]
        [-l <output_size>]
        [-m <mode>]
        [-n <nbd_dev>]
        [-o <output_img>]
        [-s <deb_suite>]

`-h` Show inline usage information.

`-c` Compress the resulting image.  This is only supported for `qcow`
and `qcow2` formats.

`-d <workdir>` Select the path of the working directory mount point.
This directory will be created if it does not exist.  We then mount a
`tmpfs` on this mount point.  By default we use a `tmp` directory in
the current working directory.

`-e <fs_type>` Select the type of the root filesystem.  The default is
`btrfs` with `zlib` compression.  We also support `xfs`, `ext2`,
`ext3`, and `ext4`.

`-f <output_fmt>` Select the image format of the resulting virtual
machine image.  This can be any format supported by `qemu-img(1)`.
You can get a list of these with `qemu-img --help | grep '^Supported
formats'`.  Some examples include `raw`, `qcow2`, `vdi`.  The default
is `qcow2`, the native image format of QEMU.

`-i <deb_mirror>` Select the debian mirror used for the `debootstrap`
and other `apt` operations.  This mirror is overwritten with an
upstream mirror during finalization and release.

`-l <output_size>` Select the block size of the resulting virtual
machine image.  Sparse image types (e.g. `qcow2`, `vdi`, etc.) will
use less space than this on disk until they are full.  By default this
is 8G.

`-m <mode>` Select the operation to perform.  By default we perform
`release`.  The available operations are:

- `clean` - Unmount and remove working directory and remove output
  files
- `init` - Create and mount working directories
- `bootstrap` - Perform the `debootstrap` operation
- `build` - Build the base rootfs
- `mount-img` - Mount the image under `<workdir>/img` for manual
  operations
- `umount-img` - Unmount the image after manual operations
- `install-rootfs` - Install the rootfs to the VMI
- `install-boot` - Install a kernel and make the image bootable
- `finalize` - Cleanup image prior to release
- `release` - Build and finalize the image and clean out working files

`-n <nbd_dev>` Select the NBD block device to use for `qemu-nbd`.  By
default we use `/dev/nbd0`.

`-o <output_img>` Select the filename for the resulting virtual
machine image.  The default is to make the image in the current
directory with a filename of `vmi-debian-<deb_suite>.<output_fmt>`.

`-s <deb_suite>` Select the debian suite to bootstrap.  The default is
Debian jessie.  We currently only support building Debian jessie
images.

## Installation

This program is a shell script that is designed to run under a minimal
shell such as `dash`.

### Dependencies

To use this program, you first need to install:

- `debootstrap`
- `qemu-utils`
- `btrfs-progs` / `btrfs-tools`
- `parted`
- `systemd-container` (`systemd-nspawn`)

On Debian stretch/sid:

    apt-get install debootstrap qemu-utils \
      btrfs-progs parted systemd-container

On Debian jessie:

    apt-get install debootstrap qemu-utils \
      btrfs-tools parted dbus

## License

This project is licensed under the
[MIT/Expat](https://opensource.org/licenses/MIT) license as found in
the [LICENSE](./LICENSE) file.
