data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_ssm_parameter" "rds_instance_name" {
  name = "/rds/instance/to_keep_turned_off"
}

locals {
  common_tags = {
    Name        = var.project
    Environment = var.environment
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

resource "random_pet" "unique_name" {
  length = 2
}

resource "aws_dynamodb_table" "lambda_rds_state" {
  name         = "LambdaRDSState"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "StateKey"
  range_key    = "Timestamp"

  attribute {
    name = "StateKey"
    type = "S"
  }

  attribute {
    name = "Timestamp"
    type = "S"
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "Manage RDS Start/Stop State"
    }
  )
}

resource "aws_sns_topic" "lambda_notifications" {
  name = "lambda-notifications"
  tags = merge(
    local.common_tags,
    {
      Purpose = "Manage RDS Start/Stop State"
    }
  )
}

resource "aws_sns_topic_subscription" "email_subscription" {
  for_each = toset(var.notification_emails)

  topic_arn = aws_sns_topic.lambda_notifications.arn
  protocol  = "email"
  endpoint  = each.value
}


resource "aws_s3_bucket" "lambda_code_bucket" {
  bucket        = "harmonate-lambda-functions-${random_pet.unique_name.id}"
  force_destroy = true

  tags = merge(
    local.common_tags,
    {
      Purpose = "Store Lambda Function Code"
    }
  )
}

resource "aws_s3_bucket_versioning" "lambda_code_bucket_versioning" {
  bucket = aws_s3_bucket.lambda_code_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "lambda_bucket_policy" {
  bucket = aws_s3_bucket.lambda_code_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Effect = "Allow",
        Resource = [
          "${aws_s3_bucket.lambda_code_bucket.arn}/*"
        ],
        Principal = {
          AWS = [aws_iam_role.lambda_execution_role.arn]
        }
      }
    ]
  })
}

resource "aws_iam_role" "lambda_execution_role" {
  name = "rds_management_lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]

  })
}

resource "aws_iam_role_policy" "lambda_rds_policy" {
  name = "rds_management_lambda_policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "rds:StartDBInstance",
          "rds:StopDBInstance",
          "rds:DescribeDBInstances",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ssm:GetParameter"
        ],
        Effect = "Allow",
        Resource = [
          "arn:aws:rds:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:db:${data.aws_ssm_parameter.rds_instance_name.value}",
          "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${data.aws_ssm_parameter.rds_instance_name.name}"
        ]
      },
    ]
  })
}

resource "aws_lambda_permission" "lambda_cloudwatch_policy" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/*"
}

resource "aws_iam_role_policy" "lambda_sns_publish" {
  name = "LambdaSNSPublish"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.lambda_notifications.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "lambda_dynamodb_access" {
  name = "LambdaDynamoDBAccess"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ],
        Resource = aws_dynamodb_table.lambda_rds_state.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch_policy" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "rds_manager" {
  depends_on = [
    aws_s3_bucket.lambda_code_bucket,
    aws_iam_role.lambda_execution_role,
    aws_iam_role_policy.lambda_rds_policy,
    aws_iam_role_policy.lambda_sns_publish,
    aws_iam_role_policy.lambda_dynamodb_access,
    aws_dynamodb_table.lambda_rds_state,
    aws_sns_topic.lambda_notifications
  ]
  function_name = "RDSInstanceManager"
  handler       = "index.lambda_handler"
  runtime       = "python3.10"

  s3_bucket = aws_s3_bucket.lambda_code_bucket.id
  s3_key    = "rds-manager.zip"

  role             = aws_iam_role.lambda_execution_role.arn
  timeout          = 120
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)

  environment {
    variables = {
      DYNAMODB_TABLE     = aws_dynamodb_table.lambda_rds_state.name
      SNS_TOPIC_ARN      = aws_sns_topic.lambda_notifications.arn
      RDS_INSTANCE_ID    = data.aws_ssm_parameter.rds_instance_name.value
      STOP_AFTER_MINUTES = var.stop_after_minutes
      START_AFTER_DAYS   = var.start_after_days
    }
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "Manage RDS Start/Stop State"
    }
  )
}

resource "aws_iam_role_policy" "lambda_cloudwatch_policy" {
  name = "LambdaCloudWatchPolicy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "events:PutEvents",
          "events:PutRule",
          "events:PutTargets",
          "events:DeleteRule",
          "events:RemoveTargets",
          "events:DescribeRule",
          "events:ListRules",
          "events:ListTargetsByRule",
        ]
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_source/"
  output_path = "${path.module}/rds-manager.zip"
}

resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.lambda_code_bucket.id
  key    = "rds-manager.zip"
  source = data.archive_file.lambda_zip.output_path

  etag = filemd5(data.archive_file.lambda_zip.output_path)
}

output "lambda_function_arn" {
  description = "The ARN of the Lambda function"
  value       = aws_lambda_function.rds_manager.arn
}

resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.rds_manager.function_name}"
  retention_in_days = 14

  tags = merge(
    local.common_tags,
    {
      Purpose = "Store Lambda Function Logs"
    }
  )
}
