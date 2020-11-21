provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_network" "k3os" {
  name      = "k3os-${var.cluster_name}"
  mode      = "nat"
  addresses = ["10.17.3.0/24"]

  dns {
    enabled = true
  }

  dhcp {
    enabled = true
  }
}

resource "libvirt_pool" "cluster" {
  name = "cluster"
  type = "dir"
  path = "${path.cwd}/pool"
}

resource "libvirt_volume" "kernel" {
  source = "https://github.com/rancher/k3os/releases/download/${var.k3os_version}/k3os-vmlinuz-amd64"
  name   = "kernel-${var.cluster_name}"
  pool   = libvirt_pool.cluster.name
  format = "raw"
}

resource "libvirt_volume" "initrd" {
  source = "https://github.com/rancher/k3os/releases/download/${var.k3os_version}/k3os-initrd-amd64"
  name   = "initrd-${var.cluster_name}"
  pool   = libvirt_pool.cluster.name
  format = "raw"
}

resource "libvirt_volume" "iso" {
  source = "https://github.com/rancher/k3os/releases/download/${var.k3os_version}/k3os-amd64.iso"
  name   = "k3os-amd64-${var.cluster_name}.iso"
  pool   = libvirt_pool.cluster.name
  format = "iso"
}

resource "libvirt_volume" "k3os_server" {
  name   = "k3os-server.raw"
  size   = "10737418240"
  format = "raw"
  pool   = libvirt_pool.cluster.name
}

resource "libvirt_domain" "k3os_server" {
  name = "k3os-server-${var.cluster_name}"

  vcpu   = var.server_vcpu
  memory = var.server_memory

  kernel = libvirt_volume.kernel.id
  initrd = libvirt_volume.initrd.id

  cmdline = [
    {
      "k3os.fallback_mode"      = "install"
      "k3os.install.config_url" = "https://raw.githubusercontent.com/camptocamp/terraform-libvirt-k3os/master/config-server.yaml"
      "k3os.install.silent"     = true
      "k3os.install.device"     = "/dev/vda"
      "k3os.token"              = random_password.k3s_token.result
    },
  ]

  disk {
    file = libvirt_volume.k3os_server.id
  }

  disk {
    file = libvirt_volume.iso.id
  }

  network_interface {
    network_id     = libvirt_network.k3os.id
    hostname       = "server"
    wait_for_lease = true
  }
}

resource "libvirt_volume" "k3os_agent" {
  count = var.node_count

  name   = "k3os-server-${count.index}.raw"
  size   = "10737418240"
  format = "raw"
  pool   = libvirt_pool.cluster.name
}

resource "libvirt_domain" "k3os_agent" {
  count = var.node_count

  name = "k3os-agent-${var.cluster_name}-${count.index}"

  vcpu   = var.agent_vcpu
  memory = var.agent_memory


  kernel = libvirt_volume.kernel.id
  initrd = libvirt_volume.initrd.id

  cmdline = [
    {
      "k3os.fallback_mode"      = "install"
      "k3os.install.config_url" = "https://raw.githubusercontent.com/camptocamp/terraform-libvirt-k3os/master/config-agent.yaml"
      "k3os.install.silent"     = true
      "k3os.install.device"     = "/dev/vda"
      "k3os.server_url"         = format("https://%s:6443", libvirt_domain.k3os_server.network_interface.0.addresses.0)
      "k3os.token"              = random_password.k3s_token.result
    }
  ]

  disk {
    file = libvirt_volume.k3os_agent[count.index].id
  }

  disk {
    file = libvirt_volume.iso.id
  }

  network_interface {
    network_id     = libvirt_network.k3os.id
    hostname       = "server"
    wait_for_lease = true
  }
}

resource "random_password" "k3s_token" {
  length = 16
}

resource "null_resource" "wait_for_cluster" {
  provisioner "local-exec" {
    command     = var.wait_for_cluster_cmd
    interpreter = var.wait_for_cluster_interpreter
    environment = {
      ENDPOINT = format("https://%s:6443", libvirt_domain.k3os_server.network_interface.0.addresses.0)
    }
  }
}

resource "null_resource" "wait_for_kubeconfig" {
  depends_on = [
    null_resource.wait_for_cluster,
  ]

  provisioner "local-exec" {
    command = "chmod 0600 ${path.module}/id_ed25519 && ssh -o StrictHostKeyChecking=no -i ${path.module}/id_ed25519 rancher@${libvirt_domain.k3os_server.network_interface.0.addresses.0} 'for i in `seq 1 60`; do test -f /etc/rancher/k3s/k3s.yaml && exit 0 || true; sleep 5; done; echo TIMEOUT && exit 1'"
  }
}

resource "null_resource" "get_kubeconfig" {
  depends_on = [
    null_resource.wait_for_kubeconfig,
  ]

  provisioner "local-exec" {
    command = "chmod 0600 ${path.module}/id_ed25519 && ssh -o StrictHostKeyChecking=no -i ${path.module}/id_ed25519 rancher@${libvirt_domain.k3os_server.network_interface.0.addresses.0} cat /etc/rancher/k3s/k3s.yaml > ${path.cwd}/kubeconfig.yaml"
  }
}

resource "null_resource" "fix_kubeconfig" {
  depends_on = [
    null_resource.get_kubeconfig,
  ]

  provisioner "local-exec" {
    command = "sed -i -e 's/127.0.0.1/${libvirt_domain.k3os_server.network_interface.0.addresses.0}/' ${path.cwd}/kubeconfig.yaml"
  }
}

data "local_file" "kubeconfig" {
  filename = "${path.cwd}/kubeconfig.yaml"

  depends_on = [
    null_resource.fix_kubeconfig,
  ]
}
