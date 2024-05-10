# variables.tf

variable "rds_instance_id" {
  type        = string
  description = "The ID of the RDS instance to manage."
}

variable "region" {
  type        = string
  description = "The AWS region to deploy the resources."
  default     = "us-east-2"
}

variable "profile" {
  type        = string
  description = "The AWS profile to use."
}

variable "notification_emails" {
  description = "List of email addresses to receive notifications"
  type        = list(string)
}

variable "environment" {
  description = "The environment to deploy the resources."
  type        = string
  default     = "Development"
}

variable "project" {
  description = "The project name to deploy the resources."
  type        = string
  default     = "LambdaRDSState"
}

variable "stop_after_minutes" {
  description = "The number of minutes to wait before stopping the RDS instance."
  type        = number
  default     = 30
}

variable "start_after_days" {
  description = "The number of minutes to wait before starting the RDS instance."
  type        = number
  default     = 6
}
