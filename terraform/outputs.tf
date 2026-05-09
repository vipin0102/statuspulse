output "server_public_ip" {
  description = "Public IP of server"
  value       = aws_instance.statuspulse.public_ip
}

output "server_public_dns" {
  description = "Public DNS"
  value       = aws_instance.statuspulse.public_dns
}

output "server_ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i /home/vipinkumarsingh/terra/new/terra-key-pair.pem ubuntu@${aws_instance.statuspulse.public_ip}"
}