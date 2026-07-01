#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="casdoor"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_NAMESPACE="casdoor"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_SERVICE_TYPE="ClusterIP"
DEFAULT_HTTP_ADDR="0.0.0.0"

ACTION="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi

REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
NAMESPACE="${DEFAULT_NAMESPACE}"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVICE_TYPE="${DEFAULT_SERVICE_TYPE}"
NODEPORT_HTTP=""
SKIP_IMAGE_PREPARE=0
YES=0
DELETE_NAMESPACE=0
CREATE_DATABASE="true"
DB_DRIVER="mysql"
DATA_SOURCE_NAME=""
DB_NAME="casdoor"
HTTP_ADDR="${DEFAULT_HTTP_ADDR}"
ORIGIN=""
ORIGIN_FRONTEND=""
STATIC_BASE_URL=""
RUNMODE="prod"
IMAGE_PULL_POLICY="IfNotPresent"
LOG_LEVEL="info"
WORKDIR=""
IMAGE_INDEX=""

usage() {
  cat <<USAGE
Usage:
  ./casdoor-<version>-<arch>.run install [options]
  ./casdoor-<version>-<arch>.run status [options]
  ./casdoor-<version>-<arch>.run uninstall [options]
  ./casdoor-<version>-<arch>.run help

Actions:
  install      Extract payload, load/tag/push image, render app.conf and Kubernetes manifests, and install Casdoor.
  status       Show Casdoor resources.
  uninstall    Delete Casdoor resources. Namespace is kept unless --delete-namespace is set.
  help         Show this help.

Options:
  --registry <repo-prefix>           Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>             Registry username for docker login.
  --registry-pass <pass>             Registry password for docker login.
  --skip-image-prepare               Skip docker load/tag/push; still render image to --registry prefix.
  -n, --namespace <namespace>        Kubernetes namespace. Default: ${DEFAULT_NAMESPACE}
  --db-driver <mysql|postgres>       Casdoor database driver. Default: mysql
  --data-source-name <dsn>           Casdoor dataSourceName, without dbName for MySQL-style config.
  --db-name <name>                   Casdoor dbName. Default: casdoor
  --http-addr <addr>                 Casdoor listen address in container. Default: ${DEFAULT_HTTP_ADDR}
  --create-database <true|false>     Run server with --createDatabase flag. Default: true
  --origin <url>                     Casdoor backend public origin, for example https://casdoor.example.com
  --origin-frontend <url>            Optional frontend origin.
  --static-base-url <url>            Optional static asset base URL. Empty means use bundled frontend assets.
  --runmode <dev|prod>               Casdoor runmode. Default: prod
  --service-type <type>              ClusterIP, NodePort, or LoadBalancer. Default: ClusterIP
  --nodeport-http <port>             Optional NodePort for HTTP port 8000.
  --image-pull-policy <policy>       IfNotPresent, Always, or Never. Default: IfNotPresent
  --wait-timeout <duration>          Wait timeout. Default: ${DEFAULT_WAIT_TIMEOUT}
  --delete-namespace                 During uninstall, also delete namespace.
  -y, --yes                          Do not ask for confirmation.
  -h, --help                         Show this help.

Example MySQL:
  ./casdoor-2026.07.01-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'passw0rd' \
    -n casdoor \
    --db-driver mysql \
    --data-source-name 'root:password@tcp(mysql.default.svc.cluster.local:3306)/' \
    --db-name casdoor \
    --http-addr 0.0.0.0 \
    --origin 'https://casdoor.example.com' \
    -y

Example PostgreSQL:
  ./casdoor-2026.07.01-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    -n casdoor \
    --db-driver postgres \
    --data-source-name 'user=postgres password=password host=postgres.default.svc.cluster.local port=5432 sslmode=disable' \
    --db-name casdoor \
    --http-addr 0.0.0.0 \
    --origin 'https://casdoor.example.com' \
    -y
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
    --registry-pass|--registry-password) REGISTRY_PASS="${2:-}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGE_PREPARE=1; shift ;;
    -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --db-driver) DB_DRIVER="${2:-}"; shift 2 ;;
    --data-source-name) DATA_SOURCE_NAME="${2:-}"; shift 2 ;;
    --db-name) DB_NAME="${2:-}"; shift 2 ;;
    --http-addr) HTTP_ADDR="${2:-}"; shift 2 ;;
    --create-database) CREATE_DATABASE="${2:-}"; shift 2 ;;
    --origin) ORIGIN="${2:-}"; shift 2 ;;
    --origin-frontend) ORIGIN_FRONTEND="${2:-}"; shift 2 ;;
    --static-base-url) STATIC_BASE_URL="${2:-}"; shift 2 ;;
    --runmode) RUNMODE="${2:-}"; shift 2 ;;
    --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
    --nodeport-http) NODEPORT_HTTP="${2:-}"; shift 2 ;;
    --image-pull-policy) IMAGE_PULL_POLICY="${2:-}"; shift 2 ;;
    --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
    --delete-namespace) DELETE_NAMESPACE=1; shift ;;
    -y|--yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${ACTION}" in install|status|uninstall|help) ;; *) die "unknown action: ${ACTION}" ;; esac
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

