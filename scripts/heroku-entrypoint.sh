#!/bin/bash

# The following environment variables MUST be set:
# SDC_VERSION - e.g. 2.7.2.0
# DPM_USER - e.g. admin@example.com
# DPM_PASSWORD
#
# The following environment variables are optional:
# DPM_URL - defaults to https://cloud.streamsets.com/
# DPM_ORG - retrieved via API

set -e

DPM_URL=${DPM_URL:-https://cloud.streamsets.com/}

if [ "${DPM_URL: -1}" != "/" ]; then
    DPM_URL=${DPM_URL}/
fi

SDC_DIST=${HOME}/streamsets-datacollector-${SDC_VERSION}
SDC_CONF=${SDC_DIST}/etc

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
sed -i "s|dpm.base.url=.*|dpm.base.url=${URL}|" ${SDC_CONF}/dpm.properties
sed -i "s|dpm.remote.control.job.labels=.*|dpm.remote.control.job.labels=${LABELS}|" ${SDC_CONF}/dpm.properties

exec "${SDC_DIST}/bin/streamsets" "$@"