# ZoRRA: ZFS on Root - Remote Access
Script for installing and managing Ubuntu with ZFS on Root, using rEFInd and ZFSBootMenu with remote access to simplify the booting process.

### Usage

```bash
gsettings set org.gnome.desktop.media-handling automount false
sudo -i 
```

```bash
cd
apt update && sudo apt install -y git nano
git clone https://github.com/maanloper/zfs_on_root_zbm_remote_access.git
cd zfs_on_root_zbm_remote_access
nano zfs_on_root_zbm.sh
```

as root, execute the script:
```bash
./zfs_on_root_zbm.sh
```

### Inspired by:
[dzacca/zfs_on_root](https://github.com/dzacca/zfs_on_root)

[Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu)
