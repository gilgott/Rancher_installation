#! /bin/bash
CERT_MANAGER_VERSION="v1.15.3"
RANCHER_VERSION="2.8.5"
RKE2_VERSION="v1.28.12+rke2r1"
RKE2_URL="https://github.com/rancher/rke2/releases/download"
RKE2_FILES=( "rke2.linux-amd64.tar.gz" "sha256sum-amd64.txt" "rke2-images.linux-amd64.tar.gz" )
DOCKER_REPO_MIRROR=""
QUAY_REPO_MIRROR=""
OFFLINE_INSTALLATION="false"
ARTIFACTS_DIR="$(dirname $0)/Artifacts"
configSet=0
KUBECTL_RETRIES=12
green='\033[0;32m'
red='\033[0;31m'
clear='\033[0m'


### Handle flags ###
function flags () {
    while [[ $# -gt 0 ]]
    do
        case $1 in
            -h | --help) 
                help
                exit 0
                ;;
            -v | --version| -v=* | --version=*)
                if [[ "$1" == *=* ]]; then
                    # Case where version is passed like -v=1.2.3 or --version=1.2.3
                    RKE2_VERSION="${1#*=}"
                elif [[ -n "$2" && "$2" != -* ]]; 
                then
                    # Case where version is passed like -v 1.2.3 or --version 1.2.3
                    RKE2_VERSION="$2"
                    shift                   # 2 parameters are used, need to shift an extra time.
                else
                    echo "${red}Error the given RKE2 version is invalid.${clear}"
                    help
                    exit 1
                fi
                ;;
            -a | --artifacts | -a=* | --artifacts=*)
                if [[ "$1" == *=* ]]; 
                then
                    ARTIFACTS_DIR="${1#*=}"
                elif [[ -n "$2" && "$2" != -* ]]; then
                    ARTIFACTS_DIR="${2%/}"  # Remove trailing slashes
                    shift                   # 2 parameters are used, need to shift an extra time.
                else
                    echo "${red}Error the given Artifacts directory location is invalid.${clear}"
                    help
                    exit 1
                fi
                
                # Validate artifact directory path syntax
                if [[ ! "$ARTIFACTS_DIR" =~ ^[a-zA-Z0-9._/~/-]+$ ]]; then
                    echo -e "${red}Error the given Artifacts directory path contains invalid characters.${clear}"
                    help
                    exit 1
                fi
                ;;
            --offline)
                OFFLINE_INSTALLATION="true"
                ;;
            --docker-mirror-repo | --docker-mirror-repo=*)
                if [[ "$1" == *=* ]]; 
                then
                    DOCKER_REPO_MIRROR="${1#*=}"
                elif [[ -n "$2" && "$2" != -* ]]; then
                    DOCKER_REPO_MIRROR="${2%/}"  # Remove trailing slashes
                    shift                        # 2 parameters are used, need to shift an extra time.
                else
                    echo -e "${red}Error docker repo mirror address given was incorrect.${clear}"
                    help
                    exit 1
                fi
                ;;
            --quay-mirror-repo | --quay-mirror-repo=*)
                if [[ "$1" == *=* ]]; 
                then
                    QUAY_REPO_MIRROR="${1#*=}"
                elif [[ -n "$2" && "$2" != -* ]]; then
                    QUAY_REPO_MIRROR="${2%/}"   # Remove trailing slashes
                    shift                       # 2 parameters are used, need to shift an extra time.
                else
                    echo -e "${red}Error quay repo mirror address given was incorrect.${clear}"
                    help
                    exit 1
                fi
                ;;
            *)
                echo "Invalid option: $1" >&2
                help
                exit 1
                ;;
        esac
        shift
    done
}       
### Help function ###
function help () {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "-h, --help                Display this help message"
    echo "-v, --version             Set rke2 version (only used in online mode)"
    echo "-a, --artifacts           Set the 'Artifacts' directory location"
    echo "--offline                 Set the script to run in offline mode"
    echo "--docker-mirror-repo      Set a mirrored repo address to be used in place of docker.io (used in offline installations)"     
    echo "--quay-mirror-repo        Set a mirrored repo address to be used in place of quay.io (used in offline installations)"
}

