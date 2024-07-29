# As asked in the Task this is a single script using IaC to deploy a simple web application.

# Variables ]--------------------------------------------------------------
# varaibles with default and a few list types to simplyif creation of resources
# across multiple az's
# for a more full featured iac more complex map variables, locals and TF_VARS can be 
# could be employed here.
variable "AWS_REGION" {
  type    = string
  default = "us-east-1"
}

variable "MIN_SIZE" {
  type    = string
  default = "1"
}

variable "MAX_SIZE" {
  type    = string
  default = "4"
}

variable "DESIRED_CAPACITY" {
  type    = string
  default = "2"
}

variable "INSTANCE_TYPE" {
  type    = string
  default = "t3.micro"
}

variable "INSTANCE_AMI_ID" {
  type    = string
  default = "ami-0b72821e2f351e396"
}

variable "KEY_NAME" {
  type    = string
  default = "MyEC2KeyPair"
}

variable "VPC_CIDR" {
  type        = string
  description = "CIDR for VPC"
  default     = "10.0.0.0/16"
}

variable "VPC_TARGET_AZS" {
  type        = list(string)
  description = "AWS Availability Zones"
  default     = ["us-east-1a", "us-east-1b"]
}

variable "VPC_PUBLIC_SUBNETS" {
  type        = list(string)
  description = "Public Subnets"
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "VPC_PRIVATE_SUBNETS" {
  type        = list(string)
  description = "Private Subnets"
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}


# Provider ]----------------------------------------------------------------
# provider is aws using env vars for authentication
provider "aws" {
  region = var.AWS_REGION
 default_tags {
    tags = {
      Application = "testing"
      Environment = "dev"
      Owner       = "Terraform"
    }
  }
}


# VPC ]--------------------------------------------------------------------
# a single vpc in a single aws accout is used
# two subnets defiened in each az one public to hold alb and any public facing resources
# one private allowing us to manage traffic flows.
resource "aws_vpc" "main" {
  cidr_block = var.VPC_CIDR
}

# Subnet
resource "aws_subnet" "private" {
  count = length(var.VPC_PRIVATE_SUBNETS)
  vpc_id     = aws_vpc.main.id
  cidr_block = var.VPC_PRIVATE_SUBNETS[count.index]
  availability_zone = var.VPC_TARGET_AZS[count.index]
  tags = {
    Name = "private-subnet-${count.index}"
  }  
}

resource "aws_subnet" "public" {
  count = length(var.VPC_PUBLIC_SUBNETS)
  vpc_id     = aws_vpc.main.id
  cidr_block = var.VPC_PUBLIC_SUBNETS[count.index]
  availability_zone = var.VPC_TARGET_AZS[count.index]
  tags = {
    Name = "public-subnet-${count.index}"
  }  
}


# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Elastic IP
resource "aws_eip" "elastic_ip_for_nat_gw" {
  domain                    = "vpc"
  associate_with_private_ip = "10.0.0.5"
  depends_on                = [aws_internet_gateway.igw]
  tags = {
    Name = "nat-gateway-eip"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.elastic_ip_for_nat_gw.id
  subnet_id     = element(aws_subnet.public[*].id, 0)
  depends_on    = [aws_eip.elastic_ip_for_nat_gw]
  tags = {
    Name = "ngw"
  }
}

# Public Route Table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public_route_table"
  }  
}

# Public Route Table Association
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public_route_table.id
}

# Private Route Table
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.nat_gw.id
  }

  tags = {
    Name = "private_route_table"
  }
}

# Private Route Table Association
resource "aws_route_table_association" "private" {
  count          = length(var.VPC_PRIVATE_SUBNETS)
  subnet_id      = element(aws_subnet.private[*].id, count.index)
  route_table_id = aws_route_table.private_route_table.id
}


# Application Load Balancer ]-------------------------------------------------------------------
# define an alb responsible for distributing incoming application traffic across targets
resource "aws_lb" "application_load_balancer" {
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_security_group.id]
  subnets                    =  [for k, v in aws_subnet.public : aws_subnet.public[k].id]
  enable_deletion_protection = false
  depends_on = [ aws_subnet.public ]
}

 # define a target group to route requests to asg
resource "aws_lb_target_group" "alb_target_group" {
  target_type = "instance"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    interval            = 300
    path                = "/"
    timeout             = 60
    matcher             = 200
    healthy_threshold   = 5
    unhealthy_threshold = 5
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [ aws_subnet.public, aws_security_group.alb_security_group ]
}

