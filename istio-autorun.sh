#!/bin/bash
#
# Prerequisite:
#   1. The host running this script can access the K8s cluster with 'kubectl'.
#   2. The 'istioctl' client program is executable from $PATH.
#   3. No pods deployed in the namespace that will auto inject Envoy proxies.
#   4. Fortio and k6 load testing tools are installed.
#

function usage {
    printf '
Usage: %s [OPTION]... [APP]...
    Istio options:
        -f configuration    Istio configuration file
        -k                  Keep installed resources
        -p uri              Virtual service URI to match
        -s                  Use HTTPS scheme on gateway
    Fortio options:
        -c connection       Number of connections (default %d)
        -F string           Parameters passed to Fortio
    k6 options:
        -u vus              Number of virtual users (default 0: skip k6)
        -K string           Parameters passed to Grafana k6

Note: the Istio BookInfo sample app will be deployed if no APP is specified.\n' "$0" "$FORTIO_CONN"
}

KCTL='kubectl'
ISCTL='istioctl'
ISPROFILE='default'
ISAUTOINJECTNS='default'
EBPF_BYPASS_YAML='https://raw.githubusercontent.com/intel/istio-tcpip-bypass/main/bypass-tcpip-daemonset.yaml'
BOOKINFO_WL='https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml'
BOOKINFO_GW='https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/networking/bookinfo-gateway.yaml'

# Istio
CUSTOM_CONFIG=''
INGRESS_HOST=''
INGRESS_PORT=''
SECURE_INGRESS_PORT=''
VIRTUALSERVICE_MATCH_URI=''

# Fortio
FORTIO_CONN=$(("$(nproc)" * 4))
FORTIO_PARAMS=''

# Grafana k6
K6_VUSER=0
K6_PARAMS=''

# void run_command (string command)
function run_command {
    if [ -n "$1" ]; then
        echo "$1"
        eval "$1"
    fi
    printf '\n'
}

# void update_istio_ingress_url (void)
function update_istio_ingress_url {
    INGRESS_HOST="$($KCTL -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    if [ -n "$INGRESS_HOST" ]; then
        # Support external load balancers
        INGRESS_PORT="$($KCTL -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')"
        SECURE_INGRESS_PORT="$($KCTL -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')"
    else
        # Need to access the gateway using the node port
        INGRESS_HOST="$($KCTL -n istio-system get pod -l istio=ingressgateway -o jsonpath='{.items[0].status.hostIP}')"
        INGRESS_PORT="$($KCTL -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')"
        SECURE_INGRESS_PORT="$($KCTL -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')"
    fi
    printf 'Ingress gateway URLs:\n\thttp://%s:%s\n\thttps://%s:%s\n' \
           "$INGRESS_HOST" "$INGRESS_PORT" "$INGRESS_HOST" "$SECURE_INGRESS_PORT"
}

# void install_istio (string configuration)
function install_istio {
    printf 'Installing Istio ...\n'
    local flag="--set profile=$ISPROFILE"
    # Install using the provided CR, otherwise using the preset profile
    if [[ -n "$1" && -f "$1" ]]; then
        flag="-f $1"
    fi
    run_command "$ISCTL install -y $flag"
    # Label namespace for auto inject Envoy sidecar proxies
    printf "Auto inject Envoy sidecar proxies in '%s' namespace ...\n" "$ISAUTOINJECTNS"
    run_command "$KCTL label namespace $ISAUTOINJECTNS istio-injection=enabled"
    update_istio_ingress_url
}

# void uninstall_istio (void)
function uninstall_istio {
    printf 'Uninstalling Istio ...\n'
    run_command "$ISCTL uninstall -y --purge"
    printf 'Removing the label for sidecar proxies auto-injection ...\n'
    run_command "$KCTL label namespace $ISAUTOINJECTNS istio-injection-"
    printf 'Removing the Istio namespace ...\n'
    run_command "$KCTL delete namespace istio-system"
}

