#!/bin/bash
echo "Starting drift detection scan..."

INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$INSTANCE_IDS" ]; then
  echo "No running instances found."
  exit 0
fi

echo "Checking instances: $INSTANCE_IDS"

for ID in $INSTANCE_IDS; do
  TAG_VALUE=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$ID" "Name=key,Values=Environment" \
    --query "Tags[0].Value" \
    --output text 2>/dev/null)
  
  if [ "$TAG_VALUE" != "Terraform-Managed" ]; then
    echo "🚨 Found rogue instance: $ID"
    aws lambda invoke \
      --function-name drift-detective-enforcer \
      --invocation-type Event \
      --cli-binary-format raw-in-base64-out \
      --payload "{\"instance_id\": \"$ID\"}" \
      /tmp/response.json > /dev/null 2>&1
    echo "✅ Invoked Lambda for $ID"
  else
    echo "✓ $ID is managed (has correct tag)"
  fi
done

echo "Scan complete!"
