#!/usr/bin/env bash
set -euo pipefail

# 1. Fill these in or export them before running the script
SD_EMAIL="${SD_EMAIL:-tojaigupta@gmail.com}"
SD_PASSWORD="${SD_PASSWORD:-czq@ctc6rhr2TGE_unv}"

if [[ "$SD_EMAIL" == "you@example.com" || "$SD_PASSWORD" == "your-password-here" ]]; then
  echo "Set SD_EMAIL and SD_PASSWORD first (export SD_EMAIL=...; export SD_PASSWORD=...)."
  exit 1
fi

# 2. Generate a unique job name
SD_JOBNAME=$(date +%F-%H%M%S)

echo "Logging in as $SD_EMAIL..."

SD_LOGIN=$(cat <<EOF
{
  "email":"$SD_EMAIL",
  "password":"$SD_PASSWORD"
}
EOF
)

# 3. Log in and get bearer token
TOKEN=$(
  curl -sS --location 'https://api.silicondata.com/api/user/login' \
    --header 'Content-Type: application/json' \
    --data-raw "$SD_LOGIN" \
  | jq -r '.data.id_token // .id_token'
)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Failed to obtain auth token. Check email/password."
  exit 1
fi

echo "Got auth token."

# 4. Create a new SiliconMark job
SD_JOBDATA=$(cat <<EOF
{
  "name": "$SD_JOBNAME",
  "benchmarks": ["quick_mark"],
  "node_count": 1,
  "description": "Job created by $SD_EMAIL"
}
EOF
)

echo "Creating SiliconMark job '$SD_JOBNAME'..."

curl -sS --location 'https://api.silicondata.com/api/silicon-mark/v1/jobs' \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $TOKEN" \
  --data "$SD_JOBDATA" > job.json

# 5. Extract Job ID and Job Token (API key for the agent)
JOB_TOKEN=$(jq -r '.data.token // .token' job.json)
JOB_ID=$(jq -r '.data.id // .id' job.json)

if [[ -z "$JOB_TOKEN" || "$JOB_TOKEN" == "null" ]]; then
  echo "Failed to extract job token from job.json:"
  cat job.json
  exit 1
fi

echo "Job created."
echo "Job ID:       $JOB_ID"
echo "Agent API key: $JOB_TOKEN"
echo
echo "Run the agent with:"
echo "  ./agent -api-key $JOB_TOKEN"

# Optional helper to download agent
# wget -O ./agent https://downloads.silicondata.com/agent
# chmod +x ./agent
# ./agent -api-key "$JOB_TOKEN"
