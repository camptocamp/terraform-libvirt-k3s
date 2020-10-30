output "cluster_endpoint" {
  value = format("https://%s:6443", libvirt_domain.k3os_server.network_interface.0.addresses.0)
}

output "ingress_ip_address" {
  value = libvirt_domain.k3os_server.network_interface.0.addresses.0
}

output "kubeconfig" {
  value = data.local_file.kubeconfig.content
}

output "kubeconfig_filename" {
  value = data.local_file.kubeconfig.filename
}