# define a listener for http trafic
resource "aws_lb_listener" "alb_http_listener" {
  load_balancer_arn = aws_lb.application_load_balancer.id
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target_group.id

  }
}

# attach the asg to the target group
resource "aws_autoscaling_attachment" "asg_attachment_elb" {
  autoscaling_group_name = aws_autoscaling_group.nginx_asg.id
  lb_target_group_arn = aws_lb_target_group.alb_target_group.arn
}

# Launch Configuration ]---------------------------------------------------------------------
# simple launch config to start a single page site for validation. to keep this super simple
# a nginx single page site is used.
resource "aws_launch_configuration" "nginx_launch_configuration" {
  name          = "nginx-launch-configuration"
  image_id      = var.INSTANCE_AMI_ID # Update this to your preferred AMI
  instance_type = var.INSTANCE_TYPE
  key_name      = var.KEY_NAME
  security_groups = [aws_security_group.asg_security_group.id]

  user_data = <<-EOF
                #!/bin/bash
                yum update -y
                yum install -y epel-release
                yum install -y nginx
                echo "<html><body><h1>Hello from Nginx</h1></body></html>" > /usr/share/nginx/html/index.html
                systemctl start nginx
                systemctl enable nginx
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

# VPC Endpoints ]-------------------------------------------------------------------------
# provide secure access to ec2 instances. this is super helpful to validate instance health 
# if needed to reach live hosts.
resource "aws_ec2_instance_connect_endpoint" "ecs_instance_connect_endpoint" {
  subnet_id          = aws_subnet.private[0].id
  security_group_ids = [aws_security_group.vpc_endpoint_security_group.id]
}


# Auto Scaling Group ]--------------------------------------------------------------------
# define an asg to scale ec2 instances
resource "aws_autoscaling_group" "nginx_asg" {
  launch_configuration = aws_launch_configuration.nginx_launch_configuration.id
  min_size             = var.MIN_SIZE
  max_size             = var.MAX_SIZE
  desired_capacity     = var.DESIRED_CAPACITY
  vpc_zone_identifier  =  [for k, v in aws_subnet.private : aws_subnet.private[k].id]

  tag {
    key                 = "Name"
    value               = "nginx-asg-instance"
    propagate_at_launch = true
  }

  metrics_granularity  = "1Minute"
  enabled_metrics      = ["GroupDesiredCapacity", "GroupInServiceInstances", "GroupMinSize", "GroupMaxSize", "GroupPendingInstances", "GroupTerminatingInstances", "GroupTotalInstances", "GroupStandbyInstances", "GroupTotalInstances"]

  target_group_arns = [aws_lb_target_group.alb_target_group.arn]

  health_check_type         = "EC2"
  health_check_grace_period = 300

  lifecycle {
    create_before_destroy = true
  }
  depends_on = [ aws_subnet.private ]
}

# Auto Scaling Policies ]---------------------------------------------------------------

resource "aws_autoscaling_policy" "scale_up_policy" {
  name                   = "scale_up_policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.nginx_asg.name
}

resource "aws_autoscaling_policy" "scale_down_policy" {
  name                   = "scale_down_policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.nginx_asg.name
}


# Cloudwatch Alarms ]----------------------------------------------------------------------
# set threshold to scale out based on cpu usage
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "HighCPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "70"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nginx_asg.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_up_policy.arn]
}

# set the threshold to scale out based on mem usage
resource "aws_cloudwatch_metric_alarm" "high_memory_alarm" {
  alarm_name          = "HighMemoryUtilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = "60"
  statistic           = "Average"
  threshold           = "70"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nginx_asg.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_up_policy.arn]
}


# Security Groups ]---------------------------------------------------------------------------

# allow 443 in to vpc endpoints 
# used for the instance connect endpoint for secure access to ec2
resource "aws_security_group" "vpc_endpoint_security_group" {
  name        = "vpc_endpoint"
  description = "Allows inbound HTTPS access for vpc endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
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

# allow 80 and 443 in
# used for alb allow http traffic in
resource "aws_security_group" "alb_security_group" {
  description = "Controls access to the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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

# allow all ports from alb to asg (could be locked down further)
resource "aws_security_group" "asg_security_group" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb_security_group.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
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

# Outputs ]----------------------------------------------------------------------------
# single output to show endpoint for accessing web app
output "alb_endpoint" {
  value = aws_lb.application_load_balancer.dns_name
}
