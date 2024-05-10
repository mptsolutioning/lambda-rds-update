import boto3
from boto3.dynamodb.conditions import Key, Attr
from datetime import datetime, timedelta
import os


def lambda_handler(event, context):
    dynamodb = boto3.resource("dynamodb")
    rds = boto3.client("rds")
    events = boto3.client("events")
    sns = boto3.client("sns")
    tzformat = "%Y-%m-%dT%H:%M:%SZ"


    # Ensure 'now' is timezone-naive to match DynamoDB-stored times if they are naive
    now = datetime.now().replace(tzinfo=None)

    rds_instance_to_manage = os.environ["RDS_INSTANCE_ID"]
    table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])
    stop_after_minutes = int(os.getenv("STOP_AFTER_MINUTES", "30"))
    start_after_days = int(os.getenv("START_AFTER_DAYS", "6"))
    function_arn = context.invoked_function_arn

    last_state = fetch_last_state(rds, dynamodb, table, "RDSControl")

    if last_state:
        last_action_time = datetime.strptime(last_state["Timestamp"], tzformat)
        state = last_state.get("State", "STOPPED")
    else:
        last_action_time = now  # Default to now to handle edge case on first run
        state = "STOPPED"

    time_since_last_action = now - last_action_time

    if state == "STOPPED" and time_since_last_action > timedelta(days=start_after_days):
        # Start the RDS instance
        rds.start_db_instance(DBInstanceIdentifier=rds_instance_to_manage)
        log_state_change(table, "STARTED", now, tzformat)
        schedule_next_event(
            events, "stop-instance", stop_after_minutes, function_arn, now
        )
        message = f"RDS instance {rds_instance_to_manage} has been started at {now} and will be stopped after {stop_after_minutes} minutes."
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message=message,
            Subject="RDS Manager - Instance Started",
        )
    elif state == "STARTED" and time_since_last_action > timedelta(
        minutes=stop_after_minutes
    ):
        # Stop the RDS instance
        rds.stop_db_instance(DBInstanceIdentifier=rds_instance_to_manage)
        log_state_change(table, "STOPPED", now, tzformat)
        schedule_next_event(
            events, "start-instance", start_after_days * 1440, function_arn, now
        )  # Convert days to minutes
        message = f"RDS instance {rds_instance_to_manage} has been stopped at {now} and will be started again in {start_after_days} days."
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message=message,
            Subject="RDS Manager - Instance Stopped",
        )
    else:
        message = f"RDS instance {rds_instance_to_manage} is in state {state}."
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message=message,
            Subject="RDS Manager - No Action Taken",
        )

    return {
        "message": f"RDS instance {state}.",
        "state": state,
        "timestamp": now.strftime(tzformat),
    }


def log_state_change(dynamodb_table, new_state, timestamp, tzformat):
    """Logs the state change to DynamoDB."""
    dynamodb_table.put_item(
        Item={
            "StateKey": "RDSControl",
            "Timestamp": timestamp.strftime(tzformat),
            "State": new_state,
        }
    )


def schedule_next_event(
    events_client, action, minutes, lambda_function_arn, source_time
):
    """Schedule the next start/stop event."""
    rule_name = f"{action}-lambda-trigger"

    # Create or update the rule to trigger at the specified future time
    future_time = source_time + timedelta(minutes=minutes)
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


def fetch_last_state(my_rds, database_name, my_resource, table, state_key):

    rds_status = my_rds.describe_db_instances(DBInstanceIdentifier=database_name)['DBInstances'][0]['DBInstanceStatus']
    
    # Querying the table for the given StateKey
    # Assuming that you are storing the Timestamp in ISO 8601 format
    response = table.query(
        KeyConditionExpression=Key("StateKey").eq(state_key),
        ScanIndexForward=False,  # False makes the order descending
        Limit=1,  # Retrieves only the most recent item based on the Timestamp
    )

    # Extract the latest state from the response
    items = response.get("Items", [])
    if items:
        return items[0]  # Return the most recent item
    else:
        return None  # No items found for the given StateKey
