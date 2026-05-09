resource "aws_key_pair" "terra-key" {
  key_name   = "terra-key-pair"
  public_key = file("/home/vipinkumarsingh/terra/new/terra-key-pair.pub")
}

resource "aws_security_group" "statuspulse_sg" {
  name = "${var.project_name}-sg"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
  }

  ingress {
    description = "8000"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_ip]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Uptime Kuma"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "statuspulse_eip" {
  instance = aws_instance.statuspulse.id

  tags = {
    Name = "${var.project_name}-eip"
  }

  depends_on = [aws_instance.statuspulse]
}

resource "aws_instance" "statuspulse" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.terra-key.key_name
  vpc_security_group_ids = [aws_security_group.statuspulse_sg.id]

  #user_data = file("${path.module}/userdata.sh")
  user_data = templatefile("${path.module}/userdata.sh", {
    tailscale_auth_key = var.tailscale_auth_key
  })

  root_block_device {
    volume_size = 15
    volume_type = "gp3"
  }

  tags = {
    Name = var.project_name
  }
}