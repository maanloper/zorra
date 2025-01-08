# ZoRRA: ZFS on Root - Remote Access
Fork of [dzacca/zfs_on_root](https://github.com/dzacca/zfs_on_root) with ZBM remote access, pure efibootmgr, single dataset for whole system (easy total rollback and cloning into different release)

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
