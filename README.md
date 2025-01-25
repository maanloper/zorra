# ZoRRA: ZFS on Root - Remote Access
Script for installing and managing Ubuntu with ZFS on Root, using rEFInd and ZFSBootMenu with remote access to simplify the booting process.

### Usage
```bash
sudo apt update && sudo apt install -y git nano
sudo git -C /usr/local clone https://github.com/maanloper/zorra.git
sudo ln -s /usr/local/zorra/zorra /usr/local/bin/zorra
```

Execute the script:
```bash
sudo zorra <command> [options]
```

To update the script:
```bash
sudo git -C /usr/local/zorra pull
```

### Inspired by:
[ZFSBootMenu](https://zfsbootmenu.org/)

[dzacca/zfs_on_root](https://github.com/dzacca/zfs_on_root)

[Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu)