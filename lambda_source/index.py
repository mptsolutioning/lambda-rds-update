import boto3
from datetime import datetime, timedelta
import os


def lambda_handler(event, context):
    dynamodb = boto3.resource("dynamodb")
    rds = boto3.client("rds")
    events = boto3.client("events")
    sns = boto3.client("sns")

    now = datetime.now()

    rds_instance_to_manage = os.environ["RDS_INSTANCE_ID"]
    table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])
    stop_after_minutes = int(os.getenv("STOP_AFTER_MINUTES", "30"))
    start_after_days = int(os.getenv("START_AFTER_DAYS", "6"))
    function_arn = os.environ["AWS_LAMBDA_FUNCTION_ARN"]

    # Fetch the last state from DynamoDB
    response = table.get_item(Key={"StateKey": "RDSControl"})
    last_state = response.get("Item", {})

    if last_state:
        last_action_time = datetime.strptime(
            last_state["Timestamp"], "%Y-%m-%dT%H:%M:%S"
        )
        state = last_state.get("State", "STOPPED")
    else:
        last_action_time = now  # Default to now to handle edge case on first run
        state = "STOPPED"

    if state == "STOPPED" and now - last_action_time > timedelta(days=start_after_days):
        # Start the RDS instance
        rds.start_db_instance(DBInstanceIdentifier=rds_instance_to_manage)
        state = "STARTED"
        # Log start time in DynamoDB
        log_state_change(table, "STARTED", now)
        # Set a CloudWatch event to stop the instance after 30 minutes
        schedule_next_event(events, "stop-instance", stop_after_minutes, function_arn)
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message="RDS Cost Manager Instance for instance"
            + rds_instance_to_manage
            + "has been started at "
            + now
            + " and will be stopped after 30 minutes",
            Subject="RDS Cost Manger Lambda Notification - Instance Started",
        )
    elif state == "STARTED":
        # Stop the RDS instance
        rds.stop_db_instance(DBInstanceIdentifier=rds_instance_to_manage)
        state = "STOPPED"
        # Log stop time in DynamoDB
        log_state_change(table, "STOPPED", now)
        # Set a CloudWatch event to start the instance again after 6 days
        schedule_next_event(
            events, "start-instance", start_after_days * 24 * 60, function_arn
        )  # 6 days in minutes
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message="RDS Cost Manager Instance for instance"
            + rds_instance_to_manage
            + "has been stopped at "
            + now
            + " and will be started again in 6 days",
            Subject="RDS Cost Manger Lambda Notification - Instance Stopped",
        )

    return {
        "message": f"RDS instance {state}.",
        "state": state,
        "timestamp": now.isoformat(),
    }


def log_state_change(dynamodb_table, new_state, timestamp):
    """Logs the state change to DynamoDB."""
    dynamodb_table.put_item(
        Item={
            "StateKey": "RDSControl",
            "Timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%S"),
            "State": new_state,
        }
    )


def schedule_next_event(events_client, action, minutes, lambda_function_arn):
    """Schedule the next start/stop event."""
    rule_name = f"{action}-lambda-trigger"

    # Create or update the rule to trigger at the specified future time
    future_time = datetime.now() + timedelta(minutes=minutes)
    cron_expression = future_time.strftime("cron(%M %H %d %m ? %Y)")

    events_client.put_rule(Name=rule_name, ScheduleExpression=cron_expression)

    events_client.put_targets(
        Rule=rule_name,
        Targets=[
            {
                "Id": "1",
                "Arn": lambda_function_arn,
            }
        ],
    )
