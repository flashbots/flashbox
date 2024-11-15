#!/bin/bash
set -e

usage() {
    echo "Usage: $0 [command] [options] <cloud> <name> [region] [image-path]"
    echo ""
    echo "Commands:"
    echo "  deploy                    Deploy a new VM (default if no command specified)"
    echo "  cleanup                   Remove all resources for the given name"
    echo ""
    echo "Cloud Platforms:"
    echo "  azure                     Deploy to Azure"
    echo "  gcp                       Deploy to Google Cloud Platform"
    echo ""
    echo "Arguments:"
    echo "  name                      Resource name/prefix for the deployment"
    echo "  region                    Cloud region to deploy in (default: westeurope for Azure, us-east4 for GCP)"
    echo "  image-path               Path to VM image (optional, will download appropriate image if not provided)"
    echo ""
    echo "Options:"
    echo "  --machine-type TYPE      VM size (default: Standard_EC4eds_v5 for Azure, c3-standard-4 for GCP)"
    echo "  --ports PORTS            Additional ports to open, comma-separated (24070,24071 always open)"
    echo "  --ssh-source-ip IP       Restrict SSH access to this IP address"
    exit 1
}

download_flashbox() {
    local cloud=$1
    local image_name
    local expected_file
    
    if [[ "$cloud" == "azure" ]]; then
        image_name="flashbox.azure.vhd"
        expected_file="$image_name"
    else
        image_name="flashbox.raw.tar.gz"
        expected_file="$image_name"
    fi

    if [ -f "$expected_file" ]; then
        echo "Using existing $expected_file"
    else
        echo "Downloading $image_name..."
        local DOWNLOAD_URL=$(curl -s https://api.github.com/repos/flashbots/flashbox/releases/latest | grep "browser_download_url.*${image_name}" | cut -d '"' -f 4)
        if [ -z "$DOWNLOAD_URL" ]; then
            echo "Error: Could not find download URL for $image_name"
            exit 1
        fi
        wget "$DOWNLOAD_URL" || {
            echo "Error: Failed to download $image_name"
            exit 1
        }
    fi
    echo "$expected_file is ready"
    echo "$expected_file"
}

check_dependencies() {
    local cloud=$1
    if [[ "$cloud" == "azure" ]]; then
        command -v az >/dev/null 2>&1 || { echo "Error: 'az' required"; exit 1; }
        command -v azcopy >/dev/null 2>&1 || { echo "Error: 'azcopy' required"; exit 1; }
        command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' required"; exit 1; }
    elif [[ "$cloud" == "gcp" ]]; then
        command -v gcloud >/dev/null 2>&1 || { echo "Error: 'gcloud' required"; exit 1; }
    fi
}

cleanup_azure() {
    local name=$1
    echo "Cleaning up Azure resources for $name..."
    az group delete --name "$name" --yes
}

cleanup_gcp() {
    local name=$1
    local label="flashbox-deployment=$name"
    
    echo "Cleaning up GCP resources for $name..."
    
    # Delete VM instance
    gcloud compute instances delete "$name" --quiet || true
    
    # Delete image
    gcloud compute images delete "$name" --quiet || true
    
    # Delete firewall rules
    gcloud compute firewall-rules list --filter="labels.$label" --format="get(name)" | \
    while read -r rule; do
        gcloud compute firewall-rules delete "$rule" --quiet || true
    done
    
    # Delete network
    gcloud compute networks delete "$name" --quiet || true
    
    # Delete storage bucket
    gcloud storage rm -r "gs://${name}" || true
}

create_azure_deployment() {
    local name=$1
    local region=$2
    local image_path=$3
    local machine_type=${4:-"Standard_EC4eds_v5"}
    local ssh_source_ip=$5
    local additional_ports=$6
    
    # Create resource group
    echo "Creating resource group..."
    az group create --name "$name" --location "$region"
    
    # Create and upload disk
    echo "Creating and uploading disk..."
    local disk_size=$(wc -c < "$image_path")
    az disk create -n "$name" -g "$name" -l "$region" \
        --os-type Linux \
        --upload-type Upload \
        --upload-size-bytes "$disk_size" \
        --sku standard_lrs \
        --security-type ConfidentialVM_NonPersistedTPM \
        --hyper-v-generation V2

    # Upload VHD
    local sas_json=$(az disk grant-access -n "$name" -g "$name" --access-level Write --duration-in-seconds 86400)
    local sas_uri=$(echo "$sas_json" | jq -r '.accessSas')
    azcopy copy "$image_path" "$sas_uri" --blob-type PageBlob
    az disk revoke-access -n "$name" -g "$name"

    # Create NSG with base rules
    echo "Creating network security group..."
    az network nsg create --name "$name" --resource-group "$name" --location "$region"
    
    # Add SSH rule with optional IP restriction
    local ssh_source="${ssh_source_ip:-*}"
    az network nsg rule create --nsg-name "$name" --resource-group "$name" \
        --name AllowSSH --priority 100 \
        --source-address-prefixes "$ssh_source" \
        --destination-port-ranges 22 --access Allow --protocol Tcp

    # Add default ports
    az network nsg rule create --nsg-name "$name" --resource-group "$name" \
        --name "FlashboxAPI" --priority 200 \
        --destination-port-ranges 24070-24071 --access Allow --protocol Tcp

    # Add additional port rules if specified
    if [[ -n "$additional_ports" ]]; then
        IFS=',' read -ra PORTS <<< "$additional_ports"
        local priority=300
        for port in "${PORTS[@]}"; do
            az network nsg rule create --nsg-name "$name" --resource-group "$name" \
                --name "Port_${port}" --priority $priority \
                --destination-port-ranges "$port" --access Allow --protocol Tcp
            ((priority+=1))
        done
    fi

    # Create VM
    echo "Creating VM..."
    az vm create --name "$name" \
        --resource-group "$name" \
        --size "$machine_type" \
        --attach-os-disk "$name" \
        --security-type ConfidentialVM \
        --enable-vtpm true \
        --enable-secure-boot false \
        --os-disk-security-encryption-type NonPersistedTPM \
        --os-type Linux \
        --nsg "$name"
}

create_gcp_deployment() {
    local name=$1
    local region=$2
    local image_path=$3
    local machine_type=${4:-"c3-standard-4"}
    local ssh_source_ip=$5
    local additional_ports=$6
    
    local zone="${region}-b" # Assuming zone b
    local deployment_label="flashbox-deployment=$name"

    # Create network if it doesn't exist
    echo "Creating network..."
    gcloud compute networks create "$name" \
        --subnet-mode=auto \
        --labels="$deployment_label" || true

    # Create firewall rules
    echo "Creating firewall rules..."
    
    # SSH rule with optional IP restriction
    local ssh_source="${ssh_source_ip:-0.0.0.0/0}"
    gcloud compute firewall-rules create "${name}-ssh" \
        --network="$name" \
        --allow=tcp:22 \
        --source-ranges="$ssh_source" \
        --labels="$deployment_label"

    # Default ports
    gcloud compute firewall-rules create "${name}-flashbox" \
        --network="$name" \
        --allow=tcp:24070-24071 \
        --labels="$deployment_label"

    # Additional ports if specified
    if [[ -n "$additional_ports" ]]; then
        local ports_list="tcp:${additional_ports//,/,tcp:}"
        gcloud compute firewall-rules create "${name}-ports" \
            --network="$name" \
            --allow="$ports_list" \
            --labels="$deployment_label"
    fi

    # Upload and create image
    echo "Creating storage bucket and uploading image..."
    gcloud storage buckets create "gs://${name}" --labels="$deployment_label"
    gcloud storage cp "$image_path" "gs://${name}/image.tar.gz"

    echo "Creating VM image..."
    gcloud compute images create "$name" \
        --source-uri="gs://${name}/image.tar.gz" \
        --guest-os-features=UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE,GVNIC,TDX_CAPABLE \
        --labels="$deployment_label"

    echo "Creating VM..."
    gcloud compute instances create "$name" \
        --zone="$zone" \
        --machine-type="$machine_type" \
        --network="$name" \
        --image="$name" \
        --confidential-compute-type=TDX \
        --maintenance-policy=TERMINATE \
        --labels="$deployment_label"
}

# Parse command line arguments
COMMAND="deploy"
CLOUD=""
NAME=""
REGION=""
IMAGE_PATH=""
MACHINE_TYPE=""
SSH_SOURCE_IP=""
ADDITIONAL_PORTS=""

# Check if first arg is a command
case $1 in
    deploy|cleanup)
        COMMAND="$1"
        shift
        ;;