### Install RKE2 ###
function install_rke2 () {
    #download files
    if [ "$OFFLINE_INSTALLATION"  == "false" ]
    then
        if [ ! -d "$ARTIFACTS_DIR" ]
        then
            mkdir $ARTIFACTS_DIR
        fi

        for file in "${RKE2_FILES[@]}"
        do
            if [ ! -e "Artifacts/$file" ] # Do not download if file already exists
            then
                echo "Downloading $file"
                curl -L --progress-bar -o "Artifacts/$file" "${RKE2_URL}/${RKE2_VERSION}/$file"
                if [ $? -ne 0 ] # catch error
                then
                    echo -e "${red}Download of $file failed!${clear}"
                    exit 1
                fi
            fi
        done
    fi
    for file in "${RKE2_FILES[@]}"
    do
        if [ ! -e "Artifacts/$file" ]
        then
            echo -e "${red}Missing $file for RKE2 installation${clear}"
            exit 1
        fi
    done 

    #install rke2
    mkdir -p /etc/rancher/rke2
    mkdir -p /var/lib/rancher/rke2/agent/images/
    if [ -e /etc/rancher/rke2/config.yaml ]
    then
        echo -e "${green}Found previous config file. Delete it?${clear} (y/n)"
        while true
        do
            read -r deleteConfig
            case "$deleteConfig" in
            "y"|"Y") rm /etc/rancher/rke2/config.yaml; break
            ;;
            "n"|"N") configSet=1; break
            ;;
            *) echo "Please type y/n"
            ;;
            esac
        done
    fi

    if [ $configSet -ne 1 ]
    then
        while true
        do
          echo -e "${green}Please enter the name of the cluster:${clear}"
          read -r clusterName
          echo Got $clusterName
          echo "Is this ok? (y/n)"
          read -r response
          case "$response" in
          "y"|"Y") break
          ;;
          *) 
          ;;
          esac
        done    

    
        echo -e "${green}Is this the first server to be installed?${clear} (y/n)"
        read -r server_select
    
        declare -a tls
        while true
        do
          echo -e "${green}Enter FQDN and IP for the cluster certificates, use spaces between each address.${clear}"
          read -r tls
          echo Got ${tls[@]}
          echo "Is this ok? (y/n)"
          read -r response
          case "$response" in
          "y"|"Y") break
          ;;
          *) 
          ;;
          esac
        done
    
        if [ $server_select == "y" ] || [ $server_select == "Y" ];
        then
          serverIp=$(hostname -I | awk '{print $1}')
          nodenum=1
        else
          echo -e "${green}Enter first server's IP\FQDN:${clear}"
          read -r serverIp
          echo "server: https://${serverIp}:9345" >> /etc/rancher/rke2/config.yaml
          echo -e "${green}Please enter the machine number. This will be appended to its name in the cluster, ex entering '3' will result in the machine name '${clusterName}-master3':${clear}"
          read -r nodenum
          echo -e "${green}Copy the token from the first server, the token can be found in this location:${clear}"
          echo -e "${green}/var/lib/rancher/rke2/server/node-token${clear}"
          echo -e "${green}Now please enter the rancher${clear} ${red}token${clear} ${green}in order to add this machine to an existing cluster:${clear}"
          read -r token
          echo "token: ${token}" >> /etc/rancher/rke2/config.yaml
        fi
    
        echo -e "${green}Creating configuration file...${clear}"
        echo "tls-san:" >> /etc/rancher/rke2/config.yaml
        for tls in ${tls[@]}
        do
          echo "  - \"${tls}\"" >> /etc/rancher/rke2/config.yaml
        done
        echo "node-name:" >> /etc/rancher/rke2/config.yaml
        echo "  - $clusterName-master$nodenum" >> /etc/rancher/rke2/config.yaml
    else
        tls=( $(sed -n '/tls-san:/,/node-name:/ s/.*- "\(.*\)"/\1/p' /etc/rancher/rke2/config.yaml) )
    fi

    echo " "
    echo -e "${green}Running and installing${clear}"
    INSTALL_RKE2_ARTIFACT_PATH=$ARTIFACTS_DIR sh rke2_install_script.sh --tls-san $(echo ${tls[@]} | sed 's/ /,/g') 2>&1
    if [ $? -ne 0 ]
    then 
        echo -e "${red}rke2 installation failed!${clear}"
        exit 1;
    fi
    echo " "
    echo -e "${green}Enabling RKE2 service and agent${clear}"
    systemctl enable rke2-server.service
    systemctl enable rke2-agent.service
    echo " "
    echo -e "${green}Starting RKE2 service${clear}"
    systemctl start rke2-server.service
    
    echo " "
    echo -e "${green}Copying 'kubectl' to /usr/bin/${clear}"
    cp /var/lib/rancher/rke2/bin/kubectl /usr/bin/
    echo " "
    echo -e "${green}Creating directory for configuration file and copying to location${clear}"
    mkdir -p /home/$SUDO_USER/.kube/
    ln -s /etc/rancher/rke2/rke2.yaml /home/$SUDO_USER/.kube/config
    chmod +r /home/$SUDO_USER/.kube/config
    export KUBECONFIG=/home/$SUDO_USER/.kube/config
    echo "Waiting for cluster to respond"
    i=0
    while [ $i -le $KUBECTL_RETRIES ] #wait for cluster to respond
    do
        kubectl get nodes
        if [ $? -eq 0 ]
        then
            break
        fi
        i=$((i + 1 ))
        sleep 10
    done
    if [ $i -gt $KUBECTL_RETRIES ] #health check failed
    then
        echo "Error cluster failed to respond after $KUBECTL_RETRIES retries."
        exit 1
    fi
    echo " "
    echo -e "${green}RKE2 installed!${clear}"
}

