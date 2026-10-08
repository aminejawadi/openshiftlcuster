# OKD single-node cluster on VMware Workstation (Windows)

Ansible playbooks that install a single-node **OKD** cluster (the free
community distribution of OpenShift) on your own PC, with the
**agent-based installer**. It is sized for a 64 GB machine with a 6-core /
12-thread CPU such as the Ryzen 5 7500F.

## How it works

```
 Windows PC (VMware Workstation Pro)
 ┌───────────────────────────── VMnet8 (NAT) x.x.x.0/24 ─────────────────┐
 │                                                                        │
 │  helper VM  .10   Rocky/Alma 9, 2 vCPU, 4 GB                           │
 │    - runs Ansible and openshift-install                                │
 │    - dnsmasq: api / api-int / *.apps  ->  .50                          │
 │    - httpd :8080 serves the ISO and the Windows script                 │
 │                                                                        │
 │  okd-sno    .50   8 vCPU, 32 GB, 150 GB   (created by the script)      │
 │    - boots the agent ISO, installs itself, reboots, becomes the cluster│
 │                                                                        │
 │  Windows    .1    browser -> console (names come from the hosts file)  │
 └────────────────────────────────────────────────────────────────────────┘
```

On a single node the API and the router both run on the node, so there is
no load balancer and no bootstrap VM. The agent ISO carries the whole
installation; the node installs itself.

**Memory budget:** OKD VM 32 GB + helper 4 GB = 36 GB, leaving about
28 GB for Windows. 16 GB is the minimum for the OKD VM, but 32 GB leaves
room to actually deploy apps.

## Where Ansible runs

The **helper VM is your Ansible machine**. There is no separate control VM:
the helper is already small (2 vCPU, 4 GB), and it has to exist anyway for
DNS and to serve the ISO.

Ansible itself can't run on Windows: Windows isn't supported as a control
node. WSL2 would work, but enabling it turns on Hyper-V, and VMware
Workstation then runs on top of Hyper-V and gets noticeably slower. A Linux
VM avoids both problems.

There are two ways to get the helper.

## Option A (recommended): one command with Vagrant

Vagrant creates the helper, installs Ansible inside it, runs the playbooks
there, then calls a PowerShell script on Windows to create the OKD VM.
Nothing to install on Windows except Vagrant.

### One-time setup on Windows

1. VMware Workstation Pro (free for personal use).
2. In Workstation: **Edit → Virtual Network Editor**, check that **VMnet8**
   is NAT with DHCP on and the subnet is a /24 (the default).
3. Install [Vagrant](https://developer.hashicorp.com/vagrant/install) and the
   [Vagrant VMware Utility](https://developer.hashicorp.com/vagrant/install/vmware),
   then:

   ```powershell
   vagrant plugin install vagrant-vmware-desktop
   ```

### Run it

Open **PowerShell as Administrator** (needed to edit the hosts file) in
this folder:

```powershell
vagrant up
```

What happens:

| Step | Where | What |
|---|---|---|
| 1 | Windows | Vagrant creates `okd-helper` (Rocky Linux 9) on VMnet8 |
| 2 | helper | Installs Ansible and adds the fixed address `<subnet>.10` |
| 3 | helper | Runs `playbooks/site.yml`: DNS, web server, OKD installer, agent ISO |
| 4 | Windows | Runs `scripts/okd-vm.ps1`: downloads the ISO, creates and starts `okd-sno`, adds hosts entries |
| 5 | helper | Runs `03-wait-for-install.yml` until the cluster is ready (45–75 min) and prints the console URL and kubeadmin password |

The subnet is detected automatically, so you don't edit anything for a
default setup. Settings are in `inventory/group_vars/all.yml`.

Useful commands:

```powershell
vagrant ssh                                   # shell on the helper (oc is in ~/okd/bin)
vagrant provision --provision-with wait       # follow the install again
vagrant halt                                  # stop the helper (the OKD VM keeps running)
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
   30 GB disk, network **NAT**.
2. Give it the static IP `<VMnet8 subnet>.10`, gateway and DNS `<subnet>.2`:

   ```bash
   sudo nmcli con mod ens160 ipv4.method manual \
     ipv4.addresses 192.168.150.10/24 ipv4.gateway 192.168.150.2 ipv4.dns 192.168.150.2
   sudo nmcli con up ens160
   ```

3. Copy this project to it, then:

   ```bash
   sudo dnf install -y ansible-core
   cd okd-sno-vmware
   ansible-galaxy collection install -r requirements.yml -p collections
   ansible-playbook playbooks/site.yml -K
   ```

4. On Windows, in **PowerShell as Administrator**, from this folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\okd-vm.ps1
   ```

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

If Windows has Hyper-V, WSL2 or "Memory integrity" turned on, Workstation
still works but runs slower. Turning those off gives the VMs better
performance.

## Day-to-day

- **Shutting down:** shut down the OKD VM from the console or with
  `oc debug node/sno -- chroot /host shutdown -h 1`. Start it again in
  Workstation; it takes 5–10 minutes to become ready.
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
  The Ryzen 5 7500F has it, and Workstation passes it through.
- **Version:** `okd_version` is pinned to `5.0.0-okd-scos.1`, the latest
  stable release on the OKD GitHub page as of October 2026. Change it to
  pick another release.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Script can't download the ISO | From Windows: `Test-NetConnection 192.168.150.10 -Port 8080`; on the helper: `sudo firewall-cmd --list-ports` |
| VM boots the ISO again after installing | Disconnect the CD in Workstation (VM → Settings → CD/DVD) and restart the VM |
| Install stalls | On the helper: `ssh core@192.168.150.50` then `journalctl -u agent -f` (before reboot) or `sudo crictl ps` (after) |
| Names don't resolve on the node | On the helper: `dig @192.168.150.10 api-int.okd.lab.internal` |
| Browser can't reach the console | On Windows: `ping api.okd.lab.internal` should answer from `.50`; run `.okd\create-okd-vm.ps1 -UpdateHosts` as Administrator |

## Layout

```
.
├── Vagrantfile                   # Option A: one-command lab
├── scripts/
│   ├── helper-bootstrap.sh       # runs in the helper: Ansible + fixed IP
│   └── okd-vm.ps1                # runs on Windows: create/destroy the OKD VM
├── ansible.cfg
├── requirements.yml
├── inventory/
│   ├── hosts.yml                 # localhost (the helper)
│   └── group_vars/all.yml        # all settings
├── playbooks/
│   ├── site.yml                  # 00 + 01 + 02
│   ├── 00-prereqs.yml            # packages, SSH key, OKD installer
│   ├── 01-helper-services.yml    # dnsmasq, httpd, firewalld
│   ├── 02-agent-iso.yml          # install-config, agent-config, ISO, Windows script
│   ├── 03-wait-for-install.yml   # follow the install, print credentials
│   └── reset.yml
└── roles/
    ├── prereqs
    ├── helper_services
    └── agent_iso                 # includes create-okd-vm.ps1 template
```
