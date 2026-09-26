output "nodes" {
  value = { for n, v in local.nodes : v.name => { mac = v.mac, ip = v.ip } }
}

output "vip" {
  value = local.vip
}
