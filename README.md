# QEMU/KVM cookbook

### Getting the ISO for the VM
You may download Debian ISO with `wget -O debian-13.7.0-amd64-netinst.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso`
You may download Arch ISO with `wget -O archlinux-x86_64.iso https://mirror.rackspace.com/archlinux/iso/2026.11.01/archlinux-x86_64.iso` and `wget -O archlinux-x86_64.iso.sig https://mirror.rackspace.com/archlinux/iso/2026.11.01/archlinux-x86_64.iso.sig`
Don't forget to verify the signature:
`gpg --keyserver-options auto-key-retrieve --verify <filename.iso.sig> <filename.iso>`
Or if the keyserver cannot be auto-resolved:
`gpg --keyserver hkps://keyring.debian.org:443 --recv-keys 10460DAD76165AD81FBC0CE9988021A964E6EA7D && gpg --keyserver hkps://keyring.debian.org:443 --recv-keys DF9B9C49EAA9298432589D76DA87E80D6294BE9B && gpg --keyserver hkps://keyring.debian.org:443 --recv-keys F41D30342F3546695F65C66942468F4009EA8AC3 && wget -O debian_sha512sums https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS && wget -O debian_sha512sum_sig https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS.sign && gpg --verify debian_sha512sum_sig debian_sha512sums`
And then compare the checksum in the file with `sha512sum debian-13.7.0-amd64-netinst.iso`

### Managing the VM via the monitor (i.e. via the socket file):
- Firstly install `socat`
`sudo apt install socat`
- Then connect to the VM via the socket:
`socat - UNIX-CONNECT:<running_vm_socket_filename>.sock`

savevm <tag>          create checkpoint
loadvm <tag>          rewind to it
delvm <tag>           delete it
info snapshots        list them

- To quit the monitor, you may send the shutdown signal:
`system_powerdown`
- or force the power off:
`quit`


##### Managing snapshots from inside the VM monitor:
* savevm before-breakfast       ← freezes the VM for a few seconds, writes checkpoint
* info snapshots                ← lists all the available snapshots
* loadvm before-breakfast       ← rewinds RAM + disk to that moment

### Managing snapshots from outside of the VM:
* qemu-img snapshot -l <vm_filename>.qcow2         # list
* qemu-img snapshot -c clean <vm_filename>.qcow2   # create
* qemu-img snapshot -a clean <vm_filename>.qcow2   # apply (rewind)
* qemu-img snapshot -d clean <vm_filename>.qcow2   # delete
* qemu-img info <vm_filename>.qcow2                # shows the backing chain
* qemu-img check <vm_filename>.qcow2               # validates

### How to create an overlay (a copy-on-write) copy
* Shut VM2 down (its identity is already deduped — it's your best template source)
* Create the immutable template from it:
`qemu-img convert -O qcow2 <vm_orig_filename>.qcow2 <vm_copy_filename>.qcow2`
* enforce immutability at the filesystem level
`chmod a-w <vm_copy_filename>.qcow2`
* Spawn unlimited disposable VMs, each in ~0.2 seconds:
`qemu-img create -f qcow2 -b <vm_copy_filename>.qcow2 -F qcow2 lab-3.qcow2`
* boot lab-3.qcow2 with your usual command line; check disk usage — tiny.

Inspection and merging tools: qemu-img info <vm_filename>.qcow2 shows the backing chain; qemu-img check validates it. If you decide a day's work in an overlay deserves promotion, qemu-img commit lab-3.qcow2 folds the changes back into the base (the only legal way to write to a base).

qemu-img convert -c -O qcow2 vm.qcow2 backup-$(date +%F).qcow2 — create a compressed backup

### libvirt cheatsheet
- run:
```
virt-install \
  --name lv-lab-1 \
  --memory 2048 --vcpus 2 \
  --osinfo debian12 \
  --disk path=/home/vaclav/VM/lv-lab-1.qcow2,size=20,format=qcow2 \
  --cdrom /path/to/debian-13.7.0-amd64-netinst.iso \
  --network network:default \
  --graphics spice
```

#### virsh commands:
```
virsh list --all            # running / shut off / paused — no more pgrep
virsh dominfo lv-lab-1      # everything: state, autostart, memory, UUID
virsh shutdown lv-lab-1     # ACPI powerdown (install qemu-guest-agent in the guest
                            #  and it becomes 100% reliable)
virsh start lv-lab-1
virsh destroy lv-lab-1      # pull the plug (the honest name for kill)
virsh autostart lv-lab-1    # boot with the host
virsh dumpxml lv-lab-1      # the entire VM as XML — your start script, formalized
virsh edit lv-lab-1         # change it (memory, CPUs, devices)
```

##### Allow an unprivileged VM process to access host's USB printer
- Get to know your printer's vendorid:productid with `lsusb`
- Add the udev rule:
  ```
  sudo tee /etc/udev/rules.d/99-brother-dcp7030.rules >/dev/null <<EOF
SUBSYSTEM=="usb", ATTRS{idVendor}=="0419", ATTRS{idProduct}=="0100", TAG+="uaccess"
EOF
sudo udevadm control --reload && sudo udevadm trigger
```
