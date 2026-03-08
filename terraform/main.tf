# -------------------------------------------------------
# SQS QUEUE
# This is the actual queue we will send/receive messages to
# -------------------------------------------------------
resource "aws_sqs_queue" "test_queue" {
  # The name of the queue — pulled from variables.tf
  name = var.queue_name
}

# -------------------------------------------------------
# IAM ROLE
# A role is an AWS identity that can be assumed by a service or user
# In the real scenario, this is what the Go app assumes to get credentials
# -------------------------------------------------------
resource "aws_iam_role" "sqs_test_role" {
  # A friendly name for the role — visible in the AWS console
  name = "sqs-endpoint-test-role"

  # The trust policy — defines WHO is allowed to assume this role
  # jsonencode() converts a Terraform map into a JSON string (which AWS requires)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # We're allowing the EC2 service to assume this role
        # In a real EKS/IRSA scenario this would be "federated" with an OIDC provider
        Principal = { Service = "ec2.amazonaws.com" }
        # sts:AssumeRole is the action that lets a service "become" this role
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# -------------------------------------------------------
# IAM POLICY
# Defines WHAT the role is allowed to do once assumed
# We attach it directly to the role above (inline policy)
# -------------------------------------------------------
resource "aws_iam_role_policy" "sqs_policy" {
  # Name of this policy
  name = "sqs-access"
  # Attach this policy to the role we created above
  # .id refers to the role's unique identifier
  role = aws_iam_role.sqs_test_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # List of SQS actions this role is allowed to perform
        Action = [
          "sqs:SendMessage",       # Put messages onto the queue
          "sqs:ReceiveMessage",    # Read messages from the queue
          "sqs:GetQueueAttributes",# Get metadata about the queue
          "sqs:GetQueueUrl",       # Look up the queue URL by name
          "sqs:ListQueues"         # List all queues in the account
        ]
        # Restrict access to ONLY our specific queue (not all queues)
        # .arn references the ARN of the queue resource defined above
        Resource = aws_sqs_queue.test_queue.arn
      }
    ]
  })
}

# -------------------------------------------------------
# VPC (Virtual Private Cloud)
# An isolated network in AWS where our resources will live
# This is needed because VPC endpoints only work inside a VPC
# -------------------------------------------------------
resource "aws_vpc" "test_vpc" {
  # The IP address range for this VPC — 10.0.0.0/16 gives us 65,536 addresses
  cidr_block = "10.0.0.0/16"
  # Required for VPC endpoints to resolve DNS names correctly
  enable_dns_support   = true
  # Allows instances in the VPC to get public DNS hostnames
  enable_dns_hostnames = true

  tags = { Name = "sqs-endpoint-test-vpc" }
}

# -------------------------------------------------------
# SUBNET
# A subdivision of the VPC — resources are launched into subnets
# The VPC endpoint needs to be associated with at least one subnet
# -------------------------------------------------------
resource "aws_subnet" "test_subnet" {
  # Place this subnet inside our VPC
  vpc_id = aws_vpc.test_vpc.id
  # A smaller IP range within the VPC — 10.0.1.0/24 gives us 256 addresses
  cidr_block = "10.0.1.0/24"
  # Place in the first availability zone of our region e.g. us-east-1a
  # The interpolation ${var.region}a dynamically builds the AZ name
  availability_zone = "${var.region}a"
  # Automatically assign a public IP to any instance launched in this subnet
  map_public_ip_on_launch = true

  tags = { Name = "sqs-endpoint-test-subnet" }
}

