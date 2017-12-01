#!/bin/bash

# The following environment variables MUST be set:
# SDC_VERSION - e.g. 2.7.2.0
# DPM_USER - e.g. admin@example.com
# DPM_PASSWORD
# PIPELINE_COMMIT_ID
#
# The following environment variables are optional:
# DPM_URL - defaults to https://cloud.streamsets.com/
# DPM_ORG - retrieved via API

set -e

start_sdc() {
    local sdc_dist=$1
    shift

    # Currently required to run on OpenJDK
    export SDC_ALLOW_UNSUPPORTED_JDK=true

    # Required for Heroku free dynos
    FDS=$(ulimit -n)
    if [ $((${FDS} < 32768)) ]; then
        export SDC_FILE_LIMIT=$((${FDS}-1))
    fi

    echo "Starting SDC"
    "${sdc_dist}/bin/streamsets" "$@" &
}

# Wait until our label shows up in the list of registered SDC labels
wait_for_sdc_label() {
    local dpm_url=$1
    local session_token=$2
    local dpm_label=$3

    echo "Waiting for ${dpm_label} to show on DPM"
    while [ -z "${label}" ]; do
        local label=$(curl -s -X GET \
            ${dpm_url}jobrunner/rest/v1/sdcs/labels \
            -H "Content-Type:application/json" \
            -H "X-Requested-By:SDC" \
            -H "X-SS-REST-CALL:true" -H \
            "X-SS-User-Auth-Token:${session_token}" | jq -r ".[] | select(. | contains(\"${dpm_label}\"))")
    done
}

wait_for_sdc_start() {
    echo "Waiting for SDC to start"
    local port=$1
    while ! nc -q 1 localhost ${port} </dev/null; do sleep 2; done    
}

wait_for_sdc_exit() {
    echo "Waiting for SDC to terminate"
    local port=$1
    while nc -q 1 localhost ${port} </dev/null; do sleep 2; done    
}

# Adapted from http://wp.vpalos.com/537/uri-parsing-using-bash-built-in-features/
uri_parser() {
    # uri capture
    uri="$@"

    # safe escaping
    uri="${uri//\`/%60}"
    uri="${uri//\"/%22}"

    # top level parsing
    pattern='^(([a-z]*)://)?((([^:\/]+)(:([^@\/]*))?@)?([^:\/?]+)(:([0-9]+))?)(\/[^?]*)?(\?[^#]*)?(#.*)?$'
    [[ "$uri" =~ $pattern ]] || return 1;

    # component extraction
    uri=${BASH_REMATCH[0]}
    uri_schema=${BASH_REMATCH[2]}
    uri_address=${BASH_REMATCH[3]}
    uri_user=${BASH_REMATCH[5]}
    uri_password=${BASH_REMATCH[7]}
    uri_host=${BASH_REMATCH[8]}
    uri_port=${BASH_REMATCH[10]}
    uri_path=${BASH_REMATCH[11]}
    uri_query=${BASH_REMATCH[12]}
    uri_fragment=${BASH_REMATCH[13]}

    # path parsing
    count=0
    path="$uri_path"
    pattern='^/+([^/]+)'
    while [[ $path =~ $pattern ]]; do
        eval "uri_parts[$count]=\"${BASH_REMATCH[1]}\""
        path="${path:${#BASH_REMATCH[0]}}"
        let count++
    done

    # query parsing
    count=0
    query="$uri_query"
    pattern='^[?&]+([^= ]+)(=([^&]*))?'
    while [[ $query =~ $pattern ]]; do
        eval "uri_args[$count]=\"${BASH_REMATCH[1]}\""
        eval "uri_arg_${BASH_REMATCH[1]}=\"${BASH_REMATCH[3]}\""
        query="${query:${#BASH_REMATCH[0]}}"
        let count++
    done

    # return success
    return 0
}

if [ -z "${SDC_VERSION}" ]; then
    echo "SDC_VERSION must be set. Exiting..."
    exit 1
fi

if [ -z "${DPM_USER}" ]; then
    echo "DPM_USER must be set. Exiting..."
    exit 1
fi

if [ -z "${DPM_PASSWORD}" ]; then
    echo "DPM_PASSWORD must be set. Exiting..."
    exit 1
fi

if [ -z "${PIPELINE_COMMIT_ID}" ]; then
    echo "PIPELINE_COMMIT_ID must be set. Exiting..."
    exit 1
fi

if [ -z "${DATABASE_URL}" ]; then
    echo "DATABASE_URL must be set. Exiting..."
    exit 1
fi

# Command inside uri_parser return non-zero - don't exit the shell!
set +e
uri_parser "${DATABASE_URL}"
set -e

JDBC_USERNAME=$uri_user
JDBC_PASSWORD=$uri_password
JDBC_URL="jdbc:postgresql://${uri_host}:${uri_port}${uri_path}?sslmode=require"
JDBC_TABLENAME=staging
JDBC_SCHEMA=public

