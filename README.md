# AWS SQS VPC Endpoint Bug Reproduction (Go SDK v2)

This repository reproduces and fixes a bug in the AWS Go SDK v2 where setting
`WithBaseEndpoint` at the config level causes STS `AssumeRoleWithWebIdentity`
credential refresh calls to be routed through the SQS VPC endpoint instead of
the real STS endpoint, resulting in a `400 NoSuchVersion` error.

## The Bug

When a VPC endpoint base URL is set at the config level:
```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithBaseEndpoint(vpcEndpointURL), // bleeds into STS calls
)
```

The SDK routes ALL service calls including STS credential refresh through
the VPC endpoint. SQS VPC endpoints do not understand STS requests and
respond with `400 NoSuchVersion`.

## The Fix

Scope the base endpoint only to the SQS client:
```go
cfg, _ := config.LoadDefaultConfig(ctx,
    config.WithRegion(region), // no base endpoint here
)

sqsClient := sqs.NewFromConfig(cfg, func(o *sqs.Options) {
    o.BaseEndpoint = aws.String(vpcEndpointURL) // scoped to SQS only
})
```

## Repository Structure
```
.
├── terraform/        # AWS infrastructure provisioning
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
├── go/               # Go test code demonstrating bug and fix
│   ├── main.go
│   └── go.mod
└── .github/
    └── workflows/
        └── sqs-test.yml  # GitHub Actions workflow using OIDC
```

## Prerequisites

- AWS account
- Terraform >= 1.0
- Go >= 1.23
- GitHub account

## Usage

1. Deploy infrastructure: `cd terraform && terraform apply`
2. Push to GitHub to trigger the workflow automatically
3. Observe Scenario 1 (broken) and Scenario 2 (fixed) in GitHub Actions logs
