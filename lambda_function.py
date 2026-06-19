import boto3
import json
import os

def lambda_handler(event, context):
    rogue_instance_id = event.get('instance_id')
    
    if not rogue_instance_id:
        return {'statusCode': 400, 'body': 'No instance_id provided'}
    
    print(f"Processing rogue instance: {rogue_instance_id}")
    
    ec2 = boto3.client('ec2')
    sns = boto3.client('sns')
    
    try:
        ec2.stop_instances(InstanceIds=[rogue_instance_id])
        ec2.create_tags(
            Resources=[rogue_instance_id],
            Tags=[
                {'Key': 'Status', 'Value': 'Quarantined-Violation'},
                {'Key': 'QuarantinedBy', 'Value': 'DriftDetective-Lambda'}
            ]
        )
        
        sns_topic_arn = os.environ.get('SNS_TOPIC_ARN')
        if sns_topic_arn:
            message = f"""
🚨 SECURITY ALERT: Rogue EC2 Instance Detected and Quarantined

Instance ID: {rogue_instance_id}
Action Taken: Instance stopped and tagged
Status: Quarantined-Violation

This instance was detected without the required 'Environment=Terraform-Managed' tag
and has been automatically stopped by the Drift Detective system.

---
Drift Detective Security System
            """
            sns.publish(
                TopicArn=sns_topic_arn,
                Subject=f"🚨 Rogue Instance Quarantined: {rogue_instance_id}",
                Message=message
            )
        
        return {'statusCode': 200, 'body': json.dumps({'message': f'Quarantined {rogue_instance_id}'})}
    except Exception as e:
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
