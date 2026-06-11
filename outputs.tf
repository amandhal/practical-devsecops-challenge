output "bastion_host_public_ip" {
  description = "Bastion Host Public IP"
  value       = module.ec2_instance_bastion_host.public_ip
}