[[ -n "${REGISTRY}" ]] || die "--registry cannot be empty"
[[ -n "${NAMESPACE}" ]] || die "--namespace cannot be empty"
[[ -n "${DB_NAME}" ]] || die "--db-name cannot be empty"
[[ -n "${HTTP_ADDR}" ]] || die "--http-addr cannot be empty"
case "${DB_DRIVER}" in mysql|postgres|sqlite3|mssql|oracle) ;; *) die "unsupported --db-driver: ${DB_DRIVER}" ;; esac
case "${SERVICE_TYPE}" in ClusterIP|NodePort|LoadBalancer) ;; *) die "--service-type must be ClusterIP, NodePort, or LoadBalancer" ;; esac
case "${CREATE_DATABASE}" in true|false) ;; *) die "--create-database must be true or false" ;; esac
if [[ -n "${NODEPORT_HTTP}" && "${SERVICE_TYPE}" != "NodePort" ]]; then die "--nodeport-http requires --service-type NodePort"; fi
if [[ "${ACTION}" == "install" ]]; then
  [[ -n "${DATA_SOURCE_NAME}" ]] || die "--data-source-name is required"
fi

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  WORKDIR="$(mktemp -d -t ${PACKAGE_NAME}.XXXXXX)"
  IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
  trap 'rm -rf "${WORKDIR:-}"' EXIT
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "payload missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/casdoor.yaml.tmpl" ]] || die "payload missing manifests/casdoor.yaml.tmpl"
}

confirm() {
  [[ "${YES}" == "1" ]] && return 0
  echo "About to ${ACTION} Casdoor in namespace '${NAMESPACE}'."
  if [[ "${ACTION}" == "install" ]]; then
    echo "db-driver=${DB_DRIVER}, db-name=${DB_NAME}, http-addr=${HTTP_ADDR}, create-database=${CREATE_DATABASE}, service-type=${SERVICE_TYPE}"
  fi
  read -r -p "Continue? [y/N] " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "aborted"
}