### Install cert-manager ###
function install_cert_manager () {
    #download files
    if [ "$OFFLINE_INSTALLATION"  == "false" ]
    then
        #install helm
        if ! command -v helm &>/dev/null
        then
            echo -e "${green}Helm missing on machine, installing helm 3 now.${clear}"
            ./helm_install.sh 2>&1
            if [ $? -ne 0 ]
            then 
                echo -e "${red}Detected an error with helm installation.${clear}"
                exit 1
            fi
        fi
        
        # Fetch chart
        if [ -e $ARTIFACTS_DIR/cert-manager-*.tgz ] || [ -d $ARTIFACTS_DIR/cert-manager ] # looking for either a zipped chart or an unzipped folder
        then
            echo -e "${green}Cert-manager Chart found.\nPlease make sure the chart version is $CERT_MANAGER_VERSION as other versions are not supported.${clear}"
        else
            echo -e "${green}Fetching Cert-manager helm chart${clear}"
            helm repo add jetstack https://charts.jetstack.io --force-update
            if [ $? ne 0]
            then
                echo "Adding jetstack repo failed!"
                exit 1;
            fi
            helm pull jetstack/cert-manager -d $ARTIFACTS_DIR --version $CERT_MANAGER_VERSION
        fi
    fi

    #check helm installed correctly
    if ! command -v helm &>/dev/null
    then
        echo -e "${red}Helm missing on machine${clear}"
        exit 1;
    fi
 
    #set mirror repository
    if [ ! -z "$QUAY_REPO_MIRROR" ]
    then
        CERT_MANAGER_CHART_ARGS=" --set image.repository=${QUAY_REPO_MIRROR}/jetstack/cert-manager-controller 
        --set webhook.image.repository=${QUAY_REPO_MIRROR}/jetstack/cert-manager-webhook 
        --set cainjector.image.repository=${QUAY_REPO_MIRROR}/jetstack/cert-manager-cainjector 
        --set acmesolver.image.repository=${QUAY_REPO_MIRROR}/jetstack/cert-manager-acmesolver 
        --set startupapicheck.image.repository=${QUAY_REPO_MIRROR}/jetstack/cert-manager-startupapicheck"
    fi
    
    #install cert-manager
    echo " "
    echo -e "${green}Cert-manager installation.${clear}"
    if [ -d $ARTIFACTS_DIR/cert-manager ]
    then
        echo -e "${green}Installing cert-manager from unpacked chart directory.\nPlease note all configurations are taken from values.yaml except for:\n1)namespace (cert-manager).\n2)Quay.io mirrored repo will be substituted if specified.${clear}"
        eval helm install cert-manager $ARTIFACTS_DIR/cert-manager --namespace cert-manager --create-namespace $CERT_MANAGER_CHART_ARGS
    else
        eval helm install cert-manager $ARTIFACTS_DIR/cert-manager-*.tgz --namespace cert-manager --create-namespace --set crds.enabled=true $CERT_MANAGER_CHART_ARGS
    fi
}

