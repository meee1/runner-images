# Building the Ubuntu 26.04 runner image on Proxmox VE

Builds the same image the Azure pipeline builds, but with the `proxmox-clone`
Packer builder, producing a Proxmox VM template you clone runners from.

Everything in `images/ubuntu/scripts` is reused unchanged. Only the Packer source
differs (`templates/source.proxmox.pkr.hcl`) plus three `only = [...]` guards in
`templates/build.ubuntu-26_04.pkr.hcl`.

## 0. Requirements

| Where | What |
|---|---|
| Proxmox host | PVE 8.0+, ~120 GB free on the target storage, nested virt (`kvm_intel nested=1` / `kvm_amd nested=1`) if you want Docker-in-KVM workloads |
| Build VM | 8 vCPU, 16 GB RAM, 100 GB disk, internet access |
| Your workstation | `packer` 1.9+, an SSH keypair, network access to the PVE API |

Build takes **2–4 hours** and downloads tens of GB. The finished template is
~60–70 GB used.

## 1. Proxmox API token

In the PVE UI: *Datacenter → Permissions → API Tokens → Add*, user `root@pam`,
token ID `packer`, **uncheck** "Privilege Separation". Copy the secret — it is
shown once.

A non-root user works too, but needs `VM.Allocate`, `VM.Clone`, `VM.Config.*`,
`VM.Monitor`, `VM.Audit`, `VM.PowerMgmt`, `Datastore.AllocateSpace`,
`Datastore.Audit`, `SDN.Use` on `/`.

## 2. Base cloud-init template (once)

Run on the Proxmox host. `9026` is the template VMID, change it if taken.

```bash
apt-get install -y libguestfs-tools

cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img

# qemu-guest-agent is how Packer learns the VM's IP address - without it the build
# never connects. Install it into the image before importing.
virt-customize -a ubuntu-26.04-server-cloudimg-amd64.img \
  --install qemu-guest-agent \
  --run-command 'systemctl enable qemu-guest-agent' \
  --truncate /etc/machine-id

qm create 9026 --name ubuntu-2604-cloudinit --ostype l26 --machine q35 \
  --cpu host --cores 4 --memory 4096 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --agent enabled=1 \
  --serial0 socket --vga serial0

qm set 9026 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img,discard=on,ssd=1
qm disk resize 9026 scsi0 100G
qm set 9026 --ide2 local-lvm:cloudinit --boot order=scsi0

# Build user. The Packer Proxmox plugin does not inject SSH keys into a clone,
# so the base template must already carry them.
qm set 9026 --ciuser packer --sshkeys /root/packer.pub --ipconfig0 ip=dhcp

qm template 9026
```

Put your **public** key at `/root/packer.pub` on the PVE host first
(`scp ~/.ssh/packer.pub root@pve:/root/`). Cloud-init gives `packer` passwordless
sudo by default, which the build needs.

> Using a storage other than `local-lvm`? Substitute it in both `qm set` lines
> and in `proxmox_storage_pool` below.

## 3. Variables

```bash
cd images/ubuntu/templates
cat > proxmox.pkrvars.hcl <<'EOF'
proxmox_url          = "https://pve.example.com:8006/api2/json"
proxmox_username     = "root@pam!packer"
proxmox_token        = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_node         = "pve"
proxmox_clone_vm     = "ubuntu-2604-cloudinit"
proxmox_storage_pool = "local-lvm"
proxmox_bridge       = "vmbr0"
ssh_private_key_file = "/home/you/.ssh/packer"

image_os      = "ubuntu26"
image_version = "26.04.1"
EOF
```

`*.pkrvars.hcl` is gitignored. `PROXMOX_URL` / `PROXMOX_USERNAME` /
`PROXMOX_TOKEN` / `PROXMOX_NODE` env vars work instead if you prefer.

## 4. Build

```bash
cd images/ubuntu/templates
packer init .
packer validate -only='ubuntu-26_04.proxmox-clone.image' -var-file=proxmox.pkrvars.hcl .
packer build  -only='ubuntu-26_04.proxmox-clone.image' -var-file=proxmox.pkrvars.hcl .
```

Result: a template named `gha-runner-ubuntu-2604-<image_version>` on the node.

Useful during a long build:

- `PACKER_LOG=1 packer build ... 2>&1 | tee build.log`
- `-on-error=ask` leaves the VM up so you can SSH in and look at a failure.
- The build reboots the VM once, then pauses 5 minutes. That is expected.

The build downloads `software-report.md` over the top of
`images/ubuntu/Ubuntu2604-Readme.md`, and writes `images/ubuntu/software-report.json`.
Both are build artifacts describing what actually landed in *your* image — keep
them, or `git checkout` them if you want a clean tree.

## 5. Deploying a runner

```bash
qm clone <template-vmid> 200 --name runner-01 --full
qm set 200 --ciuser runner --sshkeys /root/runner.pub --ipconfig0 ip=dhcp \
  --cores 8 --memory 16384
qm start 200
```

Then install the Actions runner the usual way:

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o runner.tar.gz -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64.tar.gz
tar xzf runner.tar.gz
./config.sh --url https://github.com/<org> --token <registration-token> --labels self-hosted,Linux,X64,ubuntu-26.04
sudo ./svc.sh install && sudo ./svc.sh start
```

Jobs expect to run as a user with passwordless sudo and membership in `docker`.

## What differs from the Azure build

| | Azure | Proxmox |
|---|---|---|
| Source | marketplace `canonical:ubuntu-26_04-lts:server` | clone of a local cloud-init template |
| Deprovision | `waagent -deprovision+user` | `cloud-init clean` + SSH host keys and authorized_keys removed |
| `/etc/waagent.conf` | present | created empty, because `configure-environment.sh` seds it unconditionally |
| Resource disk `/mnt` | Azure ephemeral disk | absent; the cloud-init mount entry is `nofail` so it is harmless |
| Output | Shared Image Gallery version | PVE VM template |

Everything else — toolcache, sysctls, the ext4 `rootflags` grub tweak, the
software report and the test suite — runs identically.

## Troubleshooting

**Packer hangs at "Waiting for SSH"** — the guest agent isn't reporting an IP.
Check `qm agent <vmid> network-get-interfaces` on the host; if it errors,
`qemu-guest-agent` is missing from the base image (step 2) or `--agent enabled=1`
wasn't set. As a fallback, give the clone a static IP and add
`ssh_host = "<ip>"` to the source block.

**Permission denied (publickey)** — the base template's `--sshkeys` doesn't match
`ssh_private_key_file`, or `--ciuser` isn't `packer`. Both are baked into the
*template*, so `qm set` then `qm template` again (or re-run step 2's last three
commands against the template).

**Out of disk mid-build** — the 100 G root is the floor, not a suggestion.
`qm disk resize 9026 scsi0 120G` on the base template and rebuild.

**`clone` task times out** — a full clone of 100 G on spinning disks exceeds the
15 minute `task_timeout`; raise it in `source.proxmox.pkr.hcl`.
