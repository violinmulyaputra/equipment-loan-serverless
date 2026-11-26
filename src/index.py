import base64
import json
import logging
import os
import re
import uuid
from datetime import date

import boto3
from botocore.exceptions import ClientError

# Konfigurasi
s3 = boto3.client("s3")
logger = logging.getLogger()
logger.setLevel(logging.INFO)

PREFIX = "loans/"
FIELDS = ("borrower_name", "equipment_name", "loan_date", "due_date", "status")
STATUSES = ("dipinjam", "dikembalikan")


# Respons
def respond(status, body):
    return {
        "statusCode": status,
        "isBase64Encoded": False,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


# Validasi
def parse_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("Body harus berupa objek JSON")
    unknown = set(data) - set(FIELDS)
    if unknown:
        raise ValueError("Kolom tidak dikenal: " + ", ".join(sorted(unknown)))
    return data


def validate(loan):
    for field in FIELDS:
        value = loan.get(field)
        if not isinstance(value, str) or not value.strip() or len(value) > 100:
            raise ValueError(f"{field} wajib diisi, berupa teks maksimal 100 karakter")
    for field in ("loan_date", "due_date"):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", loan[field]):
            raise ValueError(f"{field} harus berformat YYYY-MM-DD")
        date.fromisoformat(loan[field])
    if loan["due_date"] < loan["loan_date"]:
        raise ValueError("due_date tidak boleh sebelum loan_date")
    if loan["status"] not in STATUSES:
        raise ValueError("status harus salah satu dari: " + ", ".join(STATUSES))


# Penyimpanan
def bucket():
    return os.environ["BUCKET_NAME"]


def key_of(loan_id):
    return f"{PREFIX}{loan_id}.json"


def read_key(key):
    obj = s3.get_object(Bucket=bucket(), Key=key)
    return json.loads(obj["Body"].read())


def find_loan(loan_id):
    try:
        return read_key(key_of(loan_id))
    except ClientError as error:
        if error.response["Error"]["Code"] == "NoSuchKey":
            return None
        raise


def save_loan(loan):
    s3.put_object(
        Bucket=bucket(),
        Key=key_of(loan["id"]),
        Body=json.dumps(loan).encode("utf-8"),
        ContentType="application/json",
    )


def all_loans():
    loans = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket(), Prefix=PREFIX):
        for item in page.get("Contents", []):
            loans.append(read_key(item["Key"]))
    return sorted(loans, key=lambda loan: (loan["loan_date"], loan["id"]))


# Endpoint
def collection(method, event):
    if method == "GET":
        return respond(200, all_loans())
    if method == "POST":
        data = {"status": "dipinjam", **parse_body(event)}
        validate(data)
        loan = {"id": str(uuid.uuid4()), **data}
        save_loan(loan)
        return respond(201, loan)
    return respond(405, {"message": "Method tidak diizinkan"})


def single(method, loan_id, event):
    if method not in ("GET", "PUT", "DELETE"):
        return respond(405, {"message": "Method tidak diizinkan"})
    loan = find_loan(loan_id)
    if loan is None:
        return respond(404, {"message": "Data tidak ditemukan"})
    if method == "GET":
        return respond(200, loan)
    if method == "PUT":
        updated = {**loan, **parse_body(event)}
        validate(updated)
        save_loan(updated)
        return respond(200, updated)
    s3.delete_object(Bucket=bucket(), Key=key_of(loan_id))
    return respond(200, {"message": "Data dihapus", "id": loan_id})


# Handler
def handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "/").rstrip("/") or "/"
    logger.info("%s %s", method, path)
    try:
        if path == "/health" and method == "GET":
            return respond(200, {"status": "ok"})
        if path == "/loans":
            return collection(method, event)
        match = re.fullmatch(r"/loans/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})", path)
        if match:
            return single(method, match.group(1), event)
        return respond(404, {"message": "Route tidak ditemukan"})
    except ValueError as error:
        return respond(400, {"message": str(error)})
    except Exception:
        logger.exception("Request gagal")
        return respond(500, {"message": "Terjadi kesalahan pada server"})