retarget_image() {
  local default_ref="$1"
  local suffix
  if [[ "${default_ref}" == sealos.hub:5000/kube4/* ]]; then
    suffix="${default_ref#sealos.hub:5000/kube4/}"
  else
    suffix="${default_ref#*/}"
  fi
  printf '%s/%s\n' "${REGISTRY%/}" "${suffix}"
}

image_ref_by_name() {
  local wanted="$1"
  awk -F'|' -v name="${wanted}" 'NR > 1 && $1 == name { print $4; exit }' "${IMAGE_INDEX}"
}

target_ref_by_name() {
  local wanted="$1" default_ref
  default_ref="$(image_ref_by_name "${wanted}")"
  [[ -n "${default_ref}" ]] || die "image not found in index: ${wanted}"
  retarget_image "${default_ref}"
}

prepare_images() {
  [[ "${SKIP_IMAGE_PREPARE}" == "1" ]] && { info "skip image prepare"; return 0; }
  need docker

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "both --registry-user and --registry-pass are required for docker login"
    local login_host="${REGISTRY%%/*}"
    info "docker login ${login_host}"
    printf '%s' "${REGISTRY_PASS}" | docker login "${login_host}" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name load_ref default_ref platform pull dockerfile; do
    [[ -n "${name}" ]] || continue
    local tar_path="${WORKDIR}/images/${tar_name}"
    local target_ref
    [[ -f "${tar_path}" ]] || die "image tar not found: ${tar_path}"
    target_ref="$(retarget_image "${default_ref}")"
    info "docker load ${tar_name}"
    docker load -i "${tar_path}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      info "docker tag ${load_ref} ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    info "docker push ${target_ref}"
    docker push "${target_ref}"
  done
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

render_app_conf_b64() {
  local static_base_url="${STATIC_BASE_URL}"
  if [[ -z "${static_base_url}" ]]; then
    static_base_url=""
  fi
  cat <<CONF | base64 | tr -d '\n'
appname = casdoor
httpaddr = ${HTTP_ADDR}
httpport = 8000
runmode = ${RUNMODE}
copyrequestbody = true
driverName = ${DB_DRIVER}
dataSourceName = ${DATA_SOURCE_NAME}
dbName = ${DB_NAME}
tableNamePrefix =
showSql = false
redisEndpoint =
defaultStorageProvider =
isCloudIntranet = false
authState = "casdoor"
socks5Proxy =
verificationCodeTimeout = 10
initScore = 0
logPostOnly = true
isUsernameLowered = false
origin = ${ORIGIN}
originFrontend = ${ORIGIN_FRONTEND}
staticBaseUrl = ${static_base_url}
isDemoMode = false
batchSize = 100
showGithubCorner = false
forceLanguage = ""
defaultLanguage = "en"
aiAssistantUrl = ""
defaultApplication = "app-built-in"
maxItemsForFlatMenu = 7
enableErrorMask = false
enableGzip = true
inactiveTimeoutMinutes =
ldapServerPort = 389
ldapsCertId = ""
ldapsServerPort = 636
radiusServerPort = 1812
radiusDefaultOrganization = "built-in"
radiusSecret = "secret"
quota = {"organization": -1, "user": -1, "application": -1, "provider": -1}
logConfig = {"adapter":"console"}
initDataNewOnly = false
initDataFile = "./init_data.json"
frontendBaseDir = "./web/build"
CONF
}

render_manifest() {
  local casdoor_image rendered app_conf_b64 nodeport_http_line create_database_arg
  casdoor_image="$(target_ref_by_name casdoor)"
  rendered="${WORKDIR}/rendered-casdoor.yaml"
  app_conf_b64="$(render_app_conf_b64)"
  nodeport_http_line=""
  create_database_arg="--createDatabase=${CREATE_DATABASE}"
  if [[ -n "${NODEPORT_HTTP}" ]]; then nodeport_http_line="    nodePort: ${NODEPORT_HTTP}"; fi

  awk \
    -v ns="${NAMESPACE}" \
    -v image="${casdoor_image}" \
    -v image_pull_policy="${IMAGE_PULL_POLICY}" \
    -v service_type="${SERVICE_TYPE}" \
    -v nodeport_http_line="${nodeport_http_line}" \
    -v app_conf_b64="${app_conf_b64}" \
    -v create_database_arg="${create_database_arg}" \
    '
      /__NODEPORT_HTTP_LINE__/ { if (nodeport_http_line != "") print nodeport_http_line; next }
      {
        gsub(/__NAMESPACE__/, ns)
        gsub(/__CASDOOR_IMAGE__/, image)
        gsub(/__IMAGE_PULL_POLICY__/, image_pull_policy)
        gsub(/__SERVICE_TYPE__/, service_type)
        gsub(/__APP_CONF_B64__/, app_conf_b64)
        gsub(/__CREATE_DATABASE_ARG__/, create_database_arg)
        print
      }
    ' "${WORKDIR}/manifests/casdoor.yaml.tmpl" > "${rendered}"

  printf '%s\n' "${rendered}"
}

install_app() {
  need kubectl
  need base64
  extract_payload
  confirm
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  info "kubectl apply -f rendered manifest"
  kubectl apply -f "${rendered}"
  info "waiting for deployment/casdoor"
  kubectl rollout status deployment/casdoor -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  status_app
}

status_app() {
  need kubectl
  echo "Namespace: ${NAMESPACE}"
  kubectl get pods,svc,deploy,secret -n "${NAMESPACE}" -l app.kubernetes.io/name=casdoor || true
}

uninstall_app() {
  need kubectl
  extract_payload
  confirm
  local rendered
  rendered="$(render_manifest)"
  info "kubectl delete -f rendered manifest"
  kubectl delete -f "${rendered}" --ignore-not-found=true || true
  if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
    info "delete namespace ${NAMESPACE}"
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true || true
  else
    info "namespace kept: ${NAMESPACE}"
  fi
}

case "${ACTION}" in
  install) install_app ;;
  status) status_app ;;
  uninstall) uninstall_app ;;
esac

exit 0
__PAYLOAD_BELOW__
