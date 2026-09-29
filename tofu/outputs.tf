output "nodes" {
  value = { for n, v in local.nodes : v.name => { mac = v.mac } }
}

output "vip" {
  value = local.vip
}
