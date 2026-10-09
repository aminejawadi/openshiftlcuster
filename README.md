# OKD single-node cluster on VirtualBox or VMware (Windows)

Ansible playbooks that install a single-node **OKD** cluster (the free
community distribution of OpenShift) on your own PC, with the
**agent-based installer**. Works with **VirtualBox 7** or **VMware
Workstation Pro**. It is sized for a 64 GB machine with a 6-core /
12-thread CPU such as the Ryzen 5 7500F.

## How it works

On a single node the API and the router both run on the node, so there is
no load balancer and no bootstrap VM. The agent ISO carries the whole
installation; the node installs itself. A small **helper VM** provides DNS,
serves the ISO, and runs Ansible.

### VirtualBox

```
 Windows PC (VirtualBox)
 ┌──────────────────── host-only network 192.168.56.0/24 ────────────────┐
 │                                                                        │
 │  Windows    .1    browser -> console (names come from the hosts file)  │
 │                                                                        │
 │  helper VM  .10   Rocky Linux 9, 2 vCPU, 4 GB                          │
 │    - runs Ansible and openshift-install                                │
 │    - dnsmasq: api / api-int / *.apps  ->  .50                          │
 │    - httpd :8080 serves the ISO and the Windows script                 │
 │    - routes the OKD VM to the internet ───── NAT adapter ──▶ internet  │
 │                                                                        │
 │  okd-sno    .50   8 vCPU, 32 GB, 150 GB   gateway + DNS = helper       │
 └────────────────────────────────────────────────────────────────────────┘
```

A host-only network lets your PC reach the cluster directly, but it has no
internet access. So the helper has a second, NAT adapter and forwards the
OKD VM's traffic through it.

### VMware Workstation

```
 Windows PC (VMware Workstation Pro)
 ┌───────────────────────────── VMnet8 (NAT) x.x.x.0/24 ─────────────────┐
 │  Windows    .1    browser -> console                                   │
 │  VMware NAT .2    gateway + upstream DNS                               │
 │  helper VM  .10   Ansible, dnsmasq, httpd                              │
 │  okd-sno    .50   8 vCPU, 32 GB, 150 GB   gateway .2, DNS = helper     │
 └────────────────────────────────────────────────────────────────────────┘
```

VMware's NAT network already gives every VM internet access and lets your PC
reach them, so no routing is needed.

The playbooks **detect which hypervisor the helper runs on** and pick the
network layout and the matching Windows script automatically.

**Memory budget:** OKD VM 32 GB + helper 4 GB = 36 GB, leaving about
28 GB for Windows. 16 GB is the minimum for the OKD VM, but 32 GB leaves
room to actually deploy apps.

## Where Ansible runs

The **helper VM is your Ansible machine**. There is no separate control VM:
the helper is already small (2 vCPU, 4 GB), and it has to exist anyway for
DNS and to serve the ISO.

Ansible itself can't run on Windows: Windows isn't supported as a control
node. WSL2 would work, but enabling it turns on Hyper-V, which slows
VirtualBox and VMware down (see below). A Linux VM avoids both problems.

## Before you start: turn off Hyper-V

