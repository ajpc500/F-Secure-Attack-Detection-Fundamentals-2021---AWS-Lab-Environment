# Specify AWS region for deployment
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

################################################
#        S3 Bucket to hold our logs
#        inc. CloudTrail and S3 Server Access
################################################
resource "aws_s3_bucket" "bucket_for_log_events" {
  bucket = var.logging_bucket_name
  acl    = "log-delivery-write"
  force_destroy = true

  tags = {
    Name = "Logging"
  }

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${var.logging_bucket_name}"
        },
        {
            "Sid": "AWSCloudTrailWrite",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${var.logging_bucket_name}/cloudtrail-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        }
    ]
}
POLICY

}

################################################
#        S3 Bucket to hold our dummy data
################################################
resource "aws_s3_bucket" "bucket_for_exfil" {
  bucket = var.data_bucket_name
  acl    = "private"
  force_destroy = true

  tags = {
    Name = "Super Sensitive Info"
  }

  # Enabling server logging aswell
  logging {
    target_bucket = aws_s3_bucket.bucket_for_log_events.id
    target_prefix = "s3-logs/"
  }
}


################################################
#        Upload contents of dummy data dir
#        to S3 for something to exfil
################################################
resource "aws_s3_bucket_object" "object" {
  for_each = fileset("${var.local_exfil_data_dir}/", "*")

  bucket = aws_s3_bucket.bucket_for_exfil.id
  key    = each.value
  source = "${var.local_exfil_data_dir}/${each.value}"
  etag   = filemd5("${var.local_exfil_data_dir}/${each.value}")
}


