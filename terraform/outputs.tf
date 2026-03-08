# Outputs are like return values — Terraform prints these after "terraform apply"
# We use them to grab important values we need for our Go test code

# The full URL of the SQS queue e.g. https://sqs.us-east-1.amazonaws.com/123456789/queue-name
output "queue_url" {
  # aws_sqs_queue.test_queue refers to the resource named "test_queue" in main.tf
  # .url is an attribute that AWS assigns automatically after creation
  value = aws_sqs_queue.test_queue.url
}

# The ARN (Amazon Resource Name) — a unique identifier for the queue across all of AWS
output "queue_arn" {
  value = aws_sqs_queue.test_queue.arn
}

# The DNS name of the VPC endpoint — this is what we use as "baseEndpoint" in Go
# dns_entry is a list, [0] gets the first (primary) DNS entry
output "vpc_endpoint_dns" {
  value = aws_vpc_endpoint.sqs.dns_entry[0].dns_name
}

# The ARN of the IAM role we created — useful for referencing in other AWS services
output "role_arn" {
  value = aws_iam_role.sqs_test_role.arn
}

# Public IP of the EC2 instance — used to SSH into it from our workstation
output "ec2_public_ip" {
  value = aws_instance.sqs_test_instance.public_ip
}

# ARN of the GitHub Actions role — needed in the workflow file
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_role.arn
}
