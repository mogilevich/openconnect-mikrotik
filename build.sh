#!/bin/bash
# ============================================
# Build script for OpenConnect MikroTik container
# ============================================

set -e

IMAGE_NAME="openconnect-mikrotik"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}OpenConnect MikroTik Container Builder${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

ARCH="${1:-arm64}"

case $ARCH in
    arm64|aarch64)
        PLATFORM="linux/arm64"
        TAG_SUFFIX="arm64"
        echo -e "${GREEN}Building for ARM64 (hAP ax2, ax3, RB5009, etc.)${NC}"
        ;;
    arm|arm32|armv7)
        PLATFORM="linux/arm/v7"
        TAG_SUFFIX="arm"
        echo -e "${GREEN}Building for ARM32 (hAP ac2, hEX, RB4011, etc.)${NC}"
        ;;
    amd64|x86_64|x86)
        PLATFORM="linux/amd64"
        TAG_SUFFIX="amd64"
        echo -e "${GREEN}Building for AMD64 (CHR, x86 routers)${NC}"
        ;;
    all)
        echo -e "${GREEN}Building for all architectures...${NC}"
        $0 arm64
        $0 arm
        $0 amd64
        echo -e "${GREEN}All architectures built!${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}Unknown architecture: $ARCH${NC}"
        echo ""
        echo "Usage: $0 [arch]"
        echo ""
        echo "Architectures:"
        echo "  arm64  - ARM64 (hAP ax2, ax3, RB5009) - default"
        echo "  arm    - ARM32 (hAP ac2, hEX, RB4011)"
        echo "  amd64  - AMD64 (CHR, x86)"
        echo "  all    - Build all architectures"
        exit 1
        ;;
esac

echo ""

if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed!${NC}"
    exit 1
fi

FULL_TAG="${IMAGE_NAME}:${TAG_SUFFIX}"
TAR_FILE="${IMAGE_NAME}-${TAG_SUFFIX}.tar"

echo -e "Image: ${GREEN}${FULL_TAG}${NC}"
echo -e "Platform: ${GREEN}${PLATFORM}${NC}"
echo ""

echo -e "${YELLOW}Building image...${NC}"

if docker buildx version &> /dev/null; then
    docker buildx create --name mikrotik-builder --use 2>/dev/null || docker buildx use mikrotik-builder 2>/dev/null || true
    docker buildx build --platform ${PLATFORM} --tag ${FULL_TAG} --load --no-cache .
else
    docker build --no-cache -t ${FULL_TAG} .
fi

echo ""
IMAGE_SIZE=$(docker image inspect ${FULL_TAG} --format='{{.Size}}' | awk '{printf "%.1fMB", $1/1024/1024}')
echo -e "Image size: ${GREEN}${IMAGE_SIZE}${NC}"

echo -e "${YELLOW}Exporting to tar...${NC}"
docker save ${FULL_TAG} > ${TAR_FILE}

SIZE=$(du -h ${TAR_FILE} | cut -f1)

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Done!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "File: ${GREEN}${TAR_FILE}${NC} (${SIZE})"
echo ""
echo "Upload the file to MikroTik and run:"
echo ""
echo "  /container add file=${TAR_FILE} \\"
echo "      interface=veth-vpn \\"
echo "      envlist=openconnect \\"
echo "      root-dir=openconnect \\"
echo "      dns=8.8.8.8 \\"
echo "      start-on-boot=yes \\"
echo "      logging=yes"
echo ""
echo "  /container start 0"
echo ""