esac

while [[ $# -gt 0 ]]; do
    case $1 in
        --machine-type)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --ports)
            ADDITIONAL_PORTS="$2"
            shift 2
            ;;
        --ssh-source-ip)
            SSH_SOURCE_IP="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            if [[ -z "$CLOUD" ]]; then
                CLOUD="$1"
            elif [[ -z "$NAME" ]]; then
                NAME="$1"
            elif [[ -z "$REGION" ]]; then
                REGION="$1"
            elif [[ -z "$IMAGE_PATH" ]]; then
                IMAGE_PATH="$1"
            else
                echo "Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$CLOUD" ]] || [[ -z "$NAME" ]]; then
    echo "Error: Missing required arguments"
    usage
fi

if [[ "$CLOUD" != "azure" ]] && [[ "$CLOUD" != "gcp" ]]; then
    echo "Error: Invalid cloud platform. Must be 'azure' or 'gcp'"
    usage
fi

# Set default region if not specified for deploy command
if [[ "$COMMAND" == "deploy" && -z "$REGION" ]]; then
    REGION=$([ "$CLOUD" == "azure" ] && echo "westeurope" || echo "us-east4")
fi

# Execute command
case $COMMAND in
    deploy)
        check_dependencies "$CLOUD"
        if [[ -z "$IMAGE_PATH" ]]; then
            IMAGE_PATH=$(download_flashbox "$CLOUD")
        fi
        if [[ "$CLOUD" == "azure" ]]; then
            create_azure_deployment "$NAME" "$REGION" "$IMAGE_PATH" "$MACHINE_TYPE" "$SSH_SOURCE_IP" "$ADDITIONAL_PORTS"
        else
            create_gcp_deployment "$NAME" "$REGION" "$IMAGE_PATH" "$MACHINE_TYPE" "$SSH_SOURCE_IP" "$ADDITIONAL_PORTS"
        fi
        ;;
    cleanup)
        if [[ "$CLOUD" == "azure" ]]; then
            cleanup_azure "$NAME"
        else
            cleanup_gcp "$NAME"
        fi
        ;;
esac

echo "${COMMAND} complete!"