# void load_eBPF_program (void)
function load_eBPF_program {
    local yaml=${EBPF_BYPASS_YAML##*/}
    # Use the local eBPF bypass yaml file if present
    if [ -f "$yaml" ]; then
        EBPF_BYPASS_YAML="$yaml"
    fi
    printf 'Loading the eBPF program via setting up a deamonset ...\n'
    run_command "$KCTL apply -f $EBPF_BYPASS_YAML"
}

# void unload_eBPF_program (void)
function unload_eBPF_program {
    local yaml=${EBPF_BYPASS_YAML##*/}
    # Use the local eBPF bypass yaml file if present
    if [ -f "$yaml" ]; then
        EBPF_BYPASS_YAML="$yaml"
    fi
    printf 'Unloading the eBPF TCP/IP bypass daemonset ...\n'
    run_command "$KCTL delete -f $EBPF_BYPASS_YAML"
}

# void wait_pods_and_sidecars_become_ready (void)
function wait_pods_and_sidecars_become_ready {
    local ready=false
    until [ $ready = true ]; do
        sleep 1
        local str=()
        mapfile -t str < <(eval "$KCTL get pod --no-headers -n $ISAUTOINJECTNS")
        for i in "${str[@]}"; do
            local n r s unused
            read -r n r s unused < <(echo "$i")
            [[ "$r" = '2/2' && "$s" = 'Running' ]] || continue 2
        done
        ready=true
    done
}

# void deploy_sample_apps (string[] apps)
function deploy_sample_apps {
    for r in "$@"; do
        printf 'Deploying resource %s ...\n' "$r"
        run_command "$KCTL apply -f $r"
    done
    printf "Waiting until all pods report READY '2/2' and STATUS 'Running' ..."
    wait_pods_and_sidecars_become_ready
    printf '\n\n'
}

# void delete_sample_apps (string[] apps)
function delete_sample_apps {
    local r resources=("$@")
    # Delete the deployed resources in reverse order
    for (( i="${#resources[@]}-1"; i>=0; i-- )); do
        r="${resources[$i]}"
        printf 'Deleting resource %s ...\n' "$r"
        run_command "$KCTL delete -f $r"
    done
}

# void run_fortio (string url)
function run_fortio {
    if [ -n "$1" ]; then
        run_command "fortio load -c $FORTIO_CONN $FORTIO_PARAMS $1"
    fi
}

# void run_k6 (string url)
function run_k6 {
    if [ -n "$1" ]; then
        run_command "sed \"s|<URL>|$1|\" k6.js.template | k6 run --vus $K6_VUSER $K6_PARAMS -"
    fi
}

# void main (string[] arg)
keep_installed_resources=false
use_https_scheme=false
while getopts 'f:kp:sc:F:u:K:' opt; do
    case "$opt" in
    f)  CUSTOM_CONFIG="${OPTARG}"
        ;;
    k)  keep_installed_resources=true
        ;;
    p)  VIRTUALSERVICE_MATCH_URI="${OPTARG}"
        ;;
    s)  use_https_scheme=true
        ;;
    c)  FORTIO_CONN="${OPTARG}"
        ;;
    F)  FORTIO_PARAMS="${OPTARG}"
        ;;
    u)  K6_VUSER="${OPTARG}"
        ;;
    K)  K6_PARAMS="${OPTARG}"
        ;;
    \?|:)
        usage
        exit
        ;;
    esac
done
shift "$((OPTIND - 1))"

[ "${#@}" = 0 ] && apps=("$BOOKINFO_WL" "$BOOKINFO_GW") || apps=("$@")

install_istio "$CUSTOM_CONFIG"
deploy_sample_apps "${apps[@]}"

if [ $use_https_scheme = true ]; then
    target="https://$INGRESS_HOST:$SECURE_INGRESS_PORT$VIRTUALSERVICE_MATCH_URI"
else
    target="http://$INGRESS_HOST:$INGRESS_PORT$VIRTUALSERVICE_MATCH_URI"
fi

[[ $FORTIO_CONN -gt 0 ]] && run_fortio "$target"
[[ $K6_VUSER -gt 0 ]] && run_k6 "$target"

if [ $keep_installed_resources = false ]; then
    delete_sample_apps "${apps[@]}"
    uninstall_istio
fi
