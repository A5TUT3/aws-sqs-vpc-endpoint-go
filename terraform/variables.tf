# Variables allow us to reuse values across files without hardcoding them
# Think of them like environment variables for your Terraform code

variable "region" {
  # Default value used if no value is passed in at runtime
  # You can override this by running: terraform apply -var="region=us-west-2"
  default = "us-east-1"
}

variable "queue_name" {
  # The name we want to give our SQS queue
  # Referenced later in main.tf as var.queue_name
  default = "sqs-endpoint-test-queue"
}
