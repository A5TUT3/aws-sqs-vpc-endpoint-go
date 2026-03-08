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

	// The AWS region where our SQS queue lives
	// Make sure this matches the region in your terraform variables.tf
	region := "us-east-1"

	// This is the VPC endpoint DNS name from your terraform output
	// Replace this placeholder after running: terraform output vpc_endpoint_dns
	// Format: vpce-xxxx.sqs.us-east-1.vpce.amazonaws.com
	vpcEndpointDNS := "vpce-084176e4d1f44835a-t5vk2914.sqs.us-east-1.vpce.amazonaws.com"

	// Build the full HTTPS URL for the VPC endpoint
	// The SDK requires a full URL including the https:// prefix
	vpcEndpointURL := "https://" + vpcEndpointDNS

	// Your SQS queue URL from terraform output queue_url
	// Format: https://sqs.us-east-1.amazonaws.com/123456789012/sqs-endpoint-test-queue
	queueURL := "https://sqs.us-east-1.amazonaws.com/898961940126/sqs-endpoint-test-queue"

	// -------------------------------------------------------
	// SCENARIO 1 — THE BROKEN WAY
	// BaseEndpoint is set at the config level which means it
	// applies globally to ALL AWS service calls including STS
	// credential refresh calls — causing them to hit the SQS
	// VPC endpoint instead of the real STS endpoint
	// -------------------------------------------------------
	fmt.Println("\n========================================")
	fmt.Println("SCENARIO 1: BaseEndpoint at config level (BROKEN)")
	fmt.Println("========================================")

	// LoadDefaultConfig builds AWS config by checking in order:
	// 1. Environment variables (AWS_ACCESS_KEY_ID etc.)
	// 2. ~/.aws/credentials file
	// 3. IAM instance profile (if running on EC2)
	brokenCfg, err := config.LoadDefaultConfig(
		// context.TODO() is a placeholder context — fine for scripts
		// In production use a real context with timeout/cancellation
		context.TODO(),

		// Tell the SDK which AWS region to use for all API calls
		config.WithRegion(region),

		// THIS IS THE BUG — setting BaseEndpoint at the config level
		// makes the SDK route ALL service calls including STS credential
		// refresh through this endpoint — SQS VPC endpoint cannot handle
		// STS requests and responds with 400 NoSuchVersion error
		config.WithBaseEndpoint(vpcEndpointURL),

		// Write SDK debug logs to stderr so they don't mix with our fmt.Println output
		config.WithLogger(logging.NewStandardLogger(os.Stderr)),

		// Log full HTTP request and response details so we can see exactly
		// which Host header the STS credential call is being sent to
		// LogRequestWithBody  — prints HTTP method, URL, headers and body
		// LogResponseWithBody — prints HTTP status, headers and response body
		// The | operator combines both flags using bitwise OR
		config.WithClientLogMode(aws.LogRequestWithBody|aws.LogResponseWithBody),
	)
	if err != nil {
		fmt.Println("Failed to load config:", err)
		return
	}

	// Create SQS client using the broken config
	brokenClient := sqs.NewFromConfig(brokenCfg)

	// Attempt to receive messages — this will trigger a credential refresh
	// which is where the bug manifests — watch the debug logs for the
	// STS call going to the wrong Host
	_, err = brokenClient.ReceiveMessage(
		context.TODO(),
		&sqs.ReceiveMessageInput{
			// aws.String() wraps a plain string into a pointer (*string)
			// because the AWS SDK uses pointers for optional fields
			QueueUrl: aws.String(queueURL),
			// Fetch up to 10 messages at once (maximum allowed by SQS)
			MaxNumberOfMessages: 10,
		},
	)
	if err != nil {
		// Expected failure — look for NoSuchVersion or 400 Bad Request
		fmt.Println("❌ BROKEN - Error received (expected):", err)
	} else {
		fmt.Println("✅ Unexpectedly succeeded — check your endpoint URL")
	}

	// -------------------------------------------------------
	// SCENARIO 2 — THE CORRECT WAY
	// BaseEndpoint is scoped only to the SQS client options
	// STS credential refresh calls are not affected and continue
	// going to the real sts.amazonaws.com endpoint correctly
	// -------------------------------------------------------
	fmt.Println("\n========================================")
	fmt.Println("SCENARIO 2: BaseEndpoint scoped to SQS client only (CORRECT)")
	fmt.Println("========================================")

	// Load a clean config with NO base endpoint override at the global level
	// This ensures STS credential refresh calls go to the correct endpoint
	fixedCfg, err := config.LoadDefaultConfig(
		context.TODO(),
		config.WithRegion(region),
		// Same debug logging so we can compare STS Host headers side by side
		config.WithLogger(logging.NewStandardLogger(os.Stderr)),
		config.WithClientLogMode(aws.LogRequestWithBody|aws.LogResponseWithBody),
	)
	if err != nil {
		fmt.Println("Failed to load config:", err)
		return
	}

	// Create SQS client with VPC endpoint scoped ONLY to this client
	// The second argument is an options function that overrides settings
	// for this specific SQS client without touching the global config
	fixedClient := sqs.NewFromConfig(fixedCfg, func(o *sqs.Options) {
		// This endpoint override applies ONLY to SQS API calls
		// STS credential refresh calls are completely unaffected
		// and continue going to sts.amazonaws.com as expected
		o.BaseEndpoint = aws.String(vpcEndpointURL)
	})

	// Attempt the same ReceiveMessage call with the correctly configured client
	_, err = fixedClient.ReceiveMessage(
		context.TODO(),
		&sqs.ReceiveMessageInput{
			QueueUrl:            aws.String(queueURL),
			MaxNumberOfMessages: 10,
		},
	)
	if err != nil {
		// A network error here is acceptable — what matters is the error
		// type is different from Scenario 1 (no NoSuchVersion error)
		fmt.Println("❌ Error (check if network/connectivity related):", err)
	} else {
		fmt.Println("✅ FIXED - ReceiveMessage succeeded via VPC endpoint!")
	}

	fmt.Println("\n========================================")
	fmt.Println("COMPARE THE DEBUG LOGS ABOVE:")
	fmt.Println("SCENARIO 1 — STS call Host should show your VPC endpoint")
	fmt.Println("SCENARIO 2 — STS call Host should show sts.amazonaws.com")
	fmt.Println("========================================")
}
