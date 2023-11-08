terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
  }
}

# Hong Kong region
provider "aws" {
  region = "ap-east-1" 
}

# VPC IP range
resource "aws_vpc" "welend_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Pubilc subnet on AZ a
resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.welend_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-east-1a"
}

# Pubilc subnet on AZ b
resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.welend_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-east-1b"
}

# Pubilc subnet on AZ c
resource "aws_subnet" "public_subnet_3" {
  vpc_id                  = aws_vpc.welend_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "ap-east-1c"
}

# Route table
resource "aws_route_table" "welend_route_table" {
  vpc_id = aws_vpc.welend_vpc.id
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.welend_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.welend_igw.id
}

resource "aws_route_table_association" "public_subnet_1_association" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.welend_route_table.id
}

resource "aws_route_table_association" "public_subnet_2_association" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.welend_route_table.id
}

resource "aws_route_table_association" "public_subnet_3_association" {
  subnet_id      = aws_subnet.public_subnet_3.id
  route_table_id = aws_route_table.welend_route_table.id
}

resource "aws_internet_gateway" "welend_igw" {
  vpc_id = aws_vpc.welend_vpc.id
}

resource "aws_key_pair" "welend_ec2_key_pair" {
  key_name   = "welend-ec2-key-pair"
  public_key = "xxxxxxxxxxxxxxxxxxxxxxxxxx"
}

resource "aws_security_group" "web_alb_sg" {
  name        = "web_alb_sg"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.welend_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.web_ec2_sg.id]
  }
}

resource "aws_security_group" "web_ec2_sg" {
  name        = "web_ec2_sg"
  description = "Security group for EC2"
  vpc_id      = aws_vpc.welend_vpc.id

  # Allow specific IP to ssh web
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["1.2.3.4/32"]
  }

  # Allow incoming HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# WEB EC2
resource "aws_instance" "web_ec2_instance" {
  ami           = "ami-046b96ba42142cd59" # Amazon Linux AMI
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public_subnet_1.id
  associate_public_ip_address = true
  root_block_device {
    volume_size = 80
  }
  instance_initiated_shutdown_behavior = "terminate"
  monitoring {
    enabled = true
  }
  vpc_security_group_ids = [aws_security_group.web_ec2_sg.id]
  key_name               = aws_key_pair.welend_ec2_key_pair.key_name
  credit_specification {
    cpu_credits = "standard"
  }
  # install docker and deploy nginx
  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io
    systemctl start docker
    docker run -d -p 80:80 nginx:1.25.3
    EOF
}

resource "aws_alb" "web_alb" {
  name               = "web_alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_alb_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id, aws_subnet.public_subnet_3.id]
}

resource "aws_alb_target_group" "web_target_group" {
  name        = "web-target-group"
  port= 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.welend_vpc.id
  target_type = "instance"
  health_check {
    protocol            = "HTTP"
    port                = 80
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    path                = "/"
    matcher             = "200-299"
  }
}

resource "aws_alb_listener" "web_listener" {
  load_balancer_arn = aws_alb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.web_target_group.arn
    type             = "forward"
  }
}

# Enable CloudWatch logging for the ALB
resource "aws_lb_access_logs" "web_alb_logs" {
  load_balancer_arn = aws_lb.web_alb.arn
  bucket            = "welend-cloudwatch-logs-bucket" 
  prefix            = "web-alb-logs"
}

# Output the default welcome page of the Nginx container
output "nginx_welcome_page" {
  value = aws_instance.my_instance.public_ip
}

# Configure CloudWatch logging for the Nginx container
resource "aws_cloudwatch_log_group" "nginx_log_group" {
  name              = "nginx-logs"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "nginx_log_stream" {
  name           = "nginx-stream"
  log_group_name = aws_cloudwatch_log_group.nginx_log_group.name
}

resource "aws_cloudwatch_log_metric_filter" "nginx_log_metric_filter" {
  name           = "nginx-metric-filter"
  log_group_name = aws_cloudwatch_log_group.nginx_log_group.name
  pattern        = "{$.nginx_status_code = \"200\"}"
  metric_transformation {
    name      = "Count"
    namespace = "Custom"
    value     = "1"
  }
}
