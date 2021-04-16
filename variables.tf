variable "aws_region" {
  description = "AWS region to launch servers."
  default     = "us-east-1"
}

variable "local_exfil_data_dir" {
    description = "Local folder to add to exfil target bucket"
    default = "dummy-data"
}

variable "data_bucket_name" {
    description = "The name to give to the sensitive data bucket"
    default = "fsecure-aws-workshop-data-bucket"
}

variable "logging_bucket_name" {
    description = "The name to give to the logging data bucket"
    default = "fsecure-aws-workshop-logs-bucket"
}