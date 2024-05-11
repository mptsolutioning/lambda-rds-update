import boto3
from boto3.dynamodb.conditions import Key
from datetime import datetime, timedelta
import os
import logging

# Setup logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
MAX_ROWS = 10  # Specify the maximum number of rows to keep in the DynamoDB table

dynamodb = boto3.resource("dynamodb")
rds = boto3.client("rds")
events = boto3.client("events")
sns = boto3.client("sns")

# Get the environment variables
RDS_INSTANCE_ID = os.environ["RDS_INSTANCE_ID"]
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
STOP_AFTER_MINUTES = int(os.getenv("STOP_AFTER_MINUTES", "30"))
START_AFTER_DAYS = int(os.getenv("START_AFTER_DAYS", "6"))


def lambda_handler(event, context):
    logger.info("Lambda function has started execution.")
    lambda_function_arn = context.invoked_function_arn

    now = datetime.now().replace(tzinfo=None)
    table = dynamodb.Table(DYNAMODB_TABLE)
    last_state = get_latest_state(table, "RDSControl")
    state = last_state["State"]
    last_action_time = datetime.strptime(last_state["Timestamp"], TIMESTAMP_FORMAT)

    logger.info(f"Current state from DynamoDB: {state}")

    time_since_last_action = now - last_action_time

    # Get the current state of the RDS instance
    current_rds_state = get_rds_instance_current_status(rds, RDS_INSTANCE_ID)
    logger.info(f"Current RDS instance state: {current_rds_state}")

    if current_rds_state != state:
        # Update the state in the DynamoDB table if it differs from the current RDS state
        log_state_change(table, current_rds_state, now)
        state = current_rds_state
        logger.info(f"State change logged: {state}")

    if state == "stopped" and time_since_last_action.days >= START_AFTER_DAYS:
        log_state_change(table, "available", now)
        rds.start_db_instance(DBInstanceIdentifier=RDS_INSTANCE_ID)
        schedule_next_event(
            events, "stop-instance", STOP_AFTER_MINUTES, lambda_function_arn, now
        )
        publish_sns_message(
            sns,
            f"RDS instance {RDS_INSTANCE_ID} has been started at {now} and will be stopped after {STOP_AFTER_MINUTES} minutes.",
            "RDS Manager - Instance Started",
        )
        logger.info(
            f"RDS instance {RDS_INSTANCE_ID} started and scheduled to stop after {STOP_AFTER_MINUTES} minutes."
        )
    elif (
        state == "available"
        and time_since_last_action.total_seconds() >= STOP_AFTER_MINUTES * 60
    ):
        rds.stop_db_instance(DBInstanceIdentifier=RDS_INSTANCE_ID)
        log_state_change(table, "stopped", now)
        schedule_next_event(
            events, "start-instance", START_AFTER_DAYS * 1440, lambda_function_arn, now
        )
        publish_sns_message(
            sns,
            f"RDS instance {RDS_INSTANCE_ID} has been stopped at {now} and will be started again in {START_AFTER_DAYS} days.",
            "RDS Manager - Instance Stopped",
        )
        logger.info(
            f"RDS instance {RDS_INSTANCE_ID} stopped and scheduled to start in {START_AFTER_DAYS} days."
        )
    else:
        publish_sns_message(
            sns,
            f"RDS instance {RDS_INSTANCE_ID} is in state {state}.",
            "RDS Manager - No Action Taken",
        )
        logger.info(
            f"No action needed for RDS instance {RDS_INSTANCE_ID} currently in state {state}."
        )

    return {
        "message": f"RDS instance {state}.",
        "state": state,
        "timestamp": now.strftime(TIMESTAMP_FORMAT),
    }


def log_state_change(dynamodb_table, new_state, timestamp):
    # Put the new item into the DynamoDB table
    dynamodb_table.put_item(
        Item={
            "StateKey": "RDSControl",
            "Timestamp": timestamp.strftime(TIMESTAMP_FORMAT),
            "State": new_state,
        }
    )

    # Check if the number of rows exceeds MAX_ROWS
    response = dynamodb_table.query(
        KeyConditionExpression=Key("StateKey").eq("RDSControl"),
        Select="COUNT",
    )
    row_count = response["Count"]

    if row_count > MAX_ROWS:
        # Delete the oldest item
        oldest_item = dynamodb_table.query(
            KeyConditionExpression=Key("StateKey").eq("RDSControl"),
            ScanIndexForward=True,
            Limit=1,
        )["Items"][0]
        dynamodb_table.delete_item(
            Key={
                "StateKey": oldest_item["StateKey"],
                "Timestamp": oldest_item["Timestamp"],
            }
        )


def schedule_next_event(
    events_client, action, minutes, lambda_function_arn, source_time
):
    rule_name = f"{action}-lambda-trigger"
    future_time = source_time + timedelta(minutes=minutes)
    cron_expression = future_time.strftime("cron(%M %H %d %m ? %Y)")

    try:
        events_client.put_rule(
            Name=rule_name, ScheduleExpression=cron_expression, State="ENABLED"
        )
        events_client.put_targets(
            Rule=rule_name,
            Targets=[{"Id": "1", "Arn": lambda_function_arn}],
        )
    except Exception as e:
        logger.error(f"Error scheduling next event: {str(e)}")


def publish_sns_message(sns_client, message, subject):
    try:
        sns_client.publish(
            TopicArn=os.environ["SNS_TOPIC_ARN"],
            Message=message,
            Subject=subject,
        )
    except Exception as e:
        logger.error(f"Error publishing SNS message: {str(e)}")


def get_latest_state(table, state_key):
    try:
        response = table.query(
            KeyConditionExpression=Key("StateKey").eq(state_key),
            ScanIndexForward=False,
            Limit=1,
        )
        if response["Items"]:
            return response["Items"][0]
        else:
            # If no entries found, insert a record with a timestamp that forces a start from a stopped state
            start_time = datetime.now() - timedelta(days=START_AFTER_DAYS + 1)
            initial_state = {
                "StateKey": state_key,
                "Timestamp": start_time.strftime(TIMESTAMP_FORMAT),
                "State": "stopped",
            }
            table.put_item(Item=initial_state)
            return initial_state
    except Exception as e:
        logger.error(f"Error retrieving or inserting latest state: {str(e)}")
        return e


def get_rds_instance_current_status(rds_client, rds_instance_id):
    try:
        response = rds_client.describe_db_instances(
            DBInstanceIdentifier=rds_instance_id
        )
        return response["DBInstances"][0]["DBInstanceStatus"]
    except Exception as e:
        logger.error(f"Error getting RDS instance status: {str(e)}")
        return "unknown"
