# SeleniumRestartStateMachine
![Step Function Graph](stepfunctions_graph.svg)


CloudFormation and Terraform templates to spin up State Machine resources to recover and restart service on instance status check fail, implemented using AWS Step Functions


This guide will help you deploy the resources necessary for managing EC2 instances using AWS CloudFormation, Step Functions, and Lambda functions.

## Prerequisites

- AWS CLI installed and configured with the proper credentials.
- An existing S3 bucket to store Lambda function code zip files.

## CloudFormation Deployment Instructions

### Step 1: Package the CloudFormation Template

The Lambda function code needs to be packaged and uploaded to the specified S3 bucket before deploying the CloudFormation stack.

```bash
aws cloudformation package \
  --template-file template.yml \
  --s3-bucket YOUR-S3-BUCKET-NAME \
  --output-template-file packaged-template.yml
```

### Step 2: Deploy the CloudFormation Stack

```bash
  aws cloudformation deploy \
  --template-file packaged-template.yml \
  --stack-name SeleniumRestartStateMachineStack \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      S3Bucket=YOUR-S3-BUCKET-NAME \
      S3StopFunctionKey=ec2-status-check-fail-stop-function.zip \
      S3RestartFunctionKey=ec2-status-check-fail-restart-function.zip \
      AlarmNamePrefix=YOUR-ALARM-NAME