# -------------------------------------------------------
# SECURITY GROUP
# Acts like a firewall — controls what traffic can reach the VPC endpoint
# -------------------------------------------------------
resource "aws_security_group" "vpc_endpoint_sg" {
  name   = "sqs-vpce-sg"
  # Attach this security group to our VPC
  vpc_id = aws_vpc.test_vpc.id

  # INBOUND RULE — allow HTTPS traffic (port 443) from within the VPC
  # SQS API calls use HTTPS so we must allow port 443
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # Only allow traffic originating from within our VPC IP range
    cidr_blocks = ["10.0.0.0/16"]
  }

  # OUTBOUND RULE — allow all outbound traffic
  # -1 means all protocols, 0.0.0.0/0 means anywhere
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------------------------------------
# VPC ENDPOINT FOR SQS
# This is the KEY resource for our test
# It creates a private connection to SQS within the VPC
# Without this, SQS traffic would go out to the public internet
# With this, traffic stays inside AWS's private network
# -------------------------------------------------------
resource "aws_vpc_endpoint" "sqs" {
  # Which VPC to create the endpoint in
  vpc_id = aws_vpc.test_vpc.id
  # The name of the AWS service we want a private connection to
  # Format is always: com.amazonaws.<region>.<service>
  service_name = "com.amazonaws.${var.region}.sqs"
  # "Interface" type creates an ENI (Elastic Network Interface) in your subnet
  # This is required for SQS (as opposed to "Gateway" type used for S3/DynamoDB)
  vpc_endpoint_type = "Interface"
  # Which subnet to place the endpoint's network interface in
  subnet_ids = [aws_subnet.test_subnet.id]
  # Which security group controls traffic to this endpoint
  security_group_ids = [aws_security_group.vpc_endpoint_sg.id]
  # When true, the endpoint's DNS name overrides the public SQS DNS
  # This means sqs.us-east-1.amazonaws.com resolves to the private endpoint IP
  # This is exactly what triggers the bug we are reproducing!
  private_dns_enabled = true

  tags = { Name = "sqs-vpce-test" }
}

# -------------------------------------------------------
# KEY PAIR
# Uploads our local public key to AWS so we can SSH
# into the EC2 instance we are about to create
# -------------------------------------------------------
resource "aws_key_pair" "sqs_test_key" {
  key_name = "sqs-test-key"
  # The public key we generated with ssh-keygen
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMZ/sIzlsHTs3dpXStRJIsIXUdubfHr8TGJqchy/PmSC a5tut3@45TUT3"
}

# -------------------------------------------------------
# INTERNET GATEWAY
# Allows our VPC to communicate with the internet
# Required so the EC2 instance can download Go and our code
# Without this the instance has no outbound internet access
# -------------------------------------------------------
resource "aws_internet_gateway" "test_igw" {
  # Attach the internet gateway to our existing VPC
  vpc_id = aws_vpc.test_vpc.id

  tags = { Name = "sqs-endpoint-test-igw" }
}

# -------------------------------------------------------
# ROUTE TABLE
# Defines routing rules for our subnet
# We need a rule that sends internet-bound traffic
# through the internet gateway
# -------------------------------------------------------
resource "aws_route_table" "test_rt" {
  vpc_id = aws_vpc.test_vpc.id

  route {
    # 0.0.0.0/0 means all traffic not destined for the VPC
    cidr_block = "0.0.0.0/0"
    # Send that traffic through the internet gateway
    gateway_id = aws_internet_gateway.test_igw.id
  }

  tags = { Name = "sqs-endpoint-test-rt" }
}

# -------------------------------------------------------
# ROUTE TABLE ASSOCIATION
# Links our route table to our subnet
# Without this the subnet still uses the default route
# table which has no internet gateway route
# -------------------------------------------------------
resource "aws_route_table_association" "test_rta" {
  subnet_id      = aws_subnet.test_subnet.id
  route_table_id = aws_route_table.test_rt.id
}

# -------------------------------------------------------
# SECURITY GROUP FOR EC2
# Controls what traffic can reach our EC2 instance
# We need to allow SSH so we can connect to it
# -------------------------------------------------------
resource "aws_security_group" "ec2_sg" {
  name   = "sqs-test-ec2-sg"
  vpc_id = aws_vpc.test_vpc.id

  # Allow SSH (port 22) from anywhere so we can connect
  # from our workstation
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic so the instance can
  # download Go, reach SQS and STS endpoints
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sqs-test-ec2-sg" }
}

# -------------------------------------------------------
# IAM INSTANCE PROFILE
# This is the bridge between an EC2 instance and an IAM role
# EC2 cannot use an IAM role directly — it needs an
# instance profile as a container for the role
# -------------------------------------------------------
resource "aws_iam_instance_profile" "sqs_test_profile" {
  name = "sqs-endpoint-test-profile"
  # Reference our existing IAM role
  role = aws_iam_role.sqs_test_role.name
}

