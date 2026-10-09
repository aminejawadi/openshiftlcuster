# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# One-command lab: run from an *Administrator* PowerShell in this folder:
#
#   vagrant up                              # VirtualBox (default)
#   vagrant up --provider=vmware_desktop    # VMware Workstation Pro
#   vagrant destroy                         # removes the OKD VM, its hosts entries, then the helper
#
# Each run: helper VM -> Ansible inside it -> OKD VM on Windows -> wait for install.
#
# Needs Vagrant 2.4.9+ and one of:
#   - VirtualBox 7.x (nothing else to install)
#   - VMware Workstation Pro + the Vagrant VMware Utility +
#       vagrant plugin install vagrant-vmware-desktop
#
# Settings live in inventory/group_vars/all.yml (shared with manual runs).
# The hypervisor is detected inside the helper, so the playbooks need no switch.
# Environment overrides:
#   OKD_HELPER_BOX=bento/almalinux-9   use another EL9 box
#   OKD_AUTO_WAIT=0                    don't block "vagrant up" until the cluster is ready

HELPER_BOX  = ENV.fetch("OKD_HELPER_BOX", "bento/rockylinux-9")
AUTO_WAIT   = ENV.fetch("OKD_AUTO_WAIT", "1") != "0"
VBOX_SUBNET = "192.168.56"                   # must match virtualbox_subnet in all.yml
GUEST_WORK  = "/home/vagrant/okd"            # installer files stay on the VM's own disk
HOST_SCRIPT = File.join(__dir__, "scripts", "okd-vm.ps1")
PS          = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"#{HOST_SCRIPT}\""

# Shared by every Ansible run inside the helper.
ANSIBLE_EXTRA_VARS = {
  "bin_dir"           => "#{GUEST_WORK}/bin",
  "install_dir"       => "#{GUEST_WORK}/install",
  "virtualbox_subnet" => VBOX_SUBNET,
}

def ansible_cli(playbook)
  extra = ANSIBLE_EXTRA_VARS.map { |k, v| "-e '#{k}=#{v}'" }.join(" ")
  "cd /vagrant && ANSIBLE_CONFIG=/vagrant/ansible.cfg ansible-playbook #{playbook} #{extra}"
end

Vagrant.configure("2") do |config|
  config.vm.define "okd-helper", primary: true do |helper|
    helper.vm.box      = HELPER_BOX
    helper.vm.hostname = "okd-helper"
    helper.vm.synced_folder ".", "/vagrant"

    # Listed first, so it is the default provider.
    # Adapter 1: NAT (internet). Adapter 2: host-only lab network shared with
    # the OKD VM and your PC; the helper routes the OKD VM out through adapter 1.
    helper.vm.provider "virtualbox" do |vb, override|
      override.vm.network "private_network", ip: "#{VBOX_SUBNET}.10"
      vb.name   = "okd-helper"
      vb.memory = 4096
      vb.cpus   = 2
      vb.gui    = false
    end

    # Single NIC on VMware's NAT network (VMnet8), shared with the OKD VM;
    # the bootstrap script adds the fixed <subnet>.10 address.
    helper.vm.provider "vmware_desktop" do |v|
      v.gui                  = false
      v.vmx["displayName"]   = "okd-helper"
      v.vmx["memsize"]       = "4096"
      v.vmx["numvcpus"]      = "2"
    end

    # 1. Ansible (+ the fixed helper IP on VMware)
    helper.vm.provision "bootstrap", type: "shell", path: "scripts/helper-bootstrap.sh"

    # 2. Packages, DNS, routing (VirtualBox), web server, OKD installer, agent ISO,
    #    and the Windows VM script for the detected hypervisor
    helper.vm.provision "okd", type: "ansible_local" do |a|
      a.install           = false                 # done by the bootstrap script
      a.provisioning_path = "/vagrant"
      a.config_file       = "/vagrant/ansible.cfg" # shared folder is world-writable, so pass it explicitly
      a.inventory_path    = "inventory/hosts.yml"
      a.limit             = "localhost"
      a.playbook          = "playbooks/site.yml"
      a.extra_vars        = ANSIBLE_EXTRA_VARS
    end

    # Manual rerun: vagrant provision --provision-with wait
    helper.vm.provision "wait", type: "ansible_local", run: "never" do |a|
      a.install           = false
      a.provisioning_path = "/vagrant"
      a.config_file       = "/vagrant/ansible.cfg"
      a.inventory_path    = "inventory/hosts.yml"
      a.limit             = "localhost"
      a.playbook          = "playbooks/03-wait-for-install.yml"
      a.extra_vars        = ANSIBLE_EXTRA_VARS
    end

    # 3. On Windows: create (or start) the OKD VM from the generated script
    helper.trigger.after :up do |t|
      t.name = "Create or start the OKD VM"
      t.run  = { inline: PS }
    end

    # 4. Back in the helper: follow the install to the end (45-75 minutes)
    if AUTO_WAIT
      helper.trigger.after :up do |t|
        t.name       = "Wait for the OKD installation to finish"
        t.run_remote = { inline: ansible_cli("playbooks/03-wait-for-install.yml"), privileged: false }
      end
    end

    # Remove the OKD VM and its hosts entries before the helper goes away
    helper.trigger.before :destroy do |t|
      t.name     = "Delete the OKD VM"
      t.run      = { inline: "#{PS} -Destroy" }
      t.on_error = :continue
    end
  end
end
