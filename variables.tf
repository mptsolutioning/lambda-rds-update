# variables.tf

variable "rds_instance_id" {
  type        = string
  description = "The ID of the RDS instance to manage."
}

variable "region" {
  type        = string
  description = "The AWS region to deploy the resources."
  default     = "us-west-2"
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