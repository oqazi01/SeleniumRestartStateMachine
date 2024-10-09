provider "aws" {
  region = var.region
}

variable "region" {
  description = "The AWS region where the resources will be deployed"
  type        = string
  default     = "us-east-1"
  validation {
    condition     = contains(["us-west-1", "us-west-2", "us-east-1", "us-east-2", "eu-west-1", "eu-central-1"], var.region)
    error_message = "Must be a valid AWS region."
  }
}

variable "s3_bucket" {
  description = "S3 bucket where Lambda start/stop code is stored"
  type        = string
}

variable "s3_stop_function_key" {
  description = "S3 key (file path) for the stop function zip file"
  type        = string
  default     = "ec2-status-check-fail-stop-function.zip"
}

variable "s3_restart_function_key" {
  description = "S3 key (file path) for the restart function zip file"
  type        = string
  default     = "ec2-status-check-fail-restart-function.zip"
}

variable "alarm_name_prefix" {
  description = "The alarm name or alarm name prefix to trigger the selenium machine restart workflow"
  type        = string
  default     = "Selenium-MachineStatusCheckFailAlarm"
}

# SNS Topic
resource "aws_sns_topic" "state_fail_topic" {
  name = "SeleniumRestartFailEventTopic"
}

# IAM Role for Lambda Functions
resource "aws_iam_role" "lambda_execution_role" {
  name = "LambdaExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  inline_policy {
    name   = "LambdaBasicExecutionPolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstances",
          "ec2:RebootInstances",
          "ec2:StopInstances",
          "ec2:StartInstances"
        ]
        Effect   = "Allow"
        Resource = "*"
      }]
    })
  }
}

# Lambda function to stop EC2 instance
resource "aws_lambda_function" "stop_ec2_lambda" {
  function_name = "instance-stop-function"
  handler       = "lambda_function.lambda_handler"
  role          = aws_iam_role.lambda_execution_role.arn
  runtime       = "python3.10"

  s3_bucket = var.s3_bucket
  s3_key    = var.s3_stop_function_key
}

# Lambda function to restart EC2 instance
resource "aws_lambda_function" "restart_ec2_lambda" {
  function_name = "instance-start-function"
  handler       = "lambda_function.lambda_handler"
  role          = aws_iam_role.lambda_execution_role.arn
  runtime       = "python3.10"

  s3_bucket = var.s3_bucket
  s3_key    = var.s3_restart_function_key
}

# IAM Role for Step Functions
resource "aws_iam_role" "step_function_execution_role" {
  name = "StepFunctionExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "states.amazonaws.com"
      }
    }]
  })

  inline_policy {
    name   = "StepFunctionExecutionPolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Action = [
          "lambda:InvokeFunction",
          "sns:Publish"
        ]
        Effect   = "Allow"
        Resource = "*"
      }]
    })
  }
}

# Step Function to stop/start EC2 instance
resource "aws_sfn_state_machine" "ec2_state_machine" {
  name     = "StopStartEC2StateMachine"
  role_arn = aws_iam_role.step_function_execution_role.arn
  definition = jsonencode({
    Comment = "State machine to stop and start EC2 instance based on health check failure"
    StartAt = "Stop EC2 Instance"
    States = {
      "Stop EC2 Instance" = {
        Type     = "Task"
        Resource = aws_lambda_function.stop_ec2_lambda.arn
        Next     = "Wait"
      }
      "Wait" = {
        Type     = "Wait"
        Seconds  = 180
        Next     = "Check Instance State"
      }
      "Check Instance State" = {
        Type        = "Task"
        Resource    = aws_lambda_function.restart_ec2_lambda.arn
        Next        = "Check Stopping State"
        ResultPath  = "$.instanceState"
        Retry       = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 30
          MaxAttempts     = 5
          BackoffRate     = 2
        }]
      }
      "Check Stopping State" = {
        Type     = "Choice"
        Choices  = [
          {
            Variable    = "$.instanceState.status"
            StringEquals = "stopping"
            Next        = "Wait and Retry"
          },
          {
            Variable    = "$.instanceState.status"
            StringEquals = "running"
            Next        = "Stop EC2 Instance"
          },
          {
            Variable    = "$.instanceState.status"
            StringEquals = "starting"
            Next        = "Success"
          },
          {
            Variable    = "$.instanceState.status"
            StringEquals = "stopped"
            Next        = "Start EC2 Instance"
          }
        ]
        Default = "SNS Publish"
      }
      "SNS Publish" = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = aws_sns_topic.state_fail_topic.arn
          Message.$ = "$"
        }
        Next = "Fail"
      }
      "Start EC2 Instance" = {
        Type     = "Task"
        Resource = aws_lambda_function.restart_ec2_lambda.arn
        Next     = "Success"
      }
      "Wait and Retry" = {
        Type     = "Wait"
        Seconds  = 60
        Next     = "Check Instance State"
      }
      "Success" = { Type = "Succeed" }
      "Fail"    = { Type = "Fail" Cause = "Unknown instance state" }
    }
  })
}

# IAM Role for EventBridge to invoke Step Function
resource "aws_iam_role" "eventbridge_execution_role" {
  name = "EventBridgeExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "events.amazonaws.com"
      }
    }]
  })

  inline_policy {
    name   = "EventBridgeInvokeStepFunctionPolicy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Action   = "states:StartExecution"
        Effect   = "Allow"
        Resource = aws_sfn_state_machine.ec2_state_machine.arn
      }]
    })
  }
}

# EventBridge rule
resource "aws_cloudwatch_event_rule" "cloudwatch_event_rule" {
  name        = "EC2HealthCheckFailureRule"
  event_pattern = jsonencode({
    source = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources = [join("", ["arn:aws:cloudwatch:", var.region, ":", data.aws_caller_identity.current.account_id, ":alarm:", var.alarm_name_prefix])]
    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "step_function_target" {
  rule      = aws_cloudwatch_event_rule.cloudwatch_event_rule.name
  target_id = "StepFunctionTarget"
  arn       = aws_sfn_state_machine.ec2_state_machine.arn
}

# Add permissions for EventBridge to invoke the Step Function
resource "aws_lambda_permission" "allow_eventbridge_to_invoke_stepfunction" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stop_ec2_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cloudwatch_event_rule.arn
}
