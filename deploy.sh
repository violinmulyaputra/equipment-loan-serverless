#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Konfigurasi
export AWS_DEFAULT_REGION=us-east-1
STACK="${STACK_NAME:-loan-app}"
LAPTOP_IP="${1:-}"

if [[ ! "$LAPTOP_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Pemakaian: bash deploy.sh <IP-publik-laptop>"
  exit 1
fi

# Jaringan
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" == "None" ]]; then
  echo "Default VPC tidak ditemukan"
  exit 1
fi
read -r SUBNET_A SUBNET_B _ <<< "$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
  --query "Subnets[?AvailabilityZoneId!='use1-az3'].SubnetId" --output text | tr '\n' ' ')"
if [[ -z "${SUBNET_B:-}" ]]; then
  echo "Butuh minimal dua subnet di AZ berbeda"
  exit 1
fi
SHELL_IP=$(curl -fsS https://checkip.amazonaws.com)

# Stack
echo "Deploy stack $STACK"
if ! aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name "$STACK" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    "VpcId=$VPC_ID" \
    "SubnetIds=$SUBNET_A,$SUBNET_B" \
    "LaptopCidr=$LAPTOP_IP/32" \
    "ShellCidr=$SHELL_IP/32"; then
  aws cloudformation describe-stack-events --stack-name "$STACK" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
    --output table || true
  exit 1
fi

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
FUNCTION=$(output FunctionName)
API_URL=$(output ApiUrl)

# Kode
echo "Unggah kode Lambda"
mkdir -p build
rm -f build/function.zip
(cd src && zip -q ../build/function.zip index.py)
aws lambda update-function-code --function-name "$FUNCTION" \
  --zip-file fileb://build/function.zip > /dev/null
aws lambda wait function-updated --function-name "$FUNCTION"

# Pemeriksaan
echo "Menunggu ALB siap"
for _ in $(seq 1 36); do
  if curl -fsS -m 5 "$API_URL/health" > /dev/null 2>&1; then
    echo "Siap: $API_URL"
    exit 0
  fi
  sleep 5
done
echo "ALB belum merespons: $API_URL/health"
exit 1