# -------------------------------------------------------
# UPDATE EXISTING IAM ROLE TRUST POLICY
# Our existing role only trusts ec2.amazonaws.com
# which is exactly what we need for EC2 instance profiles
# No changes needed here — it already works
# -------------------------------------------------------

# -------------------------------------------------------
# EC2 INSTANCE
# A small Amazon Linux 2023 instance launched inside
# our VPC that will run our Go test code
# -------------------------------------------------------
resource "aws_instance" "sqs_test_instance" {
  # Amazon Linux 2023 AMI for us-east-1
  # Free tier eligible t2.micro instance type
  ami           = "ami-0c101f26f147fa7fd"
  instance_type = "t2.micro"

  # Launch inside our existing subnet
  subnet_id = aws_subnet.test_subnet.id

  # Attach our SSH key pair so we can connect
  key_name = aws_key_pair.sqs_test_key.key_name

  # Attach the EC2 security group
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  # Attach the IAM instance profile so the instance
  # automatically gets credentials via AssumeRole
  iam_instance_profile = aws_iam_instance_profile.sqs_test_profile.name

  # Give the instance a public IP so we can SSH into it
  # from our workstation over the internet
  associate_public_ip_address = true

  # User data runs automatically when the instance first boots
  # We use it to install Go and write our test code
  # so everything is ready when we SSH in
  user_data = <<-USERDATA
    #!/bin/bash
    # Update system packages
    yum update -y

    # Download Go 1.23.6
    wget https://go.dev/dl/go1.23.6.linux-amd64.tar.gz -O /tmp/go.tar.gz

    # Extract Go to /usr/local
    tar -C /usr/local -xzf /tmp/go.tar.gz

    # Add Go to PATH for all users
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/ec2-user/.bashrc

    # Create the test directory
    mkdir -p /home/ec2-user/sqs-test

    # Write go.mod
    cat > /home/ec2-user/sqs-test/go.mod << 'GOMOD'
module sqs-endpoint-test

go 1.23
GOMOD

    # Write main.go with the real VPC endpoint and queue URL
    cat > /home/ec2-user/sqs-test/main.go << 'GOCODE'
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/smithy-go/logging"
)