### Install rancher ###
function install_rancher () {
    #download files
    if [ "$OFFLINE_INSTALLATION"  == "false" ]
    then
        #install helm
        if ! command -v helm &>/dev/null
        then
            echo -e "${green}Helm missing on machine, installing helm 3 now.${clear}"
            ./helm_install.sh 2>&1
            if [ $? -ne 0 ]
            then 
                echo -e "${red}Detected an error with helm installation.${clear}"
                exit 1
            fi
        fi
       
        #Fetch chart
        if [ -e $ARTIFACTS_DIR/rancher-*.tgz ] || [ -d $ARTIFACTS_DIR/rancher/ ] # looking for either a zipped chart or an unzipped folder
        then
            echo -e "${green}Rancher Chart found.\nPlease make sure the chart version is $RANCHER_VERSION as other versions are not supported.${clear}"
        else
            echo -e "${green}Fetching Rancher helm chart${clear}"
            helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
            if [ $? ne 0]
            then
                echo "Adding rancher repo failed!"
                exit 1;
            fi
            helm pull rancher-stable/rancher -d $ARTIFACTS_DIR --version $RANCHER_VERSION
        fi
    fi

    #check helm installed correctly
    if ! command -v helm &>/dev/null
    then
        echo -e "${red}Helm missing on machine${clear}"
        exit 1;
    fi

    #set mirror repository
    if [ ! -z "$DOCKER_REPO_MIRROR" ]
    then
        RANCHER_CHART_ARGS=" --set auditLog.image.repository=$DOCKER_REPO_MIRROR/rancher/mirrored-bci-micro 
        --set rancherImage=$DOCKER_REPO_MIRROR/rancher/rancher 
        --set systemDefaultRegistry=$DOCKER_REPO_MIRROR"
    fi

    #install rancher
    echo " "
    echo -e "${green}Rancher installation.${clear}"
    if [ -d $ARTIFACTS_DIR/rancher ]
    then
        echo -e "${green}Installing rancher from unpacked chart directory.\nPlease note all configurations are taken from values.yaml except for:\n1)namespace (cattle-system).\n2)useBundledSystemChart (charts catalog will use offline charts in offline installation and visa-versa).\n3)Docker mirrored repo will be substituted if specified.${clear}"
        eval helm install rancher $ARTIFACTS_DIR/rancher --namespace cattle-system --create-namespace $RANCHER_CHART_ARGS --set useBundledSystemChart=$OFFLINE_INSTALLATION
    else
        echo -e "${green}Please enter the FQDN for the rancher manager:${clear}"
        read -r FQDN
        eval helm install rancher $ARTIFACTS_DIR/rancher-*.tgz --namespace cattle-system --create-namespace --set bootstrapPassword=admin --set hostname=$FQDN $RANCHER_CHART_ARGS useBundledSystemChart=$OFFLINE_INSTALLATION
    fi
}

### Handle flags ### 
flags "$@"

### Check if root ### 
if [ "$EUID" -ne 0 ]
  then echo -e "${red}Please run as root${clear}"
  exit
fi

PS3='Please enter your choice: '
options=("Install all" "Install rke2" "Install cert-manager+rancher" "Install cert-manager only" "Install rancher only" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "Install all"|"1")
            install_rke2
            install_cert_manager
            install_rancher
            ;;
        "Install rke2"|"2")
            install_rke2
            ;;
        "Install cert-manager+rancher"|"3")
            install_cert_manager
            install_rancher
            ;;
        "Install cert-manager only"|"4")
            install_cert_manager
            ;;
        "Install rancher only"|"5")
            install_rancher
            ;;
        "Quit")
            break
            ;;
        *) echo "invalid option $REPLY";;
    esac
done

echo " "
echo -e "${green}Installation complete!${clear}"