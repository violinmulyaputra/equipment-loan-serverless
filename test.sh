#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# Konfigurasi
export AWS_DEFAULT_REGION=us-east-1
STACK="${STACK_NAME:-loan-app}"
MODE="${1:-crud}"
FAILED=0
BODY=""

case "$MODE" in
  crud|persist|failure) ;;
  *) echo "Pemakaian: bash test.sh [crud|persist|failure]"; exit 1 ;;
esac

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
API_URL=$(output ApiUrl) || exit 1
BUCKET=$(output BucketName) || exit 1
FUNCTION=$(output FunctionName) || exit 1

mkdir -p evidence
LOG="evidence/$MODE-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$LOG") 2>&1

# Bantuan
check() {
  if [[ "$2" == "$3" ]]; then
    echo "LULUS  $1 (HTTP $3)"
  else
    echo "GAGAL  $1 (harapan $2, hasil $3)"
    FAILED=$((FAILED + 1))
  fi
}

request() {
  local label="$1" expected="$2" method="$3" path="$4" data="${5:-}"
  local args=(-s -m 20 -X "$method" -w $'\n%{http_code}')
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
  echo
  echo "> $method $path $data"
  local result
  result=$(curl "${args[@]}" "$API_URL$path")
  BODY="${result%$'\n'*}"
  echo "$BODY"
  check "$label" "$expected" "${result##*$'\n'}"
}

json_id() {
  python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$BODY" 2>/dev/null
}

set_env() {
  aws lambda update-function-configuration --function-name "$FUNCTION" \
    --environment "Variables={BUCKET_NAME=$1,UPDATED_AT=$(date +%s)}" > /dev/null &&
    aws lambda wait function-updated --function-name "$FUNCTION"
}

SAMPLE='{"borrower_name":"Budi","equipment_name":"Proyektor","loan_date":"2026-11-26","due_date":"2026-11-30"}'

create_sample() {
  request "Tambah data" 201 POST /loans "$SAMPLE"
  ID=$(json_id)
  if [[ -z "$ID" ]]; then
    echo "Data gagal dibuat, pengujian dihentikan"
    exit 1
  fi
}

# Pengujian CRUD dan keamanan
run_crud() {
  request "Health check" 200 GET /health
  create_sample
  request "Daftar data" 200 GET /loans
  request "Detail data" 200 GET "/loans/$ID"
  request "Ubah data" 200 PUT "/loans/$ID" '{"status":"dikembalikan"}'
  request "Input tidak lengkap ditolak" 400 POST /loans '{"borrower_name":"Budi"}'
  request "JSON rusak ditolak" 400 POST /loans '{rusak'
  echo
  echo "> GET objek S3 tanpa kredensial"
  check "Akses publik S3 ditolak" 403 \
    "$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://$BUCKET.s3.amazonaws.com/loans/$ID.json")"
  request "Hapus data" 200 DELETE "/loans/$ID"
  request "Data terhapus" 404 GET "/loans/$ID"
}

# Pengujian persistence
run_persist() {
  create_sample
  echo
  echo "Memperbarui konfigurasi Lambda"
  set_env "$BUCKET" || exit 1
  request "Data tetap ada" 200 GET "/loans/$ID"
  echo
  aws s3 ls "s3://$BUCKET/loans/"
}

# Pengujian failure dan recovery
run_failure() {
  request "Kondisi normal" 200 GET /loans
  local start=$(($(date +%s) * 1000))
  trap 'set_env "$BUCKET"' EXIT
  echo
  echo "Mengganti nama bucket menjadi salah"
  set_env "bucket-salah-$BUCKET" || exit 1
  request "Terjadi kegagalan" 500 GET /loans
  echo
  echo "Log CloudWatch"
  sleep 15
  aws logs filter-log-events --log-group-name "/aws/lambda/$FUNCTION" \
    --start-time "$start" --filter-pattern ERROR \
    --query 'events[].message' --output text | head -n 15
  echo
  echo "Memulihkan konfigurasi"
  set_env "$BUCKET" || exit 1
  trap - EXIT
  request "Pulih" 200 GET /loans
}

echo "Pengujian: $MODE"
echo "Waktu: $(date)"
echo "API: $API_URL"
"run_$MODE"

echo
echo "Jumlah gagal: $FAILED"
echo "Log: $LOG"
[[ "$FAILED" -eq 0 ]]
