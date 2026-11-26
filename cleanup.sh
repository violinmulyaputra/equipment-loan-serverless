#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Konfigurasi
export AWS_DEFAULT_REGION=us-east-1
STACK="${STACK_NAME:-loan-app}"

read -r -p "Hapus stack $STACK beserta datanya? (y/N) " ANSWER
if [[ "$ANSWER" != "y" ]]; then
  echo "Dibatalkan"
  exit 0
fi

# Bucket
BUCKET=$(aws cloudformation describe-stack-resources --stack-name "$STACK" \
  --query "StackResources[?LogicalResourceId=='LoanBucket'].PhysicalResourceId" --output text)
if [[ -n "$BUCKET" && "$BUCKET" != "None" ]] && aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3 rm "s3://$BUCKET" --recursive
fi

# Stack
echo "Menghapus stack"
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"

# Log
aws logs delete-log-group --log-group-name "/aws/lambda/$STACK-fn" 2>/dev/null || true
rm -rf build
echo "Selesai"
