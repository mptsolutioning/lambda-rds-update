data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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

resource "aws_dynamodb_table" "lambda_rds_state" {
  name         = "LambdaRDSState"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "StateKey"

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
  bucket = "harmonate-lambda-infra-functions"

  tags = merge(
    local.common_tags,
    {
      Purpose = "Store Lambda Function Code"
    }
  )
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

resource "aws_iam_role_policy" "lambda_policy" {
  name = "rds_management_lambda_policy"
  role = aws_iam_role.lambda_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "rds:StartDBInstance",
          "rds:StopDBInstance",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "arn:aws:rds:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:db:${var.rds_instance_id}"
      },
    ]
  })
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

resource "aws_lambda_function" "rds_manager" {
  depends_on = [
    aws_s3_bucket.lambda_code_bucket,
    aws_iam_role.lambda_execution_role,
    aws_iam_role_policy.lambda_policy,
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

  role    = aws_iam_role.lambda_execution_role.arn
  timeout = 30

  environment {
    variables = {
      DYNAMODB_TABLE      = aws_dynamodb_table.lambda_rds_state.name
      SNS_TOPIC_ARN       = aws_sns_topic.lambda_notifications.arn
      LAMBDA_FUNCTION_ARN = aws_lambda_function.rds_manager.arn
      RDS_INSTANCE_ID     = var.rds_instance_id
      STOP_AFTER_MINUTES  = "30"
      START_AFTER_DAYS    = "6"
    }
  }

  tags = merge(
    local.common_tags,
    {
      Purpose = "Manage RDS Start/Stop State"
    }
  )
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_lambda" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_six_hours.arn
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

resource "null_resource" "invoke_lambda_after_creation" {
  depends_on = [aws_lambda_function.rds_manager]

  provisioner "local-exec" {
    command = "aws lambda invoke --function-name ${aws_lambda_function.rds_manager.function_name} response.json"
  }
}