```
repo init -u https://github.com/flashbots/flashbox.git -b yocto-build -m build/flashbox.xml
repo sync
source .repo/manifests/build/setup
MACHINE=tdx-qemu bitbake core-image-minimal
```
