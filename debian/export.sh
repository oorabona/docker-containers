#!/bin/bash

# Stop the script if any command fails
set -e
set -o pipefail
# set -x # Enable debugging output

# Function to display help
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --version=<version>             Specify the distribution version (e.g., sid, buster)"
    echo "  --locales=<locales>             Specify locales to be installed (e.g., 'fr_FR en_US')"
    echo "  --packages=[none|copy|install]  Manage installed packages (default: none)"
    echo "  --package-manager=[apt|apt-get|aptitude] Choose the package manager (default: apt)"
    echo "  --copy-etc                      Copy the /etc directory into the container"
    echo "  --copy-etc-exclude=<dirs>       Exclude specific directories from /etc (comma-separated)"
    echo "  --copy-home                     Copy the /home directory into the container"
    echo "  --copy-home-exclude=<dirs>      Exclude specific directories from /home (comma-separated)"
    echo "  --omit-linux-kernel             Omit Linux kernel-related packages (linux-*)"
    echo "  --help                          Display this help"
    echo
}

# Initialize variables
VERSION="sid"   # Default value
LOCALES="en_US" # Default locales
PACKAGES_OPTION="none"
PACKAGE_MANAGER="apt"
COPY_ETC=false
COPY_HOME=false
OMIT_LINUX_KERNEL=false
COPY_ETC_EXCLUDE=()
COPY_HOME_EXCLUDE=()

# Process arguments
for i in "$@"; do
    case $i in
    --version=*)
        VERSION="${i#*=}"
        shift
        ;;
    --locales=*)
        LOCALES="${i#*=}"
        shift
        ;;
    --packages=*)
        PACKAGES_OPTION="${i#*=}"
        if [[ ! "$PACKAGES_OPTION" =~ ^(none|copy|install)$ ]]; then
            echo "Error: Invalid value for --packages: $PACKAGES_OPTION"
            exit 1
        fi
        shift
        ;;
    --package-manager=*)
        PACKAGE_MANAGER="${i#*=}"
        if [[ ! "$PACKAGE_MANAGER" =~ ^(apt|apt-get|aptitude)$ ]]; then
            echo "Error: Invalid value for --package-manager: $PACKAGE_MANAGER"
            exit 1
        fi
        shift
        ;;
    --copy-etc)
        COPY_ETC=true
        shift
        ;;
    --copy-etc-exclude=*)
        IFS=',' read -ra dirs <<<"${i#*=}"
        COPY_ETC_EXCLUDE+=("${dirs[@]}")
        shift
        ;;
    --copy-home)
        COPY_HOME=true
        shift
        ;;
    --copy-home-exclude=*)
        IFS=',' read -ra dirs <<<"${i#*=}"
        COPY_HOME_EXCLUDE+=("${dirs[@]}")
        shift
        ;;
    --omit-linux-kernel)
        OMIT_LINUX_KERNEL=true
        shift
        ;;
    --help)
        show_help
        exit 0
        ;;
    *)
        echo "Unknown option: $i"
        show_help
        exit 1
        ;;
    esac
done

# Summarize choices and confirm
echo "Selected options:"
echo "  - Distribution version: $VERSION"
echo "  - Locales: $LOCALES"
echo "  - Package management: $PACKAGES_OPTION"
echo "  - Package manager: $PACKAGE_MANAGER"
echo "  - Copy /etc directory: $COPY_ETC"
echo "  - Exclusions from /etc: ${COPY_ETC_EXCLUDE[*]}"
echo "  - Copy /home directory: $COPY_HOME"
echo "  - Exclusions from /home: ${COPY_HOME_EXCLUDE[*]}"
echo "  - Omit Linux kernel packages: $OMIT_LINUX_KERNEL"
echo
read -p "Do you confirm these choices? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "Operation canceled."
    exit 0
fi

# Start Docker Compose services with build arguments
docker compose build --build-arg VERSION="$VERSION" --build-arg LOCALES="$LOCALES"
docker compose up -d

# Wait until the container is running
container_name="debian-${VERSION}"
echo "Waiting for the container ${container_name} to start..."
while [ -z "$(docker ps -qf "name=${container_name}")" ]; do
    sleep 2
