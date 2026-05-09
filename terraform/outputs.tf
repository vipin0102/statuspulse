output "server_public_ip" {
  description = "Public IP of server"
  value       = aws_instance.statuspulse.public_ip
}

output "server_public_dns" {
  description = "Public DNS"
  value       = aws_instance.statuspulse.public_dns
}