DPM_URL=${DPM_URL:-https://cloud.streamsets.com/}

if [ "${DPM_URL: -1}" != "/" ]; then
    DPM_URL=${DPM_URL}/
fi

# Need to munge RC version
if [[ ${SDC_VERSION} == *-RC* ]]; then
    SDC_VERSION=${SDC_VERSION:0:7}
fi

SDC_DIST=${HOME}/streamsets-datacollector-${SDC_VERSION}
SDC_CONF=${SDC_DIST}/etc

# Generate unique DPM_LABEL
DPM_LABEL=$(cat /proc/sys/kernel/random/uuid)

echo "Using DPM label ${DPM_LABEL}"

# Get session token
SESSION_TOKEN=$(curl -s -X POST -d "{\"userName\":\"${DPM_USER}\", \"password\": \"${DPM_PASSWORD}\"}" \
    ${DPM_URL}security/public-rest/v1/authentication/login \
    -H "Content-Type:application/json" -H "X-Requested-By:SDC" \
    -c - | grep SSO | grep -o '\S*$')

if [ -z "${DPM_ORG}" ]; then
    DPM_ORG=$(curl -s -X GET \
        ${DPM_URL}security/rest/v1/organizations \
        -H "Content-Type:application/json" -H "X-Requested-By:SDC" -H "X-SS-REST-CALL:true" \
        -H "X-SS-User-Auth-Token:${SESSION_TOKEN}" | jq -r .[0].id)
fi

AUTH_TOKEN=$(curl -s -X PUT \
    -d "{\"organization\": \"${DPM_ORG}\", \
         \"componentType\": \"dc\", \
         \"numberOfComponents\" : 1, \
         \"active\" : true}" \
    ${DPM_URL}security/rest/v1/organization/${DPM_ORG}/components \
    -H "Content-Type:application/json" -H "X-Requested-By:SDC" -H "X-SS-REST-CALL:true" \
    -H "X-SS-User-Auth-Token:${SESSION_TOKEN}" | jq -r .[0].fullAuthToken)

echo "${AUTH_TOKEN}" > "${SDC_CONF}/application-token.txt"
sed -i "s|dpm.enabled=.*|dpm.enabled=true|" ${SDC_CONF}/dpm.properties
sed -i "s|dpm.base.url=.*|dpm.base.url=${DPM_URL}|" ${SDC_CONF}/dpm.properties
sed -i "s|dpm.remote.control.job.labels=.*|dpm.remote.control.job.labels=${DPM_LABEL}|" ${SDC_CONF}/dpm.properties

start_sdc $SDC_DIST "$@"

PIPELINE_COMMIT=$(curl -s -X GET \
    ${DPM_URL}pipelinestore/rest/v1/pipelineCommit/${PIPELINE_COMMIT_ID} \
    -H "Content-Type:application/json" -H "X-Requested-By:SDC" -H "X-SS-REST-CALL:true" \
    -H "X-SS-User-Auth-Token:${SESSION_TOKEN}")
PIPELINE_ID=$(echo ${PIPELINE_COMMIT} | jq -r .pipelineId)
PIPELINE_NAME=$(echo ${PIPELINE_COMMIT} | jq -r .name)
RULES_ID=$(echo ${PIPELINE_COMMIT} | jq -r .currentRules.id)
PIPELINE_COMMIT_LABEL=v$(echo ${PIPELINE_COMMIT} | jq -r .version)

# Create a job
JOB_ID=$(curl -s -X PUT \
    -d "{\"name\": \"${DPM_LABEL}\", \
         \"description\": \"Automatically created\", \
         \"pipelineName\" : \"${PIPELINE_NAME}\", \
         \"pipelineId\" : \"${PIPELINE_ID}\", \
         \"pipelineCommitId\" : \"${PIPELINE_COMMIT_ID}\", \
         \"rulesId\" : \"${RULES_ID}\", \
         \"pipelineCommitLabel\" : \"${PIPELINE_COMMIT_LABEL}\", \
         \"labels\" : [\"${DPM_LABEL}\"], \
         \"statsRefreshInterval\": 10000, \
         \"numInstances\" : 1, \
         \"migrateOffsets\" : true, \
         \"runtimeParameters\": \
           \"{ \
           \\\"AWS_KEY\\\" : \\\"${AWS_KEY}\\\", \
           \\\"AWS_SECRET\\\" : \\\"${AWS_SECRET}\\\", \
           \\\"AWS_BUCKET\\\" : \\\"${AWS_BUCKET}\\\", \
           \\\"JDBC_USERNAME\\\" : \\\"${JDBC_USERNAME}\\\", \
           \\\"JDBC_PASSWORD\\\" : \\\"${JDBC_PASSWORD}\\\", \
           \\\"JDBC_URL\\\" : \\\"${JDBC_URL}\\\", \
           \\\"JDBC_SCHEMA\\\" : \\\"${JDBC_SCHEMA}\\\", \
           \\\"JDBC_TABLENAME\\\" : \\\"${JDBC_TABLENAME}\\\" \
         }\", \
         \"edge\" : false}" \
    ${DPM_URL}jobrunner/rest/v1/jobs \
    -H "Content-Type:application/json" -H "X-Requested-By:SDC" -H "X-SS-REST-CALL:true" \
    -H "X-SS-User-Auth-Token:${SESSION_TOKEN}" | jq -r .id)

wait_for_sdc_start ${PORT}

wait_for_sdc_label ${DPM_URL} ${SESSION_TOKEN} ${DPM_LABEL}

# Start the job
JOB_STARTED=$(curl -s -X POST \
    ${DPM_URL}jobrunner/rest/v1/job/${JOB_ID}/start \
    -H "Content-Type:application/json" -H "X-Requested-By:SDC" -H "X-SS-REST-CALL:true" \
    -H "X-SS-User-Auth-Token:${SESSION_TOKEN}")
JOB_ID=$(echo ${JOB_STARTED} | jq -r .jobId)
JOB_STATUS=$(echo ${JOB_STARTED} | jq -r .status)

echo "Job ${JOB_ID} status is ${JOB_STATUS}"

wait_for_sdc_exit ${PORT}