If Hyper-V is active on Windows, VirtualBox runs on top of it and becomes
very slow (a green turtle icon in the VM's status bar). An OKD install may
then time out. VMware is affected less, but still slows down.

Hyper-V is switched on by Hyper-V itself, WSL2, Windows Sandbox, and
**Memory integrity** (Windows Security → Device security → Core isolation).
To turn it off, run in an Administrator PowerShell, then reboot:

```powershell
bcdedit /set hypervisorlaunchtype off
```

and switch Memory integrity off. To undo it later:
`bcdedit /set hypervisorlaunchtype auto`.

## Option A (recommended): one command with Vagrant

Vagrant creates the helper, installs Ansible inside it, runs the playbooks
there, then calls a PowerShell script on Windows to create the OKD VM.

### One-time setup on Windows

Install [Vagrant](https://developer.hashicorp.com/vagrant/install) 2.4.9 or
newer, plus one hypervisor:

- **VirtualBox:** install [VirtualBox 7](https://www.virtualbox.org/wiki/Downloads).
  Nothing else is needed.
- **VMware:** install VMware Workstation Pro (free for personal use), the
  [Vagrant VMware Utility](https://developer.hashicorp.com/vagrant/install/vmware),
  then run `vagrant plugin install vagrant-vmware-desktop`. In Workstation,
  check that **VMnet8** is NAT with DHCP on and a /24 subnet (the default).

### Run it

Open **PowerShell as Administrator** (needed to edit the hosts file) in
this folder. Use PowerShell rather than Git Bash: Git Bash usually isn't
elevated, so the hosts file can't be updated.

```powershell
vagrant up                              # VirtualBox (the default)
vagrant up --provider=vmware_desktop    # VMware Workstation
```

What happens:

| Step | Where | What |
|---|---|---|
| 1 | Windows | Vagrant creates `okd-helper` (Rocky Linux 9). On VirtualBox it also creates the host-only network `192.168.56.0/24` |
| 2 | helper | Installs Ansible (on VMware, also adds the fixed address `<subnet>.10`) |
| 3 | helper | Runs `playbooks/site.yml`: DNS, routing (VirtualBox), web server, OKD installer, agent ISO |
| 4 | Windows | Runs `scripts/okd-vm.ps1`: downloads the ISO, creates and starts `okd-sno`, adds hosts entries |
| 5 | helper | Runs `03-wait-for-install.yml` until the cluster is ready (45–75 min) and prints the console URL and kubeadmin password |

You don't edit anything for a default setup. Settings are in
`inventory/group_vars/all.yml`.

Useful commands:

```powershell
vagrant ssh                                   # shell on the helper (oc is in ~/okd/bin)
vagrant provision --provision-with wait       # follow the install again
vagrant halt                                  # stop the helper (see "Day-to-day")
vagrant destroy                               # delete the OKD VM, hosts entries and helper
$env:OKD_AUTO_WAIT = "0"; vagrant up          # don't block on step 5
$env:OKD_HELPER_BOX = "bento/almalinux-9"     # use another box if Rocky is unavailable
```

On the helper, use the cluster with:

```bash
export KUBECONFIG=~/okd/install/auth/kubeconfig PATH=~/okd/bin:$PATH
oc get nodes
```

## Option B: create the helper by hand

1. Create a VM with Rocky Linux 9 or AlmaLinux 9 (minimal), 2 vCPU, 4 GB,
   30 GB disk.
2. Network:
   - **VirtualBox:** adapter 1 **NAT**, adapter 2 **Host-only** on the
     `192.168.56.0/24` network (VirtualBox: File → Tools → Network Manager).
     Give adapter 2 the static IP `192.168.56.10/24` with **no gateway**:

     ```bash
     sudo nmcli con mod "Wired connection 1" ipv4.method manual ipv4.addresses 192.168.56.10/24
     sudo nmcli con up "Wired connection 1"
     ```

     (`nmcli con show` lists the connection names; pick the one on the
     second adapter, usually `enp0s8`.)
   - **VMware:** one adapter on **NAT**, static IP `<VMnet8 subnet>.10`,
     gateway and DNS `<subnet>.2`:

     ```bash
     sudo nmcli con mod ens160 ipv4.method manual \
       ipv4.addresses 192.168.150.10/24 ipv4.gateway 192.168.150.2 ipv4.dns 192.168.150.2
     sudo nmcli con up ens160
     ```

3. Copy this project to it, then:

   ```bash
   sudo dnf install -y ansible-core
   cd openshiftlcuster
   ansible-galaxy collection install -r requirements.yml -p collections
   ansible-playbook playbooks/site.yml -K
   ```

4. On Windows, in **PowerShell as Administrator**, from this folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\okd-vm.ps1
   ```

   The script finds the helper on your VirtualBox or VMware network by
   itself. If it can't, add `-HelperIp 192.168.56.10` (or your VMware
   helper's address).

5. Back on the helper:

   ```bash
   ansible-playbook playbooks/03-wait-for-install.yml
   ```

At the end, open `https://console-openshift-console.apps.okd.lab.internal`
in your browser and accept the self-signed certificate warnings.

## Starting over

With Vagrant: `vagrant destroy` then `vagrant up`.

By hand:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\okd-vm.ps1 -Destroy   # Windows
```
```bash
ansible-playbook playbooks/reset.yml          # helper
ansible-playbook playbooks/site.yml -K
```

## Day-to-day

- **Keep the helper running whenever the cluster runs.** The cluster uses
  the helper for DNS, and on VirtualBox also as its route to the internet.
  Start the helper first (`vagrant up` just starts it again if it exists),
  then the OKD VM.
- **Shutting down:** shut down the OKD VM from the console or with
  `oc debug node/sno -- chroot /host shutdown -h 1`. Start it again in
  VirtualBox or Workstation; it takes 5–10 minutes to become ready.
- **Wait at least 24 hours after install before the first long shutdown.**
  The cluster rotates its initial certificates during the first day; if it
  is off when they expire, it may need manual CSR approval
  (`oc get csr`, `oc adm certificate approve ...`) when it comes back.
- **New routes:** the Windows hosts file has no wildcards. Add each new
  route's hostname to `windows_host_names` in `all.yml`, rerun
  `02-agent-iso.yml`, then run `.okd\create-okd-vm.ps1 -UpdateHosts`. Or point a
  local DNS tool at the helper's dnsmasq.
- **Storage:** a single node has no storage class by default. For a lab,
  install the LVM Storage operator (needs a second VM disk) or a hostpath
  provisioner.

## Things to know

- **The ISO expires.** Its certificates are valid for 24 hours. If you
  build it and boot the VM a day later, rebuild it with
  `ansible-playbook playbooks/02-agent-iso.yml -e regenerate_iso=true`.
- **CPU:** recent OKD releases need a CPU with x86-64-v3 (AVX2) support.
  The Ryzen 5 7500F has it, and both hypervisors pass it through when
  Hyper-V is off.
- **8 vCPUs on a 6-core CPU:** single-node OKD requires at least 8 vCPUs.
  VirtualBox may warn that this is more than your physical cores; that is
  expected and works, using the CPU's 12 threads.
- **Disk speed matters.** etcd is sensitive to slow disks. Keep the VM on an
  SSD.
- **Version:** `okd_version` is pinned to `5.0.0-okd-scos.1`, the latest
  stable release on the OKD GitHub page as of October 2026. Change it to
  pick another release.

## Troubleshooting

Addresses below are for VirtualBox (`192.168.56.x`); on VMware use your
VMnet8 subnet.

| Symptom | What to check |
|---|---|
| VirtualBox VM is very slow, green turtle icon | Hyper-V is active: see "Before you start" |
| `Bringing machine 'okd-helper' up with 'hyperv' provider` or "SSH authentication failed" | Vagrant used Hyper-V. Run `vagrant destroy -f`, delete the `.vagrant` folder, install VirtualBox, turn Hyper-V off, reboot, then `vagrant up --provider=virtualbox` |
| Script can't download the ISO | From Windows: `Test-NetConnection 192.168.56.10 -Port 8080`; on the helper: `sudo firewall-cmd --list-all-zones` |
| OKD VM has no internet (VirtualBox) | On the helper: `sysctl net.ipv4.ip_forward` should be 1, `sudo firewall-cmd --zone=public --query-masquerade` should say yes, `sudo firewall-cmd --info-policy=okd-lab-egress` should exist |
| VM boots the ISO again after installing | Remove the ISO from the VM's optical drive (VirtualBox: Settings → Storage; Workstation: Settings → CD/DVD) and restart the VM |
| Install stalls | On the helper: `ssh core@192.168.56.50` then `journalctl -u agent -f` (before reboot) or `sudo crictl ps` (after) |
| Names don't resolve on the node | On the helper: `dig @192.168.56.10 api-int.okd.lab.internal` |
| Browser can't reach the console | On Windows: `ping api.okd.lab.internal` should answer from `.50`; run `.okd\create-okd-vm.ps1 -UpdateHosts` as Administrator |

## Layout

```
.
├── Vagrantfile                   # Option A: one-command lab (VirtualBox or VMware)
├── scripts/
│   ├── helper-bootstrap.sh       # runs in the helper: Ansible (+ fixed IP on VMware)
│   └── okd-vm.ps1                # runs on Windows: finds the helper, creates/destroys the OKD VM
├── ansible.cfg
├── requirements.yml
├── inventory/
│   ├── hosts.yml                 # localhost (the helper)
│   └── group_vars/all.yml        # all settings, hypervisor detection
├── playbooks/
│   ├── site.yml                  # 00 + 01 + 02
│   ├── 00-prereqs.yml            # packages, SSH key, OKD installer
│   ├── 01-helper-services.yml    # dnsmasq, httpd, firewalld, routing (VirtualBox)
│   ├── 02-agent-iso.yml          # install-config, agent-config, ISO, Windows script
│   ├── 03-wait-for-install.yml   # follow the install, print credentials
│   └── reset.yml
└── roles/
    ├── prereqs
    ├── helper_services           # includes router.yml for VirtualBox
    └── agent_iso                 # create-okd-vm-virtualbox / -vmware templates
```
