## Insert the ssm parameter

aws --profile harmonate-sandbox --region us-east-2 ssm put-parameter \
  --name "/rds/instance/to_keep_turned_off" \
  --type "String" \
  --value "example-db-for-lambda" \
  --overwrite | jq