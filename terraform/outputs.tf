output "server_elastic_ip" {
  description = "Elastic IP of server"
  value       = aws_eip.statuspulse_eip.public_ip
}

output "server_ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i /home/vipinkumarsingh/terra/new/terra-key-pair ubuntu@${aws_eip.statuspulse_eip.public_ip}"
}