func main() {

	region := "us-east-1"

	// VPC endpoint DNS — private SQS endpoint inside our VPC
	vpcEndpointDNS := "vpce-084176e4d1f44835a-t5vk2914.sqs.us-east-1.vpce.amazonaws.com"
	vpcEndpointURL := "https://" + vpcEndpointDNS

	// Our SQS queue URL
	queueURL := "https://sqs.us-east-1.amazonaws.com/162343470963/sqs-endpoint-test-queue"

	// -------------------------------------------------------
	// SCENARIO 1 - BROKEN
	// BaseEndpoint set at config level bleeds into STS calls
	// -------------------------------------------------------
	fmt.Println("\n========================================")
	fmt.Println("SCENARIO 1: BaseEndpoint at config level (BROKEN)")
	fmt.Println("========================================")

	brokenCfg, err := config.LoadDefaultConfig(
		context.TODO(),
		config.WithRegion(region),
		config.WithBaseEndpoint(vpcEndpointURL),
		config.WithLogger(logging.NewStandardLogger(os.Stderr)),
		config.WithClientLogMode(aws.LogRequestWithBody|aws.LogResponseWithBody),
	)
	if err != nil {
		fmt.Println("Failed to load config:", err)
		return
	}

	brokenClient := sqs.NewFromConfig(brokenCfg)

	_, err = brokenClient.ReceiveMessage(
		context.TODO(),
		&sqs.ReceiveMessageInput{
			QueueUrl:            aws.String(queueURL),
			MaxNumberOfMessages: 10,
		},
	)
	if err != nil {
		fmt.Println("BROKEN - Error received:", err)
	} else {
		fmt.Println("Unexpectedly succeeded")
	}

	// -------------------------------------------------------
	// SCENARIO 2 - FIXED
	// BaseEndpoint scoped only to SQS client
	// STS credential calls go to real sts.amazonaws.com
	// -------------------------------------------------------
	fmt.Println("\n========================================")
	fmt.Println("SCENARIO 2: BaseEndpoint scoped to SQS client only (CORRECT)")
	fmt.Println("========================================")

	fixedCfg, err := config.LoadDefaultConfig(
		context.TODO(),
		config.WithRegion(region),
		config.WithLogger(logging.NewStandardLogger(os.Stderr)),
		config.WithClientLogMode(aws.LogRequestWithBody|aws.LogResponseWithBody),
	)
	if err != nil {
		fmt.Println("Failed to load config:", err)
		return
	}

	fixedClient := sqs.NewFromConfig(fixedCfg, func(o *sqs.Options) {
		o.BaseEndpoint = aws.String(vpcEndpointURL)
	})

	_, err = fixedClient.ReceiveMessage(
		context.TODO(),
		&sqs.ReceiveMessageInput{
			QueueUrl:            aws.String(queueURL),
			MaxNumberOfMessages: 10,
		},
	)
	if err != nil {
		fmt.Println("Error (check type - should differ from Scenario 1):", err)
	} else {
		fmt.Println("SUCCESS - ReceiveMessage succeeded via VPC endpoint!")
	}

	fmt.Println("\n========================================")
	fmt.Println("COMPARE THE DEBUG LOGS ABOVE:")
	fmt.Println("SCENARIO 1 - STS Host should show VPC endpoint (wrong)")
	fmt.Println("SCENARIO 2 - STS Host should show sts.amazonaws.com (correct)")
	fmt.Println("========================================")
}
GOCODE

    # Set ownership so ec2-user can access the files
    chown -R ec2-user:ec2-user /home/ec2-user/sqs-test

    # Download dependencies
    cd /home/ec2-user/sqs-test
    /usr/local/go/bin/go mod tidy
    USERDATA

  tags = { Name = "sqs-endpoint-test-instance" }
}


# -------------------------------------------------------
# GITHUB OIDC PROVIDER
# This tells AWS to trust JWT tokens issued by GitHub Actions
# When a GitHub Actions workflow runs it automatically gets
# a JWT token from GitHub's OIDC provider
# AWS will verify that token is genuine before allowing
# the workflow to assume our IAM role
# -------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  # This is GitHub's well-known OIDC issuer URL
  # AWS uses this to fetch GitHub's public keys for JWT verification
  url = "https://token.actions.githubusercontent.com"

  # client_id_list identifies who the token is intended for
  # "sts.amazonaws.com" means the token is meant to be used with AWS STS
  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint of GitHub's OIDC certificate
  # AWS uses this to verify it's talking to the real GitHub OIDC endpoint
  # This is GitHub's current certificate thumbprint
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# -------------------------------------------------------
# IAM ROLE FOR GITHUB ACTIONS
# This role can be assumed by GitHub Actions workflows
# running in our specific repository using WebIdentity
# -------------------------------------------------------
resource "aws_iam_role" "github_actions_role" {
  name = "github-actions-sqs-test-role"

  # Trust policy — defines who can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # Allow assumption via WebIdentity (OIDC)
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          # The federated principal is our GitHub OIDC provider
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringEquals = {
            # Ensure the token is intended for AWS STS
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to only our specific GitHub repository
            # This prevents other GitHub repos from assuming this role
            # The * at the end allows any branch or event
            "token.actions.githubusercontent.com:sub" = "repo:A5TUT3/aws-sqs-vpc-endpoint-go:*"
          }
        }
      }
    ]
  })
}

# -------------------------------------------------------
# IAM POLICY FOR GITHUB ACTIONS ROLE
# Grants the GitHub Actions role permission to access SQS
# -------------------------------------------------------
resource "aws_iam_role_policy" "github_actions_sqs_policy" {
  name = "github-actions-sqs-access"
  role = aws_iam_role.github_actions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ListQueues"
        ]
        # Restrict access to only our specific test queue
        Resource = aws_sqs_queue.test_queue.arn
      }
    ]
  })
}