################################################
#        CloudTrail with S3 Data Events
################################################
resource "aws_cloudtrail" "cloudtrail_with_s3_data_events" {
  
  name                          = "fsecure-workshop-cloudtrail"
  s3_bucket_name                = var.logging_bucket_name
  s3_key_prefix                 = "cloudtrail-logs"
  include_global_service_events = true 
  is_multi_region_trail         = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type = "AWS::S3::Object"
      values = ["${aws_s3_bucket.bucket_for_exfil.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket.bucket_for_exfil]

}


################################################
#        IAM Access Keys for Compromise
################################################

resource "aws_iam_access_key" "compromised_keys" {
  user    = aws_iam_user.compromised_user.name
}

resource "aws_iam_user" "compromised_user" {
  name = "customer_data_management_user"
  force_destroy = true
}

resource "aws_iam_user_policy" "compromised_user_policy" {
  name = "s3_access"
  user = aws_iam_user.compromised_user.name

  # S3 Permissions and full IAM - big yikes!
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [ "s3:GetObject" ],
      "Effect": "Allow",
      "Resource": "${aws_s3_bucket.bucket_for_exfil.arn}/*"
    },
    {
      "Action": [ "s3:ListBucket" ],
      "Effect": "Allow",
      "Resource": "${aws_s3_bucket.bucket_for_exfil.arn}"
    },
    {
      "Action": [
        "s3:ListAllMyBuckets",
        "iam:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_athena_workgroup" "example" {
  name = "fsecure-aws-workshop-workgroup"
  force_destroy = true

  configuration {
    publish_cloudwatch_metrics_enabled = false
    
    result_configuration {
      output_location = "s3://${var.logging_bucket_name}/athena-output/"
    }
  }
}

resource "aws_athena_database" "database" {
  name   = "fsecure_workshop_database"
  bucket = "${var.logging_bucket_name}/athena-output/"
}

################################################
#        AWS Glue Catalog Tables
#        CloudTrail and S3 Server Access Logs
################################################

# Taken from https://github.com/JamesWoolfenden/terraform-aws-cloudtrail/blob/master/aws_glue_catalog_table.cloudtrail.tf
resource "aws_glue_catalog_table" "cloudtrail" {
  name          = "cloudtrail_logs_${data.aws_caller_identity.current.account_id}"
  database_name = "fsecure_workshop_database"
  parameters = {
    "EXTERNAL"              = "TRUE"
    "classification"        = "cloudtrail"
    "comment"               = "CloudTrail table for ${var.logging_bucket_name} bucket"
  }

  depends_on = [aws_athena_database.database]

  table_type = "EXTERNAL_TABLE"
  storage_descriptor {
    bucket_columns            = []
    compressed                = false
    input_format              = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    location                  = "s3://${var.logging_bucket_name}/cloudtrail-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail"
    number_of_buckets         = -1
    output_format             = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    parameters                = {}
    stored_as_sub_directories = false

    columns {
      name = "eventversion"
      type = "string"
    }
    columns {
      name = "useridentity"
      type = "struct<type:string,principalId:string,arn:string,accountId:string,invokedBy:string,accessKeyId:string,userName:string,sessionContext:struct<attributes:struct<mfaAuthenticated:string,creationDate:string>,sessionIssuer:struct<type:string,principalId:string,arn:string,accountId:string,userName:string>>>"
    }
    columns {
      name = "eventtime"
      type = "string"
    }
    columns {
      name = "eventsource"
      type = "string"
    }
    columns {
      name = "eventname"
      type = "string"
    }
    columns {
      name = "awsregion"
      type = "string"
    }
    columns {
      name = "sourceipaddress"
      type = "string"
    }
    columns {
      name = "useragent"
      type = "string"
    }
    columns {
      name = "errorcode"
      type = "string"
    }
    columns {
      name = "errormessage"
      type = "string"
    }
    columns {
      name = "requestparameters"
      type = "string"
    }
    columns {
      name = "responseelements"
      type = "string"
    }
    columns {
      name = "additionaleventdata"
      type = "string"
    }
    columns {
      name = "requestid"
      type = "string"
    }
    columns {
      name = "eventid"
      type = "string"
    }
    columns {
      name = "resources"
      type = "array<struct<arn:string,accountId:string,type:string>>"
    }
    columns {
      name = "eventtype"
      type = "string"
    }
    columns {
      name = "apiversion"
      type = "string"
    }
    columns {
      name = "readonly"
      type = "string"
    }
    columns {
      name = "recipientaccountid"
      type = "string"
    }
    columns {
      name = "serviceeventdetails"
      type = "string"
    }
    columns {
      name = "sharedeventid"
      type = "string"
    }
    columns {
      name = "vpcendpointid"
      type = "string"
    }

    ser_de_info {
      parameters = {
        "serialization.format" = "1"
      }
      serialization_library = "com.amazon.emr.hive.serde.CloudTrailSerde"
    }

  }
}

# Adapted from https://aws.amazon.com/premiumsupport/knowledge-center/analyze-logs-athena/
resource "aws_glue_catalog_table" "s3_access_logs" {
  name          = "s3_access_logs_${data.aws_caller_identity.current.account_id}"
  database_name = "fsecure_workshop_database"
  parameters = {
    "EXTERNAL"              = "TRUE"
    "classification"        = "s3_access_logs"
    "comment"               = "S3 access logs for ${var.logging_bucket_name} bucket"
    
  }

  depends_on = [aws_athena_database.database]

  table_type = "EXTERNAL_TABLE"
  storage_descriptor {
    bucket_columns            = []
    compressed                = false
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"

    location                  = "s3://${var.logging_bucket_name}/s3-logs"
    number_of_buckets         = -1
    
    output_format             = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    parameters                = {}
    stored_as_sub_directories = false

    columns {
      name = "bucketowner"
      type = "string"
      }
    columns {
      name = "bucket_name"
      type = "string"
      }
    columns {
      name = "requestdatetime"
      type = "string"
      }
    columns {
      name = "remoteip"
      type = "string"
      }
    columns {
      name = "requester"
      type = "string"
      }
    columns {
      name = "requestid"
      type = "string"
      }
    columns {
      name = "operation"
      type = "string"
      }
    columns {
      name = "key"
      type = "string"
      }
    columns {
      name = "request_uri"
      type = "string"
      }
    columns {
      name = "httpstatus"
      type = "string"
      }
    columns {
      name = "errorcode"
      type = "string"
      }
    columns {
      name = "bytessent"
      type = "bigint"
      }
    columns {
      name = "objectsize"
      type = "bigint"
      }
    columns {
      name = "totaltime"
      type = "string"
      }
    columns {
      name = "turnaroundtime"
      type = "string"
      }
    columns {
      name = "referrer"
      type = "string"
      }
    columns {
      name = "useragent"
      type = "string"
      }
    columns {
      name = "versionid"
      type = "string"
      }
    columns {
      name = "hostid"
      type = "string"
      }
    columns {
      name = "sigv"
      type = "string"
      }
    columns {
      name = "ciphersuite"
      type = "string"
      }
    columns {
      name = "authtype"
      type = "string"
      }
    columns {
      name = "endpoint"
      type = "string"
      }
    columns {
      name = "tlsversion"
      type = "string"
      }

    ser_de_info {
      parameters = {
        "serialization.format" = "1"
        "input.regex"="([^ ]*) ([^ ]*) \\[(.*?)\\] ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) (\"[^\"]*\"|-) (-|[0-9]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) (\"[^\"]*\"|-) ([^ ]*)(?: ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*))?.*$"
      }
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
    }
  }
}

################################################
#        Output our access keys to 
#        get things rolling!
################################################
output "secret" {
  value = aws_iam_access_key.compromised_keys.secret
}

output "id" {
  value = aws_iam_access_key.compromised_keys.id
}