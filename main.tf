# Configuration Block
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Provider Configuration (Assumes AWS credentials are configured locally)
provider "aws" {
  region = var.aws_region
}

# --- Input Variables ---

variable "aws_region" {
  description = "The AWS region to deploy resources to."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "The name of an existing EC2 Key Pair for SSH access."
  type        = string
  default     = "my-ssh-key" # **CRITICAL: CHANGE THIS TO YOUR EXISTING KEY NAME**
}

variable "project_tag" {
  description = "A tag used for resource naming."
  type        = string
  default     = "VPC-EC2-S3-Demo"
}

# --- 1. Data Sources (AMI and Region Lookup) ---

# Find the latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- 2. VPC and Networking Resources ---

# Create a new VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_tag}-VPC"
  }
}

# Create a Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # Allows EC2 instances to get a public IP

  tags = {
    Name = "${var.project_tag}-Public-Subnet-A"
  }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_tag}-IGW"
  }
}

# Create a Route Table for internet access
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.project_tag}-Public-RT"
  }
}

# Associate the Route Table with the Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Create a Security Group to allow SSH (port 22)
resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id
  name   = "${var.project_tag}-EC2-SG"

  ingress {
    description = "Allow SSH from anywhere"
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

  tags = {
    Name = "${var.project_tag}-EC2-SG"
  }
}

# --- 3. IAM Role for S3 Access (EC2 Instance Profile) ---

# Define the Trust Policy (Allows EC2 to assume the role)
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Create the IAM Role
resource "aws_iam_role" "s3_access_role" {
  name               = "${var.project_tag}-S3AccessRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Define the S3 Full Access Policy
data "aws_iam_policy_document" "s3_full_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = ["*"]
  }
}

# Create the IAM Policy from the document
resource "aws_iam_policy" "s3_full_access_policy" {
  name        = "${var.project_tag}-S3FullAccessPolicy"
  policy      = data.aws_iam_policy_document.s3_full_access.json
  description = "Grants full S3 access to attached resources."
}

# Attach the S3 Policy to the IAM Role
resource "aws_iam_role_policy_attachment" "s3_attachment" {
  role       = aws_iam_role.s3_access_role.name
  policy_arn = aws_iam_policy.s3_full_access_policy.arn
}

# Create the Instance Profile (required to attach the role to EC2)
resource "aws_iam_instance_profile" "s3_instance_profile" {
  name = "${var.project_tag}-S3InstanceProfile"
  role = aws_iam_role.s3_access_role.name
}

# --- 4. EC2 Instance ---

# Launch the EC2 Instance
resource "aws_instance" "web_server" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.s3_instance_profile.name

  tags = {
    Name = "${var.project_tag}-Server"
  }
}

# --- 5. Outputs ---

output "vpc_id" {
  description = "The ID of the created VPC."
  value       = aws_vpc.main.id
}

output "public_ip" {
  description = "The public IP address of the EC2 instance (for SSH)."
  value       = aws_instance.web_server.public_ip
}

output "iam_role_arn" {
  description = "The ARN of the IAM role with S3 full access."
  value       = aws_iam_role.s3_access_role.arn
}