done

container_id=$(docker ps -qf "name=${container_name}")

# Manage APT sources and packages
if [ "$PACKAGES_OPTION" == "copy" ] || [ "$PACKAGES_OPTION" == "install" ]; then
    echo "Copying APT sources from /etc/apt/sources.list.d..."

    # Ensure the target directory exists in the container
    docker exec -it "${container_id}" mkdir -p /etc/apt/sources.list.d/ || {
        echo "Failed to create directory /etc/apt/sources.list.d/"
        exit 1
    }

    # Copy files individually to avoid creating a nested directory
    for file in /etc/apt/sources.list.d/*.list; do
        if [ -f "$file" ]; then
            # Extract 'signed-by' path if present
            signed_by=$(grep -oP '\[?signed-by=\K[^]]*' "$file" | cut -d' ' -f1 || true)

            for sb in $signed_by; do
                # Only attempt to copy the keyring file if signed_by is not empty
                if [ -n "$sb" ]; then
                    if [ -f "$sb" ]; then
                        echo "Copying APT keyring $sb..."
                        docker cp "$sb" "${container_id}:${sb}" || {
                            echo "Failed to copy $sb"
                            exit 1
                        }
                    else
                        echo "Warning: Keyring file $sb not found, skipping."
                    fi
                else
                    echo "No 'signed-by' entry found in $file, skipping keyring copy."
                fi
            done

            echo "Copying APT source file $file..."
            docker cp "$file" "${container_id}:/etc/apt/sources.list.d/" || {
                echo "Failed to copy $file"
                exit 1
            }
        fi
    done

    echo "Copying APT trusted keys..."
    for trusted in /etc/apt/trusted.gpg.d/*; do
        if [ -r "$trusted" ]; then
            docker cp "$trusted" "${container_id}:/etc/apt/trusted.gpg.d/" || {
                echo "Failed to copy trusted key $trusted"
                exit 1
            }
        fi
    done

    echo "Generating a list of manually installed packages..."
    if [ "$OMIT_LINUX_KERNEL" = true ]; then
        apt-mark showmanual | grep -vE '^linux-' >installed-packages.txt
    else
        apt-mark showmanual >installed-packages.txt
    fi

    echo "Copying the list of packages into the container..."
    docker cp installed-packages.txt "${container_id}:/home/${USER}/installed-packages.txt"

    if [ "$PACKAGES_OPTION" == "install" ]; then
        echo "Updating package manager repositories in the container..."
        docker exec -it "${container_id}" bash -c "sudo $PACKAGE_MANAGER update" || {
            echo "Failed to update package manager"
            exit 1
        }

        echo "Installing packages in the container using $PACKAGE_MANAGER..."
        docker exec -it "${container_id}" bash -c "sudo xargs -a /home/${USER}/installed-packages.txt $PACKAGE_MANAGER install -y" || {
            echo "Failed to install packages"
            exit 1
        }
    fi
fi

# Copy the /etc directory
if [ "$COPY_ETC" = true ]; then
    echo "Copying /etc directory into the container..."
    tar --exclude="${COPY_ETC_EXCLUDE[@]}" --ignore-failed-read -czf - /etc | docker exec -i "${container_id}" bash -c "sudo tar -xzf - -C /" || {
        echo "Failed to copy some files in /etc directory, but continuing..."
    }
    echo "/etc directory copy completed."
fi

# Copy the /home directory
if [ "$COPY_HOME" = true ]; then
    echo "Copying /home directory into the container..."
    tar --exclude="${COPY_HOME_EXCLUDE[@]}" -czf - /home | docker exec -i "${container_id}" bash -c "sudo tar -xzf - -C /" || {
        echo "Failed to copy /home directory"
        exit 1
    }
    echo "/home directory copy completed."
fi

# Export the container to a gzipped tar file
echo "Exporting the container with gzip compression..."
docker export -o "${container_name}.tar" "$container_id"
#docker export "$container_id" | gzip > "${container_name}.tar.gz"
#docker commit "$container_id" ${container_name}
#docker save -o ${container_name}.tar ${container_name}

# Stop and remove the container
docker compose down

echo "Migration completed. The container has been exported to ${container_name}.tar"
